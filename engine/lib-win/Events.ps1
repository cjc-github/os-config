#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Events.ps1 —— 结构化事件（engine/lib/events.sh 的移植）
.DESCRIPTION
  输出 JSONL 供 Web UI 实时消费。字段名与顺序和 Bash 版保持一致，
  使同一个解析器能同时读两种引擎写出的事件流。

  刻意不用 ConvertTo-Json：它会把 < > ' 转义成 < > '，
  破坏与 Bash 版 events.jsonl 的字节兼容性。这里手写转义，
  与 json_escape / json_string_array 逐条对应。
#>

Set-StrictMode -Version 2.0

$script:EventsFile = ''

function ConvertTo-JsonLiteral {
  <# json_escape 的移植 #>
  param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $s = $Text
  $s = $s.Replace('\', '\\')
  $s = $s.Replace('"', '\"')
  $s = $s.Replace("`r", '\r')
  $s = $s.Replace("`n", '\n')
  $s = $s.Replace("`t", '\t')
  # 去掉其余控制字符（对应 LC_ALL=C tr -d '\000-\010\013\014\016-\037'）
  $s = [regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
  return $s
}

function ConvertTo-JsonStringArray {
  <# json_string_array 的移植 #>
  param([string[]]$Values = @())
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($v in $Values) {
    if ($null -eq $v) { continue }
    $parts.Add(('"{0}"' -f (ConvertTo-JsonLiteral -Text $v)))
  }
  return ('[' + ($parts -join ',') + ']')
}

function Publish-Event {
  <#
    events_emit <type> <fragment>。
    任何写失败都不得影响主流程（events.sh 用 2>/dev/null || true 达到同样效果）。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Type,
    [string]$Fragment = ''
  )
  if ([string]::IsNullOrEmpty($script:EventsFile)) { return }
  $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $line = ('{{"ts":"{0}","event":"{1}",{2}}}' -f (ConvertTo-JsonLiteral -Text $ts), (ConvertTo-JsonLiteral -Text $Type), $Fragment)
  try {
    [System.IO.File]::AppendAllText($script:EventsFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
  } catch { }
}
