#!/usr/bin/env bash
# sys-base 软件目录和二维选择配置解析器。
# 本文件由 install.sh / verify.sh source，不应直接执行，也不应设置 set -e。

# shellcheck disable=SC2034 # 多个关联数组分别由 install.sh / verify.sh 使用。
declare -gA BASE_CATEGORY_DESC=()
declare -gA BASE_TOOL_CATEGORY=()
declare -gA BASE_TOOL_NAME=()
declare -gA BASE_TOOL_PACKAGES=()
declare -gA BASE_TOOL_COMMANDS=()
declare -gA BASE_TOOL_DESC=()
declare -gA BASE_CATEGORY_ENABLED=()
declare -gA BASE_TOOL_ENABLED=()
declare -ga BASE_CATEGORY_ORDER=()
declare -ga BASE_TOOL_ORDER=()
declare -ga BASE_SELECTED_TOOLS=()
declare -ga BASE_SELECTED_PACKAGES=()

base_trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

base_bool_normalize() {
  case "${1,,}" in
    true) printf 'true' ;;
    false) printf 'false' ;;
    *) return 1 ;;
  esac
}

base_resolve_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PROJECT_DIR" "$path"
  fi
}

base_reset_catalog() {
  BASE_CATEGORY_DESC=()
  BASE_TOOL_CATEGORY=()
  BASE_TOOL_NAME=()
  BASE_TOOL_PACKAGES=()
  BASE_TOOL_COMMANDS=()
  BASE_TOOL_DESC=()
  BASE_CATEGORY_ENABLED=()
  BASE_TOOL_ENABLED=()
  BASE_CATEGORY_ORDER=()
  BASE_TOOL_ORDER=()
  BASE_SELECTED_TOOLS=()
  BASE_SELECTED_PACKAGES=()
}

base_load_catalog() {
  local catalog="$1" raw line category category_desc tool packages commands description extra id token line_no=0
  local -A seen_category=()

  [[ -f "$catalog" ]] || { log_error "sys-base 软件目录不存在：$catalog"; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%%#*}"
    line="$(base_trim "$line")"
    [[ -z "$line" ]] && continue

    IFS='|' read -r category category_desc tool packages commands description extra <<<"$line"
    category="$(base_trim "$category")"
    category_desc="$(base_trim "$category_desc")"
    tool="$(base_trim "$tool")"
    packages="$(base_trim "$packages")"
    commands="$(base_trim "$commands")"
    description="$(base_trim "$description")"
    extra="$(base_trim "${extra-}")"

    if [[ -n "$extra" || -z "$category_desc" || -z "$packages" || -z "$description" ]]; then
      log_error "软件目录格式错误：$catalog:$line_no"
      return 1
    fi
    if [[ ! "$category" =~ ^[a-z0-9][a-z0-9_-]*$ || ! "$tool" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
      log_error "软件目录包含非法分类或工具名：$catalog:$line_no（$category/$tool）"
      return 1
    fi

    id="$category.$tool"
    if [[ -n "${BASE_TOOL_CATEGORY[$id]+x}" ]]; then
      log_error "软件目录中工具重复：$id"
      return 1
    fi

    if [[ -z "${seen_category[$category]+x}" ]]; then
      seen_category[$category]=1
      BASE_CATEGORY_ORDER+=("$category")
      BASE_CATEGORY_DESC[$category]="$category_desc"
      BASE_CATEGORY_ENABLED[$category]=false
    elif [[ "${BASE_CATEGORY_DESC[$category]}" != "$category_desc" ]]; then
      log_error "软件目录中分类说明不一致：$category"
      return 1
    fi

    for token in $packages; do
      if [[ ! "$token" =~ ^[a-zA-Z0-9][a-zA-Z0-9+.:_-]*$ ]]; then
        log_error "软件目录包含非法 APT 软件包名：$token（$id）"
        return 1
      fi
    done
    for token in $commands; do
      if [[ ! "$token" =~ ^[a-zA-Z0-9][a-zA-Z0-9+._-]*$ ]]; then
        log_error "软件目录包含非法验证命令：$token（$id）"
        return 1
      fi
    done

    BASE_TOOL_ORDER+=("$id")
    BASE_TOOL_CATEGORY[$id]="$category"
    BASE_TOOL_NAME[$id]="$tool"
    BASE_TOOL_PACKAGES[$id]="$packages"
    BASE_TOOL_COMMANDS[$id]="$commands"
    BASE_TOOL_DESC[$id]="$description"
    BASE_TOOL_ENABLED[$id]=false
  done <"$catalog"

  if (( ${#BASE_TOOL_ORDER[@]} == 0 )); then
    log_error "sys-base 软件目录为空：$catalog"
    return 1
  fi
}

base_load_config() {
  local config="$1" raw line section="" key value normalized id line_no=0

  [[ -f "$config" ]] || { log_error "sys-base 选择配置不存在：$config"; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%%#*}"
    line="$(base_trim "$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[([a-z0-9][a-z0-9_-]*)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      if [[ -z "${BASE_CATEGORY_DESC[$section]+x}" ]]; then
        log_error "基础工具配置包含未知分类：$config:$line_no（$section）"
        return 1
      fi
      continue
    fi

    if [[ -z "$section" || "$line" != *=* ]]; then
      log_error "基础工具配置格式错误：$config:$line_no"
      return 1
    fi

    key="$(base_trim "${line%%=*}")"
    value="$(base_trim "${line#*=}")"
    if [[ ! "$key" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
      log_error "基础工具配置包含非法键名：$config:$line_no（$key）"
      return 1
    fi
    if ! normalized="$(base_bool_normalize "$value")"; then
      log_error "基础工具配置值必须是 true 或 false：$config:$line_no（$key=$value）"
      return 1
    fi

    if [[ "$key" == enabled ]]; then
      BASE_CATEGORY_ENABLED[$section]="$normalized"
    else
      id="$section.$key"
      if [[ -z "${BASE_TOOL_CATEGORY[$id]+x}" ]]; then
        log_error "基础工具配置包含未知工具：$config:$line_no（$id）"
        return 1
      fi
      BASE_TOOL_ENABLED[$id]="$normalized"
    fi
  done <"$config"
}

base_build_selection() {
  local id category package
  local -A seen_package=()

  BASE_SELECTED_TOOLS=()
  BASE_SELECTED_PACKAGES=()

  for id in "${BASE_TOOL_ORDER[@]}"; do
    category="${BASE_TOOL_CATEGORY[$id]}"
    if [[ "${BASE_CATEGORY_ENABLED[$category]}" == true && "${BASE_TOOL_ENABLED[$id]}" == true ]]; then
      BASE_SELECTED_TOOLS+=("$id")
      for package in ${BASE_TOOL_PACKAGES[$id]}; do
        if [[ -z "${seen_package[$package]+x}" ]]; then
          seen_package[$package]=1
          BASE_SELECTED_PACKAGES+=("$package")
        fi
      done
    fi
  done
}

base_load_selection() {
  local config="$1" catalog="$2"
  base_reset_catalog
  base_load_catalog "$catalog" || return 1
  base_load_config "$config" || return 1
  base_build_selection
}

base_log_selection() {
  local category id selected tool_list
  for category in "${BASE_CATEGORY_ORDER[@]}"; do
    if [[ "${BASE_CATEGORY_ENABLED[$category]}" != true ]]; then
      log_info "[${BASE_CATEGORY_DESC[$category]}] disabled：跳过整个分类"
      continue
    fi

    selected=0
    tool_list=""
    for id in "${BASE_TOOL_ORDER[@]}"; do
      [[ "${BASE_TOOL_CATEGORY[$id]}" == "$category" ]] || continue
      [[ "${BASE_TOOL_ENABLED[$id]}" == true ]] || continue
      selected=$((selected + 1))
      tool_list+="${tool_list:+, }${BASE_TOOL_NAME[$id]}"
    done

    if (( selected > 0 )); then
      log_info "[${BASE_CATEGORY_DESC[$category]}] 已选 $selected 项：$tool_list"
    else
      log_warn "[${BASE_CATEGORY_DESC[$category]}] 已启用，但未选择任何工具"
    fi
  done
  log_info "sys-base 共选择 ${#BASE_SELECTED_TOOLS[@]} 个工具、${#BASE_SELECTED_PACKAGES[@]} 个去重后的 APT 软件包"
}

base_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}
