#!/usr/bin/env bash
# engine/actions/git.sh —— 配置 git 身份与代理（~/.gitconfig）
# 接口：action_git_apply | action_git_remove | action_git_verify <id>
# 由 engine.sh 的 action_dispatch 惰性 source；不要加 set -e，不要调用 setup_traps。
#
# 依赖 catalog 中的 [git-cli]（apt 安装 git）；本动作不安装包。
#
# 参数（config/user.env）：
#   GIT_USER_NAME   留空则 warning 后跳过（不覆盖现有身份）
#   GIT_USER_EMAIL  留空则 warning 后跳过
#   PROXY_ENABLED   默认 true；为 true 时写 http.proxy/https.proxy
#   PROXY_HOST/PORT 留空自动推导（复用 util.sh 的 resolve_proxy_endpoint）
#
# remove 语义：只 unset 本动作写入的代理键，绝不删除用户身份（user.name/email）。

action_git_apply() {
  local id="$1" cur key
  : "${PROXY_ENABLED:=true}"
  : "${PROXY_HOST:=}"
  : "${PROXY_PORT:=}"

  if ! cmd_exists git; then
    log_error "[$id] git 不可用；请先安装其依赖 git-cli"
    return 1
  fi

  if [[ -n "${GIT_USER_NAME:-}" ]]; then
    cur=$(git_cfg_get user.name || true)
    if [[ "$cur" != "$GIT_USER_NAME" || "${FORCE:-0}" == 1 ]]; then
      run_step "git config user.name" git config --global user.name "$GIT_USER_NAME" || return 1
    else
      log_info "[$id] user.name 已是预期值，跳过"
    fi
  else
    log_warn "[$id] GIT_USER_NAME 未设置：跳过 git 全局 user.name 配置；请执行："
    log_command 'git config --global user.name "你的姓名"'
  fi

  if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    cur=$(git_cfg_get user.email || true)
    if [[ "$cur" != "$GIT_USER_EMAIL" || "${FORCE:-0}" == 1 ]]; then
      run_step "git config user.email" git config --global user.email "$GIT_USER_EMAIL" || return 1
    else
      log_info "[$id] user.email 已是预期值，跳过"
    fi
  else
    log_warn "[$id] GIT_USER_EMAIL 未设置：跳过 git 全局 user.email 配置；请执行："
    log_command 'git config --global user.email "your-email@example.com"'
  fi

  if [[ "$PROXY_ENABLED" != true ]]; then
    log_info "[$id] 代理未启用，跳过 git 代理配置"
    return 0
  fi

  local rc
  if resolve_proxy_endpoint; then
    [[ -n "$PROXY_SOURCE_IP" ]] && log_info "[$id] 自动使用代理主机 $RESOLVED_PROXY_HOST（来自 $PROXY_SOURCE_IP）"
  else
    rc=$?
    case "$rc" in
      1) log_error "[$id] 无法检测当前 IPv4；请显式设置 PROXY_HOST" ;;
      2) log_error "[$id] PROXY_PORT 必须是 1-65535 的端口号（当前：${PROXY_PORT:-<空>}）" ;;
      3) log_error "[$id] PROXY_HOST 必须是主机名、IP，或带方括号的 IPv6 地址" ;;
      *) log_error "[$id] 无法解析代理地址" ;;
    esac
    return "$rc"
  fi
  ensure_proxy_host_reachable "$RESOLVED_PROXY_HOST" "$RESOLVED_PROXY_PORT" "$PROXY_SOURCE_IP" || return 1

  for key in http.proxy https.proxy; do
    cur=$(git_cfg_get "$key" || true)
    if [[ "$cur" != "$RESOLVED_PROXY_URL" || "${FORCE:-0}" == 1 ]]; then
      run_step "git config $key" git config --global "$key" "$RESOLVED_PROXY_URL" || return 1
    else
      log_info "[$id] $key 已是预期值，跳过"
    fi
  done
  log_ok "[$id] git 配置完成（代理 $RESOLVED_PROXY_URL）"
}

action_git_remove() {
  local id="$1" key cur
  if ! cmd_exists git; then
    log_info "[$id] git 不可用，无需还原代理键"
    return 0
  fi
  for key in http.proxy https.proxy; do
    cur=$(git_cfg_get "$key" || true)
    if [[ -n "$cur" ]]; then
      run_step "git config --unset $key" git config --global --unset "$key" || true
    else
      log_debug "[$id] $key 本就不存在"
    fi
  done
  log_ok "[$id] 已移除 git 代理配置（保留 user.name/user.email）"
}

action_git_verify() {
  local id="$1" key cur rc=0
  if ! cmd_exists git; then
    log_error "[$id] git 不可用"
    return 1
  fi

  : "${PROXY_ENABLED:=true}"
  if [[ "$PROXY_ENABLED" != true ]]; then
    log_ok "[$id] 代理未启用，跳过代理键校验"
    return 0
  fi

  if ! resolve_proxy_endpoint 2>/dev/null; then
    log_warn "[$id] 无法推导代理地址，跳过代理键校验"
    return 0
  fi
  for key in http.proxy https.proxy; do
    cur=$(git_cfg_get "$key" || true)
    if [[ "$cur" == "$RESOLVED_PROXY_URL" ]]; then
      log_debug "[$id] $key=$cur"
    else
      log_error "[$id] $key 不匹配：${cur:-<空>} != $RESOLVED_PROXY_URL"
      rc=1
    fi
  done
  (( rc == 0 )) || return 1
  log_ok "[$id] git 配置校验通过"
}
