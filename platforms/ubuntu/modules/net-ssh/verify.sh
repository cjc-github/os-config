#!/usr/bin/env bash
# net-ssh/verify —— 验证 SSH 客户端、可选服务端和用户密钥。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"

: "${SSH_INSTALL_SERVER:=false}"
: "${SSH_KEY_TYPE:=ed25519}"
fail=0

if cmd_exists ssh; then
  log_ok "ssh: $(ssh -V 2>&1)"
else
  log_error "ssh 客户端未安装"
  fail=1
fi

if [[ "$SSH_INSTALL_SERVER" == true ]]; then
  if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q '^install ok installed$' && cmd_exists sshd; then
    log_ok "openssh-server 已安装"
  else
    log_error "SSH_INSTALL_SERVER=true，但 openssh-server/sshd 不可用"
    fail=1
  fi
else
  log_ok "SSH 服务端未启用，跳过服务端验证"
fi

case "$SSH_KEY_TYPE" in
  ed25519|rsa) ;;
  *) log_error "不支持的 SSH_KEY_TYPE=$SSH_KEY_TYPE"; exit 2 ;;
esac
keyfile="$HOME/.ssh/id_${SSH_KEY_TYPE}"
if [[ -f "$keyfile" && -f "${keyfile}.pub" ]]; then
  log_ok "密钥存在：$keyfile"
  perm=$(stat -c '%a' "$keyfile")
  if [[ "$perm" == 600 ]]; then
    log_ok "私钥权限 600"
  else
    log_error "私钥权限 $perm（预期 600）"
    fail=1
  fi
else
  log_error "密钥对不存在：$keyfile / ${keyfile}.pub"
  fail=1
fi
exit "$fail"
