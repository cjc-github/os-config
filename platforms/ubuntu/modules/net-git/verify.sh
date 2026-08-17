#!/usr/bin/env bash
# =============================================================================
# 模块：net-git/verify  ——  验证 net-git 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - git 命令是否可用（打印 git --version）
#   - PROXY_ENABLED=true 时，curl -x 是否能访问 GitHub，且 git http.proxy / https.proxy 是否正确
#   - host 留空时使用当前 IPv4 的前三段加 .1，port 留空时使用 7890
#
# 【参考变量】（少量；来自 config/user.env）
#   PROXY_ENABLED=true  PROXY_HOST=  PROXY_PORT=
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

: "${PROXY_ENABLED:=true}"
: "${PROXY_HOST:=}"
: "${PROXY_PORT:=}"
: "${PROXY_TEST_URL:=https://github.com}"
: "${PROXY_CONNECT_TIMEOUT:=5}"
: "${PROXY_MAX_TIME:=15}"

fail=0
if cmd_exists git; then
  log_ok "git: $(git --version)"
else
  log_error "git 未安装"
  fail=1
fi

# 验证代理（PROXY_ENABLED=true 时）
if [[ "$PROXY_ENABLED" == true ]]; then
  if resolve_proxy_endpoint; then
    expected="$RESOLVED_PROXY_URL"
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
  for key in http.proxy https.proxy; do
    v=$(git_cfg_get "$key" || true)
    if [[ "$v" == "$expected" ]]; then
      log_ok "git $key = $v"
    else
      log_error "git $key = '${v:-<未设置>}' (预期 $expected)"
      fail=1
    fi
  done
fi

exit $fail
