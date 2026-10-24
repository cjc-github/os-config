#!/usr/bin/env bash
# ui.sh —— os-config 本机 Web UI 启动器
# ---------------------------------------------------------------------------
# 只监听本机（127.0.0.1/localhost），每次启动生成一次性 token。
# 不做业务逻辑：参数校验、sudo 预授权、启动 ui.server、清理子进程。
# 不要加 set -e（清理与错误提示要可控）。
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST="127.0.0.1"
PORT=8765
NO_OPEN=0
SERVER_PID=""
KEEPALIVE_PID=""
# 由 cleanup 置位，用来区分“用户主动停止”和“服务自身异常退出”。
STOPPING=0

usage() {
  cat <<'EOF'
用法: ./ui.sh [选项]

选项:
  --port N        监听端口（1-65535，默认 8765）
  --host H        监听地址（仅 127.0.0.1 或 localhost，默认 127.0.0.1）
  --no-open       不自动打开浏览器，只打印访问地址
  --help          显示本帮助

启动后终端会打印带 token 的访问地址；token 也可从 URL 中取出后直接访问。
EOF
}

die_usage() {
  printf '错误: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

cleanup() {
  STOPPING=1
  trap - INT TERM EXIT
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$KEEPALIVE_PID" ]] && kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
    pkill -P "$KEEPALIVE_PID" 2>/dev/null || true
    kill "$KEEPALIVE_PID" 2>/dev/null || true
    wait "$KEEPALIVE_PID" 2>/dev/null || true
  fi
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      [[ $# -ge 2 ]] || die_usage "--port 需要一个值"
      PORT="$2"; shift 2 ;;
    --port=*)
      PORT="${1#*=}"; shift ;;
    --host)
      [[ $# -ge 2 ]] || die_usage "--host 需要一个值"
      HOST="$2"; shift 2 ;;
    --host=*)
      HOST="${1#*=}"; shift ;;
    --no-open)
      NO_OPEN=1; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      die_usage "未知参数: $1" ;;
  esac
done

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  die_usage "端口必须是 1-65535 的整数: $PORT"
fi
if [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" ]]; then
  die_usage "只允许监听本机地址（127.0.0.1 或 localhost）: $HOST"
fi
# 解释器探测：Windows 的 Git Bash 里常常只有 python 没有 python3，而
# Microsoft Store 的 python3 存根一执行就退出 49——所以必须真跑一次。
PY_BIN=""
for _pycand in python3 python py; do
  _pypath="$(command -v "$_pycand" || true)"
  [[ -n "$_pypath" ]] || continue
  if "$_pypath" -c 'import sys' >/dev/null 2>&1; then PY_BIN="$_pypath"; break; fi
done
if [[ -z "$PY_BIN" ]]; then
  printf '错误: 需要 python（>= 3.10）\n' >&2
  exit 1
fi
# 只检查"存在"是不够的：服务端用了 3.10 才有的语法（X | Y 类型标注），
# 低版本会在启动后直接抛 SyntaxError。
py_ver="$("$PY_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
if [[ ! "$py_ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
  printf '错误: 无法识别 python 版本（当前：%s），需要 python >= 3.10\n' "${py_ver:-未知}" >&2
  exit 1
fi
py_major="${py_ver%%.*}"
py_minor="${py_ver##*.}"
if (( 10#$py_major < 3 || (10#$py_major == 3 && 10#$py_minor < 10) )); then
  printf '错误: 需要 python >= 3.10（当前：%s）\n' "$py_ver" >&2
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  os_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
  if [[ "$os_id" != "ubuntu" ]]; then
    printf '警告: 已在非 Ubuntu 环境启动，部分动作可能不可用\n' >&2
  fi
fi

STATE_UI="$ROOT/state/ui"
mkdir -p "$STATE_UI"
umask 077
LOG="$STATE_UI/server.log"
: >"$LOG"

trap cleanup INT TERM EXIT

if [[ -t 0 ]] && command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    :
  else
    printf '需要 sudo 权限，请在下方输入密码（仅本次会话）...\n' >&2
    if sudo -v >/dev/null 2>&1; then
      (
        while sleep 50; do
          sudo -n -v >/dev/null 2>&1 || break
        done
      ) &
      KEEPALIVE_PID=$!
    else
      printf '警告: sudo 预授权失败，需要 sudo 的动作可能无法执行\n' >&2
    fi
  fi
fi

TOKEN="$("$PY_BIN" -c 'import secrets;print(secrets.token_urlsafe(32))')"
if [[ -z "$TOKEN" ]]; then
  printf '错误: 无法生成访问 token\n' >&2
  exit 1
fi

port_ready() {
  "$PY_BIN" -c 'import socket,sys
s=socket.socket(); s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()' "$PORT"
}

# 端口已被占用时直接失败：否则就绪探测会连上别的服务，
# 打印一个带新 token 的地址，而实际服务仍是旧进程（表现为 unauthorized）。
if port_ready >/dev/null 2>&1; then
  printf '错误: 端口 %s 已被占用，请关闭占用该端口的进程或改用 --port 指定其他端口\n' "$PORT" >&2
  exit 1
fi

PYTHONPATH="$ROOT" OS_CONFIG_UI_TOKEN="$TOKEN" \
  "$PY_BIN" -m ui.server --host "$HOST" --port "$PORT" >>"$LOG" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 100); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  if port_ready >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 0.1
done

if (( ready == 0 )); then
  printf '错误: 服务未能在 10 秒内就绪。端口可能被占用，请用 --port 指定其他端口\n' >&2
  printf '服务日志: %s\n' "$LOG" >&2
  exit 1
fi

URL="http://$HOST:$PORT/?token=$TOKEN"
printf 'os-config UI 已启动: %s\n' "$URL"
printf '服务日志: %s\n' "$LOG"
if (( NO_OPEN == 0 )) && [[ -t 0 ]] && command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 || true
fi
printf '按 Ctrl-C 停止。\n'

wait "$SERVER_PID" 2>/dev/null
rc=$?
# 用户主动停止时 wait 会被信号打断（130/143），这不算服务故障。
if (( STOPPING == 1 )) && (( rc >= 128 )); then
  rc=0
fi
exit "$rc"
