#!/usr/bin/env bash
# engine/lib/list_json.sh —— catalog / profiles 的 JSON 序列化（供 Web UI 读取）
# 依赖 catalog.sh、profile.sh、events.sh；不要加 set -e。

_json_bool() {
  [[ "${1:-0}" == 1 ]] && printf 'true' || printf 'false'
}

list_json_catalog() {
  local id path first=1
  local -a arts=()
  printf '['
  for id in "${CAT_ORDER[@]}"; do
    (( first )) || printf ','
    first=0
    arts=()
    while IFS= read -r path; do
      [[ -n "$path" ]] && arts+=("$path")
    done < <(catalog_expand_artifacts "$id")
    printf '{"id":"%s","group":"%s","type":"%s","backend":"%s","packages":"%s","version":"%s","track":"%s","commands":"%s","deps":"%s","desc":"%s","action":"%s","artifacts":%s,"platforms":"%s","sudo":%s}' \
      "$(json_escape "$id")" \
      "$(json_escape "${CAT_GROUP[$id]:-}")" \
      "$(json_escape "${CAT_TYPE[$id]:-}")" \
      "$(json_escape "${CAT_BACKEND[$id]:-}")" \
      "$(json_escape "${CAT_PACKAGES[$id]:-}")" \
      "$(json_escape "${CAT_VERSION[$id]:-}")" \
      "$(json_escape "${CAT_TRACK[$id]:-}")" \
      "$(json_escape "${CAT_COMMANDS[$id]:-}")" \
      "$(json_escape "${CAT_DEPS[$id]:-}")" \
      "$(json_escape "${CAT_DESC[$id]:-}")" \
      "$(json_escape "${CAT_ACTION[$id]:-}")" \
      "$(json_string_array "${arts[@]}")" \
      "$(json_escape "${CAT_PLATFORMS[$id]:-linux}")" \
      "$(_json_bool "${CAT_SUDO[$id]:-0}")"
  done
  printf ']'
}

# 在子 shell 中渲染单个 profile：profile_resolve 会注册 adhoc 工具，
# 必须隔离，避免污染 catalog 序列化与后续 profile。
_list_json_profile() {
  local name="$1"
  local ext="${PROF_EXTENDS[$name]:-}" raw="${PROF_TOOLS[$name]:-}"
  local tok err="" line out errfile
  local -a raws=() toks=() tools=()

  local IFS=','
  for tok in $raw; do
    tok="$(util_trim "$tok")"
    [[ -n "$tok" ]] && raws+=("$tok")
  done
  unset IFS

  if out="$(profile_tokens "$name" 2>&1)"; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && toks+=("$line")
    done <<<"$out"
  else
    err="$(printf '%s\n' "$out" | head -n1)"
  fi

  if [[ -z "$err" ]]; then
    if errfile="$(util_mktemp 'profile 解析错误捕获文件')"; then
      if profile_resolve "$name" 2>"$errfile"; then
        tools=("${SELECTED_TOOLS[@]}")
      else
        err="$(head -n1 "$errfile")"
      fi
      rm -f "$errfile"
    else
      err="无法创建临时文件"
    fi
  fi

  printf '{"name":"%s","desc":"%s","extends":"%s","raw_tools":%s,"tokens":%s,"tools":%s,"error":"%s"}' \
    "$(json_escape "$name")" \
    "$(json_escape "${PROF_DESC[$name]:-}")" \
    "$(json_escape "$ext")" \
    "$(json_string_array "${raws[@]}")" \
    "$(json_string_array "${toks[@]}")" \
    "$(json_string_array "${tools[@]}")" \
    "$(json_escape "$err")"
}

list_json_profiles() {
  local name first=1
  printf '['
  for name in "${PROF_ORDER[@]}"; do
    (( first )) || printf ','
    first=0
    ( _list_json_profile "$name" )
  done
  printf ']'
}

list_json() {
  printf '{"catalog":'
  list_json_catalog
  printf ',"profiles":'
  list_json_profiles
  printf '}\n'
}
