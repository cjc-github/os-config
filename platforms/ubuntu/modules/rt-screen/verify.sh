#!/usr/bin/env bash
# rt-screen/verify —— 验证 GNOME 或 X11 的息屏/锁屏设置。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"

if cmd_exists gsettings && [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  fail=0
  idle=$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)
  lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true)
  sidl=$(gsettings get org.gnome.desktop.screensaver idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)
  [[ "$idle" == 0 ]] && log_ok "GNOME session idle-delay=0" || { log_error "GNOME session idle-delay=${idle:-<不可读>}（预期 0）"; fail=1; }
  [[ "$lock" == false ]] && log_ok "GNOME lock-enabled=false" || { log_error "GNOME lock-enabled=${lock:-<不可读>}（预期 false）"; fail=1; }
  [[ "$sidl" == 0 ]] && log_ok "GNOME screensaver idle-delay=0" || { log_error "GNOME screensaver idle-delay=${sidl:-<不可读>}（预期 0）"; fail=1; }
  exit "$fail"
fi

if cmd_exists xset && [[ -n "${DISPLAY:-}" ]]; then
  if ! output=$(xset q 2>/dev/null); then
    log_error "xset q 无法读取 DISPLAY=$DISPLAY"
    exit 1
  fi
  fail=0
  grep -Eq 'timeout:[[:space:]]+0([[:space:]]|$)' <<<"$output" && log_ok "X11 Screen Saver timeout=0" || { log_error "X11 Screen Saver 仍启用"; fail=1; }
  grep -q 'DPMS is Disabled' <<<"$output" && log_ok "X11 DPMS 已关闭" || { log_error "X11 DPMS 仍启用"; fail=1; }
  grep -Eq 'prefer blanking:[[:space:]]+no' <<<"$output" && log_ok "X11 blanking 已关闭" || { log_error "X11 blanking 仍启用"; fail=1; }
  exit "$fail"
fi

log_ok "当前无可验证的图形会话，screen 模块按 skipped 处理（验证通过）"
