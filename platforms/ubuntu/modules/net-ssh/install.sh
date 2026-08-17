#!/usr/bin/env bash
# net-ssh —— 安装 SSH 客户端并生成用户密钥；服务端默认不安装。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"
setup_traps
parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x

: "${SSH_INSTALL_SERVER:=false}"
: "${SSH_KEY_TYPE:=ed25519}"
: "${SSH_KEY_PASSPHRASE:=}"

case "$SSH_KEY_TYPE" in
  ed25519|rsa) ;;
  *) log_error "不支持的 SSH_KEY_TYPE=$SSH_KEY_TYPE（仅支持 ed25519/rsa）"; exit 2 ;;
esac
[[ "$SSH_INSTALL_SERVER" == true || "$SSH_INSTALL_SERVER" == false ]] || {
  log_error "SSH_INSTALL_SERVER 只能是 true 或 false"
  exit 2
}

wait_for_apt_lock
packages=(openssh-client)
[[ "$SSH_INSTALL_SERVER" == true ]] && packages+=(openssh-server)
missing=()
for pkg in "${packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
    missing+=("$pkg")
  fi
done
if (( ${#missing[@]} > 0 )); then
  run_step "apt install ${missing[*]}" \
    with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing[@]}"
else
  log_info "SSH 软件包已安装：${packages[*]}"
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
keyfile="$HOME/.ssh/id_${SSH_KEY_TYPE}"
if [[ -f "$keyfile" ]]; then
  log_info "密钥已存在，跳过：$keyfile"
else
  comment="${USER:-$(id -un)}@$(hostname) $(date +%Y%m%d)"
  if [[ "$SSH_KEY_TYPE" == ed25519 ]]; then
    run_step "ssh-keygen ed25519" ssh-keygen -t ed25519 -N "$SSH_KEY_PASSPHRASE" -C "$comment" -f "$keyfile"
  else
    run_step "ssh-keygen rsa 4096" ssh-keygen -t rsa -b 4096 -N "$SSH_KEY_PASSPHRASE" -C "$comment" -f "$keyfile"
  fi
fi

chmod 600 "$keyfile"
[[ ! -f "${keyfile}.pub" ]] || chmod 644 "${keyfile}.pub"
log_ok "ssh 模块安装完成（server=$SSH_INSTALL_SERVER）"
