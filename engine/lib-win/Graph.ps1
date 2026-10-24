#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Graph.ps1 —— 依赖闭包与拓扑排序（engine/lib/graph.sh 的移植）
.DESCRIPTION
  与 Bash 版的一处有意差异：Windows 上的"有效依赖"取 CAT_DEPS 与 CAT_WIN_DEPS
  的并集。这样 [nodejs] 可以只写 deps=curl（跨平台共用），再用 win_deps 追加
  Windows 专属依赖，而 graph_build / graph_dependents 在两端都得到正确顺序。
#>

Set-StrictMode -Version 2.0

$script:GRAPH_ORDER = New-Object System.Collections.Generic.List[string]
$script:_GRAPH_VISITED = @{}
$script:_GRAPH_STACK = @{}

function Get-EffectiveDeps {
  <# 当前平台的有效依赖：deps 与 win_deps 的并集（保序去重） #>
  param([Parameter(Mandatory=$true)][string]$Id)
  $result = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  foreach ($src in @($script:CAT_DEPS[$Id], $script:CAT_WIN_DEPS[$Id])) {
    foreach ($d in (($src -split '\s+') | Where-Object { $_ -ne '' })) {
      if (-not (Test-DictHasKey -Dictionary $seen -Key $d)) { $seen[$d] = $true; $result.Add($d) }
    }
  }
  return $result
}

function Invoke-GraphVisit {
  <# _graph_visit 的移植。返回 $true/$false。 #>
  param([Parameter(Mandatory=$true)][string]$Id)

  if (-not (Test-DictHasKey -Dictionary $script:CAT_TYPE -Key $Id)) {
    Write-ErrorLog ("依赖闭包遇到未知工具：{0}" -f $Id); return $false
  }
  if ((Test-DictHasKey -Dictionary $script:_GRAPH_VISITED -Key $Id) -and $script:_GRAPH_VISITED[$Id]) { return $true }
  if ((Test-DictHasKey -Dictionary $script:_GRAPH_STACK -Key $Id) -and $script:_GRAPH_STACK[$Id]) {
    Write-ErrorLog ("检测到循环依赖：{0}" -f $Id); return $false
  }

  $script:_GRAPH_STACK[$Id] = $true
  foreach ($dep in (Get-EffectiveDeps -Id $Id)) {
    if (-not (Invoke-GraphVisit -Id $dep)) { return $false }
  }
  $script:_GRAPH_STACK[$Id] = $false
  $script:_GRAPH_VISITED[$Id] = $true
  $script:GRAPH_ORDER.Add($Id)
  return $true
}

function Build-Graph {
  <# graph_build <id...>：收集闭包并拓扑排序到 GRAPH_ORDER #>
  param([Parameter(Mandatory=$true)][string[]]$Ids)

  $script:GRAPH_ORDER = New-Object System.Collections.Generic.List[string]
  $script:_GRAPH_VISITED = @{}
  $script:_GRAPH_STACK = @{}
  foreach ($id in $Ids) {
    if (-not (Invoke-GraphVisit -Id $id)) { return $false }
  }
  return $true
}

function Reverse-Graph {
  <# graph_reverse：把 GRAPH_ORDER 反转为移除顺序（被依赖者先删） #>
  $rev = New-Object System.Collections.Generic.List[string]
  for ($i = $script:GRAPH_ORDER.Count - 1; $i -ge 0; $i--) { $rev.Add($script:GRAPH_ORDER[$i]) }
  $script:GRAPH_ORDER = $rev
}

function Get-GraphDependents {
  <#
    graph_dependents 的移植：输出依赖该工具的、已在闭包内的其它工具。
    用于 remove 前的连带提示。
  #>
  param([Parameter(Mandatory=$true)][string]$Target)
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($id in $script:GRAPH_ORDER) {
    if ($id -eq $Target) { continue }
    foreach ($dep in (Get-EffectiveDeps -Id $id)) {
      if ($dep -eq $Target) { $out.Add($id); break }
    }
  }
  return $out
}
