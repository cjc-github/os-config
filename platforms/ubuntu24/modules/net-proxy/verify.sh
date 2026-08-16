#!/usr/bin/env bash
# =============================================================================
# 模块：net-proxy/verify  ——  验证 net-proxy 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - ~/.bashrc 是否含 os-config proxy 标记块（# >>> os-config proxy begin >>>）
#   - 块内 HTTPS_PROXY 是否等于预期的 http://${PROXY_HOST}:${PROXY_PORT}
#
# 【参考变量】（少量；来自 config/user.env）
#   PROXY_HOST=127.0.0.1  PROXY_PORT=7890   # 拼装预期代理 URL
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

: "${PROXY_HOST:=127.0.0.1}"
: "${PROXY_PORT:=7890}"
proxy_url="http://${PROXY_HOST}:${PROXY_PORT}"

bashrc="$HOME/.bashrc"
marker_begin="# >>> os-config proxy begin >>>"

fail=0
if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$marker_begin"; then
  log_ok "~/.bashrc 含 os-config proxy 块"
  if file_contains "$bashrc" "export HTTPS_PROXY=\"$proxy_url\""; then
    log_ok "HTTPS_PROXY = $proxy_url"
  else
    log_error "HTTPS_PROXY 未匹配预期值 $proxy_url"
    fail=1
  fi
else
  log_error "~/.bashrc 未找到 os-config proxy 块"
  fail=1
fi
exit $fail
