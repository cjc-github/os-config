#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Log.ps1 —— 终端 + 文件日志与脱敏（engine/lib/log.sh 的移植）
.DESCRIPTION
  与 Bash 版的关键差异（PowerShell 特有，必须遵守）：

  1. 所有日志一律走 Write-Host，绝不写输出流。PowerShell 函数会把输出流里的
     对象一起"返回"，污染调用方的返回值；Bash 用 stderr 天然隔开了数据与日志。
  2. 文件写入用 [System.IO.File]::AppendAllText + UTF8 无 BOM。
     PS 5.1 的 Out-File/Set-Content 默认写 UTF-16LE，-Encoding UTF8 又会带 BOM，
     后者会被 git / ssh-keygen 拒绝。
  3. 脱敏正则与 log.sh 的 _redact 逐条对应，保证两份引擎的日志可以互相审阅。
.NOTES
  不要设置 $ErrorActionPreference = 'Stop'；本引擎全程用显式返回码表达失败，
  对应 Bash 侧"不要加 set -e"的约定。
#>

Set-StrictMode -Version 2.0

# 颜色（非交互或重定向时禁用）
$script:LogUseColor = $false
try {
  if ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
    $script:LogUseColor = $true
  }
} catch {
  $script:LogUseColor = $false
}

$script:LogFile = ''

function Initialize-LogFile {
  <#
    初始化日志文件。目录或文件不可写时降级为仅终端输出，与 log.sh:14-32 一致：
    否则每条日志都会抛红定向错误，既淹没真正的失败信息，也让人误以为已落盘。
  #>
  param([string]$Path)

  $script:LogFile = ''
  if ([string]::IsNullOrEmpty($Path)) { return }

  $dir = Split-Path -Path $Path -Parent
  if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
  try {
    if (-not (Test-Path -LiteralPath $dir)) {
      $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $Path)) {
      $null = New-Item -ItemType File -Path $Path -ErrorAction Stop
    }
    $script:LogFile = $Path
  } catch {
    Write-Host ("[WARN] 无法写入日志文件：{0}（本次仅输出到终端）" -f $Path)
    $script:LogFile = ''
  }
}

function Get-LogPath {
  if ([string]::IsNullOrEmpty($script:LogFile)) { return '<未落盘>' }
  return $script:LogFile
}

function Invoke-Redact {
  <#
    脱敏：key=value 形式的凭据、裸令牌（sk-/gh* 前缀）、Bearer 与 URL 凭据。
    与 engine/lib/log.sh 的 _redact 一一对应。
  #>
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $s = $Text
  $s = [regex]::Replace($s, '(?i)((sk-|token|password|passphrase|api[_-]?key|secret)=)[^\s]+', '${1}****')
  $s = [regex]::Replace($s, '(^|[^A-Za-z0-9_-])(sk-[A-Za-z0-9_-]{8,})', '${1}sk-****')
  $s = [regex]::Replace($s, '(^|[^A-Za-z0-9_-])(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9]{16,})', '${1}****')
  $s = [regex]::Replace($s, '(?i)(Authorization:\s*Bearer\s+)[^\s]+', '${1}****')
  $s = [regex]::Replace($s, '(?i)(https?://)[^/@\s]+:[^/@\s]+@', '${1}****:****@')
  return $s
}

function Write-LogLine {
  <#
    统一出口：终端（带颜色）+ 落盘（脱敏、UTF8 无 BOM）。
    绝不向输出流写任何东西。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Level,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
    [string]$Color = 'Gray'
  )

  $ts = (Get-Date).ToString('HH:mm:ss')
  $prefix = "[$Level]"
  if ($script:LogUseColor) {
    # Write-Host 的 -ForegroundColor 只接受枚举名；用 try 包裹以防宿主不支持
    try { Write-Host $prefix -ForegroundColor $Color -NoNewline } catch { Write-Host $prefix -NoNewline }
    Write-Host " $Message"
  } else {
    Write-Host "$prefix $Message"
  }

  if (-not [string]::IsNullOrEmpty($script:LogFile)) {
    $line = "[$ts] [$Level] $Message"
    $line = Invoke-Redact -Text $line
    try {
      [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {
      # 落盘失败不能反过来影响主流程（log.sh 用 2>/dev/null 达到同样效果）
    }
  }
}

function Write-InfoLog    { param([Parameter(Mandatory=$true)][string]$Message) Write-LogLine -Level 'INFO'  -Message $Message -Color 'Cyan' }
function Write-OkLog      { param([Parameter(Mandatory=$true)][string]$Message) Write-LogLine -Level 'OK'    -Message $Message -Color 'Green' }
function Write-WarnLog    { param([Parameter(Mandatory=$true)][string]$Message) Write-LogLine -Level 'WARN'  -Message $Message -Color 'Yellow' }
function Write-ErrorLog   { param([Parameter(Mandatory=$true)][string]$Message) Write-LogLine -Level 'ERROR' -Message $Message -Color 'Red' }

function Write-DebugLog {
  param([Parameter(Mandatory=$true)][string]$Message)
  if ($script:DEBUG -ne 1) { return }
  Write-LogLine -Level 'DEBUG' -Message $Message -Color 'Cyan'
}

function Write-SectionLog {
  <#
    与 log_section 对应：终端输出分隔标题，同时写入日志文件。
    注意日志文件里的标题不带颜色转义。
  #>
  param([Parameter(Mandatory=$true)][string]$Title)
  if ($script:LogUseColor) {
    try { Write-Host ("`n=== {0} ===" -f $Title) -ForegroundColor Magenta } catch { Write-Host "`n=== $Title ===" }
  } else {
    Write-Host "`n=== $Title ==="
  }
  if (-not [string]::IsNullOrEmpty($script:LogFile)) {
    try {
      [System.IO.File]::AppendAllText($script:LogFile, "`n=== $Title ===`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch { }
  }
}

function Write-CommandLog {
  <#
    在提示日志下一行显示可复制执行的命令，同时以 COMMAND 级别写入日志。
    对应 log_command（log.sh:61-68）。
  #>
  param([Parameter(Mandatory=$true)][string]$Message)
  Write-Host "       $Message"
  if (-not [string]::IsNullOrEmpty($script:LogFile)) {
    $line = Invoke-Redact -Text ("[{0}] [COMMAND] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Message)
    try {
      [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch { }
  }
}
