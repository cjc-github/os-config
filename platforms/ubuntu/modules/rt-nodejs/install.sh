#!/usr/bin/env bash
# =============================================================================
# 模块：rt-nodejs  ——  nvm + node LTS + npm 镜像
# 平台：ubuntu（22.04/24.04）
# 作用：通过 nvm 安装指定版本 nvm + node LTS，并（可选）配置 npm 镜像源
# 依赖：base（sys-base 提供的 curl 等基础工具）
# =============================================================================
#
# 关键说明：本模块安装的 nvm/node 会被 runner 在调用 ai-* 模块前通过
#           runner_activate_node_env() 自动 source nvm + nvm use default 注入 PATH，
#           无需在此修改 ~/.bashrc。
#
# 【可配置参数】（集中在 config/versions.env，修改版本只需改那里一处）
#   NVM_VERSION=v0.40.1                             # nvm 版本
#   NODE_LTS_MAJOR=22                               # Node 主版本
#   NODE_VERSION=                                   # 可选完整版本；非空时优先
#   NPM_REGISTRY=https://registry.npmmirror.com     # npm 镜像；留空则不改 npm config
#
#   实查最新稳定版：
#     curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+'
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   重跑固定版本 nvm installer，并强制安装目标 Node 版本
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=nodejs）
#   $MODULE_DIR   本模块目录绝对路径
#   $LOG_FILE     本次运行的日志文件
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"
setup_traps   # 注册 EXIT/INT/TERM/ERR trap：失败时清理临时文件 + 回滚备份 + 打印失败命令
parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x

# 版本变量（config/versions.env 已通过 setup.sh 注入；未注入则用默认值）
: "${NVM_VERSION:=v0.40.1}"
: "${NODE_LTS_MAJOR:=22}"
: "${NODE_VERSION:=}"
: "${NPM_REGISTRY:=}"
[[ "$NODE_LTS_MAJOR" =~ ^[0-9]+$ ]] || { log_error "NODE_LTS_MAJOR 必须是数字"; exit 2; }
[[ -z "$NODE_VERSION" || "$NODE_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  log_error "NODE_VERSION 必须为空或完整版本号（如 22.18.0）"
  exit 2
}

nvm_dir="$HOME/.nvm"
nvm_script="$nvm_dir/nvm.sh"

# ---------------------------------------------------------------------------
# 1) 安装/更新 nvm（比较版本；FORCE 不删除整个 ~/.nvm，避免丢失已有 Node）
# ---------------------------------------------------------------------------
installed_nvm=""
if [[ -s "$nvm_script" ]]; then
  export NVM_DIR="$nvm_dir"
  # shellcheck disable=SC1091
  . "$nvm_script"
  installed_nvm=$(nvm --version 2>/dev/null || true)
fi
wanted_nvm="${NVM_VERSION#v}"
if [[ "$installed_nvm" == "$wanted_nvm" && "${FORCE:-0}" != 1 ]]; then
  log_info "nvm $installed_nvm 已安装，跳过"
else
  url="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
  nvm_installer=$(mktemp)
  register_tmpfile "$nvm_installer"
  run_step_verbose "下载 nvm $NVM_VERSION 安装脚本" \
    with_retry 3 2 -- curl -fL# -o "$nvm_installer" "$url"
  # 不让 nvm installer 自动编辑 .bashrc/.profile；runner 会显式激活 nvm。
  run_step_verbose "运行 nvm 安装脚本" env PROFILE=/dev/null bash "$nvm_installer"
  rm -f -- "$nvm_installer"
fi

# ---------------------------------------------------------------------------
# 2) 加载 nvm（在当前进程，非交互）
# ---------------------------------------------------------------------------
if [[ ! -s "$nvm_script" ]]; then
  log_error "nvm 安装后 $nvm_script 仍不存在"
  exit 1
fi
export NVM_DIR="$nvm_dir"
# shellcheck disable=SC1091
. "$nvm_script"

# ---------------------------------------------------------------------------
# 3) 装 node LTS（幂等：已装且版本一致则跳过；--force 重装）
# ---------------------------------------------------------------------------
# NODE_VERSION 非空时锁定完整版本；否则安装指定主版本下最新可用版本。
if [[ -n "$NODE_VERSION" ]]; then
  node_wanted="${NODE_VERSION#v}"
else
  node_wanted=$(nvm version-remote "$NODE_LTS_MAJOR" 2>/dev/null | sed -E 's/^v//')
fi
if [[ -z "$node_wanted" || "$node_wanted" == "N/A" ]]; then
  log_error "无法解析目标 Node.js 版本（NODE_VERSION=${NODE_VERSION:-<空>} NODE_LTS_MAJOR=$NODE_LTS_MAJOR）"
  exit 1
fi
log_info "目标 Node.js 版本：$node_wanted"

current=""
if cmd_exists node; then
  current=$(node --version 2>/dev/null | sed -E 's/^v//')
fi

if [[ "$current" == "$node_wanted" && "${FORCE:-0}" != 1 ]]; then
  log_info "node $current 已安装，跳过 nvm install"
else
  run_step_verbose "nvm install $node_wanted" \
    with_retry 3 5 -- nvm install "$node_wanted"
fi

run_step "nvm alias default $node_wanted" nvm alias default "$node_wanted"
nvm use --silent "$node_wanted" >/dev/null

# ---------------------------------------------------------------------------
# 4) npm 提速：镜像 + 关闭冗余请求 + 优先缓存 + 长超时（幂等）
#    作用：
#      registry       → 国内访问速度提升（如 npmmirror）
#      audit false    → 跳过 npm audit 安全数据请求（~1-3 秒 / 次 HTTP）
#      fund false     → 跳过 npm funding 统计（一个小 POST，省几十到几百 ms）
#      prefer-offline → 优先本地缓存，减少网络 round-trip（后续重跑显著加速）
#      fetch-timeout  → 下载包时单次请求长超时（国内网络 30s 不够）
#      fetch-retry-maxtimeout → 重试窗口拉长，配合 with_retry 整体不轻易放弃
# ---------------------------------------------------------------------------
_npm_set_if_different() {
  # 用法：_npm_set_if_different <key> <value> <log_name>
  local k="$1" v="$2" name="${3:-$1}"
  local cur
  cur=$(npm config get "$k" 2>/dev/null || echo "")
  if [[ "$cur" != "$v" || "${FORCE:-0}" = 1 ]]; then
    run_step "npm config set $name" npm config set "$k" "$v"
  else
    log_debug "npm config $name 已是 $v，跳过"
  fi
}

if [[ -n "$NPM_REGISTRY" ]]; then
  _npm_set_if_different registry "$NPM_REGISTRY" "registry $NPM_REGISTRY"
fi
_npm_set_if_different audit "false"
_npm_set_if_different fund "false"
_npm_set_if_different prefer-offline "true"
_npm_set_if_different fetch-timeout "120000" "fetch-timeout 120s"
_npm_set_if_different fetch-retry-maxtimeout "120000" "fetch-retry-maxtimeout 120s"

log_ok "nodejs 模块安装完成：node=$(node --version) npm=$(npm --version)"
