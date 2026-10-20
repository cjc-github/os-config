#!/usr/bin/env bash
# engine/actions/ssh.sh —— 生成 SSH 用户密钥（~/.ssh）
# 接口：action_ssh_apply | action_ssh_remove | action_ssh_verify <id>
# 由 engine.sh 的 action_dispatch 惰性 source；不要加 set -e，不要调用 setup_traps。
#
# 依赖 catalog 中的 [openssh-client]（apt 安装 openssh-client）；本动作不安装包。
# 服务端由独立条目 [openssh-server] 负责，不再用布尔开关。
#
# 参数（config/user.env）：
#   SSH_KEY_TYPE       ed25519（默认）| rsa
#   SSH_KEY_PASSPHRASE 默认空（无口令）
#
# remove 语义：只删除「本动作创建」的密钥（记录在 $STATE_DIR/actions/ssh/created.txt），
#   不删除用户自行生成的其他密钥，也不删除 ~/.ssh 目录。

_SSH_KEY_DIR="$HOME/.ssh"

# 输出 created.txt 路径
_ssh_action_dir() {
  local d
  d="$(state_action_dir ssh)" || return 1
  printf '%s' "$d"
}

_ssh_key_type() {
  : "${SSH_KEY_TYPE:=ed25519}"
  : "${SSH_KEY_PASSPHRASE:=}"
  case "$SSH_KEY_TYPE" in
    ed25519|rsa) ;;
    *) log_error "不支持的 SSH_KEY_TYPE=$SSH_KEY_TYPE（仅支持 ed25519/rsa）"; return 2 ;;
  esac
  printf '%s' "$SSH_KEY_TYPE"
}

action_ssh_apply() {
  local id="$1" type keyfile comment dir passphrase
  type="$(_ssh_key_type)" || return $?
  # _ssh_key_type 在命令替换的子 shell 中执行，其默认值无法回传到本函数；
  # 这里自行兜底，避免 set -u 下引用未绑定的 SSH_KEY_PASSPHRASE。
  passphrase="${SSH_KEY_PASSPHRASE:-}"
  if ! cmd_exists ssh-keygen; then
    log_error "[$id] ssh-keygen 不可用；请先安装其依赖 openssh-client"
    return 1
  fi

  run_step "创建 $HOME/.ssh（0700）" mkdir -p -- "$_SSH_KEY_DIR" || return 1
  chmod 700 -- "$_SSH_KEY_DIR"

  keyfile="$_SSH_KEY_DIR/id_${type}"
  if [[ -f "$keyfile" ]]; then
    log_info "[$id] 密钥已存在，跳过：$keyfile"
  else
    comment="${USER:-$(id -un)}@$(hostname) $(date +%Y%m%d)"
    if [[ "$type" == ed25519 ]]; then
      run_step "ssh-keygen ed25519" \
        ssh-keygen -t ed25519 -N "$passphrase" -C "$comment" -f "$keyfile" || return 1
    else
      run_step "ssh-keygen rsa 4096" \
        ssh-keygen -t rsa -b 4096 -N "$passphrase" -C "$comment" -f "$keyfile" || return 1
    fi
    dir="$(_ssh_action_dir)" || {
      # 密钥已生成但无法登记；不清理会变成 remove 永远删不掉的孤儿文件。
      log_error "[$id] 无法记录密钥来源，已回滚：$keyfile"
      rm -f -- "$keyfile" "${keyfile}.pub"
      return 1
    }
    if ! printf '%s\n%s\n' "$keyfile" "${keyfile}.pub" >>"$dir/created.txt"; then
      log_error "[$id] 无法记录密钥来源，已回滚：$keyfile"
      rm -f -- "$keyfile" "${keyfile}.pub"
      return 1
    fi
    log_ok "[$id] 已生成密钥：$keyfile"
  fi

  chmod 600 -- "$keyfile" 2>/dev/null || true
  [[ ! -f "${keyfile}.pub" ]] || chmod 644 -- "${keyfile}.pub" 2>/dev/null || true
  log_ok "[$id] ssh 密钥就绪（type=$type）"
}

action_ssh_remove() {
  local id="$1" dir list f rc=0
  dir="$(state_action_dir ssh)"
  list="$dir/created.txt"
  if [[ ! -s "$list" ]]; then
    log_info "[$id] 没有本动作创建的密钥记录，跳过（不删除用户自有密钥）"
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -f "$f" ]]; then
      if rm -f -- "$f"; then
        log_ok "[$id] 已删除：$f"
      else
        log_error "[$id] 删除失败：$f"
        rc=1
      fi
    fi
  done <"$list"
  if (( rc != 0 )); then
    log_warn "[$id] 部分密钥删除失败，保留记录以便重试：$list"
    return 1
  fi
  rm -rf -- "$dir"
  log_ok "[$id] 已清理本动作创建的 SSH 密钥"
}

action_ssh_verify() {
  local id="$1" type keyfile
  type="$(_ssh_key_type)" || return $?
  if ! cmd_exists ssh; then
    log_error "[$id] ssh 命令不可用"
    return 1
  fi
  keyfile="$_SSH_KEY_DIR/id_${type}"
  if [[ ! -f "$keyfile" ]]; then
    log_error "[$id] 未找到私钥：$keyfile"
    return 1
  fi
  local mode
  mode="$(stat -c '%a' "$keyfile" 2>/dev/null || stat -f '%Lp' "$keyfile" 2>/dev/null || echo '')"
  if [[ "$mode" != "600" ]]; then
    log_error "[$id] 私钥权限应为 600，实际为 ${mode:-未知}：$keyfile"
    return 1
  fi
  log_ok "[$id] 私钥存在且权限正确（$keyfile）"
}
