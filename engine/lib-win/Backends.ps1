#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Backends.ps1 —— 包管理器后端适配器（engine/lib/backends.sh 的移植）
.DESCRIPTION
  实现 winget 与 npm 两个后端的五个动词。每个后端提供
  Invoke-<Backend>Backend<Verb>，由 Backend-Dispatch 调用；后端只读 CAT_* 数据，
  不认识任何具体工具名。

  winget CLI 事实（本机 v1.29 实测，写代码前已验证）：

  * 是否已装：`winget list --id <id>` 退出码 0=已装、20=未装。比解析表格可靠。
  * 没有 JSON 输出（1.29 不接受 --output），必须解析表格。
  * 表格有**两种布局**：全量 `winget list` 是 2+ 空格填充的定宽列；
    `winget list --id X` 是单空格分隔的窄表且多一列"源"。
    因此解析规则是"按空白切分后定位等于 id 的那个字段，取下一个字段为版本"，
    两种布局下都成立，且不依赖中文本地化表头。
  * 非交互安装需 --silent --disable-interactivity
    --accept-package-agreements --accept-source-agreements。
  * -e/--exact 精确匹配；-v/--version 锁版本；--no-upgrade 已装则跳过；
    --scope user|machine 选择安装范围；--force 绕过安全检查。

  性能关键：winget 单次调用数秒级，42 个条目逐个查会慢到不可用。
  因此全量查一次建立索引（Update-WingetIndex），之后所有查询走内存。
#>

Set-StrictMode -Version 2.0

$script:WingetIndex = $null
$script:WingetScope = 'user'

# ---------------------------------------------------------------------------
# winget 索引
# ---------------------------------------------------------------------------
function Update-WingetIndex {
  <#
    一次 bulk 调用建立 id -> 版本列表。
    一个 id 可能对应多行（实测 Thunder.Xmp 出现两次），因此值是数组。
    解析规则见文件头：定位等于 id 的字段，取其下一个字段为版本。
  #>
  $idx = @{}
  $out = & winget.exe list --source winget --disable-interactivity --accept-source-agreements 2>&1
  foreach ($raw in $out) {
    if ($null -eq $raw) { continue }
    $line = $raw.ToString().Trim()
    if ($line -eq '') { continue }
    # 跳过分隔线（全是 - 或 =）
    if ($line -match '^[-=\s]+$') { continue }
    $tokens = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -lt 2) { continue }

    # 找最后一个等于已知 id 形态的字段：winget 包 id 形如 Publisher.Product
    $idIdx = -1
    for ($i = 0; $i -lt $tokens.Count; $i++) {
      if ($tokens[$i] -match '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$') { $idIdx = $i }
    }
    if ($idIdx -lt 0 -or $idIdx + 1 -ge $tokens.Count) { continue }
    $id = $tokens[$idIdx].ToLowerInvariant()
    if ($id -eq 'id') { continue }
    $ver = $tokens[$idIdx + 1]
    if (-not (Test-DictHasKey -Dictionary $idx -Key $id)) { $idx[$id] = New-Object System.Collections.ArrayList }
    $null = $idx[$id].Add($ver)
  }
  $script:WingetIndex = $idx
}

function Get-WingetVersion {
  <#
    取已安装版本（多版本时取最大者）。未安装返回 $null。
    精确版本场景（track=pin）走单包查询，避免批量索引的解析误差。
  #>
  param([Parameter(Mandatory=$true)][string]$PackageId)
  $id = $PackageId.ToLowerInvariant()

  $out = & winget.exe list --id $PackageId --exact --source winget --disable-interactivity --accept-source-agreements 2>&1
  $rc = $LASTEXITCODE
  if ($rc -ne 0) { return $null }

  foreach ($raw in $out) {
    if ($null -eq $raw) { continue }
    $line = $raw.ToString().Trim()
    if ($line -eq '' -or $line -match '^[-=\s]+$') { continue }
    $tokens = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -lt 2) { continue }
    $idIdx = -1
    for ($i = 0; $i -lt $tokens.Count; $i++) {
      if ($tokens[$i].ToLowerInvariant() -eq $id) { $idIdx = $i }
    }
    if ($idIdx -lt 0 -or $idIdx + 1 -ge $tokens.Count) { continue }
    $ver = $tokens[$idIdx + 1]
    # 版本字段不该含空格；若下一个字段不像版本号（例如 "winget"），说明定位失败
    if ($ver -match '^\d') { return $ver }
  }
  return $null
}

function Test-WingetInstalled {
  param([Parameter(Mandatory=$true)][string]$PackageId)
  $v = Get-WingetVersion -PackageId $PackageId
  return ($null -ne $v)
}

function Test-WingetPinSatisfied {
  param(
    [Parameter(Mandatory=$true)][string]$PackageId,
    [Parameter(Mandatory=$true)][string]$Version
  )
  $v = Get-WingetVersion -PackageId $PackageId
  if ($null -eq $v) { return $false }
  return ($v -eq $Version)
}

# ---------------------------------------------------------------------------
# 通用辅助
# ---------------------------------------------------------------------------
function Test-CommandsAvailable {
  <# commands_verify 的移植：CAT_COMMANDS 里的命令是否都可用 #>
  param([Parameter(Mandatory=$true)][string]$Id)
  $cmds = (Get-CatalogEffective -Id $Id -Field 'Commands')
  $rc = 0
  foreach ($c in (($cmds -split '\s+') | Where-Object { $_ -ne '' })) {
    if (Test-CommandExists -Name $c) {
      Write-DebugLog ("[{0}] 命令可用：{1}" -f $Id, $c)
    } else {
      Write-ErrorLog ("[{0}] 命令不可用：{1}" -f $Id, $c)
      $rc = 1
    }
  }
  return $rc
}

function Get-Semver {
  <# semver_of 的移植：抽取第一个 x.y.z #>
  param([AllowEmptyString()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $m = [regex]::Match($Text, '[0-9]+\.[0-9]+\.[0-9]+')
  if ($m.Success) { return $m.Value }
  return ''
}

function Resolve-CommandBin {
  <# resolve_command_path 的移植：解析可执行文件路径（含 npm prefix/bin 兜底） #>
  param(
    [Parameter(Mandatory=$true)][string]$Command,
    [string]$FallbackDir = ''
  )
  # 与 Test-CommandExists 同理限定 CommandType：别名（curl→Invoke-WebRequest）
  # 的 .Source 是空串，原样返回会让调用方拿到 '' 而不是 $null，随后
  # `& $bin` 变成调用 PowerShell 自己的 cmdlet，语义完全错掉。
  $cmd = Get-Command -Name $Command -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
         Select-Object -First 1
  if ($cmd -and -not [string]::IsNullOrEmpty($cmd.Source)) { return $cmd.Source }
  if ($FallbackDir) {
    foreach ($ext in @('.exe', '.cmd', '.bat', '.ps1', '')) {
      $p = Join-Path $FallbackDir ($Command + $ext)
      if (Test-Path -LiteralPath $p) { return $p }
    }
  }
  return $null
}

function Get-NpmPrefixBin {
  $prefix = ''
  if (Test-CommandExists 'npm') {
    $prefix = (& npm config get prefix 2>$null | Out-String).Trim()
  }
  if ([string]::IsNullOrEmpty($prefix)) { return '' }
  return (Join-Path $prefix 'bin')
}

# ---------------------------------------------------------------------------
# winget 后端
# ---------------------------------------------------------------------------
function Invoke-WingetInstallImpl {
  <#
    _apt_install_impl 的结构对应物。
    only_missing=1：已装即跳过（install）；=0：已装也执行以升级（update）。
    track=pin 时已装但版本不符视为未满足。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][int]$OnlyMissing
  )

  $packages = (Get-CatalogEffective -Id $Id -Field 'Packages')
  $version = (Get-CatalogEffective -Id $Id -Field 'Version')
  $track = $script:CAT_TRACK[$Id]
  $pin = ($track -eq 'pin' -and -not [string]::IsNullOrEmpty($version))

  $targets = New-Object System.Collections.Generic.List[string]
  foreach ($pkg in (($packages -split '\s+') | Where-Object { $_ -ne '' })) {
    if ($OnlyMissing -eq 1) {
      if ($pin) {
        if (Test-WingetPinSatisfied -PackageId $pkg -Version $version) { continue }
      } else {
        if (Test-WingetInstalled -PackageId $pkg) { continue }
      }
    }
    $targets.Add($pkg)
  }

  if ($targets.Count -eq 0) {
    Write-InfoLog ("[{0}] winget 包已安装：{1}" -f $Id, $packages)
    return 0
  }

  foreach ($pkg in $targets) {
    # 变量名必须是普通名字（不能叫 $args）：$args 是 PowerShell 的自动变量，
    # 在函数里赋值虽然生效，但**脚本块里的 $args 会重新绑定到脚本块自己的
    # 未绑定参数**——下面 Invoke-Step 的 -Script { & winget.exe @args } 拿到
    # 的是空集合，winget.exe 实际以零参数运行：它打印帮助并**退出 0**，
    # 于是每次 install/update 都"静默成功"而什么都没装。
    $wingetArgs = New-Object System.Collections.Generic.List[string]
    $wingetArgs.Add('install')
    $wingetArgs.Add('--exact')
    $wingetArgs.Add('--id')
    $wingetArgs.Add($pkg)
    $wingetArgs.Add('--source')
    $wingetArgs.Add('winget')
    $wingetArgs.Add('--silent')
    $wingetArgs.Add('--disable-interactivity')
    $wingetArgs.Add('--accept-source-agreements')
    $wingetArgs.Add('--accept-package-agreements')
    $wingetArgs.Add('--scope')
    $wingetArgs.Add($script:WingetScope)
    if ($pin) { $wingetArgs.Add('--version'); $wingetArgs.Add($version) }
    if ($OnlyMissing -eq 1) { $wingetArgs.Add('--no-upgrade') }
    if ($script:FORCE -eq 1) { $wingetArgs.Add('--force') }

    $desc = ("winget install {0}" -f $pkg)
    if ($pin) { $desc += ("={0}" -f $version) }
    $rc = Invoke-Step -Description $desc -Script {
      & winget.exe @wingetArgs
    }

    if ($rc -ne 0) {
      # winget 各版本对"已安装"的退出码不一致：重新查一次，确实装上了就算成功
      $nowVer = Get-WingetVersion -PackageId $pkg
      if ($null -ne $nowVer -and (-not $pin -or $nowVer -eq $version)) {
        Write-InfoLog ("[{0}] {1} 已安装（版本 {2}）" -f $Id, $pkg, $nowVer)
        continue
      }
      # user 域装不上时，提权重试 machine 域
      if ($script:WingetScope -eq 'user') {
        Write-WarnLog ("[{0}] user 域安装 {1} 失败（rc={2}），尝试 machine 域" -f $Id, $pkg, $rc)
        if ((Request-Elevation) -ne 0) {
          Write-ErrorLog ("[{0}] 无法提权安装 {1}" -f $Id, $pkg)
          return 1
        }
        $script:WingetScope = 'machine'
        # 替换 --scope 的**值**（它后面的那个元素），不能顺手改最后一个元素：
        # --version / --no-upgrade / --force 都排在 --scope 之后，改末位会把
        # 它们冲掉，拼出 `--force machine` 这种畸形命令行。
        $scopeIdx = $wingetArgs.IndexOf('--scope')
        if ($scopeIdx -ge 0 -and $scopeIdx + 1 -lt $wingetArgs.Count) {
          $wingetArgs[$scopeIdx + 1] = 'machine'
        } else {
          $wingetArgs.Add('--scope'); $wingetArgs.Add('machine')
        }
        $rc = Invoke-WithRetry -MaxAttempts 3 -SleepSeconds 5 -Script {
          & winget.exe @wingetArgs
        }
        $script:WingetScope = 'user'
        if ($rc -ne 0) {
          $nowVer = Get-WingetVersion -PackageId $pkg
          if ($null -ne $nowVer -and (-not $pin -or $nowVer -eq $version)) {
            Write-InfoLog ("[{0}] {1} 已安装（版本 {2}）" -f $Id, $pkg, $nowVer)
            continue
          }
          Write-ErrorLog ("[{0}] winget 安装 {1} 失败（rc={2}）" -f $Id, $pkg, $rc)
          return 1
        }
      } else {
        Write-ErrorLog ("[{0}] winget 安装 {1} 失败（rc={2}）" -f $Id, $pkg, $rc)
        return 1
      }
    }
  }

  Update-WingetIndex
  return 0
}

function Invoke-WingetBackendInstall { param([string]$Id) return (Invoke-WingetInstallImpl -Id $Id -OnlyMissing 1) }
function Invoke-WingetBackendUpdate  { param([string]$Id) return (Invoke-WingetInstallImpl -Id $Id -OnlyMissing 0) }

function Test-WingetBackendInstalled {
  <# _backend_winget_is_installed：供 export 与外部依赖扫描使用 #>
  param([string]$Id)
  $packages = (Get-CatalogEffective -Id $Id -Field 'Packages')
  foreach ($pkg in (($packages -split '\s+') | Where-Object { $_ -ne '' })) {
    if (Test-WingetInstalled -PackageId $pkg) { return $true }
  }
  return $false
}

function Invoke-WingetBackendVerify {
  param([string]$Id)
  $packages = (Get-CatalogEffective -Id $Id -Field 'Packages')
  $version = (Get-CatalogEffective -Id $Id -Field 'Version')
  $track = $script:CAT_TRACK[$Id]
  $rc = 0
  foreach ($pkg in (($packages -split '\s+') | Where-Object { $_ -ne '' })) {
    $v = Get-WingetVersion -PackageId $pkg
    if ($null -eq $v) {
      Write-ErrorLog ("[{0}] 未安装：{1}" -f $Id, $pkg)
      $rc = 1
      continue
    }
    if ($track -eq 'pin' -and -not [string]::IsNullOrEmpty($version)) {
      if ($v -eq $version) {
        Write-DebugLog ("[{0}] 已安装且版本匹配：{1}={2}" -f $Id, $pkg, $version)
      } else {
        Write-ErrorLog ("[{0}] 版本不符：{1} 期望 {2}，实际 {3}" -f $Id, $pkg, $version, $v)
        $rc = 1
      }
    } else {
      Write-DebugLog ("[{0}] 已安装：{1}={2}" -f $Id, $pkg, $v)
    }
  }
  if ($rc -ne 0) { return 1 }
  return (Test-CommandsAvailable -Id $Id)
}

function Invoke-WingetBackendRemove {
  param([string]$Id)
  $packages = (Get-CatalogEffective -Id $Id -Field 'Packages')
  # blocking pin 会拒绝卸载，先解除
  foreach ($pkg in (($packages -split '\s+') | Where-Object { $_ -ne '' })) {
    & winget.exe pin remove --id $pkg --exact --source winget --disable-interactivity --accept-source-agreements 2>&1 | Out-Null
  }
  $rc = 0
  foreach ($pkg in (($packages -split '\s+') | Where-Object { $_ -ne '' })) {
    $r = Invoke-Step -Description ("winget uninstall {0}" -f $pkg) -Script {
      & winget.exe uninstall --exact --id $pkg --source winget --silent --disable-interactivity --accept-source-agreements
      return $LASTEXITCODE
    }
    if ($r -ne 0) {
      Write-ErrorLog ("[{0}] winget 卸载 {1} 失败（rc={2}）" -f $Id, $pkg, $r)
      $rc = 1
    }
  }
  Update-WingetIndex
  return $rc
}

function Invoke-WingetBackendStatus {
  param([string]$Id)
  $packages = (Get-CatalogEffective -Id $Id -Field 'Packages')
  foreach ($pkg in (($packages -split '\s+') | Where-Object { $_ -ne '' })) {
    $v = Get-WingetVersion -PackageId $pkg
    if ($null -ne $v) {
      Write-Host ("    {0,-22} {1}" -f $pkg, ("已安装 " + $v))
    } else {
      Write-Host ("    {0,-22} {1}" -f $pkg, '未安装')
    }
  }
  return 0
}

# ---------------------------------------------------------------------------
# builtin 后端：系统自带，无需安装
# ---------------------------------------------------------------------------
function Invoke-BuiltinBackendInstall {
  param([string]$Id)
  Write-InfoLog ("[{0}] 系统自带，无需安装" -f $Id)
  return 0
}
function Invoke-BuiltinBackendUpdate {
  param([string]$Id)
  Write-InfoLog ("[{0}] 系统自带，无需更新" -f $Id)
  return 0
}
function Invoke-BuiltinBackendRemove {
  param([string]$Id)
  # 系统组件没有可还原的先前状态，0 是如实回答
  Write-InfoLog ("[{0}] 系统自带，无法由本工具卸载" -f $Id)
  return 0
}
function Invoke-BuiltinBackendVerify {
  param([string]$Id)
  return (Test-CommandsAvailable -Id $Id)
}
function Invoke-BuiltinBackendStatus {
  param([string]$Id)
  $cmds = (Get-CatalogEffective -Id $Id -Field 'Commands')
  $any = $false
  foreach ($c in (($cmds -split '\s+') | Where-Object { $_ -ne '' })) {
    $any = $true
    if (Test-CommandExists -Name $c) { Write-Host ("    {0,-22} {1}" -f $c, '可用') }
    else { Write-Host ("    {0,-22} {1}" -f $c, '不可用') }
  }
  if (-not $any) { Write-Host ("    {0,-22} {1}" -f '(无命令)', '系统自带') }
  return 0
}
function Test-BuiltinBackendInstalled {
  param([string]$Id)
  $cmds = (Get-CatalogEffective -Id $Id -Field 'Commands')
  $tokens = @(($cmds -split '\s+') | Where-Object { $_ -ne '' })
  if ($tokens.Count -eq 0) { return $true }
  foreach ($c in $tokens) { if (-not (Test-CommandExists -Name $c)) { return $false } }
  return $true
}

# ---------------------------------------------------------------------------
# npm 后端
# ---------------------------------------------------------------------------
function Get-NpmToolState {
  <# _npm_tool_state 的移植 #>
  param([string]$Id)
  $want = (Get-CatalogEffective -Id $Id -Field 'Version')
  $cmds = (Get-CatalogEffective -Id $Id -Field 'Commands')
  foreach ($c in (($cmds -split '\s+') | Where-Object { $_ -ne '' })) {
    if (-not (Test-CommandExists -Name $c)) {
      Write-DebugLog ("[{0}] 命令缺失：{1}" -f $Id, $c); return $false
    }
  }
  if ($script:CAT_TRACK[$Id] -eq 'pin' -and -not [string]::IsNullOrEmpty($want)) {
    $tokens = @(($cmds -split '\s+') | Where-Object { $_ -ne '' })
    if ($tokens.Count -eq 0) { return $false }
    $bin = Resolve-CommandBin -Command $tokens[0] -FallbackDir (Get-NpmPrefixBin)
    if (-not $bin) { return $false }
    $vout = (& $bin --version 2>$null | Select-Object -First 1 | Out-String).Trim()
    $v = Get-Semver -Text $vout
    if ($v -ne $want) {
      Write-DebugLog ("[{0}] 版本不匹配：{1} != {2}" -f $Id, $v, $want); return $false
    }
  }
  return $true
}

function Test-NpmSelfcheck {
  <#
    _npm_selfcheck 的移植：npm 退出码 0 不等于命令可用，
    必须真的能执行且有版本输出。
  #>
  param([string]$Id)
  $prefixBin = Get-NpmPrefixBin
  $cmds = (Get-CatalogEffective -Id $Id -Field 'Commands')
  foreach ($c in (($cmds -split '\s+') | Where-Object { $_ -ne '' })) {
    $bin = Resolve-CommandBin -Command $c -FallbackDir $prefixBin
    if (-not $bin) {
      Write-ErrorLog ("[{0}] 安装后命令仍不可用：{1}（prefix/bin={2}，请检查 PATH）" -f $Id, $c, $prefixBin)
      return $false
    }
    $out = (& $bin --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    if ([string]::IsNullOrEmpty($out)) {
      Write-ErrorLog ("[{0}] {1} --version 无输出，安装可能不完整（postinstall 失败？）" -f $Id, $c)
      return $false
    }
    Write-DebugLog ("[{0}] 自检 {1} -> {2}" -f $Id, $c, $out)
  }
  return $true
}

function Install-NpmGlobalFixed {
  <# npm_install_global_fixed 的移植 #>
  param(
    [Parameter(Mandatory=$true)][string]$Package,
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$Registry = ''
  )
  if (-not (Test-CommandExists 'npm')) {
    Write-ErrorLog 'npm 不可用；请先安装其依赖 nodejs'
    return 1
  }
  $spec = if ($Version -eq 'latest' -or [string]::IsNullOrEmpty($Version)) { $Package } else { ($Package + '@' + $Version) }
  $cmd = New-Object System.Collections.Generic.List[string]
  $cmd.Add('install')
  $cmd.Add('-g')
  if (-not [string]::IsNullOrEmpty($Registry)) { $cmd.Add('--registry'); $cmd.Add($Registry) }
  $cmd.Add($spec)

  $rc = Invoke-WithRetry -MaxAttempts 1 -SleepSeconds 0 -Script {
    & npm @cmd
  }
  if ($rc -eq 0) { return 0 }

  # ENOTEMPTY：只清理 .<package>-* 隐藏 rename 残留并重试一次，不动正式包目录
  #
  # 与 Bash 版 npm_install_global_fixed 逐条对应：先正常安装**一次**（不套通用
  # 重试），失败且输出含 ENOTEMPTY 才走这里的清理 + 重试。曾经这里用
  # Invoke-WithRetry 包了三层通用重试：既与 Bash 语义不符，又让本分支永远走
  # 不到——重试耗尽后上面直接 return，残留目录没人清，而"重试后成功"还会
  # 掩盖残留问题。MaxAttempts 1 表示只跑一次，但仍走 Invoke-WithRetry 的
  # 输出捕获（LastStepOutput 是 ENOTEMPTY 的判断依据）。
  $out = $script:LastStepOutput
  if ($out -and $out.Contains('ENOTEMPTY')) {
    Write-WarnLog 'npm 报告 ENOTEMPTY，清理隐藏 rename 残留后重试一次'
    Clear-NpmEnotemptyResidue -Package $Package
    $rc = Invoke-WithRetry -MaxAttempts 1 -SleepSeconds 0 -Script {
      & npm @cmd
    }
  }
  return $rc
}

function Clear-NpmEnotemptyResidue {
  <# cleanup_npm_enotempty_residue 的移植 #>
  param([Parameter(Mandatory=$true)][string]$Package)
  $npmRoot = ''
  if (Test-CommandExists 'npm') {
    $npmRoot = (& npm root -g 2>$null | Out-String).Trim()
  }
  if ([string]::IsNullOrEmpty($npmRoot) -or -not (Test-Path -LiteralPath $npmRoot)) { return }
  $base = Split-Path -Leaf $Package
  Get-ChildItem -LiteralPath $npmRoot -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq ('.' + $base) -or $_.Name.StartsWith('.' + $base + '-') } |
    ForEach-Object {
      try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
      Write-DebugLog ("清理 npm 残留：{0}" -f $_.FullName)
    }
}

function Invoke-NpmInstallImpl {
  param(
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][int]$Force
  )
  if (-not (Test-CommandExists 'node') -or -not (Test-CommandExists 'npm')) {
    Write-ErrorLog ("[{0}] node/npm 不可用；请先安装其依赖 nodejs" -f $Id)
    return 1
  }
  $pkg = (Get-CatalogEffective -Id $Id -Field 'Packages')
  $ver = 'latest'
  if ($script:CAT_TRACK[$Id] -eq 'pin' -and -not [string]::IsNullOrEmpty((Get-CatalogEffective -Id $Id -Field 'Version'))) {
    $ver = (Get-CatalogEffective -Id $Id -Field 'Version')
  }
  if ($Force -eq 0 -and (Get-NpmToolState -Id $Id)) {
    Write-InfoLog ("[{0}] 已安装且版本匹配，跳过（--force 可重装）" -f $Id)
    return 0
  }
  $registry = Get-ConfigValue 'NPM_REGISTRY' ''
  $rc = Install-NpmGlobalFixed -Package $pkg -Version $ver -Registry $registry
  if ($rc -ne 0) { return $rc }
  if (-not (Test-NpmSelfcheck -Id $Id)) { return 1 }
  return 0
}

function Invoke-NpmBackendInstall { param([string]$Id) return (Invoke-NpmInstallImpl -Id $Id -Force 0) }
function Invoke-NpmBackendUpdate  { param([string]$Id) return (Invoke-NpmInstallImpl -Id $Id -Force 1) }

function Test-NpmBackendInstalled {
  param([string]$Id)
  return (Get-NpmToolState -Id $Id)
}

function Invoke-NpmBackendVerify {
  param([string]$Id)
  if (-not (Get-NpmToolState -Id $Id)) {
    Write-ErrorLog ("[{0}] npm 工具状态不符合预期" -f $Id); return 1
  }
  return (Test-CommandsAvailable -Id $Id)
}

function Invoke-NpmBackendRemove {
  param([string]$Id)
  $pkg = (Get-CatalogEffective -Id $Id -Field 'Packages')
  if (-not (Test-CommandExists 'npm')) {
    Write-ErrorLog ("[{0}] npm 不可用，无法卸载" -f $Id); return 1
  }
  $rc = Invoke-WithRetry -MaxAttempts 3 -SleepSeconds 5 -Script {
    & npm uninstall -g $pkg
    return $LASTEXITCODE
  }
  return $rc
}

function Invoke-NpmBackendStatus {
  param([string]$Id)
  $prefixBin = Get-NpmPrefixBin
  $cmds = (Get-CatalogEffective -Id $Id -Field 'Commands')
  foreach ($c in (($cmds -split '\s+') | Where-Object { $_ -ne '' })) {
    $bin = Resolve-CommandBin -Command $c -FallbackDir $prefixBin
    if ($bin) {
      $out = (& $bin --version 2>$null | Select-Object -First 1 | Out-String).Trim()
      Write-Host ("    {0,-22} {1}" -f $c, ("已安装 " + $(if ($out) { $out } else { '?' })))
    } else {
      Write-Host ("    {0,-22} {1}" -f $c, '未安装')
    }
  }
  return 0
}

# ---------------------------------------------------------------------------
# 分派
# ---------------------------------------------------------------------------
function Backend-Dispatch {
  <#
    backend_dispatch 的移植。
    返回后端函数的退出码；后端未实现该动词时返回 2。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Verb,
    [Parameter(Mandatory=$true)][string]$Id
  )
  $backend = (Get-CatalogEffective -Id $Id -Field 'Backend')
  $fnName = ('Invoke-{0}Backend{1}' -f $backend, (Get-Culture).TextInfo.ToTitleCase($Verb))
  if (-not (Get-Command -Name $fnName -ErrorAction SilentlyContinue)) {
    Write-ErrorLog ("[{0}] backend {1} 不支持动词 {2}" -f $Id, $backend, $Verb)
    return 2
  }
  $rc = & $fnName -Id $Id
  return $rc
}
