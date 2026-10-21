#!/usr/bin/env bash
# engine/lib/log.sh —— 彩色终端输出 + 落盘日志（含脱敏）
# 由 setup.sh 侧最早 source；日志路径由 $LOG_FILE 注入。
# 本文件不应设置 set -e。

# 颜色（非 TTY 时禁用）
if [[ -t 1 ]]; then
  readonly _C_RESET=$'\033[0m'  _C_INFO=$'\033[36m' _C_OK=$'\033[32m'
  readonly _C_WARN=$'\033[33m'  _C_ERR=$'\033[31m'  _C_SECT=$'\033[1;35m'
else
  readonly _C_RESET='' _C_INFO='' _C_OK='' _C_WARN='' _C_ERR='' _C_SECT=''
fi

_log_file_init() {
  local logdir
  if [[ -z "${LOG_FILE-}" ]]; then
    logdir="${PROJECT_DIR:-.}/logs"
    LOG_FILE="$logdir/setup-$(date +%Y%m%d-%H%M%S).$$.log"
  else
    logdir="$(dirname "$LOG_FILE")"
  fi
  # 目录/文件不可写时降级为仅终端输出：否则每条日志都会向 stderr 抛红定向错误，
  # 既淹没真正的失败信息，也让人误以为日志已落盘。
  if ! mkdir -p -- "$logdir" 2>/dev/null || ! touch -- "$LOG_FILE" 2>/dev/null; then
    printf '[WARN] 无法写入日志文件：%s（本次仅输出到终端）\n' "$LOG_FILE" >&2
    LOG_FILE=""
  fi
  export LOG_FILE
  [[ -n "$LOG_FILE" ]] || return 0
  chmod 700 -- "$logdir" 2>/dev/null || true
  chmod 600 -- "$LOG_FILE" 2>/dev/null || true
}
_log_file_init

# 脱敏：key=value 形式的凭据、裸令牌（sk-/gh* 前缀）、Bearer 与 URL 凭据
_redact() {
  sed -E \
    -e 's/((sk-|token|password|passphrase|api[_-]?key|secret)=)[^[:space:]]+/\1****/gi' \
    -e 's/(^|[^A-Za-z0-9_-])(sk-[A-Za-z0-9_-]{8,})/\1sk-****/g' \
    -e 's/(^|[^A-Za-z0-9_-])(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})/\1****/g' \
    -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1****/gi' \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1****:****@#g'
}

_log_emit() {  # <level> <color> <msg>
  local level="$1" color="$2" msg="$3"
  local ts; ts=$(date '+%H:%M:%S')
  printf '%s[%s]%s %s\n' "$color" "$level" "$_C_RESET" "$msg" >&2
  if [[ -n "${LOG_FILE-}" ]]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | _redact >>"$LOG_FILE"
  fi
}

log_info()    { _log_emit INFO  "$_C_INFO" "$*"; }
log_ok()      { _log_emit OK    "$_C_OK"   "$*"; }
log_warn()    { _log_emit WARN  "$_C_WARN" "$*"; }
log_error()   { _log_emit ERROR "$_C_ERR"  "$*"; }
log_debug()   { [[ "${DEBUG:-0}" = 1 ]] || return 0; _log_emit DEBUG "$_C_INFO" "$*"; }

# 在提示日志下一行与日志正文对齐显示可复制执行的命令，同时以 COMMAND 级别写入日志。
log_command() {
  local msg="$*" ts
  ts=$(date '+%H:%M:%S')
  printf '       %s\n' "$msg" >&2
  if [[ -n "${LOG_FILE-}" ]]; then
    printf '[%s] [COMMAND] %s\n' "$ts" "$msg" | _redact >>"$LOG_FILE"
  fi
}
log_section() { printf '\n%s=== %s ===%s\n' "$_C_SECT" "$*" "$_C_RESET" >&2
                [[ -z "${LOG_FILE-}" ]] || printf '\n=== %s ===\n' "$*" >>"$LOG_FILE"; }
log_path() { printf '%s\n' "${LOG_FILE:-<未落盘>}"; }
