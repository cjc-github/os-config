#!/usr/bin/env bash
# =============================================================================
# 模块：ai-opencode/verify  ——  验证 ai-opencode 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - opencode 命令是否可用（打印版本）
#   - opencode 实际版本是否与固定版本 $OPENCODE_VERSION 一致（不一致仅告警）
#
# 【参考变量】（少量；来自 config/versions.env）
#   OPENCODE_VERSION=1.18.18   # 用于版本比对（锁定于 2026-08-16）
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

# 兜底激活 nvm
if ! cmd_exists node; then
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh" && nvm use --silent default >/dev/null 2>&1 || true
fi

: "${OPENCODE_VERSION:=1.18.18}"

if cmd_exists opencode; then
  v=$(opencode --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  log_ok "opencode: ${v:-<未知版本>}"
  [[ "$v" != "$OPENCODE_VERSION" ]] && log_warn "版本 $v 与固定版本 $OPENCODE_VERSION 不一致"
  exit 0
else
  log_error "opencode 命令不可用"
  exit 1
fi
