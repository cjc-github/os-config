#!/usr/bin/env bash
# =============================================================================
# 模块：sys-base  ——  apt update/upgrade + 基础工具包
# 平台：ubuntu24
# 作用：更新 apt 索引并升级已装系统包，再安装 curl/wget/ca-certificates/gnupg/unzip
#       等基础工具，为后续模块（导入 GPG 密钥、下载安装脚本等）提供前置依赖
# 依赖：无（本模块是基础模块，拓扑排序后最先执行）
# =============================================================================
#
# 【可配置参数】
#   无。本模块只做 apt update/upgrade + 固定基础包安装，不涉及版本号或用户参数。
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   忽略幂等判断，强制再跑一次 apt update/upgrade
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=base）
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

# ---------------------------------------------------------------------------
# 1) 幂等检查：curl/wget/gpg/unzip 全部已装则跳过（--force 强制 apt upgrade）
# ---------------------------------------------------------------------------
if [[ "${FORCE:-0}" != 1 ]]; then
  if cmd_exists curl && cmd_exists wget && cmd_exists gpg && cmd_exists unzip; then
    log_info "基础工具已安装，跳过（用 FORCE=1 ./install.sh 或 ./setup.sh --module base --force 强制 apt upgrade）"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 2) apt update / upgrade
# ---------------------------------------------------------------------------
run_step "apt update"        with_retry 3 5 -- sudo apt-get update
run_step "apt upgrade"       with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

# ---------------------------------------------------------------------------
# 3) 安装基础工具包：curl wget ca-certificates gnupg unzip
# ---------------------------------------------------------------------------
run_step "安装基础工具包"   with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
                                curl wget ca-certificates gnupg unzip

log_ok "base 模块安装完成"
