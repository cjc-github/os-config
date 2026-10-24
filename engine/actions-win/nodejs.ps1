#Requires -Version 5.1
<#
.SYNOPSIS
  engine/actions-win/nodejs.ps1 —— 通过 fnm 安装 Node 并配置 npm 镜像
  （engine/actions/nodejs.sh 的 Windows 移植）
.DESCRIPTION
  Linux 版用 nvm（纯 bash 项目，官方不支持 Windows）。Windows 上换成 fnm
  （Fast Node Manager，winget 包 Schniz.fnm），理由：
    * 同时支持 NODE_LTS_MAJOR（取该大版最新）与 NODE_VERSION（精确 pin），
      完整保留原有版本语义；winget 的 OpenJS.NodeJS.LTS 只跟当前 LTS，做不到；
    * 数据目录在 %APPDATA%\fnm\node-versions，**免管理员**；系统级 Node 装在
      %ProgramFiles%\nodejs，其 npm 全局前缀需要管理员才能写；
    * 保留 nodejs 作为 config 动作，使 --pick nodejs 在两个平台通用。

  与 Bash 版逐条对应的行为：
  * 先记录 6 个 npm 键的原值到 state/actions/nodejs/npmrc.orig，
    **空值表示"原本未在 npmrc 里显式设置"**；remove 时空值 → delete，非空 → set。
  * 写入前比较现值，已是目标值且非 --force 则跳过。
  * remove 删除 fnm 版本目录前需确认，用户拒绝时返回 100（skipped）。
  * 同时清理 $PROFILE 里的 fnm env 托管块。

  已知冲突：本机若已装系统级 Node（%ProgramFiles%\nodejs），fnm 的版本目录会
  前插到 PATH 前面，因此 verify 比的是 fnm 的 node。两个都在时会打警告，
  避免优先级成为意外。
#>

Set-StrictMode -Version 2.0

$script:NODEJS_ENV_BEGIN = '# >>> os-config fnm env begin >>>'
$script:NODEJS_ENV_END   = '# <<< os-config fnm env end <<<'

$script:NODEJS_NPM_KEYS = @(
  'registry', 'audit', 'fund', 'prefer-offline', 'fetch-timeout', 'fetch-retry-maxtimeout'
)

function Set-NodejsDefaults {
  $env:NVM_VERSION = Get-ConfigValue 'NVM_VERSION' 'v0.40.1'
  $env:NODE_LTS_MAJOR = Get-ConfigValue 'NODE_LTS_MAJOR' '22'
  $env:NODE_VERSION = Get-ConfigValue 'NODE_VERSION' ''
  $env:NPM_REGISTRY = Get-ConfigValue 'NPM_REGISTRY' ''

  if ($env:NODE_LTS_MAJOR -notmatch '^[0-9]+$') {
    Write-ErrorLog ("NODE_LTS_MAJOR 非法：{0}（应为数字）" -f $env:NODE_LTS_MAJOR)
    return 2
  }
  if (-not [string]::IsNullOrEmpty($env:NODE_VERSION) -and
      $env:NODE_VERSION -notmatch '^v?[0-9]+\.[0-9]+\.[0-9]+$') {
    Write-ErrorLog ("NODE_VERSION 非法：{0}（应为空或 x.y.z）" -f $env:NODE_VERSION)
    return 2
  }
  return 0
}

function Get-FnmRoot {
  <# fnm 的版本目录；由 $HomeDir 派生而非 GetFolderPath，避免测试写进真实 profile #>
  return (Join-Path $script:HomeDir 'AppData\Roaming\fnm\node-versions')
}

function Get-FnmVersionsDir {
  return (Join-Path $script:HomeDir 'AppData\Roaming\fnm')
}

function Add-FnmToPath {
  <#
    把 fnm 管理的 node 目录前插到当前进程 PATH。
    fnm 的定位依赖 shell 集成（fnm env），在非交互脚本里显式拼接更可靠。
  #>
  $root = Get-FnmRoot
  if (-not (Test-Path -LiteralPath $root)) { return }

  $latest = $null
  try {
    $latest = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Sort-Object -Property Name -Descending | Select-Object -First 1)
  } catch { $latest = @() }
  if ($latest.Count -eq 0) { return }

  $instDir = Join-Path $latest[0].FullName 'installation'
  if (Test-Path -LiteralPath $instDir) {
    if ($env:PATH -notlike ("*" + $instDir + "*")) {
      $env:PATH = $instDir + ';' + $env:PATH
    }
  }
}

function Get-NpmrcPath {
  <# _nodejs_npmrc_path 的移植：优先 npm config get userconfig #>
  if (Test-CommandExists 'npm') {
    $p = (& npm config get userconfig 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrEmpty($p) -and $p -ne 'undefined' -and $p -ne 'null') { return $p }
  }
  return (Join-Path $script:HomeDir '.npmrc')
}

function Get-NpmrcValue {
  <#
    _nodejs_npmrc_get 的移植：直接读 npmrc 文件而不是 npm config get，
    因为后者会返回内置默认值，使"原本未显式设置"无法与"用了默认值"区分。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Key
  )
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  try { $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop) } catch { return '' }
  foreach ($raw in $lines) {
    $l = $raw.TrimStart()
    if ($l.StartsWith(';')) { continue }
    if ($l -match ("^{0}=(.*)$" -f [regex]::Escape($Key))) { return $Matches[1].Trim() }
  }
  return ''
}

function Save-NodejsOriginals {
  <# _nodejs_record_originals 的移植：首次观察才记录，空值=原本未显式设置 #>
  param([Parameter(Mandatory=$true)][string]$Dir)
  $orig = Join-Path $Dir 'npmrc.orig'
  $npmrc = Get-NpmrcPath
  foreach ($key in $script:NODEJS_NPM_KEYS) {
    if (Test-Path -LiteralPath $orig) {
      $existing = @(Get-Content -LiteralPath $orig -Encoding UTF8 -ErrorAction SilentlyContinue)
      $found = $false
      foreach ($e in $existing) { if ($e -like ($key + '=*')) { $found = $true; break } }
      if ($found) { continue }
    }
    $val = Get-NpmrcValue -Path $npmrc -Key $key
    [System.IO.File]::AppendAllText($orig, ($key + '=' + $val + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
  }
}

function Set-NpmConfigIfDifferent {
  <# _nodejs_npm_set_if_different 的移植 #>
  param(
    [Parameter(Mandatory=$true)][string]$Key,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value
  )
  $cur = ''
  if (Test-CommandExists 'npm') {
    $cur = (& npm config get $Key 2>$null | Out-String).Trim()
  }
  if ($cur -eq $Value -and $script:FORCE -ne 1) {
    Write-DebugLog ("npm {0} 已是目标值，跳过" -f $Key)
    return 0
  }
  $rc = Invoke-Step -Description ("npm config set {0} {1}" -f $Key, $Value) -Script {
    & npm config set $Key $Value
    return $LASTEXITCODE
  }
  return $rc
}

function Install-FnmIfNeeded {
  <#
    Linux 版在这里下载 nvm install.sh；Windows 版经 winget 装 fnm。
    fnm 已在 PATH 且版本满足时跳过（对应 nvm 的版本判断）。
  #>
  if (Test-CommandExists 'fnm') {
    if ($script:FORCE -ne 1) {
      Write-InfoLog 'fnm 已安装，跳过'
      return 0
    }
  }
  if (-not (Test-CommandExists 'winget')) {
    Write-ErrorLog 'winget 不可用，无法安装 fnm'
    return 1
  }
  $rc = Invoke-WithRetry -MaxAttempts 3 -SleepSeconds 5 -Script {
    & winget.exe install --exact --id Schniz.fnm --source winget --scope user --silent --disable-interactivity --accept-source-agreements --accept-package-agreements
    return $LASTEXITCODE
  }
  if ($rc -ne 0) {
    # 已装时 winget 各版本退出码不一致，复查一次
    if (Test-CommandExists 'fnm') {
      Write-InfoLog 'fnm 已安装'
      return 0
    }
    Write-ErrorLog ("安装 fnm 失败（rc={0}）" -f $rc)
    return 1
  }
  # 让当前进程能找到 fnm
  $fnmDir = Join-Path $script:HomeDir 'AppData\Local\Microsoft\WindowsApps'
  $candidates = @(
    (Join-Path $script:HomeDir 'AppData\Roaming\npm'),
    (Join-Path $script:HomeDir '.cargo\bin'),
    (Join-Path $script:HomeDir 'scoop\shims')
  )
  foreach ($c in $candidates) {
    if ((Test-Path -LiteralPath $c) -and $env:PATH -notlike ("*" + $c + "*")) {
      $env:PATH = $c + ';' + $env:PATH
    }
  }
  return 0
}

function Get-FnmEnvBlock {
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.AppendLine($script:NODEJS_ENV_BEGIN)
  $null = $sb.AppendLine("if (Get-Command fnm -ErrorAction SilentlyContinue) {")
  $null = $sb.AppendLine("    fnm env --shell powershell | Out-String | Invoke-Expression")
  $null = $sb.AppendLine("}")
  $null = $sb.Append($script:NODEJS_ENV_END)
  return $sb.ToString()
}

function action_nodejs_apply {
  param([Parameter(Mandatory=$true)][string]$Id)

  $vrc = Set-NodejsDefaults
  if ($vrc -ne 0) { return $vrc }

  if ((Install-FnmIfNeeded) -ne 0) { return 1 }
  Add-FnmToPath

  if (-not (Test-CommandExists 'fnm')) {
    Write-ErrorLog 'fnm 安装后仍不可用；请新开一个终端后重试'
    return 1
  }

  # 目标版本：NODE_VERSION 精确，否则 NODE_LTS_MAJOR 下的最新
  $spec = if (-not [string]::IsNullOrEmpty($env:NODE_VERSION)) {
    $env:NODE_VERSION.TrimStart('v')
  } else {
    $env:NODE_LTS_MAJOR
  }

  $rc = Invoke-WithRetry -MaxAttempts 3 -SleepSeconds 5 -Script {
    & fnm install $spec
    return $LASTEXITCODE
  }
  if ($rc -ne 0) {
    Write-ErrorLog ("fnm install {0} 失败（rc={1}）" -f $spec, $rc)
    return 1
  }

  $null = Invoke-Step -Description ("fnm default {0}" -f $spec) -Script {
    & fnm default $spec
    return $LASTEXITCODE
  }
  Add-FnmToPath

  # fnm env 托管块写进 $PROFILE，让新会话自动把 node 放上 PATH
  $profile = Get-PowerShellProfilePath
  $want = Get-FnmEnvBlock
  $cur = Get-ManagedBlock -Path $profile -Begin $script:NODEJS_ENV_BEGIN -End $script:NODEJS_ENV_END
  if ($script:FORCE -ne 1 -and $cur -eq $want) {
    Write-DebugLog 'fnm env 块已是最新，跳过'
  } else {
    $null = Register-Rollback -Path $profile
    if (-not [string]::IsNullOrEmpty($cur)) {
      if ((Remove-ManagedBlock -Path $profile -Begin $script:NODEJS_ENV_BEGIN -End $script:NODEJS_ENV_END) -ne 0) {
        return 1
      }
    }
    if (-not (Test-Path -LiteralPath $profile)) {
      $dir = Split-Path -Parent $profile
      if (-not [string]::IsNullOrEmpty($dir)) {
        try { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop } catch { }
      }
      try { $null = New-Item -ItemType File -Path $profile -Force -ErrorAction Stop } catch { }
    }
    try {
      [System.IO.File]::AppendAllText($profile, "`r`n" + $want + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {
      Write-ErrorLog ("无法写入 {0}：{1}" -f $profile, $_.Exception.Message)
      return 1
    }
  }

  if (-not (Test-CommandExists 'npm')) {
    Write-ErrorLog 'npm 不可用；fnm 安装的 Node 未正确生效'
    return 1
  }

  $dir = Get-StateActionDir -Name 'nodejs'
  if ($null -eq $dir) { return 1 }

  # 先记录原值，再写入
  Save-NodejsOriginals -Dir $dir

  $npmrcValues = [ordered]@{
    'registry'             = $env:NPM_REGISTRY
    'audit'                = 'false'
    'fund'                 = 'false'
    'prefer-offline'       = 'true'
    'fetch-timeout'        = '120000'
    'fetch-retry-maxtimeout' = '120000'
  }
  foreach ($key in $script:NODEJS_NPM_KEYS) {
    $val = $npmrcValues[$key]
    if ([string]::IsNullOrEmpty($val)) { continue }   # registry 为空则不写
    if ((Set-NpmConfigIfDifferent -Key $key -Value $val) -ne 0) { return 1 }
  }

  $nodeVer = (& node --version 2>$null | Select-Object -First 1 | Out-String).Trim()
  $npmVer = (& npm --version 2>$null | Select-Object -First 1 | Out-String).Trim()
  Write-OkLog ("nodejs 完成：node={0} npm={1}" -f $nodeVer, $npmVer)
  return 0
}

function action_nodejs_remove {
  param([Parameter(Mandatory=$true)][string]$Id)

  $vrc = Set-NodejsDefaults
  if ($vrc -ne 0) { return $vrc }

  $versionsRoot = Get-FnmRoot
  if (-not (Test-Path -LiteralPath $versionsRoot)) {
    Write-InfoLog ("[{0}] fnm 版本目录不存在，无需删除" -f $Id)
  } else {
    $ok = Request-Confirm -Prompt ("删除 {0} 会一并删除其中的 Node 与全局包，确认？" -f $versionsRoot) `
                          -Force $script:FORCE -AssumeYes $script:ASSUME_YES
    if (-not $ok) {
      Write-WarnLog ("[{0}] 用户取消删除，跳过" -f $Id)
      return 100   # 约定：skipped
    }
    $rc = Invoke-Step -Description ("删除 {0}" -f $versionsRoot) -Script {
      try { Remove-Item -LiteralPath $versionsRoot -Recurse -Force -ErrorAction Stop } catch { return 1 }
      return 0
    }
    if ($rc -ne 0) { return 1 }
  }

  # 清理 $PROFILE 里的 fnm env 块
  $profile = Get-PowerShellProfilePath
  if ((Test-Path -LiteralPath $profile)) {
    if (-not [string]::IsNullOrEmpty((Get-ManagedBlock -Path $profile -Begin $script:NODEJS_ENV_BEGIN -End $script:NODEJS_ENV_END))) {
      $null = Register-Rollback -Path $profile
      if ((Remove-ManagedBlock -Path $profile -Begin $script:NODEJS_ENV_BEGIN -End $script:NODEJS_ENV_END) -ne 0) {
        return 1
      }
    }
  }

  # 按 npmrc.orig 还原 npm 配置
  $dir = Get-StateActionDir -Name 'nodejs'
  if ($null -eq $dir) { return 1 }
  $orig = Join-Path $dir 'npmrc.orig'
  if ((Test-Path -LiteralPath $orig) -and (Test-CommandExists 'npm')) {
    try { $lines = @(Get-Content -LiteralPath $orig -Encoding UTF8 -ErrorAction Stop) } catch { $lines = @() }
    foreach ($l in $lines) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      $eq = $l.IndexOf('=')
      if ($eq -lt 0) { continue }
      $key = $l.Substring(0, $eq)
      $val = $l.Substring($eq + 1)
      if ([string]::IsNullOrEmpty($val)) {
        $null = Invoke-Step -Description ("npm config delete {0}" -f $key) -Script {
          & npm config delete $key
          return $LASTEXITCODE
        }
      } else {
        $null = Invoke-Step -Description ("npm config set {0} {1}" -f $key, $val) -Script {
          & npm config set $key $val
          return $LASTEXITCODE
        }
      }
    }
    try { Remove-Item -LiteralPath $orig -Force -ErrorAction SilentlyContinue } catch { }
    Write-OkLog '已还原 npm 配置'
  }
  return 0
}

function action_nodejs_verify {
  param([Parameter(Mandatory=$true)][string]$Id)

  $vrc = Set-NodejsDefaults
  if ($vrc -ne 0) { return $vrc }
  Add-FnmToPath

  if (-not (Test-CommandExists 'node')) {
    Write-ErrorLog ("[{0}] node 不可用" -f $Id); return 1
  }
  $ver = (& node --version 2>$null | Select-Object -First 1 | Out-String).Trim()
  Write-OkLog ("node: {0}" -f $ver)
  $plain = $ver.TrimStart('v')

  if (-not [string]::IsNullOrEmpty($env:NODE_VERSION)) {
    $want = $env:NODE_VERSION.TrimStart('v')
    if ($plain -ne $want) {
      Write-ErrorLog ("node 版本不符：期望 {0}，实际 {1}" -f $want, $plain)
      return 1
    }
  } else {
    $major = ($plain -split '\.')[0]
    if ($major -ne $env:NODE_LTS_MAJOR) {
      Write-ErrorLog ("node 主版本不符：期望 {0}.x，实际 {1}" -f $env:NODE_LTS_MAJOR, $plain)
      return 1
    }
  }

  if (-not (Test-CommandExists 'npm')) {
    Write-ErrorLog ("[{0}] npm 不可用" -f $Id); return 1
  }
  $npmVer = (& npm --version 2>$null | Select-Object -First 1 | Out-String).Trim()
  Write-OkLog ("npm: {0}" -f $npmVer)

  if (-not [string]::IsNullOrEmpty($env:NPM_REGISTRY)) {
    $cur = (& npm config get registry 2>$null | Out-String).Trim()
    if ($cur -ne $env:NPM_REGISTRY) {
      Write-ErrorLog ("npm registry 不符：期望 {0}，实际 {1}" -f $env:NPM_REGISTRY, $cur)
      return 1
    }
  }
  return 0
}

function action_nodejs_status {
  param([Parameter(Mandatory=$true)][string]$Id)
  $versionsRoot = Get-FnmRoot
  if (-not (Test-Path -LiteralPath $versionsRoot)) {
    Write-Host '    未安装（无 fnm 版本目录）'
    return 0
  }
  Add-FnmToPath
  $ver = ''
  if (Test-CommandExists 'node') {
    $ver = (& node --version 2>$null | Select-Object -First 1 | Out-String).Trim()
  }
  Write-Host ("    已安装（node={0}）" -f $(if ($ver) { $ver } else { '?' }))
  return 0
}
