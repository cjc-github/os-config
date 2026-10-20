#!/usr/bin/env bash
# engine/lib/events.sh —— JSONL 事件输出（供 Web UI 实时消费）
# 被动作脚本 source；不要加 set -e。
# 事件文件由 OS_CONFIG_EVENTS 指定；任何写失败都不得影响主流程。

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037'
}

json_string_array() {
  local out='[' first=1 v
  for v in "$@"; do
    (( first )) || out+=','
    first=0
    out+="\"$(json_escape "$v")\""
  done
  out+=']'
  printf '%s' "$out"
}

events_emit() {
  local type="$1" fragment="${2:-}" ts
  [[ -n "${OS_CONFIG_EVENTS:-}" ]] || return 0
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","event":"%s",%s}\n' \
    "$ts" "$(json_escape "$type")" "$fragment" \
    >>"$OS_CONFIG_EVENTS" 2>/dev/null || true
  return 0
}
