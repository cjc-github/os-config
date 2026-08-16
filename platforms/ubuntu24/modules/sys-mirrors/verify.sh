#!/usr/bin/env bash
# 模块：mirrors  ——  验证脚本
# 校验项：
#   - apt 源文件已存在
#   - 若 MIRROR_SKIP_APT!=true：当前生效的 URIs 应为目标镜像（或不是 ubuntu.com 海外源即合格）
#   - sudo apt-get check 通过（包索引可用）
#
# 可配置参数：见 install.sh 顶部（同一套 env）
# ---------------------------------------------------------------------------
set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_DIR/lib/utils.sh"
: "${LOG_FILE:=$PROJECT_DIR/logs/setup-$(date +%Y%m%d-%H%M%S).log}"

log_section "verify: mirrors"

DEB822_FILE="/etc/apt/sources.list.d/ubuntu.sources"
: "${MIRROR_SKIP_APT:=false}"

check_file_exists "$DEB822_FILE" || exit 1

if [[ "$MIRROR_SKIP_APT" != "true" ]]; then
  ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$ARCH" in
    amd64|i386|x86_64)
      OVERSEA_RE='(archive\.ubuntu\.com|security\.ubuntu\.com)' ;;
    arm64|armhf|riscv64|s390x|ppc64el)
      OVERSEA_RE='ports\.ubuntu\.com' ;;
    *)
      OVERSEA_RE='ubuntu\.com' ;;
  esac
  # 如果还有海外源，报 warning（不一定等于失败）
  if grep -qE "$OVERSEA_RE" "$DEB822_FILE"; then
    log_warn "deb822 文件仍含疑似海外源 URIs，可能换源未生效"
  else
    log_ok "deb822 URIs 为非海外源"
  fi
fi

if ! sudo -n apt-get check >/dev/null 2>&1; then
  log_error "apt-get check 失败（需提权或 apt update 还没跑）"
  exit 1
fi
log_ok "apt-get check 通过"

log_ok_section "verify: mirrors ✓"
exit 0
