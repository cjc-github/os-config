#!/usr/bin/env bash
# runner.sh —— 模块加载、依赖拓扑排序、install/verify 调度、nvm node-env 注入
# 由 setup.sh source；调用入口：runner_run_modules <platform_dir> <module_names...>
#
# 注入给模块脚本的环境变量（避免与 runner 关联数组同名）：
#   $MODULE_NAME     模块 NAME（无前缀）
#   $MODULE_DIR      模块目录绝对路径
#   $PLATFORM_DIR    平台目录绝对路径
#   $LOG_FILE        本次运行日志路径
#   $FORCE / $DEBUG  标志
#
# setup.sh 设置的行为标志：
#   FORCE=1 / DRY_RUN=1 / INSTALL_ONLY=1 / VERIFY_ONLY=1
#   KEEP_GOING=1 / NO_SUDO=1

# ---------------------------------------------------------------------------
# 模块表（全局关联数组）
# ---------------------------------------------------------------------------

declare -gA _M_DIR _M_DEPS _M_NEEDS_SUDO _M_DESC _M_STATUS
declare -ga _M_ORDER=()
declare -g _OK_COUNT=0 _FAIL_COUNT=0 _VERIFY_FAIL_COUNT=0 _SKIP_COUNT=0
declare -ga _FAIL_LIST=()        # 安装失败的模块名（D 失败汇总）
declare -ga _VERIFY_FAIL_LIST=() # 验证失败的模块名
declare -ga _SKIP_LIST=()        # 跳过的模块名
declare -g __NODE_ACTIVATED=0

# 加载某平台所有模块的元数据
runner_load_modules() {  # <platform_dir>
  local pdir="$1" m name deps sudo_flag desc k v dep
  _M_DIR=(); _M_DEPS=(); _M_NEEDS_SUDO=(); _M_DESC=(); _M_ORDER=()
  [[ -d "$pdir/modules" ]] || { log_error "平台目录无 modules/：$pdir"; return 1; }
  for m in "$pdir/modules"/*/; do
    [[ -f "$m/module.conf" ]] || continue
    name=""; deps=""; sudo_flag=0; desc=""
    while IFS='=' read -r k v; do
      v="${v%$'\r'}"
      case "$k" in
        NAME) name="$v" ;;
        DESC) desc="$v" ;;
        DEPS) deps="$v" ;;
        NEEDS_SUDO) sudo_flag="$v" ;;
      esac
    done <"$m/module.conf"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "非法或缺失的模块 NAME：$m/module.conf（NAME=$name）"; return 1; }
    [[ -z "${_M_DIR[$name]+x}" ]] || { log_error "模块 NAME 重复：$name（$m 与 ${_M_DIR[$name]}）"; return 1; }
    [[ "$sudo_flag" == 0 || "$sudo_flag" == 1 ]] || { log_error "模块 $name 的 NEEDS_SUDO 必须是 0 或 1"; return 1; }
    if [[ -n "$deps" ]]; then
      IFS=',' read -r -a dep_items <<<"$deps"
      for dep in "${dep_items[@]}"; do
        dep="${dep//[[:space:]]/}"
        [[ -z "$dep" || "$dep" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "模块 $name 含非法依赖名：$dep"; return 1; }
      done
    fi
    _M_DIR["$name"]="${m%/}"
    _M_DEPS["$name"]="$deps"
    _M_NEEDS_SUDO["$name"]="$sudo_flag"
    _M_DESC["$name"]="$desc"
    _M_ORDER+=("$name")
  done
  (( ${#_M_ORDER[@]} > 0 )) || { log_error "平台没有可加载的模块：$pdir"; return 1; }
  log_debug "已加载 ${#_M_ORDER[@]} 个模块：${_M_ORDER[*]}"
}

# ---------------------------------------------------------------------------
# 拓扑排序：递归展开 DEPS，输出 NAME 换行分隔
# 用全局 _TOPO_VISITED / _TOPO_STACK 防循环
# ---------------------------------------------------------------------------

declare -gA _TOPO_VISITED _TOPO_STACK

_topo_resolve() {  # <name>  —— 向 stdout 输出（被 mapfile 收集）
  local name="$1" dep deps_list
  [[ -n "${_TOPO_VISITED[$name]:-}" ]] && return 0
  if [[ -n "${_TOPO_STACK[$name]:-}" ]]; then
    log_error "检测到循环依赖：$name"
    return 1
  fi
  _TOPO_STACK["$name"]=1
  deps_list="${_M_DEPS[$name]:-}"
  if [[ -n "$deps_list" ]]; then
    IFS=',' read -r -a deps <<<"$deps_list"
    for dep in "${deps[@]}"; do
      dep="${dep// /}"
      [[ -z "$dep" ]] && continue
      if [[ -z "${_M_DIR[$dep]+x}" ]]; then
        log_error "模块 '$name' 依赖未注册的 '$dep'"
        return 1
      fi
      _topo_resolve "$dep" || return 1
    done
  fi
  unset '_TOPO_STACK[$name]'
  _TOPO_VISITED["$name"]=1
  echo "$name"
}

runner_topo_sort() {  # <names...>  —— stdout: 换行分隔的执行序
  _TOPO_VISITED=(); _TOPO_STACK=()
  local n
  for n in "$@"; do
    [[ -n "${_M_DIR[$n]+x}" ]] || { log_error "未注册的模块：$n"; return 1; }
  done
  for n in "$@"; do
    _topo_resolve "$n" || return 1
  done
}

# ---------------------------------------------------------------------------
# nvm / node-env 注入
# 在调用 DEPS 含 nodejs 的模块前激活 nvm + default node/npm 到当前 PATH
# ---------------------------------------------------------------------------

runner_activate_node_env() {
  [[ "$__NODE_ACTIVATED" = 1 ]] && return 0
  local nvm_dir="$HOME/.nvm"
  if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
    log_warn "nvm 未安装（$nvm_dir/nvm.sh 不存在），跳过 node-env 注入"
    return 0
  fi
  # shellcheck disable=SC1091
  \. "$nvm_dir/nvm.sh" || { log_error "加载 nvm 失败"; return 1; }
  nvm use --silent default >/dev/null 2>&1 || true
  if cmd_exists node; then
    __NODE_ACTIVATED=1
    log_debug "已激活 node-env：$(node --version 2>&1)"
  else
    log_warn "nvm 已加载但 node 仍不可用，后续 ai-* 模块可能失败"
  fi
}

# ---------------------------------------------------------------------------
# 单模块运行
# ---------------------------------------------------------------------------

runner_run_module() {  # <name>
  local name="$1"
  local mdir="${_M_DIR[$name]}"
  local needs_sudo="${_M_NEEDS_SUDO[$name]}"
  local deps="${_M_DEPS[$name]:-}"
  local rc=0

  log_section "[$name]"

  # NEEDS_SUDO 校验（dry-run 时只报告不真校验）
  if [[ "$needs_sudo" = 1 ]]; then
    if [[ "${NO_SUDO:-0}" = 1 ]]; then
      log_warn "模块 $name 需要 sudo，已被 --no-sudo 跳过"
      _SKIP_COUNT=$((_SKIP_COUNT + 1))
      _SKIP_LIST+=("$name")
      _M_STATUS["$name"]="skipped"
      return 0
    fi
    if [[ "${DRY_RUN:-0}" = 1 ]]; then
      log_info "  (dry-run) 模块 $name 需要 sudo"
    else
      if ! require_sudo; then
        _FAIL_COUNT=$((_FAIL_COUNT + 1))
        _FAIL_LIST+=("$name")
        _M_STATUS["$name"]="failed"
        return 1
      fi
    fi
  fi

  # DEPS 含 nodejs：注入 nvm
  if [[ ",$deps," == *",nodejs,"* ]]; then
    runner_activate_node_env
  fi

  # install
  if [[ "${VERIFY_ONLY:-0}" != 1 ]]; then
    log_info "▶ [$name] install"
    if [[ -f "$mdir/install.sh" ]]; then
      if [[ "${DRY_RUN:-0}" = 1 ]]; then
        log_info "  (dry-run) bash $mdir/install.sh"
      else
        MODULE_NAME="$name" MODULE_DIR="$mdir" PLATFORM_DIR="${PLATFORM_DIR:-}" \
          FORCE="${FORCE:-0}" DEBUG="${DEBUG:-0}" LOG_FILE="${LOG_FILE:-}" \
          BACKUP_MANIFEST="${BACKUP_MANIFEST:-}" bash "$mdir/install.sh"
        rc=$?
        if [[ $rc -ne 0 ]]; then
          log_error "[$name] install 失败 (exit=$rc)"
          _FAIL_COUNT=$((_FAIL_COUNT + 1))
          _FAIL_LIST+=("$name")
          _M_STATUS["$name"]="failed"
          [[ "${KEEP_GOING:-0}" = 1 ]] && return 0 || return 1
        fi
      fi
    else
      log_warn "  $name 无 install.sh，跳过安装"
    fi
  fi

  # verify
  if [[ "${INSTALL_ONLY:-0}" != 1 ]]; then
    log_info "▶ [$name] verify"
    if [[ -f "$mdir/verify.sh" ]]; then
      if [[ "${DRY_RUN:-0}" = 1 ]]; then
        log_info "  (dry-run) bash $mdir/verify.sh"
      else
        MODULE_NAME="$name" MODULE_DIR="$mdir" PLATFORM_DIR="${PLATFORM_DIR:-}" \
          bash "$mdir/verify.sh"
        rc=$?
        if [[ $rc -ne 0 ]]; then
          log_error "[$name] verify 失败 (exit=$rc)"
          _VERIFY_FAIL_COUNT=$((_VERIFY_FAIL_COUNT + 1))
          _VERIFY_FAIL_LIST+=("$name")
          _M_STATUS["$name"]="failed"
          [[ "${KEEP_GOING:-0}" = 1 ]] && return 0 || return 1
        fi
        log_ok "[$name] verify 通过"
      fi
    else
      log_warn "  $name 无 verify.sh，跳过验证"
    fi
  fi

  _OK_COUNT=$((_OK_COUNT + 1))
  _M_STATUS["$name"]="ok"
  return 0
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------

runner_run_modules() {  # <platform_dir> <module_names...>
  local pdir="$1"; shift
  local -a names=("$@") ordered
  local rc=0

  PLATFORM_DIR="$pdir"  # 给后续模块注入用

  runner_load_modules "$pdir" || return 1

  local ordered_str
  ordered_str=$(runner_topo_sort "${names[@]}") || return 1
  mapfile -t -O 0 ordered <<<"$ordered_str"

  log_info "执行计划（${#ordered[@]} 个模块）：${ordered[*]}"

  _OK_COUNT=0; _FAIL_COUNT=0; _VERIFY_FAIL_COUNT=0; _SKIP_COUNT=0
  _FAIL_LIST=(); _VERIFY_FAIL_LIST=(); _SKIP_LIST=(); _M_STATUS=()
  BACKUP_MANIFEST="${LOG_FILE}.backups"
  : >"$BACKUP_MANIFEST"
  export BACKUP_MANIFEST

  local n dep deps_list blocked_by
  local -a deps
  for n in "${ordered[@]}"; do
    blocked_by=""
    deps_list="${_M_DEPS[$n]:-}"
    if [[ -n "$deps_list" ]]; then
      IFS=',' read -r -a deps <<<"$deps_list"
      for dep in "${deps[@]}"; do
        dep="${dep//[[:space:]]/}"
        [[ -z "$dep" ]] && continue
        if [[ "${_M_STATUS[$dep]:-}" != "ok" ]]; then
          blocked_by="$dep"
          break
        fi
      done
    fi
    if [[ -n "$blocked_by" ]]; then
      log_section "[$n]"
      log_warn "模块 $n 因依赖 $blocked_by 状态为 ${_M_STATUS[$blocked_by]:-unknown} 而跳过"
      _SKIP_COUNT=$((_SKIP_COUNT + 1))
      _SKIP_LIST+=("$n")
      _M_STATUS["$n"]="blocked"
      continue
    fi
    runner_run_module "$n" || { rc=1; [[ "${KEEP_GOING:-0}" = 1 ]] || break; }
  done

  log_section "汇总"
  log_info "成功=$_OK_COUNT  安装失败=$_FAIL_COUNT  验证失败=$_VERIFY_FAIL_COUNT  跳过=$_SKIP_COUNT"
  # 醒目列出失败的模块名
  if [[ ${#_FAIL_LIST[@]} -gt 0 ]]; then
    log_error "✗ 安装失败的模块：${_FAIL_LIST[*]}"
  fi
  if [[ ${#_VERIFY_FAIL_LIST[@]} -gt 0 ]]; then
    log_error "✗ 验证失败的模块：${_VERIFY_FAIL_LIST[*]}"
  fi
  if [[ ${#_SKIP_LIST[@]} -gt 0 ]]; then
    log_warn "⊘ 跳过的模块：${_SKIP_LIST[*]}"
  fi
  if [[ -s "$BACKUP_MANIFEST" ]]; then
    log_info "本次备份文件："
    while IFS= read -r backup; do
      printf '  %s\n' "$backup" >&2
    done <"$BACKUP_MANIFEST"
  else
    rm -f -- "$BACKUP_MANIFEST"
  fi
  log_info "日志文件：$(log_path)"
  if (( _FAIL_COUNT > 0 || _VERIFY_FAIL_COUNT > 0 )); then
    return 1
  fi
  return "$rc"
}
