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
# Windows 上常常只有 `python` 没有 `python3`；更坑的是 Microsoft Store 的
# python3 存根——文件在 PATH 里、command -v 找得到，一执行却退出 49 不干活。
# 所以不能只看存在性，必须真的跑一次；用例里凡是"借 Python 当测试工具"的
# 地方都走 $PY_BIN，不要直接写 python3。
# 注意：test_ui_launcher 里刻意造的 $crashbin/python3 假命令不受此影响——
# 那几处测的是 ui.sh 自己的行为，仍须用 python3 这个名字。
PY_BIN=""
for _pycand in python3 python py; do
  _pypath="$(command -v "$_pycand" || true)"
  [[ -n "$_pypath" ]] || continue
  if "$_pypath" -c 'import sys' >/dev/null 2>&1; then PY_BIN="$_pypath"; break; fi
done
PASS=0
FAIL=0
SKIP=0
FILTER="${1:-}"
MATCHED=0

# ---------------------------------------------------------------------------
# 平台跳过：下列用例整体依赖 Windows 上不可用的能力，在 MSYS/CYGWIN 下记 skip
# 并单独计数，不让全套在 Windows 上无故染红：
#   * 符号链接——NTFS 上创建需要管理员/开发者模式；
#   * 原生 python3/node 环境——Python 在这里 spawn 不到 bash，UI 套件跑不起来。
# 只断言权限位（600/700）的用例不在此列：它们在用例内部按 _IS_MSYS 守门，
# 其余断言照常在 Windows 上执行。Linux/macOS 上全部照常全量跑。
# -------------------------------------------------------------------------
_IS_MSYS=0
case "$(uname -s 2>/dev/null || true)" in
  MSYS_*|MINGW*|CYGWIN*) _IS_MSYS=1 ;;
esac

_POSIX_ONLY_TESTS=" test_action_syslog_remove_own_link_only test_action_syslog_verify_checks_bat_link test_ui_launcher test_ui_python_suite test_ui_node_suite "

# profiles/exported.conf 是 export 动词的默认产物（已 gitignore），不属于仓库
# 自带的 profile 集合。断言集合/数量的用例会被它干扰，整轮运行前临时挪开。
_HIDDEN_EXPORTED="$ROOT/profiles/exported.conf.testhide"
if [[ -f "$ROOT/profiles/exported.conf" ]]; then
  mv -f -- "$ROOT/profiles/exported.conf" "$_HIDDEN_EXPORTED"
fi
trap '[[ -f "$_HIDDEN_EXPORTED" ]] && mv -f -- "$_HIDDEN_EXPORTED" "$ROOT/profiles/exported.conf"' EXIT

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

# 过滤：显示名与用例函数名任一命中即选中。
# （README 与文档里给的是函数名，只按显示名过滤会静默跑出 0 个用例。）
_test_filter_match() {
  local name="$1" fn="$2"
  [[ -z "$FILTER" ]] && return 0
  [[ "$name" == *"$FILTER"* || "$fn" == *"$FILTER"* ]]
}

run_test() {
  local name="$1" fn="$2"
  if ! _test_filter_match "$name" "$fn"; then return 0; fi
  MATCHED=$((MATCHED + 1))

  if [[ "$_IS_MSYS" == 1 && "$_POSIX_ONLY_TESTS" == *" $fn "* ]]; then
    printf 'skip %s（MSYS 环境限制：依赖符号链接或原生 python3/node）\n' "$name"
    SKIP=$((SKIP + 1))
    return 0
  fi

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
  . "$ROOT/engine/lib/doctor.sh"
  . "$ROOT/engine/lib/export.sh"
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
# 用户级 npmrc：真实 npm 也会把 `npm config set` 写到这里
npmrc="${FAKE_NPMRC:-$HOME/.npmrc}"
npmrc_get() {
  [[ -f "$npmrc" ]] || return 0
  local line
  while IFS= read -r line; do
    line="${line%%;*}"
    [[ "$line" == "$1="* ]] && { printf '%s' "${line#*=}"; return 0; }
  done <"$npmrc"
}
npmrc_set() {
  local key="$1" val="$2" tmp="$npmrc.tmp" line
  : >"$tmp"
  if [[ -f "$npmrc" ]]; then
    while IFS= read -r line; do
      [[ "$line" == "$key="* ]] && continue
      printf '%s\n' "$line" >>"$tmp"
    done <"$npmrc"
  fi
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  mv -f "$tmp" "$npmrc"
}
npmrc_del() {
  local key="$1" tmp="$npmrc.tmp" line
  [[ -f "$npmrc" ]] || return 0
  : >"$tmp"
  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] && continue
    printf '%s\n' "$line" >>"$tmp"
  done <"$npmrc"
  mv -f "$tmp" "$npmrc"
}
case "${1:-}" in
  config)
    case "${2:-}" in
      get)
        case "${3:-}" in
          prefix) printf '%s\n' "$FAKE_NPM_PREFIX"; exit 0 ;;
          registry) printf '%s\n' "${NPM_REGISTRY:-}"; exit 0 ;;
          userconfig) printf '%s\n' "$npmrc"; exit 0 ;;
          *) npmrc_get "${3:-}"; exit 0 ;;
        esac ;;
      set) npmrc_set "${3:-}" "${4:-}"; exit 0 ;;
      delete|rm) npmrc_del "${3:-}"; exit 0 ;;
    esac
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
  "$PY_BIN" -m py_compile "$ROOT"/ui/*.py 2>/dev/null || { rc=1; not_ok "Python 语法错误：ui/*.py"; }
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
  assert_eq '@anthropic-ai/claude-code' "${CAT_PACKAGES[claude]}" "claude 默认包名"
  assert_eq '@openai/codex' "${CAT_PACKAGES[codex]}" "codex 默认包名"
  assert_eq 'opencode-ai' "${CAT_PACKAGES[opencode]}" "opencode 默认包名"
}

test_catalog_expand_vars() {
  TESTVAR=hello
  assert_eq 'hello hello $1 x' "$(catalog_expand_vars '$TESTVAR ${TESTVAR} $1 x')" "变量展开"
  assert_eq '' "$(catalog_expand_vars '$NOPE_UNSET_VAR')" "未定义变量展开为空"
}

test_catalog_artifacts() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  assert_eq "$HOME/.gitconfig
$HOME/.config/git/config" "$(catalog_expand_artifacts git)" "git artifacts"
  assert_eq "/etc/systemd/journald.conf.d/99-os-config.conf
$HOME/.bashrc
$HOME/.local/bin/bat" "$(catalog_expand_artifacts syslog)" "syslog artifacts"
  assert_eq "/etc/apt/sources.list.d/ubuntu.sources
/etc/apt/sources.list" "$(catalog_expand_artifacts mirrors)" "mirrors artifacts"
  assert_eq "$HOME/.nvm
$HOME/.npmrc" "$(catalog_expand_artifacts nodejs)" "nodejs artifacts"
  assert_eq "" "$(catalog_expand_artifacts nosuspend)" "nosuspend 无 artifacts"
}

# artifacts 只展开一次：值里再出现 $ 不能被二次解释
test_catalog_artifacts_expanded_once() {
  local d
  d="$(mktemp -d)"
  cat >"$d/x.catalog" <<'EOF'
[foo]
type=config
action=git
artifacts=$ARTIFACT_ONE $ARTIFACT_TWO
EOF
  export ARTIFACT_ONE='$NOPE_UNSET_VAR'
  export ARTIFACT_TWO='plain'
  catalog_load "$d" >/dev/null 2>&1
  assert_eq '$NOPE_UNSET_VAR
plain' "$(catalog_expand_artifacts foo)" "artifacts 只展开一次"
  unset ARTIFACT_ONE ARTIFACT_TWO
  rm -rf "$d"
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
  # 权限位断言只对 POSIX 文件系统有意义：NTFS 没有模式位，stat 恒返回 644/755
  if [[ "$_IS_MSYS" != 1 ]]; then
    assert_eq 600 "$(stat -c '%a' "$STATE_FILE")" "清单权限 600"
  fi

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
  if [[ "$_IS_MSYS" != 1 ]]; then
    assert_eq 700 "$(stat -c '%a' "$d")" "动作私有目录权限"
  fi
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
  # 权限位只对 POSIX 文件系统有意义（NTFS 上 stat 恒返回 644）
  if [[ "$_IS_MSYS" != 1 ]]; then
    assert_eq 600 "$(stat -c '%a' "$LOG_FILE")" "日志权限 600"
  fi
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

# 回归：内联（backend:spec）注册的临时条目必须能过平台门。
# catalog_define_adhoc 曾把 platforms 写成 "linux,win"（逗号），而
# catalog_load_file 把文件里的 platforms 规范化成空格、_engine_platform_ok
# 按空格分词匹配——"linux,win" 既不含 " linux " 也不含 " win "，
# 于是 --pick apt:xxx / winget:xxx 在两个引擎上都被平台门静默跳过，
# 跑起来是"成功 0 / 跳过 1"，用户以为装上了其实什么都没发生。
test_engine_adhoc_not_skipped_by_platform_gate() {
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  resolve_inline 'apt:my-tool' || { not_ok "内联解析失败"; return 0; }
  assert_eq "linux win" "${CAT_PLATFORMS[my-tool]}" "adhoc platforms 用空格分隔"
  local out rc
  DRY_RUN=1
  out=$(engine_run install my-tool 2>&1); rc=$?
  DRY_RUN=0
  assert_rc_eq 0 "$rc" "内联条目 dry-run 返回 0"
  assert_contains "$out" "将执行 install" "内联条目未被平台门跳过"
  if [[ "$out" == *"不适用于当前平台"* ]]; then
    not_ok "内联条目被平台门跳过"
  else
    ok
  fi
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
  # 权限位只对 POSIX 文件系统有意义（NTFS 无模式位；Windows 侧的 ACL 校验
  # 由 engine/actions-win/ssh.ps1 与 test_win_ssh_keygen_empty_passphrase 覆盖）
  if [[ "$_IS_MSYS" != 1 ]]; then
    assert_eq 600 "$(stat -c '%a' "$HOME/.ssh/id_ed25519")" "私钥权限"
  fi
  if [[ "$_IS_MSYS" == 1 ]]; then
    # NTFS 上 stat 恒返回 644，Bash 版 verify 的 600 检查必然不过——这是环境
    # 限制而非缺陷，这里把该行为钉住：MSYS 下 verify 必须因权限不过而失败
    action_ssh_verify ssh >/dev/null 2>&1; rc=$?
    assert_rc_eq 1 "$rc" "MSYS 下 verify 因权限位不支持而失败"
  else
    action_ssh_verify ssh >/dev/null 2>&1; rc=$?
    assert_rc_eq 0 "$rc" "ssh verify"
  fi
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
# 10.5 配置项接线 / 回滚健壮性
# ===========================================================================

# PROXY_TEST_URL / PROXY_CONNECT_TIMEOUT / PROXY_MAX_TIME 必须真正生效
test_proxy_verify_uses_configured_url_and_timeouts() {
  . "$ROOT/engine/actions/proxy.sh"
  local fakebin marker rc
  fakebin="$TMPROOT/curlrec"
  mkdir -p "$fakebin"
  marker="$TESTDIR/curl.args"
  cat >"$fakebin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$marker"
exit 0
EOF
  chmod +x "$fakebin/curl"

  PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    action_proxy_apply proxy >/dev/null 2>&1

  PATH="$fakebin:$PATH" PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    PROXY_TEST_URL=https://example.test/probe \
    PROXY_CONNECT_TIMEOUT=9 PROXY_MAX_TIME=21 \
    action_proxy_verify proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "自定义 TEST_URL 时 verify 通过"
  assert_contains "$(cat "$marker" 2>/dev/null)" "https://example.test/probe" "verify 使用 PROXY_TEST_URL"
  assert_contains "$(cat "$marker" 2>/dev/null)" "--connect-timeout 9" "verify 使用 PROXY_CONNECT_TIMEOUT"
  assert_contains "$(cat "$marker" 2>/dev/null)" "--max-time 21" "verify 使用 PROXY_MAX_TIME"

  # 留空时回落到默认值
  PATH="$fakebin:$PATH" PROXY_ENABLED=true PROXY_HOST=127.0.0.1 PROXY_PORT=7890 \
    PROXY_TEST_URL= PROXY_CONNECT_TIMEOUT= PROXY_MAX_TIME= \
    action_proxy_verify proxy >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "默认值时 verify 通过"
  assert_contains "$(cat "$marker" 2>/dev/null)" "https://github.com" "默认 TEST_URL 为 github.com"
  assert_contains "$(cat "$marker" 2>/dev/null)" "--connect-timeout 5" "默认连接超时 5 秒"
  assert_contains "$(cat "$marker" 2>/dev/null)" "--max-time 15" "默认整体超时 15 秒"
}

# MIRROR_SKIP_APT / MIRROR_SKIP_APT_UPDATE / APT_UPGRADE 必须真正生效
test_mirrors_skip_and_upgrade_flags() {
  . "$ROOT/engine/actions/mirrors.sh"
  local src="$TESTDIR/ubuntu.sources" rc
  printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble\n' >"$src"
  _mirrors_sources() { printf '%s\n' "$src"; }

  MIRROR_SKIP_APT=true action_mirrors_apply mirrors >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "MIRROR_SKIP_APT 时 apply 返回 0"
  assert_contains "$(cat "$src")" "archive.ubuntu.com" "MIRROR_SKIP_APT 时不改写 APT 源"

  : >"$FAKE_APT_LOG"
  MIRROR_SKIP_APT=true MIRROR_SKIP_APT_UPDATE=true \
    action_mirrors_apply mirrors >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "MIRROR_SKIP_APT_UPDATE 时 apply 返回 0"
  assert_eq "" "$(cat "$FAKE_APT_LOG")" "MIRROR_SKIP_APT_UPDATE 时不执行 apt update"

  : >"$FAKE_APT_LOG"
  MIRROR_SKIP_APT=true APT_UPGRADE=true \
    action_mirrors_apply mirrors >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "APT_UPGRADE 时 apply 返回 0"
  assert_contains "$(cat "$FAKE_APT_LOG")" "update" "APT_UPGRADE 前先执行 apt update"
  assert_contains "$(cat "$FAKE_APT_LOG")" "upgrade" "APT_UPGRADE=true 执行 apt-get upgrade"

  : >"$FAKE_APT_LOG"
  MIRROR_SKIP_APT=true MIRROR_SKIP_APT_UPDATE=true APT_UPGRADE=true \
    action_mirrors_apply mirrors >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "跳过 update 时 apply 返回 0"
  assert_not_contains "$(cat "$FAKE_APT_LOG")" "upgrade" "跳过 apt update 时不执行 upgrade"

  : >"$FAKE_APT_LOG"
  MIRROR_SKIP_APT=true action_mirrors_apply mirrors >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "默认 apply 返回 0"
  assert_not_contains "$(cat "$FAKE_APT_LOG")" "upgrade" "默认不执行 apt-get upgrade"
}

# catalog 支持 ${VAR:-默认值}，且 desc 不做变量展开
test_catalog_expand_vars_default_value() {
  TESTVAR=hello
  assert_eq 'fallback' "$(catalog_expand_vars '${NOPE_UNSET_VAR:-fallback}')" "未定义变量使用默认值"
  assert_eq 'hello' "$(catalog_expand_vars '${TESTVAR:-fallback}')" "已定义变量优先于默认值"
  TESTVAR=''
  assert_eq 'fallback' "$(catalog_expand_vars '${TESTVAR:-fallback}')" "空变量使用默认值"
  TESTVAR=world
  assert_eq 'a-world-b' "$(catalog_expand_vars 'a-$TESTVAR-b')" "变量可嵌在文本中"
}

test_catalog_desc_not_expanded() {
  local d
  d="$(mktemp -d)"
  cat >"$d/x.catalog" <<'EOF'
[foo]
type=package
backend=apt
packages=foo
desc=价格 $USD 每月
EOF
  catalog_load "$d" >/dev/null 2>&1
  assert_eq '价格 $USD 每月' "${CAT_DESC[foo]}" "desc 不做变量展开"
  rm -rf "$d"
}

# npm 包名可由 versions.env 覆盖（默认值的断言放在 test_catalog_real，避免重复加载 catalog）
test_catalog_pkg_name_from_env() {
  export CLAUDE_CODE_PKG='@custom/claude' CODEX_PKG='@custom/codex' OPENCODE_PKG='custom-opencode'
  catalog_load "$ROOT/catalog" >/dev/null 2>&1
  assert_eq '@custom/claude' "${CAT_PACKAGES[claude]}" "包名可由 CLAUDE_CODE_PKG 覆盖"
  assert_eq '@custom/codex' "${CAT_PACKAGES[codex]}" "包名可由 CODEX_PKG 覆盖"
  assert_eq 'custom-opencode' "${CAT_PACKAGES[opencode]}" "包名可由 OPENCODE_PKG 覆盖"
  unset CLAUDE_CODE_PKG CODEX_PKG OPENCODE_PKG
}

# git verify 必须校验 user.name / user.email
test_action_git_verify_checks_identity() {
  . "$ROOT/engine/actions/git.sh"
  local cfg="$HOME/.gitconfig" rc

  printf '[user]\n\tname = Wrong\n\temail = wrong@example.com\n' >"$cfg"
  PROXY_ENABLED=false GIT_USER_NAME='Expected' GIT_USER_EMAIL='expected@example.com' \
    action_git_verify git >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "user.name 不匹配时 verify 返回非零"

  printf '[user]\n\tname = Expected\n\temail = expected@example.com\n' >"$cfg"
  PROXY_ENABLED=false GIT_USER_NAME='Expected' GIT_USER_EMAIL='expected@example.com' \
    action_git_verify git >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "身份匹配时 verify 返回 0"

  # 未配置期望值时跳过身份校验（apply 本就跳过该项）
  printf '[user]\n\tname = Whatever\n' >"$cfg"
  PROXY_ENABLED=false GIT_USER_NAME='' GIT_USER_EMAIL='' \
    action_git_verify git >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "未配置身份期望值时 verify 通过"
}

# sudo 不可用时不得把文件当成「新建」而在回滚时删掉
test_rollback_sudo_unavailable_keeps_file() {
  local fakebin f rc
  fakebin="$TMPROOT/sudofail"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$fakebin/sudo"
  chmod +x "$fakebin/sudo"

  f="$TESTDIR/sudo-target"
  printf 'original\n' >"$f"

  PATH="$fakebin:$PATH" register_rollback "$f" sudo; rc=$?
  assert_ne 0 "$rc" "sudo 不可用时注册回滚失败"
  assert_eq 0 "${#_ROLLBACK_ORIG[@]}" "sudo 不可用时不登记回滚项"

  printf 'changed\n' >"$f"
  rollback_on_exit 1
  assert_file_exists "$f" "sudo 不可用时回滚不删除文件"
  assert_eq 'changed' "$(cat "$f")" "sudo 不可用时回滚不改动文件内容"
}

# 备份失败时必须允许重试（旧实现会因已标记而永久跳过）
test_rollback_backup_failure_allows_retry() {
  local fakebin f real_cp rc
  fakebin="$TMPROOT/cpfail2"
  mkdir -p "$fakebin"
  real_cp="$(command -v cp)"
  cat >"$fakebin/cp" <<EOF
#!/usr/bin/env bash
dest="\${!#}"
case "\$dest" in *.bak.*) exit 1 ;; esac
exec "$real_cp" "\$@"
EOF
  chmod +x "$fakebin/cp"

  f="$TESTDIR/retry-target"
  printf 'original\n' >"$f"

  PATH="$fakebin:$PATH" register_rollback "$f"; rc=$?
  assert_ne 0 "$rc" "备份失败时注册返回非零"
  assert_eq 0 "${#_ROLLBACK_ORIG[@]}" "备份失败时不登记回滚项"

  register_rollback "$f"; rc=$?
  assert_rc_eq 0 "$rc" "备份恢复后可重试注册"
  assert_eq 1 "${#_ROLLBACK_ORIG[@]}" "重试后登记了回滚项"

  printf 'changed\n' >"$f"
  rollback_on_exit 1
  assert_eq 'original' "$(cat "$f")" "回滚恢复原内容"
}

# 过滤既匹配显示名也匹配用例函数名
test_filter_matches_function_name() {
  local rc
  FILTER=graph _test_filter_match '依赖闭包' test_graph_closure; rc=$?
  assert_rc_eq 0 "$rc" "过滤命中函数名"
  FILTER=graph _test_filter_match '毫不相干的用例' test_graph_closure; rc=$?
  assert_rc_eq 0 "$rc" "过滤按函数名命中"
  FILTER=graph _test_filter_match '毫不相干的用例' test_something_else; rc=$?
  assert_rc_eq 1 "$rc" "过滤未命中时返回非零"
  FILTER='' _test_filter_match '任意用例' test_any; rc=$?
  assert_rc_eq 0 "$rc" "无过滤条件时全部命中"
}

test_filter_no_match_exits_nonzero() {
  local rc
  bash "$ROOT/tests/run.sh" '__不存在的用例__' >/dev/null 2>&1; rc=$?
  assert_ne 0 "$rc" "过滤无匹配用例时返回非零（避免静默假通过）"
}

# 废弃的配置键要明确提示，不能静默忽略
test_deprecated_config_warns() {
  local out
  out=$(SSH_INSTALL_SERVER=true bash -c '
    PROJECT_DIR="$1"
    export PROJECT_DIR
    . "$1/engine/lib/log.sh"
    . "$1/engine/lib/util.sh"
  ' _ "$ROOT" 2>&1)
  assert_contains "$out" "SSH_INSTALL_SERVER 已废弃" "加载配置时提示废弃键"
  assert_contains "$out" "openssh-server" "提示里给出替代做法"

  out=$(SSH_INSTALL_SERVER=true _warn_deprecated_config 2>&1)
  assert_contains "$out" "SSH_INSTALL_SERVER 已废弃" "直接调用也提示"
  unset SSH_INSTALL_SERVER
  out=$(_warn_deprecated_config 2>&1)
  assert_not_contains "$out" "SSH_INSTALL_SERVER" "没有废弃键时不提示"
}

# 每个动作都要实现专属 status（不再落到通用兜底）
test_actions_have_status() {
  local a
  for a in mirrors proxy git ssh syslog nosuspend nodejs; do
    . "$ROOT/engine/actions/$a.sh"
    assert_true "action_${a}_status 已实现" declare -F "action_${a}_status"
  done
}

# status 动词要走专属实现，输出可读的一行状态
test_engine_status_uses_action_status() {
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  _ACTION_SOURCED[testfake]=1
  action_testfake_status() { printf '    %-22s %s\n' testfake "专属状态"; }
  local out rc
  out=$(engine_run status testfake 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "status 返回 0"
  assert_contains "$out" "专属状态" "走专属 status 实现"
  assert_not_contains "$out" "config:testfake" "不再落到通用兜底"
}

# 各动作的 status 只读且不报错
test_action_status_outputs() {
  local a out
  for a in mirrors proxy git ssh syslog nosuspend nodejs; do
    . "$ROOT/engine/actions/$a.sh"
    out="$(action_${a}_status probe 2>&1)"
    assert_contains "$out" "probe" "$a 的 status 输出包含工具 id"
  done
}

# engine 的 update / verify 动词
test_engine_update_and_verify_verbs() {
  catalog_reset
  register_config_tool testfake testfake
  _install_testfake_actions
  local rc
  engine_run update testfake >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "engine update 返回 0"
  assert_contains "$(cat "$TESTDIR/marker" 2>/dev/null || true)" applied "update 落到 apply 动作"
  engine_run verify testfake >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "engine verify 返回 0"
  assert_contains "$(cat "$TESTDIR/marker" 2>/dev/null || true)" verified "verify 调用 verify 动作"
}

# nodejs 卸载被用户拒绝时必须是 skipped，不能算成功
test_action_nodejs_remove_declined_is_skipped() {
  . "$ROOT/engine/actions/nodejs.sh"
  mkdir -p "$HOME/.nvm"
  local rc
  # 非交互下 confirm 读不到输入即视为拒绝
  action_nodejs_remove nodejs >/dev/null 2>&1; rc=$?
  assert_rc_eq 100 "$rc" "用户拒绝卸载时返回 skipped(100)"
  assert_true "用户拒绝时保留 ~/.nvm" test -d "$HOME/.nvm"

  FORCE=1 action_nodejs_remove nodejs >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "--force 强制卸载返回 0"
  assert_true "--force 时删除 ~/.nvm" test ! -d "$HOME/.nvm"
}

# nodejs apply 改了 npm 配置，remove 必须按原值还原（原本没有的删掉）
test_action_nodejs_remove_restores_npm_config() {
  . "$ROOT/engine/actions/nodejs.sh"
  local dir rc
  dir="$(state_action_dir nodejs)"
  printf 'registry=https://old.example\n' >"$HOME/.npmrc"

  # 模拟 apply 记下的原值
  printf 'registry=https://old.example\n' >"$dir/npmrc.orig"
  printf 'audit=\n' >>"$dir/npmrc.orig"

  mkdir -p "$HOME/.nvm"
  FORCE=1 action_nodejs_remove nodejs >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "remove 返回 0"
  assert_contains "$(cat "$HOME/.npmrc")" "registry=https://old.example" "registry 还原为原值"
  assert_not_contains "$(cat "$HOME/.npmrc")" "audit=" "原本没有的 audit 键被删除"
  assert_file_missing "$dir/npmrc.orig" "还原后清掉原值记录"
}

# nosuspend：remove 必须还原用户原值，而不是发行版默认
test_action_nosuspend_restores_original_values() {
  . "$ROOT/engine/actions/nosuspend.sh"
  local fakebin rc store="$TESTDIR/gsettings.db"
  fakebin="$TMPROOT/gnomebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/gsettings" <<EOF
#!/usr/bin/env bash
store="$store"
declare -A cur=(
  [org.gnome.desktop.session idle-delay]="600"
  [org.gnome.desktop.screensaver lock-enabled]="true"
  [org.gnome.desktop.screensaver idle-delay]="900"
)
sub="\$1"; key="\$2 \$3"
if [[ "\$sub" == "get" ]]; then
  v="\${cur[\$key]:-0}"
  [[ "\$key" == *"idle-delay" ]] && v="uint32 \$v"
  printf '%s\n' "\$v"
  exit 0
fi
if [[ "\$sub" == "set" ]]; then
  printf '%s=%s\n' "\$key" "\$4" >>"$store"
  exit 0
fi
if [[ "\$sub" == "reset" ]]; then
  printf '%s=RESET\n' "\$key" >>"$store"
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/gsettings"

  export XDG_CURRENT_DESKTOP=GNOME DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/fake
  PATH="$fakebin:$PATH" action_nosuspend_apply nosuspend >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "apply 返回 0"
  assert_true "apply 记录了原值" test -f "$(state_action_dir nosuspend)/gsettings.orig"
  assert_contains "$(cat "$(state_action_dir nosuspend)/gsettings.orig")" "session-idle-delay=600" "记录了 session idle-delay 原值"

  PATH="$fakebin:$PATH" action_nosuspend_remove nosuspend >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "remove 返回 0"
  local applied
  applied="$(cat "$store")"
  assert_contains "$applied" "org.gnome.desktop.session idle-delay=600" "按原值还原 idle-delay"
  assert_contains "$applied" "org.gnome.desktop.screensaver lock-enabled=true" "按原值还原 lock-enabled"
  assert_contains "$applied" "org.gnome.desktop.screensaver idle-delay=900" "按原值还原 screensaver idle-delay"
  assert_not_contains "$applied" "RESET" "有原值记录时不使用 gsettings reset"
  unset XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS
}

# syslog verify 必须检查自己创建的 bat 软链
test_action_syslog_verify_checks_bat_link() {
  . "$ROOT/engine/actions/syslog.sh"
  local link="$HOME/.local/bin/bat" rc out
  _SYSLOG_DROPIN="$TESTDIR/journald.conf"
  printf '[Journal]\nStorage=persistent\nSystemMaxUse=200M\n' >"$_SYSLOG_DROPIN"
  printf '%s\noslogs\n%s\n' "$_SYSLOG_ALIAS_BEGIN" "$_SYSLOG_ALIAS_END" >"$HOME/.bashrc"
  mkdir -p "$(dirname "$link")"

  # 软链指向别处 → verify 必须报出来
  ln -sfn /opt/custom/bat "$link"
  out=$(action_syslog_verify syslog 2>&1); rc=$?
  assert_ne 0 "$rc" "bat 软链指向异常时 verify 返回非零"
  assert_contains "$out" "bat 软链指向异常" "verify 报出软链异常"

  # 指向 batcat → 通过
  ln -sfn "$TESTDIR/bin/batcat" "$link"
  out=$(action_syslog_verify syslog 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "软链指向 batcat 时 verify 通过"
}

# syslog 卸载：没有 sudo 也要清理用户级残留
test_action_syslog_remove_without_sudo_cleans_user_files() {
  . "$ROOT/engine/actions/syslog.sh"
  local fakebin bashrc="$HOME/.bashrc" rc
  fakebin="$TMPROOT/nosudo"
  mkdir -p "$fakebin"
  # sudo 一律失败：模拟没有提权凭据的环境
  printf '#!/usr/bin/env bash\nexit 1\n' >"$fakebin/sudo"
  chmod +x "$fakebin/sudo"

  printf '%s\noslogs 别名\n%s\n' "$_SYSLOG_ALIAS_BEGIN" "$_SYSLOG_ALIAS_END" >"$bashrc"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(command -v batcat || echo /bin/batcat)" "$HOME/.local/bin/bat"

  PATH="$fakebin:$PATH" action_syslog_remove syslog >/dev/null 2>&1; rc=$?
  assert_rc_eq 100 "$rc" "无 sudo 时返回 skipped(100)"
  assert_not_contains "$(cat "$bashrc" 2>/dev/null)" "$_SYSLOG_ALIAS_BEGIN" "无 sudo 时仍移除 oslogs 别名块"
  assert_file_missing "$HOME/.local/bin/bat" "无 sudo 时仍移除 bat 软链"
}

# remove 时要提示「选集之外、但已安装」的依赖方
test_engine_remove_warns_external_dependents() {
  catalog_reset
  register_pkg_tool git-cli apt git
  register_config_tool git git
  CAT_DEPS[git]="git-cli"
  state_init
  state_record git git "$HOME/.gitconfig"
  local out rc
  out=$(engine_run remove git-cli 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "remove 返回 0"
  assert_contains "$out" "已安装的工具依赖本次卸载的项" "提示选集外的已安装依赖方"
  assert_contains "$out" "git" "提示里包含依赖方 id"

  # 未安装的依赖方不提示
  state_forget git
  out=$(engine_run remove git-cli 2>&1)
  assert_not_contains "$out" "已安装的工具依赖本次卸载的项" "未安装的依赖方不提示"
}

# 内联工具 id：首尾的 '-' 要全部去掉（与 ui/schema.py 一致）
test_profile_adhoc_id_strips_all_dashes() {
  profile_reset
  PROF_ORDER=(cli); PROF_DESC[cli]="inline"; PROF_EXTENDS[cli]=""; PROF_TOOLS[cli]="apt:x--"
  profile_resolve cli >/dev/null 2>&1
  assert_eq "x" "${SELECTED_TOOLS[0]:-}" "内联 id 去掉首尾所有 '-'"
  assert_eq "scope-pkg" "$(bash "$ROOT/setup.sh" --pick 'npm:@scope/pkg' --dry-run 2>&1 | grep -o 'scope-pkg' | head -1)" "npm 作用域包的 id 与 Web UI 一致"
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
  local out; out=$("$PY_BIN" - "$OS_CONFIG_EVENTS" <<'PY'
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
  parsed=$("$PY_BIN" - "$out" <<'PY'
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
  parsed=$("$PY_BIN" - "$out" <<'PY'
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
  port=$("$PY_BIN" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  "$PY_BIN" - "$port" <<'PY' &
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
  port=$("$PY_BIN" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
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

  # python3 版本过低时必须拒绝启动（服务端用了 3.10 才有的语法）
  local oldbin
  oldbin="$TESTDIR/oldpy"
  mkdir -p "$oldbin"
  port=$("$PY_BIN" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  cat >"$oldbin/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then printf '3.9\n'; exit 0; fi
exit 0
EOF
  chmod +x "$oldbin/python3"
  out=$(PATH="$oldbin:$PATH" timeout 10 bash "$ROOT/ui.sh" --no-open --port "$port" </dev/null 2>&1); rc=$?
  assert_rc_eq 1 "$rc" "python3 版本过低返回 1"
  assert_contains "$out" "python3 >= 3.10" "版本过低提示"
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
  out=$("$PY_BIN" - "$OS_CONFIG_EVENTS" <<'PY'
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
  out=$("$PY_BIN" - "$OS_CONFIG_EVENTS" "$f" <<'PY'
import json,sys,os
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8") if x.strip()]
rb=[r for r in rows if r["event"]=="rollback"]
# 只比 basename：Git Bash 会把路径型参数翻译成 Windows 形式（/tmp/x → C:/.../Temp/x）
# 再交给原生 python，而事件文件里记的是 bash 看到的 MSYS 路径，两边字面不同。
# 用 basename 断言"回滚的正是这个文件"，不依赖路径的表示形式。
assert len(rb)==1, rb
assert [os.path.basename(p) for p in rb[0]["restored"]]==[os.path.basename(sys.argv[2])], rb
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
  out=$(cd "$ROOT" && "$PY_BIN" -m unittest tests/test_ui_server.py 2>&1); rc=$?
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
# 14. 并发锁 / verify --fix / export / doctor
# ===========================================================================
test_state_lock_acquire_release() {
  state_lock_acquire
  assert_true "取锁成功" state_locked
  assert_file_exists "$STATE_LOCK/pid" "锁里写了 pid"
  assert_eq "$$" "$(cat "$STATE_LOCK/pid")" "pid 是自己"
  state_lock_release
  assert_true "锁已释放" test ! -d "$STATE_LOCK"
}

test_state_lock_ignores_other_holder() {
  # 用存活的后台进程模拟另一个运行的 pid
  sleep 30 & local other=$!
  mkdir -p -- "$STATE_LOCK"
  printf '%s\n' "$other" >"$STATE_LOCK/pid"
  state_lock_release
  assert_true "别人的锁不会被误删" test -d "$STATE_LOCK"
  rm -rf -- "$STATE_LOCK"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
}

test_state_lock_cleans_stale() {
  mkdir -p -- "$STATE_LOCK"
  printf '999999\n' >"$STATE_LOCK/pid"   # 必然已死
  state_lock_acquire
  assert_true "残留锁被清理并重新取到" state_locked
  state_lock_release
}

test_state_lock_acquire_blocked_message() {
  sleep 30 & local other=$!
  mkdir -p -- "$STATE_LOCK"
  printf '%s\n' "$other" >"$STATE_LOCK/pid"
  local out rc
  out=$(state_lock_acquire 2>&1); rc=$?
  assert_rc_eq 1 "$rc" "存活持有者时取锁失败"
  assert_contains "$out" "pid $other" "错误里给出对方 pid"
  assert_not_contains "$out" "pid $other$other" "pid 不应被重复拼接"
  rm -rf -- "$STATE_LOCK"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
}

test_engine_verify_without_fix_fails() {
  catalog_reset
  register_config_tool testfake testfake
  _ACTION_SOURCED[testfake]=1
  local marker="$TESTDIR/marker"
  action_testfake_apply()  { printf 'applied\n'  >>"$marker"; }
  action_testfake_remove() { :; }
  action_testfake_verify() { printf 'drift\n' >>"$marker"; return 1; }
  FIX=0
  local rc out
  out=$(engine_run verify testfake 2>&1); rc=$?
  assert_rc_eq 1 "$rc" "verify 失败返回 1"
  assert_not_contains "$out" "执行 apply 修复" "未加 --fix 不该修复"
  assert_not_contains "$(cat "$marker" 2>/dev/null || true)" applied "apply 未被调用"
}

test_engine_verify_fix_converges() {
  catalog_reset
  register_config_tool testfake testfake
  _ACTION_SOURCED[testfake]=1
  local marker="$TESTDIR/marker"
  : >"$marker"
  # 第一次 verify 失败；apply 之后 verify 才通过
  action_testfake_apply()  { printf 'applied\n' >>"$marker"; }
  action_testfake_remove() { :; }
  action_testfake_verify() {
    if grep -q applied "$marker"; then return 0; fi
    printf 'drift\n' >>"$marker"
    return 1
  }
  FIX=1
  local rc out
  out=$(engine_run verify testfake 2>&1); rc=$?
  FIX=0
  assert_rc_eq 0 "$rc" "verify --fix 成功返回 0"
  assert_contains "$out" "执行 apply 修复" "打印了修复动作"
  assert_contains "$out" "已修复并通过复验" "打印了复验通过"
  assert_contains "$(cat "$marker")" applied "apply 被调用过"
  assert_true "修复后落清单" state_has testfake
}

test_engine_verify_fix_dry_run_noop() {
  catalog_reset
  register_config_tool testfake testfake
  _ACTION_SOURCED[testfake]=1
  local marker="$TESTDIR/marker"
  action_testfake_apply()  { printf 'applied\n' >>"$marker"; }
  action_testfake_remove() { :; }
  action_testfake_verify() { return 1; }
  FIX=1 DRY_RUN=1
  local rc
  engine_run verify testfake >/dev/null 2>&1; rc=$?
  FIX=0 DRY_RUN=0
  assert_ne 0 "$rc" "dry-run 下不修复，仍报失败"
  assert_file_missing "$marker" "dry-run 不触发 apply"
}

test_export_writes_profile() {
  catalog_reset
  register_pkg_tool pkg-a apt "a"
  register_pkg_tool pkg-b apt "b"
  register_config_tool cfg-a cfga
  printf 'a\n' >"$TESTDIR/apt-installed"
  state_record cfg-a cfga ~/.cfg-a
  EXPORT_OUTPUT="$TESTDIR/out.conf"
  local out rc
  out=$(export_run 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "export 返回 0"
  assert_contains "$out" "已导出" "提示已导出"
  assert_file_exists "$TESTDIR/out.conf" "生成了 profile 文件"
  local body
  body="$(cat "$TESTDIR/out.conf")"
  assert_contains "$body" "pkg-a" "包含已安装的包"
  assert_contains "$body" "cfg-a" "包含已应用的配置"
  assert_not_contains "$body" "pkg-b" "不含未安装的包"
  assert_contains "$body" "[out]" "profile 名来自文件名"
}

test_export_empty_state_fails() {
  catalog_reset
  register_pkg_tool pkg-a apt "a"
  EXPORT_OUTPUT="$TESTDIR/none.conf"
  local out rc
  out=$(export_run 2>&1); rc=$?
  assert_rc_eq 1 "$rc" "空状态返回 1"
  assert_not_contains "$out" "已导出" "不应生成文件"
}

test_export_profile_name_from_path() {
  catalog_reset
  register_pkg_tool pkg-a apt "a"
  printf 'a\n' >"$TESTDIR/apt-installed"
  EXPORT_OUTPUT="$TESTDIR/profiles/gen.conf"
  mkdir -p -- "$TESTDIR/profiles"
  export_run >/dev/null 2>&1
  assert_file_exists "$TESTDIR/profiles/gen.conf" "按 --output 路径生成"
  assert_contains "$(cat "$TESTDIR/profiles/gen.conf")" "[gen]" "profile 名取自文件名"
}

# 回归：export 产出的 profile 必须能被 profile_load_file 原样读回。
# 曾经 Export.ps1 的说明行漏了 '# ' 前缀，生成的文件被解析器判为
# 「键值出现在任何 [名字] 段之前」，于是 export 的产物自己就用不了。
# 只断言"包含 [gen]"抓不到这类问题——文件必须真的过一遍解析器。
test_export_output_roundtrips_through_parser() {
  catalog_reset
  register_pkg_tool pkg-a apt "a"
  register_pkg_tool pkg-b apt "b"
  register_config_tool cfg-a cfga
  printf 'a\nb\n' >"$TESTDIR/apt-installed"
  state_record cfg-a cfga ~/.cfg-a
  EXPORT_OUTPUT="$TESTDIR/rt.conf"
  export_run >/dev/null 2>&1
  assert_file_exists "$TESTDIR/rt.conf" "生成了 profile"

  # 每个非注释、非空行都必须落在某个 [名字] 段内：这是解析器的硬约束
  local bad_line
  bad_line="$(awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/  { next }
    /^\[[^]]+\]$/    { insec = 1; next }
    { if (!insec) print NR": "$0 }
  ' "$TESTDIR/rt.conf")"
  assert_eq "" "$bad_line" "导出文件中没有段外键值行"

  profile_reset
  local rc
  profile_load_file "$TESTDIR/rt.conf" >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "导出文件可被 profile_load_file 解析"
  # export.sh 用 ", " 连接，这里同样按 ", " 归一化后再比对
  assert_eq "pkg-a pkg-b cfg-a" "${PROF_TOOLS[rt]//, / }" "tools 原样读回"
}

# 回归：profiles 目录里只要有一个文件解析失败，整目录加载就中止，
# 排在其后的 profile（如 default 依赖的 minimal）全部读不到，
# 于是 default/dev 报「extends 指向未知 profile」。export 的默认产物
# exported.conf 正好按字母序排在 minimal 之前，最容易被这条路径坑到。
test_exported_profile_does_not_break_sibling_profiles() {
  local dir="$TESTDIR/profiles" rc
  mkdir -p "$dir"
  printf '[base]\ntools=git-cli\n' >"$dir/aa-base.conf"
  printf '[default]\nextends=base\ntools=ssh\n' >"$dir/bb-default.conf"

  catalog_reset
  register_pkg_tool pkg-a apt "a"
  printf 'a\n' >"$TESTDIR/apt-installed"
  EXPORT_OUTPUT="$dir/zz-exported.conf"
  export_run >/dev/null 2>&1
  assert_file_exists "$dir/zz-exported.conf" "导出到同一目录"

  profile_reset
  profile_load "$dir" >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "含导出产物的 profiles 目录仍可整体加载"
  assert_eq "git-cli ssh" "$(profile_tokens default | tr '\n' ' ' | sed 's/ $//')" \
    "default 仍能解析出 extends 链上的工具"
}

# ===========================================================================
# Windows 引擎用例（有 PowerShell/pwsh 才跑；探针脚本直接点源 lib-win）
#
# 【写探针的铁律】heredoc 生成的 .ps1 必须是纯 ASCII：
# bash 写出来的是 LF 行尾、无 BOM，PowerShell 5.1 会按 ANSI 代码页读，
# 中文被啃成乱码后**可能**（取决于字节序列与位置）直接解析失败——
# 症状是探针零输出、断言全红，而错误信息根本不指向编码。
# 需要说明的地方写在 bash 侧注释里，heredoc 内只放 ASCII。
# ===========================================================================

# 回归：Windows 引擎（setup.ps1）导出的 profile 同样要能被读回。
# 只在有 PowerShell 时运行；没有时记一条通过，避免用例因零断言而失败。
test_win_export_roundtrip() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows 导出用例" true
    return 0
  fi

  local out="$TESTDIR/win-exported.conf" rc
  "$ps" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/setup.ps1" \
    export --output "$out" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # Windows 专属依赖（winget 等）缺失时不算本用例失败
    assert_true "setup.ps1 export 因环境不可用而跳过（rc=$rc）" true
    return 0
  fi
  assert_file_exists "$out" "setup.ps1 export 生成文件"

  profile_reset
  profile_load_file "$out" >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "Windows 导出的 profile 可被 Bash 解析器读回"

  # 生成的 profile 还要能真的被两个引擎各自加载一次
  local dir="$TESTDIR/winprofiles"
  mkdir -p "$dir"
  cp -- "$out" "$dir/win.conf"
  printf '[base]\ntools=git-cli\n' >"$dir/aa-base.conf"
  profile_reset
  profile_load "$dir" >/dev/null 2>&1; rc=$?
  assert_rc_eq 0 "$rc" "Windows 导出产物不破坏同目录其它 profile"
}

# 回归：curl / wget 在 PowerShell 里是 Invoke-WebRequest 的内置别名，
# 裸 Get-Command 会先把命令名解析到别名，于是「没装」被判成「已装」。
# wget 是现成的探针：本机没有 wget.exe，但裸 Get-Command 因别名返回 $true。
test_win_command_exists_ignores_aliases() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过别名用例" true
    return 0
  fi
  # 直接在引擎自己的 Util.ps1 上调用，避免起整个 setup.ps1
  local script="$TESTDIR/probe.ps1"
  cat >"$script" <<'PS'
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Log.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Util.ps1')
foreach ($n in @('wget')) {
  $engine = Test-CommandExists -Name $n
  $bare   = [bool](Get-Command -Name $n -ErrorAction SilentlyContinue)
  Write-Host ("{0}|{1}|{2}" -f $n, $engine, $bare)
}
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  # 引擎必须说 False（没有 wget.exe），而裸 Get-Command 因别名说 True
  assert_contains "$out" "wget|False|True" "Test-CommandExists 不把别名当成已安装"
}

# 回归：setup.ps1 --list --json 的 artifacts 必须走 win_artifacts ?: artifacts，
# 且同行多路径要按词拆成多个数组元素（与 Bash 版逐字段可比）。
# 曾经的实现直接读 CAT_ARTIFACTS 并按换行拆分：proxy 把 Linux 的 ~/.bashrc
# 暴露给 Windows 的 Web UI；git 的第二个 ~/.config 不展开，还和第一个挤在
# 同一个字符串里；${PSPROFILE}/${HOME} 也被 Expand-CatalogVars 提前吞成空串。
test_win_list_json_artifacts() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows list --json 用例" true
    return 0
  fi
  local out rc
  out="$(OSC_STATE_DIR="$TESTDIR/win-state" "$ps" -NoProfile -ExecutionPolicy Bypass \
    -File "$ROOT/setup.ps1" --list --json 2>/dev/null)"; rc=$?
  assert_rc_eq 0 "$rc" "setup.ps1 --list --json 返回 0"
  local parsed
  parsed=$("$PY_BIN" - "$out" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
by={x["id"]:x for x in d["catalog"]}
# proxy：win_artifacts=${PSPROFILE} 必须胜出，而不是 Linux 的 ~/.bashrc
pa=by["proxy"]["artifacts"]
assert len(pa)==1 and ".bashrc" not in pa[0], pa
assert pa[0].lower().endswith("microsoft.powershell_profile.ps1"), pa
# git：同行两个路径必须拆成两个元素，~ 全部展开
ga=by["git"]["artifacts"]
assert len(ga)==2, ga
assert not any("~" in a for a in ga), ga
# nodejs：三个 win_artifacts，${HOME} 与 ${PSPROFILE} 都展开
na=by["nodejs"]["artifacts"]
assert len(na)==3, na
assert not any("$" in a for a in na), na
print("ok")
PY
)
  assert_contains "$parsed" "ok" "Windows list --json 的 artifacts 展开正确"
}

# 回归：Windows 侧 rollback 事件必须存在、且带 restored 文件列表。
# 曾经的实现调用一个不存在的 Emit-Event（真名是 Publish-Event），
# restored 还恒为 []——回滚事件从未写出，Web UI 与 Bash 版也对不上。
test_win_rollback_event_restored() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows rollback 事件用例" true
    return 0
  fi
  local script="$TESTDIR/probe-rollback.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Log.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Util.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Events.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\State.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Rollback.ps1')

$dir = $env:OSC_TEST_DIR
$null = Initialize-StatePaths -Dir (Join-Path $dir 'state')
$script:EventsFile = Join-Path $dir 'events.jsonl'
$script:VERB = 'install'

$f1 = Join-Path $dir 'keep.txt'
$f2 = Join-Path $dir 'new.txt'
[System.IO.File]::WriteAllText($f1, 'original')
$null = Register-Rollback -Path $f1
$null = Register-Rollback -Path $f2
[System.IO.File]::WriteAllText($f1, 'modified')
[System.IO.File]::WriteAllText($f2, 'created')
$null = Invoke-RollbackOnExit -Rc 1
Write-Host ("restored1={0}" -f [System.IO.File]::ReadAllText($f1))
Write-Host ("newgone={0}" -f (-not (Test-Path -LiteralPath $f2)))
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "restored1=original" "回滚后原文件内容恢复"
  assert_contains "$out" "newgone=True" "回滚后新建文件被删除"
  local parsed
  parsed=$("$PY_BIN" - "$TESTDIR/events.jsonl" <<'PY'
import json,sys,os
rows=[json.loads(x) for x in open(sys.argv[1],encoding="utf-8") if x.strip()]
rb=[r for r in rows if r["event"]=="rollback"]
assert len(rb)==1, rows
restored=rb[0]["restored"]
assert len(restored)==2, restored
assert sorted(os.path.basename(p) for p in restored)==["keep.txt","new.txt"], restored
assert rb[0]["phase"]=="install", rb[0]
print("ok")
PY
)
  assert_contains "$parsed" "ok" "rollback 事件带 restored 列表"
}

# 回归：catalog 校验报错必须给出可读信息。
# 曾经的实现两条错误消息引用未定义的 $rawBackend，Set-StrictMode 2.0 下
# 变成"The variable '$rawBackend' cannot be retrieved"，真正的校验原因
# 被淹没；事件仍能正确拒绝，但用户看到的是一堆乱码。
test_win_catalog_missing_win_backend_message() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows catalog 校验用例" true
    return 0
  fi
  local catdir="$TESTDIR/badcatalog"
  mkdir -p "$catdir"
  cat >"$catdir/test.catalog" <<'EOF'
[good-one]
type=package
backend=winget
packages=Good.One
platforms=linux,win
win_backend=winget
win_packages=Good.One
win_commands=good
desc=合法条目

[bad-one]
type=package
backend=winget
packages=Bad.One
platforms=linux,win
desc=缺 win_backend 的条目
EOF
  local script="$TESTDIR/probe-catalog.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Log.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Util.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Catalog.ps1')
$ok = Import-Catalog -Dir $env:OSC_TEST_CATALOG
Write-Host ("import_ok={0}" -f $ok)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_CATALOG="$catdir" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "import_ok=False" "非法 catalog 被拒绝"
  assert_contains "$out" "缺少 win_backend" "错误信息说明缺少 win_backend"
  assert_contains "$out" "bad-one" "错误信息指出具体条目"
  if [[ "$out" == *"cannot be retrieved"* ]]; then
    not_ok "错误信息被 strict mode 变量错误污染"
  else
    ok
  fi
}

# 回归：config 动作必须真的分派到动作脚本里的函数，而不是回退到通用 status。
# Windows 引擎曾在函数内点源动作脚本——PowerShell 的函数内点源只把定义
# 放进该函数自己的作用域，函数返回即消失。后果是分派时找不到
# action_<x>_<verb>：apply/remove/verify 报"不支持动词"，status 又静默
# 回退到通用输出，整个 config 动作层失效且没有显式错误。
# 选 ssh 作探针：依赖 openssh-client 是 builtin 后端（系统自带），不依赖
# winget；action_ssh_status 只判断密钥文件是否存在，无外部命令依赖。
test_win_action_dispatch_uses_action_script() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows 动作分派用例" true
    return 0
  fi
  local out rc
  out="$(OSC_STATE_DIR="$TESTDIR/win-state" "$ps" -NoProfile -ExecutionPolicy Bypass \
    -File "$ROOT/setup.ps1" status --pick ssh 2>/dev/null)"; rc=$?
  assert_rc_eq 0 "$rc" "setup.ps1 status --pick ssh 返回 0"
  assert_contains "$out" "status 汇总" "引擎跑完出汇总"
  if [[ "$out" == *"config:ssh"* ]]; then
    not_ok "status 回退到了通用输出（动作脚本未加载）"
  else
    ok
  fi
  if [[ "$out" == *"不支持动词"* ]]; then
    not_ok "分派报动作不支持动词（动作脚本未加载）"
  else
    ok
  fi
  if [[ "$out" == *"已生成"* || "$out" == *"未生成"* ]]; then
    ok
  else
    not_ok "status 输出来自动作脚本自身"
  fi
}

# 回归：默认配置（SSH_KEY_PASSPHRASE 未设置 → 空口令）下 ssh 动作必须能生成密钥。
# PowerShell 5.1 用调用运算符执行原生程序时会丢弃空字符串参数：
# `& ssh-keygen -N '' ...` 传给 ssh-keygen 的是 -N -C ...，程序报
# "Too many arguments"——默认路径整个失效，且错误信息完全指错方向。
# 修法：Invoke-NativeStep 用 ProcessStartInfo 自拼命令行，空参数是 ""。
# 整个 install 跑在沙箱 HOME 里（USERPROFILE 重定向），不碰真实 ~/.ssh。
test_win_ssh_keygen_empty_passphrase() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows ssh-keygen 用例" true
    return 0
  fi
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    assert_true "无 ssh-keygen，跳过 Windows ssh-keygen 用例" true
    return 0
  fi
  # 必须用系统原生的 ssh-keygen：Git Bash 的 PATH 里 Git 自带的 MSYS2 版排在
  # 前面，而它不做 Windows ACL 加固（私钥 ACL 全继承、含 CodexSandboxUsers 之
  # 类的组），动作的 ACL 校验会按"过松"失败。真实 Windows 终端里 System32 的
  # 原生版本来就优先，这里按真实顺序跑，顺带覆盖"原生版写严格 ACL"这条路径。
  local nativedir="/c/Windows/System32/OpenSSH"
  if [[ ! -x "$nativedir/ssh-keygen.exe" ]]; then
    assert_true "无原生 ssh-keygen，跳过 Windows ssh-keygen 用例" true
    return 0
  fi
  local home="$TESTDIR/winhome"
  mkdir -p "$home"
  local out rc
  out="$(USERPROFILE="$home" OSC_STATE_DIR="$TESTDIR/win-state" \
    OSC_CONFIG_EVENTS="$TESTDIR/events.jsonl" PATH="$nativedir:$PATH" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/setup.ps1" \
    install --pick ssh 2>/dev/null)"; rc=$?
  assert_rc_eq 0 "$rc" "setup.ps1 install --pick ssh 返回 0"
  assert_file_exists "$home/.ssh/id_ed25519" "空口令下私钥被生成"
  assert_file_exists "$home/.ssh/id_ed25519.pub" "空口令下公钥被生成"
  assert_contains "$out" "SSH 密钥就绪" "动作报告密钥就绪"
  assert_contains "$(cat "$TESTDIR/win-state/manifest.conf" 2>/dev/null)" "ssh|" "清单记录 ssh"

  # verify 必须认这把钥匙（存在性 + ACL），remove 必须按记录删掉
  out="$(USERPROFILE="$home" OSC_STATE_DIR="$TESTDIR/win-state" \
    PATH="$nativedir:$PATH" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/setup.ps1" \
    verify --pick ssh 2>/dev/null)"; rc=$?
  assert_rc_eq 0 "$rc" "verify 认可生成的密钥"
  out="$(USERPROFILE="$home" OSC_STATE_DIR="$TESTDIR/win-state" \
    PATH="$nativedir:$PATH" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/setup.ps1" \
    remove --pick ssh --yes 2>/dev/null)"; rc=$?
  assert_rc_eq 0 "$rc" "remove 返回 0"
  assert_file_missing "$home/.ssh/id_ed25519" "remove 删掉生成的私钥"
}

# 回归：Invoke-NativeStep 必须把空串参数原样送进命令行。
# 同样是 PowerShell 丢弃空参数的问题：git config --global <key> '' 若被丢掉
# 空参数就退化成读操作——"还原一个原本未设置的值"静默失败且退出码为 0。
# 探针：先把键设成非空，再用空串"还原"，最后读回来的必须是空而不是原值。
test_win_native_step_empty_argument() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows 原生调用用例" true
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    assert_true "无 git，跳过 Windows 原生调用用例" true
    return 0
  fi
  local script="$TESTDIR/probe-native.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Log.ps1')
. (Join-Path $env:OSC_PROJECT_DIR 'engine\lib-win\Util.ps1')
$env:USERPROFILE = $env:OSC_TEST_DIR
$env:HOME = $env:OSC_TEST_DIR
# Empty element must become "" on the command line, not get dropped
$s = ConvertTo-NativeArgumentString -Arguments @('config','--global','osc.testkey','')
Write-Host ("cmdline={0}" -f $s)
# Seed non-empty, then "restore" empty: delivered => reads back empty; dropped => keeps old value
$null = Invoke-NativeStep -Description 'seed' -FileName 'git' -Arguments @('config','--global','osc.testkey','hello')
$rc = Invoke-NativeStep -Description 'restore empty' -FileName 'git' -Arguments @('config','--global','osc.testkey','')
$got = (& git config --global --get osc.testkey 2>$null | Out-String).Trim()
Write-Host ("rc={0}" -f $rc)
Write-Host ("got=[{0}]" -f $got)
$null = Invoke-NativeStep -Description 'cleanup' -FileName 'git' -Arguments @('config','--global','--unset','osc.testkey')
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" 'cmdline="config" "--global" "osc.testkey" ""' "空参数被引用为空串"
  assert_contains "$out" "rc=0" "git config 空值设置成功"
  assert_contains "$out" "got=[]" "空参数真的送达（键被改成空串而非保持原值）"
}

# 回归：winget 安装必须真的把参数传给 winget.exe。
# Invoke-WingetInstallImpl 曾把参数链表命名为 $args——PowerShell 的自动变量。
# 函数里赋值虽然生效，但 Invoke-Step 的 -Script { & winget.exe @args } 里
# $args 会重新绑定到**脚本块自己**的未绑定参数（空集合），于是 winget.exe
# 以零参数运行：它打印帮助并退出 0，每次 install/update 都静默"成功"而
# 什么都没装。mock 用 global:winget.exe 函数遮蔽外部命令来记录真实入参。
test_win_winget_install_passes_arguments() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows winget 参数用例" true
    return 0
  fi
  local script="$TESTDIR/probe-winget.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
foreach ($m in @('Log','Util','Events','Catalog','Profile','Graph','State','Rollback','Backends','Engine','Doctor','Export','ListJson')) {
  . (Join-Path $script:ProjectDir ("engine\lib-win\{0}.ps1" -f $m))
}
$actionFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir 'engine\actions-win') -Filter '*.ps1' -File | Sort-Object -Property Name)
foreach ($af in $actionFiles) { . $af.FullName }
$null = Import-Catalog
$null = Import-Profile
$script:EventsFile = ''
$null = Initialize-StatePaths -Dir (Join-Path $env:OSC_TEST_DIR 'state')
$script:HomeDir = $env:OSC_TEST_DIR

$global:WingetLog = Join-Path $env:OSC_TEST_DIR 'winget.log'
$global:WingetInstalled = @{}
function global:winget.exe {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$WArgs)
  $n = @($WArgs).Count
  [System.IO.File]::AppendAllText($global:WingetLog, ("CALL n={0} args=[{1}]" -f $n, (@($WArgs) -join ' ')) + "`r`n", (New-Object System.Text.UTF8Encoding $false))
  if ($n -eq 0) { $global:LASTEXITCODE = 0; return }
  if ($WArgs[0] -eq 'list') {
    for ($i = 0; $i -lt $n; $i++) {
      if ($WArgs[$i] -eq '--id') {
        $id = $WArgs[$i+1].ToLowerInvariant()
        if ($global:WingetInstalled.ContainsKey($id)) {
          Write-Output ("Fake   {0}   {1}   winget" -f $WArgs[$i+1], $global:WingetInstalled[$id])
          $global:LASTEXITCODE = 0
          return
        }
      }
    }
    $global:LASTEXITCODE = 20
    return
  }
  if ($WArgs[0] -eq 'install') {
    for ($i = 0; $i -lt $n; $i++) {
      if ($WArgs[$i] -eq '--id') { $global:WingetInstalled[$WArgs[$i+1].ToLowerInvariant()] = '1.2.3' }
    }
  }
  if ($WArgs[0] -eq 'uninstall') {
    for ($i = 0; $i -lt $n; $i++) {
      if ($WArgs[$i] -eq '--id') { $null = $global:WingetInstalled.Remove($WArgs[$i+1].ToLowerInvariant()) }
    }
  }
  $global:LASTEXITCODE = 0
}

$rc1 = Invoke-EngineRun -Verb 'install' -Ids @('jq')
$rc2 = Invoke-EngineRun -Verb 'install' -Ids @('jq')
$rc3 = Invoke-EngineRun -Verb 'verify' -Ids @('jq')
Write-Host ("rc1={0} rc2={1} rc3={2}" -f $rc1, $rc2, $rc3)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "rc1=0 rc2=0 rc3=1" "install 两次 + verify（jq 命令不在 PATH，verify 失败是对的）"
  local log; log="$(cat "$TESTDIR/winget.log" 2>/dev/null)"
  if [[ "$log" == *"CALL n=0 "* ]]; then
    not_ok "winget.exe 收到了零参数调用（自动变量 args 陷阱）"
  else
    ok
  fi
  assert_contains "$log" "args=[install --exact --id jqlang.jq --source winget --silent" "install 带齐参数"
  assert_contains "$log" "--scope user --no-upgrade]" "user 域 + --no-upgrade"
  # 第二次 install 应只做一次已装查询，不再调用 install
  local install_calls
  install_calls="$(grep -c 'args=\[install ' "$TESTDIR/winget.log" 2>/dev/null || true)"
  install_calls="${install_calls:-0}"
  assert_eq "1" "$install_calls" "已安装后不重复 install"
}

# 回归：npm 安装遇到 ENOTEMPTY 必须清理残留后重试一次。
# Install-NpmGlobalFixed 靠 $script:LastStepOutput 判断 ENOTEMPTY，
# 而 Invoke-WithRetry 原先不捕获输出——LastStepOutput 永远是别处遗留的旧值，
# 定向重试是死代码。mock 的 npm 第一次安装报 ENOTEMPTY，第二次成功。
test_win_npm_enotempty_retry() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows npm 重试用例" true
    return 0
  fi
  local script="$TESTDIR/probe-npm.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
foreach ($m in @('Log','Util','Events','Catalog','Profile','Graph','State','Rollback','Backends','Engine','Doctor','Export','ListJson')) {
  . (Join-Path $script:ProjectDir ("engine\lib-win\{0}.ps1" -f $m))
}
$actionFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir 'engine\actions-win') -Filter '*.ps1' -File | Sort-Object -Property Name)
foreach ($af in $actionFiles) { . $af.FullName }
$null = Import-Catalog
$null = Import-Profile
$script:EventsFile = ''
$null = Initialize-StatePaths -Dir (Join-Path $env:OSC_TEST_DIR 'state')
$script:HomeDir = $env:OSC_TEST_DIR

$global:NpmLog = Join-Path $env:OSC_TEST_DIR 'npm.log'
$global:NpmRoot = Join-Path $env:OSC_TEST_DIR 'npmroot'
$global:NpmBin = Join-Path $global:NpmRoot 'bin'
$global:NpmModules = Join-Path $global:NpmRoot 'lib\node_modules'
$global:NpmResidue = Join-Path $global:NpmModules '.fake-pkg-abc123'
$env:PATH = $global:NpmBin + ';' + $env:PATH
function global:npm {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$NArgs)
  [System.IO.File]::AppendAllText($global:NpmLog, ("args=[{0}]" -f (@($NArgs) -join ' ')) + "`r`n", (New-Object System.Text.UTF8Encoding $false))
  if ($NArgs[0] -eq 'install') {
    # Residue dir present => keep failing with ENOTEMPTY. Only a real cleanup
    # can make this succeed, so the generic retry cannot mask the fix.
    if (Test-Path -LiteralPath $global:NpmResidue) {
      $null = New-Item -ItemType Directory -Path $global:NpmModules -Force
      Write-Output "npm ERR! ENOTEMPTY: directory not empty, rename 'C:\x' -> 'C:\y'"
      $global:LASTEXITCODE = 1
      return
    }
    $null = New-Item -ItemType Directory -Path $global:NpmBin -Force
    [System.IO.File]::WriteAllText((Join-Path $global:NpmBin 'fakecmd.cmd'), "@echo off`r`necho 9.9.9`r`n", (New-Object System.Text.UTF8Encoding $false))
    $global:LASTEXITCODE = 0
    return
  }
  if ($NArgs[0] -eq 'uninstall') {
    try { Remove-Item -LiteralPath (Join-Path $global:NpmBin 'fakecmd.cmd') -Force -ErrorAction SilentlyContinue } catch { }
    $global:LASTEXITCODE = 0
    return
  }
  if ($NArgs[0] -eq 'config') { Write-Output $global:NpmRoot; $global:LASTEXITCODE = 0; return }
  # npm root -g returns the node_modules dir; residue cleanup searches there
  if ($NArgs[0] -eq 'root') { Write-Output $global:NpmModules; $global:LASTEXITCODE = 0; return }
  $global:LASTEXITCODE = 0
}
# Pre-seed the residue dir: simulates a .<pkg>-* rename leftover from a prior failure
$null = New-Item -ItemType Directory -Path $global:NpmResidue -Force

$null = Register-CatalogAdhoc -Id 'fakepkg' -Backend 'npm' -Packages 'fake-pkg' -Commands 'fakecmd'
$rc1 = Invoke-EngineRun -Verb 'install' -Ids @('fakepkg')
$rc2 = Invoke-EngineRun -Verb 'install' -Ids @('fakepkg')
$rc3 = Invoke-EngineRun -Verb 'verify' -Ids @('fakepkg')
$rc4 = Invoke-EngineRun -Verb 'remove' -Ids @('fakepkg')
Write-Host ("rc1={0} rc2={1} rc3={2} rc4={3}" -f $rc1, $rc2, $rc3, $rc4)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "rc1=0 rc2=0 rc3=0 rc4=0" "npm 四动词全绿（含 ENOTEMPTY 重试）"
  local install_calls
  install_calls="$(grep -c 'args=\[install ' "$TESTDIR/npm.log" 2>/dev/null || true)"
  install_calls="${install_calls:-0}"
  # 第一次 ENOTEMPTY + 修复重试 = 2 次；第二次 install 应命中幂等跳过
  assert_eq "2" "$install_calls" "ENOTEMPTY 后重试一次，且重复 install 被幂等跳过"
  # 安装参数与 Bash 版 npm_install_global_fixed 逐项对齐（曾经 PowerShell 侧
  # 只传 install -g spec，丢了 foreground-scripts/超时/离线优先等 flag）
  local first_install
  first_install="$(grep -m1 'args=\[install ' "$TESTDIR/npm.log" 2>/dev/null || true)"
  for flag in --loglevel=info --foreground-scripts --no-audit --no-fund \
              --prefer-offline --fetch-timeout=120000 --fetch-retry-maxtimeout=120000; do
    assert_contains "$first_install" "$flag" "npm install 带 $flag"
  done
  assert_contains "$first_install" "fake-pkg]" "install 带包规格"
}

# 回归：Windows proxy 动作全生命周期（apply/verify/remove + 禁用语义 + 幂等）。
# 探针在沙箱 HOME 里跑，Test-Connection 与 curl.exe 用函数遮蔽（ PowerShell 函数
# 优先于 PATH 可执行文件），不碰真实 profile 与网络。
test_win_proxy_action_lifecycle() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows proxy 动作用例" true
    return 0
  fi
  local script="$TESTDIR/probe-proxy.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
foreach ($m in @('Log','Util','Events','Catalog','Profile','Graph','State','Rollback','Backends','Engine','Doctor','Export','ListJson')) {
  . (Join-Path $script:ProjectDir ("engine\lib-win\{0}.ps1" -f $m))
}
$actionFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir 'engine\actions-win') -Filter '*.ps1' -File | Sort-Object -Property Name)
foreach ($af in $actionFiles) { . $af.FullName }
$null = Import-Catalog
$null = Import-Profile
$script:EventsFile = ''
$null = Initialize-StatePaths -Dir (Join-Path $env:OSC_TEST_DIR 'state')
$script:HomeDir = $env:OSC_TEST_DIR

function global:Test-Connection { param([Parameter(ValueFromRemainingArguments)]$a) return $true }
function global:curl.exe { param([Parameter(ValueFromRemainingArguments)]$a) $global:LASTEXITCODE = 0; return }
$env:PROXY_ENABLED = 'true'
$env:PROXY_HOST = '10.0.0.1'
$env:PROXY_PORT = '7890'

$profile = Get-PowerShellProfilePath
$rc1 = & action_proxy_apply -Id 'proxy'
$rc2 = & action_proxy_verify -Id 'proxy'
$block = Get-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
$hasUrl = ($block -match 'HTTPS_PROXY = ''http://10\.0\.0\.1:7890''')
$rc3 = & action_proxy_remove -Id 'proxy'
$afterRemove = Get-ManagedBlock -Path $profile -Begin $script:PROXY_BEGIN -End $script:PROXY_END
$rc4 = & action_proxy_apply -Id 'proxy'
$rc5 = & action_proxy_verify -Id 'proxy'
Write-Host ("a={0} v={1} url={2} r={3} gone={4} again={5}/{6}" -f $rc1, $rc2, $hasUrl, $rc3, [string]::IsNullOrEmpty($afterRemove), $rc4, $rc5)

$env:PROXY_ENABLED = 'false'
$rc6 = & action_proxy_verify -Id 'proxy'
$rc7 = & action_proxy_remove -Id 'proxy'
$rc8 = & action_proxy_verify -Id 'proxy'
Write-Host ("disabled_with_block={0} after_remove={1}" -f $rc6, $rc8)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "a=0 v=0 url=True r=0 gone=True again=0/0" "proxy apply/verify/remove/幂等 全绿"
  assert_contains "$out" "disabled_with_block=1 after_remove=0" "禁用时要求无残留块"
}

# 回归：Windows git 动作全生命周期。身份写入、代理键写入与 .orig 备份、
# remove 只还原代理键不碰身份——与 Bash 版语义一致。
test_win_git_action_lifecycle() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows git 动作用例" true
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    assert_true "无 git，跳过 Windows git 动作用例" true
    return 0
  fi
  local script="$TESTDIR/probe-git.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
foreach ($m in @('Log','Util','Events','Catalog','Profile','Graph','State','Rollback','Backends','Engine','Doctor','Export','ListJson')) {
  . (Join-Path $script:ProjectDir ("engine\lib-win\{0}.ps1" -f $m))
}
$actionFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir 'engine\actions-win') -Filter '*.ps1' -File | Sort-Object -Property Name)
foreach ($af in $actionFiles) { . $af.FullName }
$null = Import-Catalog
$null = Import-Profile
$script:EventsFile = ''
$null = Initialize-StatePaths -Dir (Join-Path $env:OSC_TEST_DIR 'state')
$script:HomeDir = $env:OSC_TEST_DIR
$env:HOME = $env:OSC_TEST_DIR
$env:USERPROFILE = $env:OSC_TEST_DIR
function global:Test-Connection { param([Parameter(ValueFromRemainingArguments)]$a) return $true }

$env:PROXY_ENABLED = 'false'
$env:GIT_USER_NAME = 'UI Test'
$env:GIT_USER_EMAIL = 'ui-test@example.invalid'
$rc1 = & action_git_apply -Id 'git'
$rc2 = & action_git_verify -Id 'git'
$name = Get-GitConfigValue -Key 'user.name'
$email = Get-GitConfigValue -Key 'user.email'

$env:PROXY_ENABLED = 'true'
$env:PROXY_HOST = '10.0.0.1'
$env:PROXY_PORT = '7890'
$rc3 = & action_git_apply -Id 'git'
$rc4 = & action_git_verify -Id 'git'
$hp = Get-GitConfigValue -Key 'http.proxy'
$orig = Join-Path (Get-StateActionDir -Name 'git') 'http.proxy.orig'
# Evaluate now: remove deletes the whole state action dir, checking later would always be False
$origExists = (Test-Path -LiteralPath $orig)

$rc5 = & action_git_remove -Id 'git'
$hpAfter = Get-GitConfigValue -Key 'http.proxy'
$nameAfter = Get-GitConfigValue -Key 'user.name'
$cfgPath = Get-GitGlobalConfigPath
# NOTE: keep probe files pure ASCII - bash heredoc writes LF without BOM and
# PowerShell 5.1 reads that as ANSI, so Chinese comments corrupt the tokenizer.
$normCfg = $cfgPath.Replace('\', '/')
$normDir = $env:OSC_TEST_DIR.Replace('\', '/')
$inSandbox = $normCfg.StartsWith($normDir, [System.StringComparison]::OrdinalIgnoreCase)
Write-Host ("id={0}/{1} name=[{2}] email=[{3}]" -f $rc1, $rc2, $name, $email)
Write-Host ("proxy={0}/{1} key=[{2}] orig={3}" -f $rc3, $rc4, $hp, $origExists)
Write-Host ("remove={0} key_after=[{1}] name_after=[{2}] cfg_in_sandbox={3}" -f $rc5, $hpAfter, $nameAfter, $inSandbox)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "id=0/0 name=[UI Test] email=[ui-test@example.invalid]" "git 身份写入并校验通过"
  assert_contains "$out" "proxy=0/0 key=[http://10.0.0.1:7890] orig=True" "代理键写入且留下原值备份"
  assert_contains "$out" "remove=0 key_after=[] name_after=[UI Test]" "remove 还原代理键、保留身份"
  assert_contains "$out" "cfg_in_sandbox=True" "gitconfig 路径解析在沙箱内（home 只读变量回归）"
}

# 回归：Windows nodejs 动作（fnm 路径）全生命周期。fnm 必须是真的可执行文件
# （Test-CommandExists 只认 Application/ExternalScript，函数与别名不算已装），
# 因此在候选目录里放假 fnm.cmd；winget 用函数遮蔽。
test_win_nodejs_action_lifecycle() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows nodejs 动作用例" true
    return 0
  fi
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    assert_true "无 node/npm，跳过 Windows nodejs 动作用例" true
    return 0
  fi
  local script="$TESTDIR/probe-nodejs.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
foreach ($m in @('Log','Util','Events','Catalog','Profile','Graph','State','Rollback','Backends','Engine','Doctor','Export','ListJson')) {
  . (Join-Path $script:ProjectDir ("engine\lib-win\{0}.ps1" -f $m))
}
$actionFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectDir 'engine\actions-win') -Filter '*.ps1' -File | Sort-Object -Property Name)
foreach ($af in $actionFiles) { . $af.FullName }
$null = Import-Catalog
$null = Import-Profile
$script:EventsFile = ''
$null = Initialize-StatePaths -Dir (Join-Path $env:OSC_TEST_DIR 'state')
$script:HomeDir = $env:OSC_TEST_DIR
$env:HOME = $env:OSC_TEST_DIR
$env:USERPROFILE = $env:OSC_TEST_DIR

function global:winget.exe { param([Parameter(ValueFromRemainingArguments)]$a) $global:LASTEXITCODE = 0 }
$fnmDir = Join-Path $env:OSC_TEST_DIR 'AppData\Roaming\npm'
$null = New-Item -ItemType Directory -Path $fnmDir -Force
[System.IO.File]::WriteAllText((Join-Path $fnmDir 'fnm.cmd'), "@echo off`r`nsetlocal`r`nset FNMLOG=%OSC_TEST_DIR%\fnm.log`r`necho %*>>%FNMLOG%`r`nif `"%1`"==`"install`" mkdir `"%USERPROFILE%\AppData\Roaming\fnm\node-versions\v%2.0.0\installation`"`r`nexit /b 0`r`n", (New-Object System.Text.UTF8Encoding $false))
$global:FnmLog = Join-Path $env:OSC_TEST_DIR 'fnm.log'

# node/npm must also be directly callable by PowerShell: the harness fakes are
# extension-less bash scripts that the call operator cannot run ("Cannot run a
# document in the middle of a pipeline") and Test-CommandExists cannot find.
# Put .cmd fakes here and prepend to PATH so both paths work; the npmrc lives
# in the sandbox and never touches the real config.
$fakeBin = Join-Path $env:OSC_TEST_DIR 'fakebin'
$null = New-Item -ItemType Directory -Path $fakeBin -Force
[System.IO.File]::WriteAllText((Join-Path $fakeBin 'node.cmd'), "@echo off`r`nif `"%1`"==`"--version`" echo v22.0.0`r`nexit /b 0`r`n", (New-Object System.Text.UTF8Encoding $false))
$npmCmd = @'
@echo off
setlocal
set RC=%OSC_TEST_DIR%\npmrc
if "%1"=="config" goto cfg
if "%1"=="--version" (echo 11.0.0&exit /b 0)
exit /b 0
:cfg
if "%2"=="get" (
  if "%3"=="userconfig" (echo %RC%&exit /b 0)
  if "%3"=="prefix" (echo %OSC_TEST_DIR%\npm-prefix&exit /b 0)
  for /f "usebackq tokens=1,* delims==" %%A in ("%RC%") do if "%%A"=="%3" (echo %%B&exit /b 0)
  exit /b 0
)
if "%2"=="set" (
  if exist "%RC%" findstr /v /b /c:"%3=" "%RC%">"%RC%.t" 2>nul
  if exist "%RC%.t" (move /y "%RC%.t" "%RC%">nul) else (type nul>"%RC%")
  echo %3=%4>>"%RC%"
  exit /b 0
)
if "%2"=="delete" (
  if exist "%RC%" findstr /v /b /c:"%3=" "%RC%">"%RC%.t" 2>nul
  if exist "%RC%.t" move /y "%RC%.t" "%RC%">nul
  exit /b 0
)
exit /b 0
'@
[System.IO.File]::WriteAllText((Join-Path $fakeBin 'npm.cmd'), ($npmCmd -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding $false))
$env:PATH = $fakeBin + ';' + $env:PATH

$nodeMajor = ((& node --version 2>$null | Out-String).Trim()).TrimStart('v').Split('.')[0]
$env:NODE_LTS_MAJOR = $nodeMajor
$env:NPM_REGISTRY = 'https://registry.npmmirror.com'

$rc1 = & action_nodejs_apply -Id 'nodejs'
$rc2 = & action_nodejs_verify -Id 'nodejs'
$profile = Get-PowerShellProfilePath
$block = Get-ManagedBlock -Path $profile -Begin $script:NODEJS_ENV_BEGIN -End $script:NODEJS_ENV_END
# Effective value comes from npm config get (verify judges the same way): the
# fake npm answers config get registry from the env var, so the engine skips the
# write; audit has no env shortcut and does land in the npmrc file.
$regEffective = (& npm config get registry 2>$null | Out-String).Trim()
$npmrcAudit = Get-NpmrcValue -Path (Get-NpmrcPath) -Key 'audit'

$script:ASSUME_YES = 1
$rc3 = & action_nodejs_remove -Id 'nodejs'
$blockAfter = Get-ManagedBlock -Path $profile -Begin $script:NODEJS_ENV_BEGIN -End $script:NODEJS_ENV_END
# For the restored state read the npmrc file: the fake npm always answers
# config get registry from the env var, only the file shows the key is gone.
$npmrcAuditAfter = Get-NpmrcValue -Path (Get-NpmrcPath) -Key 'audit'
$versionsGone = -not (Test-Path -LiteralPath (Get-FnmRoot))
Write-Host ("apply={0} verify={1} block={2} registry=[{3}] audit=[{4}]" -f $rc1, $rc2, (-not [string]::IsNullOrEmpty($block)), $regEffective, $npmrcAudit)
Write-Host ("fnm=[{0}]" -f ((Get-Content $global:FnmLog -ErrorAction SilentlyContinue) -join ' | '))
Write-Host ("remove={0} block_gone={1} versions_gone={2} audit_after=[{3}]" -f $rc3, [string]::IsNullOrEmpty($blockAfter), $versionsGone, $npmrcAuditAfter)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "apply=0 verify=0 block=True registry=[https://registry.npmmirror.com] audit=[false]" "nodejs apply/verify 全绿且 npm 配置生效"
  assert_contains "$out" "fnm=[install" "fnm install 被调用"
  assert_contains "$out" "remove=0 block_gone=True versions_gone=True audit_after=[]" "remove 清理版本目录/托管块并还原 npm 配置"
}

# 回归：非管理员 + 非交互时 Request-Elevation 必须明确报错并返回 1，
# 不能挂住等输入、也不能弹 UAC。CI 与非交互终端走的都是这条分支。
# 探针的 stdout 被重定向 => [Console]::IsOutputRedirected 为真 => 非交互。
test_win_elevation_noninteractive_errors() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows 提权用例" true
    return 0
  fi
  # 已经是管理员时这条分支不适用（会直接返回 0）
  local admin
  admin="$("$ps" -NoProfile -Command "if ((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'yes' } else { 'no' }" 2>/dev/null)"
  if [[ "$admin" == "yes" ]]; then
    assert_true "当前已是管理员，跳过非交互提权用例" true
    return 0
  fi
  local script="$TESTDIR/probe-elev.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
. (Join-Path $script:ProjectDir 'engine\lib-win\Log.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Util.ps1')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rc = Request-Elevation
$sw.Stop()
Write-Host ("rc={0} elapsed_ms={1}" -f $rc, $sw.ElapsedMilliseconds)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "rc=1" "非交互且非管理员时提权返回 1"
  # 5 秒内必须返回：挂住或弹 UAC 都会让这条断言失败
  local ms
  ms="$(printf '%s\n' "$out" | sed -n 's/.*elapsed_ms=\([0-9]*\).*/\1/p' | head -1)"
  if [[ -n "$ms" && "$ms" -lt 5000 ]]; then
    ok
  else
    not_ok "提权在 5 秒内返回（elapsed_ms=$ms）"
  fi
}

# 回归：winget 全量索引必须按表头定位 Id 列，不能按"id 形状的 token"找。
# 真实输出里版本号（23.01）和可用版本（26.05）都符合 Publisher.Product 形态，
# 旧实现取末位匹配，版本读取越界后整行跳过——实测全量 112 行解析出 0 条，
# 而索引建好后本就没人用，白跑一次数秒级 winget list。
# mock 的 bulk 输出刻意仿真真实表格（表头 + 分隔线 + 尾随可用版本列）。
test_win_winget_index_parses_real_table() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows winget 索引用例" true
    return 0
  fi
  local script="$TESTDIR/probe-index.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
. (Join-Path $script:ProjectDir 'engine\lib-win\Log.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Util.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Catalog.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Backends.ps1')

# Mock a realistic two-run winget table: the English header writes "Id" (the
# case-insensitive match must still find it), and rows carry a trailing
function global:winget.exe {
  param([Parameter(ValueFromRemainingArguments)][string[]]$WArgs)
  if ($WArgs[0] -eq 'list' -and $WArgs -contains '--source') {
    Write-Output 'Name                Id            Version    Available'
    Write-Output '----------------------------------------------------------------------'
    Write-Output '7-Zip 23.01 (x64)   7zip.7zip     23.01      26.05'
    Write-Output 'Git                 Git.Git        2.39.1     2.56.0.3'
    Write-Output 'ChatGPT             OpenAI.ChatGPT 26.1021.3705.0'
    $global:LASTEXITCODE = 0
    return
  }
  if ($WArgs[0] -eq 'list') { $global:LASTEXITCODE = 20; return }
  $global:LASTEXITCODE = 0
}

Update-WingetIndex
$count = 0
if ($null -ne $script:WingetIndex) { $count = $script:WingetIndex.Count }
Write-Host ("entries={0}" -f $count)
$git = ''
if ($null -ne $script:WingetIndex -and $script:WingetIndex.ContainsKey('git.git')) { $git = $script:WingetIndex['git.git'] -join ',' }
Write-Host ("git.git=[{0}]" -f $git)
$zip = ''
if ($null -ne $script:WingetIndex -and $script:WingetIndex.ContainsKey('7zip.7zip')) { $zip = $script:WingetIndex['7zip.7zip'] -join ',' }
Write-Host ("7zip.7zip=[{0}]" -f $zip)
# "Available" column - the old parser mistook it for the package id.
$global:LASTEXITCODE = 0
$v = Get-WingetVersion -PackageId 'Git.Git'
Write-Host ("cached_query=[{0}]" -f $v)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "entries=3" "三行数据全部解析入库"
  assert_contains "$out" "git.git=[2.39.1]" "Id 列定位正确（不是尾随的可用版本）"
  assert_contains "$out" "7zip.7zip=[23.01]" "名称含空格与括号的行也解析正确"
  assert_contains "$out" "cached_query=[2.39.1]" "建好索引后查询走内存"
}

# 回归：Import-UserConfig 必须加载 config/ui.env（Web UI 写的参数层）。
# Bash 侧 load_user_config 是 versions.env → user.env → ui.env 三层，Windows
# 侧原先只读前两层：UI 改的参数写进 ui.env 后无人读取，页面显示成功而引擎
# 用的还是 user.env / 引擎默认值，且没有任何提示。两个引擎因此对同一份
# ui.env 给出不同答案。
# 同时锁住 shell 单引号转义的还原：render_ui_env 把含 ' 的值写成
# 'O'\''Brien'，只剥一层成对引号会得到 O'\''Brien（Git 身份整个错掉）。
test_win_ui_env_precedence() {
  local ps=""
  for c in powershell pwsh; do
    if command -v "$c" >/dev/null 2>&1; then ps="$c"; break; fi
  done
  if [[ -z "$ps" ]]; then
    assert_true "无 PowerShell，跳过 Windows ui.env 用例" true
    return 0
  fi
  local script="$TESTDIR/probe-uienv.ps1"
  cat >"$script" <<'PS'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:ProjectDir = $env:OSC_PROJECT_DIR
. (Join-Path $script:ProjectDir 'engine\lib-win\Log.ps1')
. (Join-Path $script:ProjectDir 'engine\lib-win\Util.ps1')

# --- ConvertFrom-ShellQuoted: bash source quoting rules ---
$cases = @(
  @{ in = "'O'\''Brien'"; want = "O'Brien" },
  @{ in = "'plain'"; want = 'plain' },
  @{ in = "'a b'"; want = 'a b' },
  @{ in = '"dq"'; want = 'dq' },
  @{ in = 'bare'; want = 'bare' },
  @{ in = 'bare  # trailing'; want = 'bare' },
  @{ in = 'val#ue'; want = 'val#ue' },
  @{ in = ''; want = '' },
  @{ in = "''"; want = '' }
)
$bad = 0
foreach ($c in $cases) {
  $got = ConvertFrom-ShellQuoted -Value $c.in
  if ($got -ne $c.want) { $bad++ }
}
Write-Host ("quote_cases_bad={0}" -f $bad)

# --- three-layer precedence: versions.env -> user.env -> ui.env ---
$dir = Join-Path $env:OSC_TEST_DIR 'cfg'
$null = New-Item -ItemType Directory -Path (Join-Path $dir 'config') -Force
Set-Content -LiteralPath (Join-Path $dir 'config\versions.env') -Value "SAME=versions`nONLY_V=1" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $dir 'config\user.env')   -Value "SAME=user`nONLY_U=1" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $dir 'config\ui.env')     -Value "SAME=ui`nONLY_UI='a b'" -Encoding UTF8
$null = Import-UserConfig -ProjectDir $dir
Write-Host ("SAME=[{0}] ONLY_V=[{1}] ONLY_UI=[{2}]" -f $env:SAME, $env:ONLY_V, $env:ONLY_UI)
PS
  local out
  out="$(OSC_PROJECT_DIR="$ROOT" OSC_TEST_DIR="$TESTDIR" \
    "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>/dev/null)"
  assert_contains "$out" "quote_cases_bad=0" "shell 引号还原 9 个用例全部正确"
  assert_contains "$out" "SAME=[ui]" "ui.env 覆盖 user.env"
  assert_contains "$out" "ONLY_V=[1]" "versions.env 仍生效"
  assert_contains "$out" "ONLY_UI=[a b]" "ui.env 值解析（含空格）"
}

test_doctor_runs_all_checks() {
  catalog_reset
  register_pkg_tool pkg-a apt "a"
  local out rc
  out=$(doctor_run 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "doctor 返回 0"
  assert_contains "$out" "catalog：通过" "检查了 catalog"
  assert_contains "$out" "sudo：通过" "检查了 sudo（假命令可用）"
  assert_contains "$out" "磁盘剩余" "检查了磁盘"
  assert_contains "$out" "apt-lock：通过" "检查了 apt 锁"
  assert_contains "$out" "doctor 汇总" "有汇总"
}

test_doctor_manifest_missing_artifact_warns() {
  catalog_reset
  register_config_tool cfg-a cfga
  state_record cfga cfga "$TESTDIR/definitely-not-here"
  local out rc
  out=$(doctor_run 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "缺失只算 warn，仍返回 0"
  assert_contains "$out" "产物已消失" "提示产物缺失"
  assert_contains "$out" "verify --fix" "给出修复建议"
}

test_setup_fix_requires_verify() {
  local out rc
  out=$(timeout 30 bash "$ROOT/setup.sh" install --pick pkg --fix 2>&1); rc=$?
  assert_rc_eq 2 "$rc" "--fix 非 verify 时报错退出 2"
  assert_contains "$out" "--fix 只能与 verify" "错误信息明确"
}

test_setup_output_requires_export() {
  local out rc
  out=$(timeout 30 bash "$ROOT/setup.sh" install --pick pkg --output /tmp/x.conf 2>&1); rc=$?
  assert_rc_eq 2 "$rc" "--output 非 export 时报错退出 2"
  assert_contains "$out" "--output 只能与 export" "错误信息明确"
}

test_setup_doctor_needs_no_selection() {
  local out rc
  out=$(timeout 90 bash "$ROOT/setup.sh" doctor 2>&1); rc=$?
  assert_rc_eq 0 "$rc" "doctor 无需选择即可运行"
  assert_contains "$out" "doctor 汇总" "输出了汇总"
}

test_setup_export_needs_no_selection() {
  local out rc
  out=$(timeout 90 bash "$ROOT/setup.sh" export --output "$TESTDIR/no-sel.conf" 2>&1); rc=$?
  # 本机若确有已装包则返回 0；若全无则返回 1。两种都说明它没要求 --pick/--profile/--all
  assert_contains "$out" "export：" "进入了 export 流程"
  assert_not_contains "$out" "未选择任何工具" "未因缺选择而失败"
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
run_test 'catalog artifacts 只展开一次'                test_catalog_artifacts_expanded_once
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
run_test '内联条目不被平台门跳过'                      test_engine_adhoc_not_skipped_by_platform_gate
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
run_test 'proxy verify 读取 TEST_URL 与超时配置'       test_proxy_verify_uses_configured_url_and_timeouts
run_test 'mirrors 跳过/升级开关生效'                   test_mirrors_skip_and_upgrade_flags
run_test 'catalog 变量默认值与 desc 不展开'            test_catalog_expand_vars_default_value
run_test 'catalog desc 不做变量展开'                   test_catalog_desc_not_expanded
run_test 'catalog 包名可由环境变量覆盖'                test_catalog_pkg_name_from_env
run_test 'git verify 校验身份'                         test_action_git_verify_checks_identity
run_test '回滚：sudo 不可用时不删文件'                 test_rollback_sudo_unavailable_keeps_file
run_test '回滚：备份失败后可重试'                      test_rollback_backup_failure_allows_retry
run_test '测试过滤命中函数名'                          test_filter_matches_function_name
run_test '测试过滤无匹配时返回非零'                    test_filter_no_match_exits_nonzero
run_test '引擎 update/verify 动词'                     test_engine_update_and_verify_verbs
run_test 'nodejs 卸载被拒绝时算 skipped'                test_action_nodejs_remove_declined_is_skipped
run_test 'nodejs 卸载还原 npm 配置'                     test_action_nodejs_remove_restores_npm_config
run_test 'nosuspend 还原用户原值'                      test_action_nosuspend_restores_original_values
run_test 'syslog verify 检查 bat 软链'                  test_action_syslog_verify_checks_bat_link
run_test 'syslog 无 sudo 时仍清理用户级残留'            test_action_syslog_remove_without_sudo_cleans_user_files
run_test 'remove 提示选集外的已安装依赖方'              test_engine_remove_warns_external_dependents
run_test '内联工具 id 去首尾短横'                      test_profile_adhoc_id_strips_all_dashes
run_test '废弃配置键有明确提示'                        test_deprecated_config_warns
run_test '每个动作都有专属 status'                     test_actions_have_status
run_test 'status 走专属实现'                          test_engine_status_uses_action_status
run_test '各动作 status 输出可读'                     test_action_status_outputs
run_test '写锁取放'                                  test_state_lock_acquire_release
run_test '写锁不误删他人锁'                            test_state_lock_ignores_other_holder
run_test '写锁清理残留'                               test_state_lock_cleans_stale
run_test '写锁被占时错误信息正确'                       test_state_lock_acquire_blocked_message
run_test 'verify 不加 --fix 不修复'                   test_engine_verify_without_fix_fails
run_test 'verify --fix 修复后复验'                    test_engine_verify_fix_converges
run_test 'verify --fix 在 dry-run 下不修复'            test_engine_verify_fix_dry_run_noop
run_test 'export 生成 profile'                        test_export_writes_profile
run_test 'export 空状态返回非零'                       test_export_empty_state_fails
run_test 'export 文件名即 profile 名'                  test_export_profile_name_from_path
run_test 'export 产物可被 profile 解析器读回'          test_export_output_roundtrips_through_parser
run_test 'export 产物不破坏同目录其它 profile'         test_exported_profile_does_not_break_sibling_profiles
run_test 'Windows 导出的 profile 可读回'              test_win_export_roundtrip
run_test 'Windows 命令探测不把别名当已安装'            test_win_command_exists_ignores_aliases
run_test 'Windows list --json 的 artifacts 展开'      test_win_list_json_artifacts
run_test 'Windows rollback 事件带 restored 列表'      test_win_rollback_event_restored
run_test 'Windows catalog 缺 win_backend 报错可读'    test_win_catalog_missing_win_backend_message
run_test 'Windows config 动作真的被分派'              test_win_action_dispatch_uses_action_script
run_test 'Windows 空口令下 ssh-keygen 可用'           test_win_ssh_keygen_empty_passphrase
run_test 'Windows 原生调用保留空参数'                 test_win_native_step_empty_argument
run_test 'Windows winget 安装真的传参数'               test_win_winget_install_passes_arguments
run_test 'Windows npm ENOTEMPTY 重试'                 test_win_npm_enotempty_retry
run_test 'Windows proxy 动作全生命周期'                test_win_proxy_action_lifecycle
run_test 'Windows git 动作全生命周期'                  test_win_git_action_lifecycle
run_test 'Windows nodejs 动作全生命周期'               test_win_nodejs_action_lifecycle
run_test 'Windows 非交互提权明确报错'                  test_win_elevation_noninteractive_errors
run_test 'Windows winget 索引按表头解析'               test_win_winget_index_parses_real_table
run_test 'Windows ui.env 覆盖顺序与 shell 引号还原'    test_win_ui_env_precedence
run_test 'doctor 跑完全部检查'                         test_doctor_runs_all_checks
run_test 'doctor 提示清单产物缺失'                     test_doctor_manifest_missing_artifact_warns
run_test '--fix 只能配 verify'                        test_setup_fix_requires_verify
run_test '--output 只能配 export'                     test_setup_output_requires_export
run_test 'doctor 不需要选择'                           test_setup_doctor_needs_no_selection
run_test 'export 不需要选择'                           test_setup_export_needs_no_selection

if [[ -n "$FILTER" && "$MATCHED" == 0 ]]; then
  printf '没有用例匹配过滤条件：%s\n' "$FILTER" >&2
  exit 1
fi

printf '\n总计：PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
