#!/usr/bin/env bash
# engine/actions/nosuspend.sh —— 关闭桌面息屏与自动锁屏（会话级，尽力而为）
# 接口：action_nosuspend_apply | action_nosuspend_remove | action_nosuspend_verify <id>
# 由 engine.sh 的 action_dispatch 惰性 source；不要加 set -e，不要调用 setup_traps。
#
# 无文件产物（artifacts 为空）：GNOME 走 gsettings，X11 走 xset。
# 无图形会话时安静跳过（不视为失败）——无头服务器场景属正常；
# 有会话但写入失败时记 failed 并返回非 0。

_nosuspend_has_gnome_session() {
  [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]
}

action_nosuspend_apply() {
  local id="$1" applied="" failed=0 cur_idle cur_lock cur_sidl

  if cmd_exists gsettings && _nosuspend_has_gnome_session; then
    cur_idle=$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)
    cur_lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true)
    cur_sidl=$(gsettings get org.gnome.desktop.screensaver idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)

    if [[ "$cur_idle" != 0 || "${FORCE:-0}" == 1 ]]; then
      run_step "GNOME session idle-delay=0" gsettings set org.gnome.desktop.session idle-delay 0 || failed=$((failed + 1))
    fi
    if [[ "$cur_lock" != false || "${FORCE:-0}" == 1 ]]; then
      run_step "GNOME lock-enabled=false" gsettings set org.gnome.desktop.screensaver lock-enabled false || failed=$((failed + 1))
    fi
    if [[ "$cur_sidl" != 0 || "${FORCE:-0}" == 1 ]]; then
      run_step "GNOME screensaver idle-delay=0" gsettings set org.gnome.desktop.screensaver idle-delay 0 || failed=$((failed + 1))
    fi
    applied="gsettings"
  elif cmd_exists gsettings && [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
    log_warn "[$id] 检测到 GNOME，但当前无可用 D-Bus 会话，跳过 gsettings"
  fi

  if [[ -z "$applied" ]] && cmd_exists xset && [[ -n "${DISPLAY:-}" ]]; then
    run_step "关闭 X11 Screen Saver" xset s off || failed=$((failed + 1))
    run_step "关闭 X11 DPMS" xset -dpms || failed=$((failed + 1))
    run_step "关闭 X11 blanking" xset s noblank || failed=$((failed + 1))
    applied="xset"
  fi

  if [[ -z "$applied" ]]; then
    log_info "[$id] 当前无 GNOME D-Bus 或 X11 DISPLAY，会话级 screen 策略跳过"
    return 0
  fi
  if (( failed > 0 )); then
    log_error "[$id] 息屏/锁屏策略有 $failed 项写入失败（策略：$applied）"
    return 1
  fi
  log_ok "[$id] 已关闭息屏与锁屏（策略：$applied）"
}

action_nosuspend_remove() {
  local id="$1" applied=""

  if cmd_exists gsettings && _nosuspend_has_gnome_session; then
    # 还原为发行版默认：idle-delay 300s（5 分钟），锁屏开启
    run_step "还原 GNOME session idle-delay" \
      gsettings reset org.gnome.desktop.session idle-delay || true
    run_step "还原 GNOME lock-enabled" \
      gsettings reset org.gnome.desktop.screensaver lock-enabled || true
    run_step "还原 GNOME screensaver idle-delay" \
      gsettings reset org.gnome.desktop.screensaver idle-delay || true
    applied="gsettings"
  fi

  if [[ -z "$applied" ]] && cmd_exists xset && [[ -n "${DISPLAY:-}" ]]; then
    run_step "还原 X11 Screen Saver" xset s default || true
    run_step "还原 X11 DPMS" xset +dpms || true
    applied="xset"
  fi

  if [[ -z "$applied" ]]; then
    log_info "[$id] 当前无图形会话，无需还原"
    return 0
  fi
  log_ok "[$id] 已还原息屏与锁屏策略（策略：$applied）"
}

action_nosuspend_verify() {
  local id="$1"
  if ! cmd_exists gsettings || ! _nosuspend_has_gnome_session; then
    log_info "[$id] 无 GNOME 会话，跳过校验（尽力而为动作）"
    return 0
  fi
  local idle lock sidl
  idle=$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)
  lock=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true)
  sidl=$(gsettings get org.gnome.desktop.screensaver idle-delay 2>/dev/null | sed -E 's/^uint32[[:space:]]+//' || true)
  local rc=0
  [[ "$idle" == 0 ]] || { log_error "[$id] session idle-delay=$idle（应为 0）"; rc=1; }
  [[ "$lock" == false ]] || { log_error "[$id] lock-enabled=$lock（应为 false）"; rc=1; }
  [[ "$sidl" == 0 ]] || { log_error "[$id] screensaver idle-delay=$sidl（应为 0）"; rc=1; }
  (( rc == 0 )) || return 1
  log_ok "[$id] 息屏/锁屏策略校验通过"
}
