#!/usr/bin/env bash
# setup.sh —— os-config 唯一入口
# 流程：解析参数 → 识别平台 → 读配置 → 排序 → 逐模块 install+verify
set -euo pipefail

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR

# 共享库（注意：log.sh 内会 lazy 初始化 $LOG_FILE）
# shellcheck source=lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=lib/log.sh
. "$PROJECT_DIR/lib/log.sh"
# shellcheck source=lib/platform.sh
. "$PROJECT_DIR/lib/platform.sh"
# shellcheck source=lib/runner.sh
. "$PROJECT_DIR/lib/runner.sh"

# ---------------------------------------------------------------------------
# 行为标志
# ---------------------------------------------------------------------------

FORCE=0
DRY_RUN=0
INSTALL_ONLY=0
VERIFY_ONLY=0
KEEP_GOING=0
NO_SUDO=0
DEBUG=${DEBUG:-0}
PLATFORM_OVERRIDE=""
MODULES_FROM_CLI=""

# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
os-config —— 一键初始化当前平台
用法:
  ./setup.sh                              按配置文件 config/modules.conf 跑
  ./setup.sh --module git,nodejs          只跑指定模块（自动补依赖）
  ./setup.sh --all                        跑当前平台全部模块
  ./setup.sh --list                      列出可用模块（NAME / DEPS / NEEDS_SUDO）
  ./setup.sh --dry-run                    只打印执行计划不执行
  ./setup.sh --install-only               只跑 install
  ./setup.sh --verify-only                只跑 verify
  ./setup.sh --force                      忽略幂等判断强制重装
  ./setup.sh --keep-going                 遇错不停，跑完再汇总
  ./setup.sh --no-sudo                    跳过 NEEDS_SUDO 的模块
  ./setup.sh --platform ubuntu24          强制指定平台（测试用）
  ./setup.sh --help                       本帮助
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)        MODULES_FROM_CLI="$2"; shift 2 ;;
    --all)           ALL=1; shift ;;
    --list)          LIST=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --install-only)  INSTALL_ONLY=1; shift ;;
    --verify-only)   VERIFY_ONLY=1; shift ;;
    --force)         FORCE=1; shift ;;
    --keep-going)    KEEP_GOING=1; shift ;;
    --no-sudo)       NO_SUDO=1; shift ;;
    --platform)      PLATFORM_OVERRIDE="$2"; shift 2 ;;
    --debug)         DEBUG=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               log_error "未知参数：$1"; usage; exit 2 ;;
  esac
done

# shellcheck disable=SC2034
: "${ALL:=0}"; : "${LIST:=0}"

# ---------------------------------------------------------------------------
# 平台识别
# ---------------------------------------------------------------------------

PLATFORM=""
if [[ -n "$PLATFORM_OVERRIDE" ]]; then
  PLATFORM="$PLATFORM_OVERRIDE"
  log_warn "使用 --platform 强制覆盖：$PLATFORM"
else
  PLATFORM="$(detect_platform || true)"
  if [[ -z "$PLATFORM" ]]; then
    log_error "无法识别当前平台（暂未支持，可用 --platform <name> 强制覆盖）"
    exit 1
  fi
fi

PLATFORM_DIR="$PROJECT_DIR/platforms/$PLATFORM"
if [[ ! -d "$PLATFORM_DIR" ]]; then
  log_error "平台目录不存在：$PLATFORM_DIR"
  exit 1
fi
# 平台自检（双保险）
if ! platform_selfcheck "$PLATFORM_DIR" 2>/dev/null; then
  log_warn "平台自检脚本 detect.sh 未通过（可能 --platform 强制指定）"
fi

log_section "os-config"
log_info "PROJECT_DIR  = $PROJECT_DIR"
log_info "PLATFORM     = $PLATFORM"
log_info "PLATFORM_DIR = $PLATFORM_DIR"
log_info "LOG_FILE     = $(log_path)"

# ---------------------------------------------------------------------------
# 加载配置
# ---------------------------------------------------------------------------

# versions.env
VERSIONS_FILE="$PROJECT_DIR/config/versions.env"
if [[ -f "$VERSIONS_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$VERSIONS_FILE"
  set +a
  log_debug "已加载 versions.env"
else
  log_warn "未找到 versions.env，模块若依赖版本变量会异常"
fi

# user.env（可选，复制自 user.env.example）
USER_ENV="$PROJECT_DIR/config/user.env"
if [[ -f "$USER_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$USER_ENV"
  set +a
  log_debug "已加载 user.env"
fi

# ---------------------------------------------------------------------------
# 加载模块表（runner_load_modules）用于 --list 和确定 --all 名单
# ---------------------------------------------------------------------------

runner_load_modules "$PLATFORM_DIR" || { log_error "加载模块表失败"; exit 1; }

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------

if [[ "$LIST" = 1 ]]; then
  printf '%-12s %-30s %-25s %s\n' "NAME" "DIR" "DEPS" "NEEDS_SUDO"
  for n in $(printf '%s\n' "${!_M_DIR[@]}" | LC_ALL=C sort); do
    printf '%-12s %-30s %-25s %s\n' \
      "$n" "${_M_DIR[$n]#$PROJECT_DIR/}" "${_M_DEPS[$n]:-}" "${_M_NEEDS_SUDO[$n]}"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# 确定启用模块集合
# ---------------------------------------------------------------------------

declare -a MODULES=()

if [[ -n "$MODULES_FROM_CLI" ]]; then
  IFS=',' read -r -a MODULES <<<"$MODULES_FROM_CLI"
elif [[ "${ALL:-0}" = 1 ]]; then
  for n in "${!_M_DIR[@]}"; do MODULES+=("$n"); done
else
  # 读 modules.conf（去掉注释和空行）
  CONF="$PROJECT_DIR/config/modules.conf"
  if [[ ! -f "$CONF" ]]; then
    log_error "modules.conf 不存在：$CONF"
    exit 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"           # 去注释
    line="${line//[[:space:]]/}" # 去空白
    [[ -z "$line" ]] && continue
    MODULES+=("$line")
  done < "$CONF"
fi

if [[ ${#MODULES[@]} -eq 0 ]]; then
  log_error "未指定任何模块（请填 config/modules.conf 或用 --module / --all）"
  exit 1
fi

# 校验每个名字都已注册
for n in "${MODULES[@]}"; do
  if [[ -z "${_M_DIR[$n]+x}" ]]; then
    log_error "未注册的模块：$n（用 --list 查可用模块）"
    exit 1
  fi
done

log_info "启用的模块（${#MODULES[@]}）：${MODULES[*]}"

# ---------------------------------------------------------------------------
# 调度
# ---------------------------------------------------------------------------

runner_run_modules "$PLATFORM_DIR" "${MODULES[@]}"
rc=$?

if [[ $rc -eq 0 ]]; then
  log_ok "全部完成 ✓"
else
  log_error "存在失败的模块（rc=$rc）"
fi
exit $rc
