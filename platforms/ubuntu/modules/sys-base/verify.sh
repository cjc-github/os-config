#!/usr/bin/env bash
# =============================================================================
# 模块：sys-base/verify  ——  验证 sys-base 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - curl / wget / ca-certificates / gpg / unzip / ping 六个命令是否可用（打印版本首行）
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

fail=0
for c in curl wget gpg unzip ping; do
  if cmd_exists "$c"; then
    log_ok "  $c: $("$c" --version 2>&1 | head -1)"
  else
    log_error "  $c 未找到"
    fail=1
  fi
done

if dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -qx 'install ok installed'; then
  log_ok "  ca-certificates: 已安装"
else
  log_error "  ca-certificates 未安装"
  fail=1
fi
exit "$fail"
