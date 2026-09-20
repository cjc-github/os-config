#!/usr/bin/env bash
# engine/actions/mirrors.sh —— 切换 APT 镜像源为国内加速源
# 接口：action_mirrors_apply | action_mirrors_remove | action_mirrors_verify <id>
# 由 engine.sh 的 action_dispatch 惰性 source；不要加 set -e。
#
# 参数（config/user.env）：
#   MIRROR_APT_URL        默认 https://mirrors.tuna.tsinghua.edu.cn/ubuntu
#   MIRROR_APT_PORTS_URL  默认 https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
#
# remove 语义：把源文件还原为「本动作首次改写前」的持久备份，并 apt update。
#   持久备份存放在 $STATE_DIR/actions/mirrors/ 下，跨运行有效（与一次性回滚不同）。

_mirrors_defaults() {
  : "${MIRROR_APT_URL:=https://mirrors.tuna.tsinghua.edu.cn/ubuntu}"
  : "${MIRROR_APT_PORTS_URL:=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"
}

# 输出 amd64/arm64 对应的镜像地址
_mirrors_url_for_arch() {
  _mirrors_defaults
  local arch; arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$arch" in
    arm64|armhf|riscv64|s390x|ppc64el) printf '%s\n' "$MIRROR_APT_PORTS_URL" ;;
    *) printf '%s\n' "$MIRROR_APT_URL" ;;
  esac
}

# 输出海外源正则（用于判断是否需要替换）
_mirrors_origin_re() {
  _mirrors_defaults
  local arch; arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$arch" in
    amd64|i386|x86_64) printf '%s\n' '(archive\.ubuntu\.com|security\.ubuntu\.com)' ;;
    arm64|armhf|riscv64|s390x|ppc64el) printf '%s\n' 'ports\.ubuntu\.com' ;;
    *) printf '%s\n' 'ubuntu\.com' ;;
  esac
}

_mirrors_sources() {
  local f
  for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
}

# 记录「本动作改写过」的文件清单，供 remove 还原
_mirrors_changed_add() {
  local dir="$1" f="$2" list="$1/changed.txt"
  grep -Fxq -- "$f" "$list" 2>/dev/null || printf '%s\n' "$f" >>"$list"
}

_mirrors_durable_backup() {
  local dir="$1" f="$2" base; base=$(basename "$f")
  [[ -f "$dir/$base" ]] && return 0
  sudo cat -- "$f" >"$dir/$base" || return 1
  chmod 600 -- "$dir/$base" 2>/dev/null || true
  log_info "已记录持久备份：$f -> $dir/$base"
}

action_mirrors_apply() {
  local id="$1" url origin_re dir f tmp changed=0
  _mirrors_defaults
  url="$(_mirrors_url_for_arch)"
  origin_re="$(_mirrors_origin_re)"
  dir="$(state_action_dir mirrors)"

  require_sudo || return 1
  wait_for_apt_lock || return 1

  local -a targets=()
  while IFS= read -r f; do
    if grep -qE "$origin_re" "$f"; then
      targets+=("$f")
    elif [[ "${FORCE:-0}" == 1 ]]; then
      targets+=("$f")
    else
      log_info "已是镜像或非海外源，跳过：$f"
    fi
  done < <(_mirrors_sources)

  if (( ${#targets[@]} == 0 )); then
    log_ok "[$id] APT 源无需更改"
  else
    for f in "${targets[@]}"; do
      _mirrors_durable_backup "$dir" "$f" || return 1
      register_rollback "$f" sudo
      tmp=$(mktemp); register_tmpfile "$tmp"
      run_step "生成新的 $f" \
        sudo sed -E -e "s|(URIs:[[:space:]]+)(https?://[^/]+/ubuntu[^ ]*)|\1${url}|g" \
                    -e "s|(deb(-src)?[[:space:]]+)(https?://[^ ]+ubuntu[^ ]*)|\1${url}|g" \
                    "$f" >"$tmp" || return 1
      run_step "覆盖 $f" sudo cp -- "$tmp" "$f" || return 1
      _mirrors_changed_add "$dir" "$f"
      log_ok "[$id] 已更新：$f -> $url"
      changed=1
    done
  fi

  run_step "apt update" with_retry 2 10 -- sudo apt-get update || return 1
  log_ok "[$id] 完成（changed=$changed）"
}

action_mirrors_remove() {
  local id="$1" dir list f base rc=0
  dir="$(state_action_dir mirrors)"
  list="$dir/changed.txt"
  if [[ ! -s "$list" ]]; then
    log_info "[$id] 没有本动作记录的换源历史，跳过还原"
    return 0
  fi
  require_sudo || return 1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    base=$(basename "$f")
    if [[ -f "$dir/$base" ]]; then
      if sudo cp -- "$dir/$base" "$f"; then
        log_ok "[$id] 已还原：$f <- $base"
      else
        log_error "[$id] 还原失败：$f"; rc=1
      fi
    else
      log_warn "[$id] 缺少持久备份，跳过：$f"
    fi
  done <"$list"
  rm -rf -- "$dir"
  (( rc == 0 )) || return 1
  wait_for_apt_lock || return 1
  run_step "apt update" with_retry 2 10 -- sudo apt-get update || return 1
  log_ok "[$id] 已还原为换源前的 APT 源"
}

action_mirrors_verify() {
  local id="$1" origin_re f rc=0 found=0
  origin_re="$(_mirrors_origin_re)"
  while IFS= read -r f; do
    found=1
    if grep -qE "$origin_re" "$f"; then
      log_error "[$id] $f 仍含海外 Ubuntu 源，换源未生效"
      rc=1
    else
      log_debug "[$id] $f 未发现海外 Ubuntu 源"
    fi
  done < <(_mirrors_sources)

  if (( found == 0 )); then
    log_error "[$id] 未找到 APT 源文件"
    return 1
  fi
  (( rc == 0 )) || return 1

  if ! sudo -n apt-get check >/dev/null 2>&1; then
    log_error "[$id] apt-get check 失败（需提权或 apt update 未执行）"
    return 1
  fi
  log_ok "[$id] apt-get check 通过"
}
