#!/usr/bin/env bash
# engine/lib/engine.sh —— 五动词编排器（install/update/remove/verify/status）
# ---------------------------------------------------------------------------
# 输入：profile 已解析出的工具标识列表（SELECTED_TOOLS 或显式 --pick 列表）。
# 职责：展开依赖闭包 → 按序分派到 后端适配器（type=package）/ 配置动作（type=config）
#       → 汇总结果。引擎不认识任何具体工具名，只认 catalog 数据。
# 不要加 set -e。
# ---------------------------------------------------------------------------

declare -gA _ACTION_SOURCED=()
declare -g  ENGINE_OK=0
declare -g  ENGINE_SKIPPED=0
declare -g  ENGINE_FAILED=0

# ---------------------------------------------------------------------------
# 动作分派
# ---------------------------------------------------------------------------

# 五动词 → 配置动作动词：install/update 都落到 apply（apply 自身保证幂等）
_engine_action_verb() {
  case "$1" in
    install) printf 'apply' ;;
    update)  printf 'apply' ;;
    remove)  printf 'remove' ;;
    verify)  printf 'verify' ;;
    status)  printf 'status' ;;
    *) return 1 ;;
  esac
}

# 惰性 source 动作脚本（同一动作只 source 一次）
_engine_source_action() {
  local action="$1" file
  [[ -n "${_ACTION_SOURCED[$action]+x}" ]] && return 0
  file="$PROJECT_DIR/engine/actions/${action}.sh"
  [[ -f "$file" ]] || { log_error "动作脚本不存在：$file"; return 2; }
  # shellcheck disable=SC1090
  if ! . "$file"; then
    log_error "加载动作脚本失败：$file"
    return 2
  fi
  _ACTION_SOURCED[$action]=1
}

# 无 action_<name>_status 时的通用状态输出
_engine_config_status_fallback() {
  local id="$1" path
  printf '    %-22s %s\n' "$id" "config:${CAT_ACTION[$id]}"
  if state_has "$id"; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      printf '      %-20s %s\n' "artifact" "$path"
    done < <(state_artifacts "$id")
  else
    printf '      %-20s %s\n' "state" "未记录（可能未安装）"
  fi
}

# action_dispatch <action_verb> <id>
action_dispatch() {
  local averb="$1" id="$2" action fn
  action="${CAT_ACTION[$id]}"
  [[ -n "$action" ]] || { log_error "[$id] catalog 未声明 action"; return 2; }
  [[ -n "${CAT_TYPE[$id]+x}" ]] || { log_error "[$id] 未知工具"; return 2; }

  _engine_source_action "$action" || return $?
  fn="action_${action}_${averb}"
  if declare -F "$fn" >/dev/null; then
    "$fn" "$id"
    return $?
  fi
  if [[ "$averb" == status ]]; then
    _engine_config_status_fallback "$id"
    return 0
  fi
  log_error "[$id] 动作 $action 不支持动词 $averb（缺少 $fn）"
  return 2
}

# ---------------------------------------------------------------------------
# sudo 判定与写操作预报
# ---------------------------------------------------------------------------
_engine_needs_sudo() {
  local id="$1"
  if [[ "${CAT_TYPE[$id]}" == package ]]; then
    case "${CAT_BACKEND[$id]}" in apt|snap) return 0 ;; *) return 1 ;; esac
  fi
  [[ "${CAT_SUDO[$id]}" == 1 ]]
}

_engine_is_write_verb() {
  case "$1" in install|update|remove) return 0 ;; *) return 1 ;; esac
}

# remove 前提示：remove 走逆序（依赖者先删），故依赖本项的项会先于本项被删除。
_engine_warn_dependents() {
  local id dents
  for id in "${GRAPH_ORDER[@]}"; do
    dents="$(graph_dependents "$id" | tr '\n' ' ')"
    dents="${dents% }"
    [[ -n "$dents" ]] && log_warn "[$id] 被以下项依赖，它们将先于本项删除：$dents"
  done
  _engine_warn_external_dependents
}

# 该工具是否已安装：config 类查清单，package 类问后端。
_engine_tool_installed() {
  local id="$1" fn
  if [[ "${CAT_TYPE[$id]:-}" == config ]]; then
    state_has "$id"
    return $?
  fi
  fn="_backend_${CAT_BACKEND[$id]:-}_is_installed"
  declare -F "$fn" >/dev/null || return 1
  "$fn" "$id"
}

# 选集之外、但已安装的依赖者：卸载它们的依赖后，这些项会失效。
# graph_dependents 只看得到本次闭包内的依赖者，必须再扫一遍完整 catalog。
_engine_warn_external_dependents() {
  local id dent dep in_set
  local -a external=()
  for id in "${GRAPH_ORDER[@]}"; do
    for dent in "${CAT_ORDER[@]}"; do
      [[ "$dent" == "$id" ]] && continue
      case " ${CAT_DEPS[$dent]:-} " in
        *" $id "*) ;;
        *) continue ;;
      esac
      in_set=0
      for dep in "${GRAPH_ORDER[@]}"; do
        if [[ "$dep" == "$dent" ]]; then in_set=1; break; fi
      done
      (( in_set == 1 )) && continue
      _engine_tool_installed "$dent" || continue
      external+=("$dent")
    done
  done
  if (( ${#external[@]} > 0 )); then
    log_warn "以下已安装的工具依赖本次卸载的项，卸载后可能失效：${external[*]}"
    log_warn "如需一并卸载，请把它们一起加入本次选择。"
  fi
}

# ---------------------------------------------------------------------------
# 记录配置动作的产物清单（package 类不落清单，实时查询后端）
# ---------------------------------------------------------------------------
_engine_state_sync() {
  local verb="$1" id="$2"
  [[ "${CAT_TYPE[$id]}" == config ]] || return 0
  case "$verb" in
    install|update)
      local -a arts=()
      while IFS= read -r line; do [[ -n "$line" ]] && arts+=("$line"); done \
        < <(catalog_expand_artifacts "$id")
      if (( ${#arts[@]} == 0 )); then
        state_record "$id" "${CAT_ACTION[$id]}"
      else
        state_record "$id" "${CAT_ACTION[$id]}" "${arts[@]}"
      fi
      ;;
    remove)
      state_forget "$id"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 单工具分派
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 平台门：条目的 platforms 不含当前平台时跳过（返回 100 = skipped）
#
# 为什么要这一层：catalog 是跨平台共享的数据层，同一条 [git-cli] 在 Linux 上
# 走 apt、在 Windows 上走 winget；也有些条目（mirrors/syslog/nosuspend/
# lrzsz/tcpdump/...）只在一端有意义。没有 platforms 字段的条目默认 linux，
# 因此 Bash 引擎上本函数恒为真——既有条目的门控顺序与回归结果完全不变。
#
# 故意放在 --no-sudo 与 --dry-run 之前：Linux 专属条目在 dry-run 下应打印
# "不适用"而不是谎报"将执行 install"。
# ---------------------------------------------------------------------------
_ENGINE_PLATFORM="${_ENGINE_PLATFORM:-linux}"

_engine_platform_ok() {
  local id="$1" plats
  plats="${CAT_PLATFORMS[$id]:-linux}"
  case " $plats " in
    *" $_ENGINE_PLATFORM "*) return 0 ;;
  esac
  log_info "[$id] 不适用于当前平台（platforms=$plats），跳过"
  return 1
}

_engine_dispatch_verb() {
  local verb="$1" id="$2"

  _engine_platform_ok "$id" || return 100   # 约定：skipped

  if [[ "${NO_SUDO:-0}" == 1 ]] && _engine_needs_sudo "$id"; then
    log_warn "[$id] 需要提权，--no-sudo 下跳过"
    return 100   # 约定：skipped
  fi

  if [[ "${DRY_RUN:-0}" == 1 ]] && _engine_is_write_verb "$verb"; then
    log_info "[$id] [dry-run] 将执行 ${verb}（type=${CAT_TYPE[$id]}）"
    return 0
  fi

  if [[ "${CAT_TYPE[$id]}" == package ]]; then
    backend_dispatch "$verb" "$id" || return $?
    return 0
  fi

  local averb
  averb="$(_engine_action_verb "$verb")" || { log_error "[$id] 未知动词：$verb"; return 2; }
  action_dispatch "$averb" "$id" || return $?
  _engine_state_sync "$verb" "$id"
}

# 校验一项；--fix 时校验未通过会先 apply 再复验。
# 修完仍不过才判失败，避免"修了但没修好"被算成成功。
_engine_verify_or_fix() {
  local id="$1" rc
  _engine_dispatch_verb verify "$id"
  rc=$?
  (( rc == 0 || rc == 100 )) && return "$rc"

  if [[ "${FIX:-0}" != 1 || "${DRY_RUN:-0}" == 1 ]]; then
    return "$rc"
  fi
  log_warn "[$id] 校验未通过（rc=$rc），执行 apply 修复"
  _engine_dispatch_verb install "$id" || {
    log_error "[$id] 修复失败"
    return 1
  }
  _engine_dispatch_verb verify "$id" || {
    log_error "[$id] 修复后复验仍未通过"
    return 1
  }
  log_ok "[$id] 已修复并通过复验"
  return 0
}

engine_run_one() {
  local verb="$1" id="$2"
  if [[ "$verb" == verify && "${FIX:-0}" == 1 ]]; then
    _engine_verify_or_fix "$id"
    return $?
  fi
  _engine_dispatch_verb "$verb" "$id"
}

# ---------------------------------------------------------------------------
# 编排入口：engine_run <verb> <id...>
#   install/update/verify/status → 依赖闭包拓扑序（依赖在前）
#   remove                       → 逆序（被依赖者先删）
# ---------------------------------------------------------------------------
engine_run() {
  local verb="${1:-install}"; shift || true
  local -a ids=("$@")
  (( ${#ids[@]} > 0 )) || { log_error "engine_run：未提供任何工具"; return 2; }

  case "$verb" in
    install|update|remove|verify|status) ;;
    *) log_error "未知动词：$verb（应为 install/update/remove/verify/status）"; return 2 ;;
  esac

  graph_build "${ids[@]}" || return 1
  if [[ "$verb" == remove ]]; then
    graph_reverse
    _engine_warn_dependents
  fi

  local -a order=("${GRAPH_ORDER[@]}")
  ENGINE_OK=0; ENGINE_SKIPPED=0; ENGINE_FAILED=0
  events_emit run_start "\"verb\":\"$(json_escape "$verb")\",\"dry_run\":$([[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false),\"phase\":\"$(json_escape "$verb")\",\"ids\":$(json_string_array "${order[@]}")"
  log_section "$verb：共 ${#order[@]} 项（含依赖闭包）"

  local -a failed=() skipped=()
  local id rc ok=0 status
  for id in "${order[@]}"; do
    log_info "[$id] ${CAT_DESC[$id]:-$id}（type=${CAT_TYPE[$id]}${CAT_BACKEND[$id]:+/${CAT_BACKEND[$id]}}）"
    events_emit item_start "\"id\":\"$(json_escape "$id")\",\"verb\":\"$(json_escape "$verb")\",\"phase\":\"$(json_escape "$verb")\",\"type\":\"$(json_escape "${CAT_TYPE[$id]:-}")\""
    engine_run_one "$verb" "$id"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      if [[ "${DRY_RUN:-0}" == 1 ]] && _engine_is_write_verb "$verb"; then
        status=planned
      else
        status=ok
      fi
    elif [[ $rc -eq 100 ]]; then
      status=skipped
    else
      status=failed
    fi
    events_emit item_end "\"id\":\"$(json_escape "$id")\",\"verb\":\"$(json_escape "$verb")\",\"phase\":\"$(json_escape "$verb")\",\"type\":\"$(json_escape "${CAT_TYPE[$id]:-}")\",\"status\":\"$status\",\"rc\":$rc"
    case "$status" in
      ok|planned) ok=$((ok + 1)) ;;
      skipped) skipped+=("$id") ;;
      failed) failed+=("$id"); log_error "[$id] $verb 失败（rc=$rc）" ;;
    esac
    case "$status" in
      ok|planned) ENGINE_OK=$((ENGINE_OK + 1)) ;;
      skipped)    ENGINE_SKIPPED=$((ENGINE_SKIPPED + 1)) ;;
      failed)     ENGINE_FAILED=$((ENGINE_FAILED + 1)) ;;
    esac

    if (( ${#failed[@]} > 0 )); then
      if [[ "${KEEP_GOING:-0}" == 1 ]]; then
        log_warn "继续执行其余工具（--keep-going）"
      else
        break
      fi
    fi
  done

  log_section "$verb 汇总：成功 $ok / 跳过 ${#skipped[@]} / 失败 ${#failed[@]}"
  if (( ${#skipped[@]} > 0 )); then
    log_warn "跳过：${skipped[*]}"
  fi
  if (( ${#failed[@]} > 0 )); then
    log_error "失败：${failed[*]}"
    [[ "${KEEP_GOING:-0}" == 1 ]] && \
      log_warn "--keep-going：已跑完其余工具，保留成功项，不触发整体回滚"
    return 1
  fi
  return 0
}
