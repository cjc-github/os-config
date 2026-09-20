#!/usr/bin/env bash
# tests/run.sh —— os-config 新架构回归测试（无外部框架）
# ---------------------------------------------------------------------------
# 覆盖：catalog 解析/校验、profile 继承与解析、依赖闭包、state、rollback、
#       util（代理/重试/校验）、后端适配器（apt/npm/snap，全部用假命令）、
#       引擎五动词编排、动作脚本接口、setup.sh 入口。
# 安全：绝不触碰宿主 /etc；apt/snap/npm/sudo 全部替换为假命令。
# 用法：bash tests/run.sh [名称过滤]
# 不要加 set -e。
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FILTER="${1:-}"

# ---------------------------------------------------------------------------
# 断言：每个断言记一行 PASS/FAIL 到 $TMPROOT/.results
# ---------------------------------------------------------------------------
ok() { printf 'PASS\n' >>"$TMPROOT/.results"; }
not_ok() {
  printf 'FAIL\n' >>"$TMPROOT/.results"
  printf '    NOT_OK: %s\n' "$1" >&2
}

assert_eq() {
  local exp="$1" act="$2" msg="${3:-}"
  if [[ "$exp" == "$act" ]]; then ok; else not_ok "$msg (exp=[$exp] act=[$act])"; fi
}
assert_ne() {
  local a="$1" b="$2" msg="${3:-}"
  if [[ "$a" != "$b" ]]; then ok; else not_ok "$msg (both=[$a])"; fi
}
assert_contains() {
  local hay="$1" needle="$2" msg="${3:-}"
  if [[ "$hay" == *"$needle"* ]]; then ok; else not_ok "$msg (未包含 [$needle])"; fi
}
assert_not_contains() {
  local hay="$1" needle="$2" msg="${3:-}"
  if [[ "$hay" != *"$needle"* ]]; then ok; else not_ok "$msg (不应包含 [$needle])"; fi
}
assert_file_exists() {
  if [[ -f "$1" ]]; then ok; else not_ok "${2:-文件不存在}: $1"; fi
}
assert_file_missing() {
  if [[ ! -e "$1" ]]; then ok; else not_ok "${2:-文件不应存在}: $1"; fi
}
assert_true() { local m="$1"; shift; if "$@"; then ok; else not_ok "$m"; fi; }
assert_false() { local m="$1"; shift; if "$@"; then not_ok "$m"; else ok; fi; }
assert_rc_eq() {
  local exp="$1" act="$2" msg="${3:-}"
  if [[ "$exp" == "$act" ]]; then ok; else not_ok "$msg (exp rc=$exp act rc=$act)"; fi
}

# ---------------------------------------------------------------------------
# 测试运行器：每个用例独立子 shell + 独立 TMPROOT
# ---------------------------------------------------------------------------
run_test() {
  local name="$1" fn="$2"
  if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then return 0; fi

  local TMPROOT
  TMPROOT="$(mktemp -d)"
  mkdir -p "$TMPROOT/home" "$TMPROOT/bin" "$TMPROOT/t"
  : >"$TMPROOT/.results"

  (
    export TMPROOT TESTDIR="$TMPROOT/t" ROOT
    export HOME="$TMPROOT/home"
    export STATE_DIR="$TMPROOT/state"
    export STATE_FILE="$STATE_DIR/manifest.conf"
    export LOG_FILE="$TMPROOT/test.log"
    export CATALOG_DIR="$ROOT/catalog"
    export PROFILES_DIR="$ROOT/profiles"
    export FORCE=0 DRY_RUN=0 KEEP_GOING=0 NO_SUDO=0 DEBUG=0
    export FAKE_APT_LOG="$TMPROOT/apt.log"
    export FAKE_NPM_LOG="$TMPROOT/npm.log"
    export FAKE_NPM_PREFIX="$TMPROOT/npm-prefix"
    export FAKE_SNAP_LOG="$TMPROOT/snap.log"
    export PATH="$FAKE_NPM_PREFIX/bin:$TMPROOT/bin:$PATH"
    make_fakes
    load_libs
    "$fn"
  ) >"$TMPROOT/.out" 2>&1
  local rc=$?

  local p f
  p=$(grep -c '^PASS$' "$TMPROOT/.results" 2>/dev/null || true)
  f=$(grep -c '^FAIL$' "$TMPROOT/.results" 2>/dev/null || true)
  p="${p:-0}"; f="${f:-0}"

  if [[ "$rc" == 0 && "$f" == 0 && "$p" -gt 0 ]]; then
    printf 'ok   %s (%s)\n' "$name" "$p"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s (pass=%s fail=%s rc=%s)\n' "$name" "$p" "$f" "$rc" >&2
    sed 's/^/      | /' "$TMPROOT/.out" >&2
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$TMPROOT"
  return 0
}

# ---------------------------------------------------------------------------
# 库加载与假命令
# ---------------------------------------------------------------------------
load_libs() {
  export PROJECT_DIR="$ROOT"
  . "$ROOT/engine/lib/log.sh"
  . "$ROOT/engine/lib/util.sh"
  . "$ROOT/engine/lib/rollback.sh"
  . "$ROOT/engine/lib/state.sh"
  . "$ROOT/engine/lib/catalog.sh"
  . "$ROOT/engine/lib/profile.sh"
  . "$ROOT/engine/lib/graph.sh"
  . "$ROOT/engine/lib/backends.sh"
  . "$ROOT/engine/lib/engine.sh"
}

make_fakes() {
  local b="$TMPROOT/bin"

  # sudo：吞掉 -n/-v/-E/--/-H/-S 与「命令前」的 VAR=VALUE，执行其余命令
  cat >"$b/sudo" <<'EOF'
#!/usr/bin/env bash
args=()
leading=1
while (( $# > 0 )); do
  case "$1" in
    -n|-v|-E|--|-H|-S|-k) shift ;;
    *)
      if (( leading )) && [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        export "$1"; shift
      else
        leading=0
        args+=("$1"); shift
      fi
      ;;
  esac
done
(( ${#args[@]} == 0 )) && exit 0
exec "${args[@]}"
EOF

  printf '#!/usr/bin/env bash\nexit 1\n' >"$b/fuser"

  cat >"$b/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '1.1.1.1 via 192.168.114.254 dev eth0 src 192.168.114.50 uid 1000'
EOF

  cat >"$b/ping" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_PING_FAIL:-0}" != 1 ]]
EOF

  cat >"$b/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_APT_LOG:-/dev/null}"
exit 0
EOF

  cat >"$b/dpkg-query" <<'EOF'
#!/usr/bin/env bash
pkg="${!#}"
fmt=""
for a in "$@"; do case "$a" in -f=*) fmt="${a#-f=}" ;; esac; done
if [[ -f "$TESTDIR/apt-installed" ]] && grep -qx -- "$pkg" "$TESTDIR/apt-installed"; then
  if [[ "$fmt" == *Version* ]]; then printf '%s\n' '1.2.3-1'; else printf '%s\n' 'install ok installed'; fi
  exit 0
fi
exit 1
EOF

  cat >"$b/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$TESTDIR/dpkg-arch" ]]; then cat "$TESTDIR/dpkg-arch"; else printf 'amd64\n'; fi
EOF

  cat >"$b/npm" <<'EOF'
#!/usr/bin/env bash
ver="${FAKE_NPM_VERSION:-1.2.3}"
case "${1:-}" in
  config)
    if [[ "${2:-}" == get ]]; then
      case "${3:-}" in
        prefix) printf '%s\n' "$FAKE_NPM_PREFIX"; exit 0 ;;
        registry) printf '%s\n' "${NPM_REGISTRY:-}"; exit 0 ;;
      esac
    fi
    exit 0 ;;
  install)
    last="${!#}"; spec="${last%@*}"; base="${spec##*/}"
    mkdir -p "$FAKE_NPM_PREFIX/bin"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$ver" >"$FAKE_NPM_PREFIX/bin/$base"
    chmod +x "$FAKE_NPM_PREFIX/bin/$base"
    printf 'install %s\n' "$*" >>"${FAKE_NPM_LOG:-/dev/null}"
    exit 0 ;;
  uninstall)
    last="${!#}"; base="${last##*/}"
    rm -f "$FAKE_NPM_PREFIX/bin/$base"
    printf 'uninstall %s\n' "$*" >>"${FAKE_NPM_LOG:-/dev/null}"
    exit 0 ;;
esac
printf '%s\n' "$ver"
EOF

  cat >"$b/node" <<'EOF'
#!/usr/bin/env bash
printf 'v22.0.0\n'
EOF

  cat >"$b/snap" <<'EOF'
#!/usr/bin/env bash
sub="${1:-}"
case "$sub" in
  list)
    [[ -f "$TESTDIR/snap-installed" ]] && grep -qx -- "${2:-}" "$TESTDIR/snap-installed" && exit 0
    exit 1 ;;
  install)
    printf 'install %s\n' "${2:-}" >>"${FAKE_SNAP_LOG:-/dev/null}"
    printf '%s\n' "${2:-}" >>"$TESTDIR/snap-installed"
    exit 0 ;;
  refresh)
    printf 'refresh %s\n' "${2:-}" >>"${FAKE_SNAP_LOG:-/dev/null}"
    exit 0 ;;
  remove)
    printf 'remove %s\n' "${2:-}" >>"${FAKE_SNAP_LOG:-/dev/null}"
    grep -vx -- "${2:-}" "$TESTDIR/snap-installed" >"$TESTDIR/snap.tmp" 2>/dev/null || true
    mv -f "$TESTDIR/snap.tmp" "$TESTDIR/snap-installed" 2>/dev/null || true
    exit 0 ;;
esac
exit 0
EOF

  cat >"$b/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
out=""
while (( $# > 0 )); do
  case "$1" in -f) out="$2"; shift 2 ;; *) shift ;; esac
done
[[ -n "$out" ]] || exit 1
: >"$out"
printf '%s.pub\n' "$out" >"$out.pub"
chmod 600 -- "$out"
EOF

  printf '#!/usr/bin/env bash\nexit 0\n' >"$b/ssh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$b/curl"

  chmod +x "$b"/*
}

# ---------------------------------------------------------------------------
# 测试辅助
# ---------------------------------------------------------------------------
register_pkg_tool() {
  local id="$1" backend="$2" packages="$3" commands="${4:-}" version="${5:-}" track="${6:-latest}"
  CAT_ORDER+=("$id")
  CAT_TYPE[$id]=package
  CAT_BACKEND[$id]="$backend"
  CAT_PACKAGES[$id]="$packages"
  CAT_VERSION[$id]="$version"
  CAT_COMMANDS[$id]="$commands"
  CAT_TRACK[$id]="$track"
  CAT_DEPS[$id]=""
  CAT_DESC[$id]="test"
  CAT_GROUP[$id]="test"
  CAT_ACTION[$id]=""
  CAT_ARTIFACTS[$id]=""
  CAT_SUDO[$id]=0
}

register_config_tool() {
  local id="$1" action="$2"; shift 2
  CAT_ORDER+=("$id")
  CAT_TYPE[$id]=config
  CAT_BACKEND[$id]=""
  CAT_PACKAGES[$id]=""
  CAT_VERSION[$id]=""
  CAT_COMMANDS[$id]=""
  CAT_TRACK[$id]=latest
  CAT_DEPS[$id]=""
  CAT_DESC[$id]="test"
  CAT_GROUP[$id]="test"
  CAT_ACTION[$id]="$action"
  CAT_ARTIFACTS[$id]="$*"
  CAT_SUDO[$id]=0
}

catalog_expect() {
  local exp_rc="$1"; shift
  local d; d="$(mktemp -d)"
  local line
  for line in "$@"; do printf '%s\n' "$line"; done >"$d/a.catalog"
  local out rc
  out=$(catalog_load "$d" 2>&1); rc=$?
  assert_rc_eq "$exp_rc" "$rc" "catalog rc: $out"
  rm -rf "$d"
}

resolve_inline() {
  profile_reset
  PROF_ORDER=(cli); PROF_DESC[cli]="inline"; PROF_EXTENDS[cli]=""; PROF_TOOLS[cli]="$1"
  profile_resolve cli >/dev/null 2>&1
}

# ===========================================================================
# 1. 语法
# ===========================================================================
test_syntax() {
  local f rc=0
  while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { rc=1; not_ok "语法错误：$f"; }
  done < <(find "$ROOT/engine" "$ROOT/tests" -type f -name '*.sh' -print0)
  bash -n "$ROOT/setup.sh" 2>/dev/null || { rc=1; not_ok "语法错误：setup.sh"; }
  (( rc == 0 )) && ok
  return 0
}

# ===========================================================================
# 2. catalog 数据层
# ===========================================================================
test_catalog_real() {
  local out rc
  catalog_load "$ROOT/catalog" >"$TESTDIR/load.out" 2>&1; rc=$?
  out="$(cat "$TESTDIR/load.out")"
  assert_rc_eq 0 "$rc" "真实 catalog 加载：$out"
  assert_eq 56 "${#CAT_ORDER[@]}" "真实 catalog 条目数"

  assert_eq apt "${CAT_BACKEND[curl]}" "curl backend"
  assert_eq ca-certificates "${CAT_DEPS[curl]}" "curl deps"
  assert_eq config "${CAT_TYPE[git]}" "git type"
  assert_eq git "${CAT_ACTION[git]}" "git action"
  assert_eq git-cli "${CAT_DEPS[git]}" "git deps"
  assert_eq 0 "${CAT_SUDO[proxy]}" "proxy sudo"
  assert_eq 1 "${CAT_SUDO[mirrors]}" "mirrors sudo"
  assert_eq npm "${CAT_BACKEND[claude]}" "claude backend"
  assert_eq pin "${CAT_TRACK[claude]}" "claude track"
  assert_eq 2.1.228 "${CAT_VERSION[claude]}" "claude version"
  assert_eq nodejs "${CAT_DEPS[claude]}" "claude deps"
  assert_eq fdfind "${CAT_COMMANDS[fd]}" "fd commands"
  assert_eq xz-utils "${CAT_PACKAGES[xz]}" "xz packages"
  assert_eq ninja-build "${CAT_PACKAGES[ninja]}" "ninja packages"
  assert_eq build-essential "${CAT_PACKAGES[gcc]}" "gcc packages"
}

test_catalog_expand_vars() {
  TESTVAR=hello
  assert_eq 'hello hello $1 x' "$(catalog_expand_vars '$TESTVAR ${TESTVAR} $1 x')" "变量展开"
  assert_eq '' "$(catalog_expand_vars '$NOPE_UNSET_VAR')" "未定义变量展开为空"
}

test_catalog_artifacts() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  assert_eq "$HOME/.gitconfig" "$(catalog_expand_artifacts git)" "git artifacts"
  assert_eq "/etc/systemd/journald.conf.d/99-os-config.conf
$HOME/.bashrc" "$(catalog_expand_artifacts syslog)" "syslog artifacts"
  assert_eq "" "$(catalog_expand_artifacts nosuspend)" "nosuspend 无 artifacts"
}

test_catalog_reject() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  catalog_expect 0 '[foo]' 'type=package' 'backend=apt' 'packages=foo'
  catalog_expect 1 '[foo]' 'type=package' 'backend=apt' 'packages=foo' 'bogus=1'
  catalog_expect 1 '[foo]' 'type=package' 'type=package' 'backend=apt' 'packages=foo'
  catalog_expect 1 'type=package' '[foo]' 'backend=apt' 'packages=foo'
  catalog_expect 1 '[Jq]' 'type=package' 'backend=apt' 'packages=foo'
  catalog_expect 1 '[foo]' 'type package' 'backend=apt' 'packages=foo'
  catalog_expect 1 '[foo]' 'type=package' 'backend=brew' 'packages=foo'
  catalog_expect 1 '[foo]' 'type=package' 'backend=apt'
  catalog_expect 1 '[foo]' 'type=widget' 'packages=foo'
  catalog_expect 1 '[foo]' 'type=package' 'backend=apt' 'packages=foo' 'track=frozen'
  catalog_expect 1 '[foo]' 'type=package' 'backend=apt' 'packages=foo' 'track=pin'
  catalog_expect 0 '[foo]' 'type=package' 'backend=apt' 'packages=foo' 'track=pin' 'version=1.2.3'
  catalog_expect 1 '[foo]' 'type=config'
  catalog_expect 1 '[foo]' 'type=package' 'backend=apt' 'packages=foo' 'deps=nope'
  catalog_expect 0 '[foo]' 'type=config' 'action=git'
  local empty; empty="$(mktemp -d)"
  local out rc
  out=$(catalog_load "$empty" 2>&1); rc=$?
  assert_rc_eq 1 "$rc" "空 catalog 目录：$out"
  rm -rf "$empty"
}

test_catalog_adhoc() {
  catalog_reset
  catalog_define_adhoc mytool apt mytool "" "临时" || not_ok "adhoc 注册失败"
  assert_eq package "${CAT_TYPE[mytool]}" "adhoc type"
  assert_eq apt "${CAT_BACKEND[mytool]}" "adhoc backend"
  assert_eq adhoc "${CAT_GROUP[mytool]}" "adhoc group"
  assert_eq latest "${CAT_TRACK[mytool]}" "adhoc track"
  catalog_define_adhoc mytool npm other ""
  assert_eq 1 "${#CAT_ORDER[@]}" "adhoc 幂等不重复"
  assert_eq apt "${CAT_BACKEND[mytool]}" "adhoc 幂等不改写"
  local rc
  catalog_define_adhoc 'Bad' apt x ""; rc=$?
  assert_rc_eq 1 "$rc" "非法 adhoc id"
}

# ===========================================================================
# 3. profile
# ===========================================================================
test_profile_basic() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  local out rc
  profile_load "$ROOT/profiles" >"$TESTDIR/prof.out" 2>&1; rc=$?
  out="$(cat "$TESTDIR/prof.out")"
  assert_rc_eq 0 "$rc" "profile 加载：$out"
  assert_eq 4 "${#PROF_ORDER[@]}" "profile 数量"
  assert_eq "ai default dev minimal" "${PROF_ORDER[*]}" "profile 顺序"
  assert_eq minimal "${PROF_EXTENDS[default]}" "default extends"
  local toks
  toks="$(profile_tokens default | tr '\n' ' ')"
  assert_eq "mirrors @core git ssh @archive @transfer proxy nodejs @ai syslog nosuspend " "$toks" "default tokens"
}

test_profile_resolve_counts() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  profile_load "$ROOT/profiles" >/dev/null 2>&1
  local p
  for p in minimal:7 ai:10 default:24 dev:52; do
    local name="${p%%:*}" want="${p##*:}"
    profile_resolve "$name" >/dev/null 2>&1 || not_ok "resolve $name 失败"
    assert_eq "$want" "${#SELECTED_TOOLS[@]}" "resolve $name 数量"
  done
}

test_profile_inline() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  resolve_inline 'claude, apt:my-tool, npm:@scope/pkg' || not_ok "内联解析失败"
  assert_eq "claude my-tool scope-pkg" "${SELECTED_TOOLS[*]}" "内联解析结果"
  assert_eq apt "${CAT_BACKEND[my-tool]}" "内联 apt backend"
  assert_eq my-tool "${CAT_PACKAGES[my-tool]}" "内联 apt 包名"
  assert_eq npm "${CAT_BACKEND[scope-pkg]}" "内联 npm backend"
  assert_eq "@scope/pkg" "${CAT_PACKAGES[scope-pkg]}" "内联 npm 包名"
}

test_profile_errors() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  local rc
  resolve_inline '@nope'; rc=$?; assert_rc_eq 1 "$rc" "空分组报错"
  resolve_inline 'brew:jq'; rc=$?; assert_rc_eq 1 "$rc" "非法后端报错"
  resolve_inline 'no-such-tool'; rc=$?; assert_rc_eq 1 "$rc" "未知工具报错"
  resolve_inline 'apt:'; rc=$?; assert_rc_eq 1 "$rc" "缺包名报错"

  local d; d="$(mktemp -d)"
  printf '[a]\nextends=b\ntools=git\n[b]\nextends=a\ntools=ssh\n' >"$d/cycle.conf"
  profile_load "$d/cycle.conf" >/dev/null 2>&1
  profile_tokens a >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "extends 循环报错"

  printf '[a]\nextends=nope\ntools=git\n' >"$d/unknown.conf"
  profile_load "$d/unknown.conf" >/dev/null 2>&1
  profile_tokens a >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "extends 未知报错"

  printf '[dup]\ntools=git\n[dup]\ntools=ssh\n' >"$d/dup.conf"
  profile_load "$d/dup.conf" >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "profile 重名报错"

  printf '[a]\nbogus=1\n' >"$d/field.conf"
  profile_load "$d/field.conf" >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "profile 未知字段报错"

  printf 'tools=git\n' >"$d/pre.conf"
  profile_load "$d/pre.conf" >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "profile 段前键值报错"
  rm -rf "$d"
}

# ===========================================================================
# 4. 依赖图
# ===========================================================================
test_graph() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  graph_build git-cli git ssh
  assert_eq "git-cli git openssh-client ssh" "${GRAPH_ORDER[*]}" "拓扑序（依赖在前）"

  graph_build nodejs claude
  assert_eq "ca-certificates curl nodejs claude" "${GRAPH_ORDER[*]}" "nodejs/claude 闭包"

  graph_reverse
  assert_eq "claude nodejs curl ca-certificates" "${GRAPH_ORDER[*]}" "逆序"

  graph_build git-cli git
  assert_eq "git" "$(graph_dependents git-cli | tr '\n' ' ' | sed 's/ $//')" "被依赖者"

  local rc
  catalog_reset
  register_config_tool ga cyc; CAT_DEPS[ga]=gb; register_config_tool gb cyc; CAT_DEPS[gb]=ga
  graph_build ga >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "循环依赖报错"

  catalog_reset
  register_config_tool gx cyc; CAT_DEPS[gx]=nope
  graph_build gx >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "未知依赖报错"
}

# ===========================================================================
# 5. state
# ===========================================================================
test_state() {
  state_init
  assert_file_exists "$STATE_FILE" "state 清单创建"
  assert_eq 600 "$(stat -c '%a' "$STATE_FILE")" "清单权限 600"

  state_record foo action1 a b
  assert_eq "a
b" "$(state_artifacts foo)" "artifacts 记录"
  assert_true "state_has" state_has foo

  state_record foo action2
  assert_eq "" "$(state_artifacts foo)" "无产物记录清空 artifacts"
  assert_contains "$(cat "$STATE_FILE")" "foo|action2|-" "无产物占位 '-'"

  state_forget foo
  assert_false "forget 后无记录" state_has foo

  local d; d="$(state_action_dir ssh)"
  assert_eq 700 "$(stat -c '%a' "$d")" "动作私有目录权限"
}

# ===========================================================================
# 6. rollback（每个用例独立子 shell）
# ===========================================================================
test_rollback_restore() {
  local f="$TESTDIR/f"
  printf 'old' >"$f"
  register_rollback "$f" || not_ok "注册失败"
  printf 'new' >"$f"
  rollback_on_exit 1
  assert_eq old "$(cat "$f")" "失败时恢复原文件"
}

test_rollback_delete_new() {
  local f="$TESTDIR/new"
  register_rollback "$f" || not_ok "注册失败"
  printf 'created' >"$f"
  rollback_on_exit 1
  assert_file_missing "$f" "失败时删除新建文件"
}

test_rollback_dedup() {
  local f="$TESTDIR/f"
  printf 'old' >"$f"
  register_rollback "$f"
  register_rollback "$f"
  assert_eq 1 "${#_ROLLBACK_ORIG[@]}" "同文件只备份一次"
}

test_rollback_bad_mode() {
  local f="$TESTDIR/f"; : >"$f"
  local rc
  register_rollback "$f" bogus; rc=$?
  assert_rc_eq 2 "$rc" "非法备份模式"
}

test_rollback_success_noop() {
  local f="$TESTDIR/f"
  printf 'old' >"$f"
  register_rollback "$f"
  printf 'new' >"$f"
  rollback_on_exit 0
  assert_eq new "$(cat "$f")" "成功时不回滚"
}

test_rollback_tmpfile_cleanup() {
  local f="$TESTDIR/tmp"; : >"$f"
  register_tmpfile "$f"
  rollback_on_exit 1
  assert_file_missing "$f" "临时文件清理"
}

test_rollback_state_snapshot() {
  state_init
  state_record keep act1 /tmp/keep
  state_snapshot
  state_record newtool act2 /tmp/new
  rollback_on_exit 1
  assert_true "回滚后保留运行前清单记录" state_has keep
  assert_false "回滚后清除本次新增记录" state_has newtool
  assert_file_missing "$STATE_RUN_BAK" "快照用后清理"
}

test_rollback_keepgoing_keeps_state() {
  state_init
  state_snapshot
  state_record kept act /tmp/x
  KEEP_GOING=1 rollback_on_exit 1
  KEEP_GOING=0
  assert_true "keep-going 保留本次清单记录" state_has kept
  assert_file_missing "$STATE_RUN_BAK" "keep-going 丢弃快照"
}

# ===========================================================================
# 7. util
# ===========================================================================
test_util() {
  assert_eq "abc" "$(util_trim '  abc  ')" "util_trim"
  printf 'hello world\n' >"$TESTDIR/ct";
  assert_true "file_contains 命中" file_contains "$TESTDIR/ct" 'wor'
  assert_false "file_contains 未命中" file_contains "$TESTDIR/ct" 'zzz'
  assert_true "cmd_exists bash" cmd_exists bash
  assert_false "cmd_exists 不存在" cmd_exists no-such-cmd-xyz

  validate_ipv4 192.168.1.1; assert_rc_eq 0 "$?" "合法 IPv4"
  validate_ipv4 999.1.1.1; assert_rc_eq 1 "$?" "越界 IPv4"
  validate_ipv4 1.2.3; assert_rc_eq 1 "$?" "段数不足"
  validate_ipv4 ""; assert_rc_eq 1 "$?" "空 IPv4"

  assert_eq 192.168.114.50 "$(detect_primary_ipv4)" "本机 IPv4 探测"
  assert_true "sudo 可用" sudo_available
  assert_true "require_sudo" require_sudo
}

test_with_retry() {
  cat >"$TESTDIR/flaky" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$TESTDIR/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$TESTDIR/count"
(( n >= 2 ))
EOF
  cat >"$TESTDIR/always" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TESTDIR/flaky" "$TESTDIR/always"

  local rc
  with_retry 3 0 -- "$TESTDIR/flaky" >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "重试后成功"
  assert_eq 2 "$(cat "$TESTDIR/count")" "重试次数"
  assert_contains "$(cat "$LOG_FILE")" "第 2 次尝试成功" "重试成功日志"

  with_retry 2 0 -- "$TESTDIR/always" >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "重试耗尽返回失败码"
  assert_contains "$(cat "$LOG_FILE")" "重试 2 次后仍失败" "重试失败日志"

  with_retry 2 0 true >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "缺少 -- 用法错误"
}

test_resolve_proxy_endpoint() {
  local rc
  unset PROXY_HOST PROXY_PORT
  resolve_proxy_endpoint; rc=$?
  assert_rc_eq 0 "$rc" "自动推导代理端点"
  assert_eq 192.168.114.1 "$RESOLVED_PROXY_HOST" "推导主机"
  assert_eq 7890 "$RESOLVED_PROXY_PORT" "推导端口"
  assert_eq "http://192.168.114.1:7890" "$RESOLVED_PROXY_URL" "推导 URL"
  assert_eq 192.168.114.50 "$PROXY_SOURCE_IP" "来源 IP"

  PROXY_HOST=10.0.0.5 PROXY_PORT=8888 resolve_proxy_endpoint; rc=$?
  assert_rc_eq 0 "$rc" "显式端点"
  assert_eq "http://10.0.0.5:8888" "$RESOLVED_PROXY_URL" "显式 URL"

  PROXY_HOST=10.0.0.5 PROXY_PORT=99999 resolve_proxy_endpoint; rc=$?
  assert_rc_eq 2 "$rc" "端口越界"
  PROXY_HOST=-bad PROXY_PORT=8080 resolve_proxy_endpoint; rc=$?
  assert_rc_eq 3 "$rc" "非法主机"
}

test_log_redact() {
  run_step_verbose "secret" bash -c \
    'echo "token=abc Authorization: Bearer xyz https://u:p@example.com sk-ant-api03-AbCdEf123456789 ghp_ABCDEFGHIJKLMNOP0123456789"' >/dev/null 2>&1
  local log; log="$(cat "$LOG_FILE")"
  assert_contains "$log" 'token=****' "token 脱敏"
  assert_contains "$log" 'Authorization: Bearer ****' "Bearer 脱敏"
  assert_contains "$log" 'https://****:****@' "URL 凭据脱敏"
  assert_contains "$log" 'sk-****' "裸 sk- 令牌脱敏"
  assert_not_contains "$log" 'sk-ant-api03-AbCdEf123456789' "原始 sk- 令牌不落盘"
  assert_not_contains "$log" 'ghp_ABCDEFGHIJKLMNOP0123456789' "原始 ghp_ 令牌不落盘"
  assert_not_contains "$log" 'xyz' "原始 token 不落盘"
  assert_not_contains "$log" 'u:p' "原始凭据不落盘"
  assert_eq 600 "$(stat -c '%a' "$LOG_FILE")" "日志权限 600"
}

# ===========================================================================
# 8. 后端适配器
# ===========================================================================
test_semver_commands_dispatch() {
  assert_eq 1.2.3 "$(semver_of 'v1.2.3-beta')" "semver 抽取"
  catalog_reset
  register_pkg_tool ok apt foo bash
  assert_rc_eq 0 "$?" "占位"
  local rc
  commands_verify ok >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "命令均可用"
  CAT_COMMANDS[ok]="bash no-such-cmd-xyz"
  commands_verify ok >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "命令缺失"

  catalog_reset
  register_pkg_tool bad brew x
  local out
  out=$(backend_dispatch install bad 2>&1); rc=$?
  assert_rc_eq 2 "$rc" "不支持的后端"
  assert_contains "$out" "不支持的 backend" "后端错误信息"

  catalog_reset
  register_pkg_tool a1 apt foo
  out=$(backend_dispatch frobnicate a1 2>&1); rc=$?
  assert_rc_eq 2 "$rc" "不支持的后端动词"
  assert_contains "$out" "不支持动词" "动词错误信息"
}

test_apt_backend() {
  catalog_reset
  register_pkg_tool aptfoo apt foo
  local rc out
  : >"$FAKE_APT_LOG"

  backend_dispatch install aptfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt install"
  assert_contains "$(cat "$FAKE_APT_LOG")" "-y install foo" "apt 安装命令"

  printf 'foo\n' >"$TESTDIR/apt-installed"
  : >"$FAKE_APT_LOG"
  backend_dispatch install aptfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt install 已装跳过"
  assert_eq "" "$(cat "$FAKE_APT_LOG")" "已装不再 apt-get"

  backend_dispatch update aptfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt update"
  assert_contains "$(cat "$FAKE_APT_LOG")" "-y install foo" "update 强制安装"

  backend_dispatch verify aptfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt verify 通过"
  out=$(backend_dispatch status aptfoo 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "apt status"
  assert_contains "$out" "已安装 1.2.3-1" "status 输出"

  : >"$FAKE_APT_LOG"
  backend_dispatch remove aptfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt remove"
  assert_contains "$(cat "$FAKE_APT_LOG")" "-y remove foo" "apt 卸载命令"

  : >"$TESTDIR/apt-installed"
  : >"$FAKE_APT_LOG"
  backend_dispatch verify aptfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "apt verify 未装失败"

  catalog_reset
  register_pkg_tool aptpin apt foo "" "1.2.3-1" pin
  : >"$FAKE_APT_LOG"
  backend_dispatch install aptpin >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt pin 安装"
  assert_contains "$(cat "$FAKE_APT_LOG")" "foo=1.2.3-1" "pin 版本锁定"

  # pin 已装且版本一致（假 dpkg 版本固定为 1.2.3-1）：跳过且 verify 通过
  printf 'foo\n' >"$TESTDIR/apt-installed"
  : >"$FAKE_APT_LOG"
  backend_dispatch install aptpin >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt pin 版本一致跳过"
  assert_eq "" "$(cat "$FAKE_APT_LOG")" "pin 版本一致不再 apt-get"
  backend_dispatch verify aptpin >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt pin verify 版本匹配"

  # pin 版本不一致：install 仍强制安装，verify 判失败
  catalog_reset
  register_pkg_tool aptpin2 apt foo "" "9.9.9" pin
  printf 'foo\n' >"$TESTDIR/apt-installed"
  : >"$FAKE_APT_LOG"
  backend_dispatch install aptpin2 >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apt pin 版本不符仍安装"
  assert_contains "$(cat "$FAKE_APT_LOG")" "foo=9.9.9" "pin 版本不符重新安装"
  backend_dispatch verify aptpin2 >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "apt pin verify 版本不符失败"
}

test_npm_backend() {
  catalog_reset
  register_pkg_tool npmfoo npm foo foo "" pin
  CAT_VERSION[npmfoo]="1.2.3"
  local rc

  : >"$FAKE_NPM_LOG"
  backend_dispatch install npmfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "npm install"
  assert_file_exists "$FAKE_NPM_PREFIX/bin/foo" "npm 生成命令"
  assert_contains "$(cat "$FAKE_NPM_LOG")" "install" "npm 安装日志"

  backend_dispatch verify npmfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "npm verify 版本匹配"

  CAT_VERSION[npmfoo]="9.9.9"
  backend_dispatch verify npmfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "npm verify 版本不匹配"

  CAT_VERSION[npmfoo]="1.2.3"
  : >"$FAKE_NPM_LOG"
  backend_dispatch install npmfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "npm 已装跳过"
  assert_eq "" "$(cat "$FAKE_NPM_LOG")" "跳过时不重装"

  : >"$FAKE_NPM_LOG"
  backend_dispatch remove npmfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "npm remove"
  assert_file_missing "$FAKE_NPM_PREFIX/bin/foo" "npm 卸载命令"
}

test_snap_backend() {
  catalog_reset
  register_pkg_tool snapfoo snap foo
  local rc
  : >"$FAKE_SNAP_LOG"; : >"$TESTDIR/snap-installed"

  backend_dispatch install snapfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "snap install"
  assert_contains "$(cat "$FAKE_SNAP_LOG")" "install foo" "snap 安装日志"

  : >"$FAKE_SNAP_LOG"
  backend_dispatch install snapfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "snap 已装跳过"
  assert_eq "" "$(cat "$FAKE_SNAP_LOG")" "已装不再 install"

  backend_dispatch update snapfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "snap update"
  assert_contains "$(cat "$FAKE_SNAP_LOG")" "refresh foo" "snap refresh"

  backend_dispatch verify snapfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "snap verify"
  assert_contains "$(backend_dispatch status snapfoo 2>&1)" "已安装" "snap status"

  backend_dispatch remove snapfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "snap remove"
  backend_dispatch verify snapfoo >/dev/null 2>&1; rc=$?
  assert_rc_eq 1 "$rc" "移除后 verify 失败"
}

# ===========================================================================
# 9. 引擎编排
# ===========================================================================
_install_testfake_actions() {
  _ACTION_SOURCED[testfake]=1
  action_testfake_apply()  { printf 'applied\n'  >>"$TESTDIR/marker"; }
  action_testfake_remove() { printf 'removed\n'  >>"$TESTDIR/marker"; }
  action_testfake_verify() { printf 'verified\n' >>"$TESTDIR/marker"; }
}

test_engine_config_apply() {
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  local rc
  engine_run install testfake >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "config install"
  assert_contains "$(cat "$TESTDIR/marker")" applied "动作被调用"
  assert_true "install 落清单" state_has testfake
}

test_engine_config_remove() {
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  local rc
  engine_run remove testfake >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "config remove"
  assert_contains "$(cat "$TESTDIR/marker")" removed "remove 动作被调用"
  assert_false "remove 清清单" state_has testfake
}

test_engine_dry_run() {
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  local out rc
  DRY_RUN=1
  out=$(engine_run install testfake 2>&1); rc=$?
  DRY_RUN=0
  assert_rc_eq 0 "$rc" "dry-run 返回 0"
  assert_contains "$out" "dry-run" "dry-run 提示"
  assert_file_missing "$TESTDIR/marker" "dry-run 不产生写操作"
}

test_engine_nosudo_skip() {
  catalog_reset
  register_config_tool testfake testfake
  CAT_SUDO[testfake]=1
  _install_testfake_actions
  local out rc
  NO_SUDO=1
  out=$(engine_run install testfake 2>&1); rc=$?
  NO_SUDO=0
  assert_rc_eq 0 "$rc" "no-sudo 跳过不算失败"
  assert_contains "$out" "跳过" "no-sudo 提示"
  assert_file_missing "$TESTDIR/marker" "跳过时不执行动作"
}

test_engine_failure() {
  catalog_reset
  register_config_tool testfail testfail
  _ACTION_SOURCED[testfail]=1
  action_testfail_apply() { return 1; }
  local out rc
  out=$(engine_run install testfail 2>&1); rc=$?
  assert_rc_eq 1 "$rc" "动作失败使引擎返回 1"
  assert_contains "$out" "失败：testfail" "失败汇总"
}

test_engine_keepgoing() {
  catalog_reset
  register_config_tool testfail testfail
  register_config_tool testfake testfake
  _install_testfake_actions
  _ACTION_SOURCED[testfail]=1
  action_testfail_apply() { return 1; }
  local out rc
  KEEP_GOING=1
  out=$(engine_run install testfail testfake 2>&1); rc=$?
  KEEP_GOING=0
  assert_rc_eq 1 "$rc" "keep-going 失败仍返回非零"
  assert_contains "$out" "已跑完其余工具" "keep-going 提示"
  assert_contains "$(cat "$TESTDIR/marker" 2>/dev/null || true)" applied "失败后仍执行后续"
}

test_engine_remove_dependents_warning() {
  catalog_reset
  register_config_tool depbase testfake
  register_config_tool depchild testfake
  CAT_DEPS[depchild]=depbase
  _install_testfake_actions
  local out rc
  out=$(engine_run remove depchild 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "remove 成功"
  assert_contains "$out" "[depbase] 被以下项依赖，它们将先于本项删除：depchild" "remove 连带依赖提示"
}

test_engine_status_fallback() {
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  local out rc
  out=$(engine_run status testfake 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "status 返回 0"
  assert_contains "$out" "config:testfake" "status 回退输出"
}

test_engine_missing_action() {
  catalog_reset
  register_config_tool testmiss noact
  local out rc
  out=$(engine_run install testmiss 2>&1); rc=$?
  assert_rc_eq 1 "$rc" "动作脚本缺失失败"
  assert_contains "$out" "动作脚本不存在" "缺失动作提示"
}

test_engine_unknown_verb() {
  catalog_reset
  register_config_tool testfake testfake
  local out rc
  out=$(engine_run frobnicate testfake 2>&1); rc=$?
  assert_rc_eq 2 "$rc" "未知动词"
  assert_contains "$out" "未知动词" "未知动词提示"
}

# ===========================================================================
# 10. 动作脚本
# ===========================================================================
test_action_interface() {
  local f name
  for f in "$ROOT"/engine/actions/*.sh; do
    name="$(basename "$f" .sh)"
    # shellcheck disable=SC1090
    . "$f"
    assert_true "$name: apply" declare -F "action_${name}_apply"
    assert_true "$name: remove" declare -F "action_${name}_remove"
    assert_true "$name: verify" declare -F "action_${name}_verify"
  done
}

test_action_mirrors_helpers() {
  . "$ROOT/engine/actions/mirrors.sh"
  printf 'arm64\n' >"$TESTDIR/dpkg-arch"
  assert_contains "$(_mirrors_url_for_arch)" "ubuntu-ports" "arm64 使用 ports 源"
  printf 'amd64\n' >"$TESTDIR/dpkg-arch"
  assert_true "amd64 海外源正则命中" grep -qE "$(_mirrors_origin_re)" <<<"http://archive.ubuntu.com/ubuntu"
  assert_false "amd64 正则不误伤国内镜像" grep -qE "$(_mirrors_origin_re)" <<<"https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
}

test_action_nodejs_defaults() {
  . "$ROOT/engine/actions/nodejs.sh"
  local rc
  NODE_LTS_MAJOR=22 NODE_VERSION= _nodejs_defaults >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "nodejs 默认参数"
  NODE_LTS_MAJOR=abc _nodejs_defaults >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "nodejs 非法主版本"
  NODE_LTS_MAJOR=22 NODE_VERSION=1.2 _nodejs_defaults >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "nodejs 非法完整版本"
}

test_action_nosuspend_helpers() {
  . "$ROOT/engine/actions/nosuspend.sh"
  local rc
  unset XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS
  _nosuspend_has_gnome_session; rc=$?
  assert_rc_eq 1 "$rc" "无 GNOME 会话"
  XDG_CURRENT_DESKTOP=GNOME DBUS_SESSION_BUS_ADDRESS=unix:path=x _nosuspend_has_gnome_session; rc=$?
  assert_rc_eq 0 "$rc" "有 GNOME 会话"
}

test_action_ssh() {
  . "$ROOT/engine/actions/ssh.sh"
  local rc
  SSH_KEY_TYPE=bogus _ssh_key_type >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "非法密钥类型"
  action_ssh_apply ssh >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "ssh apply"
  assert_file_exists "$HOME/.ssh/id_ed25519" "私钥生成"
  assert_eq 600 "$(stat -c '%a' "$HOME/.ssh/id_ed25519")" "私钥权限"
  action_ssh_verify ssh >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "ssh verify"
  action_ssh_remove ssh >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "ssh remove"
  assert_file_missing "$HOME/.ssh/id_ed25519" "remove 删除自建密钥"
}

test_action_proxy() {
  . "$ROOT/engine/actions/proxy.sh"
  local rc bashrc="$HOME/.bashrc"

  PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    NO_PROXY='localhost,127.0.0.1' action_proxy_apply proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "proxy apply"
  assert_file_exists "$bashrc" "proxy 块写入 .bashrc"
  assert_contains "$(cat "$bashrc")" 'http://127.0.0.1:7890' "写入解析后的代理 URL"
  assert_eq 1 "$(grep -cF "$_PROXY_BEGIN" "$bashrc")" "仅一个托管块"

  # 幂等：参数不变时不追加第二个块
  local before after
  before=$(cat "$bashrc")
  PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    NO_PROXY='localhost,127.0.0.1' action_proxy_apply proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "proxy 重复 apply"
  after=$(cat "$bashrc")
  assert_eq "$before" "$after" "参数不变时幂等不重写"

  # update 生效：端口变化时重写，且不残留旧块
  PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7891 \
    NO_PROXY='localhost,127.0.0.1' action_proxy_apply proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "proxy 参数变化后 apply"
  assert_contains "$(cat "$bashrc")" 'http://127.0.0.1:7891' "新代理 URL 已写入"
  assert_not_contains "$(cat "$bashrc")" '7890' "旧代理 URL 已移除"
  assert_eq 1 "$(grep -cF "$_PROXY_BEGIN" "$bashrc")" "重写后仍仅一个托管块"

  PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7891 \
    action_proxy_verify proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "proxy verify"

  action_proxy_remove proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "proxy remove"
  assert_not_contains "$(cat "$bashrc" 2>/dev/null)" "$_PROXY_BEGIN" "remove 删除托管块"

  # PROXY_ENABLED=false 时不写入
  PROXY_ENABLED=false action_proxy_apply proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "禁用时 apply 返回 0"
  assert_not_contains "$(cat "$bashrc" 2>/dev/null)" "$_PROXY_BEGIN" "禁用时不写入块"
}

# ===========================================================================
# 11. setup.sh 入口
# ===========================================================================
test_entry() {
  local out rc
  out=$(bash "$ROOT/setup.sh" --list 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "--list 返回 0"
  assert_contains "$out" "工具目录" "--list 工具表"
  assert_contains "$out" "配置清单" "--list profile 表"

  out=$(bash "$ROOT/setup.sh" --help 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "--help 返回 0"

  bash "$ROOT/setup.sh" --nope >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "未知参数返回 2"
  bash "$ROOT/setup.sh" frobnicate >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "未知动词返回 2"
  bash "$ROOT/setup.sh" --profile minimal --pick git >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "选择互斥返回 2"
  bash "$ROOT/setup.sh" --pick no-such-tool --dry-run >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "未知工具返回 2"
  bash "$ROOT/setup.sh" --profile no-such-profile --dry-run >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "未知 profile 返回 2"

  out=$(bash "$ROOT/setup.sh" --dry-run --pick git 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "dry-run 返回 0"
  assert_contains "$out" "dry-run" "dry-run 提示"

  out=$(bash "$ROOT/setup.sh" --all --dry-run 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "--all dry-run 返回 0"

  out=$(bash "$ROOT/setup.sh" status --pick git-cli 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "status 返回 0"
}

# ===========================================================================
run_test '所有 Shell 脚本语法'                         test_syntax
run_test '真实 catalog 加载与关键字段'                 test_catalog_real
run_test 'catalog 变量展开'                            test_catalog_expand_vars
run_test 'catalog artifacts 展开'                      test_catalog_artifacts
run_test 'catalog 非法输入拒绝'                        test_catalog_reject
run_test 'catalog adhoc 注册与幂等'                    test_catalog_adhoc
run_test 'profile 加载、顺序与 tokens'                 test_profile_basic
run_test 'profile 解析数量（minimal/ai/default/dev）'  test_profile_resolve_counts
run_test 'profile 内联 backend:spec 与 @分组'          test_profile_inline
run_test 'profile 错误路径'                            test_profile_errors
run_test '依赖闭包拓扑与逆序'                          test_graph
run_test 'state 清单读写与权限'                        test_state
run_test 'rollback 恢复原文件'                         test_rollback_restore
run_test 'rollback 删除新建文件'                       test_rollback_delete_new
run_test 'rollback 同文件去重'                         test_rollback_dedup
run_test 'rollback 非法模式'                           test_rollback_bad_mode
run_test 'rollback 成功时不动作'                       test_rollback_success_noop
run_test 'rollback 清理临时文件'                       test_rollback_tmpfile_cleanup
run_test 'rollback 同步 state 清单'                    test_rollback_state_snapshot
run_test 'rollback keep-going 保留清单'                test_rollback_keepgoing_keeps_state
run_test 'util 基础与 IPv4/sudo'                       test_util
run_test 'with_retry 成功/耗尽/用法'                   test_with_retry
run_test '代理端点推导与校验'                          test_resolve_proxy_endpoint
run_test '日志脱敏与权限'                              test_log_redact
run_test 'semver/命令校验/后端分派错误'                test_semver_commands_dispatch
run_test 'apt 后端五动词与 pin'                        test_apt_backend
run_test 'npm 后端五动词与版本'                        test_npm_backend
run_test 'snap 后端五动词'                             test_snap_backend
run_test 'engine config install'                       test_engine_config_apply
run_test 'engine config remove'                        test_engine_config_remove
run_test 'engine dry-run 不写盘'                       test_engine_dry_run
run_test 'engine no-sudo 跳过'                         test_engine_nosudo_skip
run_test 'engine 失败汇总返回 1'                       test_engine_failure
run_test 'engine keep-going 返回非零'                   test_engine_keepgoing
run_test 'engine remove 连带依赖提示'                   test_engine_remove_dependents_warning
run_test 'engine status 回退'                          test_engine_status_fallback
run_test 'engine 动作脚本缺失'                         test_engine_missing_action
run_test 'engine 未知动词'                             test_engine_unknown_verb
run_test '动作脚本接口完整性'                          test_action_interface
run_test 'mirrors 辅助函数'                            test_action_mirrors_helpers
run_test 'nodejs 默认参数校验'                         test_action_nodejs_defaults
run_test 'nosuspend 会话判断'                          test_action_nosuspend_helpers
run_test 'ssh 密钥生成/校验/移除'                      test_action_ssh
run_test 'proxy 写入/幂等/重写/移除'                   test_action_proxy
run_test 'setup.sh 入口参数与 dry-run'                 test_entry

printf '\n总计：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
