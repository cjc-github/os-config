import json, tempfile, threading, time, unittest, urllib.error, urllib.request
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

    def test_collision(self):
        with self.assertRaises(schema.ValidationError):
            schema.validate_pick(["apt:foo", "snap:foo"], {"git"})
        with self.assertRaises(schema.ValidationError):
            schema.validate_pick(["foo", "apt:foo"], {"foo"})

    def test_bad_catalog_ids(self):
        for bad in ["bad id", "-x", "", "a;b", "../x"]:
            with self.assertRaises(schema.ValidationError):
                schema.validate_pick([bad], {"git"})

class ParamTests(unittest.TestCase):
    def test_groups(self):
        groups = {g["id"]: g for g in schema.PARAM_GROUPS}
        self.assertEqual(set(groups), {"mirrors", "proxy", "git", "ssh", "syslog", "nodejs"})
        self.assertEqual(groups["nodejs"]["tools"], ["nodejs"])
        self.assertEqual(groups["git"]["tools"], ["git"])
        self.assertIn("NPM_REGISTRY", {f["key"] for f in groups["nodejs"]["fields"]})

    def test_whitelist(self):
        schema.validate_params({"GIT_USER_NAME": "A B"}, [])
        for bad in [{"EVIL": "x"}, {"GIT_USER_NAME": "a\nb"},
                    {"PROXY_PORT": "70000"}, {"SSH_KEY_TYPE": "dsa"},
                    {"MIRROR_APT_URL": "file:///etc/passwd"}]:
            with self.assertRaises(schema.ValidationError):
                schema.validate_params(bad, [])
        with self.assertRaises(schema.ValidationError):
            schema.validate_params({}, ["EVIL"])

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
        self.assertNotIn("SSH_KEY_PASSPHRASE", d["params"])
        self.assertTrue(d["secrets"]["SSH_KEY_PASSPHRASE"])
        for key in ["profiles", "running", "current", "sudo"]:
            self.assertIn(key, d)

    def test_static_and_traversal(self):
        self.assertEqual(self.get("/", token="tok")[0], 200)
        self.assertEqual(self.get("/static/app.js", token="tok")[0], 200)
        self.assertEqual(self.get("/static/../fake-setup.sh", token="tok")[0], 404)

    def test_sudo_check(self):
        code, body = self.post("/api/sudo/check", {})
        self.assertEqual(code, 200)
        self.assertIn("available", json.loads(body))

    def test_post_requires_json(self):
        code, _ = self.post("/api/sudo/check", {}, content_type="text/plain")
        self.assertEqual(code, 415)

FAKE = r'''#!/usr/bin/env bash
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

    def test_run_rejects_update(self):
        code, _ = self.post("/api/run", {"verb": "update", "pick": ["git"]})
        self.assertEqual(code, 400)

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
