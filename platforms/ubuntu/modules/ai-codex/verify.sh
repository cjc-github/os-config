#!/usr/bin/env bash
# =============================================================================
# 模块：ai-codex/verify  ——  验证 ai-codex 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - codex 命令是否可用（打印版本）
#   - codex 实际版本是否与固定版本 $CODEX_VERSION 一致（不一致仅告警）
#
# 【参考变量】（少量；来自 config/versions.env）
#   CODEX_VERSION=0.147.0   # 用于版本比对
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

# 始终优先激活 nvm default，避免系统 node 存在时漏掉 nvm 全局命令。
activate_nvm_default || true

: "${CODEX_VERSION:=0.147.0}"

if cmd_exists codex; then
  v=$(codex --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  log_ok "codex: ${v:-<未知版本>}"
  [[ "$v" != "$CODEX_VERSION" ]] && log_warn "版本 $v 与固定版本 $CODEX_VERSION 不一致"
  exit 0
else
  log_error "codex 命令不可用"
  exit 1
fi
