#!/usr/bin/env bash
# =============================================================================
# 模块：sys-base/verify —— 验证配置中选中的基础工具
# =============================================================================
set -euo pipefail

: "${MODULE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${PROJECT_DIR:=$(cd "$MODULE_DIR/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"
# shellcheck source=packages.sh
. "$MODULE_DIR/packages.sh"

parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x

BASE_TOOLS_CONFIG="$(base_resolve_path "${BASE_TOOLS_CONFIG:-config/base-tools.conf}")"
BASE_TOOLS_CATALOG="$(base_resolve_path "${BASE_TOOLS_CATALOG:-${MODULE_DIR#$PROJECT_DIR/}/packages.catalog}")"
base_load_selection "$BASE_TOOLS_CONFIG" "$BASE_TOOLS_CATALOG"

log_section "[base] 验证基础工具"
if (( ${#BASE_SELECTED_TOOLS[@]} == 0 )); then
  log_warn "配置未选择任何基础工具：没有需要验证的项目"
  exit 0
fi

fail=0
for id in "${BASE_SELECTED_TOOLS[@]}"; do
  tool="${BASE_TOOL_NAME[$id]}"
  category="${BASE_TOOL_CATEGORY[$id]}"
  tool_failed=0

  for package in ${BASE_TOOL_PACKAGES[$id]}; do
    if ! base_package_installed "$package"; then
      log_error "[${BASE_CATEGORY_DESC[$category]}/$tool] APT 软件包未安装：$package"
      tool_failed=1
    fi
  done

  for command_name in ${BASE_TOOL_COMMANDS[$id]}; do
    if ! cmd_exists "$command_name"; then
      log_error "[${BASE_CATEGORY_DESC[$category]}/$tool] 命令不可用：$command_name"
      tool_failed=1
    fi
  done

  if (( tool_failed == 0 )); then
    log_ok "[${BASE_CATEGORY_DESC[$category]}/$tool] ${BASE_TOOL_DESC[$id]}"
  else
    fail=1
  fi
done

exit "$fail"
