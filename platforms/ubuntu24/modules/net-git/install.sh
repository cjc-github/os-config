#!/usr/bin/env bash
# =============================================================================
# 模块：net-git  ——  安装 git + 配置 user.name/email + 配置 git http/https 代理
# 平台：ubuntu24
# 作用：apt 安装 git，并写入全局 user.name/user.email 与 http.proxy/https.proxy
# 依赖：base（sys-base 提供的 apt/curl 等基础工具）
# =============================================================================
#
# 【可配置参数】（来自 config/user.env，复制 user.env.example 修改）
#   GIT_USER_NAME=          # git 全局 user.name；留空则跳过该项配置
#   GIT_USER_EMAIL=         # git 全局 user.email；留空则跳过该项配置
#   PROXY_HOST=127.0.0.1    # 代理主机（与 net-proxy 共用）
#   PROXY_PORT=7890         # 代理端口；留空则跳过 git 代理配置
#
#   说明：本模块无版本号参数（apt 装 git 跟随发行版版本）。
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   忽略幂等判断，强制重写 user.name/user.email/proxy 配置
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=git）
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
wait_for_apt_lock || log_warn "apt 锁检测失败（可能无 sudo），继续尝试"

# 用户参数默认值（user.env 未注入时兜底）
: "${PROXY_HOST:=127.0.0.1}"
: "${PROXY_PORT:=7890}"

# ---------------------------------------------------------------------------
# 1) 安装 git（幂等：已装则跳过 apt install）
# ---------------------------------------------------------------------------
if ! cmd_exists git; then
  run_step "apt install git" with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y install git
else
  log_info "git 已安装，跳过 apt install（FORCE=1 ./install.sh 可重设 git 配置；要重装 git 需先 apt remove）"
fi

# ---------------------------------------------------------------------------
# 2) 配置 user.name / user.email（用户未提供则跳过；幂等：值相同不重写）
# ---------------------------------------------------------------------------
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  cur=$(git_cfg_get user.name || true)
  if [[ "$cur" != "$GIT_USER_NAME" || "${FORCE:-0}" = 1 ]]; then
    run_step "git config user.name" git config --global user.name "$GIT_USER_NAME"
  else
    log_info "user.name 已是预期值，跳过"
  fi
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  cur=$(git_cfg_get user.email || true)
  if [[ "$cur" != "$GIT_USER_EMAIL" || "${FORCE:-0}" = 1 ]]; then
    run_step "git config user.email" git config --global user.email "$GIT_USER_EMAIL"
  else
    log_info "user.email 已是预期值，跳过"
  fi
fi

# ---------------------------------------------------------------------------
# 3) 配置 git http/https 代理（PROXY_PORT 为空则跳过；幂等：值相同不重写）
# ---------------------------------------------------------------------------
if [[ -n "${PROXY_PORT:-}" ]]; then
  proxy_url="http://${PROXY_HOST}:${PROXY_PORT}"
  for key in http.proxy https.proxy; do
    cur=$(git_cfg_get "$key" || true)
    if [[ "$cur" != "$proxy_url" || "${FORCE:-0}" = 1 ]]; then
      run_step "git config $key" git config --global "$key" "$proxy_url"
    else
      log_info "$key 已是预期值，跳过"
    fi
  done
else
  log_warn "PROXY_PORT 未设置，跳过 git 代理配置"
fi

log_ok "git 模块安装完成"
