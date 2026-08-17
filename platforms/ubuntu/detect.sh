#!/usr/bin/env bash
# platforms/ubuntu/detect.sh —— Ubuntu 操作系统族自检脚本
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
if [[ ! -r "$OS_RELEASE_FILE" ]]; then
  log_error "$OS_RELEASE_FILE 不可读"
  exit 1
fi

ID=''
VERSION_ID=''
# shellcheck disable=SC1090
. "$OS_RELEASE_FILE"

case "${ID,,}/${VERSION_ID:-}" in
  ubuntu/22.04|ubuntu/24.04)
    log_ok "ubuntu 平台检测通过 (ID=$ID VERSION_ID=$VERSION_ID)"
    exit 0
    ;;
  *)
    log_error "NOT supported ubuntu (ID=${ID:-<未知>} VERSION_ID=${VERSION_ID:-<未知>})"
    exit 1
    ;;
esac
