#!/usr/bin/env bash
# =============================================================================
# 模块：ai-opencode  ——  安装 OpenCode CLI
# 平台：ubuntu24
# 作用：通过 npm 全局安装 opencode-ai 的固定版本
# 依赖：nodejs（runner 在调用本模块前会自动 source nvm + nvm use default）
# =============================================================================
#
# 注意：npm 包名是 opencode-ai（不是 opencode），极易写错。
#
# 【可配置参数】
#   本模块所有版本/包名都集中在仓库根目录的 config/versions.env 中，
#   修改版本只需改那里一处，不需要改本脚本：
#
#     OPENCODE_PKG=opencode-ai          # npm 包名（注意：是 opencode-ai，不是 opencode）
#     OPENCODE_VERSION=1.18.18         # 固定版本号（锁定于 2026-08-16）
#
#   实查最新稳定版：
#     npm view opencode-ai version
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   忽略幂等判断，强制重装（npm install -g 会覆盖现有版本）
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=opencode）
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
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh" && nvm use --silent default >/dev/null 2>&1 || true
fi
if ! cmd_exists node; then
  log_error "node 不可用；请先跑 rt-nodejs 模块"
  exit 1
fi

# 版本变量（来自 config/versions.env，未注入则用默认值）
: "${OPENCODE_PKG:=opencode-ai}"
: "${OPENCODE_VERSION:=1.18.18}"
# npm registry（单跑本模块也强制走 npmmirror 国内镜像，避免海外拉取慢）
: "${NPM_REGISTRY:=https://registry.npmmirror.com}"

# ---------------------------------------------------------------------------
# 1) 幂等检查：opencode 已存在且版本一致 → 跳过
# ---------------------------------------------------------------------------
if cmd_exists opencode && [[ "${FORCE:-0}" != 1 ]]; then
  cur=$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  if [[ "$cur" == "$OPENCODE_VERSION" ]]; then
    log_info "opencode $cur 已安装，跳过（用 --force 或 -f 强制重装）"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 2) 清理旧目录（关键：避免 npm install -g 报 ENOTEMPTY）
#    npm 装新版本时会把旧目录 rename 成 .opencode-ai-XXXX 临时目录再替换；
#    若旧目录非空（残留文件/上次安装失败半状态），rename 失败报 ENOTEMPTY。
#    这里在 install 前主动清理 prefix 下的旧包目录 + npm 残留临时目录。
# ---------------------------------------------------------------------------
prefix=$(npm config get prefix 2>/dev/null || echo "")
if [[ -n "$prefix" ]]; then
  nm_dir="$prefix/lib/node_modules"
  # 清理目标包目录（旧版残留）
  if [[ -d "$nm_dir/$OPENCODE_PKG" ]]; then
    log_info "清理旧目录：$nm_dir/$OPENCODE_PKG"
    rm -rf "$nm_dir/$OPENCODE_PKG" 2>/dev/null || \
      log_warn "清理失败（可能权限不足），继续尝试 npm install"
  fi
  # 清理 npm 上次失败留下的 .opencode-ai-XXXX 临时目录
  shopt -s nullglob
  for d in "$nm_dir"/."$OPENCODE_PKG"-*; do
    [[ -d "$d" ]] && {
      log_info "清理 npm 残留临时目录：$d"
      rm -rf "$d" 2>/dev/null || true
    }
  done
  shopt -u nullglob
fi

# ---------------------------------------------------------------------------
# 3) 安装：npm install -g <pkg>@<version>
#    进展可见：--loglevel=info + --foreground-scripts
#    提速参数：--no-audit / --no-fund / --prefer-offline / --fetch-timeout 120s
#    用 run_step_verbose 把 npm 输出同时落盘到 LOG_FILE。
# ---------------------------------------------------------------------------
run_step_verbose "npm install -g $OPENCODE_PKG@$OPENCODE_VERSION (registry=$NPM_REGISTRY)" \
  npm install -g --loglevel=info --foreground-scripts \
  --no-audit --no-fund --prefer-offline \
  --registry="$NPM_REGISTRY" \
  --fetch-timeout=120000 --fetch-retry-maxtimeout=120000 \
  "$OPENCODE_PKG@$OPENCODE_VERSION"

# ---------------------------------------------------------------------------
# 4) 安装自检：npm install 退出码 0 ≠ 命令可用
#    postinstall 失败 / bin 未链接 / PATH 未含 prefix/bin 都会让命令缺失。
#    就地跑 opencode --version，失败即 exit 1（让 setup_traps 的 ERR trap 回滚）。
# ---------------------------------------------------------------------------
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
prefix_bin="$(npm config get prefix 2>/dev/null)/bin"
if ! cmd_exists "$OPENCODE_BIN" && [[ ! -x "$prefix_bin/$OPENCODE_BIN" ]]; then
  log_error "opencode 安装后仍不可用（prefix/bin=$prefix_bin；请检查 PATH）"
  exit 1
fi
# npm 全局 bin 可能不在当前 shell PATH，显式带上 prefix_bin 兜底再取版本
PATH="$prefix_bin:$PATH" actual="$(
  "$OPENCODE_BIN" --version 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
)"
if [[ -z "$actual" ]]; then
  log_error "opencode --version 无版本输出，安装可能不完整（postinstall 失败？）"
  exit 1
fi
if [[ "$actual" != "$OPENCODE_VERSION" ]]; then
  log_warn "opencode 实际版本 $actual 与固定版本 $OPENCODE_VERSION 不一致（仍按成功处理）"
fi
log_ok "opencode $actual 安装成功（自检通过）"
