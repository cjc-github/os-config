#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Doctor.ps1 —— 环境体检（engine/lib/doctor.sh 的移植）
.DESCRIPTION
  纯只读，不走 catalog 分派。

  契约（必须与 Bash 版一致）：
    * 检查函数返回 0=通过、2=需关注（不影响退出码）、其余=未通过。
    * Invoke-DoctorCheck 自身恒返回 0——单项失败绝不能中断整个序列。
    * doctor_run 仅在有未通过项时返回 1。

  与 Bash 版的检查项差异：winget 没有 apt 锁与 APT 镜像源这两个概念，
  对应换成"winget 可用性"；sudo 换成提权判定。
#>

Set-StrictMode -Version 2.0

$script:DOCTOR_OK = 0
$script:DOCTOR_WARN = 0
$script:DOCTOR_FAIL = 0

function Invoke-DoctorCheck {
  <# _doctor_check 的移植：恒返回 0 #>
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Hint,
    [Parameter(Mandatory=$true)][scriptblock]$Check
  )
  Write-InfoLog ("[doctor] {0} —— {1}" -f $Name, $Hint)
  $rc = & $Check
  if ($rc -eq 0) {
    Write-OkLog ("[doctor] {0}：通过" -f $Name)
    $script:DOCTOR_OK++
  } elseif ($rc -eq 2) {
    Write-WarnLog ("[doctor] {0}：需关注" -f $Name)
    $script:DOCTOR_WARN++
  } else {
    Write-ErrorLog ("[doctor] {0}：未通过" -f $Name)
    $script:DOCTOR_FAIL++
  }
  return 0
}

function Test-DoctorCatalog {
  if ($script:CAT_ORDER.Count -eq 0) { return 1 }
  Write-InfoLog ("catalog 条目：{0} 个" -f $script:CAT_ORDER.Count)
  return 0
}

function Test-DoctorProfiles {
  if ($script:PROF_ORDER.Count -eq 0) { return 2 }
  Write-InfoLog ("profiles：{0} 个（{1}）" -f $script:PROF_ORDER.Count, ($script:PROF_ORDER -join ' '))
  return 0
}

function Test-DoctorElevation {
  <# _doctor_sudo 的 Windows 对应物 #>
  if (Test-IsAdmin) { return 0 }
  Write-InfoLog '当前不是管理员身份；--scope user 的安装不受影响，machine 域安装时会弹 UAC'
  return 2
}

function Test-DoctorDisk {
  <# _doctor_disk：根分区剩余 <512MB fail；<2GB warn #>
  try {
    $drive = Get-PSDrive -Name ($env:SystemDrive.Substring(0,1)) -ErrorAction Stop
    $availMb = [math]::Floor($drive.Free / 1MB)
    Write-InfoLog ("系统盘剩余：{0}MB" -f $availMb)
    if ($availMb -lt 512) { return 1 }
    if ($availMb -lt 2048) { return 2 }
    return 0
  } catch {
    return 2
  }
}

function Test-DoctorCommands {
  <# _doctor_commands：缺 curl/git → warn #>
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($c in @('curl.exe','git')) {
    if (-not (Test-CommandExists -Name $c)) { $missing.Add($c) }
  }
  if ($missing.Count -gt 0) {
    Write-WarnLog ("缺少命令：{0}" -f ($missing -join ' '))
    return 2
  }
  Write-InfoLog '基础命令齐全：curl git'
  return 0
}

function Test-DoctorWinget {
  <# winget 可用性与版本（替代 Bash 版的 apt-lock 与 mirror 两项） #>
  if (-not (Test-CommandExists 'winget')) {
    Write-WarnLog 'winget 不可用；Windows 后端的 package 条目将无法安装'
    return 2
  }
  try {
    $ver = (& winget.exe --version 2>$null | Select-Object -First 1 | Out-String).Trim()
    if ([string]::IsNullOrEmpty($ver)) { return 2 }
    Write-InfoLog ("winget 版本：{0}" -f $ver)
    return 0
  } catch { return 2 }
}

function Test-DoctorProxy {
  <# _doctor_proxy 的移植 #>
  if ((Get-ConfigValue 'PROXY_ENABLED' 'true') -ne 'true') { return 0 }
  if (-not (Test-CommandExists 'curl.exe')) { return 2 }

  $rc = Resolve-ProxyEndpoint
  if ($rc -ne 0) { return 2 }

  $hostName = $script:RESOLVED_PROXY_HOST
  $port = Get-ConfigValue 'PROXY_PORT' '7890'
  $reachRc = Test-ProxyHostReachable -HostName $hostName
  if ($reachRc -eq 2) { return 2 }
  if ($reachRc -ne 0) { return 2 }

  $testUrl = Get-ConfigValue 'PROXY_TEST_URL' 'https://github.com'
  $ct = Get-ConfigValue 'PROXY_CONNECT_TIMEOUT' '5'
  $mt = Get-ConfigValue 'PROXY_MAX_TIME' '15'
  $curlRc = Test-ProxyCurlConnectivity -ProxyUrl $script:RESOLVED_PROXY_URL -TestUrl $testUrl -ConnectTimeout $ct -MaxTime $mt
  if ($curlRc -eq 2) { return 2 }
  if ($curlRc -ne 0) {
    Write-WarnLog ("经代理 {0} 访问 {1} 失败" -f $script:RESOLVED_PROXY_URL, $testUrl)
    return 2
  }
  Write-InfoLog ("代理可用：{0}" -f $script:RESOLVED_PROXY_URL)
  return 0
}

function Test-DoctorManifest {
  <# _doctor_manifest 的移植：清单记录的产物路径消失 → warn #>
  if (-not (Test-Path -LiteralPath $script:StateFile)) { return 0 }
  try { $lines = @(Get-Content -LiteralPath $script:StateFile -Encoding UTF8 -ErrorAction Stop) }
  catch { return 0 }

  $total = 0; $missing = 0
  $tools = @{}
  foreach ($l in $lines) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    $parts = $l.Split('|')
    if ($parts.Count -lt 3) { continue }
    $tool = $parts[0]; $artifact = $parts[2]
    if ($artifact -eq '-') { continue }
    $tools[$tool] = $true
    $total++
    # Bash 版对 artifact 字段做词拆分，一个字段可能含多个空格分隔的路径
    foreach ($p in (($artifact -split '\s+') | Where-Object { $_ -ne '' })) {
      if (-not (Test-Path -LiteralPath $p)) {
        Write-WarnLog ("清单记录的产物已消失：{0}（tool={1}）" -f $p, $tool)
        $missing++
      }
    }
  }
  Write-InfoLog ("清单产物 {0} 个（涉及 {1} 个工具），缺失 {2} 个" -f $total, $tools.Count, $missing)
  if ($missing -gt 0) {
    Write-WarnLog '有清单记录的产物已消失；可用 verify --fix 收敛'
    return 2
  }
  return 0
}

function Test-DoctorStateDir {
  <# _doctor_state_dir 的 Windows 对应物：目录存在即可（NTFS 无 700 模式位） #>
  if (-not (Test-Path -LiteralPath $script:StateDir)) { return 0 }
  Write-InfoLog ("状态目录：{0}" -f $script:StateDir)
  return 0
}

function Invoke-DoctorRun {
  <# doctor_run 的移植 #>
  $script:DOCTOR_OK = 0
  $script:DOCTOR_WARN = 0
  $script:DOCTOR_FAIL = 0

  Publish-Event -Type 'run_start' -Fragment '"verb":"doctor","dry_run":false,"phase":"doctor","ids":[]'

  Write-SectionLog 'doctor：环境体检'

  $null = Invoke-DoctorCheck -Name 'catalog'   -Hint '数据层是否可加载'   -Check { Test-DoctorCatalog }
  $null = Invoke-DoctorCheck -Name 'profiles'  -Hint '选择清单是否可用'   -Check { Test-DoctorProfiles }
  $null = Invoke-DoctorCheck -Name 'elevation' -Hint '提权能力'           -Check { Test-DoctorElevation }
  $null = Invoke-DoctorCheck -Name 'disk'      -Hint '磁盘剩余空间'       -Check { Test-DoctorDisk }
  $null = Invoke-DoctorCheck -Name 'commands'  -Hint '基础命令是否齐全'   -Check { Test-DoctorCommands }
  $null = Invoke-DoctorCheck -Name 'winget'    -Hint 'Windows 程序包管理器是否可用' -Check { Test-DoctorWinget }
  $null = Invoke-DoctorCheck -Name 'proxy'     -Hint '代理主机与连通性'   -Check { Test-DoctorProxy }
  $null = Invoke-DoctorCheck -Name 'manifest'  -Hint '状态清单与磁盘是否一致' -Check { Test-DoctorManifest }
  $null = Invoke-DoctorCheck -Name 'state'     -Hint '状态目录'           -Check { Test-DoctorStateDir }

  Write-SectionLog ("doctor 汇总：通过 {0} / 需关注 {1} / 未通过 {2}" -f $script:DOCTOR_OK, $script:DOCTOR_WARN, $script:DOCTOR_FAIL)

  if ($script:DOCTOR_FAIL -gt 0) {
    Write-ErrorLog '存在未通过项，请先处理后再执行 install'
  } elseif ($script:DOCTOR_WARN -gt 0) {
    Write-WarnLog '存在需关注项，不影响继续使用'
  }

  Publish-Event -Type 'run_end' -Fragment (
    '"verb":"doctor","phase":"doctor","ok":{0},"skipped":{1},"failed":{2},"rc":{3},"rolled_back":false' -f
    $script:DOCTOR_OK, $script:DOCTOR_WARN, $script:DOCTOR_FAIL,
    $(if ($script:DOCTOR_FAIL -gt 0) { 1 } else { 0 })
  )

  if ($script:DOCTOR_FAIL -gt 0) { return 1 }
  return 0
}
