#!/usr/bin/env bash
# 无外部测试框架的快速回归测试；不会修改宿主 /etc。
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0
FAIL=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
not_ok() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
run_test() {
  local name=$1; shift
  if ( "$@" ); then ok "$name"; else not_ok "$name"; fi
}

syntax_test() {
  while IFS= read -r -d '' f; do bash -n "$f" || return; done < <(find "$ROOT" -type f -name '*.sh' -print0)
  git -C "$ROOT" diff --check
}

args_test() {
  local args rc
  for args in '--module' '--platform' '--install-only --verify-only' '--all --module base'; do
    # 这里需要按空格拆分固定测试参数。
    read -r -a argv <<<"$args"
    "$ROOT/setup.sh" "${argv[@]}" >/dev/null 2>&1
    rc=$?
    [[ $rc == 2 ]] || { printf '%s => %s\n' "$args" "$rc" >&2; return 1; }
  done
}

dry_run_test() {
  "$ROOT/setup.sh" --platform ubuntu --all --dry-run >/dev/null 2>&1 || return
  ! "$ROOT/setup.sh" --platform windows --all --dry-run >/dev/null 2>&1 || return 1
}


platform_classification_test() {
  local t="$TMP_ROOT/platform"; mkdir -p "$t/bin"
  (
    export LOG_FILE="$t/test.log"
    . "$ROOT/lib/log.sh"
    . "$ROOT/lib/platform.sh"

    printf 'ID=ubuntu\nVERSION_ID="22.04"\n' >"$t/os-release"
    [[ $(OS_RELEASE_FILE="$t/os-release" detect_platform) == ubuntu ]] || exit 1
    OS_RELEASE_FILE="$t/os-release" bash "$ROOT/platforms/ubuntu/detect.sh" >/dev/null 2>&1 || exit 1

    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$t/os-release"
    [[ $(OS_RELEASE_FILE="$t/os-release" detect_platform) == ubuntu ]] || exit 1
    OS_RELEASE_FILE="$t/os-release" bash "$ROOT/platforms/ubuntu/detect.sh" >/dev/null 2>&1 || exit 1

    printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$t/os-release"
    ! OS_RELEASE_FILE="$t/os-release" detect_platform >/dev/null 2>&1 || exit 1

    printf 'ID=kylin\nVERSION_ID="V10"\n' >"$t/os-release"
    ! OS_RELEASE_FILE="$t/os-release" detect_platform >/dev/null 2>&1 || exit 1

    cat >"$t/bin/uname" <<'UNAME'
#!/usr/bin/env bash
printf '%s\n' aarch64
UNAME
    chmod +x "$t/bin/uname"
    [[ $(PATH="$t/bin:$PATH" detect_architecture) == arm64 ]]
  )
}

runner_test() {
  local t="$TMP_ROOT/runner"; mkdir -p "$t/modules"/{a,b,c}
  cat >"$t/modules/a/module.conf" <<'E'; cat >"$t/modules/b/module.conf" <<'E2'; cat >"$t/modules/c/module.conf" <<'E3'
NAME=a
DEPS=
NEEDS_SUDO=0
E
NAME=b
DEPS=a
NEEDS_SUDO=0
E2
NAME=c
DEPS=
NEEDS_SUDO=0
E3
  printf '#!/usr/bin/env bash\nexit 9\n' >"$t/modules/a/install.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$t/modules/b/install.sh"
  printf '#!/usr/bin/env bash\nprintf c-ran >%q\n' "$t/c-ran" >"$t/modules/c/install.sh"
  chmod +x "$t"/modules/*/install.sh
  (
    export LOG_FILE="$t/test.log" KEEP_GOING=1 INSTALL_ONLY=1 VERIFY_ONLY=0 DRY_RUN=0 NO_SUDO=0 FORCE=0 DEBUG=0
    . "$ROOT/lib/log.sh"; . "$ROOT/lib/utils.sh"; . "$ROOT/lib/runner.sh"
    set +e
    runner_run_modules "$t" a b c >/dev/null 2>&1
    rc=$?
    set -e
    [[ $rc == 1 && "${_M_STATUS[a]}" == failed && "${_M_STATUS[b]}" == blocked && "${_M_STATUS[c]}" == ok && -f "$t/c-ran" ]]
  )
}

metadata_test() {
  local t="$TMP_ROOT/meta"; mkdir -p "$t/modules"/{one,two}
  printf 'NAME=dup\nDEPS=\nNEEDS_SUDO=0\n' >"$t/modules/one/module.conf"
  printf 'NAME=dup\nDEPS=\nNEEDS_SUDO=0\n' >"$t/modules/two/module.conf"
  (
    export LOG_FILE="$t/test.log"
    . "$ROOT/lib/log.sh"; . "$ROOT/lib/runner.sh"
    ! runner_load_modules "$t" >/dev/null 2>&1
  )
}

verbose_redaction_test() {
  local t="$TMP_ROOT/log"; mkdir -p "$t"
  (
    export LOG_FILE="$t/test.log"
    . "$ROOT/lib/log.sh"; . "$ROOT/lib/utils.sh"
    set +e
    run_step_verbose secret bash -c 'echo "token=abc Authorization: Bearer xyz https://u:p@example.com"; exit 9' >/dev/null 2>&1
    rc=$?
    set -e
    [[ $rc == 9 ]] || exit 1
    grep -q 'token=\*\*\*\*' "$LOG_FILE" || exit 1
    grep -q 'Authorization: Bearer \*\*\*\*' "$LOG_FILE" || exit 1
    ! grep -q 'xyz\|u:p' "$LOG_FILE" || exit 1
    [[ $(stat -c '%a' "$LOG_FILE") == 600 ]]
  )
}

rollback_test() {
  local t="$TMP_ROOT/rollback"; mkdir -p "$t/bin"
  cat >"$t/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
  chmod +x "$t/bin/sudo"
  (
    export PATH="$t/bin:$PATH" LOG_FILE="$t/test.log"
    . "$ROOT/lib/log.sh"; . "$ROOT/lib/utils.sh"
    printf old >"$t/user-existing"
    register_rollback "$t/user-existing"
    printf new >"$t/user-existing"
    register_rollback "$t/user-created"
    printf created >"$t/user-created"
    register_rollback "$t/sudo-created" sudo
    printf created >"$t/sudo-created"
    rollback_on_exit 1
    [[ $(cat "$t/user-existing") == old && ! -e "$t/user-created" && ! -e "$t/sudo-created" ]]
  )
}

npm_test() {
  local t="$TMP_ROOT/npm"; mkdir -p "$t/bin" "$t/prefix/lib/node_modules/@scope"
  cat >"$t/bin/npm" <<'NPM'
#!/usr/bin/env bash
if [[ "${1:-}" == config ]]; then printf '%s\n' "$FAKE_PREFIX"; exit 0; fi
mkdir -p "$FAKE_STATE"
n=0; [[ ! -f "$FAKE_STATE/count" ]] || n=$(cat "$FAKE_STATE/count")
n=$((n+1)); echo "$n" >"$FAKE_STATE/count"
case "$FAKE_MODE" in
  success) echo 'token=secret'; exit 0 ;;
  fail) echo 'npm ERR! EACCES'; exit 7 ;;
  enotempty) (( n == 1 )) && { echo 'npm ERR! ENOTEMPTY'; exit 217; }; echo retry-ok ;;
esac
NPM
  chmod +x "$t/bin/npm"
  (
    export PATH="$t/bin:$PATH" LOG_FILE="$t/test.log" FAKE_PREFIX="$t/prefix" FAKE_STATE="$t/state"
    . "$ROOT/lib/log.sh"; . "$ROOT/lib/utils.sh"
    export FAKE_MODE=success; npm_install_global_fixed foo 1.0.0 '' >/dev/null 2>&1 || exit
    rm -rf "$FAKE_STATE"; export FAKE_MODE=fail; set +e; npm_install_global_fixed foo 1.0.0 '' >/dev/null 2>&1; rc=$?; set -e
    [[ $rc == 7 ]] || exit 1
    rm -rf "$FAKE_STATE"; export FAKE_MODE=enotempty
    mkdir -p "$FAKE_PREFIX/lib/node_modules/@scope/pkg" "$FAKE_PREFIX/lib/node_modules/@scope/.pkg-old"
    printf keep >"$FAKE_PREFIX/lib/node_modules/@scope/pkg/marker"
    npm_install_global_fixed @scope/pkg 1.0.0 '' >/dev/null 2>&1 || exit
    [[ $(cat "$FAKE_STATE/count") == 2 && -f "$FAKE_PREFIX/lib/node_modules/@scope/pkg/marker" && ! -e "$FAKE_PREFIX/lib/node_modules/@scope/.pkg-old" ]]
  )
}

proxy_test() {
  local t="$TMP_ROOT/proxy"; mkdir -p "$t/home" "$t/bin"
  cat >"$t/bin/ip" <<'IP'
#!/usr/bin/env bash
printf '%s\n' '1.1.1.1 via 192.168.114.254 dev eth0 src 192.168.114.147 uid 1000'
IP
  cat >"$t/bin/ping" <<'PING'
#!/usr/bin/env bash
[[ "${FAKE_PING_FAIL:-0}" != 1 ]]
PING
  cat >"$t/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_CURL_ARGS:?}"
[[ "${FAKE_CURL_FAIL:-0}" != 1 ]]
CURL
  chmod +x "$t/bin/ip" "$t/bin/ping" "$t/bin/curl"
  export FAKE_CURL_ARGS="$t/curl-args"

  HOME="$t/home" PROJECT_DIR="$ROOT" PROXY_ENABLED=false \
    bash "$ROOT/platforms/ubuntu/modules/net-proxy/install.sh" >/dev/null 2>&1 || return
  [[ ! -e "$t/home/.bashrc" ]] || return 1

  PATH="$t/bin:$PATH" HOME="$t/home" PROJECT_DIR="$ROOT" PROXY_ENABLED=true PROXY_HOST= PROXY_PORT= \
    NO_PROXY='localhost,$HOME' bash "$ROOT/platforms/ubuntu/modules/net-proxy/install.sh" >/dev/null 2>&1 || return
  bash -n "$t/home/.bashrc" || return
  grep -Fq 'http://192.168.114.1:7890' "$t/home/.bashrc" || return
  PATH="$t/bin:$PATH" HOME="$t/home" PROJECT_DIR="$ROOT" PROXY_ENABLED=true PROXY_HOST= PROXY_PORT= \
    bash "$ROOT/platforms/ubuntu/modules/net-proxy/verify.sh" >/dev/null 2>&1 || return
  grep -Fxq -- '-x' "$FAKE_CURL_ARGS" || return
  grep -Fxq 'http://192.168.114.1:7890' "$FAKE_CURL_ARGS" || return
  grep -Fxq 'https://github.com' "$FAKE_CURL_ARGS" || return

  output=$(PATH="$t/bin:$PATH" HOME="$t/home" PROJECT_DIR="$ROOT" PROXY_ENABLED=true PROXY_HOST= PROXY_PORT= \
    GIT_USER_NAME= GIT_USER_EMAIL= bash "$ROOT/platforms/ubuntu/modules/net-git/install.sh" 2>&1) || return
  grep -Fq $'GIT_USER_NAME 未设置：跳过 git 全局 user.name 配置；请执行以下命令：\n       git config --global user.name "你的姓名"' <<<"$output" || return
  grep -Fq $'GIT_USER_EMAIL 未设置：跳过 git 全局 user.email 配置；请执行以下命令：\n       git config --global user.email "your-email@example.com"' <<<"$output" || return
  [[ -z $(HOME="$t/home" git config --global --get user.name 2>/dev/null) ]] || return
  [[ -z $(HOME="$t/home" git config --global --get user.email 2>/dev/null) ]] || return
  [[ $(HOME="$t/home" git config --global --get http.proxy) == http://192.168.114.1:7890 ]] || return
  [[ $(HOME="$t/home" git config --global --get https.proxy) == http://192.168.114.1:7890 ]] || return
  PATH="$t/bin:$PATH" HOME="$t/home" PROJECT_DIR="$ROOT" PROXY_ENABLED=true PROXY_HOST= PROXY_PORT= \
    bash "$ROOT/platforms/ubuntu/modules/net-git/verify.sh" >/dev/null 2>&1 || return

  output=$(PATH="$t/bin:$PATH" HOME="$t/home" PROJECT_DIR="$ROOT" PROXY_ENABLED=true PROXY_HOST= PROXY_PORT= \
    FAKE_CURL_FAIL=1 bash "$ROOT/platforms/ubuntu/modules/net-proxy/verify.sh" 2>&1)
  rc=$?
  [[ $rc == 1 ]] || return
  grep -Fq 'curl -x http://192.168.114.1:7890 https://github.com' <<<"$output" || return
  grep -Fq 'curl 代理访问验证失败' <<<"$output" || return

  output=$(PATH="$t/bin:$PATH" HOME="$t/home" PROJECT_DIR="$ROOT" PROXY_ENABLED=true PROXY_HOST= PROXY_PORT= \
    FAKE_PING_FAIL=1 bash "$ROOT/platforms/ubuntu/modules/net-proxy/verify.sh" 2>&1)
  rc=$?
  [[ $rc == 1 ]] || return
  grep -Fq '1、先确认本机 IP 和网卡是否正确' <<<"$output" || return
  grep -Fq '2、检查代理主机 192.168.114.1 是否开启防火墙' <<<"$output" || return
  grep -Fq '放行代理 TCP 端口 7890' <<<"$output"
}

base_tools_test() {
  local t="$TMP_ROOT/base-tools" output rc
  mkdir -p "$t/bin"

  cat >"$t/catalog" <<'CATALOG'
core|核心依赖|curl|curl|fakecurl|HTTP 客户端
archive|压缩解压|zip|zip unzip|fakezip fakeunzip|ZIP 工具
system|系统管理|jq|jq|fakejq|JSON 工具
CATALOG
  cat >"$t/config" <<'CONFIG'
[core]
enabled=true
curl=true
[archive]
enabled=true
zip=true
[system]
enabled=false
jq=true
CONFIG

  (
    export PROJECT_DIR="$ROOT" LOG_FILE="$t/parser.log"
    . "$ROOT/lib/log.sh"
    . "$ROOT/platforms/ubuntu/modules/sys-base/packages.sh"
    base_load_selection "$ROOT/config/base-tools.conf" \
      "$ROOT/platforms/ubuntu/modules/sys-base/packages.catalog" || exit
    (( ${#BASE_SELECTED_TOOLS[@]} > 0 )) || exit 1
    base_load_selection "$t/config" "$t/catalog" || exit
    [[ "${BASE_SELECTED_TOOLS[*]}" == 'core.curl archive.zip' ]] || exit 1
    [[ "${BASE_SELECTED_PACKAGES[*]}" == 'curl zip unzip' ]] || exit 1
  ) || return

  cat >"$t/invalid.conf" <<'CONFIG'
[archive]
enabled=true
not-a-tool=true
CONFIG
  output=$(
    PROJECT_DIR="$ROOT" LOG_FILE="$t/invalid.log" bash -c '
      . "$PROJECT_DIR/lib/log.sh"
      . "$PROJECT_DIR/platforms/ubuntu/modules/sys-base/packages.sh"
      base_load_selection "$1" "$2"
    ' _ "$t/invalid.conf" "$t/catalog" 2>&1
  )
  rc=$?
  [[ $rc == 1 ]] || return
  grep -Fq '基础工具配置包含未知工具' <<<"$output" || return

  cat >"$t/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == fuser ]] && exit 1
done
printf '%s\n' "$*" >>"${FAKE_SUDO_LOG:?}"
SUDO
  cat >"$t/bin/dpkg-query" <<'DPKG'
#!/usr/bin/env bash
package="${!#}"
if [[ "${FAKE_ALL_INSTALLED:-0}" == 1 || "$package" == curl ]]; then
  printf '%s\n' 'install ok installed'
  exit 0
fi
exit 1
DPKG
  for command_name in fakecurl fakezip fakeunzip; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$t/bin/$command_name"
  done
  chmod +x "$t/bin"/*

  : >"$t/sudo.log"
  PATH="$t/bin:$PATH" PROJECT_DIR="$ROOT" LOG_FILE="$t/install.log" \
    BASE_TOOLS_CONFIG="$t/config" BASE_TOOLS_CATALOG="$t/catalog" \
    FAKE_SUDO_LOG="$t/sudo.log" APT_UPGRADE=false \
    bash "$ROOT/platforms/ubuntu/modules/sys-base/install.sh" >/dev/null 2>&1 || return
  grep -Fxq 'apt-get update' "$t/sudo.log" || return
  grep -Fxq 'DEBIAN_FRONTEND=noninteractive apt-get -y install zip unzip' "$t/sudo.log" || return
  ! grep -Eq 'install .*curl' "$t/sudo.log" || return 1

  : >"$t/sudo.log"
  PATH="$t/bin:$PATH" PROJECT_DIR="$ROOT" LOG_FILE="$t/force.log" \
    BASE_TOOLS_CONFIG="$t/config" BASE_TOOLS_CATALOG="$t/catalog" \
    FAKE_SUDO_LOG="$t/sudo.log" APT_UPGRADE=false \
    bash "$ROOT/platforms/ubuntu/modules/sys-base/install.sh" --force >/dev/null 2>&1 || return
  grep -Fxq 'DEBIAN_FRONTEND=noninteractive apt-get -y --reinstall install curl zip unzip' "$t/sudo.log" || return

  PATH="$t/bin:$PATH" PROJECT_DIR="$ROOT" LOG_FILE="$t/verify.log" \
    BASE_TOOLS_CONFIG="$t/config" BASE_TOOLS_CATALOG="$t/catalog" FAKE_ALL_INSTALLED=1 \
    bash "$ROOT/platforms/ubuntu/modules/sys-base/verify.sh" >/dev/null 2>&1
}

run_test '所有 Shell 脚本语法与 diff 格式' syntax_test
run_test 'sys-base 二维配置、动态安装、force 与验证' base_tools_test
run_test 'setup 参数冲突与缺值返回 2' args_test
run_test 'ubuntu dry-run 与未实现平台拦截' dry_run_test
run_test '操作系统族与 CPU 架构分类' platform_classification_test
run_test 'runner keep-going/blocked/最终返回码' runner_test
run_test 'module.conf 重名校验' metadata_test
run_test 'verbose 返回码、日志脱敏与权限' verbose_redaction_test
run_test '用户文件与 fake-sudo 新文件回滚' rollback_test
run_test 'npm 普通失败与 ENOTEMPTY 定向修复' npm_test
run_test 'Git 空身份、代理推导、ping 与 curl 真实访问验证' proxy_test

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
