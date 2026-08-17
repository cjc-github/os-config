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
PROJECT_DIR="$(cd "$MODULE_DIR/../../../.." && pwd)"
# shellcheck source=../../../../lib/utils.sh
source "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
source "$PROJECT_DIR/lib/log.sh"

log_section "verify: mirrors"

DEB822_FILE="/etc/apt/sources.list.d/ubuntu.sources"
LEGACY_FILE="/etc/apt/sources.list"
: "${MIRROR_SKIP_APT:=false}"

source_files=()
[[ -f "$DEB822_FILE" ]] && source_files+=("$DEB822_FILE")
[[ -f "$LEGACY_FILE" ]] && source_files+=("$LEGACY_FILE")
if [[ ${#source_files[@]} -eq 0 ]]; then
  log_error "未找到 APT 源文件：$DEB822_FILE 或 $LEGACY_FILE"
  exit 1
fi

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
  overseas_found=0
  for source_file in "${source_files[@]}"; do
    if grep -qE "$OVERSEA_RE" "$source_file"; then
      log_error "$source_file 仍含海外 Ubuntu 源，换源未生效"
      overseas_found=1
    else
      log_ok "$source_file 未发现海外 Ubuntu 源"
    fi
  done
  (( overseas_found == 0 )) || exit 1
fi

if ! sudo -n apt-get check >/dev/null 2>&1; then
  log_error "apt-get check 失败（需提权或 apt update 还没跑）"
  exit 1
fi
log_ok "apt-get check 通过"

log_ok "verify: mirrors ✓"
exit 0
