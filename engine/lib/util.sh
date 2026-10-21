#!/usr/bin/env bash
# engine/lib/util.sh —— 平台无关工具函数（幂等、确认、步骤运行、重试、sudo）
# 被引擎与动作脚本 source；不要加 set -e。

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ---------------------------------------------------------------------------
# 用户配置加载（versions.env + user.env + ui.env），幂等
# ---------------------------------------------------------------------------
load_user_config() {
  [[ "${_USER_CONFIG_LOADED:-0}" == "1" ]] && return 0
  _USER_CONFIG_LOADED=1
  local vf="$PROJECT_DIR/config/versions.env"
  local uf="$PROJECT_DIR/config/user.env"
  local f
  for f in "$vf" "$uf" "$PROJECT_DIR/config/ui.env"; do
    [[ -f "$f" ]] || continue
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  done
  _warn_deprecated_config
}

# 已废弃的配置键：曾经有效、现在由别的机制接管。
# 静默忽略会让用户以为开关还起作用，因此明确提示一次。
_warn_deprecated_config() {
  declare -F log_warn >/dev/null 2>&1 || return 0
  if [[ -n "${SSH_INSTALL_SERVER+x}" ]]; then
    log_warn "SSH_INSTALL_SERVER 已废弃（openssh-server 现在是 catalog 条目），本项不再生效"
    log_command './setup.sh install --pick openssh-server'
  fi
}
load_user_config

# ---------------------------------------------------------------------------
# 命令存在性 / 文本判断
# ---------------------------------------------------------------------------
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
file_contains() { grep -qE "$2" "$1" 2>/dev/null; }
git_cfg_get() { git config --global --get "$1" 2>/dev/null; }

# util_trim <str> —— 去除首尾空白
util_trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# util_mktemp <描述> —— 创建临时文件；失败时记录原因并返回非零（不输出路径）
util_mktemp() {
  local desc="${1:-临时文件}" f
  f="$(mktemp)" || { log_error "无法创建${desc}"; return 1; }
  printf '%s\n' "$f"
}

# ---------------------------------------------------------------------------
# 用户交互
# ---------------------------------------------------------------------------
confirm() {
  local prompt="$1" ans
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# 步骤运行
# ---------------------------------------------------------------------------
run_step() {
  local desc="$1"; shift
  log_info "  ▸ $desc"
  if "$@"; then
    log_ok "  ✓ $desc"
    return 0
  else
    local rc=$?
    log_error "  ✗ $desc (exit=$rc)"
    return $rc
  fi
}

# 同 run_step，但把子命令 stdout/stderr 同时打到终端与 LOG_FILE（脱敏）
run_step_verbose() {
  local desc="$1"; shift
  local rc log_target="${LOG_FILE:-/dev/null}"
  log_info "  ▸ $desc"
  if "$@" 2>&1 | tee >(_redact >>"$log_target") >&2; then
    rc=${PIPESTATUS[0]}
  else
    rc=${PIPESTATUS[0]}
  fi
  if [[ $rc -eq 0 ]]; then
    log_ok "  ✓ $desc"
  else
    log_error "  ✗ $desc (exit=$rc)"
  fi
  return "$rc"
}

resolve_command_path() {
  local bin="$1" fallback_dir="${2:-}"
  if cmd_exists "$bin"; then
    command -v "$bin"
  elif [[ -n "$fallback_dir" && -x "$fallback_dir/$bin" ]]; then
    printf '%s\n' "$fallback_dir/$bin"
  else
    return 1
  fi
}

# run_step_verbose_capture <desc> <capture_file> <cmd...>
# 同 run_step_verbose，并把原始输出暂存到权限 600 的文件，供错误分类（如 ENOTEMPTY）。
run_step_verbose_capture() {
  local desc="$1" capture_file="$2"; shift 2
  local rc log_target="${LOG_FILE:-/dev/null}"
  : >"$capture_file"
  chmod 600 -- "$capture_file" 2>/dev/null || true
  log_info "  ▸ $desc"
  if "$@" 2>&1 | tee "$capture_file" >(_redact >>"$log_target") >&2; then
    rc=${PIPESTATUS[0]}
  else
    rc=${PIPESTATUS[0]}
  fi
  if [[ $rc -eq 0 ]]; then
    log_ok "  ✓ $desc"
  else
    log_error "  ✗ $desc (exit=$rc)"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# npm 全局安装（幂等 / ENOTEMPTY 定向修复）
# ---------------------------------------------------------------------------

# cleanup_npm_enotempty_residue <pkg> —— 只删除 npm rename 遗留的隐藏目录，不动正式包。
cleanup_npm_enotempty_residue() {
  local pkg="$1" prefix nm_dir parent base d
  prefix=$(npm config get prefix 2>/dev/null || true)
  [[ -n "$prefix" && "$prefix" != "undefined" ]] || return 1
  nm_dir="$prefix/lib/node_modules"
  if [[ "$pkg" == @*/* ]]; then
    parent="$nm_dir/${pkg%%/*}"
    base="${pkg##*/}"
  else
    parent="$nm_dir"
    base="$pkg"
  fi
  [[ -d "$parent" ]] || return 0

  local restore_nullglob=0
  shopt -q nullglob || restore_nullglob=1
  shopt -s nullglob
  for d in "$parent"/."$base"-*; do
    [[ -d "$d" ]] || continue
    log_warn "清理 npm ENOTEMPTY 残留目录：$d"
    rm -rf -- "$d"
  done
  (( restore_nullglob == 0 )) || shopt -u nullglob
}

# npm_install_global_fixed <pkg> <version> <registry>
# 正常安装一次；仅在确认 ENOTEMPTY 后清理隐藏残留并重试一次。
npm_install_global_fixed() {
  local pkg="$1" version="$2" registry="${3:-}"
  local capture rc desc
  local -a cmd=(npm install -g --loglevel=info --foreground-scripts
    --no-audit --no-fund --prefer-offline
    --fetch-timeout=120000 --fetch-retry-maxtimeout=120000)
  [[ -z "$registry" ]] || cmd+=(--registry="$registry")
  cmd+=("${pkg}@${version}")
  desc="npm install -g ${pkg}@${version}"
  [[ -z "$registry" ]] || desc+=" (registry=$registry)"

  capture="$(util_mktemp 'npm 输出捕获文件')" || return 1
  register_tmpfile "$capture"
  if run_step_verbose_capture "$desc" "$capture" "${cmd[@]}"; then
    return 0
  else
    rc=$?
  fi

  if grep -q 'ENOTEMPTY' "$capture"; then
    log_warn "检测到 npm ENOTEMPTY，清理隐藏残留后重试一次"
    cleanup_npm_enotempty_residue "$pkg" || true
    run_step_verbose "$desc（ENOTEMPTY 修复重试）" "${cmd[@]}"
    return $?
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# sudo
# ---------------------------------------------------------------------------
sudo_available() { cmd_exists sudo && sudo -n true 2>/dev/null; }

require_sudo() {
  cmd_exists sudo || { log_error "系统未安装 sudo"; return 1; }
  sudo_available && return 0
  if [[ -t 0 && -t 1 ]]; then
    log_info "需要 sudo 权限，请按提示输入密码"
    sudo -v && return 0
  fi
  log_error "sudo 凭据不可用；非交互运行请预先执行 sudo -v，或用 --no-sudo 跳过特权工具"
  return 1
}

# ---------------------------------------------------------------------------
# 重试 / apt 锁
# ---------------------------------------------------------------------------
with_retry() {
  local max="${1:-3}" sleep_sec="${2:-2}"
  shift 2
  [[ "${1:-}" == "--" ]] || { log_error "with_retry 用法: with_retry <max> <sleep> -- <cmd...>"; return 2; }
  shift
  local attempt=1 rc=0
  while [[ $attempt -le $max ]]; do
    log_debug "[retry $attempt/$max] $*"
    if "$@"; then
      [[ $attempt -gt 1 ]] && log_info "  第 $attempt 次尝试成功"
      return 0
    else
      rc=$?
    fi
    if [[ $attempt -lt $max ]]; then
      log_warn "  第 $attempt/$max 次失败（rc=$rc），${sleep_sec}s 后重试：$*"
      sleep "$sleep_sec"
    fi
    attempt=$((attempt + 1))
  done
  log_error "重试 $max 次后仍失败：$*"
  return $rc
}

wait_for_apt_lock() {
  local max_wait="${1:-60}" elapsed=0
  while [[ $elapsed -lt $max_wait ]]; do
    if ! sudo fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       && ! sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      return 0
    fi
    [[ $elapsed -eq 0 ]] && log_warn "apt 锁被占用，等待释放（最多 ${max_wait}s）..."
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log_error "等待 apt 锁超时（${max_wait}s）"
  return 1
}

# ---------------------------------------------------------------------------
# 代理推导与连通性（net 相关动作复用）
# ---------------------------------------------------------------------------
validate_ipv4() {
  local ip="${1:-}" octet
  local -a octets
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

detect_primary_ipv4() {
  local addr=""
  if cmd_exists ip; then
    addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src" && (i + 1) <= NF) { print $(i + 1); exit }
      }
    }')
  fi
  if [[ -z "$addr" ]] && cmd_exists hostname; then
    addr=$(hostname -I 2>/dev/null | tr ' ' '\n' \
      | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 !~ /^127\./ { print; exit }')
  fi
  validate_ipv4 "$addr" || return 1
  printf '%s\n' "$addr"
}

# 成功设置 RESOLVED_PROXY_HOST/PORT/URL；自动推导时设置 PROXY_SOURCE_IP
resolve_proxy_endpoint() {
  local host="${PROXY_HOST:-}" port="${PROXY_PORT:-}" current_ip=""
  PROXY_SOURCE_IP=""
  if [[ -z "$host" ]]; then
    current_ip=$(detect_primary_ipv4) || return 1
    host="${current_ip%.*}.1"
    PROXY_SOURCE_IP="$current_ip"
  fi
  [[ -n "$port" ]] || port=7890
  [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 2
  [[ "$host" != -* && "$host" =~ ^([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\])$ ]] || return 3
  RESOLVED_PROXY_HOST="$host"
  RESOLVED_PROXY_PORT="$port"
  RESOLVED_PROXY_URL="http://${host}:${port}"
}

# 0=可达 1=不可达 2=缺少 ping
check_proxy_host_reachable() {
  local host="${1:-}" target
  [[ -n "$host" ]] || return 1
  cmd_exists ping || return 2
  target="${host#[}"
  target="${target%]}"
  ping -n -c 1 -W 2 -- "$target" >/dev/null 2>&1
}

log_proxy_connectivity_diagnostics() {
  local host="${1:-<未知>}" port="${2:-7890}" source_ip="${3:-}" target
  target="${host#[}"
  target="${target%]}"
  log_error "代理主机 $host ping 不通，请按以下步骤检查："
  log_error "1、先确认本机 IP 和网卡是否正确："
  log_error "   执行：ip -4 addr show"
  log_error "   执行：ip route get $target"
  if [[ -n "$source_ip" ]]; then
    log_error "   预期路由输出中的 src 为 $source_ip，并确认对应网卡处于 UP 状态。"
  else
    log_error "   确认路由输出中的 src 是当前主机实际 IPv4，并确认对应网卡处于 UP 状态。"
  fi
  log_error "2、检查代理主机 $host 是否开启防火墙或拦截 ICMP："
  log_error "   Linux：sudo ufw status verbose；sudo nft list ruleset"
  log_error "   Windows PowerShell：Get-NetFirewallProfile"
  log_error "   确认允许 ICMP Echo，并放行代理 TCP 端口 $port。"
}

ensure_proxy_host_reachable() {
  local host="${1:-}" port="${2:-7890}" source_ip="${3:-}" rc
  if check_proxy_host_reachable "$host"; then
    log_ok "代理主机连通性正常：ping $host"
    return 0
  else
    rc=$?
  fi
  if [[ $rc -eq 2 ]]; then
    log_error "缺少 ping 命令，无法检查代理主机连通性；请安装 iputils-ping"
  fi
  log_proxy_connectivity_diagnostics "$host" "$port" "$source_ip"
  return 1
}

# 代理连通性验证：目标地址与超时都可由 config/user.env 覆盖
#   PROXY_TEST_URL         默认 https://github.com
#   PROXY_CONNECT_TIMEOUT  默认 5（秒）
#   PROXY_MAX_TIME         默认 15（秒）
ensure_proxy_curl_connectivity() {
  local proxy_url="${1:-}"
  local test_url="${2:-${PROXY_TEST_URL:-https://github.com}}"
  local connect_timeout="${3:-${PROXY_CONNECT_TIMEOUT:-5}}"
  local max_time="${4:-${PROXY_MAX_TIME:-15}}"
  if ! cmd_exists curl; then
    log_error "缺少 curl 命令，无法执行代理真实访问验证"
    return 1
  fi
  if [[ -z "$proxy_url" || ! "$connect_timeout" =~ ^[1-9][0-9]*$ || ! "$max_time" =~ ^[1-9][0-9]*$ ]]; then
    log_error "curl 代理验证参数无效（proxy=${proxy_url:-<空>} connect-timeout=$connect_timeout max-time=$max_time）"
    return 1
  fi
  log_info "使用 curl 通过代理访问：$test_url"
  log_command "curl -x $proxy_url $test_url"
  if curl -fsSL -x "$proxy_url" \
      --connect-timeout "$connect_timeout" --max-time "$max_time" \
      -o /dev/null -- "$test_url"; then
    log_ok "curl 代理访问验证通过：$test_url"
    return 0
  fi
  log_error "curl 代理访问验证失败：无法通过 $proxy_url 访问 $test_url"
  log_error "请检查代理程序是否监听对应端口、代理主机防火墙，以及代理是否允许 HTTPS CONNECT。"
  return 1
}

# ---------------------------------------------------------------------------
# Node / nvm 公共工具
# ---------------------------------------------------------------------------
activate_nvm_default() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    nvm use --silent default >/dev/null 2>&1 || return 1
  fi
  cmd_exists node && cmd_exists npm
}
