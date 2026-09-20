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
# shellcheck source=engine/lib/profile.sh
. "$PROJECT_DIR/engine/lib/profile.sh"
# shellcheck source=engine/lib/graph.sh
. "$PROJECT_DIR/engine/lib/graph.sh"
# shellcheck source=engine/lib/backends.sh
. "$PROJECT_DIR/engine/lib/backends.sh"
# shellcheck source=engine/lib/engine.sh
. "$PROJECT_DIR/engine/lib/engine.sh"

# ---------------------------------------------------------------------------
# 行为标志
# ---------------------------------------------------------------------------
FORCE=0
DRY_RUN=0
KEEP_GOING=0
NO_SUDO=0
DEBUG="${DEBUG:-0}"

VERB=install
PROFILE_NAME=""
PICK=""
ALL=0
LIST=0

VERBS='install|update|remove|verify|status'

# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
os-config —— 声明式软件与配置管理（选择清单 + 五动词）

用法：
  ./setup.sh [动词] [选择] [选项]

动词（默认 install）：
  install   安装/应用选中项（含依赖闭包，依赖优先）
  update    更新选中项（尽力而为）
  remove    卸载/还原选中项（依赖逆序，配置类先还原）
  verify    校验选中项是否符合预期
  status    显示选中项当前状态

选择（三选一，默认使用 profile "default"）：
  --profile <名字>          使用 profiles/ 中的配置清单
  --pick <a,b,@组,apt:jq>   临时指定；支持 @分组 与 后端:包 内联写法
  --all                     选择 catalog 中全部工具

选项：
  --list       列出 catalog 工具与可用 profile，然后退出
  --dry-run    只打印计划，不做写操作
  --force      忽略幂等判断，强制重做
  --keep-going 单项失败不中断，跑完再汇总（不触发回滚）
  --no-sudo    跳过需要提权的项
  --debug      输出调试日志
  -h, --help   本帮助

示例：
  ./setup.sh --list
  ./setup.sh --dry-run
  ./setup.sh install --profile ai
  ./setup.sh verify --pick git,ssh,proxy
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
    install|update|remove|verify|status) VERB="$1"; shift ;;
    --profile) _need_arg "$@"; PROFILE_NAME="$2"; shift 2 ;;
    --pick)    _need_arg "$@"; PICK="$2"; shift 2 ;;
    --all)     ALL=1; shift ;;
    --list)    LIST=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --keep-going) KEEP_GOING=1; shift ;;
    --no-sudo) NO_SUDO=1; shift ;;
    --debug)   DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) log_error "未知参数：$1"; usage; exit 2 ;;
    *)  log_error "未知动词：$1（应为 ${VERBS//|/、}）"; usage; exit 2 ;;
  esac
done

if (( (ALL == 1) + (${#PICK} > 0 ? 1 : 0) + (${#PROFILE_NAME} > 0 ? 1 : 0) > 1 )); then
  log_error "--profile / --pick / --all 只能选一个"
  exit 2
fi

export FORCE DRY_RUN KEEP_GOING NO_SUDO DEBUG

# ---------------------------------------------------------------------------
# 加载数据层
# ---------------------------------------------------------------------------
catalog_load || { log_error "catalog 加载失败"; exit 1; }

profile_load >/dev/null 2>&1 || log_warn "profiles 目录不可用（--pick/--all 仍可用）"

if [[ "$LIST" == 1 ]]; then
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
  printf '\n用法：./setup.sh [install|update|remove|verify|status] --profile <名字> [--dry-run]\n\n'
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
state_init
state_snapshot          # 记录运行前清单，失败回滚时还原
setup_traps

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
