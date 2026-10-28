import json, os, socket, subprocess, sys, tempfile, threading, time, types, unittest, urllib.error, urllib.request
from pathlib import Path
from unittest import mock
from ui import schema
from ui import server as server_mod
from ui.server import AppConfig, make_server

class AdhocTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(schema.normalize_adhoc_id("apt:jq"), ("jq", "apt", "jq"))
        self.assertEqual(schema.normalize_adhoc_id("npm:@scope/pkg"),
                         ("scope-pkg", "npm", "@scope/pkg"))
        self.assertEqual(schema.normalize_adhoc_id("snap:code"), ("code", "snap", "code"))

    def test_rejects_metacharacters(self):
        for bad in ["apt:jq;rm", "apt:-x", "brew:jq", "npm:a b", "apt:", "apt:$(id)"]:
            with self.assertRaises(schema.ValidationError):
                schema.normalize_adhoc_id(bad)

    def test_id_strips_all_edge_dashes(self):
        """id 规则必须与 engine/lib/profile.sh 一致：首尾的 '-' 全部去掉。"""
        self.assertEqual(schema.normalize_adhoc_id("apt:x--"), ("x", "apt", "x--"))
        self.assertEqual(schema.normalize_adhoc_id("apt:x-"), ("x", "apt", "x-"))
        self.assertEqual(schema.normalize_adhoc_id("npm:@scope/pkg"),
                         ("scope-pkg", "npm", "@scope/pkg"))
        # 包名以 '-' 开头时两边都拒绝（引擎 _catalog_valid_pkg_spec 同样拒绝）
        with self.assertRaises(schema.ValidationError):
            schema.normalize_adhoc_id("apt:--x--")

    def test_accepts_engine_pkg_chars(self):
        """包名字符集必须与引擎的 _catalog_valid_pkg_spec 一致。"""
        self.assertEqual(schema.normalize_adhoc_id("apt:pkg=1.2.3"),
                         ("pkg-1-2-3", "apt", "pkg=1.2.3"))
        self.assertEqual(schema.normalize_adhoc_id("npm:pkg~rc1"),
                         ("pkg-rc1", "npm", "pkg~rc1"))

    def test_collision(self):
        with self.assertRaises(schema.ValidationError):
            schema.validate_pick(["apt:foo", "snap:foo"], {"git"})
        with self.assertRaises(schema.ValidationError):
            schema.validate_pick(["foo", "apt:foo"], {"foo"})

    def test_bad_catalog_ids(self):
        for bad in ["bad id", "-x", "", "a;b", "../x"]:
            with self.assertRaises(schema.ValidationError):
                schema.validate_pick([bad], {"git"})

    def test_normalized_id_must_not_collide_with_catalog(self):
        with self.assertRaises(schema.ValidationError):
            schema.validate_pick(["apt:git"], {"git", "jq"})
        with self.assertRaises(schema.ValidationError):
            schema.validate_pick(["npm:@scope/git"], {"scope-git"})
        self.assertEqual(schema.validate_pick(["apt:jq"], {"git"}), ["apt:jq"])

class ParamTests(unittest.TestCase):
    def test_groups(self):
        groups = {g["id"]: g for g in schema.PARAM_GROUPS}
        self.assertEqual(set(groups), {"mirrors", "proxy", "git", "ssh", "syslog",
                                       "nodejs", "claude", "codex", "opencode",
                                       "gemini", "qwen", "copilot", "iflow"})
        self.assertEqual(groups["nodejs"]["tools"], ["nodejs"])
        self.assertEqual(groups["git"]["tools"], ["git"])
        self.assertIn("NPM_REGISTRY", {f["key"] for f in groups["nodejs"]["fields"]})
        self.assertIn("NVM_VERSION", {f["key"] for f in groups["nodejs"]["fields"]})
        for group, key in [("claude", "CLAUDE_CODE_PKG"), ("codex", "CODEX_PKG"),
                           ("opencode", "OPENCODE_PKG"), ("gemini", "GEMINI_PKG"),
                           ("qwen", "QWEN_CODE_PKG"), ("copilot", "COPILOT_PKG"),
                           ("iflow", "IFLOW_PKG")]:
            self.assertIn(key, {f["key"] for f in groups[group]["fields"]})

    def test_whitelist(self):
        schema.validate_params({"GIT_USER_NAME": "A B"}, [])
        for bad in [{"EVIL": "x"}, {"GIT_USER_NAME": "a\nb"},
                    {"PROXY_PORT": "70000"}, {"SSH_KEY_TYPE": "dsa"},
                    {"MIRROR_APT_URL": "file:///etc/passwd"}]:
            with self.assertRaises(schema.ValidationError):
                schema.validate_params(bad, [])
        with self.assertRaises(schema.ValidationError):
            schema.validate_params({}, ["EVIL"])

    def test_proxy_host_rejects_leading_dash(self):
        """PROXY_HOST 会被传进 shell/curl，必须与引擎一样拒绝选项注入。"""
        for bad in ["-x", "-", "--flag"]:
            with self.assertRaises(schema.ValidationError):
                schema.validate_params({"PROXY_HOST": bad}, [])
        for good in ["127.0.0.1", "localhost", "[::1]", "host-name.example"]:
            schema.validate_params({"PROXY_HOST": good}, [])

    def test_three_state_and_escaping(self):
        merged = schema.apply_param_changes(
            {"GIT_USER_NAME": "old", "PROXY_PORT": "7890"},
            {"GIT_USER_NAME": "O'Brien", "GIT_USER_EMAIL": ""},
            ["PROXY_PORT"])
        self.assertEqual(merged["GIT_USER_NAME"], "O'Brien")
        self.assertEqual(merged["GIT_USER_EMAIL"], "")
        self.assertNotIn("PROXY_PORT", merged)
        env = schema.render_ui_env(merged)
        self.assertIn("GIT_USER_NAME='O'\\''Brien'", env)
        self.assertIn("GIT_USER_EMAIL=", env)

    def test_read_env_inline_comment(self):
        """user.env 由 shell source；未加引号时的行内注释不属于值。"""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "user.env"
            p.write_text("GIT_USER_NAME=Alice # note\n"
                         "GIT_USER_EMAIL='a#b@x' # note\n"
                         "PROXY_PORT=7890#x\n"
                         "# GIT_USER_EMAIL=ignored\n")
            self.assertEqual(schema.read_env_file(p), {
                "GIT_USER_NAME": "Alice",
                "GIT_USER_EMAIL": "a#b@x",
                "PROXY_PORT": "7890#x",
            })

    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "ui.env"
            schema.write_ui_env(p, {"GIT_USER_NAME": "O'Brien", "PROXY_PORT": ""}, Path(d) / "bak")
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertEqual(schema.read_env_file(p),
                             {"GIT_USER_NAME": "O'Brien", "PROXY_PORT": ""})
            schema.write_ui_env(p, {"GIT_USER_NAME": "x"}, Path(d) / "bak")
            self.assertIsNotNone(schema.write_ui_env(p, {"GIT_USER_NAME": "y"}, Path(d) / "bak"))
            backups = list((Path(d) / "bak").iterdir())
            self.assertEqual(len(backups), 2)
            self.assertEqual((Path(d) / "bak").stat().st_mode & 0o777, 0o700)
            for backup in backups:
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

class PathTests(unittest.TestCase):
    def test_static_traversal(self):
        root = Path("/tmp/uiroot").resolve()
        self.assertIsNotNone(schema.safe_static_path(root, "app.js"))
        for bad in ["../etc/passwd", "a/../../x", "/etc/passwd", "a\x00b"]:
            self.assertIsNone(schema.safe_static_path(root, bad))

    def test_static_symlink_escape(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            root = base / "root"
            root.mkdir()
            (base / "secret").write_text("x")
            (root / "link").symlink_to(base / "secret")
            self.assertIsNone(schema.safe_static_path(root, "link"))

    def test_run_id(self):
        self.assertEqual(schema.safe_run_id("20261020-120000-abc123"),
                         "20261020-120000-abc123")
        for bad in ["../x", "/etc/passwd", "a/b", "x.txt", ".hidden",
                    "20261020-120000", "20261020-120000-abc.log"]:
            self.assertIsNone(schema.safe_run_id(bad))

class LogAttributionTests(unittest.TestCase):
    def test_level_prefixed_item_line(self):
        self.assertEqual(
            server_mod._log_item_id("[INFO] [git] setting user", None), "git")

    def test_fallback_to_current_item(self):
        self.assertEqual(
            server_mod._log_item_id("       $ git config --global x", "git"), "git")

    def test_dotted_bracket_is_not_an_item(self):
        self.assertIsNone(
            server_mod._log_item_id("[ERROR] [install.sh] 命令失败：", None))

    def test_no_context(self):
        self.assertIsNone(server_mod._log_item_id("=== install ===", None))

class EngineSelectionTests(unittest.TestCase):
    """UI 必须按平台选引擎：Windows 跑 setup.ps1，其余跑 setup.sh。"""

    def test_posix_uses_bash(self):
        project = Path("/opt/os-config")
        cmd = server_mod.default_engine_command(project, platform="posix")
        # 用 Path 拼期望值：在 Windows 上跑时分隔符会变成反斜杠
        self.assertEqual(cmd, ["bash", str(project / "setup.sh")])

    def test_windows_uses_powershell(self):
        cmd = server_mod.default_engine_command(Path(r"C:\os-config"),
                                                platform="nt")
        self.assertEqual(cmd[0], "powershell")
        for flag in ("-NoProfile", "-ExecutionPolicy", "Bypass", "-File"):
            self.assertIn(flag, cmd)
        self.assertTrue(cmd[-1].endswith("setup.ps1"), cmd)

    def test_appconfig_default_follows_platform(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = AppConfig(project_dir=d, static_dir=d, state_dir=d)
            self.assertEqual(cfg.setup_cmd,
                             server_mod.default_engine_command(Path(d)))

    def test_appconfig_explicit_cmd_wins(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = AppConfig(project_dir=d, static_dir=d, state_dir=d,
                            setup_cmd=["bash", "/bin/true"])
            self.assertEqual(cfg.setup_cmd, ["bash", "/bin/true"])


class ProcessTeardownTests(unittest.TestCase):
    """超时终止与残留锁清理必须跨平台工作（Windows 上没有 killpg/SIGKILL）。"""

    def test_terminate_process_tree_kills_child(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.assertIsNone(proc.poll())
            server_mod._terminate_process_tree(proc)
            proc.wait(timeout=20)
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()

    def test_stale_lock_with_dead_pid_is_cleared(self):
        # 死 pid 的判定跨平台不同：POSIX 抛 ProcessLookupError，Windows 抛
        # WinError 87。两者都必须判为“进程已死”并清锁，否则一次异常退出就能
        # 把 UI 永久堵死（这是 Windows 上真实存在过的行为）。
        dead_pid = (1 << 22) + 12345
        try:
            os.kill(dead_pid, 0)
            self.skipTest("找不到可用的死 pid")
        except ProcessLookupError:
            pass
        except OSError as exc:
            if not (os.name == "nt" and getattr(exc, "winerror", None) == 87):
                self.skipTest("找不到可用的死 pid")
        with tempfile.TemporaryDirectory() as d:
            lock = Path(d) / "run.lock"
            lock.write_text(str(dead_pid), encoding="utf-8")
            job = types.SimpleNamespace(
                server=types.SimpleNamespace(lock_path=lock))
            self.assertTrue(server_mod.RunJob._clear_stale_lock(job))
            self.assertFalse(lock.exists())


class ServerFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        (d / "static").mkdir(); (d / "static" / "index.html").write_text("<html>ok</html>")
        (d / "static" / "app.js").write_text("//ok")
        catalog = {"catalog": [{"id": "git", "desc": "git", "type": "config"}],
                   "profiles": [{"name": "default", "tools": ["git"], "error": ""}]}
        setup = d / "fake-setup.sh"
        setup.write_text("#!/usr/bin/env bash\n"
                         "if [[ \"$*\" == *--list* ]]; then\n"
                         f"  printf '%s\\n' '{json.dumps(catalog)}'\n"
                         "  exit 0\nfi\nexit 0\n")
        cls.cfg = AppConfig(project_dir=d, static_dir=d / "static",
                            state_dir=d / "state", port=0, token="tok",
                            setup_cmd=["bash", str(setup)])
        cls.srv = make_server(cls.cfg)
        cls.thread = threading.Thread(target=cls.srv.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown(); cls.srv.server_close(); cls.tmp.cleanup()

    def get(self, path, token=None, headers=None, timeout=5):
        req = urllib.request.Request(self.base + path, headers=headers or {})
        if token: req.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.headers, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read().decode()

    def sse(self, query="", timeout=10):
        """读取一次 SSE 连接的全部帧（服务端写完 done 后应主动关闭）。"""
        req = urllib.request.Request(
            self.base + "/api/events" + query,
            headers={"Authorization": "Bearer tok"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
        events = []
        for frame in raw.split("\n\n"):
            event = {"id": None, "event": None, "data": None}
            for line in frame.splitlines():
                if line.startswith("id:"):
                    event["id"] = int(line[3:].strip())
                elif line.startswith("event:"):
                    event["event"] = line[6:].strip()
                elif line.startswith("data:"):
                    event["data"] = json.loads(line[5:].strip())
            if event["event"]:
                events.append(event)
        return events

    def post(self, path, payload, token="tok", content_type="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        headers = {"Authorization": "Bearer " + token}
        if content_type:
            headers["Content-Type"] = content_type
        req = urllib.request.Request(self.base + path, method="POST", data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def wait_idle(self, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            _, _, body = self.get("/api/state", token="tok")
            if not json.loads(body)["running"]:
                return
            time.sleep(0.05)
        self.fail("run did not finish")

    def wait_meta(self, run_id, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            code, _, body = self.get(f"/api/history/{run_id}", token="tok")
            if code == 200 and json.loads(body)["meta"].get("finished"):
                return json.loads(body)
            time.sleep(0.05)
        self.fail("run did not finish")

class AuthTests(ServerFixture):
    def test_401_without_token(self):
        code, _, _ = self.get("/api/catalog")
        self.assertEqual(code, 401)

    def test_header_and_query_token(self):
        code, _, body = self.get("/api/catalog", token="tok")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["catalog"][0]["id"], "git")
        code, headers, _ = self.get("/?token=tok")
        self.assertEqual(code, 200)
        cookie = headers.get("Set-Cookie", "")
        self.assertIn("os_config_token=tok", cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)

    def test_cookie_token(self):
        code, _, _ = self.get("/api/catalog",
                              headers={"Cookie": "os_config_token=tok"})
        self.assertEqual(code, 200)

    def test_state(self):
        ui = self.cfg.state_dir / "ui"
        ui.mkdir(parents=True, exist_ok=True)
        (ui / "selection.json").write_text(json.dumps(
            {"version": 1, "tools": ["git"], "adhoc": ["apt:jq"],
             "verb": "install", "updated": "2026-10-20T10:00:00Z"}))
        cfg_dir = self.cfg.project_dir / "config"
        cfg_dir.mkdir(exist_ok=True)
        (cfg_dir / "user.env").write_text("GIT_USER_EMAIL='u@x'\nGIT_USER_NAME='U'\n")
        (cfg_dir / "ui.env").write_text("GIT_USER_NAME='A'\nSSH_KEY_PASSPHRASE='x'\n")
        code, _, body = self.get("/api/state", token="tok")
        self.assertEqual(code, 200, body)
        d = json.loads(body)
        self.assertEqual(d["selection"]["tools"], ["git"])
        self.assertEqual(d["selection"]["adhoc"], ["apt:jq"])
        self.assertEqual(d["params"]["GIT_USER_NAME"], "A")
        self.assertEqual(d["params"]["GIT_USER_EMAIL"], "u@x")
        self.assertEqual(d["defaults"]["GIT_USER_NAME"], "U")
        self.assertEqual(d["defaults"]["GIT_USER_EMAIL"], "u@x")
        self.assertNotIn("SSH_KEY_PASSPHRASE", d["params"])
        self.assertNotIn("SSH_KEY_PASSPHRASE", d["defaults"])
        self.assertTrue(d["secrets"]["SSH_KEY_PASSPHRASE"])
        for key in ["profiles", "running", "current", "sudo", "defaults"]:
            self.assertIn(key, d)

    def test_state_includes_versions_env_defaults(self):
        """versions.env 里的默认值也要出现在 UI 的默认值里（如 NPM_REGISTRY）。"""
        cfg_dir = self.cfg.project_dir / "config"
        cfg_dir.mkdir(exist_ok=True)
        (cfg_dir / "versions.env").write_text(
            "NPM_REGISTRY='https://registry.example'\nNODE_LTS_MAJOR=22\n")
        (cfg_dir / "user.env").write_text("NODE_LTS_MAJOR=20\n")
        code, _, body = self.get("/api/state", token="tok")
        self.assertEqual(code, 200, body)
        d = json.loads(body)
        self.assertEqual(d["defaults"]["NPM_REGISTRY"], "https://registry.example")
        self.assertEqual(d["params"]["NPM_REGISTRY"], "https://registry.example")
        # user.env 覆盖 versions.env
        self.assertEqual(d["defaults"]["NODE_LTS_MAJOR"], "20")
        self.assertEqual(d["params"]["NODE_LTS_MAJOR"], "20")

    def test_new_engine_backed_params_are_whitelisted(self):
        """引擎已接线的参数必须在白名单里，且拒绝非法取值。"""
        for key in ["MIRROR_SKIP_APT", "MIRROR_SKIP_APT_UPDATE", "APT_UPGRADE",
                    "PROXY_TEST_URL", "PROXY_CONNECT_TIMEOUT", "PROXY_MAX_TIME",
                    "NO_PROXY", "NVM_VERSION",
                    "CLAUDE_CODE_PKG", "CLAUDE_CODE_VERSION",
                    "CODEX_PKG", "CODEX_VERSION",
                    "OPENCODE_PKG", "OPENCODE_VERSION",
                    "GEMINI_PKG", "GEMINI_VERSION",
                    "QWEN_CODE_PKG", "QWEN_CODE_VERSION",
                    "COPILOT_PKG", "COPILOT_VERSION",
                    "IFLOW_PKG", "IFLOW_VERSION"]:
            self.assertIn(key, schema.PARAM_KEYS)
        schema.validate_params({"APT_UPGRADE": "true", "MIRROR_SKIP_APT": ""}, [])
        schema.validate_params({"PROXY_TEST_URL": "https://example.test/probe"}, [])
        schema.validate_params({"PROXY_CONNECT_TIMEOUT": "9", "PROXY_MAX_TIME": "21"}, [])
        schema.validate_params({"NO_PROXY": "localhost,127.0.0.1,::1"}, [])
        schema.validate_params({"NVM_VERSION": "v0.40.1"}, [])
        schema.validate_params({"CLAUDE_CODE_PKG": "@anthropic-ai/claude-code"}, [])
        schema.validate_params({"CLAUDE_CODE_VERSION": "2.1.228"}, [])
        schema.validate_params({"CODEX_PKG": "@openai/codex"}, [])
        schema.validate_params({"CODEX_VERSION": "0.147.0"}, [])
        schema.validate_params({"OPENCODE_PKG": "opencode-ai"}, [])
        schema.validate_params({"OPENCODE_VERSION": "1.18.18"}, [])
        schema.validate_params({"GEMINI_PKG": "@google/gemini-cli"}, [])
        schema.validate_params({"GEMINI_VERSION": "0.66.0"}, [])
        schema.validate_params({"QWEN_CODE_PKG": "@qwen-code/qwen-code"}, [])
        schema.validate_params({"QWEN_CODE_VERSION": "0.26.2"}, [])
        schema.validate_params({"COPILOT_PKG": "@github/copilot"}, [])
        schema.validate_params({"COPILOT_VERSION": "1.0.105"}, [])
        schema.validate_params({"IFLOW_PKG": "@iflow-ai/iflow-cli"}, [])
        schema.validate_params({"IFLOW_VERSION": "0.5.19"}, [])
        schema.validate_params({"JOURNALD_MAX_USE": "200M"}, [])
        for bad in [{"APT_UPGRADE": "1"}, {"MIRROR_SKIP_APT": "yes"},
                    {"PROXY_CONNECT_TIMEOUT": "0"}, {"PROXY_MAX_TIME": "-1"},
                    {"PROXY_CONNECT_TIMEOUT": "abc"},
                    {"PROXY_TEST_URL": "file:///etc/passwd"},
                    {"NO_PROXY": "a b"}, {"NVM_VERSION": "v0.40.1; rm -rf /"},
                    {"CLAUDE_CODE_PKG": "pkg; rm -rf /"},
                    {"CLAUDE_CODE_PKG": "pkg with space"},
                    {"CLAUDE_CODE_VERSION": "1.0.0 && echo x"},
                    {"JOURNALD_MAX_USE": "200MB"}, {"JOURNALD_MAX_USE": "0"}]:
            with self.assertRaises(schema.ValidationError):
                schema.validate_params(bad, [])

    def test_state_drops_stale_selection(self):
        """catalog 变更或文件被手工改坏后，陈旧条目不应再导致 run 校验失败。"""
        ui = self.cfg.state_dir / "ui"
        ui.mkdir(parents=True, exist_ok=True)
        (ui / "selection.json").write_text(json.dumps(
            {"version": 1, "tools": ["git", "ghost"],
             "adhoc": ["apt:jq", "bad token"], "verb": "install"}))
        code, _, body = self.get("/api/state", token="tok")
        self.assertEqual(code, 200, body)
        d = json.loads(body)
        self.assertEqual(d["selection"]["tools"], ["git"])
        self.assertEqual(d["selection"]["adhoc"], ["apt:jq"])

    def test_static_and_traversal(self):
        self.assertEqual(self.get("/", token="tok")[0], 200)
        self.assertEqual(self.get("/static/app.js", token="tok")[0], 200)
        self.assertEqual(self.get("/static/../fake-setup.sh", token="tok")[0], 404)

    def test_sudo_check(self):
        code, body = self.post("/api/sudo/check", {})
        self.assertEqual(code, 200)
        payload = json.loads(body)
        self.assertIn("available", payload)
        self.assertEqual(payload["platform"], os.name)

    def test_post_requires_json(self):
        code, _ = self.post("/api/sudo/check", {}, content_type="text/plain")
        self.assertEqual(code, 415)

    def test_rejects_oversized_body(self):
        """超大 Content-Length 不应被完整读入内存。"""
        port = self.srv.server_address[1]
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            sock.sendall(
                b"POST /api/sudo/check HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Authorization: Bearer tok\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: 2097152\r\n\r\n")
            status_line = sock.recv(4096).split(b"\r\n", 1)[0]
        self.assertIn(b"413", status_line)

class SelectionFallbackTests(unittest.TestCase):
    def test_profile_fallback_excludes_adhoc_ids(self):
        """default profile 里的内联工具会以派生 id 出现，不能当作 catalog 工具回填。"""
        with tempfile.TemporaryDirectory() as tmp:
            holder = mock.Mock()
            holder.server.config.state_dir = Path(tmp) / "state"
            catalog = {
                "catalog": [{"id": "git"}],
                "profiles": [{"name": "default",
                              "tools": ["git", "apt-htop"]}],
            }
            selection = server_mod.Handler._read_selection(holder, catalog)
        self.assertEqual(selection["tools"], ["git"])
        self.assertEqual(selection["adhoc"], [])

    def test_catalog_index_splits_space_separated_deps(self):
        """引擎把 deps 存成空格分隔，UI 必须按同样规则切分。"""
        holder = mock.Mock()
        holder._load_catalog = mock.Mock(return_value={
            "catalog": [
                {"id": "git", "deps": "alpha beta"},
                {"id": "solo", "deps": ""},
                {"id": "commas", "deps": "x,y"},
            ],
            "profiles": [],
        })
        _ids, deps = server_mod.Handler._catalog_index(holder)
        self.assertEqual(deps["git"], ["alpha", "beta"])
        self.assertEqual(deps["solo"], [])
        self.assertEqual(deps["commas"], ["x", "y"])

class PlanTimeoutTests(ServerFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        catalog = {"catalog": [{"id": "git", "desc": "git",
                                "type": "config", "deps": ""}],
                   "profiles": [{"name": "default", "tools": ["git"],
                                 "error": ""}]}
        slow = cls.cfg.project_dir / "slow-setup.sh"
        slow.write_text("#!/usr/bin/env bash\n"
                        "if [[ \" $* \" == *\" --list \"* ]]; then\n"
                        f"  printf '%s\\n' '{json.dumps(catalog)}'\n"
                        "  exit 0\n"
                        "fi\n"
                        "sleep 5\n")
        cls.cfg.setup_cmd = ["bash", str(slow)]

    def test_plan_timeout_is_bounded_and_reported(self):
        """计划子进程卡住时必须有上限，且不能把 handler 永久占住。"""
        with mock.patch.object(server_mod, "_PLAN_TIMEOUT", 0.5, create=True):
            started = time.time()
            code, body = self.post("/api/plan",
                                   {"verb": "install", "pick": ["git"]})
            elapsed = time.time() - started
        self.assertEqual(code, 200, body)
        d = json.loads(body)
        self.assertEqual(d["exit"], 1)
        self.assertLess(elapsed, 3)
        self.assertTrue(any("超时" in line for line in d["logs"]), d["logs"])


FAKE = r'''#!/usr/bin/env bash
printf '%s\n' "$@" > "$0.args"
ev="${OS_CONFIG_EVENTS:-}"
emit() { [[ -n "$ev" ]] || return 0; printf '%s\n' "$1" >>"$ev"; }
if [[ " $* " == *" --list "* ]]; then printf '%s\n' '__CATALOG__'; exit 0; fi
phase="install"; [[ " $* " == *" verify "* ]] && phase="verify"
emit "{\"event\":\"run_start\",\"verb\":\"$phase\",\"phase\":\"$phase\",\"ids\":[\"git\"]}"
echo "line one $phase"
emit "{\"event\":\"item_start\",\"id\":\"git\",\"verb\":\"$phase\",\"phase\":\"$phase\",\"type\":\"config\"}"
[[ " $* " == *" --dry-run "* ]] && st=planned || st=ok
emit "{\"event\":\"item_end\",\"id\":\"git\",\"verb\":\"$phase\",\"phase\":\"$phase\",\"type\":\"config\",\"status\":\"$st\",\"rc\":0}"
echo "line two $phase"
echo "[INFO] [git] tagged $phase"
echo "API_KEY=supersecret"
sleep 0.4
if [[ " $* " == *"failpkg"* ]]; then exit 1; fi
exit 0
'''

class RunTests(ServerFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        fake = cls.cfg.project_dir / "run-setup.sh"
        fake.write_text(FAKE.replace("__CATALOG__", json.dumps(
            {"catalog": [{"id": "git", "desc": "git", "type": "config", "deps": ""}],
             "profiles": [{"name": "default", "tools": ["git"], "error": ""}]})))
        cls.cfg.setup_cmd = ["bash", str(fake)]

    def test_plan(self):
        code, body = self.post("/api/plan", {"verb": "install", "pick": ["git"]})
        self.assertEqual(code, 200, body)
        d = json.loads(body)
        self.assertEqual(d["items"][0]["id"], "git")
        self.assertEqual(d["items"][0]["status"], "planned")
        self.assertTrue(d["items"][0]["selected"])
        self.assertEqual(d["items"][0]["required_by"], [])
        self.assertTrue(d["logs"])

    def test_plan_rejects_bad_pick(self):
        code, _ = self.post("/api/plan", {"verb": "install", "pick": ["apt:jq;rm"]})
        self.assertEqual(code, 400)

    def test_run_accepts_all_five_verbs(self):
        """引擎的五个动词都要能从 Web UI 触发。"""
        for verb in ["install", "update", "remove", "verify", "status"]:
            body = {"verb": verb, "pick": ["git"]}
            if verb == "remove":
                body["confirm"] = True
            code, resp = self.post("/api/run", body)
            self.assertEqual(code, 202, f"{verb}: {resp}")
            self.wait_idle()
            args = (self.cfg.project_dir / "run-setup.sh.args").read_text(
                encoding="utf-8").splitlines()
            self.assertIn(verb, args, f"{verb} 未透传给 setup.sh")

    def test_run_rejects_unknown_verb(self):
        code, _ = self.post("/api/run", {"verb": "frobnicate", "pick": ["git"]})
        self.assertEqual(code, 400)

    def test_plan_of_readonly_verb_uses_install_dry_run(self):
        """只读动词没有 dry-run 短路，预览必须改用写动词，避免真的跑校验。"""
        for verb in ["verify", "status"]:
            code, body = self.post("/api/plan", {"verb": verb, "pick": ["git"]})
            self.assertEqual(code, 200, body)
            args = (self.cfg.project_dir / "run-setup.sh.args").read_text(
                encoding="utf-8").splitlines()
            self.assertIn("install", args)
            self.assertIn("--dry-run", args)
            self.assertNotIn(verb, args)

    def test_run_concurrent_409(self):
        code, body = self.post("/api/run", {"verb": "install", "pick": ["git"]})
        self.assertEqual(code, 202, body)
        code2, _ = self.post("/api/run", {"verb": "install", "pick": ["git"]})
        self.assertEqual(code2, 409)
        self.wait_idle()
        code3, _ = self.post("/api/run", {"verb": "install", "pick": ["git"]})
        self.assertEqual(code3, 202)
        self.wait_idle()

    def test_remove_requires_confirm(self):
        code, _ = self.post("/api/run", {"verb": "remove", "pick": ["git"]})
        self.assertEqual(code, 400)
        code, _ = self.post("/api/run", {"verb": "remove", "pick": ["git"], "confirm": True})
        self.assertEqual(code, 202)
        self.wait_idle()

    def test_pick_is_single_comma_argument(self):
        code, body = self.post("/api/run", {"verb": "install",
                                            "pick": ["git", "apt:other"]})
        self.assertEqual(code, 202, body)
        self.wait_idle()
        args = (self.cfg.project_dir / "run-setup.sh.args").read_text(
            encoding="utf-8").splitlines()
        self.assertEqual(args.count("--pick"), 1)
        self.assertEqual(args[args.index("--pick") + 1], "git,apt:other")

    def test_plan_pick_is_single_comma_argument(self):
        code, body = self.post("/api/plan", {"verb": "install",
                                             "pick": ["git", "apt:other"]})
        self.assertEqual(code, 200, body)
        args = (self.cfg.project_dir / "run-setup.sh.args").read_text(
            encoding="utf-8").splitlines()
        self.assertEqual(args.count("--pick"), 1)
        self.assertEqual(args[args.index("--pick") + 1], "git,apt:other")

    def test_verify_phase_runs(self):
        code, body = self.post("/api/run", {"verb": "install", "pick": ["git"],
                                            "verify_after": True})
        self.assertEqual(code, 202)
        d = self.wait_meta(json.loads(body)["run_id"])
        phases = {e.get("phase") for e in d["events"] if e["event"] == "item_end"}
        self.assertEqual(phases, {"install", "verify"})
        self.assertEqual(d["meta"]["verify_rc"], 0)

    def test_failed_install_skips_verify(self):
        code, body = self.post("/api/run", {"verb": "install", "pick": ["apt:failpkg"],
                                            "verify_after": True})
        self.assertEqual(code, 202)
        d = self.wait_meta(json.loads(body)["run_id"])
        self.assertNotEqual(d["meta"]["rc"], 0)
        self.assertFalse(any(e["event"] == "run_start" and e.get("phase") == "verify"
                             for e in d["events"]))
        self.assertIsNone(d["meta"]["verify_rc"])

    def test_remove_keeps_install_selection(self):
        ui = self.cfg.state_dir / "ui"
        ui.mkdir(parents=True, exist_ok=True)
        original = {"version": 1, "tools": ["git"], "adhoc": ["apt:jq"],
                    "verb": "install", "updated": "2026-10-20T10:00:00Z"}
        (ui / "selection.json").write_text(json.dumps(original))
        code, body = self.post("/api/run", {"verb": "remove", "pick": ["git"],
                                            "confirm": True})
        self.assertEqual(code, 202, body)
        self.wait_idle()
        saved = json.loads((ui / "selection.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["tools"], ["git"])
        self.assertEqual(saved["adhoc"], ["apt:jq"])
        self.assertEqual(saved["verb"], "install")

    def test_history_rejects_bad_name(self):
        for bad in ["a%2Fb", "x.txt", "20261020-120000"]:
            code, _, _ = self.get(f"/api/history/{bad}", token="tok")
            self.assertEqual(code, 400)

    def test_history_missing(self):
        code, _, _ = self.get("/api/history/20990101-000000-abcdef", token="tok")
        self.assertEqual(code, 404)

    def test_logs_redacted(self):
        code, body = self.post("/api/run", {"verb": "install", "pick": ["git"]})
        self.assertEqual(code, 202, body)
        run_id = json.loads(body)["run_id"]
        d = self.wait_meta(run_id)
        self.assertIn("API_KEY=****", d["log"])
        self.assertNotIn("supersecret", d["log"])
        run_log = (self.cfg.state_dir / "ui" / "runs" / run_id / "run.log")
        self.assertNotIn("supersecret", run_log.read_text(encoding="utf-8"))

    def test_meta_write_failure_releases_lock(self):
        with mock.patch.object(server_mod.RunJob, "_write_meta",
                               side_effect=OSError("disk full")):
            code, body = self.post("/api/run", {"verb": "install", "pick": ["git"]})
            self.assertEqual(code, 202, body)
            self.wait_idle()
        code, _ = self.post("/api/run", {"verb": "install", "pick": ["git"]})
        self.assertEqual(code, 202)
        self.wait_idle()

class SseTests(ServerFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        fake = cls.cfg.project_dir / "sse-setup.sh"
        fake.write_text(FAKE.replace("__CATALOG__", json.dumps(
            {"catalog": [{"id": "git", "desc": "git", "type": "config", "deps": ""}],
             "profiles": [{"name": "default", "tools": ["git"], "error": ""}]})))
        cls.cfg.setup_cmd = ["bash", str(fake)]

    def start_run(self):
        code, body = self.post("/api/run", {"verb": "install", "pick": ["git"]})
        self.assertEqual(code, 202, body)
        return json.loads(body)["run_id"]

    def test_stream_is_run_scoped_and_terminates(self):
        first = self.start_run()
        self.wait_meta(first)
        second = self.start_run()
        events = self.sse("?run_id=" + second)
        self.assertTrue(events)
        self.assertEqual({e["data"]["run_id"] for e in events}, {second})
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual([e["id"] for e in events],
                         sorted(e["id"] for e in events))
        self.assertFalse(any(e["event"] == "done"
                             and e["data"].get("run_id") == first
                             for e in events))
        self.wait_idle()

    def test_invalid_run_id_rejected(self):
        code, _, _ = self.get("/api/events?run_id=../x", token="tok", timeout=2)
        self.assertEqual(code, 400)

    def test_head_does_not_open_stream(self):
        """HEAD 不应进入 SSE 长连接，否则连接会一直挂到心跳超时。"""
        req = urllib.request.Request(
            self.base + "/api/events", method="HEAD",
            headers={"Authorization": "Bearer tok"})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=3) as resp:
                code = resp.status
        except urllib.error.HTTPError as exc:
            code = exc.code
        self.assertEqual(code, 405)
        self.assertLess(time.monotonic() - started, 2)

    def test_finished_run_without_backlog_streams_done(self):
        """服务重启后事件缓冲为空，回看已完成的 run 也必须收到 done 并断开。"""
        rid = "20261020-140000-cccccc"
        run_dir = self.cfg.state_dir / "ui" / "runs" / rid
        run_dir.mkdir(parents=True, exist_ok=True)
        (run_dir / "meta.json").write_text(json.dumps(
            {"run_id": rid, "verb": "install", "started": "2026-10-20T14:00:00Z",
             "finished": "2026-10-20T14:01:00Z", "rc": 0, "ok": 1,
             "skipped": 0, "failed": 0, "rolled_back": False, "verify_rc": 0}),
            encoding="utf-8")
        events = self.sse("?run_id=" + rid, timeout=2)
        self.assertTrue(events)
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["data"]["run_id"], rid)

    def test_log_events_carry_item_id(self):
        run_id = self.start_run()
        events = self.sse("?run_id=" + run_id)
        logs = [e["data"] for e in events if e["event"] == "log"]
        self.assertTrue(logs)
        self.assertTrue(all("id" in data for data in logs))
        tagged = [data for data in logs if data.get("id") == "git"]
        self.assertTrue(tagged, logs)
        self.assertTrue(any("tagged" in data["line"] for data in tagged))
        self.wait_idle()

class InstalledTests(ServerFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        fake = cls.cfg.project_dir / "installed-setup.sh"
        fake.write_text(FAKE.replace("__CATALOG__", json.dumps(
            {"catalog": [{"id": "git", "desc": "git", "type": "config", "deps": ""}],
             "profiles": [{"name": "default", "tools": ["git"], "error": ""}]})))
        cls.cfg.setup_cmd = ["bash", str(fake)]

    def test_manifest(self):
        (self.cfg.state_dir).mkdir(parents=True, exist_ok=True)
        (self.cfg.state_dir / "manifest.conf").write_text(
            "git|git|/home/u/.gitconfig|2026-10-20T10:00:00\n")
        code, _, body = self.get("/api/installed", token="tok")
        self.assertEqual(code, 200)
        d = json.loads(body)
        self.assertEqual(d["entries"][0]["id"], "git")
        self.assertEqual(d["entries"][0]["artifacts"], ["/home/u/.gitconfig"])
        self.assertEqual(d["catalog_tools"][0]["id"], "git")
        self.assertIn("action", d["catalog_tools"][0])

    def test_status(self):
        code, _, body = self.get("/api/status?pick=git", token="tok")
        self.assertEqual(code, 200, body)
        d = json.loads(body)
        self.assertEqual([i["id"] for i in d["items"]], ["git"])
        self.assertEqual(d["items"][0]["status"], "ok")
        self.assertEqual(d["exit"], 0)
        self.assertTrue(d["logs"])

    def test_status_conflicts_with_running_job(self):
        self.srv.run_lock.acquire()
        try:
            code, _, _ = self.get("/api/status?pick=git", token="tok")
        finally:
            self.srv.run_lock.release()
        self.assertEqual(code, 409)

    def test_status_pick_is_single_comma_argument(self):
        code, _, body = self.get("/api/status?pick=git,apt:jq", token="tok")
        self.assertEqual(code, 200, body)
        args = (self.cfg.project_dir / "installed-setup.sh.args").read_text(
            encoding="utf-8").splitlines()
        self.assertEqual(args.count("--pick"), 1)
        self.assertEqual(args[args.index("--pick") + 1], "git,apt:jq")

    def test_history_list(self):
        base = self.cfg.state_dir / "ui" / "runs"
        for rid, started in [("20261020-120000-aaaaaa", "2026-10-20T12:00:00Z"),
                             ("20261020-130000-bbbbbb", "2026-10-20T13:00:00Z")]:
            d = base / rid
            d.mkdir(parents=True, exist_ok=True)
            (d / "meta.json").write_text(json.dumps(
                {"run_id": rid, "verb": "install", "started": started,
                 "finished": started, "rc": 0, "ok": 1, "skipped": 0, "failed": 0}))
        code, _, body = self.get("/api/history", token="tok")
        self.assertEqual(code, 200)
        runs = json.loads(body)
        self.assertEqual(runs[0]["run_id"], "20261020-130000-bbbbbb")
        self.assertEqual(runs[1]["run_id"], "20261020-120000-aaaaaa")

class FrontendTests(unittest.TestCase):
    def test_assets_have_required_ids(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        html = (root / "index.html").read_text(encoding="utf-8")
        for elem_id in ["app", "sudo-badge", "preset", "search", "tool-list",
                        "dep-banner", "params", "keep-going", "verify-after",
                        "force", "clear-secrets", "plan-btn", "run-btn",
                        "plan-summary", "results", "log", "autoscroll",
                        "log-copy", "log-download",
                        "remove-section", "remove-list", "remove-btn",
                        "confirm-modal", "toasts", "history"]:
            self.assertIn(f'id="{elem_id}"', html)
        self.assertIn("某项失败后继续执行其余项", html)
        js = (root / "app.js").read_text(encoding="utf-8")
        for ev in ["log", "plan", "item", "rollback", "summary", "done"]:
            self.assertIn(ev, js)
        self.assertIn("EventSource", js)
        self.assertIn("Content-Type", js)
        self.assertIn("run_id", js)
        self.assertIn("clipboard", js)
        self.assertIn("download", js)
        self.assertIn("eventSource.close()", js)
        self.assertIn("/api/events?run_id=", js)
        self.assertIn("S.secrets[", js)
        self.assertIn("S.results.keys()", js)
        self.assertIn("catalog_tools", js)
        self.assertIn("/api/status", js)
        self.assertNotIn("innerHTML", js)
        self.assertTrue((root / "style.css").read_text(encoding="utf-8").strip())

    def test_sudo_badge_hidden_on_windows(self):
        """Windows 没有 sudo 语义：前端须按 platform=nt 隐藏 sudo 徽标。"""
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        html = (root / "index.html").read_text(encoding="utf-8")
        self.assertIn('id="sudo-badge"', html)
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ['data.platform === "nt"', "badge.hidden = true",
                      "badge.hidden = false"]:
            self.assertIn(token, js)

    def test_workspace_tabs_present(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        html = (root / "index.html").read_text(encoding="utf-8")
        self.assertIn('role="tablist"', html)
        for elem_id in ["results-tab", "log-tab", "history-tab",
                        "panel-results", "panel-log", "panel-history",
                        "results-count", "result-summary", "current-item",
                        "history-refresh"]:
            self.assertIn(f'id="{elem_id}"', html)
        self.assertIn('aria-controls="panel-results"', html)
        self.assertIn('aria-selected="true"', html)
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["function setTab", 'setTab("log")', 'setTab("results")',
                      "item_start", "results-count", "result-summary"]:
            self.assertIn(token, js)
        css = (root / "style.css").read_text(encoding="utf-8")
        for token in [".tab-panel[hidden]", ".tab.is-active", ".tabbar"]:
            self.assertIn(token, css)

    def test_main_tabs_and_header_plan(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        html = (root / "index.html").read_text(encoding="utf-8")
        for elem_id in ["tools-tab", "runs-tab", "panel-tools", "panel-runs"]:
            self.assertIn(f'id="{elem_id}"', html)
        header = html.split("</header>", 1)[0]
        self.assertIn('id="plan-summary"', header)
        self.assertIn('id="plan-btn"', header)
        self.assertIn('id="run-btn"', header)
        self.assertIn('id="status-btn"', header)
        self.assertLess(header.index('id="plan-btn"'), header.index('id="status-btn"'))
        self.assertNotIn('id="results"', header)
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["function setMainTab", "MAIN_TABS", 'setMainTab("runs")']:
            self.assertIn(token, js)
        css = (root / "style.css").read_text(encoding="utf-8")
        for token in [".maintabs", ".maintab.is-active", ".plan-strip"]:
            self.assertIn(token, css)

    def test_verb_selector_exposes_five_verbs(self):
        """顶栏动词下拉框要能选到引擎的五个动词。"""
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        html = (root / "index.html").read_text(encoding="utf-8")
        self.assertIn('id="verb"', html)
        block = html.split('id="verb"', 1)[1].split("</select>", 1)[0]
        for verb in ["install", "update", "remove", "verify", "status"]:
            self.assertIn(f'value="{verb}"', block)
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["function selectedVerb()", "runRemoveWithConfirm(",
                      "startRun(verb)", 'startRun("remove"']:
            self.assertTrue(token in js, f"app.js 缺少 {token}")

    def test_fixed_scroll_and_per_tool_logs(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        html = (root / "index.html").read_text(encoding="utf-8")
        for elem_id in ["params-scroll", "results-scroll"]:
            self.assertIn(f'id="{elem_id}"', html)
        self.assertIn('class="params-scroll"', html)
        self.assertIn('class="results-scroll"', html)
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["S.collapsedGroups", 'make("details"', 'make("summary"',
                      "S.logGroups", "function appendLog(line, cls, toolId)",
                      "logIdFromLine", "data.id"]:
            self.assertIn(token, js)
        css = (root / "style.css").read_text(encoding="utf-8")
        for token in [".params-scroll", ".results-scroll", ".log-group",
                      "overflow-y: auto", "position: sticky"]:
            self.assertIn(token, css)

    def test_fullscreen_layout(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        css = (root / "style.css").read_text(encoding="utf-8")
        self.assertIn("max-width: none", css)
        self.assertNotIn("max-width: 1280px", css)
        self.assertIn("width: 100%", css)
        self.assertIn("min-height: 100%", css)

    def test_panels_fill_viewport(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        css = (root / "style.css").read_text(encoding="utf-8")
        for token in [".mainpanel {", "grid-template-rows: minmax(0, 1fr)",
                      "min-height: 0;"]:
            self.assertIn(token, css)
        self.assertNotIn("height: 460px", css)
        self.assertNotIn("height: 380px", css)
        self.assertNotIn("height: 420px", css)

    def test_log_body_uses_full_height(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        css = (root / "style.css").read_text(encoding="utf-8")
        log_rule = css.split(".log {", 1)[1].split("}", 1)[0]
        self.assertIn("overflow: auto", log_rule)
        body_rule = css.split(".log-group-body {", 1)[1].split("}", 1)[0]
        self.assertNotIn("max-height", body_rule)
        self.assertNotIn("overflow-y", body_rule)

    def test_adhoc_input_and_semantic_layout(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        html = (root / "index.html").read_text(encoding="utf-8")
        for elem_id in ["adhoc-input", "adhoc-add"]:
            self.assertIn(f'id="{elem_id}"', html)
        self.assertIn('class="layout"', html)
        self.assertNotIn("<main", html)
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["validAdhocToken", "adhoc-input", "adhoc-add"]:
            self.assertIn(token, js)

    def test_history_playback_locked_during_run(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["function canLoadHistory", "updateHistoryAvailability",
                      "canLoadHistory(isBusy())"]:
            self.assertIn(token, js)

    def test_log_export_preserves_stream_order(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["logLines: []", "appendLogLine(S.logLines",
                      "S.logLines = []"]:
            self.assertIn(token, js)
        collect = js.split("function collectLogLines()", 1)[1].split("}", 1)[0]
        self.assertIn("S.logLines", collect)
        self.assertNotIn("querySelectorAll", collect)

    def test_selection_locked_during_run(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        for token in ["function updateSelectionControls", "updateSelectionControls()",
                      "function isBusy()", "box.disabled = isBusy()"]:
            self.assertIn(token, js)
        controls = js.split("function updateSelectionControls()", 1)[1].split("}", 1)[0]
        self.assertIn("const busy = isBusy();", controls)
        checking = js.split("function setChecking(", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("updateSelectionControls();", checking)

    def test_history_and_plan_blocked_while_checking(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        availability = js.split("function updateHistoryAvailability(", 1)[1].split("}", 1)[0]
        self.assertIn("canLoadHistory(isBusy())", availability)
        history = js.split("async function loadHistory(", 1)[1].split("try {", 1)[0]
        self.assertIn("if (!canLoadHistory(isBusy()))", history)
        plan = js.split("async function runPlan()", 1)[1].split("const seq", 1)[0]
        self.assertIn("if (isBusy()) return;", plan)

    def test_adhoc_removal_rerenders_tool_list(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        block = js.split("box.value = token;", 1)[1].split(
            "section.appendChild(line);", 1)[0]
        self.assertIn("if (!box.checked) {", block)
        self.assertIn("renderTools();", block)

    def test_results_follow_the_active_pick(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        self.assertIn("resultPick: []", js)
        self.assertIn("selectionResultIds(S.resultPick,", js)
        self.assertNotIn("selectionResultIds(Array.from(S.selection)", js)
        for name, expected in [("startRun", "S.resultPick = pick.slice()"),
                               ("checkStatus", "S.resultPick = pick.slice()"),
                               ("loadHistory", "S.resultPick = []")]:
            body = js.split(f"async function {name}(", 1)[1].split("\nasync function ", 1)[0]
            # 请求成功后才切换结果视图，失败时保留原有结果。
            self.assertGreater(body.index(expected), body.index("await api("), name)
        self.assertIn("S.resultPick = Array.from(S.selection)", js)

    def test_secret_inputs_keep_typed_value_after_rerender(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        body = js.split("function renderParams(", 1)[1].split("\nfunction ", 1)[0]
        # 重新渲染（如切换工具选择）不能丢掉用户刚输入的口令。
        self.assertIn("input.value = S.params[field.key]", body)

    def test_start_run_guards_double_submit(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        busy = js.split("function isBusy(", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("S.starting", busy)
        body = js.split("async function startRun(", 1)[1].split("\nasync function ", 1)[0]
        self.assertLess(body.index("S.starting = true"), body.index("await api("))
        self.assertIn("S.starting = false", body)

    def test_finish_run_defaults_verify_once(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        block = js.split("function finishRun(", 1)[1].split("function ", 1)[0]
        self.assertEqual(block.count('entry.verify = "not_run"'), 1)

    def test_plan_refreshes_after_busy_period(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        checking = js.split("function setChecking(", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("schedulePlan(0);", checking)
        finish = js.split("function finishRun(", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("schedulePlan(0);", finish)

    def test_failed_row_uses_real_button(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        self.assertNotIn('setAttribute("role", "button")', js)
        for token in ["log-jump", "在日志中定位", 'closest("button")']:
            self.assertIn(token, js)

    def test_object_url_is_revoked(self):
        root = Path(__file__).resolve().parents[1] / "ui" / "static"
        js = (root / "app.js").read_text(encoding="utf-8")
        self.assertEqual(js.count("createObjectURL"), js.count("revokeObjectURL"))
