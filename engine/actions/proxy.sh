#!/usr/bin/env bash
# engine/actions/proxy.sh —— 推导代理地址并写入 shell 代理环境变量（~/.bashrc）
# 接口：action_proxy_apply | action_proxy_remove | action_proxy_verify <id>
# 由 engine.sh 的 action_dispatch 惰性 source；不要加 set -e，不要调用 setup_traps。
#
# 参数（config/user.env）：
#   PROXY_ENABLED  默认 true；false 时不修改 shell
#   PROXY_HOST     默认空：当前 IPv4 最后一段替换为 1
#   PROXY_PORT     默认空：7890
#   NO_PROXY       默认 localhost,127.0.0.1,::1
#   PROXY_TEST_URL       默认 https://github.com；verify 阶段 curl -x 的真实访问地址
#   PROXY_CONNECT_TIMEOUT 默认 5（秒）
#   PROXY_MAX_TIME       默认 15（秒）
#
# 产物：~/.bashrc 中的托管块（marker 界定）。remove 仅删除该块。

_PROXY_BEGIN='# >>> os-config proxy begin >>>'
_PROXY_END='# <<< os-config proxy end <<<'

_proxy_defaults() {
  : "${PROXY_ENABLED:=true}"
  : "${PROXY_HOST:=}"
  : "${PROXY_PORT:=}"
  : "${NO_PROXY:=localhost,127.0.0.1,::1}"
  : "${PROXY_TEST_URL:=https://github.com}"
  : "${PROXY_CONNECT_TIMEOUT:=5}"
  : "${PROXY_MAX_TIME:=15}"
}

# 解析失败时打印可操作诊断并返回非 0
_proxy_resolve() {
  local rc
  if resolve_proxy_endpoint; then
    if [[ -n "$PROXY_SOURCE_IP" ]]; then
      log_info "PROXY_HOST 未设置：当前 IPv4=$PROXY_SOURCE_IP，自动使用 $RESOLVED_PROXY_HOST"
    fi
    [[ -n "$PROXY_PORT" ]] || log_info "PROXY_PORT 未设置：自动使用 $RESOLVED_PROXY_PORT"
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    1) log_error "无法检测当前 IPv4；请显式设置 PROXY_HOST" ;;
    2) log_error "PROXY_PORT 必须是 1-65535 的端口号（当前：${PROXY_PORT:-<空>}）" ;;
    3) log_error "PROXY_HOST 必须是主机名、IP，或带方括号的 IPv6 地址" ;;
    *) log_error "无法解析代理地址" ;;
  esac
  return "$rc"
}

# 删除 ~/.bashrc 中的托管块（若存在）；缺少结束标记时拒绝删除，避免误删后续内容
_proxy_strip_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  file_contains "$file" "$_PROXY_BEGIN" || return 0
  if ! file_contains "$file" "$_PROXY_END"; then
    log_error "托管块缺少结束标记，拒绝删除：$file"
    return 1
  fi
  sed -i -E "/$_PROXY_BEGIN/,/$_PROXY_END/d" "$file"
}

# 渲染期望的托管块（单一事实来源：写入与比对共用同一份内容）
_proxy_block_render() {
  printf '%s\n' "$_PROXY_BEGIN"
  printf 'export HTTP_PROXY=%q\n' "$RESOLVED_PROXY_URL"
  printf 'export HTTPS_PROXY=%q\n' "$RESOLVED_PROXY_URL"
  printf 'export http_proxy=%q\n' "$RESOLVED_PROXY_URL"
  printf 'export https_proxy=%q\n' "$RESOLVED_PROXY_URL"
  printf 'export NO_PROXY=%q\n' "$NO_PROXY"
  printf 'export no_proxy=%q\n' "$NO_PROXY"
  printf '%s\n' "$_PROXY_END"
}

# 提取 ~/.bashrc 中现有托管块（无则空输出）
_proxy_block_current() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  file_contains "$file" "$_PROXY_BEGIN" || return 0
  sed -n "/$_PROXY_BEGIN/,/$_PROXY_END/p" "$file"
}

action_proxy_apply() {
  local id="$1" bashrc="$HOME/.bashrc"
  _proxy_defaults

  if [[ "$PROXY_ENABLED" != true ]]; then
    log_info "[$id] 代理未启用（PROXY_ENABLED=$PROXY_ENABLED），不修改 shell 代理配置"
    return 0
  fi

  _proxy_resolve || return $?
  ensure_proxy_host_reachable "$RESOLVED_PROXY_HOST" "$RESOLVED_PROXY_PORT" "$PROXY_SOURCE_IP" || return 1

  local want cur
  want="$(_proxy_block_render)"
  cur="$(_proxy_block_current "$bashrc")"

  # 内容一致且非 --force 时保持幂等；否则（缺席 / 地址或 NO_PROXY 变化）重写
  if [[ "${FORCE:-0}" != 1 && "$cur" == "$want" ]]; then
    log_info "[$id] ~/.bashrc proxy 块已是最新，跳过（--force 可重写）"
    return 0
  fi

  register_rollback "$bashrc" || return 1
  touch -- "$bashrc" 2>/dev/null || { log_error "[$id] 无法创建或访问 $bashrc"; return 1; }

  if [[ -n "$cur" ]]; then
    [[ "${FORCE:-0}" == 1 ]] && log_info "[$id] --force 重写 proxy 块" \
      || log_info "[$id] proxy 块内容变化，重写（$RESOLVED_PROXY_URL）"
    _proxy_strip_block "$bashrc" || return 1
  fi

  { printf '\n'; _proxy_block_render; } >>"$bashrc" \
    || { log_error "[$id] 写入失败：$bashrc"; return 1; }

  log_ok "[$id] 已写入 proxy 块（$RESOLVED_PROXY_URL）到 $bashrc"
  log_warn "[$id] 新 shell 才生效；当前会话可执行：source ~/.bashrc"
}

action_proxy_remove() {
  local id="$1" bashrc="$HOME/.bashrc"
  if [[ ! -f "$bashrc" ]] || ! file_contains "$bashrc" "$_PROXY_BEGIN"; then
    log_info "[$id] ~/.bashrc 无 os-config proxy 块，无需还原"
    return 0
  fi
  register_rollback "$bashrc" || return 1
  _proxy_strip_block "$bashrc" || return 1
  log_ok "[$id] 已移除 shell 代理块：$bashrc"
}

action_proxy_verify() {
  local id="$1" bashrc="$HOME/.bashrc"
  _proxy_defaults

  if [[ "$PROXY_ENABLED" != true ]]; then
    if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$_PROXY_BEGIN"; then
      log_error "[$id] PROXY_ENABLED=$PROXY_ENABLED，但 ~/.bashrc 仍含 proxy 块"
      return 1
    fi
    log_ok "[$id] 代理已禁用且无残留块"
    return 0
  fi

  if [[ ! -f "$bashrc" ]] || ! file_contains "$bashrc" "$_PROXY_BEGIN"; then
    log_error "[$id] ~/.bashrc 缺少 os-config proxy 块"
    return 1
  fi

  local proxy_url
  proxy_url="$(sed -n -E '/^export HTTPS_PROXY=/{s/^export HTTPS_PROXY=//; p; q}' "$bashrc")"
  # %q 输出在无特殊字符时不带引号；这里统一去引号后使用
  proxy_url="${proxy_url%\'}"; proxy_url="${proxy_url#\'}"
  if [[ -z "$proxy_url" ]]; then
    log_error "[$id] proxy 块中未找到 HTTPS_PROXY"
    return 1
  fi
  log_ok "[$id] proxy 块存在：HTTPS_PROXY=$proxy_url"

  ensure_proxy_curl_connectivity "$proxy_url" "$PROXY_TEST_URL" \
    "$PROXY_CONNECT_TIMEOUT" "$PROXY_MAX_TIME" || return 1
  log_ok "[$id] 代理配置校验通过"
}

# status：~/.bashrc 里的代理块状态（只读）
action_proxy_status() {
  local id="$1" bashrc="$HOME/.bashrc" url=""
  _proxy_defaults
  if [[ -f "$bashrc" ]] && file_contains "$bashrc" "$_PROXY_BEGIN"; then
    url="$(sed -n -E '/^export HTTPS_PROXY=/{s/^export HTTPS_PROXY=//; p; q}' "$bashrc")"
    url="${url%\'}"; url="${url#\'}"
    printf '    %-22s %s\n' "$id" "已写入代理块（${url:-<空>}）"
  else
    printf '    %-22s %s\n' "$id" "未写入代理块"
  fi
}
