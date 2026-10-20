#!/usr/bin/env bash
# engine/lib/catalog.sh —— catalog 数据层解析器
# 把 catalog/*.catalog 解析进一组关联数组；纯数据，不执行任何安装。
# 不要加 set -e。

declare -gA CAT_TYPE=() CAT_BACKEND=() CAT_PACKAGES=() CAT_VERSION=()
declare -gA CAT_COMMANDS=() CAT_TRACK=() CAT_DEPS=() CAT_DESC=()
declare -gA CAT_GROUP=() CAT_ACTION=() CAT_ARTIFACTS=() CAT_SUDO=()
declare -ga CAT_ORDER=()

CATALOG_DIR="${CATALOG_DIR:-$PROJECT_DIR/catalog}"
CATALOG_FILE=""

catalog_reset() {
  CAT_TYPE=() CAT_BACKEND=() CAT_PACKAGES=() CAT_VERSION=()
  CAT_COMMANDS=() CAT_TRACK=() CAT_DEPS=() CAT_DESC=()
  CAT_GROUP=() CAT_ACTION=() CAT_ARTIFACTS=() CAT_SUDO=()
  CAT_ORDER=()
}

# catalog_expand_vars <raw> —— 只把 $VAR / ${VAR} 替换为环境变量值
catalog_expand_vars() {
  local raw="$1" out="" prefix
  while [[ "$raw" =~ ^([^\$]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(.*)$ ]]; do
    prefix="${BASH_REMATCH[1]}"
    out+="$prefix"
    out+="${!BASH_REMATCH[2]:-}"
    raw="${BASH_REMATCH[3]}"
  done
  out+="$raw"
  printf '%s' "$out"
}

_catalog_valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }
# 包名会做词拆分后传给 apt/npm/snap：不得含空白，也不得以 - 开头（避免参数注入）。
_catalog_valid_pkg_spec() { [[ "$1" =~ ^[A-Za-z0-9@][A-Za-z0-9._+/@=:~-]*$ ]]; }

# catalog_define <id> —— 为临时（profile 内联 backend:spec）工具注册条目
catalog_define_adhoc() {
  local id="$1" backend="$2" packages="$3" commands="$4" desc="${5:-临时指定}"
  _catalog_valid_id "$id" || return 1
  _catalog_valid_pkg_spec "$packages" || {
    log_error "临时工具 $id 的包名非法：$packages（不得含空白或以 - 开头）"
    return 1
  }
  if [[ -n "${CAT_TYPE[$id]+x}" ]]; then
    if [[ "${CAT_TYPE[$id]}" == package \
          && "${CAT_BACKEND[$id]}" == "$backend" \
          && "${CAT_PACKAGES[$id]}" == "$packages" ]]; then
      return 0
    fi
    log_error "临时工具 $id 与已有 catalog 条目冲突（已有：${CAT_TYPE[$id]} ${CAT_BACKEND[$id]:-} ${CAT_PACKAGES[$id]:-}；请求：package $backend $packages）"
    return 1
  fi
  CAT_ORDER+=("$id")
  CAT_TYPE[$id]=package
  CAT_BACKEND[$id]="$backend"
  CAT_PACKAGES[$id]="$packages"
  CAT_VERSION[$id]=""
  CAT_COMMANDS[$id]="$commands"
  CAT_TRACK[$id]=latest
  CAT_DEPS[$id]=""
  CAT_DESC[$id]="$desc"
  CAT_GROUP[$id]=adhoc
  CAT_ACTION[$id]=""
  CAT_ARTIFACTS[$id]=""
  CAT_SUDO[$id]=0
}

# catalog_load_file <file>
catalog_load_file() {
  local file="$1" raw line key value id="" line_no=0
  local -A seen_key=()

  [[ -f "$file" ]] || { log_error "catalog 文件不存在：$file"; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%%#*}"
    line="$(util_trim "$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      id="$(util_trim "${BASH_REMATCH[1]}")"
      _catalog_valid_id "$id" || { log_error "catalog 非法工具标识：$file:$line_no（$id）"; return 1; }
      if [[ -n "${CAT_TYPE[$id]+x}" ]]; then
        log_error "catalog 工具重复定义：$id（$file:$line_no）"
        return 1
      fi
      CAT_ORDER+=("$id")
      CAT_TYPE[$id]=package
      CAT_BACKEND[$id]=""
      CAT_PACKAGES[$id]=""
      CAT_VERSION[$id]=""
      CAT_COMMANDS[$id]=""
      CAT_TRACK[$id]=latest
      CAT_DEPS[$id]=""
      CAT_DESC[$id]=""
      CAT_GROUP[$id]=misc
      CAT_ACTION[$id]=""
      CAT_ARTIFACTS[$id]=""
      CAT_SUDO[$id]=0
      seen_key=()
      continue
    fi

    [[ -n "$id" ]] || { log_error "catalog 键值出现在任何 [工具] 段之前：$file:$line_no"; return 1; }
    [[ "$line" == *=* ]] || { log_error "catalog 格式错误：$file:$line_no（应为 key=value）"; return 1; }

    key="$(util_trim "${line%%=*}")"
    value="$(util_trim "${line#*=}")"
    value="$(catalog_expand_vars "$value")"
    [[ -n "${seen_key[$key]+x}" ]] && { log_error "catalog 键重复：$file:$line_no（$id.$key）"; return 1; }
    seen_key[$key]=1

    case "$key" in
      type)      CAT_TYPE[$id]="$value" ;;
      backend)   CAT_BACKEND[$id]="$value" ;;
      packages)  CAT_PACKAGES[$id]="$value" ;;
      version)   CAT_VERSION[$id]="$value" ;;
      commands)  CAT_COMMANDS[$id]="$value" ;;
      track)     CAT_TRACK[$id]="$value" ;;
      deps)      CAT_DEPS[$id]="${value//,/ }" ;;
      desc)      CAT_DESC[$id]="$value" ;;
      group)     CAT_GROUP[$id]="$value" ;;
      action)    CAT_ACTION[$id]="$value" ;;
      artifacts) CAT_ARTIFACTS[$id]="$value" ;;
      sudo)      CAT_SUDO[$id]="$value" ;;
      *) log_error "catalog 未知字段：$file:$line_no（$id.$key）"; return 1 ;;
    esac
  done <"$file"
}

# catalog_load <dir> —— 按文件名顺序加载目录下全部 *.catalog
catalog_load() {
  local dir="${1:-$CATALOG_DIR}" file
  catalog_reset
  [[ -d "$dir" ]] || { log_error "catalog 目录不存在：$dir"; return 1; }
  local -a files=()
  while IFS= read -r file; do files+=("$file"); done < <(find "$dir" -maxdepth 1 -type f -name '*.catalog' | sort)
  (( ${#files[@]} > 0 )) || { log_error "catalog 目录为空：$dir"; return 1; }
  for file in "${files[@]}"; do
    catalog_load_file "$file" || return 1
  done
  catalog_validate || return 1
}

catalog_validate() {
  local id type backend track dep
  for id in "${CAT_ORDER[@]}"; do
    type="${CAT_TYPE[$id]}"
    case "$type" in
      package)
        case "${CAT_BACKEND[$id]}" in
          apt|npm|snap) ;;
          *) log_error "catalog [$id] backend 非法：${CAT_BACKEND[$id]:-<空>}（应为 apt/npm/snap）"; return 1 ;;
        esac
        [[ -n "${CAT_PACKAGES[$id]}" ]] || { log_error "catalog [$id] 缺少 packages"; return 1; }
        ;;
      config)
        [[ -n "${CAT_ACTION[$id]}" ]] || { log_error "catalog [$id] 缺少 action"; return 1; }
        # action 会拼进 engine/actions/<action>.sh 路径；限制为标识符以防路径穿越。
        [[ "${CAT_ACTION[$id]}" =~ ^[a-z][a-z0-9_-]*$ ]] || {
          log_error "catalog [$id] action 非法：${CAT_ACTION[$id]}（仅允许小写字母、数字、_、-）"
          return 1
        }
        ;;
      *) log_error "catalog [$id] type 非法：${type:-<空>}（应为 package/config）"; return 1 ;;
    esac
    track="${CAT_TRACK[$id]}"
    [[ "$track" == pin || "$track" == latest ]] || { log_error "catalog [$id] track 非法：$track"; return 1; }
    if [[ "$track" == pin && -z "${CAT_VERSION[$id]}" ]]; then
      log_error "catalog [$id] track=pin 但缺少 version"; return 1
    fi
    for dep in ${CAT_DEPS[$id]}; do
      [[ -n "${CAT_TYPE[$dep]+x}" ]] || { log_error "catalog [$id] 依赖未定义的工具：$dep"; return 1; }
    done
  done
}

# catalog_expand_artifacts <id> —— 展开 artifacts 路径（~ 与环境变量）
catalog_expand_artifacts() {
  local id="$1" path
  for path in ${CAT_ARTIFACTS[$id]}; do
    path="$(catalog_expand_vars "$path")"
    printf '%s\n' "${path/#\~/$HOME}"
  done
}
