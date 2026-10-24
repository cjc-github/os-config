#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Engine.ps1 —— 七动词编排器（engine/lib/engine.sh 的移植）
.DESCRIPTION
  展开依赖闭包 → 按序分派到后端适配器（type=package）或配置动作（type=config）
  → 汇总结果。引擎不认识任何具体工具名，只认 catalog 数据。

  必须逐条保持的行为契约（已核对 engine.sh）：

  * rc 分类：0 = ok（dry-run 下为 planned）；100 = skipped；其余 = failed。
    100 绝不进入进程退出码。
  * 分派门顺序：**平台门 → 提权门 → dry-run 门 → package → config**。
    dry-run 在任何后端/动作代码之前短路，不碰盘、不写 manifest。
    --no-elevate + dry-run 同时给 → 100（不是 planned）。
  * state_sync 只对 type=config 生效；package 类永不写 manifest。
  * verify --fix：先 verify；0 或 100 直接返回；未通过则 apply 一次、
    复验一次；复验仍不过判失败。失败 rc 一律压平成 1。
  * 默认 fail-fast（首个失败即中断）；--keep-going 跑完但仍返回 1，
    且 EXIT 路径丢弃快照（保留改动）而非回滚。
  * planned 计入成功计数，只是事件状态不同。
#>

Set-StrictMode -Version 2.0

$script:ENGINE_OK = 0
$script:ENGINE_SKIPPED = 0
$script:ENGINE_FAILED = 0
$script:VERB = 'install'
$script:SELECTED_TOOLS = New-Object System.Collections.Generic.List[string]
# 注意：不要在这里写 $script:ProjectDir = ''。本文件被 setup.ps1 dot-source 进
# 同一个脚本作用域，那行会把入口已经算好的项目根目录清空。ProjectDir 由入口设置。

# ---------------------------------------------------------------------------
# 动作分派
# ---------------------------------------------------------------------------
function Get-EngineActionVerb {
  <# _engine_action_verb：五动词 → 配置动作动词 #>
  param([Parameter(Mandatory=$true)][string]$Verb)
  switch ($Verb) {
    'install' { return 'apply' }
    'update'  { return 'apply' }
    'remove'  { return 'remove' }
    'verify'  { return 'verify' }
    'status'  { return 'status' }
    default   { return $null }
  }
}

function Test-EngineActionLoaded {
  <#
    动作脚本是否已随入口加载（只做存在性检查，不在这里点源）。

    为什么不在本函数里点源（. file）：PowerShell 的函数内点源只把定义放进
    **该函数自己的作用域**，函数一返回就消失（实测：文件与 scriptblock 两种
    形式都不行）。Bash 的 source 没有这层作用域问题，因此 Bash 版
    _engine_source_action 的"惰性加载"不能照搬——照搬的后果是分派时
    Get-Command action_<x>_<verb> 全部找不到：apply/remove/verify 报
    "不支持动词"，status 又静默回退到通用输出，整个 config 动作层失效而
    没有任何显式错误。动作脚本改由 setup.ps1 在入口处全量点源（与 lib-win
    的各 .ps1 同一位置、同一方式），本函数只保留"脚本缺失"的显式报错。

    写注释的教训：块注释的正文里不能再出现块注释结束记号（井号后跟大于号），
    否则注释会被提前闭合，后面的函数体变成裸代码，加载期就炸。
    本文特意不写出该记号的字面形式。
  #>
  param([Parameter(Mandatory=$true)][string]$Action)
  $file = Join-Path $script:ProjectDir ("engine\actions-win\{0}.ps1" -f $Action)
  if (-not (Test-Path -LiteralPath $file)) {
    Write-ErrorLog ("动作脚本不存在：{0}" -f $file); return $false
  }
  return $true
}

function Show-ConfigStatusFallback {
  <# _engine_config_status_fallback：动作未实现 status 时的通用输出 #>
  param([Parameter(Mandatory=$true)][string]$Id)
  Write-Host ("    {0,-22} {1}" -f $Id, ("config:" + $script:CAT_ACTION[$Id]))
  if (Test-StateHas -Tool $Id) {
    foreach ($p in (Get-StateArtifacts -Tool $Id)) {
      if ([string]::IsNullOrWhiteSpace($p)) { continue }
      Write-Host ("      {0,-20} {1}" -f 'artifact', $p)
    }
  } else {
    Write-Host ("      {0,-20} {1}" -f 'state', '未记录（可能未安装）')
  }
}

function Invoke-ActionDispatch {
  <#
    action_dispatch 的移植。
    返回动作函数的退出码；动作缺失/不支持该动词时返回 2。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ActionVerb,
    [Parameter(Mandatory=$true)][string]$Id
  )
  $action = $script:CAT_ACTION[$Id]
  if ([string]::IsNullOrEmpty($action)) {
    Write-ErrorLog ("[{0}] catalog 未声明 action" -f $Id); return 2
  }
  if (-not (Test-DictHasKey -Dictionary $script:CAT_TYPE -Key $Id)) {
    Write-ErrorLog ("[{0}] 未知工具" -f $Id); return 2
  }

  # 动作函数由 setup.ps1 在入口处全量加载（见 Test-EngineActionLoaded 的说明），
  # 这里只确认脚本存在，给得出明确报错。
  if (-not (Test-EngineActionLoaded -Action $action)) { return 2 }

  $fnName = ('action_{0}_{1}' -f $action, $ActionVerb)
  if (Get-Command -Name $fnName -ErrorAction SilentlyContinue) {
    $rc = & $fnName -Id $Id
    return $rc
  }
  if ($ActionVerb -eq 'status') {
    Show-ConfigStatusFallback -Id $Id
    return 0
  }
  Write-ErrorLog ("[{0}] 动作 {1} 不支持动词 {2}（缺少 {3}）" -f $Id, $action, $ActionVerb, $fnName)
  return 2
}

# ---------------------------------------------------------------------------
# 提权判定与写操作预报
# ---------------------------------------------------------------------------
function Test-NeedsElevation {
  <#
    _engine_needs_sudo 的 Windows 对应物。
    winget 默认 --scope user 不需要提权；只有 sudo=1 的 config 条目
    或 winget machine 域回退时才需要。
  #>
  param([Parameter(Mandatory=$true)][string]$Id)
  if ($script:CAT_TYPE[$Id] -eq 'package') {
    $backend = (Get-CatalogEffective -Id $Id -Field 'Backend')
    if ($backend -eq 'winget') {
      # user 域优先；需要 machine 域时由后端内部处理提权
      return $false
    }
    return $false
  }
  return ($script:CAT_SUDO[$Id] -eq '1')
}

function Test-IsWriteVerb {
  param([Parameter(Mandatory=$true)][string]$Verb)
  return ($Verb -eq 'install' -or $Verb -eq 'update' -or $Verb -eq 'remove')
}

function Test-EngineToolInstalled {
  <# _engine_tool_installed：config 查清单，package 问后端 #>
  param([Parameter(Mandatory=$true)][string]$Id)
  if ($script:CAT_TYPE[$Id] -eq 'config') {
    return (Test-StateHas -Tool $Id)
  }
  $backend = (Get-CatalogEffective -Id $Id -Field 'Backend')
  $fnName = ('Test-{0}BackendInstalled' -f $backend)
  if (-not (Get-Command -Name $fnName -ErrorAction SilentlyContinue)) { return $false }
  return (& $fnName -Id $Id)
}

function Warn-EngineDependents {
  <# _engine_warn_dependents + _engine_warn_external_dependents 的移植 #>
  foreach ($id in $script:GRAPH_ORDER) {
    $dents = @(Get-GraphDependents -Target $id)
    if ($dents.Count -gt 0) {
      Write-WarnLog ("[{0}] 被以下项依赖，它们将先于本项删除：{1}" -f $id, ($dents -join ' '))
    }
  }

  $external = New-Object System.Collections.Generic.List[string]
  $inSet = @{}
  foreach ($x in $script:GRAPH_ORDER) { $inSet[$x] = $true }

  foreach ($id in $script:GRAPH_ORDER) {
    foreach ($dent in $script:CAT_ORDER) {
      if ($dent -eq $id) { continue }
      $deps = @((Get-EffectiveDeps -Id $dent) | Where-Object { $_ -eq $id })
      if ($deps.Count -eq 0) { continue }
      if ((Test-DictHasKey -Dictionary $inSet -Key $dent)) { continue }
      if (-not (Test-EngineToolInstalled -Id $dent)) { continue }
      $external.Add($dent)
    }
  }
  if ($external.Count -gt 0) {
    Write-WarnLog ("以下已安装的工具依赖本次卸载的项，卸载后可能失效：{0}" -f ($external -join ' '))
    Write-WarnLog '如需一并卸载，请把它们一起加入本次选择。'
  }
}

# ---------------------------------------------------------------------------
# 记录配置动作的产物清单
# ---------------------------------------------------------------------------
function Sync-EngineState {
  <# _engine_state_sync 的移植 #>
  param(
    [Parameter(Mandatory=$true)][string]$Verb,
    [Parameter(Mandatory=$true)][string]$Id
  )
  if ($script:CAT_TYPE[$Id] -ne 'config') { return }

  if ($Verb -eq 'install' -or $Verb -eq 'update') {
    $arts = @((Expand-CatalogArtifacts -Raw (Get-CatalogEffective -Id $Id -Field 'Artifacts')) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($arts.Count -eq 0) {
      $null = Set-StateRecord -Tool $Id -Action $script:CAT_ACTION[$Id]
    } else {
      $null = Set-StateRecord -Tool $Id -Action $script:CAT_ACTION[$Id] -Artifacts $arts
    }
  } elseif ($Verb -eq 'remove') {
    $null = Remove-StateRecord -Tool $Id
  }
}

# ---------------------------------------------------------------------------
# 单工具分派
# ---------------------------------------------------------------------------
function Invoke-EngineDispatchVerb {
  <#
    _engine_dispatch_verb 的移植。门顺序必须与 Bash 版一致：
      1. 平台门        → 100
      2. 提权门        → 100
      3. dry-run 门    → 0（planned），不碰盘
      4. package → 后端分派
      5. config  → 动作分派 + state_sync
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Verb,
    [Parameter(Mandatory=$true)][string]$Id
  )

  # 1. 平台门
  if (-not (Test-CatalogPlatformOk -Id $Id)) { return 100 }

  # 2. 提权门
  if ($script:NO_ELEVATE -eq 1 -and (Test-NeedsElevation -Id $Id)) {
    Write-WarnLog ("[{0}] 需要提权，--no-elevate 下跳过" -f $Id)
    return 100
  }

  # 3. dry-run 门
  if ($script:DRY_RUN -eq 1 -and (Test-IsWriteVerb -Verb $Verb)) {
    Write-InfoLog ("[{0}] [dry-run] 将执行 {1}（type={2}）" -f $Id, $Verb, $script:CAT_TYPE[$Id])
    return 0
  }

  # 4. package
  if ($script:CAT_TYPE[$Id] -eq 'package') {
    $rc = Backend-Dispatch -Verb $Verb -Id $Id
    if ($rc -ne 0) { return $rc }
    return 0
  }

  # 5. config
  $averb = Get-EngineActionVerb -Verb $Verb
  if ($null -eq $averb) {
    Write-ErrorLog ("[{0}] 未知动词：{1}" -f $Id, $Verb); return 2
  }
  $rc = Invoke-ActionDispatch -ActionVerb $averb -Id $Id
  if ($rc -ne 0) { return $rc }
  Sync-EngineState -Verb $Verb -Id $Id
  return 0
}

function Invoke-EngineVerifyOrFix {
  <# _engine_verify_or_fix 的移植 #>
  param([Parameter(Mandatory=$true)][string]$Id)

  $rc = Invoke-EngineDispatchVerb -Verb 'verify' -Id $Id
  if ($rc -eq 0 -or $rc -eq 100) { return $rc }
  if ($script:FIX -ne 1 -or $script:DRY_RUN -eq 1) { return $rc }

  Write-WarnLog ("[{0}] 校验未通过（rc={1}），执行 apply 修复" -f $Id, $rc)
  if ((Invoke-EngineDispatchVerb -Verb 'install' -Id $Id) -ne 0) {
    Write-ErrorLog ("[{0}] 修复失败" -f $Id); return 1
  }
  if ((Invoke-EngineDispatchVerb -Verb 'verify' -Id $Id) -ne 0) {
    Write-ErrorLog ("[{0}] 修复后复验仍未通过" -f $Id); return 1
  }
  Write-OkLog ("[{0}] 已修复并通过复验" -f $Id)
  return 0
}

function Invoke-EngineRunOne {
  <# engine_run_one 的移植 #>
  param(
    [Parameter(Mandatory=$true)][string]$Verb,
    [Parameter(Mandatory=$true)][string]$Id
  )
  if ($Verb -eq 'verify' -and $script:FIX -eq 1) {
    return (Invoke-EngineVerifyOrFix -Id $Id)
  }
  return (Invoke-EngineDispatchVerb -Verb $Verb -Id $Id)
}

function Invoke-EngineRun {
  <# engine_run <verb> <id...> 的移植 #>
  param(
    [Parameter(Mandatory=$true)][string]$Verb,
    [Parameter(Mandatory=$true)][string[]]$Ids
  )

  if ($Ids.Count -eq 0) {
    Write-ErrorLog 'engine_run：未提供任何工具'; return 2
  }
  $valid = @('install','update','remove','verify','status')
  if ($valid -notcontains $Verb) {
    Write-ErrorLog ("engine_run：未知动词 {0}" -f $Verb); return 2
  }
  $script:VERB = $Verb

  if (-not (Build-Graph -Ids $Ids)) { return 1 }

  if ($Verb -eq 'remove') {
    Reverse-Graph
    Warn-EngineDependents
  }

  # 计数器重置前先留住顺序（Bash 版同样在重置前拷贝 GRAPH_ORDER）
  $order = New-Object System.Collections.Generic.List[string]
  foreach ($x in $script:GRAPH_ORDER) { $order.Add($x) }

  $script:ENGINE_OK = 0
  $script:ENGINE_SKIPPED = 0
  $script:ENGINE_FAILED = 0
  $failed = New-Object System.Collections.Generic.List[string]
  $skipped = New-Object System.Collections.Generic.List[string]

  Publish-Event -Type 'run_start' -Fragment (
    '"verb":"{0}","dry_run":{1},"phase":"{2}","ids":{3}' -f
    (ConvertTo-JsonLiteral -Text $Verb),
    $(if ($script:DRY_RUN -eq 1) { 'true' } else { 'false' }),
    (ConvertTo-JsonLiteral -Text $Verb),
    (ConvertTo-JsonStringArray -Values @($order))
  )

  Write-SectionLog ("{0}：共 {1} 项（含依赖闭包）" -f $Verb, $order.Count)

  foreach ($id in $order) {
    Write-InfoLog ("[{0}] {1}（type={2}）" -f $id, $script:CAT_DESC[$id], $script:CAT_TYPE[$id])
    Publish-Event -Type 'item_start' -Fragment (
      '"id":"{0}","verb":"{1}","phase":"{2}","type":"{3}"' -f
      (ConvertTo-JsonLiteral -Text $id),
      (ConvertTo-JsonLiteral -Text $Verb),
      (ConvertTo-JsonLiteral -Text $Verb),
      (ConvertTo-JsonLiteral -Text $script:CAT_TYPE[$id])
    )

    $rc = Invoke-EngineRunOne -Verb $Verb -Id $id

    $status = 'failed'
    if ($rc -eq 0) {
      $status = $(if ($script:DRY_RUN -eq 1 -and (Test-IsWriteVerb -Verb $Verb)) { 'planned' } else { 'ok' })
    } elseif ($rc -eq 100) {
      $status = 'skipped'
    }

    Publish-Event -Type 'item_end' -Fragment (
      '"id":"{0}","verb":"{1}","phase":"{2}","type":"{3}","status":"{4}","rc":{5}' -f
      (ConvertTo-JsonLiteral -Text $id),
      (ConvertTo-JsonLiteral -Text $Verb),
      (ConvertTo-JsonLiteral -Text $Verb),
      (ConvertTo-JsonLiteral -Text $script:CAT_TYPE[$id]),
      $status,
      $rc
    )

    if ($status -eq 'ok' -or $status -eq 'planned') {
      $script:ENGINE_OK++
    } elseif ($status -eq 'skipped') {
      $skipped.Add($id)
      $script:ENGINE_SKIPPED++
    } else {
      $failed.Add($id)
      $script:ENGINE_FAILED++
      Write-ErrorLog ("[{0}] {1} 失败（rc={2}）" -f $id, $Verb, $rc)
      if ($script:KEEP_GOING -ne 1) { break }
    }
  }

  Write-SectionLog ("{0} 汇总：成功 {1} / 跳过 {2} / 失败 {3}" -f $Verb, $script:ENGINE_OK, $script:ENGINE_SKIPPED, $script:ENGINE_FAILED)
  if ($skipped.Count -gt 0) { Write-WarnLog ("跳过：{0}" -f ($skipped -join ' ')) }
  if ($failed.Count -gt 0) {
    Write-ErrorLog ("失败：{0}" -f ($failed -join ' '))
    if ($script:KEEP_GOING -eq 1) {
      Write-WarnLog '--keep-going：已跑完其余工具，保留成功项，不触发整体回滚'
    }
    return 1
  }
  return 0
}
