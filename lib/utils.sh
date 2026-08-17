#!/usr/bin/env bash
# utils.sh —— 平台无关的工具函数（幂等判断、备份、确认、命令运行）
# 注意：本文件被 runner/setup.sh 通过 source 加载，不要加 set -e。

# 路径前缀（被 setup.sh 注入）；若未注入则推断
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# 加载用户配置（versions.env + user.env）
# 由 setup.sh 在 runner 之前已加载一次（export 给子进程）；
# 但用户直接跑 ./install.sh 时不经过 setup.sh，install.sh 自己需调用一次。
# 文件不存在安静跳过；幂等：多次调用不会重复 source（用 _USER_CONFIG_LOADED 标记）
# ---------------------------------------------------------------------------
load_user_config() {
  [[ "${_USER_CONFIG_LOADED:-0}" == "1" ]] && return 0
  _USER_CONFIG_LOADED=1
  local vf="$PROJECT_DIR/config/versions.env"
  local uf="$PROJECT_DIR/config/user.env"
  if [[ -f "$vf" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$vf"
    set +a
  fi
  if [[ -f "$uf" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$uf"
    set +a
  fi
}

# utils.sh 被 source 时自动加载一次用户配置
# （保证直接跑 ./install.sh 也能读到 versions.env / user.env；
#   setup.sh 之前已 source 过则会因 _USER_CONFIG_LOADED 幂等跳过）
load_user_config

# ---------------------------------------------------------------------------
# 解析 install.sh / verify.sh 命令行参数
#   支持：--force / --debug / --help / -h
#   兼容 setup.sh 注入的 FORCE/DEBUG 环境变量（命令行参数优先级更高）
#   未知参数安静跳过（不报错），未来扩展友好。
#   用法：在 install.sh source utils.sh 之后立刻调用 parse_install_args "$@"
# ---------------------------------------------------------------------------
parse_install_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --force|-f) FORCE=1 ;;
      --debug)    DEBUG=1 ;;
      --help|-h)
        cat <<EOF
用法：$0 [--force] [--debug] [--help]

选项：
  --force, -f   忽略幂等判断，强制重装/重写
  --debug       开启 set -x 调试
  --help, -h    打印此帮助后退出

环境变量（与命令行参数等价；命令行优先级更高）：
  FORCE=1       等同 --force
  DEBUG=1       等同 --debug
EOF
        exit 0
        ;;
      *)
        # 未知参数：安静跳过（保持兼容，不阻断流程）
        ;;
    esac
    shift
  done
  # export 给后续 npm install / nvm install 等子进程
  export FORCE="${FORCE:-0}" DEBUG="${DEBUG:-0}"
}

# ---------------------------------------------------------------------------
# 命令存在性 / 幂等判断
# ---------------------------------------------------------------------------

# cmd_exists <bin> —— 命令是否在 PATH 中
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# file_contains <file> <pattern> —— 文件是否含某行（grep -E 正则）
file_contains() { grep -qE "$2" "$1" 2>/dev/null; }

# git_cfg_get <key> —— 读 git 全局配置值（无则空）
git_cfg_get() { git config --global --get "$1" 2>/dev/null; }

# validate_ipv4 <address> —— 严格校验点分十进制 IPv4 地址
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

# detect_primary_ipv4 —— 获取默认路由使用的本机 IPv4；失败时回退到首个非 loopback IPv4
detect_primary_ipv4() {
  local addr=""

  if cmd_exists ip; then
    addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src" && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
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

# resolve_proxy_endpoint —— 解析代理端点。
# PROXY_HOST 为空：将当前 IPv4 的最后一段替换为 1；PROXY_PORT 为空：使用 7890。
# 成功后设置 RESOLVED_PROXY_HOST / RESOLVED_PROXY_PORT / RESOLVED_PROXY_URL；
# 自动推导 host 时还会设置 PROXY_SOURCE_IP。
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

# check_proxy_host_reachable <host> —— 使用 ICMP ping 检查代理主机是否可达。
# 返回值：0=可达，1=不可达，2=缺少 ping 命令。
check_proxy_host_reachable() {
  local host="${1:-}" target
  [[ -n "$host" ]] || return 1
  cmd_exists ping || return 2

  # ping 接受裸 IPv6 地址，而代理 URL 中的 IPv6 host 需要方括号。
  target="${host#[}"
  target="${target%]}"
  if ping -n -c 1 -W 2 -- "$target" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# log_proxy_connectivity_diagnostics <host> <port> [source-ip]
# ping 失败时输出固定的两步排查说明。调用前须已加载 lib/log.sh。
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

# ensure_proxy_host_reachable <host> <port> [source-ip]
# 统一执行 ping 并打印结果；失败时输出诊断步骤。
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

# ensure_proxy_curl_connectivity <proxy-url> [test-url] [connect-timeout] [max-time]
# 使用显式 curl -x 请求验证代理端口、HTTP CONNECT、TLS 和目标站点访问能力。
ensure_proxy_curl_connectivity() {
  local proxy_url="${1:-}" test_url="${2:-https://github.com}"
  local connect_timeout="${3:-5}" max_time="${4:-15}"

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
# 用户交互
# ---------------------------------------------------------------------------

# confirm <prompt> —— 返回 0/1
confirm() {
  local prompt="$1" ans
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# 步骤运行（被 install.sh 调用）
# ---------------------------------------------------------------------------

# run_step <desc> <cmd...> —— 运行一步，失败则退出当前子脚本（非 set -e 模式更可控）
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

# run_step_verbose <desc> <cmd...> —— 同 run_step，但把命令的 stdout/stderr
# 同时打到终端和 LOG_FILE（带 npm/curl 进度等长输出时用，方便用户看进展）
# 注意：用 PIPESTATUS[0] 取原命令退出码，避免被 tee 影响判断
run_step_verbose() {
  local desc="$1"; shift
  local rc log_target="${LOG_FILE:-/dev/null}"
  log_info "  ▸ $desc"

  # 放在 if 条件中，避免调用方启用 set -e/pipefail 时在读取 PIPESTATUS 前退出。
  # 终端保留原始进度，落盘内容统一经过 _redact 脱敏。
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


# ---------------------------------------------------------------------------
# Node.js / npm 公共工具
# ---------------------------------------------------------------------------

# activate_nvm_default —— nvm 存在时始终激活 default，避免系统 node 抢占 PATH。
activate_nvm_default() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    nvm use --silent default >/dev/null 2>&1 || return 1
  fi
  cmd_exists node && cmd_exists npm
}

# resolve_command_path <bin> [fallback_dir] —— 输出可执行文件绝对路径。
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
# 与 run_step_verbose 相同，同时将原始输出暂存到权限 600 的临时文件供错误分类。
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

# cleanup_npm_enotempty_residue <pkg> —— 只删除 npm rename 遗留的隐藏目录，不删除正式包。
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
# 第一次正常安装；仅在确认 ENOTEMPTY 后清理隐藏残留并重试一次。
npm_install_global_fixed() {
  local pkg="$1" version="$2" registry="${3:-}"
  local capture rc desc
  local -a cmd=(npm install -g --loglevel=info --foreground-scripts
    --no-audit --no-fund --prefer-offline
    --fetch-timeout=120000 --fetch-retry-maxtimeout=120000)
  [[ -z "$registry" ]] || cmd+=(--registry="$registry")
  cmd+=("$pkg@$version")
  desc="npm install -g $pkg@$version"
  [[ -z "$registry" ]] || desc+=" (registry=$registry)"

  capture=$(mktemp)
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
# sudo 检测
# ---------------------------------------------------------------------------

# sudo_available —— 当前是否已有可用的 sudo 凭据（不弹密码提示）。
sudo_available() { cmd_exists sudo && sudo -n true 2>/dev/null; }

# require_sudo —— 交互终端允许 sudo -v 获取凭据；非交互环境必须已有凭据。
require_sudo() {
  cmd_exists sudo || { log_error "系统未安装 sudo"; return 1; }
  sudo_available && return 0
  if [[ -t 0 && -t 1 ]]; then
    log_info "需要 sudo 权限，请按提示输入密码"
    sudo -v && return 0
  fi
  log_error "sudo 凭据不可用；非交互运行请预先执行 sudo -v，或用 --no-sudo 跳过特权模块"
  return 1
}

# ===========================================================================
# 异常处理工具集（A-H 全覆盖）
#   A 中断恢复     → register_tmpfile / cleanup_tmpfiles / setup_traps
#   B 网络重试     → with_retry
#   C 错误定位     → trap_err_handler / setup_traps
#   D 失败汇总     → runner 内部 _FAIL_LIST（在 runner.sh 实现）
#   E apt 锁等待   → wait_for_apt_lock
#   F 备份失败可控 → register_rollback（失败即返回非0，调用方可决定）
#   G 半配置清理   → rollback_on_exit 失败时恢复所有备份
#   H 简易回滚     → register_rollback + rollback_on_exit
# ===========================================================================

# 全局状态（每个 install.sh 子进程独立维护）
declare -ga _TMPFILES=()           # 临时文件路径列表
declare -ga _ROLLBACK_ORIG=()      # 原文件路径
declare -ga _ROLLBACK_BACKUP=()    # 备份文件路径
declare -ga _ROLLBACK_MODE=()      # user | sudo
declare -ga _ROLLBACK_EXISTED=()   # 1=原文件存在；0=本次将创建，失败时删除
declare -g  _TRAPS_SET=0           # 防止重复设 trap
declare -g  _ROLLBACK_DONE=0       # 防止信号 trap + EXIT trap 重复回滚

# ---------------------------------------------------------------------------
# A. 临时文件注册与清理
# ---------------------------------------------------------------------------

# register_tmpfile <path>  —— 注册一个临时文件，trap 时自动清理
register_tmpfile() {
  local f="$1"
  _TMPFILES+=("$f")
}

# cleanup_tmpfiles  —— 删除所有已注册的临时文件
cleanup_tmpfiles() {
  local f
  for f in "${_TMPFILES[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f" 2>/dev/null && log_debug "清理临时文件：$f"
  done
  _TMPFILES=()
}

# ---------------------------------------------------------------------------
# F + H. 备份并注册回滚（替代旧 backup_file；失败时让调用方决定）
# ---------------------------------------------------------------------------

# register_rollback <file> [user|sudo] —— 注册文件回滚点。
#   原文件存在：创建 .bak 备份，失败时恢复。
#   原文件不存在：记录为“本次新建”，失败时删除新文件。
#   失败时返回非 0，不静默吞错。
register_rollback() {
  local f="$1" mode="${2:-user}" existed=0 bak=""
  [[ "$mode" == "user" || "$mode" == "sudo" ]] || {
    log_error "未知备份模式：$mode（仅支持 user/sudo）"
    return 2
  }

  if [[ "$mode" == "sudo" ]]; then
    sudo test -e "$f" && existed=1
  else
    [[ -e "$f" ]] && existed=1
  fi

  if [[ "$existed" == 1 ]]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    bak="${f}.bak.${ts}.$$"
    if [[ "$mode" == "sudo" ]]; then
      sudo cp -p -- "$f" "$bak" 2>/dev/null || {
        log_error "备份失败：$f（sudo 权限、磁盘空间或只读文件系统）"
        return 1
      }
    else
      cp -p -- "$f" "$bak" 2>/dev/null || {
        log_error "备份失败：$f（权限、磁盘空间或只读文件系统）"
        return 1
      }
    fi
    [[ -z "${BACKUP_MANIFEST:-}" ]] || printf '%s\n' "$bak" >>"$BACKUP_MANIFEST"
    log_info "已备份：$f -> $bak"
  else
    log_debug "已注册新文件回滚：$f"
  fi

  _ROLLBACK_ORIG+=("$f")
  _ROLLBACK_BACKUP+=("$bak")
  _ROLLBACK_MODE+=("$mode")
  _ROLLBACK_EXISTED+=("$existed")
}

backup_file() { register_rollback "$@"; }

# ---------------------------------------------------------------------------
# G + H. 回滚：失败时恢复所有已注册备份
# ---------------------------------------------------------------------------

# rollback_on_exit <exit_code>  —— trap EXIT 调用；rc != 0 时恢复备份
rollback_on_exit() {
  local rc=${1:-$?}
  [[ "$_ROLLBACK_DONE" == 1 ]] && return 0
  _ROLLBACK_DONE=1
  cleanup_tmpfiles
  if [[ $rc -eq 0 || ${#_ROLLBACK_ORIG[@]} -eq 0 ]]; then
    return 0
  fi

  log_error "脚本失败（rc=$rc），回滚以下文件到备份："
  local i orig bak mode existed
  for i in "${!_ROLLBACK_ORIG[@]}"; do
    orig="${_ROLLBACK_ORIG[$i]}"
    bak="${_ROLLBACK_BACKUP[$i]}"
    mode="${_ROLLBACK_MODE[$i]}"
    existed="${_ROLLBACK_EXISTED[$i]:-1}"
    if [[ "$existed" == 0 ]]; then
      if [[ "$mode" == "sudo" ]]; then
        sudo rm -f -- "$orig" 2>/dev/null || { log_error "  删除新文件失败：$orig"; continue; }
      else
        rm -f -- "$orig" 2>/dev/null || { log_error "  删除新文件失败：$orig"; continue; }
      fi
      log_info "  已删除失败过程中创建的文件：$orig"
    elif [[ "$mode" == "sudo" ]]; then
      if sudo test -f "$bak" && sudo cp -p -- "$bak" "$orig" 2>/dev/null; then
        log_info "  已回滚：$orig <- $bak"
      else
        log_error "  回滚失败：$orig（备份在 $bak，请手动恢复）"
      fi
    elif [[ -f "$bak" ]] && cp -p -- "$bak" "$orig" 2>/dev/null; then
      log_info "  已回滚：$orig <- $bak"
    else
      log_error "  回滚失败：$orig（备份在 $bak，请手动恢复）"
    fi
  done
  log_warn "回滚完成。请检查失败原因后重跑"
}

# ---------------------------------------------------------------------------
# C. 错误定位（trap ERR 调用）
# ---------------------------------------------------------------------------

# trap_err_handler  —— set -e 触发时打印失败的命令与行号
trap_err_handler() {
  local rc=$?
  log_error "[$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")] 命令失败："
  log_error "  命令: ${BASH_COMMAND}"
  log_error "  行号: ${BASH_LINENO[0]:-未知}"
  log_error "  退出码: $rc"
}

# ---------------------------------------------------------------------------
# A + C. 一键装好所有 trap（每个 install.sh 头部调一次）
# ---------------------------------------------------------------------------

# setup_traps  —— 注册 EXIT/INT/TERM/ERR trap，子脚本退出时清理+回滚+报错
setup_traps() {
  [[ "$_TRAPS_SET" = 1 ]] && return 0
  _TRAPS_SET=1
  trap 'rollback_on_exit $?' EXIT
  trap 'log_warn "中断信号收到（$$），即将清理并退出"; exit 130' INT
  trap 'log_warn "终止信号收到（$$），即将清理并退出"; exit 143' TERM
  trap 'trap_err_handler' ERR
}

# ---------------------------------------------------------------------------
# B. 命令重试（用于网络抖动 / 短暂资源锁）
# ---------------------------------------------------------------------------

# with_retry <max_attempts> <sleep_sec> -- <cmd...>
#   例：with_retry 3 2 -- curl -fsSL -o /tmp/x.sh https://example.com/install.sh
#   注意：必须用 -- 分隔参数与命令
with_retry() {
  local max="${1:-3}" sleep_sec="${2:-2}"
  shift 2
  [[ "${1:-}" == "--" ]] || { log_error "with_retry 用法: with_retry <max> <sleep> -- <cmd...>"; return 2; }
  shift  # 去掉 --
  local attempt=1 rc=0
  while [[ $attempt -le $max ]]; do
    log_debug "[retry $attempt/$max] $*"
    if "$@"; then
      [[ $attempt -gt 1 ]] && log_info "  第 $attempt 次尝试成功"
      return 0
    fi
    rc=$?
    if [[ $attempt -lt $max ]]; then
      log_warn "  第 $attempt/$max 次失败（rc=$rc），${sleep_sec}s 后重试：$*"
      sleep "$sleep_sec"
    fi
    attempt=$((attempt + 1))
  done
  log_error "重试 $max 次后仍失败：$*"
  return $rc
}

# ---------------------------------------------------------------------------
# E. apt dpkg 锁等待
# ---------------------------------------------------------------------------

# wait_for_apt_lock  —— 等待 /var/lib/dpkg/lock 释放（最多 60s）
#   unattended-upgrades 等场景会持有锁，apt install 会立即失败。
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
