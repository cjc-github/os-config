#!/usr/bin/env bash
# =============================================================================
# 模块：rt-nodejs/verify  ——  验证 rt-nodejs 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - node 命令是否可用（打印 node --version）
#   - npm 命令是否可用（打印 npm --version）
#
#   说明：verify 可被单独调用，故在此显式激活 nvm（source ~/.nvm/nvm.sh + nvm use default）。
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

# 必须显式激活 nvm（verify 可被单独调用）
export NVM_DIR="$HOME/.nvm"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm use --silent default >/dev/null 2>&1 || true
fi

fail=0
: "${NODE_LTS_MAJOR:=22}"
: "${NODE_VERSION:=}"
if cmd_exists node; then
  actual_node="$(node --version)"
  log_ok "node: $actual_node"
  actual_plain="${actual_node#v}"
  if [[ -n "$NODE_VERSION" && "$actual_plain" != "${NODE_VERSION#v}" ]]; then
    log_error "Node.js 版本 $actual_plain 与锁定版本 ${NODE_VERSION#v} 不一致"
    fail=1
  elif [[ -z "$NODE_VERSION" && "${actual_plain%%.*}" != "$NODE_LTS_MAJOR" ]]; then
    log_error "Node.js 主版本 ${actual_plain%%.*} 与 NODE_LTS_MAJOR=$NODE_LTS_MAJOR 不一致"
    fail=1
  fi
else
  log_error "node 不可用"
  fail=1
fi
if cmd_exists npm; then
  log_ok "npm: $(npm --version)"
else
  log_error "npm 不可用"
  fail=1
fi
exit "$fail"
