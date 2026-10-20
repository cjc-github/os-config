#!/usr/bin/env bash
# engine/lib/backends.sh —— 包管理器后端适配器
# ---------------------------------------------------------------------------
# 每个后端实现五个动词：install / update / remove / verify / status。
# 由 engine.sh 经 backend_dispatch 调用；后端只读 CAT_* 数组，不认识具体工具名。
# 新增后端 = 在此文件加 _backend_<name>_<verb> 函数 + 在 BACKEND_SUPPORTED 登记。
# 不要加 set -e。
# ---------------------------------------------------------------------------

# 已实现的后端。catalog_validate 与本表必须一致。
declare -gA BACKEND_SUPPORTED=([apt]=1 [npm]=1 [snap]=1)

_backend_require() {
  local c
  for c in "$@"; do
    cmd_exists "$c" || { log_error "后端缺少命令：$c"; return 1; }
  done
}

# semver_of <text> —— 抽取第一个 x.y.z（用于版本比对）
semver_of() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"${1:-}" | head -1 || true; }

# _command_bin <cmd> [fallback_dir] —— 解析可执行文件路径（含 npm prefix/bin 兜底）
_command_bin() {
  local c="$1" fallback="${2:-}"
  resolve_command_path "$c" "$fallback"
}

# _npm_prefix_bin —— npm 全局 bin 目录
_npm_prefix_bin() { printf '%s/bin' "$(npm config get prefix 2>/dev/null || true)"; }

# commands_verify <id> —— CAT_COMMANDS 中的命令是否都可用
commands_verify() {
  local id="$1" c rc=0
  for c in ${CAT_COMMANDS[$id]}; do
    if cmd_exists "$c"; then
      log_debug "[$id] 命令可用：$c"
    else
      log_error "[$id] 命令不可用：$c"
      rc=1
    fi
  done
  return $rc
}

# backend_dispatch <verb> <id>
backend_dispatch() {
  local verb="$1" id="$2" backend fn
  backend="${CAT_BACKEND[$id]}"
  [[ -n "${BACKEND_SUPPORTED[$backend]+x}" ]] || {
    log_error "[$id] 不支持的 backend：${backend:-<空>}"; return 2
  }
  fn="_backend_${backend}_${verb}"
  declare -F "$fn" >/dev/null || { log_error "[$id] backend $backend 不支持动词 $verb"; return 2; }
  "$fn" "$id"
}

# ===========================================================================
# apt
# ===========================================================================
_apt_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}
_apt_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# _apt_pin_satisfied <pkg> <version> —— 已安装且版本与 pin 完全一致
_apt_pin_satisfied() {
  [[ "$(_apt_version "$1")" == "$2" ]]
}

# _apt_install_impl <id> <only_missing>
#   only_missing=1：已装即跳过（install）；=0：已装也执行 apt-get install 以升级到候选版本（update）
#   track=pin 时，已装但版本不符视为未满足，仍需安装 pkg=version。
_apt_install_impl() {
  local id="$1" only_missing="$2" pkg targets=() pin=0
  _backend_require apt-get dpkg-query || return 1
  [[ "${CAT_TRACK[$id]}" == pin && -n "${CAT_VERSION[$id]}" ]] && pin=1
  for pkg in ${CAT_PACKAGES[$id]}; do
    if (( only_missing == 1 )); then
      if (( pin == 1 )); then
        _apt_pin_satisfied "$pkg" "${CAT_VERSION[$id]}" && continue
      else
        _apt_is_installed "$pkg" && continue
      fi
    fi
    if (( pin == 1 )); then
      targets+=("${pkg}=${CAT_VERSION[$id]}")
    else
      targets+=("${pkg}")
    fi
  done
  if (( ${#targets[@]} == 0 )); then
    log_info "[$id] apt 包已安装：${CAT_PACKAGES[$id]}"
    return 0
  fi
  require_sudo || return 1
  wait_for_apt_lock || return 1
  run_step "apt-get install ${targets[*]}" \
    with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "${targets[@]}"
}

_backend_apt_install() { _apt_install_impl "$1" 1; }
_backend_apt_update()  { _apt_install_impl "$1" 0; }

_backend_apt_verify() {
  local id="$1" pkg rc=0 want="" have=""
  for pkg in ${CAT_PACKAGES[$id]}; do
    if ! _apt_is_installed "$pkg"; then
      log_error "[$id] 未安装：$pkg"
      rc=1
      continue
    fi
    if [[ "${CAT_TRACK[$id]}" == pin && -n "${CAT_VERSION[$id]}" ]]; then
      want="${CAT_VERSION[$id]}"; have="$(_apt_version "$pkg")"
      if [[ "$have" == "$want" ]]; then
        log_debug "[$id] 已安装且版本匹配：$pkg=$want"
      else
        log_error "[$id] 版本不符：$pkg 期望 $want，实际 ${have:-<未知>}"
        rc=1
      fi
    else
      log_debug "[$id] 已安装：$pkg"
    fi
  done
  (( rc == 0 )) || return 1
  commands_verify "$id"
}

_backend_apt_remove() {
  local id="$1"
  # shellcheck disable=SC2206
  local pkgs=(${CAT_PACKAGES[$id]})
  _backend_require apt-get || return 1
  require_sudo || return 1
  wait_for_apt_lock || return 1
  run_step "apt-get remove ${pkgs[*]}" \
    with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y remove "${pkgs[@]}"
}

_backend_apt_status() {
  local id="$1" pkg
  for pkg in ${CAT_PACKAGES[$id]}; do
    if _apt_is_installed "$pkg"; then
      printf '    %-22s %s\n' "$pkg" "已安装 $(_apt_version "$pkg")"
    else
      printf '    %-22s %s\n' "$pkg" "未安装"
    fi
  done
}

# ===========================================================================
# npm（全局安装；node/npm 来自 nodejs 依赖，通常由 nvm 提供）
# ===========================================================================
# _npm_tool_state <id> —— 全部命令可用；pin 时版本需一致
_npm_tool_state() {
  local id="$1" c bin want v vout
  want="${CAT_VERSION[$id]}"
  for c in ${CAT_COMMANDS[$id]}; do
    cmd_exists "$c" || { log_debug "[$id] 命令缺失：$c"; return 1; }
  done
  if [[ "${CAT_TRACK[$id]}" == pin && -n "$want" ]]; then
    c="${CAT_COMMANDS[$id]%% *}"
    bin="$(_command_bin "$c" "$(_npm_prefix_bin)")" || return 1
    vout="$("$bin" --version 2>/dev/null | head -1 || true)"
    v="$(semver_of "$vout")"
    [[ "$v" == "$want" ]] || { log_debug "[$id] 版本不匹配：$v != $want"; return 1; }
  fi
  return 0
}

# _npm_selfcheck <id> —— npm 退出码 0 ≠ 命令可用；必须真的能执行且有版本输出
_npm_selfcheck() {
  local id="$1" c bin out prefix_bin
  prefix_bin="$(_npm_prefix_bin)"
  for c in ${CAT_COMMANDS[$id]}; do
    if ! bin="$(_command_bin "$c" "$prefix_bin")"; then
      log_error "[$id] 安装后命令仍不可用：$c（prefix/bin=$prefix_bin，请检查 PATH）"
      return 1
    fi
    out="$("$bin" --version 2>&1 | head -1 || true)"
    if [[ -z "$out" ]]; then
      log_error "[$id] $c --version 无输出，安装可能不完整（postinstall 失败？）"
      return 1
    fi
    log_debug "[$id] 自检 $c -> $out"
  done
}

# _npm_install_impl <id> <force>
_npm_install_impl() {
  local id="$1" force="$2" pkg ver
  activate_nvm_default || true
  if ! cmd_exists node || ! cmd_exists npm; then
    log_error "[$id] node/npm 不可用；请先安装其依赖 nodejs"
    return 1
  fi
  pkg="${CAT_PACKAGES[$id]}"
  if [[ "${CAT_TRACK[$id]}" == pin && -n "${CAT_VERSION[$id]}" ]]; then
    ver="${CAT_VERSION[$id]}"
  else
    ver="latest"
  fi
  if (( force == 0 )) && _npm_tool_state "$id"; then
    log_info "[$id] 已安装且版本匹配，跳过（--force 可重装）"
    return 0
  fi
  npm_install_global_fixed "$pkg" "$ver" "${NPM_REGISTRY:-}" || return 1
  _npm_selfcheck "$id"
}

_backend_npm_install() { _npm_install_impl "$1" 0; }
_backend_npm_update()  { _npm_install_impl "$1" 1; }

_backend_npm_verify() {
  activate_nvm_default || true
  _npm_tool_state "$1" || { log_error "[$1] npm 工具状态不符合预期"; return 1; }
  commands_verify "$1"
}

_backend_npm_remove() {
  local id="$1" pkg
  pkg="${CAT_PACKAGES[$id]}"
  activate_nvm_default || true
  if ! cmd_exists npm; then
    log_error "[$id] npm 不可用，无法卸载"
    return 1
  fi
  run_step "npm uninstall -g $pkg" with_retry 3 5 -- npm uninstall -g "$pkg"
}

_backend_npm_status() {
  local id="$1" c bin out
  for c in ${CAT_COMMANDS[$id]}; do
    if bin="$(_command_bin "$c" "$(_npm_prefix_bin)")"; then
      out="$("$bin" --version 2>/dev/null | head -1 || true)"
      printf '    %-22s %s\n' "$c" "已安装 ${out:-?}"
    else
      printf '    %-22s %s\n' "$c" "未安装"
    fi
  done
}

# ===========================================================================
# snap
# ===========================================================================
_snap_is_installed() { snap list "$1" >/dev/null 2>&1; }

_backend_snap_install() {
  local id="$1" pkg missing=()
  _backend_require snap || return 1
  for pkg in ${CAT_PACKAGES[$id]}; do
    _snap_is_installed "$pkg" || missing+=("$pkg")
  done
  if (( ${#missing[@]} == 0 )); then
    log_info "[$id] snap 包已安装：${CAT_PACKAGES[$id]}"
    return 0
  fi
  require_sudo || return 1
  run_step "snap install ${missing[*]}" with_retry 3 5 -- sudo snap install "${missing[@]}"
}

_backend_snap_update() {
  local id="$1" pkg any=0 missing=()
  _backend_require snap || return 1
  for pkg in ${CAT_PACKAGES[$id]}; do
    if _snap_is_installed "$pkg"; then
      require_sudo || return 1
      run_step "snap refresh $pkg" with_retry 3 5 -- sudo snap refresh "$pkg" || return 1
      any=1
    else
      missing+=("$pkg")
    fi
  done
  # 部分已装时也要补齐其余包，否则 update 会报成功却留下未安装项。
  if (( ${#missing[@]} > 0 )); then
    require_sudo || return 1
    run_step "snap install ${missing[*]}" with_retry 3 5 -- sudo snap install "${missing[@]}" || return 1
    any=1
  fi
  (( any == 1 )) && return 0
  _backend_snap_install "$id"
}

_backend_snap_verify() {
  local id="$1" pkg rc=0
  for pkg in ${CAT_PACKAGES[$id]}; do
    if _snap_is_installed "$pkg"; then
      log_debug "[$id] 已安装：$pkg"
    else
      log_error "[$id] 未安装：$pkg"
      rc=1
    fi
  done
  (( rc == 0 )) || return 1
  commands_verify "$id"
}

_backend_snap_remove() {
  local id="$1"
  # shellcheck disable=SC2206
  local pkgs=(${CAT_PACKAGES[$id]})
  _backend_require snap || return 1
  require_sudo || return 1
  run_step "snap remove ${pkgs[*]}" with_retry 3 5 -- sudo snap remove "${pkgs[@]}"
}

_backend_snap_status() {
  local id="$1" pkg
  for pkg in ${CAT_PACKAGES[$id]}; do
    if _snap_is_installed "$pkg"; then
      printf '    %-22s %s\n' "$pkg" "已安装"
    else
      printf '    %-22s %s\n' "$pkg" "未安装"
    fi
  done
}
