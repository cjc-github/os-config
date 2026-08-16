#!/usr/bin/env bash
# =============================================================================
# 模块：rt-nodejs  ——  nvm + node LTS + npm 镜像
# 平台：ubuntu24
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
#   NODE_LTS_MAJOR=22                               # node LTS 主版本（满足 claude≥20 / codex≥18 / opencode≥18 的最低要求）
#   NPM_REGISTRY=https://registry.npmmirror.com     # npm 镜像；留空则不改 npm config
#
#   实查最新稳定版：
#     curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+'
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   删除 ~/.nvm 重装 nvm；强制 nvm install --lts
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

# 版本变量（config/versions.env 已通过 setup.sh 注入；未注入则用默认值）
: "${NVM_VERSION:=v0.40.1}"
: "${NODE_LTS_MAJOR:=22}"
: "${NPM_REGISTRY:=}"

nvm_dir="$HOME/.nvm"
nvm_script="$nvm_dir/nvm.sh"

# ---------------------------------------------------------------------------
# 1) 安装 nvm（幂等：nvm.sh 存在则跳过；--force 重装先删）
# ---------------------------------------------------------------------------
if [[ -s "$nvm_script" && "${FORCE:-0}" != 1 ]]; then
  log_info "nvm 已安装，跳过"
else
  if [[ "${FORCE:-0}" = 1 && -d "$nvm_dir" ]]; then
    log_warn "FORCE=1 重装：删除 $nvm_dir"
    rm -rf "$nvm_dir"
  fi
  url="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
  register_tmpfile /tmp/nvm-install.sh
  # curl 加 -# 显示进度条（替代默认 -s 静默）；用 run_step_verbose 把进度落盘到 LOG_FILE
  run_step_verbose "下载 nvm $NVM_VERSION 安装脚本" \
    with_retry 3 2 -- curl -fL# -o /tmp/nvm-install.sh "$url"
  # nvm 安装脚本输出较啰嗦但有用（git clone + nvm.sh + bash_completion 等），用 verbose 落盘
  run_step_verbose "运行 nvm 安装脚本" \
    bash /tmp/nvm-install.sh
  rm -f /tmp/nvm-install.sh
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
# 找当前可用 LTS（取最近一个）
node_wanted=$(nvm version-remote --lts 2>/dev/null | sed -E 's/^v//')
if [[ -z "$node_wanted" ]]; then
  # 退化：用 NODE_LTS_MAJOR 拼
  node_wanted="${NODE_LTS_MAJOR}.$(curl -fsSL "https://nodejs.org/dist/index.json" \
                2>/dev/null | grep -oE "\"version\": \"v${NODE_LTS_MAJOR}\.[0-9.]+\"" \
                | head -1 | grep -oE "${NODE_LTS_MAJOR}\.[0-9.]+" | head -1)"
fi
log_debug "目标 node LTS 版本：$node_wanted"

current=""
if cmd_exists node; then
  current=$(node --version 2>/dev/null | sed -E 's/^v//')
fi

if [[ -n "$current" && "$current" == "$node_wanted" && "${FORCE:-0}" != 1 ]]; then
  log_info "node $current 已安装，跳过 nvm install"
else
  # nvm install 下载 node 二进制 + 解压，耗时较长；用 verbose 把进度同时落盘到 LOG_FILE
  run_step_verbose "nvm install --lts" nvm install --lts
fi

# 设为默认（幂等）
run_step "nvm alias default node" nvm alias default node

# 当前 shell 用上 default（让后续步骤能用 node/npm）
nvm use --silent default >/dev/null 2>&1 || true

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
