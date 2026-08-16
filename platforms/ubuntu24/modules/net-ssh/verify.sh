#!/usr/bin/env bash
# =============================================================================
# 模块：net-ssh/verify  ——  验证 net-ssh 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - ssh 命令是否可用（打印 ssh -V）
#   - ~/.ssh/id_${SSH_KEY_TYPE} 私钥与对应 .pub 公钥是否存在
#   - 私钥权限是否为 600（否则告警）
#
# 【参考变量】（少量；来自 config/user.env）
#   SSH_KEY_TYPE=ed25519   # 决定校验的密钥文件名 id_ed25519 / id_rsa
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

: "${SSH_KEY_TYPE:=ed25519}"

fail=0
if cmd_exists ssh; then
  log_ok "ssh: $(ssh -V 2>&1)"
else
  log_error "ssh 未安装"
  fail=1
fi

keyfile="$HOME/.ssh/id_${SSH_KEY_TYPE}"
if [[ -f "$keyfile" && -f "${keyfile}.pub" ]]; then
  log_ok "密钥存在：$keyfile"
  # 权限检查
  perm=$(stat -c '%a' "$keyfile")
  if [[ "$perm" == "600" ]]; then
    log_ok "私钥权限 600"
  else
    log_warn "私钥权限 $perm（建议 600）"
  fi
else
  log_error "密钥不存在：$keyfile"
  fail=1
fi
exit $fail
