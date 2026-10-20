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
NODE_BIN="$(command -v node || true)"
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
  . "$ROOT/engine/lib/events.sh"
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
  if (( leading )); then
    case "$1" in
      -n|-v|-E|--|-H|-S|-k) shift; continue ;;
    esac
    if [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "$1"; shift; continue
    fi
    # 与真实 sudo 一致：遇到命令后不再解析 sudo 自己的选项，
    # 后续参数（如 sed -E）原样传给命令。
    leading=0
  fi
  args+=("$1"); shift
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
  bash -n "$ROOT/ui.sh" 2>/dev/null || { rc=1; not_ok "语法错误：ui.sh"; }
  python3 -m py_compile "$ROOT"/ui/*.py 2>/dev/null || { rc=1; not_ok "Python 语法错误：ui/*.py"; }
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
  catalog_expect 1 '[foo]' 'type=config' 'action=../evil'
  catalog_expect 1 '[foo]' 'type=config' 'action=a/b'
  catalog_expect 1 '[foo]' 'type=config' 'action=-rf'
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
  catalog_define_adhoc mytool apt mytool "" || not_ok "重复注册相同 adhoc 应成功"
  assert_eq 1 "${#CAT_ORDER[@]}" "adhoc 幂等不重复"
  assert_eq apt "${CAT_BACKEND[mytool]}" "adhoc 幂等不改写"
  local rc
  catalog_define_adhoc mytool npm other ""; rc=$?
  assert_rc_eq 1 "$rc" "adhoc 冲突时返回非零"
  assert_eq apt "${CAT_BACKEND[mytool]}" "adhoc 冲突时不改写 backend"
  assert_eq mytool "${CAT_PACKAGES[mytool]}" "adhoc 冲突时不改写 packages"
  catalog_define_adhoc 'Bad' apt x ""; rc=$?
  assert_rc_eq 1 "$rc" "非法 adhoc id"
}

test_catalog_adhoc_rejects_unsafe_spec() {
  catalog_reset
  local rc
  catalog_define_adhoc unsafe apt 'foo --option' ""; rc=$?
  assert_rc_eq 1 "$rc" "拒绝含空格的包名（避免被拆成多个参数）"
  catalog_define_adhoc unsafe apt '--option' ""; rc=$?
  assert_rc_eq 1 "$rc" "拒绝以 - 开头的包名（避免参数注入）"
  catalog_define_adhoc scope npm '@scope/pkg' ""; rc=$?
  assert_rc_eq 0 "$rc" "允许 npm 作用域包"
  catalog_define_adhoc pinned apt 'pkg=1.2.3~rc1' ""; rc=$?
  assert_rc_eq 0 "$rc" "允许版本约束字符"
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
  resolve_inline 'apt:git'; rc=$?; assert_rc_eq 1 "$rc" "内联 id 与 config 工具冲突时报错"

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

test_state_action_dir_mkdir_failure() {
  local blocker="$TESTDIR/blocker" out rc
  : >"$blocker"
  STATE_DIR="$blocker/state"
  out="$(state_action_dir foo)"; rc=$?
  assert_ne 0 "$rc" "mkdir 失败时返回非零"
  assert_eq "" "$out" "失败时不输出目录路径"
}

test_state_record_write_failure() {
  local blocker="$TESTDIR/blocker" rc
  : >"$blocker"
  STATE_DIR="$blocker/state"
  state_record foo act; rc=$?
  assert_ne 0 "$rc" "写入清单失败时返回非零"
}

test_state_forget_replace_failure() {
  local rc tmpd="$TESTDIR/mvtmp"
  state_init
  state_record foo act /tmp/x
  mkdir -p "$TESTDIR/fakebin" "$tmpd"
  cat >"$TESTDIR/fakebin/mv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TESTDIR/fakebin/mv"
  ( export TMPDIR="$tmpd" PATH="$TESTDIR/fakebin:$PATH"; state_forget foo ); rc=$?
  assert_ne 0 "$rc" "清单替换失败时返回非零"
  assert_true "替换失败时保留原记录" state_has foo
  assert_eq "" "$(ls -A "$tmpd")" "替换失败时清理临时文件"
}

test_state_forget_grep_failure_keeps_manifest() {
  local rc tmpd="$TESTDIR/greptmp"
  state_init
  state_record foo act /tmp/x
  state_record bar act /tmp/y
  local before; before="$(cat "$STATE_FILE")"
  mkdir -p "$TESTDIR/fakebin" "$tmpd"
  cat >"$TESTDIR/fakebin/grep" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$TESTDIR/fakebin/grep"
  ( export TMPDIR="$tmpd" PATH="$TESTDIR/fakebin:$PATH"; state_forget foo ); rc=$?
  assert_ne 0 "$rc" "grep 失败时返回非零"
  assert_eq "$before" "$(cat "$STATE_FILE")" "grep 失败时清单未被清空"
  assert_eq "" "$(ls -A "$tmpd")" "grep 失败时清理临时文件"
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

test_rollback_verify_noop() {
  state_init
  state_record keep act1 /tmp/keep
  state_snapshot
  state_record verifynew act2 /tmp/new
  local f="$TESTDIR/f" ev="$TESTDIR/events.jsonl"
  printf 'old' >"$f"
  register_rollback "$f"
  printf 'new' >"$f"
  : >"$ev"
  VERB=verify OS_CONFIG_EVENTS="$ev" rollback_on_exit 1
  assert_eq new "$(cat "$f")" "verify 失败不回滚文件"
  assert_true "verify 失败保留清单记录" state_has verifynew
  assert_file_missing "$STATE_RUN_BAK" "verify 失败丢弃快照"
  assert_not_contains "$(cat "$ev")" '"event":"rollback"' "verify 失败不发 rollback 事件"
  assert_eq 0 "${_ROLLBACK_PERFORMED:-0}" "verify 不回滚标记"
}

test_rollback_readonly_keeps_foreign_snapshot() {
  state_init
  state_record keep act1 /tmp/keep
  # 模拟另一个写运行正在使用的快照：本进程从未调用 state_snapshot，不拥有它。
  printf 'tool|action|/tmp/x|2026-01-01T00:00:00\n' >"$STATE_RUN_BAK"
  local before; before="$(cat "$STATE_RUN_BAK")"

  rollback_on_exit 0
  assert_file_exists "$STATE_RUN_BAK" "成功退出不删除他人快照"
  assert_eq "$before" "$(cat "$STATE_RUN_BAK")" "成功退出不改写他人快照"

  _ROLLBACK_DONE=0
  VERB=verify rollback_on_exit 1
  assert_file_exists "$STATE_RUN_BAK" "verify 失败不删除他人快照"
  assert_eq "$before" "$(cat "$STATE_RUN_BAK")" "verify 失败不改写他人快照"

  _ROLLBACK_DONE=0
  VERB=install rollback_on_exit 1
  assert_file_exists "$STATE_RUN_BAK" "失败退出不删除他人快照"
  assert_eq "$before" "$(cat "$STATE_RUN_BAK")" "失败退出不改写他人快照"
  assert_true "他人快照未被用于回滚清单" state_has keep
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

test_util_mktemp() {
  local f rc
  f="$(util_mktemp '测试临时文件')"; rc=$?
  assert_rc_eq 0 "$rc" "正常创建临时文件"
  assert_file_exists "$f" "返回可用路径"
  rm -f -- "$f"
  # 环境前缀不会作用于赋值里的命令替换，需显式导出。
  export TMPDIR="$TESTDIR/no-such-tmpdir"
  f="$(util_mktemp '测试临时文件')"; rc=$?
  unset TMPDIR
  assert_ne 0 "$rc" "mktemp 失败返回非零"
  assert_eq "" "$f" "失败时不输出路径"
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

# 日志目录不可写时应降级为仅终端输出，而不是让每次日志都向 stderr 抛重定向错误。
test_log_unwritable_degrades_to_terminal() {
  local blocker="$TESTDIR/blocker" out rc
  : >"$blocker"
  out="$(LOG_FILE="$blocker/nested/run.log" bash -c '
    . "$1/engine/lib/log.sh"
    log_info "still-visible"
    printf "LOG_FILE=[%s]\n" "${LOG_FILE-<unset>}"
    printf "LOG_PATH=[%s]\n" "$(log_path)"
  ' _ "$ROOT" 2>&1)"; rc=$?
  assert_rc_eq 0 "$rc" "日志初始化失败不中止"
  assert_contains "$out" "still-visible" "日志仍输出到终端"
  assert_contains "$out" "无法写入日志文件" "给出一次性警告"
  assert_contains "$out" "LOG_FILE=[]" "禁用落盘日志"
  assert_contains "$out" "LOG_PATH=[<未落盘>]" "日志路径有可读占位"
  assert_not_contains "$out" "No such file or directory" "不产生重定向噪声"
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

test_npm_install_mktemp_failure_aborts() {
  local rc
  : >"$FAKE_NPM_LOG"
  TMPDIR="$TESTDIR/no-such-tmpdir" \
    npm_install_global_fixed somepkg latest "" >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "mktemp 失败时 npm 安装返回非零"
  assert_not_contains "$(cat "$FAKE_NPM_LOG")" "install" "mktemp 失败时不执行 npm install"
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

test_snap_update_installs_missing_package() {
  catalog_reset
  register_pkg_tool snapmulti snap 'foo bar'
  local rc
  : >"$FAKE_SNAP_LOG"
  printf 'foo\n' >"$TESTDIR/snap-installed"

  backend_dispatch update snapmulti >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "snap update 部分已装时成功"
  assert_contains "$(cat "$FAKE_SNAP_LOG")" "refresh foo" "已装包刷新"
  assert_contains "$(cat "$FAKE_SNAP_LOG")" "install bar" "缺失包补装"
  assert_contains "$(cat "$TESTDIR/snap-installed")" "bar" "缺失包标记已装"
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

test_action_git_remove_failure_reports_nonzero() {
  . "$ROOT/engine/actions/git.sh"
  local fakebin rc
  fakebin="$TMPROOT/gitfail"
  mkdir -p "$fakebin"
  cat >"$fakebin/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--get*) printf 'http://127.0.0.1:7890\n'; exit 0 ;;
  *--unset*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$fakebin/git"

  PATH="$fakebin:$PATH" action_git_remove git >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "unset 失败时 remove 返回非零"
}

test_action_git_apply_rolls_back_identity() {
  . "$ROOT/engine/actions/git.sh"
  local cfg="$HOME/.gitconfig" before rc
  printf '[user]\n\tname = Old\n' >"$cfg"
  before="$(cat "$cfg")"

  GIT_USER_NAME='New Name' GIT_USER_EMAIL='new@example.com' PROXY_ENABLED=false \
    action_git_apply git >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "身份写入成功"
  assert_contains "$(cat "$cfg")" 'New Name' "身份已写入"

  rollback_on_exit 1
  assert_eq "$before" "$(cat "$cfg")" "失败回滚还原 ~/.gitconfig"
}

test_action_git_remove_restores_original_proxy() {
  . "$ROOT/engine/actions/git.sh"
  local fakebin rc
  fakebin="$TMPROOT/gitstore"
  mkdir -p "$fakebin"
  cat >"$fakebin/git" <<'EOF'
#!/usr/bin/env bash
shift 2   # config --global
case "${1:-}" in
  --get)
    f="$TESTDIR/gitcfg-${2}"
    [[ -f "$f" ]] && { cat "$f"; exit 0; }
    exit 1 ;;
  --unset)
    rm -f "$TESTDIR/gitcfg-${2}"; exit 0 ;;
  *)
    printf '%s\n' "${2}" >"$TESTDIR/gitcfg-${1}"; exit 0 ;;
esac
EOF
  chmod +x "$fakebin/git"
  printf 'http://corp-proxy:8080\n' >"$TESTDIR/gitcfg-http.proxy"

  PATH="$fakebin:$PATH" PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    action_git_apply git >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "git apply"
  assert_eq 'http://127.0.0.1:7890' "$(cat "$TESTDIR/gitcfg-http.proxy")" "apply 写入新代理"

  PATH="$fakebin:$PATH" action_git_remove git >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "git remove"
  assert_eq 'http://corp-proxy:8080' "$(cat "$TESTDIR/gitcfg-http.proxy" 2>/dev/null)" "remove 还原原有代理"
  assert_file_missing "$TESTDIR/gitcfg-https.proxy" "remove 不重建原本不存在的键"
}

test_nodejs_npm_config_failure_aborts_apply() {
  . "$ROOT/engine/actions/nodejs.sh"
  local fakebin rc
  mkdir -p "$HOME/.nvm"
  cat >"$HOME/.nvm/nvm.sh" <<'EOF'
nvm() {
  case "${1:-}" in
    --version) printf '0.40.1\n' ;;
    version-remote) printf 'v22.0.0\n' ;;
    *) return 0 ;;
  esac
}
EOF

  fakebin="$TMPROOT/npmfail"
  mkdir -p "$fakebin"
  cat >"$fakebin/npm" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '10.0.0\n'; exit 0 ;;
  config)
    if [[ "${2:-}" == get ]]; then printf 'true\n'; exit 0; fi
    exit 1 ;;
esac
exit 0
EOF
  chmod +x "$fakebin/npm"

  PATH="$fakebin:$PATH" action_nodejs_apply nodejs >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "npm config set 失败时 apply 返回非零"
}

test_nodejs_mktemp_failure_skips_curl() {
  . "$ROOT/engine/actions/nodejs.sh"
  local fakebin rc marker="$TESTDIR/curl-called"
  rm -rf "$HOME/.nvm"; rm -f "$marker"
  fakebin="$TESTDIR/curlrec"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\n: >%s\nexit 0\n' "$marker" >"$fakebin/curl"
  chmod +x "$fakebin/curl"

  TMPDIR="$TESTDIR/no-such-tmpdir" PATH="$fakebin:$PATH" \
    action_nodejs_apply nodejs >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "mktemp 失败时 apply 返回非零"
  assert_file_missing "$marker" "mktemp 失败时不调用 curl"
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

test_action_ssh_remove_failure_keeps_record() {
  . "$ROOT/engine/actions/ssh.sh"
  action_ssh_apply ssh >/dev/null 2>&1
  local rc dir list fakebin real_rm
  dir="$STATE_DIR/actions/ssh"
  list="$dir/created.txt"
  assert_file_exists "$list" "apply 写入 created.txt"

  # 只让删除私钥失败，其余 rm 调用走真实命令
  fakebin="$TMPROOT/rmfail"
  mkdir -p "$fakebin"
  real_rm="$(command -v rm)"
  cat >"$fakebin/rm" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == "$HOME/.ssh/id_ed25519" ]] && exit 1
done
exec "$real_rm" "\$@"
EOF
  chmod +x "$fakebin/rm"

  PATH="$fakebin:$PATH" action_ssh_remove ssh >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "删除失败时 remove 返回非零"
  assert_file_exists "$list" "删除失败时保留记录以便重试"
  assert_file_exists "$HOME/.ssh/id_ed25519" "删除失败后私钥仍在"
}

test_action_ssh_apply_untracked_key_fails() {
  . "$ROOT/engine/actions/ssh.sh"
  local blocker="$TESTDIR/blocker" rc
  # 让 state_action_dir 失败：STATE_DIR 位于普通文件之下，mkdir -p 必然报错
  : >"$blocker"
  STATE_DIR="$blocker/state" action_ssh_apply ssh >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "记录失败时 apply 返回非零"
  assert_file_missing "$HOME/.ssh/id_ed25519" "记录失败后不留下未跟踪密钥"
}

test_action_mirrors_apply_escapes_replacement() {
  . "$ROOT/engine/actions/mirrors.sh"
  local src="$TESTDIR/ubuntu.sources" url rc
  url='https://mirror.example/ubuntu?a=1&b=2|c'
  printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble\n' >"$src"
  _mirrors_sources() { printf '%s\n' "$src"; }

  MIRROR_APT_URL="$url" MIRROR_APT_PORTS_URL="$url" \
    action_mirrors_apply mirrors >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apply 成功"
  assert_contains "$(cat "$src")" "URIs: $url" "URL 中的 & 和 | 按字面写入"
}

test_action_mirrors_remove_failure_keeps_backup() {
  . "$ROOT/engine/actions/mirrors.sh"
  local dir target base fakebin real_cp rc
  dir="$(state_action_dir mirrors)"
  target="$TESTDIR/sources.list"
  base="$(basename "$target")"
  printf 'original\n' >"$dir/$base"
  printf '%s\n' "$target" >"$dir/changed.txt"

  # 只让还原目标失败，其余 cp 调用走真实命令
  fakebin="$TMPROOT/cpfail"
  mkdir -p "$fakebin"
  real_cp="$(command -v cp)"
  cat >"$fakebin/cp" <<EOF
#!/usr/bin/env bash
dest="\${!#}"
[[ "\$dest" == "$target" ]] && exit 1
exec "$real_cp" "\$@"
EOF
  chmod +x "$fakebin/cp"

  PATH="$fakebin:$PATH" action_mirrors_remove mirrors >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "还原失败时 remove 返回非零"
  assert_file_exists "$dir/changed.txt" "还原失败时保留变更记录"
  assert_file_exists "$dir/$base" "还原失败时保留持久备份"
}

test_mirrors_durable_backup_failure_leaves_no_partial() {
  . "$ROOT/engine/actions/mirrors.sh"
  local dir target fakebin real_cat rc
  dir="$(state_action_dir mirrors)"
  target="$TESTDIR/sources.list"
  printf 'original\n' >"$target"

  # 只让备份读取失败，其余 cat 调用走真实命令
  fakebin="$TMPROOT/catfail"
  mkdir -p "$fakebin"
  real_cat="$(command -v cat)"
  cat >"$fakebin/cat" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == "$target" ]] && exit 1
done
exec "$real_cat" "\$@"
EOF
  chmod +x "$fakebin/cat"

  PATH="$fakebin:$PATH" _mirrors_durable_backup "$dir" "$target" >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "备份失败时返回非零"
  assert_file_missing "$dir/sources.list" "备份失败不留空备份"
}

test_action_syslog_remove_own_link_only() {
  . "$ROOT/engine/actions/syslog.sh"
  local link="$HOME/.local/bin/bat" rc
  # 避免触碰宿主 /etc
  _SYSLOG_DROPIN="$TESTDIR/journald.conf"
  mkdir -p "$(dirname "$link")"

  ln -s /opt/custom/bat "$link"
  action_syslog_remove syslog >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "remove 跳过非本动作软链"
  assert_true "非本动作创建的 bat 软链保留" test -L "$link"

  ln -sfn "$TESTDIR/bin/batcat" "$link"
  action_syslog_remove syslog >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "remove 清理本动作软链"
  assert_file_missing "$link" "指向 batcat 的软链被移除"
}

test_action_syslog_remove_missing_end_marker_refuses() {
  . "$ROOT/engine/actions/syslog.sh"
  local bashrc="$HOME/.bashrc" before rc
  # 避免触碰宿主 /etc
  _SYSLOG_DROPIN="$TESTDIR/journald.conf"
  {
    printf 'user line before\n'
    printf '%s\n' "$_SYSLOG_ALIAS_BEGIN"
    printf "alias oslogs='journalctl -e'\n"
    printf 'user line after\n'
  } >"$bashrc"
  before="$(cat "$bashrc")"

  action_syslog_remove syslog >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "缺少结束标记时拒绝删除"
  assert_eq "$before" "$(cat "$bashrc")" ".bashrc 未被改动"
}

test_action_syslog_mktemp_failure_aborts_before_write() {
  . "$ROOT/engine/actions/syslog.sh"
  local rc guard="$TESTDIR/install-called"
  # 避免触碰宿主 /etc
  _SYSLOG_DROPIN="$TESTDIR/journald.conf"
  mkdir -p "$TESTDIR/bin"
  printf '#!/usr/bin/env bash\ntouch %q\nexit 0\n' "$guard" >"$TESTDIR/bin/install"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TESTDIR/bin/logrotate"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TESTDIR/bin/systemctl"
  chmod +x "$TESTDIR/bin/install" "$TESTDIR/bin/logrotate" "$TESTDIR/bin/systemctl"
  rm -f -- "$guard" "$_SYSLOG_DROPIN"

  TMPDIR="$TESTDIR/no-such-tmpdir" PATH="$TESTDIR/bin:$PATH" \
    action_syslog_apply syslog >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "mktemp 失败时 apply 返回非零"
  assert_file_missing "$guard" "mktemp 失败时不执行 install"
  assert_file_missing "$_SYSLOG_DROPIN" "mktemp 失败时不写 drop-in"
}

test_action_syslog_apply_write_failure_reports_nonzero() {
  . "$ROOT/engine/actions/syslog.sh"
  local bashrc="$HOME/.bashrc" rc
  # 避免触碰宿主 /etc
  _SYSLOG_DROPIN="$TESTDIR/journald.conf"
  mkdir -p "$TESTDIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TESTDIR/bin/logrotate"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TESTDIR/bin/systemctl"
  chmod +x "$TESTDIR/bin/logrotate" "$TESTDIR/bin/systemctl"
  # 用目录占位，确保任何写入/复制都会失败（root 下也不受权限位影响）
  mkdir -p "$bashrc"

  PATH="$TESTDIR/bin:$PATH" action_syslog_apply syslog >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "无法写入 .bashrc 时 apply 返回非零"
}

test_action_proxy_remove_sed_failure_reports_nonzero() {
  . "$ROOT/engine/actions/proxy.sh"
  local bashrc="$HOME/.bashrc" fakebin real_sed rc
  PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    action_proxy_apply proxy >/dev/null 2>&1
  assert_true "apply 写入 proxy 块" grep -qF "$_PROXY_BEGIN" "$bashrc"

  # 只让删除托管块的 sed 调用失败，其余 sed（日志脱敏等）走真实命令
  fakebin="$TMPROOT/sedfail"
  mkdir -p "$fakebin"
  real_sed="$(command -v sed)"
  cat >"$fakebin/sed" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == *"proxy begin"* ]] && exit 1
done
exec "$real_sed" "\$@"
EOF
  chmod +x "$fakebin/sed"

  PATH="$fakebin:$PATH" action_proxy_remove proxy >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "sed 失败时 remove 返回非零"
  assert_true "删除失败时 proxy 块保留" grep -qF "$_PROXY_BEGIN" "$bashrc"
}

test_action_proxy_remove_missing_end_marker_refuses() {
  . "$ROOT/engine/actions/proxy.sh"
  local bashrc="$HOME/.bashrc" before rc
  {
    printf 'user line before\n'
    printf '%s\n' "$_PROXY_BEGIN"
    printf 'export HTTP_PROXY=http://127.0.0.1:7890\n'
    printf 'user line after\n'
  } >"$bashrc"
  before="$(cat "$bashrc")"

  action_proxy_remove proxy >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "缺少结束标记时拒绝删除"
  assert_eq "$before" "$(cat "$bashrc")" ".bashrc 未被改动"
}

test_action_proxy_apply_write_failure_reports_nonzero() {
  . "$ROOT/engine/actions/proxy.sh"
  local bashrc="$HOME/.bashrc" rc
  # 用目录占位，确保任何写入/复制都会失败（root 下也不受权限位影响）
  mkdir -p "$bashrc"

  PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    action_proxy_apply proxy >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "无法写入 .bashrc 时 apply 返回非零"
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

  rm -rf "$STATE_DIR"
  out=$(bash "$ROOT/setup.sh" --dry-run --pick git 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "dry-run 返回 0"
  assert_contains "$out" "dry-run" "dry-run 提示"
  assert_file_missing "$STATE_DIR/manifest.conf" "dry-run 不写状态清单"

  out=$(bash "$ROOT/setup.sh" --all --dry-run 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "--all dry-run 返回 0"

  out=$(bash "$ROOT/setup.sh" status --pick git-cli 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "status 返回 0"
}

test_setup_rejects_broken_profiles() {
  local bad="$TESTDIR/profiles-bad" rc
  mkdir -p "$bad"
  # 残缺文件：两个 profile 都已登记 tools，之后才遇到非法字段。
  # 若吞掉加载错误，profile 会带着部分数据继续执行。
  printf '[default]\ntools=git\n[p]\ntools=git\nbogus=1\n' >"$bad/broken.conf"
  PROFILES_DIR="$bad" bash "$ROOT/setup.sh" --profile p --dry-run >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "profile 解析失败时不执行残缺 profile"
  PROFILES_DIR="$bad" bash "$ROOT/setup.sh" --dry-run >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "无法加载 profiles 时默认选择失败"
  PROFILES_DIR="$bad" bash "$ROOT/setup.sh" --pick git --dry-run >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "--pick 不依赖 profiles"
}

test_events_json() {
  assert_eq 'a\"b\\c\nd\te' "$(json_escape $'a"b\\c\nd\te')" "JSON 转义"
  assert_eq '["a","b\"c"]' "$(json_string_array a 'b"c')" "字符串数组"
  assert_eq '[]' "$(json_string_array)" "空数组"
}

test_events_emit() {
  export OS_CONFIG_EVENTS="$TESTDIR/events.jsonl"
  : >"$OS_CONFIG_EVENTS"
  events_emit run_start '"verb":"install","ids":["a"]'
  events_emit item_end '"id":"a","status":"ok","rc":0'
  local out; out=$(python3 - "$OS_CONFIG_EVENTS" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8") if x.strip()]
assert len(rows)==2, rows
assert rows[0]["event"]=="run_start" and rows[0]["verb"]=="install"
assert rows[1]["id"]=="a" and rows[1]["status"]=="ok"
print("ok")
PY
)
  assert_eq ok "$out" "事件 JSONL 可解析"
  unset OS_CONFIG_EVENTS
  events_emit run_end '"rc":0'; assert_rc_eq 0 "$?" "未设置事件文件时静默"
  OS_CONFIG_EVENTS="/no/such/dir/x"; events_emit run_end '"rc":0'; assert_rc_eq 0 "$?" "写失败不影响流程"
  unset OS_CONFIG_EVENTS
}

test_ui_env_precedence() {
  mkdir -p "$TESTDIR/config"
  printf 'SAME=versions\nONLY_V=1\n' >"$TESTDIR/config/versions.env"
  printf 'SAME=user\nONLY_U=1\n'     >"$TESTDIR/config/user.env"
  printf "SAME=ui\nONLY_UI='a b'\n"   >"$TESTDIR/config/ui.env"
  local old_project="$PROJECT_DIR"
  PROJECT_DIR="$TESTDIR"
  unset _USER_CONFIG_LOADED
  load_user_config
  assert_eq ui "$SAME" "ui.env 覆盖 user.env"
  assert_eq 1 "$ONLY_V" "versions.env 仍生效"
  assert_eq 'a b' "$ONLY_UI" "ui.env 值解析"
  PROJECT_DIR="$old_project"
  unset SAME ONLY_V ONLY_U ONLY_UI _USER_CONFIG_LOADED
}

test_confirm_assume_yes() {
  ASSUME_YES=1 confirm "x"; assert_rc_eq 0 "$?" "ASSUME_YES 直接确认"
  ASSUME_YES=0 confirm "x" </dev/null; assert_rc_eq 1 "$?" "无输入默认拒绝"
  local out rc
  out=$(bash "$ROOT/setup.sh" --yes --profile minimal --dry-run 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "--yes 被接受"
}

test_remove_assume_yes() {
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  rm -f "$TESTDIR/marker"
  ASSUME_YES=1 engine_run remove testfake >/dev/null 2>&1
  assert_rc_eq 0 "$?" "ASSUME_YES 下 remove 不阻塞"
  assert_contains "$(cat "$TESTDIR/marker" 2>/dev/null)" "removed" "remove 动作被执行"
}

test_list_json() {
  local out rc
  out=$(bash "$ROOT/setup.sh" --list --json 2>/dev/null); rc=$?
  assert_rc_eq 0 "$rc" "--list --json 返回 0"
  local parsed
  parsed=$(python3 - "$out" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
assert len(d["catalog"])==56, len(d["catalog"])
by={x["id"]:x for x in d["catalog"]}
assert by["git"]["type"]=="config" and by["git"]["action"]=="git"
assert by["git"]["deps"]=="git-cli"
assert by["git"]["artifacts"][0].endswith("/.gitconfig")
assert isinstance(by["git"]["sudo"], bool)
profs={p["name"]:p for p in d["profiles"]}
assert set(profs)=={"ai","default","dev","minimal"}, profs.keys()
assert profs["default"]["extends"]=="minimal"
assert "mirrors" in profs["minimal"]["raw_tools"]
assert "@core" in profs["minimal"]["tokens"]
assert isinstance(profs["minimal"]["tools"], list)
assert len(profs["minimal"]["tools"])==7
assert len(profs["ai"]["tools"])==10
assert len(profs["default"]["tools"])==24
assert len(profs["dev"]["tools"])==52
assert profs["minimal"]["error"]==""
print("ok")
PY
)
  assert_eq ok "$parsed" "JSON 结构与计数"
  bash "$ROOT/setup.sh" --json >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "--json 必须配合 --list"
}

test_list_json_profile_mktemp_failure_reports_error() {
  local out parsed
  out="$(TMPDIR="$TESTDIR/no-such-tmpdir" bash "$ROOT/setup.sh" --list --json 2>/dev/null)"
  parsed=$(python3 - "$out" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
profs={p["name"]:p for p in d["profiles"]}
assert profs, "no profiles"
for p in profs.values():
    assert p["error"]=="无法创建临时文件", (p["name"], p["error"])
    assert p["tools"]==[], (p["name"], p["tools"])
print("ok")
PY
)
  assert_eq ok "$parsed" "mktemp 失败时 profile 报错且不返回部分结果"
}

test_ui_launcher() {
  local out rc
  out=$(bash "$ROOT/ui.sh" --help 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "ui.sh --help"
  assert_contains "$out" "用法" "ui.sh 帮助内容"
  bash "$ROOT/ui.sh" --port 0 </dev/null >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "非法端口返回 2"
  bash "$ROOT/ui.sh" --host 0.0.0.0 </dev/null >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "非本机 host 返回 2"
  bash "$ROOT/ui.sh" --nope </dev/null >/dev/null 2>&1; rc=$?
  assert_rc_eq 2 "$rc" "未知参数返回 2"
  # 端口已被占用时必须直接失败，不能连到别人的服务还打印成功地址。
  local port holder
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 - "$port" <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(30)
PY
  holder=$!
  sleep 0.3
  out=$(timeout 3 bash "$ROOT/ui.sh" --no-open --port "$port" </dev/null 2>&1); rc=$?
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  assert_rc_eq 1 "$rc" "端口占用返回 1"
  assert_contains "$out" "已被占用" "端口占用提示"

  # 服务自身异常退出时，ui.sh 必须如实返回其退出码，而不是吞成 0。
  local crashbin real_py
  real_py="$(command -v python3)"
  crashbin="$TESTDIR/crashbin"
  mkdir -p "$crashbin"
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  cat >"$TESTDIR/crash_server.py" <<'PY'
import socket, sys, time
args = sys.argv[1:]
port = int(args[args.index("--port") + 1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
time.sleep(0.5)
sys.exit(3)
PY
  cat >"$crashbin/python3" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-m" && "\${2:-}" == "ui.server" ]]; then
  exec "$real_py" "$TESTDIR/crash_server.py" "\${@:3}"
fi
exec "$real_py" "\$@"
EOF
  chmod +x "$crashbin/python3"
  out=$(PATH="$crashbin:$PATH" timeout 20 bash "$ROOT/ui.sh" --no-open --port "$port" </dev/null 2>&1); rc=$?
  assert_rc_eq 3 "$rc" "服务崩溃时返回真实退出码"
  assert_contains "$out" "已启动" "崩溃前已打印访问地址"
}

test_ui_ignores_and_docs() {
  local gi; gi="$(cat "$ROOT/.gitignore")"
  assert_contains "$gi" "config/ui.env" "忽略 ui.env"
  assert_contains "$gi" "state/ui/" "忽略 state/ui"
  assert_contains "$gi" "__pycache__/" "忽略 __pycache__"
  local rd; rd="$(cat "$ROOT/README.md")"
  assert_contains "$rd" "./ui.sh" "README 启动说明"
  assert_contains "$rd" "127.0.0.1" "README 绑定地址"
  assert_contains "$(bash "$ROOT/setup.sh" --help 2>&1)" "--yes" "usage 含 --yes"
  assert_contains "$(bash "$ROOT/setup.sh" --help 2>&1)" "--json" "usage 含 --json"
}

# ===========================================================================
# 10. 引擎结构化事件
# ===========================================================================
test_engine_events() {
  export OS_CONFIG_EVENTS="$TESTDIR/events.jsonl"; : >"$OS_CONFIG_EVENTS"
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  local rc
  engine_run install testfake >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "engine 成功"
  local out
  out=$(python3 - "$OS_CONFIG_EVENTS" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8") if x.strip()]
ev=[r["event"] for r in rows]
assert ev[0]=="run_start" and ev[1]=="item_start" and ev[2]=="item_end", ev
assert rows[0]["ids"]==["testfake"]
assert rows[1]["id"]=="testfake" and rows[1]["verb"]=="install" and rows[1]["phase"]=="install"
assert rows[2]["id"]=="testfake" and rows[2]["status"]=="ok" and rows[2]["rc"]==0
assert rows[2]["verb"]=="install" and rows[2]["phase"]=="install" and isinstance(rows[2]["type"],str)
print("ok")
PY
)
  assert_eq ok "$out" "事件顺序与字段"
  unset OS_CONFIG_EVENTS
}

test_engine_events_dryrun_planned() {
  export OS_CONFIG_EVENTS="$TESTDIR/events.jsonl"; : >"$OS_CONFIG_EVENTS"
  catalog_reset; register_config_tool testfake testfake; _install_testfake_actions
  DRY_RUN=1 engine_run install testfake >/dev/null 2>&1; DRY_RUN=0
  assert_contains "$(cat "$OS_CONFIG_EVENTS")" '"status":"planned"' "dry-run 标记 planned"
  unset OS_CONFIG_EVENTS
}

test_engine_events_rollback() {
  export OS_CONFIG_EVENTS="$TESTDIR/events.jsonl"; : >"$OS_CONFIG_EVENTS"
  local f="$TESTDIR/f"; printf old >"$f"
  register_rollback "$f"; printf new >"$f"
  rollback_on_exit 1
  local out
  out=$(python3 - "$OS_CONFIG_EVENTS" "$f" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8") if x.strip()]
rb=[r for r in rows if r["event"]=="rollback"]
assert len(rb)==1 and rb[0]["restored"]==[sys.argv[2]], rb
print("ok")
PY
)
  assert_eq ok "$out" "rollback 事件"
  assert_eq 1 "${_ROLLBACK_PERFORMED:-0}" "回滚标记"
  unset OS_CONFIG_EVENTS
}

test_setup_run_end() {
  local ev="$TESTDIR/events.jsonl"; : >"$ev"
  OS_CONFIG_EVENTS="$ev" bash "$ROOT/setup.sh" --profile minimal --dry-run >/dev/null 2>&1
  assert_contains "$(cat "$ev")" '"event":"run_end"' "setup 发出 run_end"
  assert_contains "$(cat "$ev")" '"rolled_back":false' "run_end 回滚字段"
}

test_ui_python_suite() {
  local out rc
  out=$(cd "$ROOT" && python3 -m unittest tests/test_ui_server.py 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "Python UI 测试通过"
  assert_contains "$out" "OK" "Python UI 测试输出 OK"
}

test_ui_node_suite() {
  local out rc
  if [[ -z "${NODE_BIN:-}" ]]; then
    printf 'node 不可用，跳过前端测试\n'
    ok
    return 0
  fi
  out=$(cd "$ROOT" && "$NODE_BIN" --test tests/test_app_js.js 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "Node 前端测试通过"
  assert_contains "$out" "# fail 0" "Node 前端测试无失败"
}

# ===========================================================================
run_test '所有 Shell 脚本语法'                         test_syntax
run_test '事件 JSON 转义'                              test_events_json
run_test '事件 JSONL 写入'                             test_events_emit
run_test 'ui.env 覆盖顺序'                             test_ui_env_precedence
run_test 'ASSUME_YES 非交互确认'                       test_confirm_assume_yes
run_test 'ASSUME_YES 卸载'                             test_remove_assume_yes
run_test '--list --json 结构'                          test_list_json
run_test '--list --json mktemp 失败仍结构化'            test_list_json_profile_mktemp_failure_reports_error
run_test 'engine 事件顺序与字段'                        test_engine_events
run_test 'engine dry-run planned 事件'                  test_engine_events_dryrun_planned
run_test 'engine rollback 事件'                         test_engine_events_rollback
run_test 'setup run_end 事件'                           test_setup_run_end
run_test '真实 catalog 加载与关键字段'                 test_catalog_real
run_test 'catalog 变量展开'                            test_catalog_expand_vars
run_test 'catalog artifacts 展开'                      test_catalog_artifacts
run_test 'catalog 非法输入拒绝'                        test_catalog_reject
run_test 'catalog adhoc 注册与幂等'                    test_catalog_adhoc
run_test 'catalog adhoc 拒绝不安全包名'                test_catalog_adhoc_rejects_unsafe_spec
run_test 'profile 加载、顺序与 tokens'                 test_profile_basic
run_test 'profile 解析数量（minimal/ai/default/dev）'  test_profile_resolve_counts
run_test 'profile 内联 backend:spec 与 @分组'          test_profile_inline
run_test 'profile 错误路径'                            test_profile_errors
run_test '依赖闭包拓扑与逆序'                          test_graph
run_test 'state 清单读写与权限'                        test_state
run_test 'state 目录创建失败时返回非零'                test_state_action_dir_mkdir_failure
run_test 'state 清单写入失败时返回非零'                test_state_record_write_failure
run_test 'state 清单替换失败时返回非零'                test_state_forget_replace_failure
run_test 'state grep 失败时不清空清单'                 test_state_forget_grep_failure_keeps_manifest
run_test 'rollback 恢复原文件'                         test_rollback_restore
run_test 'rollback 删除新建文件'                       test_rollback_delete_new
run_test 'rollback 同文件去重'                         test_rollback_dedup
run_test 'rollback 非法模式'                           test_rollback_bad_mode
run_test 'rollback 成功时不动作'                       test_rollback_success_noop
run_test 'rollback 清理临时文件'                       test_rollback_tmpfile_cleanup
run_test 'rollback 同步 state 清单'                    test_rollback_state_snapshot
run_test 'rollback keep-going 保留清单'                test_rollback_keepgoing_keeps_state
run_test 'rollback verify 失败不动作'                  test_rollback_verify_noop
run_test 'rollback 只读运行不碰他人快照'               test_rollback_readonly_keeps_foreign_snapshot
run_test 'util 基础与 IPv4/sudo'                       test_util
run_test '临时文件创建失败被检出'                        test_util_mktemp
run_test 'with_retry 成功/耗尽/用法'                   test_with_retry
run_test '代理端点推导与校验'                          test_resolve_proxy_endpoint
run_test '日志脱敏与权限'                              test_log_redact
run_test '日志不可写时降级为终端'                      test_log_unwritable_degrades_to_terminal
run_test 'semver/命令校验/后端分派错误'                test_semver_commands_dispatch
run_test 'apt 后端五动词与 pin'                        test_apt_backend
run_test 'npm 后端五动词与版本'                        test_npm_backend
run_test 'npm 安装 mktemp 失败不执行'                   test_npm_install_mktemp_failure_aborts
run_test 'snap 后端五动词'                             test_snap_backend
run_test 'snap update 补装缺失包'                      test_snap_update_installs_missing_package
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
run_test 'git remove 失败时返回非零'                   test_action_git_remove_failure_reports_nonzero
run_test 'git apply 身份可回滚'                        test_action_git_apply_rolls_back_identity
run_test 'git remove 还原原有代理'                     test_action_git_remove_restores_original_proxy
run_test 'nodejs npm 配置失败时 apply 失败'            test_nodejs_npm_config_failure_aborts_apply
run_test 'nodejs mktemp 失败时不下载脚本'               test_nodejs_mktemp_failure_skips_curl
run_test 'nosuspend 会话判断'                          test_action_nosuspend_helpers
run_test 'ssh 密钥生成/校验/移除'                      test_action_ssh
run_test 'ssh remove 失败时保留记录'                   test_action_ssh_remove_failure_keeps_record
run_test 'ssh 记录失败时不留下未跟踪密钥'               test_action_ssh_apply_untracked_key_fails
run_test 'mirrors remove 失败时保留备份'               test_action_mirrors_remove_failure_keeps_backup
run_test 'mirrors apply 转义替换串'                    test_action_mirrors_apply_escapes_replacement
run_test 'mirrors 备份失败不留空备份'                  test_mirrors_durable_backup_failure_leaves_no_partial
run_test 'syslog remove 只删自己的软链'                test_action_syslog_remove_own_link_only
run_test 'syslog remove 缺结束标记时拒绝删除'          test_action_syslog_remove_missing_end_marker_refuses
run_test 'syslog apply 写入失败时返回非零'             test_action_syslog_apply_write_failure_reports_nonzero
run_test 'syslog mktemp 失败时不写 drop-in'            test_action_syslog_mktemp_failure_aborts_before_write
run_test 'proxy 写入/幂等/重写/移除'                   test_action_proxy
run_test 'proxy remove 删除失败时返回非零'             test_action_proxy_remove_sed_failure_reports_nonzero
run_test 'proxy remove 缺结束标记时拒绝删除'           test_action_proxy_remove_missing_end_marker_refuses
run_test 'proxy apply 写入失败时返回非零'              test_action_proxy_apply_write_failure_reports_nonzero
run_test 'setup.sh 入口参数与 dry-run'                 test_entry
run_test 'setup 拒绝残缺 profiles'                     test_setup_rejects_broken_profiles
run_test 'ui.sh 启动器参数'                            test_ui_launcher
run_test 'Web UI 忽略规则与文档'                       test_ui_ignores_and_docs
run_test 'Web UI Python 单元测试'                      test_ui_python_suite
run_test 'Web UI Node 前端测试'                        test_ui_node_suite

printf '\n总计：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
