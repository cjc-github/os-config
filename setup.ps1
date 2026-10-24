<#
.SYNOPSIS
  setup.ps1 —— os-config 唯一入口（Windows 引擎，setup.sh 的对应物）
.DESCRIPTION
  解析参数 → 加载 catalog/profile → 解析出工具标识 → 交给 engine 编排。
  本文件不含任何具体工具知识；功能全在 engine/lib-win/ 与 catalog/ 中。

  与 Bash 版的对应关系：
    ./setup.sh install --profile dev      →  .\setup.ps1 install --profile dev
    ./setup.sh --list --json              →  .\setup.ps1 --list --json

  动词与选择参数完全一致，使同一份 profile 与同一条命令在两个平台通用。
  唯一的平台差异是提权开关：Windows 上规范名是 --no-elevate，
  同时接受 --no-sudo 作为别名（共享脚本/CI 里已是这个名字）。

  执行策略：本仓库的 .ps1 都是 UTF-8 with BOM。PowerShell 5.1 会用 ANSI
  代码页读取无 BOM 的脚本，把中文注释与字符串弄花，因此 git clone 后若
  文件丢了 BOM，先执行 Unblock-File 并用 -ExecutionPolicy Bypass 启动。
.NOTES
  退出码：0 成功；1 有失败项；2 参数或数据错误。
#>

[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining = @())

# PowerShell 5.1 默认用 ANSI/OEM 代码页与子进程通信，而 winget 输出 UTF-8。
# 不设这一行，用户看到的每一行 winget 输出都是乱码，测试断言也会失真。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# 定位项目根目录
# ---------------------------------------------------------------------------
$script:ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:OSC_PROJECT_DIR = $script:ProjectDir

# ---------------------------------------------------------------------------
# 加载库（顺序与 setup.sh 的 source 顺序对应）
# ---------------------------------------------------------------------------
. (Join-Path $script:ProjectDir 'engine\lib-win\Log.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Util.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Events.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Catalog.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Profile.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Graph.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\State.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Rollback.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Backends.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Engine.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Doctor.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Export.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\ListJson.ps1')

# ---------------------------------------------------------------------------
# 加载配置动作脚本（catalog 里 action=xxx 对应的 engine\actions-win\xxx.ps1）
#
# 为什么必须在这里全量加载、而不是在引擎里按需点源：PowerShell 在**函数内**
# 点源（. file）定义的函数只存在于该函数自己的作用域，函数返回即消失
# （实测文件与 scriptblock 两种形式都不行）。Bash 的 source 没有这层作用域
# 问题，因此 Bash 版 _engine_source_action 的惰性加载无法照搬——照搬后
# 分派时找不到 action_<x>_<verb>，apply/remove/verify 报"不支持动词"、
# status 静默回退，config 动作层整体失效且无显式错误。
# foreach 循环不产生新作用域，点源进脚本作用域，对所有函数可见。
# ---------------------------------------------------------------------------
$actionFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir 'engine\actions-win') `
                  -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
foreach ($af in $actionFiles) { . $af.FullName }

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
$script:DEBUG = 0
$script:FORCE = 0
$script:DRY_RUN = 0
$script:KEEP_GOING = 0
$script:NO_ELEVATE = 0
$script:ASSUME_YES = 0
$script:FIX = 0
$script:OUTPUT_SET = 0

$Verb = 'install'
$ProfileName = ''
$Pick = ''
$All = 0
$ListOnly = 0
$JsonOnly = 0
$ExportOutput = ''

function Show-Usage {
  Write-Host @'
os-config —— 声明式软件与配置管理（Windows 引擎）

用法：
  .\setup.ps1 [动词] [选择] [选项]

动词（默认 install）：
  install   安装/应用选中项（含依赖闭包，依赖优先）
  update    更新选中项（尽力而为）
  remove    卸载/还原选中项（依赖逆序，配置类先还原）
  verify    校验选中项是否符合预期；加 --fix 会自动修复偏差
  status    显示选中项当前状态
  export    扫描当前机器，把已装工具与已应用配置导出为 profile
  doctor    环境体检（提权/磁盘/命令/winget/代理/清单一致性），只读

选择（三选一，默认使用 profile "default"；export/doctor 不需要选择）：
  --profile <名字>          使用 profiles/ 中的配置清单
  --pick <a,b,@组,winget:X> 临时指定；支持 @分组 与 后端:包 内联写法
  --all                     选择 catalog 中全部工具

选项：
  --list          列出 catalog 工具与可用 profile，然后退出
  --json          与 --list 连用，输出 JSON（供 Web UI 读取）
  --dry-run       只打印计划，不做写操作
  --force         忽略幂等判断，强制重做
  --fix           与 verify 连用：校验未通过时自动 apply 修复后复验
  --keep-going    单项失败不中断，跑完再汇总（不触发回滚）
  --no-elevate    跳过需要提权的项（别名：--no-sudo）
  --yes           非交互确认（自动回答 y）
  --output        与 export 连用，指定导出的 profile 路径
  --debug         输出调试日志
  -h, --help      本帮助

示例：
  .\setup.ps1 --list
  .\setup.ps1 doctor
  .\setup.ps1 --dry-run
  .\setup.ps1 install --profile ai
  .\setup.ps1 verify --pick git,ssh
  .\setup.ps1 verify --fix --profile default
  .\setup.ps1 export
  .\setup.ps1 export --output profiles\work.conf
  .\setup.ps1 remove --pick winget:jqlang.jq
'@
}

$args_ = @($Remaining)
$i = 0
while ($i -lt $args_.Count) {
  $a = $args_[$i]
  switch -Regex ($a) {
    '^(install|update|remove|verify|status|export|doctor)$' { $Verb = $a }
    '^--profile$' {
      if ($i + 1 -ge $args_.Count) { Write-ErrorLog '--profile 需要一个参数'; Show-Usage; exit 2 }
      $ProfileName = $args_[++$i]
    }
    '^--pick$' {
      if ($i + 1 -ge $args_.Count) { Write-ErrorLog '--pick 需要一个参数'; Show-Usage; exit 2 }
      $Pick = $args_[++$i]
    }
    '^--output$' {
      if ($i + 1 -ge $args_.Count) { Write-ErrorLog '--output 需要一个参数'; Show-Usage; exit 2 }
      $ExportOutput = $args_[++$i]; $script:OUTPUT_SET = 1
    }
    '^--all$'      { $All = 1 }
    '^--list$'     { $ListOnly = 1 }
    '^--json$'     { $JsonOnly = 1 }
    '^--dry-run$'  { $script:DRY_RUN = 1 }
    '^--force$'    { $script:FORCE = 1 }
    '^--fix$'      { $script:FIX = 1 }
    '^--keep-going$' { $script:KEEP_GOING = 1 }
    '^--no-elevate$'  { $script:NO_ELEVATE = 1 }
    '^--no-sudo$'     { $script:NO_ELEVATE = 1 }   # 别名，保持跨平台命令一致
    '^--yes$'      { $script:ASSUME_YES = 1 }
    '^--debug$'    { $script:DEBUG = 1 }
    '^(-h|--help)$' { Show-Usage; exit 0 }
    default {
      Write-ErrorLog ("未知参数：{0}" -f $a)
      Show-Usage
      exit 2
    }
  }
  $i++
}

if ($script:FIX -eq 1 -and $Verb -ne 'verify') {
  Write-ErrorLog '--fix 只能与 verify 一起用'
  exit 2
}
if ($script:FIX -eq 1 -and $script:DRY_RUN -eq 1) {
  Write-WarnLog '--dry-run 下 --fix 不生效（不会做任何修复）'
}
if ($script:OUTPUT_SET -eq 1 -and $Verb -ne 'export') {
  Write-ErrorLog '--output 只能与 export 一起用'
  exit 2
}

$selCount = 0
if ($All -eq 1) { $selCount++ }
if (-not [string]::IsNullOrEmpty($Pick)) { $selCount++ }
if (-not [string]::IsNullOrEmpty($ProfileName)) { $selCount++ }
if ($selCount -gt 1) {
  Write-ErrorLog '--profile / --pick / --all 只能选一个'
  exit 2
}
if ($JsonOnly -eq 1 -and $ListOnly -ne 1) {
  Write-ErrorLog '--json 必须与 --list 一起使用'
  exit 2
}

# ---------------------------------------------------------------------------
# 日志与状态路径
# ---------------------------------------------------------------------------
$logDir = Join-Path $script:ProjectDir 'logs'
if (-not (Test-Path -LiteralPath $logDir)) {
  try { $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop } catch { }
}
$logFile = Join-Path $logDir ("setup-{0}.{1}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $PID)
Initialize-LogFile -Path $logFile

Initialize-StatePaths -Dir $env:OSC_STATE_DIR
$script:EventsFile = $env:OS_CONFIG_EVENTS

Import-UserConfig -ProjectDir $script:ProjectDir

# ---------------------------------------------------------------------------
# 加载数据层
# ---------------------------------------------------------------------------
if (-not (Import-Catalog)) {
  Write-ErrorLog 'catalog 加载失败'
  exit 1
}

$profileOk = Import-Profile
if (-not $profileOk) {
  if ($ListOnly -ne 1 -and [string]::IsNullOrEmpty($Pick) -and $All -ne 1) {
    Write-ErrorLog 'profiles 加载失败，已中止'
    exit 1
  }
  Write-WarnLog 'profiles 目录不可用（--pick/--all 仍可用）'
}

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if ($ListOnly -eq 1) {
  if ($JsonOnly -eq 1) {
    Write-Host (Export-ListJson)
    exit 0
  }
  Write-Host ''
  Write-Host '工具目录（catalog\*.catalog）'
  Write-Host ('  {0,-14} {1,-10} {2,-22} {3,-16} {4}' -f 'ID','GROUP','TYPE','DEPS','DESC')
  foreach ($id in $script:CAT_ORDER) {
    $t = $script:CAT_TYPE[$id]
    if ($t -eq 'package') { $t = 'package/' + $script:CAT_BACKEND[$id] }
    $deps = $script:CAT_DEPS[$id]
    if ([string]::IsNullOrEmpty($deps)) { $deps = '-' }
    $desc = $script:CAT_DESC[$id]
    if ([string]::IsNullOrEmpty($desc)) { $desc = '-' }
    Write-Host ('  {0,-14} {1,-10} {2,-22} {3,-16} {4}' -f $id, $script:CAT_GROUP[$id], $t, $deps, $desc)
  }
  if ($script:PROF_ORDER.Count -gt 0) {
    Write-Host ''
    Write-Host '配置清单（profiles\*.conf）'
    Write-Host ('  {0,-14} {1}' -f 'NAME','DESC')
    foreach ($name in $script:PROF_ORDER) {
      $d = $script:PROF_DESC[$name]
      if ([string]::IsNullOrEmpty($d)) { $d = '-' }
      Write-Host ('  {0,-14} {1}' -f $name, $d)
    }
  }
  Write-Host ''
  Write-Host '用法：.\setup.ps1 [install|update|remove|verify|status|export|doctor] --profile <名字> [--dry-run]'
  Write-Host ''
  exit 0
}

# ---------------------------------------------------------------------------
# doctor / export：不需要选择
# ---------------------------------------------------------------------------
if ($Verb -eq 'doctor') {
  if ($script:DRY_RUN -eq 1) {
    Write-WarnLog 'doctor 本身就是只读，--dry-run 无意义（忽略）'
  }
  if ((Invoke-DoctorRun) -eq 0) {
    Write-OkLog 'doctor 完成'
    exit 0
  } else {
    Write-ErrorLog 'doctor 发现未通过项'
    exit 1
  }
}

if ($Verb -eq 'export') {
  # Export-ProfileRun 返回 int 退出码（0=成功）；PowerShell 里 0 是假值，
  # 不能写 `-not (Export-ProfileRun ...)`，否则成功也会退出 1。
  $exportRc = Export-ProfileRun -OutputPath $ExportOutput
  if ($exportRc -ne 0) { exit 1 }
  exit 0
}

# ---------------------------------------------------------------------------
# 解析选择 → SELECTED_TOOLS
# ---------------------------------------------------------------------------
$selected = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrEmpty($Pick)) {
  Register-CliProfile -Pick $Pick
  if (-not (Resolve-Profile -Name 'cli')) { exit 2 }
  foreach ($t in $script:SELECTED_TOOLS) { $selected.Add($t) }
} elseif ($All -eq 1) {
  foreach ($t in $script:CAT_ORDER) { $selected.Add($t) }
} elseif (-not [string]::IsNullOrEmpty($ProfileName)) {
  if (-not (Resolve-Profile -Name $ProfileName)) { exit 2 }
  foreach ($t in $script:SELECTED_TOOLS) { $selected.Add($t) }
} else {
  if (-not (Resolve-Profile -Name 'default')) {
    Write-ErrorLog '默认 profile 不可用；请用 --profile/--pick/--all 指定选择'
    exit 2
  }
  foreach ($t in $script:SELECTED_TOOLS) { $selected.Add($t) }
}

if ($selected.Count -eq 0) {
  Write-ErrorLog '未选择任何工具'
  exit 2
}

# ---------------------------------------------------------------------------
# 写操作预判：需要写锁与快照
# ---------------------------------------------------------------------------
function Test-NeedsWriteLock {
  if ($script:DRY_RUN -eq 1) { return $false }
  switch ($Verb) {
    'install' { return $true }
    'update'  { return $true }
    'remove'  { return $true }
    'verify'  { if ($script:FIX -eq 1) { return $true } return $false }
    default   { return $false }
  }
}

# ---------------------------------------------------------------------------
# 主流程（try/finally 保证清理不改写退出码）
# ---------------------------------------------------------------------------
$script:ExitCode = 0
$tookLock = $false
$tookSnapshot = $false

try {
  if (Test-NeedsWriteLock) {
    if (-not (Initialize-State)) {
      Write-ErrorLog ("无法初始化状态目录：{0}" -f $script:StateDir)
      $script:ExitCode = 1
    } else {
      $lockRc = Grant-StateLock
      if ($lockRc -ne 0) {
        $script:ExitCode = 1
      } else {
        $tookLock = $true
        if (-not (Save-StateSnapshot)) {
          Write-ErrorLog '无法记录运行前清单快照，已中止'
          $script:ExitCode = 1
        } else {
          $tookSnapshot = $true
        }
      }
    }
  }

  if ($script:ExitCode -eq 0) {
    Write-SectionLog ("os-config {0}" -f $Verb)
    Write-InfoLog ("PROJECT_DIR = {0}" -f $script:ProjectDir)
    Write-InfoLog ("LOG_FILE    = {0}" -f (Get-LogPath))
    Write-InfoLog ("选择        = {0} 项：{1}" -f $selected.Count, ($selected -join ' '))
    if ($script:DRY_RUN -eq 1) { Write-WarnLog 'dry-run：不做任何写操作' }
    if ($script:NO_ELEVATE -eq 1) { Write-WarnLog 'no-elevate：将跳过需要提权的项' }

    $rc = Invoke-EngineRun -Verb $Verb -Ids @($selected)
    if ($rc -eq 0) {
      Write-OkLog ("{0} 完成（日志：{1}）" -f $Verb, (Get-LogPath))
      $script:ExitCode = 0
    } else {
      Write-ErrorLog ("{0} 未全部成功（日志：{1}）" -f $Verb, (Get-LogPath))
      $script:ExitCode = 1
    }
  }
}
finally {
  # 顺序与 setup.sh 的 EXIT trap 一致：先回滚（保留原退出码），
  # 再释放锁，最后发 run_end。
  $null = Invoke-RollbackOnExit -Rc $script:ExitCode
  if ($tookLock) { Release-StateLock }
  Publish-Event -Type 'run_end' -Fragment (
    '"verb":"{0}","phase":"{1}","ok":{2},"skipped":{3},"failed":{4},"rc":{5},"rolled_back":{6}' -f
    (ConvertTo-JsonLiteral -Text $Verb),
    (ConvertTo-JsonLiteral -Text $Verb),
    $script:ENGINE_OK, $script:ENGINE_SKIPPED, $script:ENGINE_FAILED,
    $script:ExitCode,
    $(if ($script:ROLLBACK_PERFORMED -eq 1) { 'true' } else { 'false' })
  )
  if (-not $tookSnapshot) { Discard-StateSnapshot }
  exit $script:ExitCode
}
