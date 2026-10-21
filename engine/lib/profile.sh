#!/usr/bin/env bash
# engine/lib/profile.sh —— profiles/*.conf 解析、extends 继承与工具名解析
# 不要加 set -e。

declare -gA PROF_DESC=() PROF_EXTENDS=() PROF_TOOLS=()
declare -ga PROF_ORDER=()

PROFILES_DIR="${PROFILES_DIR:-$PROJECT_DIR/profiles}"

profile_reset() {
  PROF_DESC=() PROF_EXTENDS=() PROF_TOOLS=()
  PROF_ORDER=()
}

profile_load_file() {
  local file="$1" raw line key value name="" line_no=0
  local -A seen_key=()

  [[ -f "$file" ]] || { log_error "profile 文件不存在：$file"; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%%#*}"
    line="$(util_trim "$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      name="$(util_trim "${BASH_REMATCH[1]}")"
      [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { log_error "profile 名称非法：$file:$line_no（$name）"; return 1; }
      [[ -z "${PROF_DESC[$name]+x}" ]] || { log_error "profile 重名：$name（$file:$line_no）"; return 1; }
      PROF_ORDER+=("$name")
      PROF_DESC[$name]=""
      PROF_EXTENDS[$name]=""
      PROF_TOOLS[$name]=""
      seen_key=()
      continue
    fi

    [[ -n "$name" ]] || { log_error "profile 键值出现在任何 [名字] 段之前：$file:$line_no"; return 1; }
    [[ "$line" == *=* ]] || { log_error "profile 格式错误：$file:$line_no（应为 key=value）"; return 1; }
    key="$(util_trim "${line%%=*}")"
    value="$(util_trim "${line#*=}")"
    [[ -n "${seen_key[$key]+x}" ]] && { log_error "profile 键重复：$file:$line_no（$name.$key）"; return 1; }
    seen_key[$key]=1

    case "$key" in
      desc)    PROF_DESC[$name]="$value" ;;
      extends) PROF_EXTENDS[$name]="$value" ;;
      tools)   PROF_TOOLS[$name]="$value" ;;
      *) log_error "profile 未知字段：$file:$line_no（$name.$key）"; return 1 ;;
    esac
  done <"$file"
}

# profile_load [dir|file] —— 加载内置目录，或指定外部 profile 文件
profile_load() {
  local target="${1:-$PROFILES_DIR}" file
  profile_reset
  if [[ -f "$target" ]]; then
    profile_load_file "$target" || return 1
    return 0
  fi
  [[ -d "$target" ]] || { log_error "profile 路径不存在：$target"; return 1; }
  local -a files=()
  while IFS= read -r file; do files+=("$file"); done < <(find "$target" -maxdepth 1 -type f -name '*.conf' | sort)
  (( ${#files[@]} > 0 )) || { log_error "profile 目录为空：$target"; return 1; }
  for file in "${files[@]}"; do
    profile_load_file "$file" || return 1
  done
}

# profile_tokens <name> —— 输出该 profile 合并后的工具 token（父在前，子在后；去重保序）
profile_tokens() {
  local name="$1"
  [[ -n "${PROF_DESC[$name]+x}" ]] || { log_error "未知 profile：$name"; return 1; }

  local -a chain=()
  local cur="$name" guard=0
  while [[ -n "$cur" ]]; do
    [[ -n "${PROF_DESC[$cur]+x}" ]] || { log_error "profile $name 的 extends 指向未知 profile：$cur"; return 1; }
    chain=("$cur" "${chain[@]}")
    cur="${PROF_EXTENDS[$cur]}"
    guard=$((guard + 1))
    (( guard > 32 )) && { log_error "profile $name 的 extends 存在循环"; return 1; }
  done

  local -A seen=()
  local p token
  for p in "${chain[@]}"; do
    local -a toks=()
    IFS=',' read -r -a toks <<<"${PROF_TOOLS[$p]}"
    for token in "${toks[@]}"; do
      token="$(util_trim "$token")"
      [[ -n "$token" ]] || continue
      [[ -n "${seen[$token]+x}" ]] && continue
      seen[$token]=1
      printf '%s\n' "$token"
    done
  done
}

# profile_resolve <name> —— 把 token 展开为工具标识（处理 @group 与 backend:spec）
# 输出到 SELECTED_TOOLS；无匹配的 token 报错。
declare -ga SELECTED_TOOLS=()

profile_resolve() {
  local name="$1" token id group backend spec matched
  SELECTED_TOOLS=()

  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    case "$token" in
      @*)
        group="${token#@}"
        matched=0
        for id in "${CAT_ORDER[@]}"; do
          if [[ "${CAT_GROUP[$id]}" == "$group" ]]; then
            matched=1
            SELECTED_TOOLS+=("$id")
          fi
        done
        (( matched == 1 )) || { log_error "profile [$name] 引用了空分组：$token"; return 1; }
        ;;
      *:*)
        backend="${token%%:*}"
        spec="${token#*:}"
        case "$backend" in
          apt|npm|snap) ;;
          *) log_error "profile [$name] 的 $token 后端非法（应为 apt/npm/snap）"; return 1 ;;
        esac
        [[ -n "$spec" ]] || { log_error "profile [$name] 的 $token 缺少包名"; return 1; }
        id="$(printf '%s' "$spec" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-')"
        # 去掉首尾所有 '-';规则与 ui/schema.py 的 normalize_adhoc_id 保持一致，
        # 否则 CLI 与 Web UI 会给同一个 token 算出不同的 id。
        while [[ "$id" == -* ]]; do id="${id:1}"; done
        while [[ "$id" == *- ]]; do id="${id%?}"; done
        catalog_define_adhoc "$id" "$backend" "$spec" "" "profile 内联：$token" || {
          log_error "profile [$name] 无法注册内联工具：$token"; return 1
        }
        SELECTED_TOOLS+=("$id")
        ;;
      *)
        [[ -n "${CAT_TYPE[$token]+x}" ]] || { log_error "profile [$name] 引用了未知工具：$token"; return 1; }
        SELECTED_TOOLS+=("$token")
        ;;
    esac
  done < <(profile_tokens "$name")

  (( ${#SELECTED_TOOLS[@]} > 0 )) || { log_error "profile [$name] 未选择任何工具"; return 1; }
  # 保序去重（分组展开可能与显式列举重叠）
  local -A seen=()
  local -a out=()
  for id in "${SELECTED_TOOLS[@]}"; do
    [[ -n "${seen[$id]+x}" ]] && continue
    seen[$id]=1
    out+=("$id")
  done
  SELECTED_TOOLS=("${out[@]}")
}
