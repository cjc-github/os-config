#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/State.ps1 —— 状态层（engine/lib/state.sh 的移植）
.DESCRIPTION
  覆盖 manifest 读写、运行快照、以及 mkdir 原子锁。

  必须逐条保持的行为契约（已核对 state.sh）：

  * manifest 行格式 tool|action|artifact|timestamp，一个产物一行，
    无产物时 artifact 为 -。时间戳为本地时间、秒精度。
  * state_record 是 forget-then-append：一个工具只有一代记录。
  * package 类工具永不写 manifest（状态实时问后端）。
  * STATE_SNAPSHOT_OWNER 门控 restore/discard，只读运行与 dry-run
    绝不能删掉或还原并发写运行的 .manifest.run.bak 基线。
  * 残留的 .manifest.run.bak 被直接沿用为回滚基线（有意为之，不要"修"）。
  * .lock 是一个目录，内含 pid 文件。pid 已死 → 清理后重试一次；
    pid 文件缺失或为空 → 永不回收，报"状态未知"；
    释放前必须比对 pid，只释放自己持有的锁。

  PowerShell 上的锁实现：New-Item -ItemType Directory -ErrorAction Stop
  在目录已存在时抛 IOException（Win32 ERROR_ALREADY_EXISTS），是原子的。
  注意 [System.IO.Directory]::CreateDirectory() 在目录已存在时不抛异常，
  不能用作锁原语。
#>

Set-StrictMode -Version 2.0

$script:StateDir = ''
$script:StateFile = ''
$script:StateRunBak = ''
$script:StateLock = ''
$script:STATE_SNAPSHOT_OWNER = 0

function Initialize-StatePaths {
  param([string]$Dir)
  if ([string]::IsNullOrEmpty($Dir)) { $Dir = (Join-Path $script:ProjectDir 'state') }
  $script:StateDir = $Dir
  $script:StateFile = Join-Path $Dir 'manifest.conf'
  $script:StateRunBak = Join-Path $Dir '.manifest.run.bak'
  $script:StateLock = Join-Path $Dir '.lock'
}

function Initialize-State {
  <# state_init：建目录与 manifest。失败返回 $false。 #>
  if (-not (Test-Path -LiteralPath $script:StateDir)) {
    try { $null = New-Item -ItemType Directory -Path $script:StateDir -Force -ErrorAction Stop }
    catch { Write-ErrorLog ("无法创建状态目录：{0}" -f $script:StateDir); return $false }
  }
  if (-not (Test-Path -LiteralPath $script:StateFile)) {
    try { $null = New-Item -ItemType File -Path $script:StateFile -Force -ErrorAction Stop }
    catch { Write-ErrorLog ("无法创建状态清单：{0}" -f $script:StateFile); return $false }
  }
  return $true
}

function Save-StateSnapshot {
  <#
    state_snapshot 的移植。
    已存在 .manifest.run.bak 时直接沿用并标记 owner，不重新复制——
    这是有意的保守取舍（宁可多回退，也不丢基线）。
  #>
  if (-not (Initialize-State)) { return $false }
  if (Test-Path -LiteralPath $script:StateRunBak) {
    $script:STATE_SNAPSHOT_OWNER = 1
    return $true
  }
  try {
    if (Test-Path -LiteralPath $script:StateFile) {
      Copy-Item -LiteralPath $script:StateFile -Destination $script:StateRunBak -Force -ErrorAction Stop
    } else {
      $null = New-Item -ItemType File -Path $script:StateRunBak -Force -ErrorAction Stop
    }
  } catch {
    Write-ErrorLog ("无法记录运行前清单快照：{0}" -f $script:StateRunBak)
    return $false
  }
  $script:STATE_SNAPSHOT_OWNER = 1
  return $true
}

function Restore-StateSnapshot {
  <# state_restore_snapshot：失败回滚时把 manifest 还原到快照 #>
  if ($script:STATE_SNAPSHOT_OWNER -ne 1) { return $true }
  if (-not (Test-Path -LiteralPath $script:StateRunBak)) { return $true }
  try {
    Copy-Item -LiteralPath $script:StateRunBak -Destination $script:StateFile -Force -ErrorAction Stop
  } catch {
    Write-ErrorLog ("清单回滚失败：{0}（快照在 {1}）" -f $script:StateFile, $script:StateRunBak)
    return $false
  }
  try { Remove-Item -LiteralPath $script:StateRunBak -Force -ErrorAction SilentlyContinue } catch { }
  return $true
}

function Discard-StateSnapshot {
  <# state_discard_snapshot：成功提交或 --keep-going 时丢弃快照 #>
  if ($script:STATE_SNAPSHOT_OWNER -ne 1) { return }
  try { Remove-Item -LiteralPath $script:StateRunBak -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-StateActionDir {
  <# state_action_dir：返回（并创建）动作私有簿记目录；失败返回 $null #>
  param([Parameter(Mandatory=$true)][string]$Name)
  $d = Join-Path $script:StateDir ("actions\{0}" -f $Name)
  if (-not (Test-Path -LiteralPath $d)) {
    try { $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop }
    catch { Write-ErrorLog ("无法创建动作状态目录：{0}" -f $d); return $null }
  }
  return $d
}

function Remove-StateRecord {
  <#
    state_forget：删除该工具的清单记录。原子改写（临时文件 + 移动替换）。
    与 Bash 一致：manifest 不存在时直接返回成功。
  #>
  param([Parameter(Mandatory=$true)][string]$Tool)
  if (-not (Test-Path -LiteralPath $script:StateFile)) { return $true }
  try {
    $lines = @(Get-Content -LiteralPath $script:StateFile -Encoding UTF8 -ErrorAction Stop)
  } catch {
    Write-ErrorLog ("无法读取状态清单：{0}" -f $script:StateFile); return $false
  }
  $prefix = $Tool + '|'
  $kept = @($lines | Where-Object { -not $_.StartsWith($prefix) })
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    $text = ($kept -join "`r`n")
    if ($kept.Count -gt 0) { $text += "`r`n" }
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $script:StateFile -Force -ErrorAction Stop
  } catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    Write-ErrorLog ("无法更新状态清单：{0}" -f $script:StateFile); return $false
  }
  return $true
}

function Set-StateRecord {
  <#
    state_record <tool> <action> [artifact...]：forget 之后追加。
    一个产物一行，全部共用同一时间戳。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Tool,
    [Parameter(Mandatory=$true)][string]$Action,
    [string[]]$Artifacts = @()
  )
  if (-not (Initialize-State)) { return $false }
  if (-not (Remove-StateRecord -Tool $Tool)) { return $false }

  $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
  $sb = New-Object System.Text.StringBuilder
  if ($Artifacts.Count -eq 0) {
    $null = $sb.AppendLine(("{0}|{1}|{2}|{3}" -f $Tool, $Action, '-', $ts))
  } else {
    foreach ($a in $Artifacts) {
      if ([string]::IsNullOrWhiteSpace($a)) { continue }
      $null = $sb.AppendLine(("{0}|{1}|{2}|{3}" -f $Tool, $Action, $a, $ts))
    }
  }
  try {
    [System.IO.File]::AppendAllText($script:StateFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
  } catch {
    Write-ErrorLog ("无法写入状态清单：{0}" -f $script:StateFile); return $false
  }
  return $true
}

function Get-StateArtifacts {
  <# state_artifacts：输出该工具记录的产物路径（"-" 跳过） #>
  param([Parameter(Mandatory=$true)][string]$Tool)
  $result = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $script:StateFile)) { return $result }
  try { $lines = @(Get-Content -LiteralPath $script:StateFile -Encoding UTF8 -ErrorAction Stop) }
  catch { return $result }
  foreach ($l in $lines) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    $parts = $l.Split('|')
    if ($parts.Count -lt 3) { continue }
    if ($parts[0] -eq $Tool -and $parts[2] -ne '-') { $result.Add($parts[2]) }
  }
  return $result
}

function Test-StateHas {
  <# state_has：清单中是否有该工具 #>
  param([Parameter(Mandatory=$true)][string]$Tool)
  if (-not (Test-Path -LiteralPath $script:StateFile)) { return $false }
  try { $lines = @(Get-Content -LiteralPath $script:StateFile -Encoding UTF8 -ErrorAction Stop) }
  catch { return $false }
  $prefix = $Tool + '|'
  foreach ($l in $lines) { if ($l.StartsWith($prefix)) { return $true } }
  return $false
}

# ---------------------------------------------------------------------------
# 并发锁
# ---------------------------------------------------------------------------
function Test-ProcessAlive {
  param([int]$ProcessId)
  try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $true }
  catch [System.Management.Automation.ProcessCommandException] { return $false }
  catch { return $false }
}

function Grant-StateLock {
  <#
    state_lock_acquire 的移植。返回 0 成功、1 失败。
    保留 Bash 的边界行为：pid 文件缺失或为空的锁永不回收，报"状态未知"。
  #>
  if (-not (Initialize-State)) { return 1 }

  $created = $false
  try {
    $null = New-Item -ItemType Directory -Path $script:StateLock -ErrorAction Stop
    $created = $true
  } catch [System.IO.IOException] {
    $created = $false
  } catch {
    $created = $false
  }

  if ($created) {
    try { [System.IO.File]::WriteAllText((Join-Path $script:StateLock 'pid'), "$PID`r`n", (New-Object System.Text.UTF8Encoding $false)) } catch { }
    return 0
  }

  $pidText = ''
  $pidFile = Join-Path $script:StateLock 'pid'
  if (Test-Path -LiteralPath $pidFile) {
    try { $pidText = (Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8 -ErrorAction Stop).Trim() } catch { $pidText = '' }
  }

  if ($pidText -match '^\d+$' -and -not (Test-ProcessAlive -ProcessId ([int]$pidText))) {
    Write-WarnLog ("发现残留写锁（pid {0} 已不存在），清理后重试" -f $pidText)
    try { Remove-Item -LiteralPath $script:StateLock -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    try {
      $null = New-Item -ItemType Directory -Path $script:StateLock -ErrorAction Stop
      try { [System.IO.File]::WriteAllText((Join-Path $script:StateLock 'pid'), "$PID`r`n", (New-Object System.Text.UTF8Encoding $false)) } catch { }
      return 0
    } catch {
      Write-ErrorLog '清理残留锁后仍无法取得写锁'
      return 1
    }
  }

  if ([string]::IsNullOrEmpty($pidText)) {
    Write-ErrorLog ("另一个 setup.ps1 正在写入（状态未知），已中止；" )
    Write-ErrorLog ("若确认没有其他运行，删除 {0} 后重试" -f $script:StateLock)
    return 1
  }

  Write-ErrorLog ("另一个 setup.ps1 正在写入（pid {0}），已中止；" -f $pidText)
  Write-ErrorLog ("若确认没有其他运行，删除 {0} 后重试" -f $script:StateLock)
  return 1
}

function Test-StateLocked {
  <# state_locked：当前是否持有锁（供 EXIT 路径判断） #>
  if (-not (Test-Path -LiteralPath $script:StateLock -PathType Container)) { return $false }
  $pidFile = Join-Path $script:StateLock 'pid'
  if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
  try { $t = (Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8 -ErrorAction Stop).Trim() } catch { return $false }
  return ($t -eq "$PID")
}

function Release-StateLock {
  <# state_lock_release：只释放自己持有的锁 #>
  if (-not (Test-StateLocked)) { return }
  try { Remove-Item -LiteralPath $script:StateLock -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
