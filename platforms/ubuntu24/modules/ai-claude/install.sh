#!/usr/bin/env bash
# =============================================================================
# 模块：ai-claude  ——  安装 Claude Code CLI
# 平台：ubuntu24
# 作用：通过 npm 全局安装 @anthropic-ai/claude-code 的固定版本
# 依赖：nodejs（runner 在调用本模块前会自动 source nvm + nvm use default）
# =============================================================================
#
# 【可配置参数】
#   本模块所有版本/包名都集中在仓库根目录的 config/versions.env 中，
#   修改版本只需改那里一处，不需要改本脚本：
#
#     CLAUDE_CODE_PKG=@anthropic-ai/claude-code   # npm 包名
#     CLAUDE_CODE_VERSION=2.1.228                  # 固定版本号
#
#   实查最新稳定版：
#     npm view @anthropic-ai/claude-code version
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   忽略幂等判断，强制重装（npm install -g 会覆盖现有版本）
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=claude）
#   $MODULE_DIR   本模块目录绝对路径
#   $LOG_FILE     本次运行的日志文件
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"
setup_traps   # 注册 EXIT/INT/TERM/ERR trap：失败时清理临时文件 + 回滚备份 + 打印失败命令

# 解析命令行参数：--force / -f / --debug / --help
# 不调用此行，命令行 --force 不会生效（utils.sh 只提供函数，不自动解析）
parse_install_args "$@"
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ---------------------------------------------------------------------------
# 0) 前置检查：node/npm 必须可用
#    （runner 在调用本模块前会自动注入 nvm，这里只是兜底，方便单独运行本脚本）
# ---------------------------------------------------------------------------
if ! cmd_exists node; then
  export NVM_DIR="$HOME/.nvm"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm use --silent default >/dev/null 2>&1 || true
  fi
fi
if ! cmd_exists node; then
  log_error "node 不可用；请先跑 rt-nodejs 模块或检查 nvm 是否安装"
  exit 1
fi

# 版本变量（来自 config/versions.env，未注入则用默认值）
: "${CLAUDE_CODE_PKG:=@anthropic-ai/claude-code}"
: "${CLAUDE_CODE_VERSION:=2.1.228}"
# npm registry（单跑本模块也强制走 npmmirror 国内镜像，避免海外拉取慢）
: "${NPM_REGISTRY:=https://registry.npmmirror.com}"

# ---------------------------------------------------------------------------
# 1) 幂等检查：claude 已存在且版本一致 → 跳过
# ---------------------------------------------------------------------------
if cmd_exists claude && [[ "${FORCE:-0}" != 1 ]]; then
  cur=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  if [[ "$cur" == "$CLAUDE_CODE_VERSION" ]]; then
    log_info "claude $cur 已安装，跳过（用 --force 或 -f 强制重装）"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 2) 清理旧目录（关键：避免 npm install -g 报 ENOTEMPTY）
#    npm 装新版本时会把旧目录 rename 成 .<pkg>-XXXX 临时目录再替换；
#    若旧目录非空（残留文件/上次安装失败半状态），rename 失败报 ENOTEMPTY。
#    这里在 install 前主动清理 prefix 下的旧包目录 + npm 残留临时目录。
# ---------------------------------------------------------------------------
prefix=$(npm config get prefix 2>/dev/null || echo "")
if [[ -n "$prefix" ]]; then
  nm_dir="$prefix/lib/node_modules"
  if [[ -d "$nm_dir/$CLAUDE_CODE_PKG" ]]; then
    log_info "清理旧目录：$nm_dir/$CLAUDE_CODE_PKG"
    rm -rf "$nm_dir/$CLAUDE_CODE_PKG" 2>/dev/null || \
      log_warn "清理失败（可能权限不足），继续尝试 npm install"
  fi
  # 包名含 @scope，目录名是 @scope/pkg；通配符匹配 .@scope-pkg-* 不准，改用 .${pkg basename}-*
  pkg_base="${CLAUDE_CODE_PKG##*/}"
  shopt -s nullglob
  for d in "$nm_dir"/."$pkg_base"-* "$nm_dir"/."$CLAUDE_CODE_PKG"-*; do
    [[ -d "$d" ]] && {
      log_info "清理 npm 残留临时目录：$d"
      rm -rf "$d" 2>/dev/null || true
    }
  done
  shopt -u nullglob
fi

# ---------------------------------------------------------------------------
# 3) 安装：npm install -g <pkg>@<version>
#    进展可见：--loglevel=info（fetch/extract/link 等）+ --foreground-scripts（postinstall）
#    提速参数：
#      --no-audit / --no-fund  → 跳过冗余 HTTP 请求（~1-3s）
#      --prefer-offline        → 优先本地缓存，重跑显著加速
#      --fetch-timeout / --fetch-retry-maxtimeout 120000 → 配合 with_retry 拉长窗口
#    用 run_step_verbose 把 npm 输出同时落盘到 LOG_FILE。
# ---------------------------------------------------------------------------
run_step_verbose "npm install -g $CLAUDE_CODE_PKG@$CLAUDE_CODE_VERSION (registry=$NPM_REGISTRY)" \
  npm install -g --loglevel=info --foreground-scripts \
  --no-audit --no-fund --prefer-offline \
  --registry="$NPM_REGISTRY" \
  --fetch-timeout=120000 --fetch-retry-maxtimeout=120000 \
  "$CLAUDE_CODE_PKG@$CLAUDE_CODE_VERSION"

log_ok "claude 模块安装完成"
