#!/usr/bin/env bash
# =============================================================================
# 模块：rt-screen/verify  ——  验证 rt-screen 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - 无图形环境（无 DISPLAY 且无 gsettings）→ 标记 skipped 并通过
#   - GNOME 会话：gsettings org.gnome.desktop.session idle-delay 是否为 0
#   - X11：xset q 是否可读（Screen Saver 段）
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

# Server 版无图形环境 → 标记 skipped 并通过
if [[ -z "${DISPLAY:-}" ]] && ! cmd_exists gsettings; then
  log_ok "无图形环境，screen 模块按 skipped 处理（验证通过）"
  exit 0
fi

fail=0
if cmd_exists gsettings \
   && [[ -n "${XDG_CURRENT_DESKTOP:-}" && "$XDG_CURRENT_DESKTOP" == *GNOME* \
        || -d "$HOME/.config/dconf" ]]; then
  v=$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null || echo "")
  if [[ "$v" == "0" ]]; then
    log_ok "GNOME idle-delay = 0"
  else
    log_error "GNOME idle-delay = '${v:-<未设置>}' (预期 0)"
    fail=1
  fi
elif cmd_exists xset && [[ -n "${DISPLAY:-}" ]]; then
  # xset q 看 Screen Saver / DPMS 状态
  if xset q 2>/dev/null | grep -q "Screen Saver" >/dev/null; then
    log_ok "xset 可读"
  else
    log_warn "xset q 输出异常（仍可接受）"
  fi
else
  log_warn "无可验证的图形工具"
fi
exit $fail
