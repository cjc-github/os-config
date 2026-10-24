#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Util.ps1 —— 通用工具（engine/lib/util.sh 的移植）
.DESCRIPTION
  覆盖：配置加载、命令探测、run_step、with_retry、提权、代理推导与连通性、
  托管块读写。对应 util.sh 的同名函数，行为契约保持一致。

  PowerShell 特有约束（写代码前必读）：

  * 每个可能往输出流吐对象的 cmdlet 调用都要 $null = ... 或 | Out-Null，
    否则函数"返回"的会是那个对象而不是我们 return 的整数。
  * 原生程序（winget.exe / npm.cmd / curl.exe）的退出码只存在于 $LASTEXITCODE，
    必须紧跟在调用之后立即捕获，中间不能插入任何 cmdlet 调用。
  * PS 5.1 里 curl 是 Invoke-WebRequest 的别名，必须显式写 curl.exe。
  * 读取文本用 Get-Content -Encoding UTF8（默认是 ANSI 代码页，会把 UTF-8 中文
    读成乱码）；写文本用 [System.IO.File]::WriteAllText + 无 BOM UTF8。

  【返回值约定——最容易踩的坑】
  Bash 里 `return 0` 表示成功；PowerShell 里 **0 是假值**。
  因此判断一个"返回 int 退出码"的函数时，绝不能写 `-not (Some-Func ...)`——
  成功（返回 0）会被判成失败。必须写成：
      $rc = Some-Func ...
      if ($rc -ne 0) { ... }
  本引擎的约定：
      - Test-* / Get-* 前缀大多返回 [bool]，可以用 -not 判断；
      - Import-*/Invoke-*Run/Export-* 等返回 int 退出码，一律用 -ne 0 判断。
  已在 Catalog.ps1 的 Import-Catalog 与 setup.ps1 的 export 分支按此修正。
#>

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# 模块级可变状态（对应 Bash 侧的进程全局变量）
# ---------------------------------------------------------------------------
if (-not (Get-Variable -Name 'OSC_DEBUG' -Scope Script -ErrorAction SilentlyContinue)) { $script:DEBUG = 0 }
if (-not (Get-Variable -Name 'OSC_ASSUME_YES' -Scope Script -ErrorAction SilentlyContinue)) { $script:ASSUME_YES = 0 }
if (-not (Get-Variable -Name 'OSC_FORCE' -Scope Script -ErrorAction SilentlyContinue)) { $script:FORCE = 0 }
if (-not (Get-Variable -Name 'OSC_DRY_RUN' -Scope Script -ErrorAction SilentlyContinue)) { $script:DRY_RUN = 0 }
if (-not (Get-Variable -Name 'OSC_NO_ELEVATE' -Scope Script -ErrorAction SilentlyContinue)) { $script:NO_ELEVATE = 0 }
if (-not (Get-Variable -Name 'OSC_KEEP_GOING' -Scope Script -ErrorAction SilentlyContinue)) { $script:KEEP_GOING = 0 }
if (-not (Get-Variable -Name 'OSC_FIX' -Scope Script -ErrorAction SilentlyContinue)) { $script:FIX = 0 }

$script:HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$script:UserConfigLoaded = $false

# $LASTEXITCODE 是"本会话跑过原生程序后"才存在的自动变量。Invoke-Step /
# Invoke-StepCapture 无条件 return $LASTEXITCODE，而 Set-StrictMode 2.0 下
# 读取未设置的变量直接报错——第一个只跑 cmdlet 的步骤（如 ssh 的 mkdir）
# 就会触发，且返回值被 scriptblock 的偶然输出掩盖，时好时坏。
# 加载时统一置 0：此刻还没有原生程序退出过，0 就是正确答案。
$global:LASTEXITCODE = 0

# ---------------------------------------------------------------------------
# 基础探测
# ---------------------------------------------------------------------------
function Test-CommandExists {
  <#
    某个外部命令是否真的可用。

    必须限定 -CommandType：PS 5.1 里 curl / wget 是 Invoke-WebRequest 的内置
    别名，裸 Get-Command 会先解析到别名并返回 $true——于是 catalog 里
    win_backend=builtin 的 [curl] 会被判成"已安装、无需安装"，而实际上机器上
    并没有 curl.exe；接着 Resolve-CommandBin 取别名的 .Source（空串）又说找不到，
    两个 helper 对同一输入给出相反答案。限定为 Application + ExternalScript
    后只认磁盘上真实存在的可执行文件/脚本（npm.ps1 属于后者，仍能解析到）。
  #>
  param([Parameter(Mandatory=$true)][string]$Name)
  return [bool](Get-Command -Name $Name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
                Select-Object -First 1)
}

function Test-DictHasKey {
  <#
    统一的"字典里有没有这个键"判断。

    为什么需要它：PowerShell 里 [ordered]@{} 造出来的是
    System.Collections.Specialized.OrderedDictionary，它的 API 与普通 @{} 哈希表
    不同——只有 .Contains()，没有 .ContainsKey()（实测 PS 5.1 直接抛
    MethodNotFound）。而本引擎有序映射（CAT_* / PROF_*）必须用 [ordered]@{}
    （普通哈希表枚举顺序是任意的），局部去重表又习惯用 @{}。
    用这个 helper 屏蔽两种类型的差异，调用方不必关心底层是哪种。
  #>
  param(
    [Parameter(Mandatory=$false)]$Dictionary,
    [Parameter(Mandatory=$true)][string]$Key
  )
  if ($null -eq $Dictionary) { return $false }
  if ($Dictionary -is [System.Collections.Specialized.OrderedDictionary]) {
    return $Dictionary.Contains($Key)
  }
  if ($Dictionary -is [System.Collections.IDictionary]) {
    # 普通 @{} 哈希表（以及 Hashtable）才有 ContainsKey
    return $Dictionary.ContainsKey($Key)
  }
  return $false
}

function Test-FileContains {
  <# file_contains：grep -qE "$2" "$1" 的移植 #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Pattern
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
  } catch { return $false }
  return [regex]::IsMatch($content, $Pattern)
}

function Get-GitConfigValue {
  <# git_cfg_get：git config --global --get <key>；未设置时返回空串 #>
  param([Parameter(Mandatory=$true)][string]$Key)
  if (-not (Test-CommandExists 'git')) { return '' }
  try {
    $out = & git config --global --get $Key 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($out | Out-String).Trim()
  } catch { return '' }
}

function Invoke-Trim {
  param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return '' }
  return $Value.Trim()
}

function New-TempFile {
  <# util_mktemp：创建临时文件并返回路径；失败返回 $null #>
  param([string]$Description = '临时文件')
  try {
    $path = [System.IO.Path]::GetTempFileName()
    return $path
  } catch {
    Write-ErrorLog ("无法创建{0}" -f $Description)
    return $null
  }
}

function Request-Confirm {
  <#
    confirm：交互确认。--yes / --force 时默认通过（与 util.sh:62-67 一致）。
    返回 $true/$false。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$Force = 0,
    [int]$AssumeYes = 0
  )
  if ($AssumeYes -eq 1) { return $true }
  if ($Force -eq 1) { return $true }
  if (-not [Environment]::UserInteractive) { return $false }
  try {
    $answer = Read-Host -Prompt "$Prompt [y/N]"
  } catch { return $false }
  return ($answer -eq 'y' -or $answer -eq 'Y')
}

# ---------------------------------------------------------------------------
# 步骤执行
# ---------------------------------------------------------------------------
function Invoke-Step {
  <#
    run_step：记录命令后执行，返回原生退出码。
    Bash 侧 run_step 只记录不捕获输出；这里保持一致（输出直接进终端）。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Description,
    [Parameter(Mandatory=$true)][scriptblock]$Script
  )
  Write-InfoLog $Description
  & $Script
  return $LASTEXITCODE
}

function Invoke-StepCapture {
  <#
    run_step_verbose_capture：执行并把输出收成字符串，同时返回退出码。
    用 [void] 捕获 + 显式 return，避免调用方拿到输出对象。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Description,
    [Parameter(Mandatory=$true)][scriptblock]$Script
  )
  Write-InfoLog $Description
  $output = & $Script 2>&1
  $rc = $LASTEXITCODE
  foreach ($line in $output) {
    $text = if ($null -eq $line) { '' } else { $line.ToString() }
    Write-DebugLog ("  | {0}" -f $text)
  }
  $script:LastStepOutput = ($output | Out-String)
  return $rc
}

function ConvertTo-NativeArgumentString {
  <#
    Windows 命令行参数引用：每个参数独立包一层双引号，参数内部的双引号翻倍。
    空参数变成 ""——这正是关键： PowerShell 5.1 用普通调用运算符执行原生
    程序时会**丢弃空字符串参数**（实测：& tool -N '' 传给程序的是 -N 后面
    直接接下一个参数），某些程序因此收到错位的一系列参数。
  #>
  param(
    # AllowEmptyString：调用方就是要传空串元素（空口令、空配置值）。
    # Mandatory 自带 ValidateNotNullOrEmpty，少了它整个数组会被拒绑。
    [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @()
  )
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($a in $Arguments) {
    if ($null -eq $a) { $parts.Add('""'); continue }
    $parts.Add(('"{0}"' -f $a.Replace('"', '""')))
  }
  return ($parts -join ' ')
}

function Invoke-NativeStep {
  <#
    以"自己拼的命令行"执行原生程序，返回退出码（int）。

    为什么需要它：PowerShell 5.1 通过调用运算符执行原生程序时会丢弃空字符串
    参数。两个真实后果：
      * ssh-keygen -N ''（SSH_KEY_PASSPHRASE 未设置时的默认路径）变成
        -N -C ...，ssh-keygen 报 "Too many arguments"，密钥根本生成不了；
      * git config --global <key> ''（还原一个原本未设置的值）退化成读操作，
        "还原"静默地什么都不做，退出码还是 0。
    这里用 ProcessStartInfo 显式拼命令行：空参数是 ""，按 Windows/CRT 的
    参数解析规则原样送到程序。

    输出合并 stdout+stderr：debug 级别逐行打印，失败时额外 warn 一遍，
    同时写进 $script:LastStepOutput 供调用方检查（如 npm 的 ENOTEMPTY）。
    注意：本函数不经由 PowerShell 起原生进程，$LASTEXITCODE 不会更新，
    调用方必须用返回值判断成败。

    已知边界：先顺序读 stdout 再读 stderr。本引擎用到的程序输出都只有几行，
    远小于管道缓冲区，不会出现"子进程写满 stderr 缓冲区而死等"的经典死锁；
    若未来接输出量大的程序，需要改成异步读取。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Description,
    [Parameter(Mandatory=$true)][string]$FileName,
    # AllowEmptyString 是必须的：Mandatory 会顺带带上 ValidateNotNullOrEmpty，
    # 数组里的空串元素（空口令、空配置值）会被整体拒绑——那正是本函数要解决的
    # 场景，不能把自己堵死。
    [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @()
  )
  Write-InfoLog $Description

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = (ConvertTo-NativeArgumentString -Arguments $Arguments)
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = $null
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
  } catch {
    Write-ErrorLog ("无法启动 {0}：{1}" -f $FileName, $_.Exception.Message)
    return 127
  }

  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $rc = $proc.ExitCode

  $combined = ($stdout + $stderr)
  $script:LastStepOutput = $combined
  foreach ($line in ($combined -split "`r?`n")) {
    if (-not [string]::IsNullOrWhiteSpace($line)) { Write-DebugLog ("  | {0}" -f $line.Trim()) }
  }
  if ($rc -ne 0 -and -not [string]::IsNullOrWhiteSpace($combined)) {
    foreach ($line in ($combined -split "`r?`n")) {
      if (-not [string]::IsNullOrWhiteSpace($line)) { Write-WarnLog ("  | {0}" -f $line.Trim()) }
    }
  }
  return $rc
}

function Invoke-WithRetry {
  <#
    with_retry <max> <sleep_sec> -- <cmd...>：固定间隔重试。
    返回最后一次的退出码。

    输出处理：合并 stdout+stderr——既原样写进终端（保持 npm/fnm 安装进度
    可见，与修改前一致），也存进 $script:LastStepOutput。后者是
    Install-NpmGlobalFixed 判断 ENOTEMPTY 的依据：Bash 侧用
    run_step_verbose_capture 落捕获文件再 grep；本函数原先不捕获，
    LastStepOutput 永远是别处遗留的旧值，ENOTEMPTY 定向重试成了死代码。
  #>
  param(
    [Parameter(Mandatory=$true)][int]$MaxAttempts,
    [Parameter(Mandatory=$true)][int]$SleepSeconds,
    [Parameter(Mandatory=$true)][scriptblock]$Script
  )
  $attempt = 1
  while ($true) {
    $output = & $Script 2>&1
    $rc = $LASTEXITCODE
    $script:LastStepOutput = ($output | Out-String)
    foreach ($line in $output) {
      $text = if ($null -eq $line) { '' } else { $line.ToString() }
      if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Host ("  | {0}" -f $text.TrimEnd()) }
    }
    if ($rc -eq 0) { return 0 }
    if ($attempt -ge $MaxAttempts) { return $rc }
    Write-WarnLog ("命令失败（rc={0}），{1}s 后重试（第 {2}/{3} 次）" -f $rc, $SleepSeconds, ($attempt + 1), $MaxAttempts)
    Start-Sleep -Seconds $SleepSeconds
    $attempt++
  }
}

# ---------------------------------------------------------------------------
# 提权（替代 sudo）
# ---------------------------------------------------------------------------
function Test-IsAdmin {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Test-IsInteractive {
  try {
    return ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)
  } catch {
    return $false
  }
}

function Request-Elevation {
  <#
    require_sudo 的 Windows 对应物。三分支与 util.sh:200-209 一致：
      已是管理员        → 0
      交互终端          → UAC 提权重跑自身，透传退出码
      非交互且无权限    → 明确报错并返回 1（不静默、不挂住）
  #>
  param([string[]]$Arguments = @())

  if (Test-IsAdmin) { return 0 }

  if (-not (Test-IsInteractive)) {
    Write-ErrorLog '需要管理员权限：请以管理员身份重新运行，或用 --no-elevate 跳过需要提权的项'
    return 1
  }

  $self = $PSCommandPath
  if ([string]::IsNullOrEmpty($self)) { $self = (Get-Process -Id $PID).Path }
  Write-WarnLog '需要管理员权限，正在请求提权（UAC 弹窗请点"是"）'

  $argList = New-Object System.Collections.Generic.List[string]
  $argList.Add('-NoProfile')
  $argList.Add('-ExecutionPolicy')
  $argList.Add('Bypass')
  $argList.Add('-File')
  $argList.Add($self)
  foreach ($a in $Arguments) { if (-not [string]::IsNullOrEmpty($a)) { $argList.Add($a) } }

  try {
    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $argList
    return $proc.ExitCode
  } catch {
    Write-ErrorLog ("提权失败：{0}" -f $_.Exception.Message)
    Write-ErrorLog '请以管理员身份重新运行，或用 --no-elevate 跳过需要提权的项'
    return 1
  }
}

# ---------------------------------------------------------------------------
# 配置加载
# ---------------------------------------------------------------------------
function Import-UserConfig {
  <#
    load_user_config 的移植：按 versions.env → user.env 的顺序读取 KEY=VALUE，
    后者覆盖前者。Bash 侧用 set -a source；这里手写解析以避免执行文件内容。

    行内注释的处理必须与 bash source 一致：`KEY=value  # 注释` 里的 # 因为
    前面是空白、自成一个词，被 bash 当作注释起点，值只取 value；而
    `KEY=val#ue` 里的 # 属于值本身。config/versions.env 里就有
    OPENCODE_PKG=opencode-ai       # 注意：...
    这样的行，不按同样规则切会把 npm 包名静默污染成带注释的字符串。
  #>
  param([string]$ProjectDir)

  if ($script:UserConfigLoaded) { return }
  $script:UserConfigLoaded = $true
  $files = @(
    (Join-Path $ProjectDir 'config\versions.env'),
    (Join-Path $ProjectDir 'config\user.env')
  )
  foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    try {
      $lines = Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction Stop
    } catch { continue }
    foreach ($raw in $lines) {
      # 剥掉行内注释：# 位于行首或其前一个是空白时才是注释起点
      $cut = -1
      for ($i = 0; $i -lt $raw.Length; $i++) {
        if ($raw[$i] -eq '#') {
          if ($i -eq 0 -or [char]::IsWhiteSpace($raw[$i - 1])) { $cut = $i; break }
        }
      }
      $line = if ($cut -ge 0) { $raw.Substring(0, $cut) } else { $raw }
      $line = $line.Trim()
      if ($line -eq '') { continue }
      if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
      $key = $Matches[1]
      $val = $Matches[2].Trim()
      # 去掉一层成对的单/双引号（bash source 的语义）
      if ($val.Length -ge 2) {
        if (($val.StartsWith("'") -and $val.EndsWith("'")) -or ($val.StartsWith('"') -and $val.EndsWith('"'))) {
          $val = $val.Substring(1, $val.Length - 2)
        }
      }
      Set-Item -Path ("Env:{0}" -f $key) -Value $val -ErrorAction SilentlyContinue
    }
  }
  # 与 Bash 侧 _warn_deprecated_config 对齐：已废弃的键静默忽略会让用户以为
  # 开关还起作用，因此明确提示一次。PowerShell 侧原先漏了这段，导致
  # SSH_INSTALL_SERVER 在 Windows 上无声失效。
  if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('SSH_INSTALL_SERVER'))) {
    Write-WarnLog 'SSH_INSTALL_SERVER 已废弃（openssh-server 现在是 catalog 条目），本项不再生效'
    Write-CommandLog '.\setup.ps1 install --pick openssh-server'
  }
}

function Get-ConfigValue {
  <#
    读取一个配置项：环境变量优先，为空则用内置默认值。
    对应 Bash 侧的 ${VAR:-默认值}。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Key,
    [string]$Default = ''
  )
  $v = [Environment]::GetEnvironmentVariable($Key)
  if ([string]::IsNullOrEmpty($v)) { return $Default }
  return $v
}

# ---------------------------------------------------------------------------
# 托管块（BEGIN/END 标记）—— proxy 与 nodejs 两个动作共用
# ---------------------------------------------------------------------------
function Get-ManagedBlock {
  <#
    精确抽出 BEGIN..END 之间的文本（含两行标记）。没有 BEGIN 时返回空串。
    对应 proxy.sh 的 _proxy_block_current。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Begin,
    [Parameter(Mandatory=$true)][string]$End
  )
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  try { $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop } catch { return '' }
  $out = New-Object System.Collections.Generic.List[string]
  $inside = $false
  foreach ($l in $lines) {
    if (-not $inside) {
      if ($l -like ("*{0}*" -f $Begin)) { $inside = $true; $out.Add($l) }
    } else {
      $out.Add($l)
      if ($l -like ("*{0}*" -f $End)) { break }
    }
  }
  if ($out.Count -eq 0) { return '' }
  return ($out -join "`r`n")
}

function Remove-ManagedBlock {
  <#
    删除托管块。缺少 END 标记时拒绝删除并返回 1（避免误删后续内容）。
    对应 _proxy_strip_block。返回 0 表示无需删除或已删除。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Begin,
    [Parameter(Mandatory=$true)][string]$End
  )
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  try { $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop } catch { return 1 }

  $hasBegin = $false; $hasEnd = $false
  foreach ($l in $lines) {
    if ($l -like ("*{0}*" -f $Begin)) { $hasBegin = $true }
    if ($l -like ("*{0}*" -f $End)) { $hasEnd = $true }
  }
  if (-not $hasBegin) { return 0 }
  if (-not $hasEnd) {
    Write-ErrorLog ("托管块缺少结束标记，拒绝删除：{0}" -f $Path)
    return 1
  }

  $out = New-Object System.Collections.Generic.List[string]
  $inside = $false
  foreach ($l in $lines) {
    if (-not $inside) {
      if ($l -like ("*{0}*" -f $Begin)) { $inside = $true; continue }
      $out.Add($l)
    } else {
      if ($l -like ("*{0}*" -f $End)) { $inside = $false }
      continue
    }
  }
  $text = ($out -join "`r`n")
  if ($text -ne '' -and -not $text.EndsWith("`r`n")) { $text += "`r`n" }
  try {
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding $false))
  } catch {
    Write-ErrorLog ("无法写回 {0}：{1}" -f $Path, $_.Exception.Message)
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 代理地址推导与连通性
# ---------------------------------------------------------------------------
function Get-PrimaryIPv4 {
  <#
    detect_primary_ipv4 的 Windows 移植。
    Bash 用 `ip -4 route get 1.1.1.1` 取 src 字段；Windows 用 Get-NetIPAddress
    优先取默认网关所在网卡，退化到第一个非回环、非链路本地地址。
    返回 IP 字符串或空串。
  #>
  $addrs = $null
  try { $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) } catch { $addrs = @() }
  if ($addrs.Count -gt 0) {
    # 优先：与默认网关同网段的那类地址里取第一个非回环
    $candidates = @($addrs | Where-Object {
      $_.IPAddress -notlike '127.*' -and $_.IPAddress -ne '0.0.0.0'
    })
    if ($candidates.Count -gt 0) {
      # PrefixOrigin Dhcp/Manual 且不是链路本地
      $preferred = @($candidates | Where-Object { $_.IPAddress -notlike '169.254.*' } | Sort-Object -Property IPAddress)
      if ($preferred.Count -gt 0) { return $preferred[0].IPAddress }
    }
  }
  # 退化：DNS 解析本机名
  try {
    $hostEntries = [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME)
    foreach ($e in $hostEntries) {
      if ($e.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if ($e.ToString() -notlike '127.*' -and $e.ToString() -notlike '169.254.*') { return $e.ToString() }
      }
    }
  } catch { }
  return ''
}

function Test-IPv4Valid {
  param([string]$Ip)
  if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
  foreach ($oct in $Matches[1..4]) {
    if ([int]$oct -gt 255) { return $false }
  }
  return $true
}

function Resolve-ProxyEndpoint {
  <#
    resolve_proxy_endpoint 的移植。设置全局变量并返回码：
      0 成功；1 无法探测 IPv4；2 端口非法；3 主机名非法
    成功时填充 $script:RESOLVED_PROXY_HOST/PORT/URL/SOURCE_IP。
  #>
  $script:RESOLVED_PROXY_HOST = ''
  $script:RESOLVED_PROXY_PORT = ''
  $script:RESOLVED_PROXY_URL = ''
  $script:PROXY_SOURCE_IP = ''

  $host_ = Get-ConfigValue 'PROXY_HOST' ''
  $port = Get-ConfigValue 'PROXY_PORT' ''

  if ([string]::IsNullOrEmpty($host_)) {
    $ip = Get-PrimaryIPv4
    if ([string]::IsNullOrEmpty($ip)) {
      Write-ErrorLog '无法探测本机 IPv4；请在 config/user.env 中显式设置 PROXY_HOST'
      return 1
    }
    # 自动推导：把最后一段换成 1（网关）
    $idx = $ip.LastIndexOf('.')
    $host_ = $ip.Substring(0, $idx + 1) + '1'
    $script:PROXY_SOURCE_IP = $ip
    Write-DebugLog ("代理主机未设置，按探测到的 IPv4 {0} 推导为 {1}" -f $ip, $host_)
  }

  if ([string]::IsNullOrEmpty($port)) {
    $port = '7890'
    Write-DebugLog '代理端口未设置，使用默认 7890'
  }

  if ($port -notmatch '^[0-9]+$') {
    Write-ErrorLog ("代理端口非法：{0}（应为 1-65535）" -f $port)
    return 2
  }
  $portNum = [int]$port
  if ($portNum -lt 1 -or $portNum -gt 65535) {
    Write-ErrorLog ("代理端口超出范围：{0}（应为 1-65535）" -f $port)
    return 2
  }

  if ($host_ -notmatch '^([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\])$') {
    Write-ErrorLog ("代理主机名非法：{0}" -f $host_)
    return 3
  }
  if ($host_.StartsWith('-')) {
    Write-ErrorLog ("代理主机名非法：{0}" -f $host_)
    return 3
  }

  $script:RESOLVED_PROXY_HOST = $host_
  $script:RESOLVED_PROXY_PORT = $port
  $script:RESOLVED_PROXY_URL = ("http://{0}:{1}" -f $host_, $port)
  return 0
}

function Test-ProxyHostReachable {
  <#
    ensure_proxy_host_reachable 的移植：Test-Connection 代替 ping。
    Bash 侧 rc 2 表示没有 ping 命令；这里保持同一约定。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$HostName,
    [int]$Port = 0
  )
  # 这里探的是 PowerShell 自带 cmdlet（ PowerShell Core / 非 Windows 上可能没有），
  # 不是磁盘上的外部可执行文件，所以不能走限定 Application 的 Test-CommandExists，
  # 否则永远走进"不可用"分支，把代理主机连通性检查静默关掉。
  if (-not (Get-Command -Name 'Test-Connection' -ErrorAction SilentlyContinue)) {
    Write-WarnLog 'Test-Connection 不可用，跳过代理主机连通性检查'
    return 2
  }
  $probe = $HostName
  if ($probe.StartsWith('[') -and $probe.EndsWith(']')) { $probe = $probe.Substring(1, $probe.Length - 2) }
  try {
    $ok = Test-Connection -ComputerName $probe -Count 1 -Quiet -ErrorAction SilentlyContinue
  } catch { $ok = $false }
  if (-not $ok) {
    Write-WarnLog ("代理主机 {0} 不可达；请检查代理是否已启动、防火墙是否放行" -f $HostName)
    return 1
  }
  return 0
}

function Test-ProxyCurlConnectivity {
  <#
    ensure_proxy_curl_connectivity 的移植：用 curl.exe 真实经代理访问测试 URL。
    注意 PS 5.1 中 curl 是 Invoke-WebRequest 的别名，必须写 curl.exe。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ProxyUrl,
    [Parameter(Mandatory=$true)][string]$TestUrl,
    [string]$ConnectTimeout = '5',
    [string]$MaxTime = '15'
  )
  if (-not (Test-CommandExists 'curl.exe')) {
    Write-WarnLog 'curl.exe 不可用，跳过代理连通性校验'
    return 2
  }
  if ($ConnectTimeout -notmatch '^[1-9][0-9]*$') { $ConnectTimeout = '5' }
  if ($MaxTime -notmatch '^[1-9][0-9]*$') { $MaxTime = '15' }

  & curl.exe -fsSL -x $ProxyUrl --connect-timeout $ConnectTimeout --max-time $MaxTime -o NUL -- $TestUrl
  return $LASTEXITCODE
}
