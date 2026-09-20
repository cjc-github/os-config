#!/usr/bin/env bash
# engine/actions/syslog.sh —— journald 限容 + logrotate 校验 + oslogs 别名
# 接口：action_syslog_apply | action_syslog_remove | action_syslog_verify <id>
# 由 engine.sh 的 action_dispatch 惰性 source；不要加 set -e，不要调用 setup_traps。
#
# 依赖 catalog 中的 [log-tools]（apt 安装 lnav/bat/logrotate）；本动作不安装包。
#
# 参数（config/user.env）：
#   JOURNALD_MAX_USE  默认 200M（示例：200M、2G）
#
# 产物：
#   /etc/systemd/journald.conf.d/99-os-config.conf   （journald drop-in）
#   ~/.bashrc 中的 oslogs 别名托管块
#   ~/.local/bin/bat（batcat 的兼容软链）

_SYSLOG_DROPIN=/etc/systemd/journald.conf.d/99-os-config.conf
_SYSLOG_ALIAS_BEGIN='# >>> os-config oslogs >>>'
_SYSLOG_ALIAS_END='# <<< os-config oslogs <<<'

_syslog_bat_link() { printf '%s' "$HOME/.local/bin/bat"; }

_syslog_validate() {
  : "${JOURNALD_MAX_USE:=200M}"
  [[ "$JOURNALD_MAX_USE" =~ ^[1-9][0-9]*[KMGTP]?$ ]] || {
    log_error "JOURNALD_MAX_USE 格式无效：$JOURNALD_MAX_USE（示例：200M、2G）"
    return 2
  }
}

# 删除 ~/.bashrc 中的 oslogs 托管块（若存在）
_syslog_strip_aliases() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  file_contains "$file" "$_SYSLOG_ALIAS_BEGIN" || return 0
  sed -i -E "/$_SYSLOG_ALIAS_BEGIN/,/$_SYSLOG_ALIAS_END/d" "$file"
}

action_syslog_apply() {
  local id="$1" dropin_changed=0 tmp bashrc="$HOME/.bashrc" batcat_link batcat_bin

  _syslog_validate || return $?
  require_sudo || return 1

  # --- bat 兼容软链（batcat -> bat）---
  batcat_link="$(_syslog_bat_link)"
  if cmd_exists batcat && ! cmd_exists bat; then
    batcat_bin="$(command -v batcat)"
    run_step "链接 bat -> batcat（$batcat_link）" \
      install -d -m 0755 "$(dirname "$batcat_link")" || return 1
    run_step "创建软链 $batcat_link" ln -sf "$batcat_bin" "$batcat_link" || return 1
  elif ! cmd_exists batcat && ! cmd_exists bat; then
    log_warn "[$id] 未找到 bat/batcat（log-tools 是否已安装？），跳过软链"
  fi

  # --- journald drop-in ---
  tmp="$(mktemp)"; register_tmpfile "$tmp"
  {
    printf '[Journal]\n'
    printf 'Storage=persistent\n'
    printf 'SystemMaxUse=%s\n' "$JOURNALD_MAX_USE"
    printf 'ForwardToSyslog=no\n'
  } >"$tmp"

  if sudo test -f "$_SYSLOG_DROPIN" && sudo diff -q "$_SYSLOG_DROPIN" "$tmp" >/dev/null 2>&1 \
     && [[ "${FORCE:-0}" != 1 ]]; then
    log_info "[$id] journald drop-in 已是预期值"
  else
    register_rollback "$_SYSLOG_DROPIN" sudo
    run_step "创建 journald drop-in 目录" sudo install -d -m 0755 /etc/systemd/journald.conf.d || return 1
    run_step "写入 journald drop-in" sudo install -m 0644 "$tmp" "$_SYSLOG_DROPIN" || return 1
    dropin_changed=1
  fi

  # --- 移除旧版宽泛 logrotate 规则 ---
  if sudo test -e /etc/logrotate.d/99-os-config; then
    register_rollback /etc/logrotate.d/99-os-config sudo
    run_step "移除旧版宽泛 logrotate 规则" sudo rm -f -- /etc/logrotate.d/99-os-config || return 1
  fi
  run_step "校验 logrotate 全局配置" sudo logrotate --debug /etc/logrotate.conf || return 1

  # --- oslogs 别名块 ---
  if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$_SYSLOG_ALIAS_BEGIN"; then
    if [[ "${FORCE:-0}" == 1 ]]; then
      register_rollback "$bashrc"
      _syslog_strip_aliases "$bashrc"
    else
      log_info "[$id] $bashrc 已含 oslogs 别名，跳过重写（--force 可重写）"
      bashrc=""
    fi
  else
    register_rollback "$bashrc"
    touch -- "$bashrc" 2>/dev/null || true
  fi

  if [[ -n "$bashrc" ]]; then
    {
      printf '\n%s\n' "$_SYSLOG_ALIAS_BEGIN"
      printf "alias oslogs-system='journalctl -p err -e --no-pager | tail -n 200'\n"
      printf "alias oslogs-auth='sudo tail -n 200 /var/log/auth.log 2>/dev/null || sudo journalctl -u systemd-logind -e --no-pager | tail -n 200'\n"
      printf "alias oslogs-apt='sudo tail -n 200 /var/log/apt/history.log 2>/dev/null'\n"
      printf "alias oslogs-syslog='sudo journalctl -e --no-pager | tail -n 200'\n"
      printf "alias oslogs='oslogs-system && echo \"---auth---\" && oslogs-auth && echo \"---apt---\" && oslogs-apt'\n"
      printf '%s\n' "$_SYSLOG_ALIAS_END"
    } >>"$bashrc"
    log_ok "[$id] oslogs 别名已写入 $bashrc（新 shell 生效）"
  fi

  # 重启放到所有写入与校验之后
  if (( dropin_changed == 1 )); then
    run_step "重启 systemd-journald" sudo systemctl restart systemd-journald || return 1
  fi
  log_ok "[$id] journald 限容与日志别名配置完成"
}

action_syslog_remove() {
  local id="$1" bashrc="$HOME/.bashrc" batcat_link
  require_sudo || return 1

  if sudo test -e "$_SYSLOG_DROPIN"; then
    register_rollback "$_SYSLOG_DROPIN" sudo
    run_step "删除 journald drop-in" sudo rm -f -- "$_SYSLOG_DROPIN" || return 1
    run_step "重启 systemd-journald" sudo systemctl restart systemd-journald || true
  else
    log_debug "[$id] journald drop-in 不存在"
  fi

  if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$_SYSLOG_ALIAS_BEGIN"; then
    register_rollback "$bashrc"
    _syslog_strip_aliases "$bashrc"
    log_ok "[$id] 已移除 oslogs 别名块"
  fi

  batcat_link="$(_syslog_bat_link)"
  if [[ -L "$batcat_link" ]]; then
    rm -f -- "$batcat_link" && log_ok "[$id] 已移除软链：$batcat_link"
  fi
  log_ok "[$id] 日志配置已还原"
}

action_syslog_verify() {
  local id="$1" bashrc="$HOME/.bashrc" rc=0
  _syslog_validate || return $?

  if sudo -n test -f "$_SYSLOG_DROPIN" 2>/dev/null; then
    if sudo -n grep -q '^Storage=persistent$' "$_SYSLOG_DROPIN" 2>/dev/null \
       && sudo -n grep -q "^SystemMaxUse=${JOURNALD_MAX_USE}$" "$_SYSLOG_DROPIN" 2>/dev/null; then
      log_debug "[$id] journald drop-in 内容正确"
    else
      log_error "[$id] journald drop-in 内容不符预期：$_SYSLOG_DROPIN"
      rc=1
    fi
  else
    log_error "[$id] 缺少 journald drop-in：$_SYSLOG_DROPIN（需 sudo 权限读取）"
    rc=1
  fi

  if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$_SYSLOG_ALIAS_BEGIN"; then
    log_debug "[$id] oslogs 别名块存在"
  else
    log_error "[$id] ~/.bashrc 缺少 oslogs 别名块"
    rc=1
  fi

  (( rc == 0 )) || return 1
  log_ok "[$id] 日志配置校验通过"
}
