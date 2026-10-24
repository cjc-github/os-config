#Requires -Version 5.1
<#
.SYNOPSIS
  engine/actions-win/ssh.ps1 —— 生成 SSH 用户密钥
  （engine/actions/ssh.sh 的 Windows 移植）
.DESCRIPTION
  与 Bash 版的一处实质差异：NTFS 没有 600 这种模式位，因此
  * apply 不调 chmod，而是依赖 ssh-keygen 自己写入的 ACL，并在事后校验；
  * verify 不再要求 `stat -c '%a'` 等于 600，改为解析 ACL，确认只有
    当前用户 / SYSTEM / Administrators 有 Allow 权限——这与 OpenSSH for
    Windows 自身的私钥校验标准同构。

  保持不变的部分：
  * 只删 created.txt 里记录的自建密钥，绝不删 ~/.ssh 本身或用户自有密钥；
  * 生成后若状态登记失败，删掉刚生成的密钥，避免出现无人记录的孤儿；
  * ~/.ssh 目录从不删除。
#>

Set-StrictMode -Version 2.0

function Get-SshKeyType {
  <# _ssh_key_type 的移植：默认 ed25519，只接受 ed25519/rsa #>
  $t = Get-ConfigValue 'SSH_KEY_TYPE' 'ed25519'
  if ($t -ne 'ed25519' -and $t -ne 'rsa') { return $null }
  return $t
}

function Test-SshKeyAclOk {
  <#
    私钥 ACL 是否足够严格：只允许 当前用户 / SYSTEM / Administrators /
    Authenticated Users / Users 持有 Allow 权限。
    返回 $true/$false；无法读取 ACL 时返回 $false。
  #>
  param([Parameter(Mandatory=$true)][string]$Path)
  try {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
  } catch { return $false }

  $me = $null
  try { $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return $false }
  $allowed = @($me, 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-11', 'S-1-5-32-545')

  foreach ($ace in $acl.Access) {
    if ($ace.AccessControlType -ne 'Allow') { continue }
    $sid = $null
    try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { return $false }
    if ($allowed -notcontains $sid) { return $false }
  }
  return $true
}

function Start-SshKeygen {
  <#
    生成密钥。必须走 Invoke-NativeStep（ProcessStartInfo 自拼命令行）而不是
    `& ssh-keygen @keygenArgs`：PowerShell 5.1 执行原生程序时会丢弃空字符串
    参数，-N ''（SSH_KEY_PASSPHRASE 未设置时的默认路径）被丢掉后 ssh-keygen
    收到的是 -N -C ...，程序报 "Too many arguments"——默认配置下根本生成不了
    密钥，且错误信息完全指错方向。Bash 版 `ssh-keygen -N "$passphrase"` 没有
    这层问题，照搬写法即踩坑。
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Type,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Passphrase,
    [Parameter(Mandatory=$true)][string]$Comment,
    [Parameter(Mandatory=$true)][string]$KeyFile
  )
  # 变量名避开 $args：那是 PowerShell 的自动变量（未绑定参数收集器）。实测
  # 在函数里给它赋值是可以生效的，但遮罩自动变量等于给未来的自己埋雷，
  # 何况这里根本没有未绑定参数要收集。真正的坑在别处，见下方注释。
  $keygenArgs = New-Object System.Collections.Generic.List[string]
  $keygenArgs.Add('-t'); $keygenArgs.Add($Type)
  if ($Type -eq 'rsa') { $keygenArgs.Add('-b'); $keygenArgs.Add('4096') }
  $keygenArgs.Add('-N'); $keygenArgs.Add($Passphrase)
  $keygenArgs.Add('-C'); $keygenArgs.Add($Comment)
  $keygenArgs.Add('-f'); $keygenArgs.Add($KeyFile)
  return (Invoke-NativeStep -Description ("ssh-keygen {0} {1}" -f $Type, $KeyFile) `
                           -FileName 'ssh-keygen' -Arguments $keygenArgs.ToArray())
}

function action_ssh_apply {
  param([Parameter(Mandatory=$true)][string]$Id)

  $type = Get-SshKeyType
  if ($null -eq $type) {
    Write-ErrorLog ("[{0}] SSH_KEY_TYPE 非法：{1}（应为 ed25519 或 rsa）" -f $Id, (Get-ConfigValue 'SSH_KEY_TYPE' 'ed25519'))
    return 2
  }
  $passphrase = Get-ConfigValue 'SSH_KEY_PASSPHRASE' ''

  if (-not (Test-CommandExists 'ssh-keygen')) {
    Write-ErrorLog ("[{0}] ssh-keygen 不可用；请先安装其依赖 openssh-client" -f $Id)
    return 1
  }

  $keyDir = Join-Path $script:HomeDir '.ssh'
  if (-not (Test-Path -LiteralPath $keyDir)) {
    $rc = Invoke-Step -Description ("创建 {0}" -f $keyDir) -Script {
      $null = New-Item -ItemType Directory -Path $keyDir -Force
      return 0
    }
    if ($rc -ne 0) { return 1 }
  }

  $keyfile = Join-Path $keyDir ("id_{0}" -f $type)
  if (Test-Path -LiteralPath $keyfile) {
    Write-InfoLog ("[{0}] 密钥已存在，跳过：{1}" -f $Id, $keyfile)
  } else {
    $comment = ("{0}@{1} {2}" -f $env:USERNAME, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))
    # Start-SshKeygen 内部自带步骤日志与输出收集，直接取返回值
    $rc = Start-SshKeygen -Type $type -Passphrase $passphrase -Comment $comment -KeyFile $keyfile
    if ($rc -ne 0) {
      Write-ErrorLog ("[{0}] ssh-keygen 失败（rc={1}）" -f $Id, $rc)
      return 1
    }

    # 登记失败必须删掉刚生成的密钥，避免无人记录的孤儿
    $dir = Get-StateActionDir -Name 'ssh'
    if ($null -eq $dir) {
      try { Remove-Item -LiteralPath $keyfile -Force -ErrorAction SilentlyContinue } catch { }
      try { Remove-Item -LiteralPath ($keyfile + '.pub') -Force -ErrorAction SilentlyContinue } catch { }
      return 1
    }
    $created = Join-Path $dir 'created.txt'
    try {
      [System.IO.File]::AppendAllText($created, $keyfile + "`r`n", (New-Object System.Text.UTF8Encoding $false))
      [System.IO.File]::AppendAllText($created, ($keyfile + '.pub') + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {
      Write-ErrorLog ("[{0}] 无法记录已创建的密钥，删除以避免孤儿" -f $Id)
      try { Remove-Item -LiteralPath $keyfile -Force -ErrorAction SilentlyContinue } catch { }
      try { Remove-Item -LiteralPath ($keyfile + '.pub') -Force -ErrorAction SilentlyContinue } catch { }
      return 1
    }
  }

  # 私钥 ACL 校验（Windows 上等价于 Linux 的 chmod 600）
  if (-not (Test-SshKeyAclOk -Path $keyfile)) {
    Write-WarnLog ("私钥 ACL 可能过松：{0}；建议仅保留当前用户访问" -f $keyfile)
  }

  Write-OkLog ("SSH 密钥就绪：{0}" -f $keyfile)
  return 0
}

function action_ssh_remove {
  param([Parameter(Mandatory=$true)][string]$Id)

  $dir = Get-StateActionDir -Name 'ssh'
  if ($null -eq $dir) { return 1 }
  $created = Join-Path $dir 'created.txt'
  if (-not (Test-Path -LiteralPath $created)) {
    Write-InfoLog ("[{0}] 没有本动作创建的密钥记录，跳过（不删除用户自有密钥）" -f $Id)
    return 0
  }

  try { $lines = @(Get-Content -LiteralPath $created -Encoding UTF8 -ErrorAction Stop) }
  catch { $lines = @() }
  if ($lines.Count -eq 0) {
    Write-InfoLog ("[{0}] 没有本动作创建的密钥记录，跳过（不删除用户自有密钥）" -f $Id)
    return 0
  }

  $rc = 0
  foreach ($p in $lines) {
    $path = $p.Trim()
    if ($path -eq '') { continue }
    if (Test-Path -LiteralPath $path) {
      try {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        Write-InfoLog ("  已删除：{0}" -f $path)
      } catch {
        Write-WarnLog ("  删除失败：{0}" -f $path)
        $rc = 1
      }
    }
  }

  if ($rc -ne 0) {
    Write-WarnLog '部分密钥删除失败；保留记录以便重试'
    return 1
  }

  try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  Write-OkLog ("[{0}] 已删除本动作创建的密钥" -f $Id)
  return 0
}

function action_ssh_verify {
  param([Parameter(Mandatory=$true)][string]$Id)

  $type = Get-SshKeyType
  if ($null -eq $type) {
    Write-ErrorLog ("[{0}] SSH_KEY_TYPE 非法" -f $Id)
    return 2
  }
  if (-not (Test-CommandExists 'ssh')) {
    Write-ErrorLog ("[{0}] ssh 不可用" -f $Id); return 1
  }

  $keyfile = Join-Path $script:HomeDir (".ssh\id_{0}" -f $type)
  if (-not (Test-Path -LiteralPath $keyfile)) {
    Write-ErrorLog ("[{0}] 私钥不存在：{1}" -f $Id, $keyfile)
    return 1
  }
  if (-not (Test-SshKeyAclOk -Path $keyfile)) {
    Write-ErrorLog ("[{0}] 私钥 ACL 过松：{1}（应仅当前用户可访问）" -f $Id, $keyfile)
    return 1
  }
  return 0
}

function action_ssh_status {
  param([Parameter(Mandatory=$true)][string]$Id)
  $type = Get-SshKeyType
  if ($null -eq $type) { $type = 'ed25519' }
  $keyfile = Join-Path $script:HomeDir (".ssh\id_{0}" -f $type)
  if (Test-Path -LiteralPath $keyfile) {
    Write-Host ("    已生成 {0}" -f $keyfile)
  } else {
    Write-Host ("    未生成 {0}" -f $keyfile)
  }
  return 0
}
