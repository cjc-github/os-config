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

# ---------------------------------------------------------------------------
# 备份（改 dotfiles 前调用）
# ---------------------------------------------------------------------------

# backup_file <path> —— cp 成 <path>.bak.<ts>，幂等（已存在 .bak 同时间戳则不覆盖）
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local bak="${f}.bak.${ts}"
  if [[ -e "$bak" ]]; then
    log_warn "备份已存在，跳过：$bak"
    return 0
  fi
  cp -p "$f" "$bak" || { log_error "备份失败：$f"; return 1; }
  log_info "已备份：$f -> $bak"
  # 把备份路径写进本次日志摘要（runner 提供 BACKUPS 列表变量）
  if [[ -n "${BACKUP_LIST-}" ]]; then
    BACKUP_LIST+=("$bak")
  fi
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
  log_info "  ▸ $desc"
  "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}" >&2
  local rc=${PIPESTATUS[0]}
  if [[ $rc -eq 0 ]]; then
    log_ok "  ✓ $desc"
    return 0
  else
    log_error "  ✗ $desc (exit=$rc)"
    return $rc
  fi
}

# ---------------------------------------------------------------------------
# sudo 检测
# ---------------------------------------------------------------------------

# sudo_available —— 当前能否免密 sudo
sudo_available() { sudo -n true 2>/dev/null; }

# require_sudo —— 模块标记 NEEDS_SUDO=1 时 runner 调用，不行就报错
require_sudo() {
  if sudo_available; then return 0; fi
  log_error "需要 sudo 权限但当前不可用（请配置免密 sudo 或用 --no-sudo 跳过 NEEDS_SUDO 模块）"
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
declare -ga _ROLLBACK_PAIRS=()     # "原文件|备份文件" 列表
declare -g  _TRAPS_SET=0           # 防止重复设 trap

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

# register_rollback <file>  —— 备份成 .bak.<ts> 并注册到回滚列表
#   失败时返回 1（不静默吞错，让调用方决定是 abort 还是 continue）
register_rollback() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local bak="${f}.bak.${ts}"
  if [[ -e "$bak" ]]; then
    log_warn "备份已存在，跳过：$bak"
    return 0
  fi
  if cp -p "$f" "$bak" 2>/dev/null; then
    _ROLLBACK_PAIRS+=("$f|$bak")
    log_info "已备份：$f -> $bak"
    return 0
  fi
  log_error "备份失败：$f（可能权限/磁盘满）"
  return 1
}

# backup_file —— 旧函数保留（保持向后兼容），内部转调 register_rollback
backup_file() { register_rollback "$@"; }

# ---------------------------------------------------------------------------
# G + H. 回滚：失败时恢复所有已注册备份
# ---------------------------------------------------------------------------

# rollback_on_exit <exit_code>  —— trap EXIT 调用；rc != 0 时恢复备份
rollback_on_exit() {
  local rc=${1:-$?}
  cleanup_tmpfiles
  if [[ $rc -eq 0 ]]; then
    return 0
  fi
  if [[ ${#_ROLLBACK_PAIRS[@]} -eq 0 ]]; then
    return 0
  fi
  log_error "脚本失败（rc=$rc），回滚以下文件到备份："
  local pair orig bak
  for pair in "${_ROLLBACK_PAIRS[@]}"; do
    orig="${pair%%|*}"
    bak="${pair##*|}"
    if [[ -f "$bak" ]]; then
      if cp -p "$bak" "$orig" 2>/dev/null; then
        log_info "  已回滚：$orig <- $bak"
      else
        log_error "  回滚失败：$orig（备份在 $bak，请手动恢复）"
      fi
    fi
  done
  log_warn "回滚完成。请检查失败原因后重跑（--force 可跳过幂等判断）"
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
  trap 'log_warn "中断信号收到（$$），清理临时文件并退出"; rollback_on_exit 130; exit 130' INT
  trap 'log_warn "终止信号收到（$$），清理临时文件并退出"; rollback_on_exit 143; exit 143' TERM
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
