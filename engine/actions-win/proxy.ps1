#Requires -Version 5.1
<#
.SYNOPSIS
  engine/actions-win/proxy.ps1 —— 推导代理地址并写入 shell 代理环境变量
  （engine/actions/proxy.sh 的 Windows 移植）
.DESCRIPTION
  目标文件从 ~/.bashrc 换成 $PROFILE.CurrentUserCurrentHost，其余行为逐条对应：

  * 沿用完全相同的 BEGIN/END 标记，使同一份 profile 文件在两种引擎下都可识别；
  * 块内写法从 `export HTTP_PROXY=...` 换成 `$env:HTTP_PROXY = '...'`；
  * 幂等仍然是"整块字符串精确比对"；
  * 缺少 END 标记时拒绝删除，避免误删后续内容；
  * verify = 块存在 + 抽出 HTTPS_PROXY + 真实 curl.exe 连通性测试；
  * PROXY_ENABLED != true 时要求块必须不存在（而不是"跳过"）。

  已知限制（与 Bash 版同类）：写进 $PROFILE 只影响会加载 profile 的 PowerShell
  会话。从 cmd / Explorer / 其它 shell 启动的 curl.exe、git、npm 看不到它。
  需要全局生效时应改用 User 级环境变量，那属于另一套产物与还原语义。
#>

Set-StrictMode -Version 2.0

$script:PROXY_BEGIN = '# >>> os-config proxy begin >>>'
$script:PROXY_END   = '# <<< os-config proxy end <<<'

function Set-ProxyDefaults {
  $env:PROXY_ENABLED = Get-ConfigValue 'PROXY_ENABLED' 'true'
  $env:PROXY_HOST = Get-ConfigValue 'PROXY_HOST' ''
  $env:PROXY_PORT = Get-ConfigValue 'PROXY_PORT' ''
  $env:NO_PROXY = Get-ConfigValue 'NO_PROXY' 'localhost,127.0.0.1,::1'
}

function Get-ProxyBlockRender {
  <# _proxy_block_render 的移植：写入与比对共用同一份内容 #>
  $noProxy = Get-ConfigValue 'NO_PROXY' 'localhost,127.0.0.1,::1'
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.AppendLine($script:PROXY_BEGIN)
  $null = $sb.AppendLine(("`$env:HTTP_PROXY = '{0}'" -f $script:RESOLVED_PROXY_URL))
  $null = $sb.AppendLine(("`$env:HTTPS_PROXY = '{0}'" -f $script:RESOLVED_PROXY_URL))
  $null = $sb.AppendLine(("`$env:http_proxy = '{0}'" -f $script:RESOLVED_PROXY_URL))
  $null = $sb.AppendLine(("`$env:https_proxy = '{0}'" -f $script:RESOLVED_PROXY_URL))
  $null = $sb.AppendLine(("`$env:NO_PROXY = '{0}'" -f $noProxy))
  $null = $sb.AppendLine(("`$env:no_proxy = '{0}'" -f $noProxy))
  $null = $sb.Append($script:PROXY_END)
  return $sb.ToString()
}

function Get-ProxyCurrentUrl {
  <# _proxy_block_current 里的 URL 抽取：只认行首的 HTTPS_PROXY，取第一个匹配 #>
  param([Parameter(Mandatory=$true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop } catch { return $null }
  foreach ($l in $lines) {
    if ($l -match '^\$env:HTTPS_PROXY\s*=\s*''(.*)''\s*$') { return $Matches[1] }
    if ($l -match '^\$env:HTTPS_PROXY\s*=\s*(.*)$') { return $Matches[1].Trim() }
  }
  return $null
}

function action_proxy_apply {
  param([Parameter(Mandatory=$true)][string]$Id)

  Set-ProxyDefaults
  if ($env:PROXY_ENABLED -ne 'true') {
    Write-InfoLog ("[{0}] 代理未启用（PROXY_ENABLED={1}），不修改 shell 代理配置" -f $Id, $env:PROXY_ENABLED)
    return 0
  }

  $rc = Resolve-ProxyEndpoint
  if ($rc -ne 0) {
    switch ($rc) {
      1 { Write-ErrorLog '无法推导代理地址：未能探测本机 IPv4，请显式设置 PROXY_HOST' }
      2 { Write-ErrorLog '无法推导代理地址：PROXY_PORT 非法' }
      3 { Write-ErrorLog '无法推导代理地址：PROXY_HOST 非法' }
      default { Write-ErrorLog ("无法推导代理地址（rc={0}）" -f $rc) }
    }
    return $rc
  }

  if ((Test-ProxyHostReachable -HostName $script:RESOLVED_PROXY_HOST) -ne 0) {
    Write-ErrorLog ("[{0}] 代理主机不可达，已中止（未写入任何文件）" -f $Id)
    return 1
  }

  $profile = Get-PowerShellProfilePath
  $want = Get-ProxyBlockRender
  $cur = Get-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END

  if ($script:FORCE -ne 1 -and $cur -eq $want) {
    Write-InfoLog ("[{0}] 代理块已是最新，跳过" -f $Id)
    return 0
  }

  $null = Register-Rollback -Path $profile

  # 目标文件可能不存在（全新机器没有 $PROFILE）
  if (-not (Test-Path -LiteralPath $profile)) {
    $dir = Split-Path -Parent $profile
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
      try { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop } catch {
        Write-ErrorLog ("[{0}] 无法创建 profile 目录：{1}" -f $Id, $dir)
        return 1
      }
    }
    try { $null = New-Item -ItemType File -Path $profile -Force -ErrorAction Stop } catch {
      Write-ErrorLog ("[{0}] 无法创建 profile 文件：{1}" -f $Id, $profile)
      return 1
    }
  }

  if (-not [string]::IsNullOrEmpty($cur)) {
    $stripRc = Remove-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
    if ($stripRc -ne 0) { return 1 }
    if ($script:FORCE -eq 1) { Write-InfoLog '--force 重写代理块' }
  }

  try {
    # 与 Bash 版一致：块前空一行，始终追加到文件末尾
    [System.IO.File]::AppendAllText($profile, "`r`n" + $want + "`r`n", (New-Object System.Text.UTF8Encoding $false))
  } catch {
    Write-ErrorLog ("[{0}] 无法写入 {1}：{2}" -f $Id, $profile, $_.Exception.Message)
    return 1
  }

  Write-OkLog ("[{0}] 代理配置完成（{1}）" -f $Id, $script:RESOLVED_PROXY_URL)
  Write-WarnLog '新开 PowerShell 会话才生效；当前会话可执行：. $PROFILE'
  return 0
}

function action_proxy_remove {
  param([Parameter(Mandatory=$true)][string]$Id)

  $profile = Get-PowerShellProfilePath
  if (-not (Test-Path -LiteralPath $profile)) {
    Write-InfoLog ("[{0}] profile 不存在，无需还原" -f $Id)
    return 0
  }
  $cur = Get-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
  if ([string]::IsNullOrEmpty($cur)) {
    Write-InfoLog ("[{0}] 无 os-config proxy 块，无需还原" -f $Id)
    return 0
  }

  $null = Register-Rollback -Path $profile
  $rc = Remove-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
  if ($rc -ne 0) { return 1 }
  Write-OkLog ("[{0}] 已移除 shell 代理块" -f $Id)
  return 0
}

function action_proxy_verify {
  param([Parameter(Mandatory=$true)][string]$Id)

  Set-ProxyDefaults
  $profile = Get-PowerShellProfilePath

  if ($env:PROXY_ENABLED -ne 'true') {
    $cur = Get-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
    if (-not [string]::IsNullOrEmpty($cur)) {
      Write-ErrorLog ("[{0}] 代理已禁用但 profile 中仍有残留块" -f $Id)
      return 1
    }
    Write-OkLog '代理已禁用且无残留块'
    return 0
  }

  $cur = Get-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
  if ([string]::IsNullOrEmpty($cur)) {
    Write-ErrorLog ("[{0}] 缺少 os-config proxy 块：{1}" -f $Id, $profile)
    return 1
  }

  $url = Get-ProxyCurrentUrl -Path $profile
  if ([string]::IsNullOrEmpty($url)) {
    Write-ErrorLog ("[{0}] 代理块中未找到 HTTPS_PROXY" -f $Id)
    return 1
  }

  $testUrl = Get-ConfigValue 'PROXY_TEST_URL' 'https://github.com'
  $ct = Get-ConfigValue 'PROXY_CONNECT_TIMEOUT' '5'
  $mt = Get-ConfigValue 'PROXY_MAX_TIME' '15'
  $crc = Test-ProxyCurlConnectivity -ProxyUrl $url -TestUrl $testUrl -ConnectTimeout $ct -MaxTime $mt
  if ($crc -eq 2) {
    Write-WarnLog 'curl.exe 不可用，跳过代理连通性校验'
    return 0
  }
  if ($crc -ne 0) {
    Write-ErrorLog ("[{0}] 经代理 {1} 访问 {2} 失败" -f $Id, $url, $testUrl)
    return 1
  }
  return 0
}

function action_proxy_status {
  param([Parameter(Mandatory=$true)][string]$Id)
  $profile = Get-PowerShellProfilePath
  $cur = Get-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
  if ([string]::IsNullOrEmpty($cur)) {
    Write-Host '    未写入代理块'
    return 0
  }
  $url = Get-ProxyCurrentUrl -Path $profile
  Write-Host ("    已写入代理块（{0}）" -f $(if ($url) { $url } else { '<空>' }))
  return 0
}
