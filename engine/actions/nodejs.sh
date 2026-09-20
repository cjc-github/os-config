#!/usr/bin/env bash
# engine/actions/nodejs.sh —— 通过 nvm 安装 Node LTS 并配置 npm 镜像
# 接口：action_nodejs_apply | action_nodejs_remove | action_nodejs_verify <id>
# 由 engine.sh 的 action_dispatch 惰性 source；不要加 set -e，不要调用 setup_traps。
#
# 依赖 catalog 中的 [curl]；本动作不安装包（nvm 以脚本方式安装在 ~/.nvm）。
#
# 参数（config/versions.env）：
#   NVM_VERSION   默认 v0.40.1
#   NODE_LTS_MAJOR 默认 22
#   NODE_VERSION  可选完整版本；非空时优先
#   NPM_REGISTRY  默认空（留空则不改 registry，仅关闭冗余请求并拉长超时）
#
# remove 语义：~/.nvm 内含用户安装的 Node 与全局包，属用户数据，
#   需显式确认或 FORCE=1 才删除。

_NODEJS_NVM_DIR="$HOME/.nvm"

_nodejs_defaults() {
  : "${NVM_VERSION:=v0.40.1}"
  : "${NODE_LTS_MAJOR:=22}"
  : "${NODE_VERSION:=}"
  : "${NPM_REGISTRY:=}"
  [[ "$NODE_LTS_MAJOR" =~ ^[0-9]+$ ]] || { log_error "NODE_LTS_MAJOR 必须是数字"; return 2; }
  [[ -z "$NODE_VERSION" || "$NODE_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    log_error "NODE_VERSION 必须为空或完整版本号（如 22.18.0）"; return 2
  }
}

_nodejs_activate() {
  export NVM_DIR="$_NODEJS_NVM_DIR"
  [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
}

# npm config 幂等写入
_nodejs_npm_set_if_different() {
  local k="$1" v="$2" name="${3:-$1}" cur
  cur=$(npm config get "$k" 2>/dev/null || echo "")
  if [[ "$cur" != "$v" || "${FORCE:-0}" == 1 ]]; then
    run_step "npm config set $name" npm config set "$k" "$v"
  else
    log_debug "npm config $name 已是 $v，跳过"
  fi
}

action_nodejs_apply() {
  local id="$1" nvm_script installed_nvm wanted_nvm url installer node_wanted current
  _nodejs_defaults || return $?
  nvm_script="$_NODEJS_NVM_DIR/nvm.sh"

  # --- 1) 安装/更新 nvm（不删除整个 ~/.nvm，避免丢失已有 Node）---
  installed_nvm=""
  if [[ -s "$nvm_script" ]]; then
    _nodejs_activate >/dev/null 2>&1 || true
    installed_nvm=$(nvm --version 2>/dev/null || true)
  fi
  wanted_nvm="${NVM_VERSION#v}"
  if [[ "$installed_nvm" == "$wanted_nvm" && "${FORCE:-0}" != 1 ]]; then
    log_info "[$id] nvm $installed_nvm 已安装，跳过"
  else
    url="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
    installer="$(mktemp)"; register_tmpfile "$installer"
    run_step_verbose "下载 nvm $NVM_VERSION 安装脚本" \
      with_retry 3 2 -- curl -fL# -o "$installer" "$url" || return 1
    # 不让 nvm installer 自动编辑 .bashrc/.profile
    run_step_verbose "运行 nvm 安装脚本" env PROFILE=/dev/null bash "$installer" || return 1
    rm -f -- "$installer"
  fi

  # --- 2) 激活 nvm ---
  if [[ ! -s "$nvm_script" ]]; then
    log_error "[$id] nvm 安装后 $nvm_script 仍不存在"
    return 1
  fi
  _nodejs_activate || return 1

  # --- 3) 安装目标 Node ---
  if [[ -n "$NODE_VERSION" ]]; then
    node_wanted="${NODE_VERSION#v}"
  else
    node_wanted=$(nvm version-remote "$NODE_LTS_MAJOR" 2>/dev/null | sed -E 's/^v//')
  fi
  if [[ -z "$node_wanted" || "$node_wanted" == "N/A" ]]; then
    log_error "[$id] 无法解析目标 Node.js 版本（NODE_VERSION=${NODE_VERSION:-<空>} NODE_LTS_MAJOR=$NODE_LTS_MAJOR）"
    return 1
  fi
  log_info "[$id] 目标 Node.js 版本：$node_wanted"

  current=""
  cmd_exists node && current=$(node --version 2>/dev/null | sed -E 's/^v//')
  if [[ "$current" == "$node_wanted" && "${FORCE:-0}" != 1 ]]; then
    log_info "[$id] node $current 已安装，跳过 nvm install"
  else
    run_step_verbose "nvm install $node_wanted" \
      with_retry 3 5 -- nvm install "$node_wanted" || return 1
  fi

  run_step "nvm alias default $node_wanted" nvm alias default "$node_wanted" || return 1
  nvm use --silent "$node_wanted" >/dev/null 2>&1 || true

  # --- 4) npm 提速配置 ---
  [[ -z "$NPM_REGISTRY" ]] || _nodejs_npm_set_if_different registry "$NPM_REGISTRY" "registry $NPM_REGISTRY"
  _nodejs_npm_set_if_different audit "false"
  _nodejs_npm_set_if_different fund "false"
  _nodejs_npm_set_if_different prefer-offline "true"
  _nodejs_npm_set_if_different fetch-timeout "120000" "fetch-timeout 120s"
  _nodejs_npm_set_if_different fetch-retry-maxtimeout "120000" "fetch-retry-maxtimeout 120s"

  log_ok "[$id] nodejs 完成：node=$(node --version) npm=$(npm --version)"
}

action_nodejs_remove() {
  local id="$1"
  if [[ ! -d "$_NODEJS_NVM_DIR" ]]; then
    log_info "[$id] $_NODEJS_NVM_DIR 不存在，无需删除"
    return 0
  fi
  if [[ "${FORCE:-0}" != 1 ]]; then
    if ! confirm "[$id] 删除 $_NODEJS_NVM_DIR 会一并删除其中的 Node 与全局包，确认？"; then
      log_warn "[$id] 已取消；如需强制删除请加 --force"
      return 0
    fi
  fi
  run_step "删除 $_NODEJS_NVM_DIR" rm -rf -- "$_NODEJS_NVM_DIR" || return 1
  log_ok "[$id] 已移除 nvm/Node（$_NODEJS_NVM_DIR）"
}

action_nodejs_verify() {
  local id="$1" actual_node actual_plain rc=0
  _nodejs_defaults || return $?
  activate_nvm_default || true

  : "${NODE_LTS_MAJOR:=22}"
  : "${NODE_VERSION:=}"

  if cmd_exists node; then
    actual_node="$(node --version)"
    log_ok "[$id] node: $actual_node"
    actual_plain="${actual_node#v}"
    if [[ -n "$NODE_VERSION" && "$actual_plain" != "${NODE_VERSION#v}" ]]; then
      log_error "[$id] Node.js 版本 $actual_plain 与锁定版本 ${NODE_VERSION#v} 不一致"
      rc=1
    elif [[ -z "$NODE_VERSION" && "${actual_plain%%.*}" != "$NODE_LTS_MAJOR" ]]; then
      log_error "[$id] Node.js 主版本 ${actual_plain%%.*} 与 NODE_LTS_MAJOR=$NODE_LTS_MAJOR 不一致"
      rc=1
    fi
  else
    log_error "[$id] node 不可用"
    rc=1
  fi

  if cmd_exists npm; then
    log_ok "[$id] npm: $(npm --version)"
  else
    log_error "[$id] npm 不可用"
    rc=1
  fi
  (( rc == 0 )) || return 1
}
