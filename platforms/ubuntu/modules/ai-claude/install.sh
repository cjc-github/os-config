#!/usr/bin/env bash
# =============================================================================
# 模块：ai-claude  ——  安装 Claude Code CLI
# 平台：ubuntu（22.04/24.04）
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
# 0) 前置检查：优先激活 nvm default，避免系统 node/npm 抢占 PATH
# ---------------------------------------------------------------------------
activate_nvm_default || true
if ! cmd_exists node || ! cmd_exists npm; then
  log_error "node/npm 不可用；请先跑 rt-nodejs 模块"
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
# 2) 安装固定版本；只有遇到 ENOTEMPTY 才清理 npm 隐藏残留并重试
# ---------------------------------------------------------------------------
npm_install_global_fixed "${CLAUDE_CODE_PKG}" "${CLAUDE_CODE_VERSION}" "${NPM_REGISTRY}"

# ---------------------------------------------------------------------------
# 4) 安装自检：npm install 退出码 0 ≠ 命令可用
#    postinstall 失败 / bin 未链接 / PATH 未含 prefix/bin 都会让命令缺失。
#    就地跑 claude --version，失败即 exit 1（让 setup_traps 的 ERR trap 回滚）。
# ---------------------------------------------------------------------------
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
prefix_bin="$(npm config get prefix 2>/dev/null)/bin"
if ! bin_path=$(resolve_command_path "${CLAUDE_BIN}" "$prefix_bin"); then
  log_error "claude 安装后仍不可用（prefix/bin=$prefix_bin；请检查 PATH）"
  exit 1
fi
actual="$(
  "$bin_path" --version 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
)"
if [[ -z "$actual" ]]; then
  log_error "claude --version 无版本输出，安装可能不完整（postinstall 失败？）"
  exit 1
fi
if [[ "$actual" != "$CLAUDE_CODE_VERSION" ]]; then
  log_warn "claude 实际版本 $actual 与固定版本 $CLAUDE_CODE_VERSION 不一致（仍按成功处理）"
fi
log_ok "claude $actual 安装成功（自检通过）"
