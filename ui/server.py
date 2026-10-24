"""本地 Web UI 的 HTTP 服务。

只监听本机，所有请求都需要 token。服务本身无状态，状态全部落在
``state/ui/`` 与 ``config/`` 下，便于测试和重启恢复。
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from ui import schema


# 请求体上限：本 UI 的最大载荷是参数表单与 pick 列表，1 MiB 已远超实际需要。
_MAX_BODY_BYTES = 1 << 20
# 计划生成只做本地解析，正常远低于此值；超时保证 handler 不被卡死。
_PLAN_TIMEOUT = 60


@dataclass
class AppConfig:
    project_dir: Path
    static_dir: Path
    state_dir: Path
    host: str = "127.0.0.1"
    port: int = 8765
    token: str = ""
    setup_cmd: list[str] | None = None

    def __post_init__(self) -> None:
        self.project_dir = Path(self.project_dir)
        self.static_dir = Path(self.static_dir)
        self.state_dir = Path(self.state_dir)
        if self.setup_cmd is None:
            self.setup_cmd = default_engine_command(self.project_dir)
        else:
            self.setup_cmd = list(self.setup_cmd)


def default_engine_command(project_dir: Path,
                           platform: str | None = None) -> list[str]:
    """按平台选择引擎入口。

    Windows 上用 PowerShell 跑 ``setup.ps1``，其余平台用 bash 跑
    ``setup.sh``。两个引擎的动词、选择参数、``--list --json`` 输出与
    JSONL 事件流完全一致，因此上层（catalog 加载、计划预览、任务执行）
    不需要知道当前跑的是哪一个；测试可显式传 ``setup_cmd`` 覆盖。

    ``platform`` 仅供测试注入（``"nt"`` / ``"posix"``），默认取 ``os.name``。
    """
    if platform is None:
        platform = os.name
    project_dir = Path(project_dir)
    if platform == "nt":
        return [
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(project_dir / "setup.ps1"),
        ]
    return ["bash", str(project_dir / "setup.sh")]


class EventBus:
    """进程内事件环形缓冲与订阅分发。"""

    def __init__(self, capacity: int = 2000):
        self._lock = threading.Lock()
        self._events: deque[tuple[int, str, dict]] = deque(maxlen=capacity)
        self._next_id = 0
        self._subscribers: set[queue.Queue] = set()

    def publish(self, name: str, data: dict) -> tuple[int, str, dict]:
        with self._lock:
            self._next_id += 1
            item = (self._next_id, name, data)
            self._events.append(item)
            subscribers = list(self._subscribers)
        for subscriber in subscribers:
            try:
                subscriber.put_nowait(item)
            except queue.Full:
                pass
        return item

    def subscribe(self) -> tuple[queue.Queue, list[tuple[int, str, dict]]]:
        subscriber: queue.Queue = queue.Queue(maxsize=1000)
        with self._lock:
            backlog = list(self._events)
            self._subscribers.add(subscriber)
        return subscriber, backlog

    def unsubscribe(self, subscriber: queue.Queue) -> None:
        with self._lock:
            self._subscribers.discard(subscriber)


class UIServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, config: AppConfig):
        self.config = config
        self.current_job = None
        self.catalog_cache: dict | None = None
        self.event_bus = EventBus()
        self.run_lock = threading.Lock()
        self.lock_path = config.state_dir / "ui" / "run.lock"
        super().__init__(address, handler)


_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
}

_TOKEN_COOKIE = "os_config_token"
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_RUN_VERBS = ("install", "update", "remove", "verify", "status")
# 只读动词用 --dry-run 预览时不会短路（引擎只对写动词短路），
# 因此预览一律用写动词生成，避免真的去跑 curl 校验之类的副作用。


def _terminate_process_tree(proc: subprocess.Popen) -> None:
    """超时后终止子进程。

    Windows 上没有 ``os.killpg`` 与 ``signal.SIGKILL``（直接 AttributeError），
    用 ``taskkill /T`` 杀整棵进程树——否则 powershell 起的原生子进程会继续
    持有 stdout 管道，让随后的 ``communicate()`` 永远等不到 EOF。
    POSIX 上沿用原来的进程组 SIGKILL。两条路都失败时退回 ``proc.kill()``。
    """
    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                capture_output=True, timeout=15, check=False)
            return
        except (OSError, subprocess.SubprocessError):
            pass
    else:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
            return
        except OSError:
            pass
    try:
        proc.kill()
    except OSError:
        pass
_PLAN_VERBS = ("install", "update", "remove")
_HISTORY_LOG_LIMIT = 1024 * 1024

# 与 engine/lib/log.sh 的 _redact 保持一致：写盘与推送前统一脱敏。
_REDACT_PATTERNS = (
    (re.compile(r"((?:sk-|token|password|passphrase|api[_-]?key|secret)=)[^\s]+",
                re.IGNORECASE), r"\1****"),
    (re.compile(r"(^|[^A-Za-z0-9_-])(sk-[A-Za-z0-9_-]{8,})"), r"\1sk-****"),
    (re.compile(r"(^|[^A-Za-z0-9_-])"
                r"(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})"),
     r"\1****"),
    (re.compile(r"(Authorization:\s*Bearer\s+)[^\s]+", re.IGNORECASE),
     r"\1****"),
    (re.compile(r"(https?://)[^/@\s]+:[^/@\s]+@"), r"\1****:****@"),
)


def _redact(line: str) -> str:
    for pattern, replacement in _REDACT_PATTERNS:
        line = pattern.sub(replacement, line)
    return line


# 引擎的 log_info/ok/warn/error 输出形如 `[INFO] [git] ...`；工具 id 不含点，
# 避免把 rollback 脚本里的 `[install.sh]` 误认成条目。
_LOG_ITEM_RE = re.compile(
    r"^\[(?:INFO|OK|WARN|ERROR|DEBUG)\]\s+\[([A-Za-z0-9][A-Za-z0-9_-]*)\]")


def _log_item_id(line: str, current: str | None) -> str | None:
    """从一行日志推断所属工具；无前缀时回落到当前执行中的条目。"""
    match = _LOG_ITEM_RE.match(line)
    if match:
        return match.group(1)
    return current


def _pick_arg(pick: list[str]) -> str:
    """setup.sh 的 --pick 只接受一个逗号分隔的参数。"""
    return ",".join(pick)


def _pick_ids(pick: list[str]) -> list[str]:
    """把 pick token 转成规范化后的工具 id（内联 token 与 profile.sh 规则一致）。"""
    return [schema.normalize_adhoc_id(token)[0] if ":" in token else token
            for token in pick]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: UIServer

    # -- 响应 ---------------------------------------------------------------
    def _send_bytes(self, status: int, body: bytes, content_type: str,
                    headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: dict | list,
                   headers: dict[str, str] | None = None) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send_bytes(status, body, "application/json; charset=utf-8", headers)

    def _error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    # -- 鉴权 ---------------------------------------------------------------
    def _auth_token(self) -> str | None:
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            return header[len("Bearer "):].strip()
        header = self.headers.get("X-UI-Token", "").strip()
        if header:
            return header
        return None

    def _query_token(self) -> str | None:
        values = parse_qs(urlsplit(self.path).query).get("token")
        if values:
            return values[0]
        return None

    def _cookie_token(self) -> str | None:
        raw = self.headers.get("Cookie")
        if not raw:
            return None
        cookie = SimpleCookie()
        try:
            cookie.load(raw)
        except Exception:
            return None
        morsel = cookie.get(_TOKEN_COOKIE)
        return morsel.value if morsel is not None else None

    def _authorized(self) -> bool:
        expected = self.server.config.token
        if not expected:
            return False
        for candidate in (self._auth_token(), self._cookie_token(),
                          self._query_token()):
            if candidate is not None and secrets.compare_digest(
                    candidate, expected):
                return True
        return False

    def _cookie_headers(self) -> dict[str, str]:
        if self._query_token() is None:
            return {}
        token = self.server.config.token
        return {"Set-Cookie": (
            f"{_TOKEN_COOKIE}={token}; HttpOnly; SameSite=Strict; Path=/")}

    # -- 路由 ---------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802 - http.server 约定
        if not self._authorized():
            self._error(HTTPStatus.UNAUTHORIZED, "unauthorized")
            return
        path = urlsplit(self.path).path
        if path in ("/", "/index.html"):
            self._serve_static("index.html")
        elif path.startswith("/static/"):
            self._serve_static(path[len("/static/"):])
        elif path == "/api/catalog":
            self._api_catalog()
        elif path == "/api/state":
            self._api_state()
        elif path == "/api/installed":
            self._api_installed()
        elif path == "/api/status":
            self._api_status()
        elif path == "/api/history":
            self._api_history_list()
        elif path == "/api/events":
            self._api_events()
        elif path.startswith("/api/history/"):
            self._api_history(path[len("/api/history/"):])
        else:
            self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self) -> None:
        if not self._authorized():
            self._error(HTTPStatus.UNAUTHORIZED, "unauthorized")
            return
        self._body = self._read_body()
        if self._body is None:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                        "request body too large")
            return
        if self.headers.get_content_type() != "application/json":
            self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                        "Content-Type must be application/json")
            return
        path = urlsplit(self.path).path
        if path == "/api/sudo/check":
            self._api_sudo_check()
        elif path == "/api/plan":
            self._api_plan()
        elif path == "/api/run":
            self._api_run()
        else:
            self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def _read_body(self) -> bytes | None:
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            length = 0
        if length <= 0:
            return b""
        if length > _MAX_BODY_BYTES:
            # 不读取也不等待声明长度的 body；HTTP/1.1 下必须断开连接，
            # 否则残余字节会被当成下一个请求解析。
            self.close_connection = True
            return None
        return self.rfile.read(length)

    # -- 静态文件 -----------------------------------------------------------
    def _serve_static(self, rel: str) -> None:
        candidate = schema.safe_static_path(self.server.config.static_dir, rel)
        if candidate is None or not candidate.is_file():
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        try:
            body = candidate.read_bytes()
        except OSError:
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        content_type = _CONTENT_TYPES.get(candidate.suffix.lower(),
                                          "application/octet-stream")
        self._send_bytes(HTTPStatus.OK, body, content_type,
                         self._cookie_headers())

    # -- API ----------------------------------------------------------------
    def _load_catalog(self) -> dict:
        cached = self.server.catalog_cache
        if cached is not None:
            return cached
        cmd = list(self.server.config.setup_cmd or []) + ["--list", "--json"]
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(self.server.config.project_dir),
                capture_output=True,
                text=True,
                # 两个引擎都把 stdout 按 UTF-8 写（setup.ps1 显式设置了
                # [Console]::OutputEncoding）；不指定编码时 Python 用区域编码
                # （中文 Windows 上是 GBK），中文目录/描述会全变乱码。
                encoding="utf-8",
                timeout=15,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("catalog command timed out") from None
        except OSError as exc:
            raise RuntimeError(f"catalog command failed: {exc}") from exc
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()
            raise RuntimeError(
                f"catalog command exited {proc.returncode}: {detail}")
        try:
            data = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid catalog JSON: {exc}") from exc
        if not isinstance(data, dict):
            raise RuntimeError("invalid catalog JSON: expected an object")
        data.setdefault("catalog", [])
        data.setdefault("profiles", [])
        data["param_groups"] = schema.PARAM_GROUPS
        self.server.catalog_cache = data
        return data

    def _api_catalog(self) -> None:
        try:
            data = self._load_catalog()
        except RuntimeError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, str(exc))
            return
        self._send_json(HTTPStatus.OK, data, self._cookie_headers())

    def _read_selection(self, catalog: dict) -> dict:
        path = self.server.config.state_dir / "ui" / "selection.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = None
        catalog_ids = {
            item.get("id") for item in catalog.get("catalog", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        if isinstance(data, dict):
            tools = data.get("tools")
            adhoc = data.get("adhoc")
            verb = data.get("verb")
            stale_ok = []
            for token in tools if isinstance(tools, list) else []:
                if isinstance(token, str) and token in catalog_ids:
                    stale_ok.append(token)
            adhoc_ok = []
            for token in adhoc if isinstance(adhoc, list) else []:
                if not isinstance(token, str) or ":" not in token:
                    continue
                try:
                    schema.normalize_adhoc_id(token)
                except schema.ValidationError:
                    continue
                adhoc_ok.append(token)
            return {
                "tools": stale_ok,
                "adhoc": adhoc_ok,
                "verb": verb if isinstance(verb, str) else "install",
            }
        tools: list[str] = []
        for profile in catalog.get("profiles", []):
            if isinstance(profile, dict) and profile.get("name") == "default":
                raw = profile.get("tools", [])
                tools = [t for t in raw if isinstance(t, str)
                         and t in catalog_ids]
                break
        return {"tools": tools, "adhoc": [], "verb": "install"}

    def _merged_params(self) -> dict[str, str]:
        config_dir = self.server.config.project_dir / "config"
        # versions.env 是引擎的版本/源默认值来源，也要参与合并，
        # 否则 UI 里看不到 NPM_REGISTRY 等只写在 versions.env 的默认值。
        merged = schema.read_env_file(config_dir / "versions.env")
        merged.update(schema.read_env_file(config_dir / "user.env"))
        merged.update(schema.read_env_file(config_dir / "ui.env"))
        return merged

    def _sudo_available(self) -> bool:
        # Windows 上没有 sudo 语义（Win11 的 sudo.exe 与这里的用法不兼容），
        # 直接判不可用；UI 会把需要提权的项交给引擎自行处理。
        if os.name == "nt":
            return False
        if shutil.which("sudo") is None:
            return False
        try:
            proc = subprocess.run(["sudo", "-n", "true"], capture_output=True,
                                  timeout=5, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return False
        return proc.returncode == 0

    def _api_state(self) -> None:
        try:
            catalog = self._load_catalog()
        except RuntimeError:
            catalog = {"catalog": [], "profiles": []}
        selection = self._read_selection(catalog)

        merged = self._merged_params()
        secrets_present = {
            key: key in merged
            for key, spec in schema.PARAM_SPECS.items() if spec["secret"]
        }
        params = {
            key: value for key, value in merged.items()
            if not schema.PARAM_SPECS[key]["secret"]
        }
        defaults = {
            key: value
            for key, value in schema.read_env_file(
                self.server.config.project_dir / "config" / "versions.env").items()
            if not schema.PARAM_SPECS[key]["secret"]
        }
        defaults.update({
            key: value
            for key, value in schema.read_env_file(
                self.server.config.project_dir / "config" / "user.env").items()
            if not schema.PARAM_SPECS[key]["secret"]
        })

        job = self.server.current_job
        if job is None:
            running, current = False, None
        else:
            running = bool(getattr(job, "running", True))
            current = {
                "run_id": getattr(job, "run_id", None),
                "verb": getattr(job, "verb", None),
                "pick": list(getattr(job, "pick", []) or []),
            }

        self._send_json(HTTPStatus.OK, {
            "selection": selection,
            "params": params,
            "defaults": defaults,
            "secrets": secrets_present,
            "profiles": catalog.get("profiles", []),
            "running": running,
            "current": current,
            "sudo": self._sudo_available(),
        }, self._cookie_headers())

    def _api_sudo_check(self) -> None:
        available = self._sudo_available()
        installed = shutil.which("sudo") is not None
        self._send_json(HTTPStatus.OK,
                        {"available": available, "sudo": installed})

    # -- plan / run ---------------------------------------------------------
    def _json_body(self) -> dict | None:
        raw = getattr(self, "_body", b"") or b""
        if not raw:
            return {}
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self._error(HTTPStatus.BAD_REQUEST, "invalid JSON body")
            return None
        if not isinstance(data, dict):
            self._error(HTTPStatus.BAD_REQUEST, "JSON body must be an object")
            return None
        return data

    def _catalog_index(self) -> tuple[set[str], dict[str, list[str]]]:
        data = self._load_catalog()
        ids: set[str] = set()
        deps: dict[str, list[str]] = {}
        for entry in data.get("catalog", []):
            if not isinstance(entry, dict):
                continue
            ident = entry.get("id")
            if not isinstance(ident, str):
                continue
            ids.add(ident)
            raw = entry.get("deps") or ""
            # 引擎把 deps 存成空格分隔（catalog.sh 会把逗号换成空格），
            # 这里两种分隔符都接受，避免多依赖工具的依赖方被漏掉。
            deps[ident] = [part for part in str(raw).replace(",", " ").split()
                           if part]
        return ids, deps

    def _validate_request(self, body: dict) -> tuple[str, list[str], dict, list[str]] | None:
        verb = body.get("verb", "install")
        if verb not in _RUN_VERBS:
            self._error(HTTPStatus.BAD_REQUEST, f"unsupported verb: {verb!r}")
            return None
        try:
            ids, _deps = self._catalog_index()
            pick = schema.validate_pick(body.get("pick"), ids)
            params = body.get("params") or {}
            reset_params = body.get("reset_params") or []
            schema.validate_params(params, reset_params)
        except schema.ValidationError as exc:
            self._error(HTTPStatus.BAD_REQUEST, str(exc))
            return None
        except RuntimeError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, str(exc))
            return None
        return verb, pick, params, reset_params

    def _capture_process(
        self, cmd: list[str], timeout: float | None = None
    ) -> tuple[list[str], list[dict], int | None, bool]:
        """运行 setup 子进程，收集日志行与事件；超时杀进程。"""
        with tempfile.TemporaryDirectory(prefix="os-config-capture-") as tmp:
            events_path = Path(tmp) / "events.jsonl"
            env = os.environ.copy()
            env["OS_CONFIG_EVENTS"] = str(events_path)
            env["ASSUME_YES"] = "1"
            proc = subprocess.Popen(
                cmd,
                cwd=str(self.server.config.project_dir),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                text=True,
                encoding="utf-8",
                env=env,
                # 独立会话：POSIX 上超时时按进程组终止，避免 shell 的子进程
                # 继续持有 stdout 管道导致 communicate() 永远等不到 EOF。
                # Windows 上没有 setsid 语义（该参数被忽略），超时改走
                # _terminate_process_tree 的 taskkill /T。
                start_new_session=True,
            )
            timed_out = False
            try:
                out, _ = proc.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                _terminate_process_tree(proc)
                out, _ = proc.communicate()
            logs = [_redact(_ANSI_RE.sub("", line))
                    for line in (out or "").splitlines()]
            events: list[dict] = []
            try:
                text = events_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = ""
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(event, dict):
                    events.append(event)
        rc = None if timed_out else proc.returncode
        return logs, events, rc, timed_out

    def _run_dry(self, cmd: list[str]) -> tuple[list[str], list[dict], int]:
        logs, events, rc, timed_out = self._capture_process(
            cmd, timeout=_PLAN_TIMEOUT)
        if timed_out:
            logs.append(f"[ERROR] 生成计划超时（{_PLAN_TIMEOUT:g}s），进程已终止")
        return logs, events, rc if rc is not None else 1

    def _api_plan(self) -> None:
        body = self._json_body()
        if body is None:
            return
        validated = self._validate_request(body)
        if validated is None:
            return
        verb, pick, _params, _reset = validated

        try:
            _ids, deps = self._catalog_index()
        except RuntimeError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, str(exc))
            return
        selected = _pick_ids(pick)
        selected_set = set(selected)
        required_by: dict[str, list[str]] = {}
        for selector in selected:
            for dep in deps.get(selector, []):
                required_by.setdefault(dep, []).append(selector)

        cmd = list(self.server.config.setup_cmd or [])
        cmd += [verb if verb in _PLAN_VERBS else "install",
                "--dry-run", "--pick", _pick_arg(pick), "--yes"]
        try:
            logs, events, rc = self._run_dry(cmd)
        except OSError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, f"setup command failed: {exc}")
            return

        items: list[dict] = []
        seen: set[str] = set()
        for event in events:
            if event.get("event") != "item_end":
                continue
            ident = event.get("id")
            if not isinstance(ident, str) or ident in seen:
                continue
            seen.add(ident)
            items.append({
                "id": ident,
                "type": event.get("type", ""),
                "selected": ident in selected_set,
                "required_by": required_by.get(ident, []),
                "status": event.get("status", ""),
                "rc": event.get("rc", rc),
            })
        self._send_json(HTTPStatus.OK,
                        {"items": items, "logs": logs, "exit": rc},
                        self._cookie_headers())

    def _api_run(self) -> None:
        body = self._json_body()
        if body is None:
            return
        validated = self._validate_request(body)
        if validated is None:
            return
        verb, pick, params, reset_params = validated
        if verb == "remove" and body.get("confirm") is not True:
            self._error(HTTPStatus.BAD_REQUEST, "remove requires confirm")
            return

        job = RunJob(
            self.server,
            verb=verb,
            pick=pick,
            params=params,
            reset_params=reset_params,
            keep_going=bool(body.get("keep_going")),
            verify_after=bool(body.get("verify_after")),
            dry_run=bool(body.get("dry_run")),
            force=bool(body.get("force")),
            confirm=body.get("confirm") is True,
        )
        try:
            started = job.start()
        except schema.ValidationError as exc:
            self._error(HTTPStatus.BAD_REQUEST, str(exc))
            return
        except OSError as exc:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, str(exc))
            return
        if not started:
            self._error(HTTPStatus.CONFLICT, "another run is in progress")
            return
        self._send_json(HTTPStatus.ACCEPTED, {"run_id": job.run_id},
                        self._cookie_headers())

    # -- SSE ----------------------------------------------------------------
    def _write_sse(self, item: tuple[int, str, dict]) -> None:
        event_id, name, data = item
        payload = json.dumps(data, ensure_ascii=False)
        frame = f"id: {event_id}\nevent: {name}\ndata: {payload}\n\n"
        self.wfile.write(frame.encode("utf-8"))
        self.wfile.flush()

    def _finished_run_meta(self, run_id: str) -> dict | None:
        meta_path = (self.server.config.state_dir / "ui" / "runs"
                     / run_id / "meta.json")
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(meta, dict) or not meta.get("finished"):
            return None
        return meta

    def _api_events(self) -> None:
        if self.command == "HEAD":
            # SSE 是无限流，HEAD 无法表达且会让处理线程一直挂着。
            self._error(HTTPStatus.METHOD_NOT_ALLOWED, "HEAD is not supported")
            return
        query = parse_qs(urlsplit(self.path).query)
        run_filter = (query.get("run_id") or [None])[0]
        if run_filter is not None:
            if schema.safe_run_id(run_filter) is None:
                self._error(HTTPStatus.BAD_REQUEST, "invalid run id")
                return
            run_dir = self.server.config.state_dir / "ui" / "runs" / run_filter
            if not run_dir.is_dir():
                self._error(HTTPStatus.NOT_FOUND, "run not found")
                return

        after: int | None = None
        header = self.headers.get("Last-Event-ID")
        raw_after = header if header is not None else (query.get("after") or [None])[0]
        if raw_after is not None:
            try:
                after = int(raw_after)
            except (TypeError, ValueError):
                after = None

        subscriber, backlog = self.server.event_bus.subscribe()
        try:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            last_id = 0
            for item in backlog:
                if after is not None and item[0] <= after:
                    continue
                if run_filter is not None and item[2].get("run_id") != run_filter:
                    continue
                self._write_sse(item)
                last_id = item[0]
                if run_filter is not None and item[1] == "done":
                    return
            # 服务重启后缓冲为空：已完成的 run 不会再有 live 事件，补一帧 done
            # 让回看连接能正常结束。
            if run_filter is not None:
                meta = self._finished_run_meta(run_filter)
                if meta is not None:
                    self._write_sse((last_id, "done", {
                        "run_id": run_filter,
                        "rc": meta.get("rc"),
                        "verify_rc": meta.get("verify_rc"),
                    }))
                    return
            while True:
                try:
                    item = subscriber.get(timeout=15)
                except queue.Empty:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    continue
                if run_filter is not None and item[2].get("run_id") != run_filter:
                    continue
                self._write_sse(item)
                if run_filter is not None and item[1] == "done":
                    return
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.server.event_bus.unsubscribe(subscriber)

    # -- history ------------------------------------------------------------
    def _api_history(self, run_id: str) -> None:
        if schema.safe_run_id(run_id) is None:
            self._error(HTTPStatus.BAD_REQUEST, "invalid run id")
            return
        run_dir = self.server.config.state_dir / "ui" / "runs" / run_id
        meta_path = run_dir / "meta.json"
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            self._error(HTTPStatus.NOT_FOUND, "run not found")
            return
        events: list[dict] = []
        try:
            lines = (run_dir / "events.jsonl").read_text(
                encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                events.append(event)
        log = ""
        try:
            raw = (run_dir / "run.log").read_bytes()
            log = raw[-_HISTORY_LOG_LIMIT:].decode("utf-8", errors="replace")
        except OSError:
            pass
        self._send_json(HTTPStatus.OK, {
            "run_id": run_id,
            "meta": meta,
            "events": events,
            "log": log,
        }, self._cookie_headers())

    # -- installed / status / history --------------------------------------
    def _manifest_entries(self) -> list[dict]:
        path = self.server.config.state_dir / "manifest.conf"
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return []
        entries: dict[str, dict] = {}
        for line in text.splitlines():
            parts = line.split("|")
            if len(parts) < 4:
                continue
            tool, action, artifact = parts[0], parts[1], parts[2]
            ts = "|".join(parts[3:])
            if not tool:
                continue
            entry = entries.setdefault(
                tool, {"id": tool, "action": "", "artifacts": [], "ts": ""})
            entry["action"] = action
            entry["ts"] = ts
            if artifact and artifact != "-" and artifact not in entry["artifacts"]:
                entry["artifacts"].append(artifact)
        return list(entries.values())

    def _api_installed(self) -> None:
        try:
            data = self._load_catalog()
        except RuntimeError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, str(exc))
            return
        tools: list[dict] = []
        for item in data.get("catalog", []):
            if not isinstance(item, dict):
                continue
            ident = item.get("id")
            if not isinstance(ident, str) or not ident:
                continue
            packages = item.get("packages") or ""
            artifacts = item.get("artifacts") or []
            tools.append({
                "id": ident,
                "desc": str(item.get("desc") or ""),
                "type": str(item.get("type") or ""),
                "backend": str(item.get("backend") or ""),
                "packages": packages if isinstance(packages, (str, list)) else "",
                "action": str(item.get("action") or ""),
                "artifacts": artifacts if isinstance(artifacts, list) else [],
                "sudo": bool(item.get("sudo")),
            })
        self._send_json(HTTPStatus.OK, {
            "entries": self._manifest_entries(),
            "catalog_tools": tools,
        }, self._cookie_headers())

    def _api_status(self) -> None:
        query = parse_qs(urlsplit(self.path).query)
        raw_pick = (query.get("pick") or [""])[0]
        tokens = [part.strip() for part in raw_pick.split(",") if part.strip()]
        try:
            ids, _deps = self._catalog_index()
            pick = schema.validate_pick(tokens, ids)
        except schema.ValidationError as exc:
            self._error(HTTPStatus.BAD_REQUEST, str(exc))
            return
        except RuntimeError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, str(exc))
            return
        cmd = list(self.server.config.setup_cmd or [])
        cmd += ["verify", "--pick", _pick_arg(pick), "--keep-going", "--yes"]
        if not self.server.run_lock.acquire(blocking=False):
            self._error(HTTPStatus.CONFLICT, "已有任务在运行，无法检查状态")
            return
        try:
            try:
                logs, events, rc, timed_out = self._capture_process(cmd, timeout=120)
            except OSError as exc:
                self._error(HTTPStatus.BAD_GATEWAY, f"setup command failed: {exc}")
                return
            if timed_out:
                self._error(HTTPStatus.GATEWAY_TIMEOUT, "verify timed out after 120s")
                return
            items = [
                {"id": event.get("id"), "phase": event.get("phase", "verify"),
                 "status": event.get("status", ""), "rc": event.get("rc", rc)}
                for event in events
                if event.get("event") == "item_end" and isinstance(event.get("id"), str)
            ]
            self._send_json(HTTPStatus.OK,
                            {"items": items, "logs": logs, "exit": rc},
                            self._cookie_headers())
        finally:
            self.server.run_lock.release()

    def _api_history_list(self) -> None:
        runs_dir = self.server.config.state_dir / "ui" / "runs"
        try:
            candidates = sorted(runs_dir.iterdir())
        except OSError:
            candidates = []
        runs: list[dict] = []
        for run_dir in candidates:
            if not run_dir.is_dir() or schema.safe_run_id(run_dir.name) is None:
                continue
            try:
                meta = json.loads(
                    (run_dir / "meta.json").read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(meta, dict):
                continue
            runs.append({
                "run_id": meta.get("run_id") or run_dir.name,
                "verb": meta.get("verb", ""),
                "started": meta.get("started", ""),
                "finished": meta.get("finished", ""),
                "rc": meta.get("rc"),
                "ok": meta.get("ok", 0),
                "skipped": meta.get("skipped", 0),
                "failed": meta.get("failed", 0),
            })
        runs.sort(key=lambda item: str(item.get("started") or ""), reverse=True)
        self._send_json(HTTPStatus.OK, runs, self._cookie_headers())

    # -- 日志 ---------------------------------------------------------------
    def log_message(self, fmt: str, *args) -> None:
        path = urlsplit(getattr(self, "path", "")).path
        sys.stderr.write(f"[ui] {self.command} {path}\n")


class RunJob:
    """一次 install / remove / verify 任务的执行器。

    锁必须在 :meth:`start` 返回前同步获取，这样并发请求能立即拿到 409，
    而不是等线程调度后才失败。
    """

    def __init__(self, server: UIServer, *, verb: str, pick: list[str],
                 params: dict, reset_params: list[str], keep_going: bool = False,
                 verify_after: bool = False, dry_run: bool = False,
                 force: bool = False, confirm: bool = False):
        self.server = server
        self.config = server.config
        self.verb = verb
        self.pick = list(pick)
        self.params = dict(params)
        self.reset_params = list(reset_params)
        self.keep_going = keep_going
        self.verify_after = verify_after
        self.dry_run = dry_run
        self.force = force
        self.confirm = confirm

        now = datetime.now(timezone.utc)
        self.run_id = now.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3)
        self.started = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        self.running = False
        self.rc: int | None = None
        self.rolled_back = False
        self.ok = 0
        self.skipped = 0
        self.failed = 0
        self.verify_rc: int | None = None

        self._memory_locked = False
        self._file_locked = False
        self._thread: threading.Thread | None = None
        self._run_dir = self.config.state_dir / "ui" / "runs" / self.run_id
        self._events_path = self._run_dir / "events.jsonl"
        self._log_path = self._run_dir / "run.log"
        self._log_lines: deque[str] = deque(maxlen=2000)
        self._event_offset = 0
        self._event_bytes = b""
        self._run_end: dict | None = None
        self._current_item: str | None = None

    # -- 启动与锁 -----------------------------------------------------------
    def start(self) -> bool:
        """校验请求、获取锁并启动后台线程；锁已被占用时返回 False。"""
        if self.verb not in _RUN_VERBS:
            raise schema.ValidationError(f"unsupported verb: {self.verb!r}")
        if self.verb == "remove" and not self.confirm:
            raise schema.ValidationError("remove requires confirm")
        schema.validate_pick(self.pick, self._catalog_ids())
        schema.validate_params(self.params, self.reset_params)

        if not self.server.run_lock.acquire(blocking=False):
            return False
        self._memory_locked = True
        try:
            if not self._acquire_file_lock():
                self._release_lock()
                return False
            self._write_ui_env()
            self._prepare_run_dir()
        except BaseException:
            self._release_lock()
            raise

        self.running = True
        self.server.current_job = self
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name=f"os-config-run-{self.run_id}")
        self._thread.start()
        return True

    def _catalog_ids(self) -> set[str]:
        data = self.server.catalog_cache
        if data is None:
            cmd = list(self.config.setup_cmd or []) + ["--list", "--json"]
            proc = subprocess.run(
                cmd, cwd=str(self.config.project_dir), capture_output=True,
                text=True, encoding="utf-8", timeout=15, check=False)
            if proc.returncode != 0:
                raise RuntimeError(
                    f"catalog command exited {proc.returncode}")
            try:
                data = json.loads(proc.stdout)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"invalid catalog JSON: {exc}") from exc
            self.server.catalog_cache = data
        return {
            entry["id"] for entry in data.get("catalog", [])
            if isinstance(entry, dict) and isinstance(entry.get("id"), str)
        }

    def _acquire_file_lock(self) -> bool:
        path = self.server.lock_path
        path.parent.mkdir(parents=True, exist_ok=True)
        for _ in range(2):
            try:
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                if self._clear_stale_lock():
                    continue
                return False
            except OSError:
                return False
            try:
                os.write(fd, str(os.getpid()).encode("ascii"))
            finally:
                os.close(fd)
            self._file_locked = True
            return True
        return False

    def _clear_stale_lock(self) -> bool:
        path = self.server.lock_path
        try:
            raw = path.read_text(encoding="utf-8").strip()
        except OSError:
            return False
        try:
            pid = int(raw)
        except ValueError:
            pid = -1
        if pid > 0 and pid != os.getpid():
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            except PermissionError:
                return False
            except OSError as exc:
                # Windows 上探测不存在的 pid 抛的是 WinError 87（参数错误），
                # 不是 ProcessLookupError；不认它的话残留锁在 Windows 上永远
                # 清不掉，一次异常退出就能把 UI 永久堵死。
                if os.name == "nt" and getattr(exc, "winerror", None) == 87:
                    pass
                else:
                    return False
            else:
                return False
        try:
            path.unlink()
        except OSError:
            return False
        return True

    def _release_lock(self) -> None:
        if self._file_locked:
            self._file_locked = False
            try:
                self.server.lock_path.unlink()
            except OSError:
                pass
        if self._memory_locked:
            self._memory_locked = False
            try:
                self.server.run_lock.release()
            except RuntimeError:
                pass

    # -- 落盘 ---------------------------------------------------------------
    def _write_ui_env(self) -> None:
        path = self.config.project_dir / "config" / "ui.env"
        existing = schema.read_env_file(path)
        merged = schema.apply_param_changes(
            existing, self.params, self.reset_params)
        schema.write_ui_env(
            path, merged, self.config.state_dir / "ui" / "env-backups")

    def _prepare_run_dir(self) -> None:
        self._run_dir.mkdir(parents=True, exist_ok=True)
        fd = os.open(self._events_path,
                     os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        os.close(fd)
        fd = os.open(self._log_path,
                     os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        os.close(fd)

    def _write_meta(self) -> None:
        self._atomic_write_json(self._run_dir / "meta.json", {
            "run_id": self.run_id,
            "verb": self.verb,
            "pick": self.pick,
            "started": self.started,
            "finished": datetime.now(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"),
            "rc": self.rc,
            "rolled_back": self.rolled_back,
            "ok": self.ok,
            "skipped": self.skipped,
            "failed": self.failed,
            "verify_rc": self.verify_rc,
        })

    def _write_selection(self) -> None:
        tools = [token for token in self.pick if ":" not in token]
        adhoc = [token for token in self.pick if ":" in token]
        self._atomic_write_json(
            self.config.state_dir / "ui" / "selection.json", {
                "version": 1,
                "tools": tools,
                "adhoc": adhoc,
                "verb": self.verb,
                "updated": datetime.now(timezone.utc).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"),
            })

    @staticmethod
    def _atomic_write_json(path: Path, payload: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.",
                                   dir=str(path.parent))
        try:
            os.chmod(tmp, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        os.chmod(path, 0o600)

    # -- 执行 ---------------------------------------------------------------
    def _run(self) -> None:
        try:
            rc = self._run_phase(self.verb)
            if (self.verb == "install" and self.verify_after and rc == 0
                    and not self.rolled_back):
                self.verify_rc = self._run_phase("verify")
            else:
                self.verify_rc = None
            if self.verify_rc:
                rc = self.verify_rc
            self.rc = rc
        except Exception as exc:  # 后台线程不能静默死掉
            self.rc = 1
            self._emit_log(f"run failed: {exc}")
        finally:
            try:
                self._write_meta()
            except Exception as exc:
                self._emit_log(f"meta write failed: {exc}")
            try:
                if self.verb == "install":
                    self._write_selection()
            except Exception:
                pass
            self.server.event_bus.publish("summary", {
                "run_id": self.run_id,
                "verb": self.verb,
                "rc": self.rc,
                "ok": self.ok,
                "skipped": self.skipped,
                "failed": self.failed,
                "rolled_back": self.rolled_back,
                "verify_rc": self.verify_rc,
            })
            self.server.event_bus.publish("done", {
                "run_id": self.run_id,
                "rc": self.rc,
                "verify_rc": self.verify_rc,
            })
            self._release_lock()
            if self.server.current_job is self:
                self.server.current_job = None
            self.running = False

    def _run_phase(self, verb: str) -> int:
        cmd = list(self.config.setup_cmd or [])
        cmd.append(verb)
        cmd += ["--pick", _pick_arg(self.pick)]
        cmd.append("--yes")
        if self.keep_going:
            cmd.append("--keep-going")
        if self.force:
            cmd.append("--force")
        if self.dry_run:
            cmd.append("--dry-run")

        env = os.environ.copy()
        env["OS_CONFIG_EVENTS"] = str(self._events_path)
        env["ASSUME_YES"] = "1"

        proc = subprocess.Popen(
            cmd,
            cwd=str(self.config.project_dir),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
            text=True,
            encoding="utf-8",
            env=env,
        )
        stop = threading.Event()
        tail = threading.Thread(target=self._tail_events, args=(stop,),
                                daemon=True)
        tail.start()
        try:
            assert proc.stdout is not None
            for raw in proc.stdout:
                self._emit_log(_ANSI_RE.sub("", raw.rstrip("\r\n")))
            rc = proc.wait()
        finally:
            stop.set()
            tail.join(timeout=5)
            if proc.stdout is not None:
                proc.stdout.close()

        if isinstance(self._run_end, dict) and self._run_end.get("rolled_back"):
            self.rolled_back = True
        return rc

    def _tail_events(self, stop: threading.Event) -> None:
        while not stop.wait(0.1):
            self._pump_events()
        self._pump_events()

    def _pump_events(self) -> None:
        try:
            with open(self._events_path, "rb") as handle:
                handle.seek(self._event_offset)
                chunk = handle.read()
        except OSError:
            return
        if not chunk:
            return
        self._event_offset += len(chunk)
        self._event_bytes += chunk
        *lines, self._event_bytes = self._event_bytes.split(b"\n")
        for raw in lines:
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                self._handle_event(line)

    def _handle_event(self, line: str) -> None:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            return
        if not isinstance(event, dict):
            return
        name = event.get("event")
        if name in ("item_start", "item_end"):
            if name == "item_start":
                self._current_item = event.get("id") or None
            elif event.get("id") in (None, self._current_item):
                self._current_item = None
            self.server.event_bus.publish("item", {**event, "run_id": self.run_id})
            if name == "item_end":
                status = event.get("status")
                if status == "ok":
                    self.ok += 1
                elif status == "skipped":
                    self.skipped += 1
                elif status == "failed":
                    self.failed += 1
        elif name == "rollback":
            self.rolled_back = True
            self.server.event_bus.publish(
                "rollback", {**event, "run_id": self.run_id})
        elif name == "run_start":
            self.server.event_bus.publish("plan", {
                "run_id": self.run_id,
                "verb": event.get("verb", self.verb),
                "phase": event.get("phase", self.verb),
                "ids": event.get("ids", []),
            })
        elif name == "run_end":
            self._run_end = event

    def _emit_log(self, line: str) -> None:
        line = _redact(line)
        self._log_lines.append(line)
        try:
            with open(self._log_path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except OSError:
            pass
        tool_id = _log_item_id(line, self._current_item)
        if tool_id is not None and tool_id != self._current_item \
                and _LOG_ITEM_RE.match(line):
            # 前缀比事件尾部更实时：用它校正当前条目，供后续无前缀行归属。
            self._current_item = tool_id
        self.server.event_bus.publish(
            "log", {"run_id": self.run_id, "line": line, "id": tool_id})


def make_server(config: AppConfig) -> UIServer:
    return UIServer((config.host, config.port), Handler, config)

def run_server(config: AppConfig) -> None:
    server = make_server(config)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    project_dir = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(prog="python3 -m ui.server",
                                     description="os-config local web UI")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--project-dir", type=Path, default=project_dir)
    args = parser.parse_args(argv)

    project_dir = args.project_dir.resolve()
    token = os.environ.get("OS_CONFIG_UI_TOKEN", "")
    generated = not token
    if generated:
        token = secrets.token_urlsafe(32)

    config = AppConfig(
        project_dir=project_dir,
        static_dir=project_dir / "ui" / "static",
        state_dir=project_dir / "state",
        host=args.host,
        port=args.port,
        token=token,
    )
    if generated:
        print(f"http://{config.host}:{config.port}/?token={token}", flush=True)
    run_server(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
