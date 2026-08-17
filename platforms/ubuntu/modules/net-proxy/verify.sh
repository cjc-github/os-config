#!/usr/bin/env bash
# net-proxy/verify —— 验证 ~/.bashrc 代理块，并用 curl -x 执行真实代理访问。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"

: "${PROXY_ENABLED:=true}"
: "${PROXY_HOST:=}"
: "${PROXY_PORT:=}"
: "${PROXY_TEST_URL:=https://github.com}"
: "${PROXY_CONNECT_TIMEOUT:=5}"
: "${PROXY_MAX_TIME:=15}"

if [[ "$PROXY_ENABLED" != true ]]; then
  log_ok "代理未启用，proxy 模块按 skipped 处理（验证通过）"
  exit 0
fi
if resolve_proxy_endpoint; then
  proxy_url="$RESOLVED_PROXY_URL"
else
  rc=$?
  case "$rc" in
    1) log_error "无法检测当前 IPv4；请显式设置 PROXY_HOST" ;;
    2) log_error "PROXY_PORT 无效：${PROXY_PORT:-<空>}" ;;
    3) log_error "PROXY_HOST 无效：${PROXY_HOST:-<空>}" ;;
    *) log_error "无法解析代理地址" ;;
  esac
  exit 1
fi
ensure_proxy_host_reachable "$RESOLVED_PROXY_HOST" "$RESOLVED_PROXY_PORT" "$PROXY_SOURCE_IP" || exit 1
ensure_proxy_curl_connectivity "$proxy_url" "$PROXY_TEST_URL" "$PROXY_CONNECT_TIMEOUT" "$PROXY_MAX_TIME" || exit 1

bashrc="$HOME/.bashrc"
marker_begin="# >>> os-config proxy begin >>>"
expected=$(printf 'export HTTPS_PROXY=%q' "$proxy_url")

fail=0
if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$marker_begin"; then
  log_ok "~/.bashrc 含 os-config proxy 块"
  if grep -Fq -- "$expected" "$bashrc"; then
    log_ok "HTTPS_PROXY = $proxy_url"
  else
    log_error "HTTPS_PROXY 未匹配预期值 $proxy_url"
    fail=1
  fi
else
  log_error "~/.bashrc 未找到 os-config proxy 块"
  fail=1
fi
exit "$fail"
