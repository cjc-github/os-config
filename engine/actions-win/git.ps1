#Requires -Version 5.1
<#
.SYNOPSIS
  engine/actions-win/git.ps1 —— 配置 git 身份与代理
  （engine/actions/git.sh 的 Windows 移植）
.DESCRIPTION
  与 Bash 版逐条对应的行为：

  * apply：user.name / user.email 为空则跳过并给出手工命令提示；
    代理键写入前先确认代理主机可达。
  * 原值记录在 state/actions/git/<key>.orig，**空值表示"原本未显式设置"**。
  * remove 只还原 http.proxy / https.proxy，**绝不碰 user.name / user.email**
    （这是有意为之：身份不是本动作引入的状态）。
  * remove 部分失败时保留状态目录，便于重试。
#>

Set-StrictMode -Version 2.0

function Get-GitGlobalConfigPath {
  <# _git_global_config_path 的移植 #>
  $home = $script:HomeDir
  $primary = Join-Path $home '.gitconfig'
  if (-not (Test-Path -LiteralPath $primary)) {
    $xdg = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
    if ([string]::IsNullOrEmpty($xdg)) { $xdg = Join-Path $home '.config' }
    $alt = Join-Path $xdg 'git\config'
    if (Test-Path -LiteralPath $alt) { return $alt }
  }
  return $primary
}

function Save-GitOriginal {
  <# _git_record_original 的移植：首次观察才记录，空值=原本未设置 #>
  param(
    [Parameter(Mandatory=$true)][string]$Dir,
    [Parameter(Mandatory=$true)][string]$Key
  )
  $orig = Join-Path $Dir ($Key + '.orig')
  if (Test-Path -LiteralPath $orig) { return }
  $val = Get-GitConfigValue -Key $Key
  [System.IO.File]::WriteAllText($orig, $val, (New-Object System.Text.UTF8Encoding $false))
}

function action_git_apply {
  param([Parameter(Mandatory=$true)][string]$Id)

  if (-not (Test-CommandExists 'git')) {
    Write-ErrorLog ("[{0}] git 不可用；请先安装其依赖 git-cli" -f $Id)
    return 1
  }

  $env:PROXY_ENABLED = Get-ConfigValue 'PROXY_ENABLED' 'true'
  $userName = Get-ConfigValue 'GIT_USER_NAME' ''
  $userEmail = Get-ConfigValue 'GIT_USER_EMAIL' ''

  # user.name
  if (-not [string]::IsNullOrEmpty($userName)) {
    $cur = Get-GitConfigValue -Key 'user.name'
    if ($cur -ne $userName -or $script:FORCE -eq 1) {
      $null = Register-Rollback -Path (Get-GitGlobalConfigPath)
      $rc = Invoke-Step -Description ("git config --global user.name {0}" -f $userName) -Script {
        & git config --global user.name $userName
        return $LASTEXITCODE
      }
      if ($rc -ne 0) { return 1 }
    } else {
      Write-InfoLog 'user.name 已是预期值，跳过'
    }
  } else {
    Write-WarnLog 'GIT_USER_NAME 未设置，跳过 user.name'
    Write-CommandLog 'git config --global user.name "你的姓名"'
  }

  # user.email
  if (-not [string]::IsNullOrEmpty($userEmail)) {
    $cur = Get-GitConfigValue -Key 'user.email'
    if ($cur -ne $userEmail -or $script:FORCE -eq 1) {
      $null = Register-Rollback -Path (Get-GitGlobalConfigPath)
      $rc = Invoke-Step -Description ("git config --global user.email {0}" -f $userEmail) -Script {
        & git config --global user.email $userEmail
        return $LASTEXITCODE
      }
      if ($rc -ne 0) { return 1 }
    } else {
      Write-InfoLog 'user.email 已是预期值，跳过'
    }
  } else {
    Write-WarnLog 'GIT_USER_EMAIL 未设置，跳过 user.email'
    Write-CommandLog 'git config --global user.email "you@example.com"'
  }

  if ($env:PROXY_ENABLED -ne 'true') {
    Write-InfoLog ("[{0}] 代理未启用（PROXY_ENABLED={1}），不修改 git 代理配置" -f $Id, $env:PROXY_ENABLED)
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
    Write-ErrorLog ("[{0}] 代理主机不可达，已中止" -f $Id)
    return 1
  }

  $dir = Get-StateActionDir -Name 'git'
  if ($null -eq $dir) { return 1 }

  foreach ($key in @('http.proxy','https.proxy')) {
    $cur = Get-GitConfigValue -Key $key
    if ($cur -ne $script:RESOLVED_PROXY_URL -or $script:FORCE -eq 1) {
      Save-GitOriginal -Dir $dir -Key $key
      $null = Register-Rollback -Path (Get-GitGlobalConfigPath)
      $rc = Invoke-Step -Description ("git config --global {0} {1}" -f $key, $script:RESOLVED_PROXY_URL) -Script {
        & git config --global $key $script:RESOLVED_PROXY_URL
        return $LASTEXITCODE
      }
      if ($rc -ne 0) { return 1 }
    } else {
      Write-InfoLog ("{0} 已是预期值，跳过" -f $key)
    }
  }

  Write-OkLog ("git 配置完成（代理 {0}）" -f $script:RESOLVED_PROXY_URL)
  return 0
}

function action_git_remove {
  param([Parameter(Mandatory=$true)][string]$Id)

  if (-not (Test-CommandExists 'git')) {
    Write-InfoLog 'git 不可用，无需还原代理键'
    return 0
  }

  $dir = Get-StateActionDir -Name 'git'
  if ($null -eq $dir) { return 1 }

  $rc = 0
  foreach ($key in @('http.proxy','https.proxy')) {
    $orig = Join-Path $dir ($Key + '.orig')
    if (Test-Path -LiteralPath $orig) {
      $val = (Get-Content -LiteralPath $orig -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
      if ($null -eq $val) { $val = '' } else { $val = $val.Trim() }
      # 必须走 Invoke-NativeStep：$val 可能为空串（原本未显式设置），
      # PowerShell 5.1 用调用运算符起原生程序会丢弃空参数，`git config
      # --global <key> ''` 会退化成读操作——"还原"静默失败且退出码为 0。
      # Bash 侧 `git config --global "$key" "$cur"` 没有这层问题。
      $r = Invoke-NativeStep -Description ("还原 git {0}" -f $key) -FileName 'git' `
            -Arguments @('config', '--global', $key, $val)
      if ($r -ne 0) { $rc = 1 }
    } else {
      $cur = Get-GitConfigValue -Key $key
      if (-not [string]::IsNullOrEmpty($cur)) {
        $r = Invoke-Step -Description ("删除 git {0}" -f $key) -Script {
          & git config --global --unset $key
          return $LASTEXITCODE
        }
        if ($r -ne 0) { $rc = 1 }
      } else {
        Write-DebugLog ("{0} 本就不存在" -f $key)
      }
    }
  }

  if ($rc -ne 0) {
    Write-ErrorLog '部分代理键还原失败；保留记录以便重试'
    return 1
  }

  try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  Write-OkLog '已还原 git 代理配置（保留 user.name/user.email）'
  return 0
}

function action_git_verify {
  param([Parameter(Mandatory=$true)][string]$Id)

  if (-not (Test-CommandExists 'git')) {
    Write-ErrorLog ("[{0}] git 不可用" -f $Id); return 1
  }

  $rc = 0
  $userName = Get-ConfigValue 'GIT_USER_NAME' ''
  $userEmail = Get-ConfigValue 'GIT_USER_EMAIL' ''

  if (-not [string]::IsNullOrEmpty($userName)) {
    $cur = Get-GitConfigValue -Key 'user.name'
    if ($cur -ne $userName) {
      Write-ErrorLog ("user.name 不符：期望 {0}，实际 {1}" -f $userName, $(if ($cur) { $cur } else { '<未设置>' }))
      $rc = 1
    }
  } else {
    Write-InfoLog 'GIT_USER_NAME 未设置，跳过 user.name 校验'
  }
  if (-not [string]::IsNullOrEmpty($userEmail)) {
    $cur = Get-GitConfigValue -Key 'user.email'
    if ($cur -ne $userEmail) {
      Write-ErrorLog ("user.email 不符：期望 {0}，实际 {1}" -f $userEmail, $(if ($cur) { $cur } else { '<未设置>' }))
      $rc = 1
    }
  } else {
    Write-InfoLog 'GIT_USER_EMAIL 未设置，跳过 user.email 校验'
  }

  if ((Get-ConfigValue 'PROXY_ENABLED' 'true') -ne 'true') {
    Write-OkLog '代理已禁用，跳过 git 代理键校验'
    return $rc
  }

  $prc = Resolve-ProxyEndpoint 2>$null
  if ($prc -ne 0) {
    Write-WarnLog '无法推导代理地址，跳过代理键校验'
    return $rc
  }

  foreach ($key in @('http.proxy','https.proxy')) {
    $cur = Get-GitConfigValue -Key $key
    if ($cur -ne $script:RESOLVED_PROXY_URL) {
      Write-ErrorLog ("{0} 不符：期望 {1}，实际 {2}" -f $key, $script:RESOLVED_PROXY_URL, $(if ($cur) { $cur } else { '<未设置>' }))
      $rc = 1
    }
  }
  return $rc
}

function action_git_status {
  param([Parameter(Mandatory=$true)][string]$Id)
  $name = Get-GitConfigValue -Key 'user.name'
  $email = Get-GitConfigValue -Key 'user.email'
  $proxy = Get-GitConfigValue -Key 'http.proxy'
  if ([string]::IsNullOrEmpty($name) -and [string]::IsNullOrEmpty($email) -and [string]::IsNullOrEmpty($proxy)) {
    Write-Host ("    {0}" -f $Id)
    Write-Host '    未配置'
    return 0
  }
  $parts = New-Object System.Collections.Generic.List[string]
  if ($name) { $parts.Add(("name={0}" -f $name)) }
  if ($email) { $parts.Add(("email={0}" -f $email)) }
  if ($proxy) { $parts.Add(("proxy={0}" -f $proxy)) }
  Write-Host ("    {0}" -f $Id)
  Write-Host ("    {0}" -f ($parts -join ' '))
  return 0
}
