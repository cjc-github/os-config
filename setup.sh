#!/usr/bin/env bash
# setup.sh —— os-config 唯一入口
# ---------------------------------------------------------------------------
# 职责：解析参数 → 加载 catalog/profile → 解析出工具标识 → 交给 engine 编排。
# 本文件不含任何具体工具知识；功能全在 engine/ 与 catalog/ 中。
# 不要加 set -e（失败要可控汇总与回滚，不能中途静默退出）。
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR

# shellcheck source=engine/lib/log.sh
. "$PROJECT_DIR/engine/lib/log.sh"
# shellcheck source=engine/lib/util.sh
. "$PROJECT_DIR/engine/lib/util.sh"
# shellcheck source=engine/lib/rollback.sh
. "$PROJECT_DIR/engine/lib/rollback.sh"
# shellcheck source=engine/lib/state.sh
. "$PROJECT_DIR/engine/lib/state.sh"
# shellcheck source=engine/lib/catalog.sh
. "$PROJECT_DIR/engine/lib/catalog.sh"
# shellcheck source=engine/lib/events.sh
. "$PROJECT_DIR/engine/lib/events.sh"
# shellcheck source=engine/lib/list_json.sh
. "$PROJECT_DIR/engine/lib/list_json.sh"
# shellcheck source=engine/lib/profile.sh
. "$PROJECT_DIR/engine/lib/profile.sh"
# shellcheck source=engine/lib/graph.sh
. "$PROJECT_DIR/engine/lib/graph.sh"
# shellcheck source=engine/lib/backends.sh
. "$PROJECT_DIR/engine/lib/backends.sh"
# shellcheck source=engine/lib/engine.sh
. "$PROJECT_DIR/engine/lib/engine.sh"
# shellcheck source=engine/lib/doctor.sh
. "$PROJECT_DIR/engine/lib/doctor.sh"
# shellcheck source=engine/lib/export.sh
. "$PROJECT_DIR/engine/lib/export.sh"

# ---------------------------------------------------------------------------
# 行为标志
# ---------------------------------------------------------------------------
FORCE=0
DRY_RUN=0
KEEP_GOING=0
NO_SUDO=0
ASSUME_YES=0
FIX=0
OUTPUT_SET=0
DEBUG="${DEBUG:-0}"

VERB=install
PROFILE_NAME=""
PICK=""
ALL=0
LIST=0
JSON=0

VERBS='install|update|remove|verify|status|export|doctor'

# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
os-config —— 声明式软件与配置管理（选择清单 + 七动词）

用法：
  ./setup.sh [动词] [选择] [选项]

动词（默认 install）：
  install   安装/应用选中项（含依赖闭包，依赖优先）
  update    更新选中项（尽力而为）
  remove    卸载/还原选中项（依赖逆序，配置类先还原）
  verify    校验选中项是否符合预期；加 --fix 会自动修复偏差
  status    显示选中项当前状态
  export    扫描当前机器，把已装工具与已应用配置导出为 profile
  doctor    环境体检（sudo/磁盘/apt 锁/网络/清单一致性），只读

选择（三选一，默认使用 profile "default"；export/doctor 不需要选择）：
  --profile <名字>          使用 profiles/ 中的配置清单
  --pick <a,b,@组,apt:jq>   临时指定；支持 @分组 与 后端:包 内联写法
  --all                     选择 catalog 中全部工具

选项：
  --list       列出 catalog 工具与可用 profile，然后退出
  --json       与 --list 连用，输出 JSON（供 Web UI 读取）
  --dry-run    只打印计划，不做写操作
  --force      忽略幂等判断，强制重做
  --fix        与 verify 连用：校验未通过时自动 apply 修复后复验
  --keep-going 单项失败不中断，跑完再汇总（不触发回滚）
  --no-sudo    跳过需要提权的项
  --yes        非交互确认（自动回答 y）
  --output     与 export 连用，指定导出的 profile 路径
  --debug      输出调试日志
  -h, --help   本帮助

示例：
  ./setup.sh --list
  ./setup.sh doctor
  ./setup.sh --dry-run
  ./setup.sh install --profile ai
  ./setup.sh verify --pick git,ssh,proxy
  ./setup.sh verify --fix --profile default
  ./setup.sh export
  ./setup.sh export --output profiles/work.conf
  ./setup.sh remove --pick apt:jq
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
_need_arg() {
  [[ $# -ge 2 && -n "$2" ]] || { log_error "$1 需要一个参数"; usage; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|remove|verify|status|export|doctor) VERB="$1"; shift ;;
    --profile) _need_arg "$@"; PROFILE_NAME="$2"; shift 2 ;;
    --pick)    _need_arg "$@"; PICK="$2"; shift 2 ;;
    --output)  _need_arg "$@"; EXPORT_OUTPUT="$2"; OUTPUT_SET=1; shift 2 ;;
    --all)     ALL=1; shift ;;
    --list)    LIST=1; shift ;;
    --json)    JSON=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --fix)     FIX=1; shift ;;
    --keep-going) KEEP_GOING=1; shift ;;
    --no-sudo) NO_SUDO=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    --debug)   DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) log_error "未知参数：$1"; usage; exit 2 ;;
    *)  log_error "未知动词：$1（应为 ${VERBS//|/、}）"; usage; exit 2 ;;
  esac
done

if [[ "$FIX" == 1 && "$VERB" != verify ]]; then
  log_error "--fix 只能与 verify 一起用"
  exit 2
fi

if [[ "$FIX" == 1 && "$DRY_RUN" == 1 ]]; then
  log_warn "--dry-run 下 --fix 不生效（不会做任何修复）"
fi

if [[ "$OUTPUT_SET" == 1 && "$VERB" != export ]]; then
  log_error "--output 只能与 export 一起用"
  exit 2
fi

if (( (ALL == 1) + (${#PICK} > 0 ? 1 : 0) + (${#PROFILE_NAME} > 0 ? 1 : 0) > 1 )); then
  log_error "--profile / --pick / --all 只能选一个"
  exit 2
fi

if [[ "$JSON" == 1 && "$LIST" != 1 ]]; then
  log_error "--json 必须与 --list 一起使用"
  exit 2
fi

export FORCE DRY_RUN KEEP_GOING NO_SUDO ASSUME_YES FIX DEBUG
export VERB
export EXPORT_OUTPUT

# ---------------------------------------------------------------------------
# 加载数据层
# ---------------------------------------------------------------------------
catalog_load || { log_error "catalog 加载失败"; exit 1; }

if ! profile_load; then
  # profile 数据残缺时只有 --list/--pick/--all 能安全继续；
  # 其余选择方式会用部分解析结果执行，静默漏装工具。
  if [[ "$LIST" != 1 && -z "$PICK" && "$ALL" != 1 ]]; then
    log_error "profiles 加载失败，已中止"
    exit 1
  fi
  log_warn "profiles 目录不可用（--pick/--all 仍可用）"
fi

if [[ "$LIST" == 1 ]]; then
  if [[ "$JSON" == 1 ]]; then
    list_json
    exit 0
  fi
  id="" t="" name=""
  printf '\n%s\n' "工具目录（catalog/*.catalog）"
  printf '  %-14s %-10s %-22s %-16s %s\n' ID GROUP TYPE DEPS DESC
  for id in "${CAT_ORDER[@]}"; do
    t="${CAT_TYPE[$id]}"
    [[ "$t" != package ]] || t="package/${CAT_BACKEND[$id]}"
    printf '  %-14s %-10s %-22s %-16s %s\n' \
      "$id" "${CAT_GROUP[$id]}" "$t" "${CAT_DEPS[$id]:--}" "${CAT_DESC[$id]:--}"
  done
  if (( ${#PROF_ORDER[@]} > 0 )); then
    printf '\n%s\n' "配置清单（profiles/*.conf）"
    printf '  %-14s %s\n' NAME DESC
    for name in "${PROF_ORDER[@]}"; do
      printf '  %-14s %s\n' "$name" "${PROF_DESC[$name]:--}"
    done
  fi
  printf '\n用法：./setup.sh [install|update|remove|verify|status|export|doctor] --profile <名字> [--dry-run]\n\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# doctor / export：不需要选择，直接处理后退出
# ---------------------------------------------------------------------------
if [[ "$VERB" == doctor ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    log_warn "doctor 本身就是只读，--dry-run 无意义（忽略）"
  fi
  if doctor_run; then
    log_ok "doctor 完成"
    exit 0
  else
    log_error "doctor 发现未通过项"
    exit 1
  fi
fi

if [[ "$VERB" == export ]]; then
  export_run || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# 解析选择 → SELECTED_TOOLS
# ---------------------------------------------------------------------------
declare -a SELECTED_TOOLS=()

if [[ -n "$PICK" ]]; then
  # 复用 profile 解析逻辑（@分组 / backend:spec 一致），把 --pick 当作临时 profile
  profile_reset
  PROF_ORDER+=("cli")
  PROF_DESC[cli]="命令行 --pick"
  PROF_EXTENDS[cli]=""
  PROF_TOOLS[cli]="$PICK"
  profile_resolve cli || exit 2
elif [[ "$ALL" == 1 ]]; then
  SELECTED_TOOLS=("${CAT_ORDER[@]}")
elif [[ -n "$PROFILE_NAME" ]]; then
  profile_resolve "$PROFILE_NAME" || exit 2
else
  profile_resolve default || {
    log_error "默认 profile 不可用；请用 --profile/--pick/--all 指定选择"
    exit 2
  }
fi

(( ${#SELECTED_TOOLS[@]} > 0 )) || { log_error "未选择任何工具"; exit 2; }

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
# 写操作（含 verify --fix）需要独占 state/，避免两个运行互相踩清单快照。
# 只读动词与 dry-run 不取锁，也不落状态。
_needs_write_lock() {
  [[ "$DRY_RUN" == 1 ]] && return 1
  case "$VERB" in
    install|update|remove) return 0 ;;
    verify) [[ "$FIX" == 1 ]] && return 0; return 1 ;;
    *) return 1 ;;
  esac
}

# 只读动词与 dry-run 不落状态：dry-run 不写盘；verify/status 只校验。
# 它们若调用 state_snapshot 后按成功/verify 语义丢弃快照，会删掉并发写运行
# 正在使用的 .manifest.run.bak，破坏该运行失败时的回滚基线。
if _needs_write_lock; then
  state_init || { log_error "无法初始化状态目录：${STATE_DIR:-}"; exit 1; }
  state_lock_acquire || exit 1
  state_snapshot || { log_error "无法记录运行前清单快照，已中止"; exit 1; }
fi
setup_traps

# EXIT trap：先回滚（保留原退出码），再发 run_end 供 Web UI 汇总
_exit_report() {
  local rc=$?
  rollback_on_exit "$rc"
  state_lock_release
  events_emit run_end "\"verb\":\"$(json_escape "$VERB")\",\"phase\":\"$(json_escape "$VERB")\",\"ok\":${ENGINE_OK:-0},\"skipped\":${ENGINE_SKIPPED:-0},\"failed\":${ENGINE_FAILED:-0},\"rc\":$rc,\"rolled_back\":$([[ "${_ROLLBACK_PERFORMED:-0}" == 1 ]] && echo true || echo false)"
  exit "$rc"
}
trap '_exit_report' EXIT

log_section "os-config $VERB"
log_info "PROJECT_DIR = $PROJECT_DIR"
log_info "LOG_FILE    = $(log_path)"
log_info "选择        = ${#SELECTED_TOOLS[@]} 项：${SELECTED_TOOLS[*]}"
[[ "$DRY_RUN" == 1 ]] && log_warn "dry-run：不做任何写操作"
[[ "$NO_SUDO" == 1 ]] && log_warn "no-sudo：将跳过需要提权的项"

if engine_run "$VERB" "${SELECTED_TOOLS[@]}"; then
  log_ok "$VERB 完成（日志：$(log_path)）"
  exit 0
else
  log_error "$VERB 未全部成功（日志：$(log_path)）"
  exit 1
fi
