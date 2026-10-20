#!/usr/bin/env bash
# engine/lib/rollback.sh —— 临时文件清理、备份与失败回滚、trap 安装
# 被动作脚本 source；不要加 set -e。

declare -ga _TMPFILES=()
declare -ga _ROLLBACK_ORIG=()
declare -ga _ROLLBACK_BACKUP=()
declare -ga _ROLLBACK_MODE=()
declare -ga _ROLLBACK_EXISTED=()
declare -gA _ROLLBACK_SEEN=()
declare -g  _TRAPS_SET=0
declare -g  _ROLLBACK_DONE=0
declare -g  _ROLLBACK_PERFORMED=0

register_tmpfile() { _TMPFILES+=("$1"); }

cleanup_tmpfiles() {
  local f
  for f in "${_TMPFILES[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f" 2>/dev/null && log_debug "清理临时文件：$f"
  done
  _TMPFILES=()
}

# register_rollback <file> [user|sudo]
#   原文件存在：创建 .bak 备份，失败时恢复；不存在：记为“本次新建”，失败时删除。
register_rollback() {
  local f="$1" mode="${2:-user}" existed=0 bak=""
  [[ "$mode" == "user" || "$mode" == "sudo" ]] || {
    log_error "未知备份模式：$mode（仅支持 user/sudo）"; return 2
  }
  # 同一文件在一次运行中可能被多个动作改写；只保留最早的备份，
  # 否则回滚会按注册顺序相互覆盖，最终无法还原到运行前状态。
  if [[ -n "${_ROLLBACK_SEEN[$f]+x}" ]]; then
    log_debug "已注册回滚，跳过重复备份：$f"
    return 0
  fi
  _ROLLBACK_SEEN[$f]=1
  if [[ "$mode" == "sudo" ]]; then
    sudo test -e "$f" && existed=1
  else
    [[ -e "$f" ]] && existed=1
  fi

  if [[ "$existed" == 1 ]]; then
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    bak="${f}.bak.${ts}.$$"
    if [[ "$mode" == "sudo" ]]; then
      sudo cp -p -- "$f" "$bak" 2>/dev/null || { log_error "备份失败：$f（sudo 权限、磁盘空间或只读文件系统）"; return 1; }
    else
      cp -p -- "$f" "$bak" 2>/dev/null || { log_error "备份失败：$f（权限、磁盘空间或只读文件系统）"; return 1; }
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

# 调用 state.sh 的清理函数（未加载该模块时静默跳过）
_rollback_call() {
  declare -F "$1" >/dev/null 2>&1 || return 0
  "$1"
}

rollback_on_exit() {
  local rc=${1:-$?}
  [[ "$_ROLLBACK_DONE" == 1 ]] && return 0
  _ROLLBACK_DONE=1
  cleanup_tmpfiles

  # 成功：本次运行的清单改动视为已提交，丢弃快照。
  if [[ $rc -eq 0 ]]; then
    _rollback_call state_discard_snapshot
    return 0
  fi

  # --keep-going：保留已完成项（含清单改动），不触发整体回滚。
  if [[ "${KEEP_GOING:-0}" == 1 ]]; then
    log_warn "--keep-going：保留已完成的改动，不触发整体回滚"
    _rollback_call state_discard_snapshot
    return 0
  fi

  # verify 只读校验，失败不应改动文件或清单。
  if [[ "${VERB:-}" == "verify" ]]; then
    _rollback_call state_discard_snapshot
    return 0
  fi

  # 失败：文件改动与清单改动必须一起还原，否则 status/remove 会依据
  # 残留清单去找已回滚的产物。无文件需回滚时也要还原清单。
  _ROLLBACK_PERFORMED=1
  local -a restored=()
  if (( ${#_ROLLBACK_ORIG[@]} == 0 )); then
    _rollback_call state_restore_snapshot
    _rollback_emit_event "${restored[@]}"
    return 0
  fi
  log_error "脚本失败（rc=$rc），回滚以下文件到备份："
  local i orig bak mode existed
  for i in "${!_ROLLBACK_ORIG[@]}"; do
    orig="${_ROLLBACK_ORIG[$i]}"
    bak="${_ROLLBACK_BACKUP[$i]}"
    mode="${_ROLLBACK_MODE[$i]}"
    existed="${_ROLLBACK_EXISTED[$i]:-1}"
    restored+=("$orig")
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
  _rollback_call state_restore_snapshot
  _rollback_emit_event "${restored[@]}"
  log_warn "回滚完成。请检查失败原因后重跑"
}

# _rollback_emit_event <path...> —— 仅在事件模块存在时发送 rollback 事件
_rollback_emit_event() {
  declare -F events_emit >/dev/null 2>&1 || return 0
  events_emit rollback "\"phase\":\"$(json_escape "${VERB:-install}")\",\"restored\":$(json_string_array "$@")"
}

trap_err_handler() {
  local rc=$?
  log_error "[$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")] 命令失败："
  log_error "  命令: ${BASH_COMMAND}"
  log_error "  行号: ${BASH_LINENO[0]:-未知}"
  log_error "  退出码: $rc"
}

# setup_traps —— 注册 EXIT/INT/TERM/ERR trap（每个动作脚本头部调一次）
setup_traps() {
  [[ "$_TRAPS_SET" = 1 ]] && return 0
  _TRAPS_SET=1
  trap 'rollback_on_exit $?' EXIT
  trap 'log_warn "中断信号收到（$$），即将清理并退出"; exit 130' INT
  trap 'log_warn "终止信号收到（$$），即将清理并退出"; exit 143' TERM
  trap 'trap_err_handler' ERR
}
