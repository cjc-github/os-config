#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Catalog.ps1 —— catalog 数据层解析器（engine/lib/catalog.sh 的移植）
.DESCRIPTION
  把 catalog/*.catalog 解析进一组有序映射。纯数据，不执行任何安装。

  与 Bash 版的两个关键差异：

  1. 集合类型。PowerShell 的 @{} 哈希表枚举顺序是任意的（实测：按 z,a,m 插入，
     按 a,m,z 读出），因此凡顺序有意义的一律用 [ordered]@{} 或 List[string]。
     $script:CAT_ORDER / $script:GRAPH_ORDER / $script:PROF_ORDER 都是 List[string]，
     其余 CAT_* 是 [ordered]@{}（既保序又能按键查）。
  2. 平台字段。Windows 引擎读 CAT_PLATFORMS / CAT_WIN_*；Bash 引擎只解析不校验。
     缺少 platforms 的条目默认 linux，在本引擎中被视为不适用。
#>

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# 数据层状态
# ---------------------------------------------------------------------------
$script:CAT_ORDER = New-Object System.Collections.Generic.List[string]
$script:CAT_TYPE = [ordered]@{}
$script:CAT_BACKEND = [ordered]@{}
$script:CAT_PACKAGES = [ordered]@{}
$script:CAT_VERSION = [ordered]@{}
$script:CAT_COMMANDS = [ordered]@{}
$script:CAT_TRACK = [ordered]@{}
$script:CAT_DEPS = [ordered]@{}
$script:CAT_DESC = [ordered]@{}
$script:CAT_GROUP = [ordered]@{}
$script:CAT_ACTION = [ordered]@{}
$script:CAT_ARTIFACTS = [ordered]@{}
$script:CAT_SUDO = [ordered]@{}
$script:CAT_PLATFORMS = [ordered]@{}
$script:CAT_WIN_BACKEND = [ordered]@{}
$script:CAT_WIN_PACKAGES = [ordered]@{}
$script:CAT_WIN_COMMANDS = [ordered]@{}
$script:CAT_WIN_VERSION = [ordered]@{}
$script:CAT_WIN_ARTIFACTS = [ordered]@{}
$script:CAT_WIN_DEPS = [ordered]@{}
$script:CAT_WIN_ACTION = [ordered]@{}

$script:CATALOG_DIR = ''

function Reset-Catalog {
  $script:CAT_ORDER = New-Object System.Collections.Generic.List[string]
  foreach ($name in @('CAT_TYPE','CAT_BACKEND','CAT_PACKAGES','CAT_VERSION','CAT_COMMANDS',
                      'CAT_TRACK','CAT_DEPS','CAT_DESC','CAT_GROUP','CAT_ACTION',
                      'CAT_ARTIFACTS','CAT_SUDO','CAT_PLATFORMS','CAT_WIN_BACKEND',
                      'CAT_WIN_PACKAGES','CAT_WIN_COMMANDS','CAT_WIN_VERSION',
                      'CAT_WIN_ARTIFACTS','CAT_WIN_DEPS','CAT_WIN_ACTION')) {
    Set-Variable -Name $name -Scope Script -Value ([ordered]@{}) -Force
  }
}

function Test-CatalogIdValid {
  param([string]$Id)
  return ($Id -match '^[a-z0-9][a-z0-9_-]*$')
}

function Test-CatalogPkgSpecValid {
  <# 包名会做词拆分后传给 winget/npm：不得含空白，也不得以 - 开头 #>
  param([string]$Spec)
  if ([string]::IsNullOrEmpty($Spec)) { return $false }
  return ($Spec -match '^[A-Za-z0-9@][A-Za-z0-9._+/@=:~-]*$')
}

function Expand-CatalogVars {
  <#
    catalog_expand_vars 的移植：支持 $VAR、${VAR}、${VAR:-默认值}。
    未定义或为空的变量取默认值；只识别 $VAR 形式，文案里的单个 $ 不会被误吞。
    对应 catalog.sh:24-38 的正则循环。

    HOME 特例：catalog 是跨平台共享的，win_artifacts 里写的是 ${HOME}
    （Bash 拼写）。Windows 进程环境里通常只有 USERPROFILE 没有 HOME，
    直接查表会得到空串、把路径静默吃掉，因此 HOME 回落到 $script:HomeDir
    （Util.ps1 加载时算好的用户主目录）。
  #>
  param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Raw)

  $out = New-Object System.Text.StringBuilder
  $i = 0
  while ($i -lt $Raw.Length) {
    $c = $Raw[$i]
    if ($c -ne '$') { $null = $out.Append($c); $i++; continue }

    # $${...} 或 $VAR
    $rest = $Raw.Substring($i + 1)
    if ($rest.StartsWith('{')) {
      $close = $rest.IndexOf('}')
      if ($close -lt 0) { $null = $out.Append($c); $i++; continue }
      $inner = $rest.Substring(1, $close - 1)
      $name = $inner; $def = ''
      $sep = $inner.IndexOf(':-')
      if ($sep -ge 0) {
        $name = $inner.Substring(0, $sep)
        $def = $inner.Substring($sep + 2)
      }
      if ($name -match '^[A-Za-z_][A-Za-z0-9_]*$') {
        $val = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($val) -and $name -eq 'HOME') { $val = $script:HomeDir }
        if ([string]::IsNullOrEmpty($val)) { $val = $def }
        $null = $out.Append($val)
        $i = $i + 1 + $close + 1
        continue
      }
      $null = $out.Append($c); $i++; continue
    }

    $m = [regex]::Match($rest, '^([A-Za-z_][A-Za-z0-9_]*)')
    if ($m.Success) {
      $name = $m.Groups[1].Value
      $val = [Environment]::GetEnvironmentVariable($name)
      if ([string]::IsNullOrEmpty($val) -and $name -eq 'HOME') { $val = $script:HomeDir }
      if ($null -eq $val) { $val = '' }
      $null = $out.Append($val)
      $i = $i + 1 + $name.Length
      continue
    }
    $null = $out.Append($c); $i++
  }
  return $out.ToString()
}

function Get-PowerShellProfilePath {
  <#
    解析 ${PSPROFILE}。生产环境优先用 $PROFILE（自动兼容 Documents 被 OneDrive
    重定向）；测试环境 $HomeDir 被改到临时目录、$PROFILE 不匹配时回落到派生路径，
    绝不写真实 profile。
  #>
  $derived = Join-Path $script:HomeDir 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
  if ($PROFILE -and $PROFILE.StartsWith($script:HomeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $PROFILE
  }
  return $derived
}

function Expand-CatalogArtifacts {
  <#
    catalog_expand_artifacts 的移植：展开变量、把行首 ~ 换算为 $HomeDir，
    每个产物输出一个路径。artifacts / win_artifacts 都走这里（只在使用时展开一次）。
    额外支持 ${PSPROFILE}，因为 Documents 可能被 OneDrive 重定向，
    在 catalog 里写死路径会对不上实际写入的文件。

    拆分时机必须与 Bash 版一致：Bash 是 `for path in ${CAT_ARTIFACTS[$id]}`
    ——先对原始值做词拆分，再逐词展开。顺序不能反：$HOME 可能含空格
    （C:\Users\John Doe），展开后再拆会把一个路径劈成两个；而 catalog 里
    `artifacts=~/.gitconfig ~/.config/git/config` 这种同行多路径本来就依赖
    词拆分。曾按换行拆分的实现会把整行当成一个产物，第二个 ~ 也不展开。
  #>
  param(
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Raw
  )
  if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }

  $result = New-Object System.Collections.Generic.List[string]
  foreach ($tok in ($Raw -split '\s+' | Where-Object { $_ -ne '' })) {
    # ${PSPROFILE} 必须在 Expand-CatalogVars 之前替换：后者只认环境变量，
    # 会把 ${PSPROFILE} 当成未定义变量吞掉（替换成空串），事后再替换就永远
    # 匹配不上，proxy 的产物会静默变成空。
    $p = $tok
    if ($p.Contains('${PSPROFILE}')) {
      $p = $p.Replace('${PSPROFILE}', (Get-PowerShellProfilePath))
    }
    $p = Expand-CatalogVars -Raw $p
    if ($p.StartsWith('~')) {
      if ($p.Length -eq 1) { $p = $script:HomeDir }
      elseif ($p[1] -eq '\' -or $p[1] -eq '/') { $p = Join-Path $script:HomeDir $p.Substring(2) }
    }
    if (-not [string]::IsNullOrWhiteSpace($p)) { $result.Add($p) }
  }
  return $result
}

function Register-CatalogAdhoc {
  <#
    catalog_define_adhoc 的移植：为内联（winget:xxx / apt:xxx）工具注册条目。
    同名 id 已存在且 backend/packages 一致时幂等返回 0。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][string]$Backend,
    [Parameter(Mandatory=$true)][string]$Packages,
    [string]$Commands = '',
    [string]$Desc = '临时指定'
  )
  if (-not (Test-CatalogIdValid -Id $Id)) {
    Write-ErrorLog ("临时工具 {0} 的标识非法" -f $Id); return 1
  }
  if (-not (Test-CatalogPkgSpecValid -Spec $Packages)) {
    Write-ErrorLog ("临时工具 {0} 的包名非法：{1}（不得含空白或以 - 开头）" -f $Id, $Packages); return 1
  }
  if ((Test-DictHasKey -Dictionary $script:CAT_TYPE -Key $Id)) {
    if ($script:CAT_TYPE[$Id] -eq 'package' -and
        $script:CAT_BACKEND[$Id] -eq $Backend -and
        $script:CAT_PACKAGES[$Id] -eq $Packages) {
      return 0
    }
    Write-ErrorLog ("临时工具 {0} 与已有 catalog 条目冲突" -f $Id)
    return 1
  }

  $script:CAT_ORDER.Add($Id)
  $script:CAT_TYPE[$Id] = 'package'
  $script:CAT_BACKEND[$Id] = $Backend
  $script:CAT_PACKAGES[$Id] = $Packages
  $script:CAT_VERSION[$Id] = ''
  $script:CAT_COMMANDS[$Id] = $Commands
  $script:CAT_TRACK[$Id] = 'latest'
  $script:CAT_DEPS[$Id] = ''
  $script:CAT_DESC[$Id] = $Desc
  $script:CAT_GROUP[$Id] = 'adhoc'
  $script:CAT_ACTION[$Id] = ''
  $script:CAT_ARTIFACTS[$Id] = ''
  $script:CAT_SUDO[$Id] = '0'
  # 内联条目在两个平台都可用：用户在 Windows 上手写 winget:xxx 是常见用法。
  # 必须是空格分隔：Import-CatalogFile 把 platforms 的逗号规范化成空格，
  # Test-CatalogPlatformOk 按空白分词匹配。这里写逗号会让分词结果只有
  # 一个 "linux,win"（既不等于 win 也不等于 linux），内联工具在两个
  # 引擎上都被平台门静默跳过。
  $script:CAT_PLATFORMS[$Id] = 'linux win'
  $script:CAT_WIN_BACKEND[$Id] = $Backend
  $script:CAT_WIN_PACKAGES[$Id] = $Packages
  $script:CAT_WIN_COMMANDS[$Id] = $Commands
  $script:CAT_WIN_VERSION[$Id] = ''
  $script:CAT_WIN_ARTIFACTS[$Id] = ''
  $script:CAT_WIN_DEPS[$Id] = ''
  $script:CAT_WIN_ACTION[$Id] = ''
  return 0
}

function Import-CatalogFile {
  <#
    catalog_load_file 的移植。注意：
    * 注释是 ${raw%%#*}——行内 # 之后全部丢弃，与 Bash 一致。
    * desc/group/artifacts/win_artifacts 不做变量展开（使用时才展开一次）。
  #>
  param([Parameter(Mandatory=$true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-ErrorLog ("catalog 文件不存在：{0}" -f $Path); return 1
  }

  $id = ''
  $lineNo = 0
  $seenKey = @{}

  try { $rawLines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop }
  catch { Write-ErrorLog ("无法读取 catalog 文件：{0}" -f $Path); return 1 }

  foreach ($raw in $rawLines) {
    $lineNo++
    $hashIdx = $raw.IndexOf('#')
    if ($hashIdx -ge 0) { $line = $raw.Substring(0, $hashIdx) } else { $line = $raw }
    $line = $line.Trim()
    if ($line -eq '') { continue }

    if ($line -match '^\[([^\]]+)\]$') {
      $id = $Matches[1].Trim()
      if (-not (Test-CatalogIdValid -Id $id)) {
        Write-ErrorLog ("catalog 非法工具标识：{0}:{1}（{2}）" -f $Path, $lineNo, $id); return 1
      }
      if ((Test-DictHasKey -Dictionary $script:CAT_TYPE -Key $id)) {
        Write-ErrorLog ("catalog 工具重复定义：{0}（{1}:{2}）" -f $id, $Path, $lineNo); return 1
      }
      $script:CAT_ORDER.Add($id)
      $script:CAT_TYPE[$id] = 'package'
      $script:CAT_BACKEND[$id] = ''
      $script:CAT_PACKAGES[$id] = ''
      $script:CAT_VERSION[$id] = ''
      $script:CAT_COMMANDS[$id] = ''
      $script:CAT_TRACK[$id] = 'latest'
      $script:CAT_DEPS[$id] = ''
      $script:CAT_DESC[$id] = ''
      $script:CAT_GROUP[$id] = 'misc'
      $script:CAT_ACTION[$id] = ''
      $script:CAT_ARTIFACTS[$id] = ''
      $script:CAT_SUDO[$id] = '0'
      # 缺省 linux：未声明 platforms 的条目在 Windows 上不适用
      $script:CAT_PLATFORMS[$id] = 'linux'
      $script:CAT_WIN_BACKEND[$id] = ''
      $script:CAT_WIN_PACKAGES[$id] = ''
      $script:CAT_WIN_COMMANDS[$id] = ''
      $script:CAT_WIN_VERSION[$id] = ''
      $script:CAT_WIN_ARTIFACTS[$id] = ''
      $script:CAT_WIN_DEPS[$id] = ''
      $script:CAT_WIN_ACTION[$id] = ''
      $seenKey = @{}
      continue
    }

    if ($id -eq '') {
      Write-ErrorLog ("catalog 键值出现在任何 [工具] 段之前：{0}:{1}" -f $Path, $lineNo); return 1
    }
    $eq = $line.IndexOf('=')
    if ($eq -lt 0) {
      Write-ErrorLog ("catalog 格式错误：{0}:{1}（应为 key=value）" -f $Path, $lineNo); return 1
    }

    $key = $line.Substring(0, $eq).Trim()
    $value = $line.Substring($eq + 1).Trim()

    switch ($key) {
      'desc'          { }
      'group'         { }
      'artifacts'     { }
      'win_artifacts' { }
      default         { $value = Expand-CatalogVars -Raw $value }
    }

    if ((Test-DictHasKey -Dictionary $seenKey -Key $key)) {
      Write-ErrorLog ("catalog 键重复：{0}:{1}（{2}.{3}）" -f $Path, $lineNo, $id, $key); return 1
    }
    $seenKey[$key] = $true

    switch ($key) {
      'type'          { $script:CAT_TYPE[$id] = $value }
      'backend'       { $script:CAT_BACKEND[$id] = $value }
      'packages'      { $script:CAT_PACKAGES[$id] = $value }
      'version'       { $script:CAT_VERSION[$id] = $value }
      'commands'      { $script:CAT_COMMANDS[$id] = $value }
      'track'         { $script:CAT_TRACK[$id] = $value }
      'deps'          { $script:CAT_DEPS[$id] = ($value -replace ',', ' ').Trim() }
      'desc'          { $script:CAT_DESC[$id] = $value }
      'group'         { $script:CAT_GROUP[$id] = $value }
      'action'        { $script:CAT_ACTION[$id] = $value }
      'artifacts'     { $script:CAT_ARTIFACTS[$id] = $value }
      'sudo'          { $script:CAT_SUDO[$id] = $value }
      'platforms'     { $script:CAT_PLATFORMS[$id] = ($value -replace ',', ' ').Trim() }
      'win_backend'   { $script:CAT_WIN_BACKEND[$id] = $value }
      'win_packages'  { $script:CAT_WIN_PACKAGES[$id] = $value }
      'win_commands'  { $script:CAT_WIN_COMMANDS[$id] = $value }
      'win_version'   { $script:CAT_WIN_VERSION[$id] = $value }
      'win_artifacts' { $script:CAT_WIN_ARTIFACTS[$id] = $value }
      'win_deps'      { $script:CAT_WIN_DEPS[$id] = ($value -replace ',', ' ').Trim() }
      'win_action'    { $script:CAT_WIN_ACTION[$id] = $value }
      default {
        Write-ErrorLog ("catalog 未知字段：{0}:{1}（{2}.{3}）" -f $Path, $lineNo, $id, $key); return 1
      }
    }
  }
  return 0
}

function Test-CatalogBackendSupported {
  <#
    Windows 侧实现的后端白名单，与 engine/lib/backends.sh 的
    BACKEND_SUPPORTED 中的 winget/builtin/npm 对应。
  #>
  param([string]$Backend)
  switch ($Backend) {
    'winget'   { return $true }
    'builtin'  { return $true }
    'npm'      { return $true }
    default    { return $false }
  }
}

function Assert-CatalogValid {
  <#
    catalog_validate 的移植。逐条对应 Bash 版的校验规则。
  #>
  $winBackends = @('winget','builtin','npm')

  foreach ($id in $script:CAT_ORDER) {
    $type = $script:CAT_TYPE[$id]
    $plats = $script:CAT_PLATFORMS[$id]
    if ([string]::IsNullOrEmpty($plats)) { $plats = 'linux' }
    $platTokens = @($plats -split '\s+' | Where-Object { $_ -ne '' })
    $onWindows = ($platTokens -contains 'win')
    # 有效后端 = win_backend ?: backend。catalog 是跨平台共享的，条目写
    # backend=apt + win_backend=builtin 完全合法。
    $effBackend = (Get-CatalogEffective -Id $id -Field 'Backend')

    if ($type -eq 'package') {
      # 只有"在本平台可用"的条目才校验后端。Linux 专属条目（platforms=linux）
      # 的 backend=apt 在 Windows 上没有意义，不该按 Windows 白名单判非法——
      # 它们会在分派时被平台门跳过。
      if ($onWindows) {
        if (-not (Test-CatalogBackendSupported -Backend $effBackend)) {
          Write-ErrorLog ("catalog [{0}] 有效 backend 非法：{1}（应为 winget/builtin/npm）" -f $id, $(if ($effBackend) { $effBackend } else { '<空>' }))
          return $false
        }
        if ([string]::IsNullOrEmpty($script:CAT_PACKAGES[$id])) {
          Write-ErrorLog ("catalog [{0}] 缺少 packages" -f $id); return $false
        }
      }
    } elseif ($type -eq 'config') {
      $action = $script:CAT_ACTION[$id]
      if ([string]::IsNullOrEmpty($action)) {
        Write-ErrorLog ("catalog [{0}] 缺少 action" -f $id); return $false
      }
      # action 会拼进 engine/actions-win/<action>.ps1 路径；限制为标识符以防路径穿越
      if ($action -notmatch '^[a-z][a-z0-9_-]*$') {
        Write-ErrorLog ("catalog [{0}] action 非法：{1}（仅允许小写字母、数字、_、-）" -f $id, $action); return $false
      }
    } else {
      Write-ErrorLog ("catalog [{0}] type 非法：{1}（应为 package/config）" -f $id, $type); return $false
    }

    # track 只能是 latest/pin；pin 时必须有 version
    $track = $script:CAT_TRACK[$id]
    if ($track -ne 'latest' -and $track -ne 'pin') {
      Write-ErrorLog ("catalog [{0}] track 非法：{1}（应为 latest/pin）" -f $id, $track); return $false
    }
    if ($track -eq 'pin' -and [string]::IsNullOrEmpty($script:CAT_VERSION[$id])) {
      Write-ErrorLog ("catalog [{0}] track=pin 但缺少 version" -f $id); return $false
    }

    # deps / win_deps 必须指向已定义工具
    foreach ($dep in ($script:CAT_DEPS[$id] -split '\s+' | Where-Object { $_ -ne '' })) {
      if (-not (Test-DictHasKey -Dictionary $script:CAT_TYPE -Key $dep)) {
        Write-ErrorLog ("catalog [{0}] deps 指向不存在的工具：{1}" -f $id, $dep); return $false
      }
    }
    foreach ($dep in ($script:CAT_WIN_DEPS[$id] -split '\s+' | Where-Object { $_ -ne '' })) {
      if (-not (Test-DictHasKey -Dictionary $script:CAT_TYPE -Key $dep)) {
        Write-ErrorLog ("catalog [{0}] win_deps 指向不存在的工具：{1}" -f $id, $dep); return $false
      }
    }

    # platforms 值域（$plats 已在函数开头规范化，逗号已换成空格）
    foreach ($p in $platTokens) {
      if ($p -ne 'linux' -and $p -ne 'win') {
        Write-ErrorLog ("catalog [{0}] platforms 非法：{1}（应为 linux/win/linux,win）" -f $id, $plats); return $false
      }
    }

    # win_backend 若非空必须在本引擎实现的后端之内
    $wb = $script:CAT_WIN_BACKEND[$id]
    if (-not [string]::IsNullOrEmpty($wb) -and ($winBackends -notcontains $wb)) {
      Write-ErrorLog ("catalog [{0}] win_backend 非法：{1}（应为 winget/builtin/npm）" -f $id, $wb); return $false
    }

    # win_action 与 action 同一套标识符规则
    $wa = $script:CAT_WIN_ACTION[$id]
    if (-not [string]::IsNullOrEmpty($wa) -and $wa -notmatch '^[a-z][a-z0-9_-]*$') {
      Write-ErrorLog ("catalog [{0}] win_action 非法：{1}" -f $id, $wa); return $false
    }

    # platforms 含 win 时，package 条目必须能在 Windows 上落地：
    #   npm     —— 用共享的 packages，不需要任何 win_* 字段
    #   builtin —— 系统自带，只需要 win_backend=builtin，没有包 id
    #   winget  —— 必须同时给出 win_backend 与 win_packages（包 id 与 apt 包名不同）
    $platTokens = @($plats -split '\s+' | Where-Object { $_ -ne '' })
    if ($platTokens -contains 'win' -and $type -eq 'package') {
      if ($effBackend -eq 'winget') {
        if ([string]::IsNullOrEmpty($wb)) {
          Write-ErrorLog ("catalog [{0}] platforms 含 win 且有效 backend={1}，缺少 win_backend" -f $id, $effBackend); return $false
        }
        if ([string]::IsNullOrEmpty($script:CAT_WIN_PACKAGES[$id])) {
          Write-ErrorLog ("catalog [{0}] 声明了 win_backend=winget 但缺少 win_packages" -f $id); return $false
        }
      } elseif ($effBackend -eq 'builtin') {
        if ([string]::IsNullOrEmpty($wb)) {
          Write-ErrorLog ("catalog [{0}] platforms 含 win 且有效 backend={1}，缺少 win_backend=builtin" -f $id, $effBackend); return $false
        }
      }
      # npm：共享 packages 即可，无需 win_* 字段
    }
  }
  return $true
}

function Import-Catalog {
  <# catalog_load <dir>：按文件名排序加载目录下全部 *.catalog，最后统一校验 #>
  param([string]$Dir)

  if ([string]::IsNullOrEmpty($Dir)) {
    if ($script:CATALOG_DIR) { $Dir = $script:CATALOG_DIR } else { $Dir = (Join-Path $script:ProjectDir 'catalog') }
  }
  $script:CATALOG_DIR = $Dir
  Reset-Catalog

  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
    Write-ErrorLog ("catalog 目录不存在：{0}" -f $Dir); return $false
  }
  $files = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.catalog' -ErrorAction SilentlyContinue |
             Sort-Object -Property Name)
  if ($files.Count -eq 0) {
    Write-ErrorLog ("catalog 目录为空：{0}" -f $Dir); return $false
  }
  foreach ($f in $files) {
    # 注意：Import-CatalogFile 返回 int 退出码（0=成功）。PowerShell 里 0 是假值，
    # 因此不能写 `-not (Import-CatalogFile ...)`——成功也会被当成失败。
    $rc = Import-CatalogFile -Path $f.FullName
    if ($rc -ne 0) { return $false }
  }
  if (-not (Assert-CatalogValid)) { return $false }
  return $true
}

function Get-CatalogEffective {
  <#
    取某个条目在 Windows 上的有效字段。
    规则（与 docs/DESIGN.md 的"平台差异只体现在后端与动作实现中"一致）：
      win_backend ?: backend
      win_packages ?: packages
      win_commands ?: commands
      win_version  ?: version
      win_action   ?: action
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][ValidateSet('Backend','Packages','Commands','Version','Action','Artifacts')][string]$Field
  )
  $map = @{
    'Backend'   = 'CAT_WIN_BACKEND';   'FallbackBackend'   = 'CAT_BACKEND'
    'Packages'  = 'CAT_WIN_PACKAGES';  'FallbackPackages'  = 'CAT_PACKAGES'
    'Commands'  = 'CAT_WIN_COMMANDS';  'FallbackCommands'  = 'CAT_COMMANDS'
    'Version'   = 'CAT_WIN_VERSION';   'FallbackVersion'   = 'CAT_VERSION'
    'Action'    = 'CAT_WIN_ACTION';    'FallbackAction'    = 'CAT_ACTION'
  }
  if ($Field -eq 'Artifacts') {
    $v = $script:CAT_WIN_ARTIFACTS[$Id]
    if ([string]::IsNullOrWhiteSpace($v)) { $v = $script:CAT_ARTIFACTS[$Id] }
    return $v
  }
  $primary = Get-Variable -Name $map[$Field] -Scope Script -ValueOnly
  $fallback = Get-Variable -Name $map["Fallback$Field"] -Scope Script -ValueOnly
  $v = $primary[$Id]
  if ([string]::IsNullOrEmpty($v)) { $v = $fallback[$Id] }
  return $v
}

function Test-CatalogPlatformOk {
  <#
    _engine_platform_ok 的数据层部分：该条目的 platforms 是否含当前平台。
    不含时打印提示并返回 $false；调用方按约定返回 100（skipped）。
  #>
  param([Parameter(Mandatory=$true)][string]$Id)
  $plats = $script:CAT_PLATFORMS[$Id]
  if ([string]::IsNullOrEmpty($plats)) { $plats = 'linux' }
  $tokens = @($plats -split '\s+' | Where-Object { $_ -ne '' })
  if ($tokens -contains 'win') { return $true }
  Write-InfoLog ("[{0}] 不适用于当前平台（platforms={1}），跳过" -f $Id, $plats)
  return $false
}
