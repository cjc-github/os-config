#!/usr/bin/env bash
# =============================================================================
# 模块：rt-log  ——  lnav/bat + journald 持久化 + logrotate 调优 + oslogs 别名
# 平台：ubuntu24
# 作用：安装日志查看工具（lnav/bat/logrotate），持久化 journald 并限容，调优
#       logrotate，并在 ~/.bashrc 注入 oslogs 系列别名
# 依赖：base（sys-base 提供的 apt 等基础工具；本模块 NEEDS_SUDO=1）
# =============================================================================
#
# 【可配置参数】（来自 config/user.env，复制 user.env.example 修改）
#   JOURNALD_MAX_USE=200M        # journald SystemMaxUse 上限
#   LOGROTATE_KEEP_WEEKS=4       # logrotate 保留周数（rotate N）
#
#   说明：本模块无版本号参数（apt 装 lnav/bat/logrotate 跟随发行版版本）。
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   强制重写 journald/logrotate 配置与 oslogs 别名块
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=log）
#   $MODULE_DIR   本模块目录绝对路径
#   $LOG_FILE     本次运行的日志文件
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"
setup_traps   # 注册 EXIT/INT/TERM/ERR trap：失败时清理临时文件 + 回滚备份 + 打印失败命令
wait_for_apt_lock || log_warn "apt 锁检测失败（可能无 sudo），继续尝试"

# 用户参数默认值（user.env 未注入时兜底）
: "${JOURNALD_MAX_USE:=200M}"
: "${LOGROTATE_KEEP_WEEKS:=4}"

# ---------------------------------------------------------------------------
# 1) 安装日志工具（幂等：三个都装则跳过）
# ---------------------------------------------------------------------------
if cmd_exists lnav && cmd_exists batcat && cmd_exists logrotate; then
  log_info "lnav/bat/logrotate 已安装，跳过"
else
  run_step "apt install lnav bat logrotate" \
    with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y install lnav bat logrotate
fi

# bat 在 ubuntu 上是 batcat（避免和另一个包冲突），建别名 bat
if cmd_exists batcat && ! cmd_exists bat; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  log_info "已链接 bat -> batcat"
fi

# ---------------------------------------------------------------------------
# 2) journald 持久化目录 + 限容（幂等：逐键先读当前值，已是目标则跳过）
# ---------------------------------------------------------------------------
journald_conf=/etc/systemd/journald.conf
cur_storage=$(sudo grep -E "^Storage="          "$journald_conf" 2>/dev/null | tail -1 | cut -d= -f2- || echo "")
cur_maxuse=$(sudo grep -E "^SystemMaxUse="      "$journald_conf" 2>/dev/null | tail -1 | cut -d= -f2- || echo "")
cur_fwd=$(sudo grep -E "^ForwardToSyslog="      "$journald_conf" 2>/dev/null | tail -1 | cut -d= -f2- || echo "")

# 任一键不是目标值 → 整体需要改
if [[ "$cur_storage" == "persistent" && "$cur_maxuse" == "$JOURNALD_MAX_USE" && "$cur_fwd" == "no" && "${FORCE:-0}" != 1 ]]; then
  log_info "journald 配置已为目标值，跳过 sed / restart"
else
  # 备份（只第一次）
  if [[ ! -f "${journald_conf}.bak.$(date +%Y%m%d)" ]]; then
    sudo cp -p "$journald_conf" "${journald_conf}.bak.$(date +%Y%m%d)" 2>/dev/null || true
  fi
  [[ "$cur_storage" == "persistent" && "${FORCE:-0}" != 1 ]] || \
    run_step "journald Storage=persistent" \
      sudo sed -i -E "s|^#?\\s*Storage=.*|Storage=persistent|" "$journald_conf"
  [[ "$cur_maxuse" == "$JOURNALD_MAX_USE" && "${FORCE:-0}" != 1 ]] || \
    run_step "journald SystemMaxUse=$JOURNALD_MAX_USE" \
      sudo sed -i -E "s|^#?\\s*SystemMaxUse=.*|SystemMaxUse=${JOURNALD_MAX_USE}|" "$journald_conf"
  [[ "$cur_fwd" == "no" && "${FORCE:-0}" != 1 ]] || \
    run_step "journald ForwardToSyslog=no" \
      sudo sed -i -E "s|^#?\\s*ForwardToSyslog=.*|ForwardToSyslog=no|" "$journald_conf"
  run_step "重启 journald" sudo systemctl restart systemd-journald || true
fi

# ---------------------------------------------------------------------------
# 3) logrotate 调优（幂等：先 diff，内容一致则跳过）
# ---------------------------------------------------------------------------
logrotate_conf=/etc/logrotate.d/99-os-config
tmpfile=$(mktemp)
register_tmpfile "$tmpfile"
cat > "$tmpfile" <<EOF
/var/log/*.log {
    weekly
    rotate ${LOGROTATE_KEEP_WEEKS}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF
if sudo diff -q "$logrotate_conf" "$tmpfile" >/dev/null 2>&1 && [[ "${FORCE:-0}" != 1 ]]; then
  log_info "logrotate 配置已是预期值，跳过"
else
  run_step "写入 logrotate 配置" sudo cp "$tmpfile" "$logrotate_conf"
  log_ok "logrotate 配置写入 $logrotate_conf"
fi
rm -f "$tmpfile"

# ---------------------------------------------------------------------------
# 4) oslogs 别名到 ~/.bashrc（幂等：搜标记块）
# ---------------------------------------------------------------------------
bashrc="$HOME/.bashrc"
backup_file "$bashrc"
marker="# >>> os-config oslogs >>>"
if file_contains "$bashrc" "$marker"; then
  if [[ "${FORCE:-0}" = 1 ]]; then
    sed -i -E "/${marker}/,/# <<< os-config oslogs <<</d" "$bashrc"
  else
    log_info "$HOME/.bashrc 已含 oslogs 别名，跳过"
    exit 0
  fi
fi

cat >>"$bashrc" <<'EOF'

# >>> os-config oslogs >>>
# 快捷查看常用日志（带颜色，自动 pager）
alias oslogs-system='journalctl -p err -e --no-pager | tail -n 200'
alias oslogs-auth='sudo tail -n 200 /var/log/auth.log 2>/dev/null || sudo journalctl -u systemd-logind -e --no-pager | tail -n 200'
alias oslogs-apt='sudo tail -n 200 /var/log/apt/history.log 2>/dev/null'
alias oslogs-syslog='sudo journalctl -e --no-pager | tail -n 200'
alias oslogs='oslogs-system && echo "---auth---" && oslogs-auth && echo "---apt---" && oslogs-apt'
# <<< os-config oslogs <<<
EOF
log_ok "oslogs 别名已写入 ~/.bashrc"
log_warn "新 shell 才生效；当前会话可手动 source：source ~/.bashrc"
