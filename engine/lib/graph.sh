#!/usr/bin/env bash
# engine/lib/graph.sh —— 依赖闭包与拓扑排序
# 不要加 set -e。

declare -ga GRAPH_ORDER=()

# graph_build <id...> —— 收集全部工具及其依赖，输出拓扑序到 GRAPH_ORDER
# 依赖先于被依赖者；同层按 catalog 声明顺序稳定输出。循环依赖报错。
declare -gA _GRAPH_VISITED=() _GRAPH_STACK=()

_graph_visit() {
  local id="$1"
  [[ -n "${CAT_TYPE[$id]+x}" ]] || { log_error "依赖闭包遇到未知工具：$id"; return 1; }
  if [[ "${_GRAPH_VISITED[$id]:-0}" == 1 ]]; then
    return 0
  fi
  if [[ "${_GRAPH_STACK[$id]:-0}" == 1 ]]; then
    log_error "检测到循环依赖：$id"
    return 1
  fi

  _GRAPH_STACK[$id]=1
  local dep
  for dep in ${CAT_DEPS[$id]}; do
    _graph_visit "$dep" || return 1
  done
  _GRAPH_STACK[$id]=0
  _GRAPH_VISITED[$id]=1
  GRAPH_ORDER+=("$id")
}

graph_build() {
  GRAPH_ORDER=()
  _GRAPH_VISITED=()
  _GRAPH_STACK=()
  local id
  for id in "$@"; do
    _graph_visit "$id" || return 1
  done
}

# graph_reverse —— 把 GRAPH_ORDER 反转为移除顺序（被依赖者先删）
graph_reverse() {
  local i
  local -a rev=()
  for (( i = ${#GRAPH_ORDER[@]} - 1; i >= 0; i-- )); do
    rev+=("${GRAPH_ORDER[$i]}")
  done
  GRAPH_ORDER=("${rev[@]}")
}

# graph_dependents <id> —— 输出依赖该工具的已选工具（用于 remove 时的连带检查）
graph_dependents() {
  local target="$1" id dep
  for id in "${GRAPH_ORDER[@]}"; do
    [[ "$id" == "$target" ]] && continue
    for dep in ${CAT_DEPS[$id]}; do
      [[ "$dep" == "$target" ]] && printf '%s\n' "$id"
    done
  done
}
