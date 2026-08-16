#!/usr/bin/env bash
# =============================================================================
# 模块：net-ssh  ——  openssh + 非交互生成密钥
# 平台：ubuntu24
# 作用：apt 安装 openssh-client/openssh-server，并在 ~/.ssh 下非交互生成密钥对
# 依赖：base（sys-base 提供的 apt 等基础工具）
# =============================================================================
#
# 【可配置参数】（来自 config/user.env，复制 user.env.example 修改）
#   SSH_KEY_TYPE=ed25519      # 密钥类型：ed25519 | rsa（留空默认 ed25519）
#   SSH_KEY_PASSPHRASE=       # 密钥 passphrase；留空 = 无 passphrase（非交互）
#
#   说明：本模块无版本号参数（apt 装 openssh 跟随发行版版本）。
#
# 【行为标志】（由 setup.sh / runner.sh 注入）
#   $FORCE=1   本模块未直接读取；密钥已存在即跳过（需重生成请先删除旧密钥）
#   $DEBUG=1   打开调试日志
#
# 【注入变量】
#   $MODULE_NAME  本模块 NAME（=ssh）
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
: "${SSH_KEY_TYPE:=ed25519}"      # ed25519 | rsa
: "${SSH_KEY_PASSPHRASE:=}"        # 留空 = 无 passphrase

# ---------------------------------------------------------------------------
# 1) 安装 openssh（幂等：已装则跳过 apt install）
# ---------------------------------------------------------------------------
if ! cmd_exists ssh; then
  run_step "apt install openssh-client openssh-server" \
    with_retry 3 5 -- sudo DEBIAN_FRONTEND=noninteractive apt-get -y install openssh-client openssh-server
else
  log_info "openssh 已安装，跳过 apt install"
fi

# ---------------------------------------------------------------------------
# 2) ~/.ssh 目录（权限 700）
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# ---------------------------------------------------------------------------
# 3) 非交互生成密钥（幂等：已存在则跳过）
# ---------------------------------------------------------------------------
keyfile="$HOME/.ssh/id_${SSH_KEY_TYPE}"
if [[ -f "$keyfile" ]]; then
  log_info "密钥已存在，跳过：$keyfile"
else
  case "$SSH_KEY_TYPE" in
    ed25519)
      run_step "ssh-keygen ed25519" \
        ssh-keygen -t ed25519 -N "$SSH_KEY_PASSPHRASE" -C "$USER@$(hostname) $(date +%Y%m%d)" -f "$keyfile"
      ;;
    rsa)
      run_step "ssh-keygen rsa 4096" \
        ssh-keygen -t rsa -b 4096 -N "$SSH_KEY_PASSPHRASE" -C "$USER@$(hostname) $(date +%Y%m%d)" -f "$keyfile"
      ;;
    *)
      log_error "不支持的 SSH_KEY_TYPE=$SSH_KEY_TYPE"
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 4) 确保私钥权限（600 私钥 / 644 公钥）
# ---------------------------------------------------------------------------
chmod 600 "$keyfile" 2>/dev/null || true
[[ -f "${keyfile}.pub" ]] && chmod 644 "${keyfile}.pub" 2>/dev/null || true

log_ok "ssh 模块安装完成"
