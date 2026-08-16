#!/usr/bin/env bash
# =============================================================================
# 模块：rt-screen  ——  关闭息屏/锁屏
# 平台：ubuntu24
# 作用：自动检测图形环境并关闭息屏/锁屏；多策略：GNOME(gsettings) → X11(xset) →
#       Server 版（无图形环境）跳过
# 依赖：base（sys-base 提供的基础工具；本模块 NEEDS_SUDO=0）
# =============================================================================
#
# 【可配置参数】
#   无。本模块自动检测 GNOME / X11 / Server 环境，不涉及版本号或用户参数。
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   忽略幂等判断，强制重设 gsettings 的 idle-delay / lock-enabled
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=screen）
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

applied=""

# ---------------------------------------------------------------------------
# 1) GNOME gsettings（最理想）：需在 GNOME 会话中
# ---------------------------------------------------------------------------
if cmd_exists gsettings; then
  # 是否有 GNOME session（通过 DBUS/GNOME 配置目录）
  if [[ -n "${XDG_CURRENT_DESKTOP:-}" && "$XDG_CURRENT_DESKTOP" == *GNOME* ]] \
     || [[ -d "$HOME/.config/dconf" ]]; then

    # 幂等：先读当前值，已是目标则跳过
    cur_idle=$(gsettings get org.gnome.desktop.session        idle-delay        2>/dev/null || echo "")
    cur_lock=$(gsettings get org.gnome.desktop.screensaver    lock-enabled      2>/dev/null || echo "")
    cur_sidl=$(gsettings get org.gnome.desktop.screensaver    idle-delay        2>/dev/null || echo "")

    if [[ "$cur_idle" == "0" && "${FORCE:-0}" != 1 ]]; then
      log_info "session idle-delay 已是 0，跳过"
    else
      run_step "gsettings session idle-delay 0" \
        gsettings set org.gnome.desktop.session idle-delay 0
    fi

    if [[ "$cur_lock" == "false" && "${FORCE:-0}" != 1 ]]; then
      log_info "screensaver lock-enabled 已是 false，跳过"
    else
      run_step "gsettings 关闭锁屏" \
        gsettings set org.gnome.desktop.screensaver lock-enabled false
    fi

    if [[ "$cur_sidl" == "0" && "${FORCE:-0}" != 1 ]]; then
      log_info "screensaver idle-delay 已是 0，跳过"
    else
      run_step "gsettings screensaver idle-delay 0" \
        gsettings set org.gnome.desktop.screensaver idle-delay 0 2>/dev/null || true
    fi
    applied="gsettings"
  else
    log_info "gsettings 存在但不在 GNOME 会话，跳过 GNOME 策略"
  fi
fi

# ---------------------------------------------------------------------------
# 2) xset（X11 桌面）：DISPLAY 可用时关闭屏保/DPMS
# ---------------------------------------------------------------------------
if [[ -z "$applied" ]] && cmd_exists xset && [[ -n "${DISPLAY:-}" ]]; then
  run_step "xset s off / -dpms" bash -c 'xset s off; xset -dpms; xset s noblank'
  applied="xset"
fi

# ---------------------------------------------------------------------------
# 3) Server 版兜底：无图形环境则跳过
# ---------------------------------------------------------------------------
if [[ -z "$applied" && -z "${DISPLAY:-}" ]]; then
  log_info "无图形环境（DISPLAY 未设置且无 gsettings/xset），rt-screen 跳过"
  log_info "（如需禁止系统休眠可在用户层手动配 systemd-inhibit 或 logind.conf）"
  exit 0
fi

log_ok "screen 模块完成（策略：$applied）"
