#!/usr/bin/env bash
# ai-claude/verify.sh
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"

# 始终优先激活 nvm default，避免系统 node 存在时漏掉 nvm 全局命令。
activate_nvm_default || true

: "${CLAUDE_CODE_VERSION:=2.1.228}"

if cmd_exists claude; then
  v=$(claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  log_ok "claude: ${v:-<未知版本>}"
  if [[ "$v" != "$CLAUDE_CODE_VERSION" ]]; then
    log_warn "版本 $v 与固定版本 $CLAUDE_CODE_VERSION 不一致"
  fi
  exit 0
else
  log_error "claude 命令不可用"
  exit 1
fi
