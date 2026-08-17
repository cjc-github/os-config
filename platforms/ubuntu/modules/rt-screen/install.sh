#!/usr/bin/env bash
# rt-screen —— 在当前桌面会话中关闭自动息屏和锁屏。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"
setup_traps
parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x

applied=""
is_gnome_session=0
if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  is_gnome_session=1
fi

if cmd_exists gsettings && (( is_gnome_session == 1 )); then
  cur_idle=$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)
  cur_lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true)
  cur_sidl=$(gsettings get org.gnome.desktop.screensaver idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)

  [[ "$cur_idle" == 0 && "${FORCE:-0}" != 1 ]] || \
    run_step "GNOME session idle-delay=0" gsettings set org.gnome.desktop.session idle-delay 0
  [[ "$cur_lock" == false && "${FORCE:-0}" != 1 ]] || \
    run_step "GNOME lock-enabled=false" gsettings set org.gnome.desktop.screensaver lock-enabled false
  [[ "$cur_sidl" == 0 && "${FORCE:-0}" != 1 ]] || \
    run_step "GNOME screensaver idle-delay=0" gsettings set org.gnome.desktop.screensaver idle-delay 0
  applied="gsettings"
elif cmd_exists gsettings && [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
  log_warn "检测到 GNOME，但当前没有可用的 D-Bus 会话，跳过 gsettings"
fi

if [[ -z "$applied" ]] && cmd_exists xset && [[ -n "${DISPLAY:-}" ]]; then
  run_step "关闭 X11 Screen Saver" xset s off
  run_step "关闭 X11 DPMS" xset -dpms
  run_step "关闭 X11 blanking" xset s noblank
  applied="xset"
fi

if [[ -z "$applied" ]]; then
  log_info "当前没有可配置的 GNOME D-Bus 或 X11 DISPLAY，会话级 screen 策略跳过"
  exit 0
fi
log_ok "screen 模块完成（策略：$applied）"
