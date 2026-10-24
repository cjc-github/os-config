<#
.SYNOPSIS
  ui.ps1 —— os-config 本机 Web UI 启动器（Windows 原生，ui.sh 的对应物）
.DESCRIPTION
  只监听本机（127.0.0.1/localhost），每次启动生成一次性 token。
  不做业务逻辑：参数校验、启动 ui.server、清理子进程。
  引擎由 ui/server.py 按平台自动选择（Windows 上跑 setup.ps1），
  因此本启动器不需要知道跑的是哪个引擎。

  与 ui.sh 的差异：Windows 上没有 sudo/xdg-open，提权由引擎在需要时
  自行处理（UAC），浏览器用 Start-Process 打开。

  执行策略：本仓库的 .ps1 都是 UTF-8 with BOM。PowerShell 5.1 会用 ANSI
  代码页读取无 BOM 的脚本，把中文注释与字符串弄花，因此 git clone 后若
  文件丢了 BOM，先执行 Unblock-File 并用 -ExecutionPolicy Bypass 启动。
.NOTES
  退出码：0 正常停止；1 启动失败；2 参数错误。
#>

[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$ListenHost = '127.0.0.1',
    [switch]$NoOpen,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining = @()
)

# PowerShell 5.1 默认用 ANSI/OEM 代码页与子进程通信，而 ui.server 输出 UTF-8。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

$script:ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:OSC_PROJECT_DIR = $script:ProjectDir

# 自包含的日志输出：本启动器不加载引擎库（ui.sh 同样只用 printf），
# 但保持与引擎一致的 [级别] 前缀，方便对照日志。
function Write-UiLog {
  param([Parameter(Mandatory=$true)][string]$Level, [Parameter(Mandatory=$true)][string]$Message)
  Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Show-Usage {
  Write-Host @'
os-config Web UI 启动器（Windows）

用法：
  .\ui.ps1 [选项]

选项：
  --port N        监听端口（1-65535，默认 8765）
  --host H        监听地址（仅 127.0.0.1 或 localhost，默认 127.0.0.1）
  --no-open       不自动打开浏览器，只打印访问地址
  -h, --help      本帮助

启动后窗口会打印带 token 的访问地址；token 也可从 URL 中取出后直接访问。
按 Ctrl-C 停止。
'@
}

# ---------------------------------------------------------------------------
# 参数解析（与 ui.sh 一致：--port N / --port=N / --host H / --host=H / --no-open）
# ---------------------------------------------------------------------------
$args_ = @($Remaining)
$i = 0
while ($i -lt $args_.Count) {
  $a = $args_[$i]
  switch -Regex ($a) {
    '^--port$' {
      if ($i + 1 -ge $args_.Count) { Write-UiLog 'ERROR' '--port 需要一个参数'; Show-Usage; exit 2 }
      $Port = $args_[++$i]
    }
    '^--port=(.*)$' { $Port = $Matches[1] }
    '^--host$' {
      if ($i + 1 -ge $args_.Count) { Write-UiLog 'ERROR' '--host 需要一个参数'; Show-Usage; exit 2 }
      $ListenHost = $args_[++$i]
    }
    '^--host=(.*)$' { $ListenHost = $Matches[1] }
    '^--no-open$' { $NoOpen = $true }
    '^(-h|--help)$' { Show-Usage; exit 0 }
    default {
      Write-UiLog 'ERROR' ("未知参数：{0}" -f $a)
      Show-Usage
      exit 2
    }
  }
  $i++
}

if ("$Port" -notmatch '^[0-9]+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) {
  Write-UiLog 'ERROR' '端口必须是 1-65535 的整数'
  exit 2
}
if ($ListenHost -ne '127.0.0.1' -and $ListenHost -ne 'localhost') {
  Write-UiLog 'ERROR' '只允许监听本机地址（127.0.0.1 或 localhost）'
  exit 2
}

# ---------------------------------------------------------------------------
# Python 探测：Windows 上常只有 python 没有 python3；Store 存根一跑就退 49；
# 更常见的是 PATH 上的 python 是旧版（如 3.9）而机器上通过 py 启动器装着
# 3.10+。因此逐个候选取版本，选第一个 >= 3.10 的。
#
# 版本命令刻意不含双引号：PowerShell 5.1 把 -c 参数里的 " 吞掉
# （实测 'print("%d.%d" % ...)' 到 Python 手里变成 print(%d.%d % ...)，
# 直接 SyntaxError），bash 侧没有这个问题。用 sep=chr(46) 免引号拼版本号。
#
# 候选顺序：PATH 上的 python/python3 → py -3（py 启动器选最新 Python 3）
# → py（默认）。py.exe 是 python.org 安装包自带的官方启动器。
# ---------------------------------------------------------------------------
function Get-PythonVersion {
  param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [AllowEmptyCollection()][string[]]$ExtraArgs = @()
  )
  try {
    $invoke = @($Exe) + @($ExtraArgs) + @('-c',
      'import sys; print(sys.version_info[0], sys.version_info[1], sep=chr(46))')
    $out = & $invoke[0] $invoke[1..($invoke.Count-1)] 2>$null | Out-String
    $v = "$out".Trim()
    if ($v -match '^[0-9]+\.[0-9]+$') { return $v }
  } catch { }
  return ''
}

$PyBin = ''
$PyVer = ''
$bestVer = ''
foreach ($pair in @(
    @('python', @()),
    @('python3', @()),
    @('py', @('-3')),
    @('py', @())
  )) {
  $cand = $pair[0]
  $extra = @($pair[1])
  $cmd = Get-Command -Name $cand -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
         Select-Object -First 1
  if (-not $cmd) { continue }
  $v = Get-PythonVersion -Exe $cmd.Source -ExtraArgs $extra
  if ([string]::IsNullOrEmpty($v)) { continue }
  if ([string]::IsNullOrEmpty($bestVer)) { $bestVer = $v }
  $major = [int]($v -split '\.')[0]
  $minor = [int]($v -split '\.')[1]
  if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 10)) {
    $PyBin = $cmd.Source
    $PyVer = $v
    $PyArgs = $extra
    break
  }
}
if ([string]::IsNullOrEmpty($PyBin)) {
  if ([string]::IsNullOrEmpty($bestVer)) {
    Write-UiLog 'ERROR' '需要 python（>= 3.10），但未找到可用的 python'
  } else {
    Write-UiLog 'ERROR' ("需要 python >= 3.10（找到的最高版本：{0}）" -f $bestVer)
  }
  exit 1
}
Write-UiLog 'INFO' ("python {0}（{1}）" -f $PyVer, $PyBin)

# ---------------------------------------------------------------------------
# 状态目录与日志
# ---------------------------------------------------------------------------
$stateUi = Join-Path $script:ProjectDir 'state\ui'
if (-not (Test-Path -LiteralPath $stateUi)) {
  try { $null = New-Item -ItemType Directory -Path $stateUi -Force -ErrorAction Stop } catch { }
}
$logFile = Join-Path $stateUi 'server.log'
try { Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }

# ---------------------------------------------------------------------------
# 端口占用检查：被占用必须直接失败，否则就绪探测会连上别人的服务，
# 打印一个带新 token 的地址，而实际服务仍是旧进程（表现为 unauthorized）。
# ---------------------------------------------------------------------------
function Test-PortInUse {
  param([int]$PortNo)
  $client = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', $PortNo)
    return $true
  } catch {
    return $false
  } finally {
    if ($null -ne $client) { try { $client.Close() } catch { } }
  }
}
if (Test-PortInUse -PortNo ([int]$Port)) {
  Write-UiLog 'ERROR' ("端口 {0} 已被占用，请关闭占用该端口的进程或改用 --port 指定其他端口" -f $Port)
  exit 1
}

# ---------------------------------------------------------------------------
# 环境规整：Start-Process 会把当前环境搬进 .NET 字典，而字典键大小写不敏感。
# 某些工具/代理软件会同时设下 NO_PROXY 与 no_proxy，此时 Start-Process 直接抛
# "已添加项。字典中的关键字"ArgumentException——服务永远起不来。
# Windows 环境块本身就是大小写不敏感的，重复项留一个没有语义差别。
# ---------------------------------------------------------------------------
function Remove-DuplicateEnvVars {
  $seen = @{}
  foreach ($k in ([System.Environment]::GetEnvironmentVariables().Keys)) {
    $lk = "$k".ToLowerInvariant()
    if ($seen.ContainsKey($lk)) {
      try { [Environment]::SetEnvironmentVariable($k, $null) } catch { }
    } else {
      $seen[$lk] = $true
    }
  }
}

# ---------------------------------------------------------------------------
# 启动服务
# ---------------------------------------------------------------------------
$token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$env:OS_CONFIG_UI_TOKEN = $token
$env:PYTHONPATH = $script:ProjectDir
Remove-DuplicateEnvVars

$proc = $null
try {
  # $PyArgs 承载 py 启动器的版本选择参数（如 -3）；普通 python 为空。
  $serverArgs = @($PyArgs) + @('-m', 'ui.server', '--host', $ListenHost, '--port', "$Port")
  $proc = Start-Process -FilePath $PyBin `
            -ArgumentList $serverArgs `
            -WorkingDirectory $script:ProjectDir `
            -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
} catch {
  Write-UiLog 'ERROR' ("无法启动 ui.server：{0}" -f $_.Exception.Message)
  exit 1
}

# 就绪探测：最多 10 秒
$ready = $false
for ($n = 0; $n -lt 100; $n++) {
  if ($proc.HasExited) { break }
  if (Test-PortInUse -PortNo ([int]$Port)) { $ready = $true; break }
  Start-Sleep -Milliseconds 100
}
if (-not $ready) {
  Write-UiLog 'ERROR' '服务未能在 10 秒内就绪。端口可能被占用，请用 --port 指定其他端口'
  Write-UiLog 'ERROR' ("服务日志：{0}" -f $logFile)
  if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
  exit 1
}

$url = "http://$ListenHost`:$Port/?token=$token"
Write-UiLog 'OK' ("os-config UI 已启动: {0}" -f $url)
Write-UiLog 'INFO' ("服务日志：{0}" -f $logFile)
if (-not $NoOpen) {
  try { Start-Process $url -ErrorAction SilentlyContinue } catch { }
}
Write-Host '按 Ctrl-C 停止。'

# ---------------------------------------------------------------------------
# 等待服务结束（Ctrl-C / 关闭窗口时清理子进程）
# ---------------------------------------------------------------------------
$script:Stopping = $false
try {
  while (-not $script:Stopping -and -not $proc.HasExited) {
    Start-Sleep -Milliseconds 300
  }
} finally {
  $script:Stopping = $true
  if ($proc -and -not $proc.HasExited) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
  }
}
exit 0
