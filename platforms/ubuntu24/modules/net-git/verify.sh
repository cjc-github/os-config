#!/usr/bin/env bash
# =============================================================================
# 模块：net-git/verify  ——  验证 net-git 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - git 命令是否可用（打印 git --version）
#   - git http.proxy / https.proxy 是否等于预期的 http://${PROXY_HOST}:${PROXY_PORT}
#     （仅当 PROXY_PORT 设置时校验）
#
# 【参考变量】（少量；来自 config/user.env）
#   PROXY_HOST=127.0.0.1  PROXY_PORT=7890   # 拼装预期代理 URL
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

: "${PROXY_HOST:=127.0.0.1}"
: "${PROXY_PORT:=7890}"

fail=0
if cmd_exists git; then
  log_ok "git: $(git --version)"
else
  log_error "git 未安装"
  fail=1
fi

# 验证代理（PROXY_PORT 设置时）
if [[ -n "${PROXY_PORT:-}" ]]; then
  expected="http://${PROXY_HOST}:${PROXY_PORT}"
  for key in http.proxy https.proxy; do
    v=$(git_cfg_get "$key" || true)
    if [[ "$v" == "$expected" ]]; then
      log_ok "git $key = $v"
    else
      log_error "git $key = '${v:-<未设置>}' (预期 $expected)"
      fail=1
    fi
  done
fi

exit $fail
