#!/usr/bin/env bash
# =============================================================================
# 模块：sys-base  ——  apt update + 可选 upgrade + 基础工具包
# 平台：ubuntu（22.04/24.04）
# 作用：更新 apt 索引，按配置可选升级已装系统包，再安装 curl/wget/ca-certificates/gnupg/unzip/iputils-ping
#       等基础工具，为后续模块（导入 GPG 密钥、下载安装脚本等）提供前置依赖
# 依赖：无（本模块是基础模块，拓扑排序后最先执行）
# =============================================================================
#
# 【可配置参数】
#   APT_UPGRADE=false  # true 时额外升级系统中已安装的软件包。
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   apt 操作本身幂等；保留该通用参数供统一调用
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
parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x
wait_for_apt_lock
: "${APT_UPGRADE:=false}"

# apt 本身具备幂等性：始终确保索引可用和目标包已安装，不再用命令存在性整体短路。
run_step "apt update" with_retry 3 5 -- sudo apt-get update

if [[ "$APT_UPGRADE" == "true" ]]; then
  run_step "apt upgrade" with_retry 3 5 -- \
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
else
  log_info "APT_UPGRADE=false：跳过系统全量升级"
fi

run_step "安装基础工具包" with_retry 3 5 -- \
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
    curl wget ca-certificates gnupg unzip iputils-ping

log_ok "base 模块安装完成"
