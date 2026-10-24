#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Rollback.ps1 —— 备份与回滚（engine/lib/rollback.sh 的移植）
.DESCRIPTION
  必须逐条保持的行为契约（已核对 rollback.sh）：

  * register_rollback <file> [user|sudo]：去重保留**首次**备份（_ROLLBACK_SEEN），
    因为回滚按注册顺序重放，后拍的备份会覆盖先拍的，丢掉运行前状态。
  * seen 只在备份**成功之后**才置位——备份失败不置位，允许重试，
    避免出现"有标记、无备份"的状态。
  * 提权不可用时必须**中止注册并返回非零**，绝不能把"无法确认是否存在"
    当成"不存在"——否则回滚会删掉本来存在的文件。
  * 失败时：原本存在的文件从 .bak.<ts>.<pid> 还原；原本不存在的文件删除。
  * 逐文件回滚失败只记录并继续，不让一个坏文件拖住其余文件。
  * 文件与 manifest 一起回滚（否则 status/remove 会去找已回滚的产物）。
  * VERB == verify 失败绝不碰文件，只丢弃快照。
  * --keep-going 失败时丢弃快照（保留改动），不回滚。

  PowerShell 上没有 bash 的 EXIT trap，用 try/finally 实现同等语义，
  并保证 finally 里的清理不改写退出码。
#>

Set-StrictMode -Version 2.0

$script:RollbackOrig = New-Object System.Collections.ArrayList
$script:RollbackBackup = New-Object System.Collections.ArrayList
$script:RollbackExisted = New-Object System.Collections.ArrayList
$script:RollbackSeen = @{}
$script:TmpFiles = New-Object System.Collections.ArrayList
$script:ROLLBACK_DONE = 0
$script:ROLLBACK_PERFORMED = 0

function Register-TmpFile {
  param([Parameter(Mandatory=$true)][string]$Path)
  $null = $script:TmpFiles.Add($Path)
}

function Clear-TmpFiles {
  <# cleanup_tmpfiles：每个退出路径都会跑，包括成功 #>
  foreach ($f in @($script:TmpFiles)) {
    if ([string]::IsNullOrWhiteSpace($f)) { continue }
    if (Test-Path -LiteralPath $f -PathType Leaf) {
      try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
      Write-DebugLog ("清理临时文件：{0}" -f $f)
    }
  }
  $script:TmpFiles = New-Object System.Collections.ArrayList
}

function Register-Rollback {
  <#
    register_rollback <file> [user|sudo]。
    返回 0 成功（或已注册过）、1 失败、2 模式非法。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [ValidateSet('user','sudo')][string]$Mode = 'user'
  )

  if ((Test-DictHasKey -Dictionary $script:RollbackSeen -Key $Path)) {
    Write-DebugLog '已注册回滚，跳过重复备份'
    return 0
  }

  $existed = $false
  if ($Mode -eq 'sudo') {
    # 提权不可用时不能假定文件不存在——那会让回滚删掉本该还原的文件。
    if (-not (Test-IsAdmin)) {
      Write-ErrorLog ("提权不可用，无法确认 {0} 是否存在；已中止回滚注册（避免回滚时误删该文件）" -f $Path)
      return 1
    }
    $existed = Test-Path -LiteralPath $Path
  } else {
    $existed = Test-Path -LiteralPath $Path
  }

  $bak = ''
  if ($existed) {
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $bak = "{0}.bak.{1}.{2}" -f $Path, $ts, $PID
    try {
      Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop
    } catch {
      Write-ErrorLog ("备份失败：{0} -> {1}（{2}）" -f $Path, $bak, $_.Exception.Message)
      return 1
    }
    Write-InfoLog ("已备份：{0} -> {1}" -f $Path, $bak)
  } else {
    Write-DebugLog ("已注册新文件回滚：{0}" -f $Path)
  }

  # 只有真正登记成功才标记"已注册"
  $script:RollbackSeen[$Path] = $true
  $null = $script:RollbackOrig.Add($Path)
  $null = $script:RollbackBackup.Add($bak)
  $null = $script:RollbackExisted.Add($existed)
  return 0
}

function Invoke-RollbackOnExit {
  <#
    rollback_on_exit <rc> 的移植。对应决策树：
      rc==0            → 丢弃快照，返回
      KEEP_GOING==1    → 保留改动，丢弃快照，返回
      VERB==verify     → 只丢弃快照，不碰文件
      其余             → 真正回滚
    返回 0 表示已处理（不改变调用方退出码）。
  #>
  param([int]$Rc = 0)

  if ($script:ROLLBACK_DONE -eq 1) { return 0 }
  $script:ROLLBACK_DONE = 1

  Clear-TmpFiles

  if ($Rc -eq 0) { Discard-StateSnapshot; return 0 }
  if ($script:KEEP_GOING -eq 1) {
    Write-WarnLog '--keep-going：保留已完成的改动，不触发整体回滚'
    Discard-StateSnapshot
    return 0
  }
  if ($script:VERB -eq 'verify') { Discard-StateSnapshot; return 0 }

  $script:ROLLBACK_PERFORMED = 1

  # restored 收集实际回滚的文件路径，与 Bash 版 _rollback_emit_event 的入参一致
  # （单个文件回滚失败也计入：事件表达的是"本次回滚覆盖了哪些路径"）。
  $restored = New-Object System.Collections.Generic.List[string]
  if ($script:RollbackOrig.Count -eq 0) {
    $null = Restore-StateSnapshot
    Publish-Event -Type 'rollback' -Fragment (
      '"phase":"{0}","restored":{1}' -f
      (ConvertTo-JsonLiteral -Text $(if ($script:VERB) { $script:VERB } else { 'install' })),
      (ConvertTo-JsonStringArray -Values @($restored))
    )
    return 0
  }

  Write-ErrorLog ("脚本失败（rc={0}），回滚以下文件到备份：" -f $Rc)
  for ($i = 0; $i -lt $script:RollbackOrig.Count; $i++) {
    $orig = $script:RollbackOrig[$i]
    $bak = $script:RollbackBackup[$i]
    $existed = [bool]$script:RollbackExisted[$i]
    $restored.Add($orig)
    if (-not $existed) {
      try {
        if (Test-Path -LiteralPath $orig) { Remove-Item -LiteralPath $orig -Force -ErrorAction Stop }
        Write-InfoLog ("  已删除失败过程中创建的文件：{0}" -f $orig)
      } catch {
        Write-ErrorLog ("  删除新文件失败：{0}" -f $orig)
      }
    } else {
      try {
        Copy-Item -LiteralPath $bak -Destination $orig -Force -ErrorAction Stop
        Write-InfoLog ("  已回滚：{0} <- {1}" -f $orig, $bak)
      } catch {
        Write-ErrorLog ("  回滚失败：{0}（备份在 {1}，请手动恢复）" -f $orig, $bak)
      }
    }
  }

  $null = Restore-StateSnapshot
  Publish-Event -Type 'rollback' -Fragment (
    '"phase":"{0}","restored":{1}' -f
    (ConvertTo-JsonLiteral -Text $(if ($script:VERB) { $script:VERB } else { 'install' })),
    (ConvertTo-JsonStringArray -Values @($restored))
  )
  Write-WarnLog '回滚完成。请检查失败原因后重跑'
  return 0
}

function Reset-RollbackState {
  <# 仅供测试使用：清空回滚簿记 #>
  $script:RollbackOrig = New-Object System.Collections.ArrayList
  $script:RollbackBackup = New-Object System.Collections.ArrayList
  $script:RollbackExisted = New-Object System.Collections.ArrayList
  $script:RollbackSeen = @{}
  $script:TmpFiles = New-Object System.Collections.ArrayList
  $script:ROLLBACK_DONE = 0
  $script:ROLLBACK_PERFORMED = 0
}
