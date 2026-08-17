#!/usr/bin/env bash
# 模块：mirrors  ——  国内镜像源一键切换
# 平台：ubuntu（22.04/24.04）
# 作用：
#   1) 识别实际生效的 apt 源文件：
#        - Ubuntu 24.04 通常使用 deb822 格式 /etc/apt/sources.list.d/ubuntu.sources
#        - 若仍有旧 sources.list（兼容场景）也替换
#        - 并区分 x86_64 → archive.ubuntu.com vs arm64 → ports.ubuntu.com/ubuntu-ports
#   2) 替换为清华源（TUNA），可通过 MIRROR_APT_URL / MIRROR_APT_PORTS_URL 覆盖
#   3) 切换后执行 sudo apt update（成功才算通过）
# 依赖：DEPS=（系统最先跑的模块之一）
#
# 【可配置参数】（集中在 config/user.env）
#   MIRROR_COUNTRY=cn          # 预留，未来扩展
#   MIRROR_APT_URL=            # 覆盖 amd64/i386 镜像；默认 https://mirrors.tuna.tsinghua.edu.cn/ubuntu
#   MIRROR_APT_PORTS_URL=      # 覆盖 arm64/armhf 等 ports 镜像；默认 https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
#   MIRROR_SKIP_APT=false      # true 则不换 apt 源（只验证当前 apt update 可用）
#   MIRROR_SKIP_APT_UPDATE=false  # true 则不执行 apt update（离线/空气环境场景）
#
# 【行为标志】
#   $FORCE=1   强制重写 apt 源文件，即使当前 URIs 已经是镜像
#   $DEBUG=1   set -x 调试
#
# 【注入变量】
#   $MODULE_NAME=mirrors   $MODULE_DIR=.../sys-mirrors   $LOG_FILE=...
#
# 【异常处理接入】
#   setup_traps       清理临时文件 + ERR 打印命令行号
#   wait_for_apt_lock apt 锁等待 60s
#   register_rollback 备份 apt 源文件，失败自动回滚
#   with_retry        apt update 重试 2 次（防止瞬间网络抖动）
# ---------------------------------------------------------------------------
set -euo pipefail
MODULE_NAME=mirrors
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$MODULE_DIR/../../../.." && pwd)"
# shellcheck source=../../../../lib/utils.sh
source "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
source "$PROJECT_DIR/lib/log.sh"
setup_traps
parse_install_args "$@"
[[ "${DEBUG:-0}" == "1" ]] && set -x

log_section "[$MODULE_NAME] 配置国内镜像源"

# ---------------------------------------------------------------------------
# 0) 默认值：清华源
# ---------------------------------------------------------------------------
: "${MIRROR_APT_URL:=https://mirrors.tuna.tsinghua.edu.cn/ubuntu}"
: "${MIRROR_APT_PORTS_URL:=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"
: "${MIRROR_SKIP_APT:=false}"
: "${MIRROR_SKIP_APT_UPDATE:=false}"

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
  amd64|i386|x86_64) APT_MIRROR="$MIRROR_APT_URL"    APT_ORIGIN_RE='(archive\.ubuntu\.com|security\.ubuntu\.com)/ubuntu/?' ;;
  arm64|armhf|riscv64|s390x|ppc64el) APT_MIRROR="$MIRROR_APT_PORTS_URL" APT_ORIGIN_RE='ports\.ubuntu\.com/ubuntu-ports/?' ;;
  *) log_warn "未知架构 $ARCH，按 amd64 默认处理"; APT_MIRROR="$MIRROR_APT_URL"; APT_ORIGIN_RE='archive\.ubuntu\.com/ubuntu/?' ;;
esac
log_info "当前架构=$ARCH  目标 APT 镜像=$APT_MIRROR"

# ---------------------------------------------------------------------------
# 1) 定位 apt 实际生效源文件
#    Ubuntu 24.04：/etc/apt/sources.list.d/ubuntu.sources（deb822 格式 URIs: ...）
#    兼容：若系统有 /etc/apt/sources.list（非迁移提示空文件），也走
# ---------------------------------------------------------------------------
DEB822_FILE="/etc/apt/sources.list.d/ubuntu.sources"
LEGACY_FILE="/etc/apt/sources.list"

changed=0
_apt_files=()

if [[ -f "$DEB822_FILE" ]]; then
  # deb822：URIs: http://archive.ubuntu.com/ubuntu 是关键字段
  if grep -qE "URIs:.*$APT_ORIGIN_RE" "$DEB822_FILE"; then
    log_info "需要替换 deb822 源文件：$DEB822_FILE"
    _apt_files+=("$DEB822_FILE")
  elif [[ "${FORCE:-0}" == "1" ]]; then
    log_info "FORCE=1：强制重写 $DEB822_FILE"
    _apt_files+=("$DEB822_FILE")
  else
    log_ok "deb822 源已是镜像或非海外源，跳过：$DEB822_FILE"
  fi
fi

if [[ -f "$LEGACY_FILE" ]] && grep -qE "$APT_ORIGIN_RE" "$LEGACY_FILE"; then
  log_info "需要替换 legacy sources.list：$LEGACY_FILE"
  _apt_files+=("$LEGACY_FILE")
fi

# ---------------------------------------------------------------------------
# 2) 若 MIRROR_SKIP_APT=true：不重写源；跳到 apt update 验证
# ---------------------------------------------------------------------------
if [[ "$MIRROR_SKIP_APT" == "true" ]]; then
  log_warn "MIRROR_SKIP_APT=true：跳过 apt 源重写，直接 apt update 验证"
  _apt_files=()
fi

# ---------------------------------------------------------------------------
# 3) 幂等 & 重写：备份 + sed + 回滚注册
# ---------------------------------------------------------------------------
if [[ ${#_apt_files[@]} -gt 0 ]]; then
  for f in "${_apt_files[@]}"; do
    run_step "备份：$f" register_rollback "$f" sudo
    tmp=$(mktemp)
    register_tmpfile "$tmp"
    # URIs: https://archive.ubuntu.com/ubuntu   ->  URIs: https://mirrors.tuna.tsinghua.edu.cn/ubuntu
    # 同时支持 URIs: 同行多空格、以及 security.ubuntu.com
    run_step "写入新的 $f（架构=$ARCH）" \
      sudo sed -E -e "s|(URIs:\s+)(https?://[^/]+/ubuntu[^ ]*)|\1${APT_MIRROR}|g" \
                  -e "s|(deb(-src)?\s+)(https?://[^ ]+ubuntu[^ ]*)|\1${APT_MIRROR}|g" \
                  "$f" > "$tmp"
    run_step "覆盖 $f（sudo 权限）" sudo cp "$tmp" "$f"
    log_ok "已更新：$f → $APT_MIRROR"
    changed=1
  done
else
  log_ok "APT 源无需更改"
fi

# ---------------------------------------------------------------------------
# 4) apt update（用 wait_for_apt_lock + with_retry）
# ---------------------------------------------------------------------------
if [[ "$MIRROR_SKIP_APT_UPDATE" != "true" ]]; then
  wait_for_apt_lock
  run_step "apt update 验证（换源后刷新包索引）" \
    with_retry 2 10 -- sudo apt-get update
  log_ok "apt update 通过 ✓"
fi

log_ok "[$MODULE_NAME] 完成（apt changed=$changed）"
exit 0
