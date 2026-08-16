#!/usr/bin/env bash
# platforms/ubuntu24/detect.sh —— 平台自检脚本
# runner 可调用做双保险。直接运行也能跑。
# 由于是被 setup.sh 通过 `bash detect.sh` 启动的子进程，需要自己 source lib。
set -euo pipefail

# 推断 PROJECT_DIR 并加载共享库（独立运行也能用 log_*）
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

if [[ ! -r /etc/os-release ]]; then
  log_error "/etc/os-release 不可读"
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release

if [[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]]; then
  log_ok "ubuntu24 平台检测通过 (ID=$ID VERSION_ID=$VERSION_ID)"
  exit 0
fi

log_error "NOT ubuntu24 (ID=$ID VERSION_ID=$VERSION_ID)"
exit 1
