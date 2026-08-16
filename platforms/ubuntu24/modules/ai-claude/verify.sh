#!/usr/bin/env bash
# ai-claude/verify.sh
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"

# 兜底激活 nvm
if ! cmd_exists node; then
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh" && nvm use --silent default >/dev/null 2>&1 || true
fi

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
