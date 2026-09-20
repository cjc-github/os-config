#!/usr/bin/env bash
# engine/lib/state.sh —— 非包管理产物清单（config 类动作写入的文件）
# 包管理类工具的状态实时查询后端，不落清单；此处只记录“动作写了哪些文件”。
# 清单格式（每行）：tool|action|artifact|timestamp
# 不要加 set -e。

STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/manifest.conf}"
# 运行期清单快照：失败回滚时把 manifest 还原到本次运行前，
# 避免出现“文件已回滚、清单仍记录”的不一致。
STATE_RUN_BAK="${STATE_RUN_BAK:-$STATE_DIR/.manifest.run.bak}"

state_init() {
  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR" 2>/dev/null || true
  [[ -f "$STATE_FILE" ]] || { : >"$STATE_FILE"; chmod 600 -- "$STATE_FILE" 2>/dev/null || true; }
}

# state_snapshot —— 运行开始时记录清单快照（幂等：一次运行只取一次）
# 注意：残留的 $STATE_RUN_BAK（上次运行被 SIGKILL 等未触发 trap 的异常中断）会被
# 本次运行直接复用为回滚基线，而不是重新抓取——即还原点可能早于本次运行开始。
# 这是有意的保守取舍（宁可多回退，也不丢基线）；若需强制刷新，运行前删除该文件。
state_snapshot() {
  state_init
  [[ -f "$STATE_RUN_BAK" ]] && return 0
  if [[ -f "$STATE_FILE" ]]; then
    cp -p -- "$STATE_FILE" "$STATE_RUN_BAK" 2>/dev/null || return 1
    chmod 600 -- "$STATE_RUN_BAK" 2>/dev/null || true
  else
    : >"$STATE_RUN_BAK"
  fi
}

# state_restore_snapshot —— 把清单还原到快照（失败回滚用）
state_restore_snapshot() {
  [[ -f "$STATE_RUN_BAK" ]] || return 0
  cp -p -- "$STATE_RUN_BAK" "$STATE_FILE" 2>/dev/null || {
    log_error "清单回滚失败：$STATE_FILE（快照在 $STATE_RUN_BAK）"; return 1
  }
  rm -f -- "$STATE_RUN_BAK" 2>/dev/null || true
}

# state_discard_snapshot —— 丢弃快照（成功提交或 --keep-going 保留改动时）
state_discard_snapshot() {
  rm -f -- "$STATE_RUN_BAK" 2>/dev/null || true
}

# state_action_dir <name> —— 动作用来保存自己簿记（备份、已创建文件清单）的私有目录
state_action_dir() {
  local d="$STATE_DIR/actions/$1"
  mkdir -p -- "$d"
  chmod 700 -- "$d" 2>/dev/null || true
  printf '%s\n' "$d"
}

# state_record <tool> <action> <artifact...>
state_record() {
  local tool="$1" action="$2"; shift 2
  local ts; ts=$(date '+%Y-%m-%dT%H:%M:%S')
  state_init
  state_forget "$tool"
  local artifact
  if [[ $# -eq 0 ]]; then
    printf '%s|%s|%s|%s\n' "$tool" "$action" "-" "$ts" >>"$STATE_FILE"
    return 0
  fi
  for artifact in "$@"; do
    printf '%s|%s|%s|%s\n' "$tool" "$action" "$artifact" "$ts" >>"$STATE_FILE"
  done
}

# state_forget <tool> —— 删除该工具的清单记录（不删除产物本身）
state_forget() {
  local tool="$1" tmp
  [[ -f "$STATE_FILE" ]] || return 0
  tmp="$(mktemp)"
  grep -v "^${tool}|" "$STATE_FILE" >"$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$STATE_FILE"
}

# state_artifacts <tool> —— 输出该工具记录的产物路径（"-" 表示无文件产物）
state_artifacts() {
  local tool="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  awk -F'|' -v t="$tool" '$1==t && $3!="-" { print $3 }' "$STATE_FILE"
}

# state_has <tool> —— 清单中是否有该工具
state_has() {
  local tool="$1"
  [[ -f "$STATE_FILE" ]] || return 1
  grep -q "^${tool}|" "$STATE_FILE"
}

# state_list —— 打印清单（供 status 展示）
state_list() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -v '^[[:space:]]*$' "$STATE_FILE" 2>/dev/null || true
}
