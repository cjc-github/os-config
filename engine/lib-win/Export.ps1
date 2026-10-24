#Requires -Version 5.1
<#
.SYNOPSIS
  engine/lib-win/Export.ps1 —— 把本机状态导出为 profile（engine/lib/export.sh 的移植）
.DESCRIPTION
  不需要选择，只读（唯一写的是输出的 profile 文件）。

  必须逐条保持的格式契约（已核对 export.sh）：
  * 尾注**恰好 20 个** key、顺序固定。
  * tools= 用 ", " 连接。
  * profile 名 = 输出文件名去掉尾部 .conf。
  * extends= 输出为空。
  * 空结果时返回 1 且不写文件。
  * 写文件用"临时文件 + 移动替换"，失败时清掉临时文件。
#>

Set-StrictMode -Version 2.0

$script:ExportParams = @(
  'MIRROR_APT_URL', 'MIRROR_APT_PORTS_URL', 'MIRROR_SKIP_APT', 'MIRROR_SKIP_APT_UPDATE',
  'APT_UPGRADE', 'PROXY_ENABLED', 'PROXY_HOST', 'PROXY_PORT', 'PROXY_TEST_URL',
  'PROXY_CONNECT_TIMEOUT', 'PROXY_MAX_TIME', 'NO_PROXY', 'GIT_USER_NAME', 'GIT_USER_EMAIL',
  'SSH_KEY_TYPE', 'JOURNALD_MAX_USE', 'NODE_VERSION', 'NODE_LTS_MAJOR', 'NVM_VERSION', 'NPM_REGISTRY'
)

function Export-ProfileRun {
  <# export_run 的移植 #>
  param([string]$OutputPath)

  if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = (Join-Path $script:ProjectDir 'profiles\exported.conf')
  }

  $installed = New-Object System.Collections.Generic.List[string]
  $configCount = 0
  foreach ($id in $script:CAT_ORDER) {
    if ($script:CAT_TYPE[$id] -eq 'config') {
      if (Test-StateHas -Tool $id) { $installed.Add($id); $configCount++ }
    } else {
      if (Test-EngineToolInstalled -Id $id) { $installed.Add($id) }
    }
  }

  if ($installed.Count -eq 0) {
    Write-WarnLog '未发现已安装的工具或已应用的配置，未生成 profile'
    Write-WarnLog '先执行一次 install，或用 --pick 指定要导出的选择'
    return 1
  }

  $pkgCount = $installed.Count - $configCount
  Write-InfoLog ("已安装的 catalog 条目：{0} 个包 + {1} 个配置动作" -f $pkgCount, $configCount)

  # 按 catalog 原始顺序输出
  $ordered = New-Object System.Collections.Generic.List[string]
  $picked = @{}
  foreach ($i in $installed) { $picked[$i] = $true }
  foreach ($id in $script:CAT_ORDER) { if ((Test-DictHasKey -Dictionary $picked -Key $id)) { $ordered.Add($id) } }

  $fileName = Split-Path -Leaf $OutputPath
  $profileName = $fileName
  if ($profileName.EndsWith('.conf')) { $profileName = $profileName.Substring(0, $profileName.Length - 5) }

  $sb = New-Object System.Text.StringBuilder
  # 每一行注释都必须带 '# ' 前缀：profile 解析器（engine/lib/profile.sh 与
  # engine/lib-win/Profile.ps1）把 '# ' 之前的内容整行丢弃，缺前缀的行会被当成
  # "出现在任何 [名字] 段之前的键值"而让整个 profiles 目录加载失败——
  # 连带 minimal.conf 读不进来，default/dev 两个 profile 全部解析失败。
  $null = $sb.AppendLine('# ===========================================================================')
  $null = $sb.AppendLine(("# {0} —— 由 setup.ps1 export 生成" -f $fileName))
  # 时间格式与 export.sh 的 date '+%Y-%m-%dT%H:%M:%S%z' 对齐：
  # .NET 的 'T' 是字面量需转义，'zzz' 才会输出 +08:00 这类带冒号偏移。
  $null = $sb.AppendLine(("# 生成时间：{0}" -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')))
  $null = $sb.AppendLine(("# 用法：.\setup.ps1 install --profile {0}" -f $profileName))
  $null = $sb.AppendLine('#')
  $null = $sb.AppendLine('# 本文件只含工具选择。参数不会写进 profile，请把新机器的')
  $null = $sb.AppendLine('# config/user.env 按下方注释核对一遍。')
  $null = $sb.AppendLine('# ===========================================================================')
  $null = $sb.AppendLine('')
  $null = $sb.AppendLine(("[{0}]" -f $profileName))
  $null = $sb.AppendLine(("desc=由 export 生成（{0} 项）" -f $ordered.Count))
  $null = $sb.AppendLine('extends=')
  $null = $sb.AppendLine(("tools={0}" -f ($ordered -join ', ')))
  $null = $sb.AppendLine('')
  $null = $sb.AppendLine('#')
  $null = $sb.AppendLine('# —— 导出时的生效参数（复制到新机器的 config/user.env）——')
  foreach ($key in $script:ExportParams) {
    $val = [Environment]::GetEnvironmentVariable($key)
    if ([string]::IsNullOrEmpty($val)) {
      $null = $sb.AppendLine(("#   {0}=<未设置，走默认值>" -f $key))
    } else {
      $null = $sb.AppendLine(("#   {0}={1}" -f $key, $val))
    }
  }

  $dir = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
    try { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop } catch { }
  }
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $OutputPath -Force -ErrorAction Stop
  } catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    Write-ErrorLog ("无法写入导出的 profile：{0}（{1}）" -f $OutputPath, $_.Exception.Message)
    return 1
  }

  Write-OkLog ("已导出 {0} 项 → {1}" -f $ordered.Count, $OutputPath)
  Write-InfoLog 'cp config/user.env.example config/user.env（按导出注释填）'
  Write-InfoLog (".\setup.ps1 install --profile {0}" -f $profileName)
  Write-Host ''
  Write-Host ("导出的 profile（{0} 项）：" -f $ordered.Count)
  foreach ($id in $ordered) {
    Write-Host ("  {0,-14} {1}" -f $id, $script:CAT_DESC[$id])
  }
  return 0
}
