#!/usr/bin/env bash
# log.sh —— 彩色终端输出 + 落盘日志（含脱敏）
# 由 setup.sh 在最早期 source；提供 log_info / log_ok / log_warn / log_error / log_section。
# 日志文件路径由 setup.sh 注入到 $LOG_FILE；如未注入则只输出到终端。

# ---------------------------------------------------------------------------
# 初始化（首次 source 时）
# ---------------------------------------------------------------------------

# 颜色（非 TTY 时禁用）
if [[ -t 1 ]]; then
  readonly _C_RESET=$'\033[0m'  _C_INFO=$'\033[36m' _C_OK=$'\033[32m'
  readonly _C_WARN=$'\033[33m'  _C_ERR=$'\033[31m'  _C_SECT=$'\033[1;35m'
else
  readonly _C_RESET='' _C_INFO='' _C_OK='' _C_WARN='' _C_ERR='' _C_SECT=''
fi

# 日志文件：若 setup.sh 已注入 $LOG_FILE 则用之；否则 lazy 创建
_log_file_init() {
  if [[ -n "${LOG_FILE-}" ]]; then return 0; fi
  local logdir="$PROJECT_DIR/logs"
  mkdir -p "$logdir" 2>/dev/null || true
  LOG_FILE="$logdir/setup-$(date +%Y%m%d-%H%M%S).$$.log"
  export LOG_FILE
}
_log_file_init

# ---------------------------------------------------------------------------
# 脱敏：对匹配 (sk-|token|password|passphrase|key)=... 的值打码后落盘
# 用法：echo "$msg" | _redact
# ---------------------------------------------------------------------------

_redact() {
  sed -E 's/((sk-|token|password|passphrase|api[_-]?key|secret)=)[^[:space:]]+/\1****/gi'
}

# ---------------------------------------------------------------------------
# 输出原语：终端（带色） + 日志文件（脱敏 + 时间戳）
# ---------------------------------------------------------------------------

_log_emit() {  # <level> <color> <msg>
  local level="$1" color="$2" msg="$3"
  local ts; ts=$(date '+%H:%M:%S')
  printf '%s[%s]%s %s\n' "$color" "$level" "$_C_RESET" "$msg" >&2
  # 落盘（脱敏）
  if [[ -n "${LOG_FILE-}" ]]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | _redact >>"$LOG_FILE"
  fi
}

log_info()    { _log_emit INFO  "$_C_INFO" "$*"; }
log_ok()      { _log_emit OK    "$_C_OK"   "$*"; }
log_warn()    { _log_emit WARN  "$_C_WARN" "$*"; }
log_error()   { _log_emit ERROR "$_C_ERR"  "$*"; }
log_debug()   { [[ "${DEBUG:-0}" = 1 ]] || return 0; _log_emit DEBUG "$_C_INFO" "$*"; }
log_section() { printf '\n%s=== %s ===%s\n' "$_C_SECT" "$*" "$_C_RESET" >&2
                [[ -z "${LOG_FILE-}" ]] || printf '\n=== %s ===\n' "$*" >>"$LOG_FILE"; }

# 打印日志文件路径（结尾汇总用）
log_path() { echo "$LOG_FILE"; }
