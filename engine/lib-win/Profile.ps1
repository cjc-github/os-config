#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Profile.ps1 —— profile 解析（engine/lib/profile.sh 的移植）
.DESCRIPTION
  把 profiles/*.conf 解析进 PROF_* 映射，并支持 extends 继承、
  tools token 三种形态（工具 id / @分组 / 后端:包）的解析。

  内联 id 生成规则必须与 engine/lib/profile.sh、ui/schema.py 的
  normalize_adhoc_id、ui/static/app.js 的 normalizeAdhocId 完全一致，
  否则同一个 winget:Git.Git 在 CLI 与 Web UI 会得到两个不同的 id。
    包名转小写 → 非 [a-z0-9_-] 字符换成 - → 去掉首尾所有 -
#>

Set-StrictMode -Version 2.0

$script:PROF_ORDER = New-Object System.Collections.Generic.List[string]
$script:PROF_DESC = [ordered]@{}
$script:PROF_EXTENDS = [ordered]@{}
$script:PROF_TOOLS = [ordered]@{}
$script:PROF_ERR = [ordered]@{}

function Reset-Profile {
  $script:PROF_ORDER = New-Object System.Collections.Generic.List[string]
  foreach ($n in @('PROF_DESC','PROF_EXTENDS','PROF_TOOLS','PROF_ERR')) {
    Set-Variable -Name $n -Scope Script -Value ([ordered]@{}) -Force
  }
}

function Import-ProfileFile {
  <# profile_load_file 的移植 #>
  param([Parameter(Mandatory=$true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-ErrorLog ("profile 文件不存在：{0}" -f $Path); return $false
  }

  $name = ''
  $lineNo = 0
  $seen = @{}

  try { $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop }
  catch { Write-ErrorLog ("无法读取 profile 文件：{0}" -f $Path); return $false }

  foreach ($raw in $lines) {
    $lineNo++
    $hashIdx = $raw.IndexOf('#')
    if ($hashIdx -ge 0) { $line = $raw.Substring(0, $hashIdx) } else { $line = $raw }
    $line = $line.Trim()
    if ($line -eq '') { continue }

    if ($line -match '^\[([^\]]+)\]$') {
      $name = $Matches[1].Trim()
      if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$') {
        Write-ErrorLog ("profile 非法名字：{0}:{1}（{2}）" -f $Path, $lineNo, $name); return $false
      }
      if ((Test-DictHasKey -Dictionary $script:PROF_DESC -Key $name)) {
        Write-ErrorLog ("profile 重复定义：{0}（{1}:{2}）" -f $name, $Path, $lineNo); return $false
      }
      $script:PROF_ORDER.Add($name)
      $script:PROF_DESC[$name] = ''
      $script:PROF_EXTENDS[$name] = ''
      $script:PROF_TOOLS[$name] = ''
      $seen = @{}
      continue
    }

    if ($name -eq '') {
      Write-ErrorLog ("profile 键值出现在任何 [名字] 段之前：{0}:{1}" -f $Path, $lineNo); return $false
    }
    $eq = $line.IndexOf('=')
    if ($eq -lt 0) {
      Write-ErrorLog ("profile 格式错误：{0}:{1}（应为 key=value）" -f $Path, $lineNo); return $false
    }
    $key = $line.Substring(0, $eq).Trim()
    $value = $line.Substring($eq + 1).Trim()

    if ((Test-DictHasKey -Dictionary $seen -Key $key)) {
      Write-ErrorLog ("profile 键重复：{0}:{1}（{2}.{3}）" -f $Path, $lineNo, $name, $key); return $false
    }
    $seen[$key] = $true

    switch ($key) {
      'desc'    { $script:PROF_DESC[$name] = $value }
      'extends' { $script:PROF_EXTENDS[$name] = $value }
      'tools'   { $script:PROF_TOOLS[$name] = $value }
      default {
        Write-ErrorLog ("profile 未知字段：{0}:{1}（{2}.{3}）" -f $Path, $lineNo, $name, $key); return $false
      }
    }
  }
  return $true
}

function Import-Profile {
  <# profile_load <dir>：加载目录下全部 *.conf #>
  param([string]$Dir)

  if ([string]::IsNullOrEmpty($Dir)) { $Dir = (Join-Path $script:ProjectDir 'profiles') }
  Reset-Profile
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
    Write-WarnLog ("profiles 目录不存在：{0}" -f $Dir)
    return $false
  }
  $files = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.conf' -ErrorAction SilentlyContinue |
             Sort-Object -Property Name)
  if ($files.Count -eq 0) {
    Write-WarnLog 'profiles 目录为空'
    return $false
  }
  foreach ($f in $files) {
    if (-not (Import-ProfileFile -Path $f.FullName)) { return $false }
  }
  return $true
}

function Get-ProfileTokens {
  <#
    profile_tokens 的移植：输出最终 token 流（每行一个，已展开 extends）。
    用 List[string] 保证顺序；seen 哈希表只用于去重。
  #>
  param([Parameter(Mandatory=$true)][string]$Name)

  $chain = New-Object System.Collections.Generic.List[string]
  $seenChain = @{}
  $cur = $Name
  while ($true) {
    if (-not (Test-DictHasKey -Dictionary $script:PROF_DESC -Key $cur)) {
      Write-ErrorLog ("profile 不存在：{0}" -f $cur)
      return $null
    }
    if ((Test-DictHasKey -Dictionary $seenChain -Key $cur)) {
      Write-ErrorLog ("profile 存在循环继承：{0}" -f $cur)
      return $null
    }
    $seenChain[$cur] = $true
    $chain.Add($cur)
    $parent = $script:PROF_EXTENDS[$cur]
    if ([string]::IsNullOrEmpty($parent)) { break }
    $cur = $parent
  }

  # 父在前、子在后；按顺序去重
  $ordered = New-Object System.Collections.Generic.List[string]
  for ($i = $chain.Count - 1; $i -ge 0; $i--) { $ordered.Add($chain[$i]) }

  $tokens = New-Object System.Collections.Generic.List[string]
  $seenTok = @{}
  foreach ($p in $ordered) {
    $raw = $script:PROF_TOOLS[$p]
    foreach ($tok in ($raw -split ',')) {
      $t = $tok.Trim()
      if ($t -eq '') { continue }
      if (-not (Test-DictHasKey -Dictionary $seenTok -Key $t)) { $seenTok[$t] = $true; $tokens.Add($t) }
    }
  }
  return $tokens
}

function ConvertTo-AdhocId {
  <#
    内联 id 生成规则。必须与 profile.sh / ui/schema.py / app.js 保持一致。
  #>
  param([Parameter(Mandatory=$true)][string]$Spec)
  $id = $Spec.ToLowerInvariant()
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $id.ToCharArray()) {
    if ($ch -match '[a-z0-9_-]') { $null = $sb.Append($ch) } else { $null = $sb.Append('-') }
  }
  $id = $sb.ToString()
  $id = $id.TrimStart('-')
  $id = $id.TrimEnd('-')
  return $id
}

function Register-CliProfile {
  <#
    对应 setup.sh 里 --pick 的处理：把 --pick 当成一个临时 profile "cli"。
    必须先 Reset-Profile 再登记，否则会与磁盘上的 profiles/*.conf 混在一起。
  #>
  param([Parameter(Mandatory=$true)][string]$Pick)
  Reset-Profile
  $script:PROF_ORDER.Add('cli')
  $script:PROF_DESC['cli'] = '命令行 --pick'
  $script:PROF_EXTENDS['cli'] = ''
  $script:PROF_TOOLS['cli'] = $Pick
}

function Resolve-Profile {
  <#
    profile_resolve 的移植：把 token 展开为工具 id 列表，写入 $script:SELECTED_TOOLS。
    返回 $true/$false。
  #>
  param([Parameter(Mandatory=$true)][string]$Name)

  $tokens = Get-ProfileTokens -Name $Name
  if ($null -eq $tokens) { return $false }

  $script:SELECTED_TOOLS = New-Object System.Collections.Generic.List[string]
  $seen = @{}

  foreach ($tok in $tokens) {
    if ($tok.StartsWith('@')) {
      $group = $tok.Substring(1)
      $matched = 0
      foreach ($id in $script:CAT_ORDER) {
        if ($script:CAT_GROUP[$id] -eq $group) {
          if (-not (Test-DictHasKey -Dictionary $seen -Key $id)) { $seen[$id] = $true; $script:SELECTED_TOOLS.Add($id) }
          $matched++
        }
      }
      if ($matched -eq 0) {
        Write-ErrorLog ("profile [{0}] 引用了空分组：{1}" -f $Name, $tok)
        return $false
      }
      continue
    }

    if ($tok.Contains(':')) {
      $backend = $tok.Substring(0, $tok.IndexOf(':'))
      $spec = $tok.Substring($tok.IndexOf(':') + 1)
      # apt/npm/snap 由 Bash 引擎实现；winget/builtin/npm 由本引擎实现。
      # 这里放行全部名字，遇到本引擎未实现的（apt/snap）在分派时明确报错。
      $known = @('apt','npm','snap','winget','builtin')
      if ($known -notcontains $backend) {
        Write-ErrorLog ("profile [{0}] 的 {1} 后端非法（应为 apt/npm/snap/winget/builtin）" -f $Name, $tok)
        return $false
      }
      if ([string]::IsNullOrEmpty($spec)) {
        Write-ErrorLog ("profile [{0}] 的 {1} 缺少包名" -f $Name, $tok)
        return $false
      }
      $id = ConvertTo-AdhocId -Spec $spec
      if ((Register-CatalogAdhoc -Id $id -Backend $backend -Packages $spec) -ne 0) { return $false }
      if (-not (Test-DictHasKey -Dictionary $seen -Key $id)) { $seen[$id] = $true; $script:SELECTED_TOOLS.Add($id) }
      continue
    }

    if (-not (Test-DictHasKey -Dictionary $script:CAT_TYPE -Key $tok)) {
      Write-ErrorLog ("profile [{0}] 引用了不存在的工具：{1}" -f $Name, $tok)
      return $false
    }
    if (-not (Test-DictHasKey -Dictionary $seen -Key $tok)) { $seen[$tok] = $true; $script:SELECTED_TOOLS.Add($tok) }
  }
  return $true
}
