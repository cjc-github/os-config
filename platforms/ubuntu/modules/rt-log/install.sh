#!/usr/bin/env bash
# rt-log —— 安装日志工具、配置 journald drop-in，并注入日志查看别名。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"
setup_traps
parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x

: "${JOURNALD_MAX_USE:=200M}"
[[ "$JOURNALD_MAX_USE" =~ ^[1-9][0-9]*[KMGTP]?$ ]] || {
  log_error "JOURNALD_MAX_USE 格式无效：$JOURNALD_MAX_USE（示例：200M、2G）"
  exit 2
}

wait_for_apt_lock
missing=()
for pkg in lnav bat logrotate; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' || missing+=("$pkg")
done
if (( ${#missing[@]} > 0 )); then
  run_step "apt install ${missing[*]}" \
    with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing[@]}"
else
  log_info "lnav/bat/logrotate 已安装"
fi

if cmd_exists batcat && ! cmd_exists bat; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  log_info "已链接 bat -> batcat"
fi

# 使用 drop-in，避免直接改写发行版维护的 /etc/systemd/journald.conf。
journald_dropin=/etc/systemd/journald.conf.d/99-os-config.conf
journald_changed=0
tmpfile=$(mktemp)
register_tmpfile "$tmpfile"
cat >"$tmpfile" <<EOF_DROPIN
[Journal]
Storage=persistent
SystemMaxUse=${JOURNALD_MAX_USE}
ForwardToSyslog=no
EOF_DROPIN
if sudo diff -q "$journald_dropin" "$tmpfile" >/dev/null 2>&1 && [[ "${FORCE:-0}" != 1 ]]; then
  log_info "journald drop-in 已是预期值"
else
  register_rollback "$journald_dropin" sudo
  run_step "创建 journald drop-in 目录" sudo install -d -m 0755 /etc/systemd/journald.conf.d
  run_step "写入 journald drop-in" sudo install -m 0644 "$tmpfile" "$journald_dropin"
  journald_changed=1
fi

# 旧版本曾创建覆盖 /var/log/*.log 的宽泛规则，可能与发行版规则重复；安全移除受管文件。
legacy_logrotate=/etc/logrotate.d/99-os-config
if sudo test -e "$legacy_logrotate"; then
  register_rollback "$legacy_logrotate" sudo
  run_step "移除旧版宽泛 logrotate 规则" sudo rm -f -- "$legacy_logrotate"
fi
run_step "校验 logrotate 全局配置" sudo logrotate --debug /etc/logrotate.conf

bashrc="$HOME/.bashrc"
marker="# >>> os-config oslogs >>>"
marker_end="# <<< os-config oslogs <<<"
write_aliases=1
if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$marker"; then
  if [[ "${FORCE:-0}" == 1 ]]; then
    register_rollback "$bashrc"
    sed -i -E "/${marker}/,/${marker_end}/d" "$bashrc"
  else
    log_info "$bashrc 已含 oslogs 别名，跳过重写"
    write_aliases=0
  fi
else
  register_rollback "$bashrc"
  touch "$bashrc"
fi

if (( write_aliases == 1 )); then
  cat >>"$bashrc" <<'EOF_ALIASES'

# >>> os-config oslogs >>>
alias oslogs-system='journalctl -p err -e --no-pager | tail -n 200'
alias oslogs-auth='sudo tail -n 200 /var/log/auth.log 2>/dev/null || sudo journalctl -u systemd-logind -e --no-pager | tail -n 200'
alias oslogs-apt='sudo tail -n 200 /var/log/apt/history.log 2>/dev/null'
alias oslogs-syslog='sudo journalctl -e --no-pager | tail -n 200'
alias oslogs='oslogs-system && echo "---auth---" && oslogs-auth && echo "---apt---" && oslogs-apt'
# <<< os-config oslogs <<<
EOF_ALIASES
  log_ok "oslogs 别名已写入 $bashrc"
  log_warn "新 shell 才生效；当前会话可执行：source ~/.bashrc"
fi

# 将服务重启放到所有配置写入和校验之后；后续步骤失败时不会留下已加载的新配置。
if (( journald_changed == 1 )); then
  run_step "重启 systemd-journald" sudo systemctl restart systemd-journald
fi
log_ok "log 模块安装完成"
