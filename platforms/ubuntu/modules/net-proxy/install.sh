#!/usr/bin/env bash
# net-proxy —— 将代理环境变量写入 ~/.bashrc；host/port 留空时自动推导，不安装代理软件。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"
setup_traps
parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x

: "${PROXY_ENABLED:=true}"
: "${PROXY_HOST:=}"
: "${PROXY_PORT:=}"
: "${NO_PROXY:=localhost,127.0.0.1,::1}"

bashrc="$HOME/.bashrc"
marker_begin="# >>> os-config proxy begin >>>"
marker_end="# <<< os-config proxy end <<<"

if [[ "$PROXY_ENABLED" != true ]]; then
  log_info "代理未启用（PROXY_ENABLED=false），不修改 shell 代理配置"
  exit 0
fi
if resolve_proxy_endpoint; then
  proxy_url="$RESOLVED_PROXY_URL"
else
  rc=$?
  case "$rc" in
    1) log_error "无法检测当前 IPv4；请显式设置 PROXY_HOST" ;;
    2) log_error "PROXY_PORT 必须是 1-65535 的端口号（当前：${PROXY_PORT:-<空>}）" ;;
    3) log_error "PROXY_HOST 必须是主机名、IP，或带方括号的 IPv6 地址" ;;
    *) log_error "无法解析代理地址" ;;
  esac
  exit 2
fi
if [[ -n "$PROXY_SOURCE_IP" ]]; then
  log_info "PROXY_HOST 未设置：当前 IPv4=$PROXY_SOURCE_IP，自动使用 $RESOLVED_PROXY_HOST"
fi
[[ -n "$PROXY_PORT" ]] || log_info "PROXY_PORT 未设置：自动使用 $RESOLVED_PROXY_PORT"
ensure_proxy_host_reachable "$RESOLVED_PROXY_HOST" "$RESOLVED_PROXY_PORT" "$PROXY_SOURCE_IP" || exit 3
register_rollback "$bashrc"
touch "$bashrc"

if file_contains "$bashrc" "$marker_begin"; then
  if [[ "${FORCE:-0}" == 1 ]]; then
    log_info "已存在 os-config proxy 块，FORCE=1 重写"
    sed -i -E "/$marker_begin/,/$marker_end/d" "$bashrc"
  else
    log_info "~/.bashrc 已含 os-config proxy 块，跳过（使用 --force 重写）"
    exit 0
  fi
fi

{
  printf '\n%s\n' "$marker_begin"
  printf 'export HTTP_PROXY=%q\n' "$proxy_url"
  printf 'export HTTPS_PROXY=%q\n' "$proxy_url"
  printf 'export http_proxy=%q\n' "$proxy_url"
  printf 'export https_proxy=%q\n' "$proxy_url"
  printf 'export NO_PROXY=%q\n' "$NO_PROXY"
  printf 'export no_proxy=%q\n' "$NO_PROXY"
  printf '%s\n' "$marker_end"
} >>"$bashrc"

log_ok "已写入 proxy 块到 $bashrc"
log_warn "新 shell 才会生效；当前会话可执行：source ~/.bashrc"
