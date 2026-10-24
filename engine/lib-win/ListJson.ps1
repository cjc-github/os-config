#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/ListJson.ps1 —— catalog/profile 的 JSON 序列化
  （engine/lib/list_json.sh 的移植）
.DESCRIPTION
  输出结构与 Bash 版一致，供 Web UI 的 /api/catalog 直接消费。
  字段顺序保持相同，使同一份数据在两种引擎下可逐字段比对。

  刻意不用 ConvertTo-Json：它会把 < > ' 转义成 < > '，
  并可能改变字段顺序/缩进。这里手写，与 json_escape 逐条对应。
#>

Set-StrictMode -Version 2.0

function ConvertTo-BoolLiteral {
  param([string]$Value)
  if ($Value -eq '1') { return 'true' }
  return 'false'
}

function Export-CatalogJson {
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append('[')
  $first = $true
  foreach ($id in $script:CAT_ORDER) {
    if (-not $first) { $null = $sb.Append(',') }
    $first = $false
    # artifacts 必须走 win_artifacts ?: artifacts 的有效字段：catalog 是跨平台
    # 共享的，[proxy] 写的是 artifacts=~/.bashrc + win_artifacts=${PSPROFILE}，
    # 直接读 CAT_ARTIFACTS 会把 Linux 的 .bashrc 暴露给 Windows 的 Web UI。
    $arts = @((Expand-CatalogArtifacts -Raw (Get-CatalogEffective -Id $id -Field 'Artifacts')) |
              Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $null = $sb.Append('{')
    $null = $sb.Append(('"id":"{0}",'   -f (ConvertTo-JsonLiteral -Text $id)))
    $null = $sb.Append(('"group":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_GROUP[$id])))
    $null = $sb.Append(('"type":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_TYPE[$id])))
    $null = $sb.Append(('"backend":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_BACKEND[$id])))
    $null = $sb.Append(('"packages":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_PACKAGES[$id])))
    $null = $sb.Append(('"version":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_VERSION[$id])))
    $null = $sb.Append(('"track":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_TRACK[$id])))
    $null = $sb.Append(('"commands":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_COMMANDS[$id])))
    $null = $sb.Append(('"deps":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_DEPS[$id])))
    $null = $sb.Append(('"desc":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_DESC[$id])))
    $null = $sb.Append(('"action":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_ACTION[$id])))
    $null = $sb.Append(('"artifacts":{0},' -f (ConvertTo-JsonStringArray -Values $arts)))
    $null = $sb.Append(('"platforms":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:CAT_PLATFORMS[$id])))
    $null = $sb.Append(('"sudo":{0}' -f (ConvertTo-BoolLiteral -Value $script:CAT_SUDO[$id])))
    $null = $sb.Append('}')
  }
  $null = $sb.Append(']')
  return $sb.ToString()
}

function Export-SingleProfileJson {
  <# _list_json_profile 的移植：在子作用域里渲染单个 profile #>
  param([Parameter(Mandatory=$true)][string]$Name)

  $ext = $script:PROF_EXTENDS[$Name]
  $raw = $script:PROF_TOOLS[$Name]
  $err = ''

  $raws = New-Object System.Collections.Generic.List[string]
  foreach ($tok in ($raw -split ',')) {
    $t = $tok.Trim()
    if ($t -ne '') { $raws.Add($t) }
  }

  $tokens = @(Get-ProfileTokens -Name $Name)
  if ($null -eq $tokens) { $tokens = @(); $err = 'profile 解析失败' }

  $tools = New-Object System.Collections.Generic.List[string]
  if ($err -eq '') {
    $savedSelected = $script:SELECTED_TOOLS
    if (Resolve-Profile -Name $Name) {
      foreach ($t in $script:SELECTED_TOOLS) { $tools.Add($t) }
    } else {
      $err = 'profile 解析失败'
    }
    $script:SELECTED_TOOLS = $savedSelected
  }

  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append('{')
  $null = $sb.Append(('"name":"{0}",' -f (ConvertTo-JsonLiteral -Text $Name)))
  $null = $sb.Append(('"desc":"{0}",' -f (ConvertTo-JsonLiteral -Text $script:PROF_DESC[$Name])))
  $null = $sb.Append(('"extends":"{0}",' -f (ConvertTo-JsonLiteral -Text $ext)))
  $null = $sb.Append(('"raw_tools":{0},' -f (ConvertTo-JsonStringArray -Values @($raws))))
  $null = $sb.Append(('"tokens":{0},' -f (ConvertTo-JsonStringArray -Values $tokens)))
  $null = $sb.Append(('"tools":{0},' -f (ConvertTo-JsonStringArray -Values @($tools))))
  $null = $sb.Append(('"error":"{0}"' -f (ConvertTo-JsonLiteral -Text $err)))
  $null = $sb.Append('}')
  return $sb.ToString()
}

function Export-ProfilesJson {
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append('[')
  $first = $true
  foreach ($name in $script:PROF_ORDER) {
    if (-not $first) { $null = $sb.Append(',') }
    $first = $false
    $null = $sb.Append((Export-SingleProfileJson -Name $name))
  }
  $null = $sb.Append(']')
  return $sb.ToString()
}

function Export-ListJson {
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append('{"catalog":')
  $null = $sb.Append((Export-CatalogJson))
  $null = $sb.Append(',"profiles":')
  $null = $sb.Append((Export-ProfilesJson))
  $null = $sb.Append('}')
  return $sb.ToString()
}
