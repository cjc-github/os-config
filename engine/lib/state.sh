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
# 本次运行是否创建/接管了快照。只读运行与 dry-run 没有快照，绝不能
# 在退出时把并发写运行正在使用的基线当成自己的删掉或还原。
declare -g STATE_SNAPSHOT_OWNER=0

state_init() {
  mkdir -p -- "$STATE_DIR" || { log_error "无法创建状态目录：$STATE_DIR"; return 1; }
  chmod 700 -- "$STATE_DIR" 2>/dev/null || true
  if [[ ! -f "$STATE_FILE" ]]; then
    : >"$STATE_FILE" || { log_error "无法创建状态清单：$STATE_FILE"; return 1; }
    chmod 600 -- "$STATE_FILE" 2>/dev/null || true
  fi
}

# state_snapshot —— 运行开始时记录清单快照（幂等：一次运行只取一次）
# 注意：残留的 $STATE_RUN_BAK（上次运行被 SIGKILL 等未触发 trap 的异常中断）会被
# 本次运行直接复用为回滚基线，而不是重新抓取——即还原点可能早于本次运行开始。
# 这是有意的保守取舍（宁可多回退，也不丢基线）；若需强制刷新，运行前删除该文件。
state_snapshot() {
  state_init || return 1
  [[ -f "$STATE_RUN_BAK" ]] && { STATE_SNAPSHOT_OWNER=1; return 0; }
  if [[ -f "$STATE_FILE" ]]; then
    cp -p -- "$STATE_FILE" "$STATE_RUN_BAK" 2>/dev/null || return 1
    chmod 600 -- "$STATE_RUN_BAK" 2>/dev/null || true
  else
    : >"$STATE_RUN_BAK"
  fi
  STATE_SNAPSHOT_OWNER=1
}

# state_restore_snapshot —— 把清单还原到快照（失败回滚用）
state_restore_snapshot() {
  [[ "${STATE_SNAPSHOT_OWNER:-0}" == 1 ]] || return 0
  [[ -f "$STATE_RUN_BAK" ]] || return 0
  cp -p -- "$STATE_RUN_BAK" "$STATE_FILE" 2>/dev/null || {
    log_error "清单回滚失败：$STATE_FILE（快照在 $STATE_RUN_BAK）"; return 1
  }
  rm -f -- "$STATE_RUN_BAK" 2>/dev/null || true
}

# state_discard_snapshot —— 丢弃快照（成功提交或 --keep-going 保留改动时）
state_discard_snapshot() {
  [[ "${STATE_SNAPSHOT_OWNER:-0}" == 1 ]] || return 0
  rm -f -- "$STATE_RUN_BAK" 2>/dev/null || true
}

# state_action_dir <name> —— 动作用来保存自己簿记（备份、已创建文件清单）的私有目录
state_action_dir() {
  local d="$STATE_DIR/actions/$1"
  mkdir -p -- "$d" || { log_error "无法创建动作状态目录：$d"; return 1; }
  chmod 700 -- "$d" 2>/dev/null || true
  printf '%s\n' "$d"
}

# state_record <tool> <action> <artifact...>
state_record() {
  local tool="$1" action="$2"; shift 2
  local ts; ts=$(date '+%Y-%m-%dT%H:%M:%S')
  state_init || return 1
  state_forget "$tool" || return 1
  local artifact
  if [[ $# -eq 0 ]]; then
    printf '%s|%s|%s|%s\n' "$tool" "$action" "-" "$ts" >>"$STATE_FILE" \
      || { log_error "无法写入状态清单：$STATE_FILE"; return 1; }
    return 0
  fi
  for artifact in "$@"; do
    printf '%s|%s|%s|%s\n' "$tool" "$action" "$artifact" "$ts" >>"$STATE_FILE" \
      || { log_error "无法写入状态清单：$STATE_FILE"; return 1; }
  done
}

# state_forget <tool> —— 删除该工具的清单记录（不删除产物本身）
state_forget() {
  local tool="$1" tmp rc
  [[ -f "$STATE_FILE" ]] || return 0
  tmp="$(mktemp)" || { log_error "无法创建临时文件以更新状态清单"; return 1; }
  # grep 退出码 1 表示没有匹配（正常），>=2 表示读取失败；
  # 后者若继续 mv，会用空文件覆盖整份清单。
  grep -v "^${tool}|" "$STATE_FILE" >"$tmp" 2>/dev/null; rc=$?
  if (( rc > 1 )); then
    rm -f -- "$tmp"
    log_error "无法读取状态清单：$STATE_FILE"
    return 1
  fi
  if ! mv -f -- "$tmp" "$STATE_FILE"; then
    rm -f -- "$tmp"
    log_error "无法更新状态清单：$STATE_FILE"
    return 1
  fi
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

# ---------------------------------------------------------------------------
# 并发锁：写操作（install/update/remove/verify --fix）独占 state/
# ---------------------------------------------------------------------------
STATE_LOCK="${STATE_LOCK:-$STATE_DIR/.lock}"

# state_lock_acquire —— 取得写锁。用 mkdir 保证原子性（POSIX 约定）。
# 残留锁（持有者已退出）会被清理后重试；清理失败则报错退出。
state_lock_acquire() {
  local pid
  state_init || return 1
  if mkdir -- "$STATE_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" >"$STATE_LOCK/pid" 2>/dev/null || true
    return 0
  fi
  pid="$(cat -- "$STATE_LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    log_warn "发现残留写锁（pid $pid 已不存在），清理后重试"
    rm -rf -- "$STATE_LOCK" 2>/dev/null || true
    if mkdir -- "$STATE_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" >"$STATE_LOCK/pid" 2>/dev/null || true
      return 0
    fi
  fi
  local who="状态未知"
  [[ -n "$pid" ]] && who="pid $pid"
  log_error "另一个 setup.sh 正在写入（$who），已中止；"
  log_error "若确认没有其他运行，删除 $STATE_LOCK 后重试"
  return 1
}

# state_locked —— 当前是否持有写锁（供 trap 判断）
state_locked() {
  [[ -d "$STATE_LOCK" ]] && [[ "$(cat -- "$STATE_LOCK/pid" 2>/dev/null || true)" == "$$" ]]
}

# state_lock_release —— 释放写锁。只释放自己持有的，避免误删他人锁。
state_lock_release() {
  state_locked || return 0
  rm -rf -- "$STATE_LOCK" 2>/dev/null || true
}
