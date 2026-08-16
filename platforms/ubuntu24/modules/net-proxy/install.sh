#!/usr/bin/env bash
# =============================================================================
# 模块：net-proxy  ——  shell 环境变量代理写入 ~/.bashrc（幂等）
# 平台：ubuntu24
# 作用：把 HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy/NO_PROXY/no_proxy 持久化
#       写入 ~/.bashrc 的 os-config 标记块；本模块不安装任何代理软件
# 依赖：base（sys-base 提供的基础工具；本模块 NEEDS_SUDO=0）
# =============================================================================
#
# 【可配置参数】（来自 config/user.env，复制 user.env.example 修改）
#   PROXY_HOST=127.0.0.1                  # 代理主机
#   PROXY_PORT=7890                        # 代理端口；留空则跳过整个 proxy 模块
#   NO_PROXY=localhost,127.0.0.1,::1       # 不走代理的主机列表
#
#   说明：本模块无版本号参数；仅做 shell 环境变量持久化，不安装代理软件。
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   已存在 os-config proxy 块时删除旧块并重写
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=proxy）
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

# 用户参数默认值（user.env 未注入时兜底）
: "${PROXY_HOST:=127.0.0.1}"
: "${PROXY_PORT:=7890}"
: "${NO_PROXY:=localhost,127.0.0.1,::1}"

# ---------------------------------------------------------------------------
# 1) 前置检查：没设置端口 → 跳过
# ---------------------------------------------------------------------------
if [[ -z "${PROXY_PORT:-}" ]]; then
  log_warn "PROXY_PORT 未设置，跳过 proxy 模块"
  exit 0
fi

proxy_url="http://${PROXY_HOST}:${PROXY_PORT}"
bashrc="$HOME/.bashrc"

# ---------------------------------------------------------------------------
# 2) 备份 ~/.bashrc
# ---------------------------------------------------------------------------
backup_file "$bashrc"

# ---------------------------------------------------------------------------
# 3) 幂等：搜 BEGIN/END os-config proxy 标记块；已存在则跳过（--force 重写）
# ---------------------------------------------------------------------------
marker_begin="# >>> os-config proxy begin >>>"
marker_end="# <<< os-config proxy end <<<"

if file_contains "$bashrc" "$marker_begin"; then
  if [[ "${FORCE:-0}" = 1 ]]; then
    log_info "已存在 os-config proxy 块，FORCE=1 重写"
    # 用 sed 删除旧块（BEGIN 到 END）
    sed -i -E "/$marker_begin/,/$marker_end/d" "$bashrc"
  else
    log_info "~/.bashrc 已含 os-config proxy 块，跳过（用 FORCE=1 ./install.sh 或 ./setup.sh --module proxy --force 重写）"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 4) 追加 os-config proxy 标记块（HTTP_PROXY/HTTPS_PROXY/NO_PROXY 等）
# ---------------------------------------------------------------------------
cat >>"$bashrc" <<EOF

$marker_begin
export HTTP_PROXY="$proxy_url"
export HTTPS_PROXY="$proxy_url"
export http_proxy="$proxy_url"
export https_proxy="$proxy_url"
export NO_PROXY="$NO_PROXY"
export no_proxy="$NO_PROXY"
$marker_end
EOF
log_ok "已写入 proxy 块到 $bashrc"
log_warn "新 shell 才会生效；当前会话可手动 source：source ~/.bashrc"
