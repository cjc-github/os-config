#!/usr/bin/env bash
# =============================================================================
# 模块：sys-base —— 配置驱动的 Ubuntu 基础工具安装
# 平台：ubuntu（22.04/24.04）
#
# 软件选择：config/base-tools.conf
# 软件映射：packages.catalog
# 执行流程：读取二维配置 -> 汇总/去重 APT 软件包 -> 检测已安装状态 -> 安装 -> verify
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

setup_traps
parse_install_args "$@"
[[ "${DEBUG:-0}" == 1 ]] && set -x

: "${APT_UPGRADE:=false}"
BASE_TOOLS_CONFIG="$(base_resolve_path "${BASE_TOOLS_CONFIG:-config/base-tools.conf}")"
BASE_TOOLS_CATALOG="$(base_resolve_path "${BASE_TOOLS_CATALOG:-${MODULE_DIR#$PROJECT_DIR/}/packages.catalog}")"

log_section "[base] 基础工具选择"
log_info "选择配置：$BASE_TOOLS_CONFIG"
log_debug "软件目录：$BASE_TOOLS_CATALOG"
base_load_selection "$BASE_TOOLS_CONFIG" "$BASE_TOOLS_CATALOG"
base_log_selection

wait_for_apt_lock
run_step "apt update" with_retry 3 5 -- sudo apt-get update

if [[ "$APT_UPGRADE" == true ]]; then
  run_step "apt upgrade" with_retry 3 5 -- \
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
else
  log_info "APT_UPGRADE=false：跳过系统全量升级"
fi

if (( ${#BASE_SELECTED_PACKAGES[@]} == 0 )); then
  log_warn "配置未选择任何基础工具：跳过 apt install"
  log_ok "base 模块完成"
  exit 0
fi

installed_count=0
missing_count=0
declare -a packages_to_install=()
for package in "${BASE_SELECTED_PACKAGES[@]}"; do
  if base_package_installed "$package"; then
    installed_count=$((installed_count + 1))
    log_info "[已安装] $package"
    if [[ "${FORCE:-0}" == 1 ]]; then
      packages_to_install+=("$package")
    fi
  else
    missing_count=$((missing_count + 1))
    log_info "[待安装] $package"
    packages_to_install+=("$package")
  fi
done

log_info "软件包状态：已安装=$installed_count，缺少=$missing_count"
if (( ${#packages_to_install[@]} == 0 )); then
  log_ok "所选基础工具均已安装，跳过 apt install"
else
  if [[ "${FORCE:-0}" == 1 ]]; then
    log_warn "FORCE=1：重新安装所选的 ${#packages_to_install[@]} 个软件包"
    run_step "强制重新安装基础工具包" with_retry 3 5 -- \
      sudo DEBIAN_FRONTEND=noninteractive apt-get -y --reinstall install "${packages_to_install[@]}"
  else
    run_step "安装缺少的基础工具包（${#packages_to_install[@]} 个）" with_retry 3 5 -- \
      sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "${packages_to_install[@]}"
  fi
fi

log_ok "base 模块安装完成"
