"""Web UI 的参数白名单、pick 校验与路径安全工具。

本模块不依赖任何第三方库，所有函数都只做纯校验/转换，便于单元测试。
"""

from __future__ import annotations

import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path


class ValidationError(ValueError):
    """请求参数或路径非法。"""


# ---------------------------------------------------------------------------
# 参数白名单
# ---------------------------------------------------------------------------
_URL_RE = re.compile(r"^https?://[^\s'\"]+$")
_PROXY_HOST_RE = re.compile(r"^(?:[A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\])$")
_JOURNALD_RE = re.compile(r"^[1-9][0-9]*[KMGTP]?$")
_DIGITS_RE = re.compile(r"^[0-9]+$")
_NODE_VERSION_RE = re.compile(r"^v?[0-9]+\.[0-9]+\.[0-9]+$")
_PKG_NAME_RE = re.compile(r"^[A-Za-z0-9@][A-Za-z0-9._+/@=-]*$")
_VERSION_RE = re.compile(r"^v?[0-9A-Za-z][0-9A-Za-z.\-+]*$")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
_WHITESPACE_RE = re.compile(r"\s")

_SECRET_KEYS = frozenset({"SSH_KEY_PASSPHRASE"})


def _valid_url(value: str) -> bool:
    return value == "" or _URL_RE.fullmatch(value) is not None


def _valid_host(value: str) -> bool:
    # 与引擎 resolve_proxy_endpoint 保持一致：首字符为 "-" 会被下游当作选项。
    if value.startswith("-"):
        return False
    return value == "" or _PROXY_HOST_RE.fullmatch(value) is not None


def _valid_port(value: str) -> bool:
    if value == "":
        return True
    if _DIGITS_RE.fullmatch(value) is None:
        return False
    return 1 <= int(value) <= 65535


def _valid_name(value: str) -> bool:
    return len(value) <= 256 and _CONTROL_RE.search(value) is None


def _valid_email(value: str) -> bool:
    return (
        value == ""
        or (
            len(value) <= 256
            and "@" in value
            and _CONTROL_RE.search(value) is None
            and _WHITESPACE_RE.search(value) is None
        )
    )


def _valid_key_type(value: str) -> bool:
    return value in ("", "ed25519", "rsa")


def _valid_passphrase(value: str) -> bool:
    return len(value) <= 1024 and not any(c in value for c in ("\x00", "\n", "\r"))


def _valid_journald(value: str) -> bool:
    return value == "" or _JOURNALD_RE.fullmatch(value) is not None


def _valid_major(value: str) -> bool:
    return value == "" or _DIGITS_RE.fullmatch(value) is not None


def _valid_node_version(value: str) -> bool:
    return value == "" or _NODE_VERSION_RE.fullmatch(value) is not None


def _valid_switch(value: str) -> bool:
    """空串=沿用引擎默认；否则只接受 true/false。"""
    return value in ("", "true", "false")


def _valid_seconds(value: str) -> bool:
    """超时秒数：空串=沿用引擎默认；否则为正整数。"""
    if value == "":
        return True
    if _DIGITS_RE.fullmatch(value) is None:
        return False
    return int(value) >= 1


def _valid_noproxy(value: str) -> bool:
    """NO_PROXY 是逗号分隔的主机列表，不允许空白与换行。"""
    return value == "" or _WHITESPACE_RE.search(value) is None


def _valid_pkg_name(value: str) -> bool:
    """npm 包名：与引擎的 _catalog_valid_pkg_spec 同一套字符。"""
    if value == "":
        return True
    if _CONTROL_RE.search(value) is not None or _WHITESPACE_RE.search(value) is not None:
        return False
    return _PKG_NAME_RE.fullmatch(value) is not None


def _valid_version(value: str) -> bool:
    """版本号或 dist-tag（如 2.1.228 / v0.40.1 / latest）。"""
    if value == "":
        return True
    return _VERSION_RE.fullmatch(value) is not None


_PARAM_VALIDATORS = {
    "MIRROR_APT_URL": _valid_url,
    "MIRROR_APT_PORTS_URL": _valid_url,
    "MIRROR_SKIP_APT": _valid_switch,
    "MIRROR_SKIP_APT_UPDATE": _valid_switch,
    "APT_UPGRADE": _valid_switch,
    "NPM_REGISTRY": _valid_url,
    "PROXY_ENABLED": _valid_switch,
    "PROXY_HOST": _valid_host,
    "PROXY_PORT": _valid_port,
    "PROXY_TEST_URL": _valid_url,
    "PROXY_CONNECT_TIMEOUT": _valid_seconds,
    "PROXY_MAX_TIME": _valid_seconds,
    "NO_PROXY": _valid_noproxy,
    "GIT_USER_NAME": _valid_name,
    "GIT_USER_EMAIL": _valid_email,
    "SSH_KEY_TYPE": _valid_key_type,
    "SSH_KEY_PASSPHRASE": _valid_passphrase,
    "JOURNALD_MAX_USE": _valid_journald,
    "NVM_VERSION": _valid_version,
    "NODE_LTS_MAJOR": _valid_major,
    "NODE_VERSION": _valid_node_version,
    "CLAUDE_CODE_PKG": _valid_pkg_name,
    "CLAUDE_CODE_VERSION": _valid_version,
    "CODEX_PKG": _valid_pkg_name,
    "CODEX_VERSION": _valid_version,
    "OPENCODE_PKG": _valid_pkg_name,
    "OPENCODE_VERSION": _valid_version,
    "GEMINI_PKG": _valid_pkg_name,
    "GEMINI_VERSION": _valid_version,
    "QWEN_CODE_PKG": _valid_pkg_name,
    "QWEN_CODE_VERSION": _valid_version,
    "COPILOT_PKG": _valid_pkg_name,
    "COPILOT_VERSION": _valid_version,
    "IFLOW_PKG": _valid_pkg_name,
    "IFLOW_VERSION": _valid_version,
}

PARAM_SPECS: dict[str, dict] = {
    key: {"validator": fn, "secret": key in _SECRET_KEYS}
    for key, fn in _PARAM_VALIDATORS.items()
}
PARAM_KEYS: frozenset[str] = frozenset(PARAM_SPECS)


def _field(key: str, label: str, *, type: str = "text", options=None,
           placeholder: str = "", secret: bool = False) -> dict:
    return {
        "key": key,
        "label": label,
        "type": type,
        "options": options or [],
        "placeholder": placeholder,
        "secret": secret,
    }


PARAM_GROUPS: list[dict] = [
    {
        "id": "mirrors",
        "title": "镜像源",
        "tools": ["mirrors"],
        "fields": [
            _field("MIRROR_APT_URL", "APT 源（amd64/i386）",
                   placeholder="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"),
            _field("MIRROR_APT_PORTS_URL", "APT 源（arm64 等）",
                   placeholder="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"),
            _field("MIRROR_SKIP_APT", "跳过换源", type="select",
                   options=["", "true", "false"]),
            _field("MIRROR_SKIP_APT_UPDATE", "跳过 apt update", type="select",
                   options=["", "true", "false"]),
            _field("APT_UPGRADE", "换源后全量 upgrade", type="select",
                   options=["", "true", "false"]),
        ],
    },
    {
        "id": "proxy",
        "title": "代理",
        "tools": ["proxy"],
        "fields": [
            _field("PROXY_ENABLED", "启用代理", type="select",
                   options=["", "true", "false"]),
            _field("PROXY_HOST", "代理主机", placeholder="留空自动探测"),
            _field("PROXY_PORT", "代理端口", placeholder="7890"),
            _field("PROXY_TEST_URL", "连通性验证地址",
                   placeholder="https://github.com"),
            _field("PROXY_CONNECT_TIMEOUT", "连接超时（秒）", placeholder="5"),
            _field("PROXY_MAX_TIME", "整体超时（秒）", placeholder="15"),
            _field("NO_PROXY", "不走代理的主机",
                   placeholder="localhost,127.0.0.1,::1"),
        ],
    },
    {
        "id": "git",
        "title": "Git",
        "tools": ["git"],
        "fields": [
            _field("GIT_USER_NAME", "用户名称", placeholder="Your Name"),
            _field("GIT_USER_EMAIL", "邮箱", placeholder="you@example.com"),
        ],
    },
    {
        "id": "ssh",
        "title": "SSH",
        "tools": ["ssh"],
        "fields": [
            _field("SSH_KEY_TYPE", "密钥类型", type="select",
                   options=["", "ed25519", "rsa"]),
            _field("SSH_KEY_PASSPHRASE", "密钥口令", type="password", secret=True),
        ],
    },
    {
        "id": "syslog",
        "title": "系统日志",
        "tools": ["syslog"],
        "fields": [
            _field("JOURNALD_MAX_USE", "journald 最大占用", placeholder="200M"),
        ],
    },
    {
        "id": "nodejs",
        "title": "Node.js",
        "tools": ["nodejs"],
        "fields": [
            _field("NVM_VERSION", "nvm 版本", placeholder="v0.40.1"),
            _field("NODE_LTS_MAJOR", "LTS 主版本", placeholder="22"),
            _field("NODE_VERSION", "指定版本", placeholder="v22.11.0"),
            _field("NPM_REGISTRY", "npm 源",
                   placeholder="https://registry.npmmirror.com"),
        ],
    },
    {
        "id": "claude",
        "title": "Claude Code",
        "tools": ["claude"],
        "fields": [
            _field("CLAUDE_CODE_PKG", "npm 包名",
                   placeholder="@anthropic-ai/claude-code"),
            _field("CLAUDE_CODE_VERSION", "锁定版本", placeholder="2.1.228"),
        ],
    },
    {
        "id": "codex",
        "title": "Codex",
        "tools": ["codex"],
        "fields": [
            _field("CODEX_PKG", "npm 包名", placeholder="@openai/codex"),
            _field("CODEX_VERSION", "锁定版本", placeholder="0.147.0"),
        ],
    },
    {
        "id": "opencode",
        "title": "OpenCode",
        "tools": ["opencode"],
        "fields": [
            _field("OPENCODE_PKG", "npm 包名", placeholder="opencode-ai"),
            _field("OPENCODE_VERSION", "锁定版本", placeholder="1.18.18"),
        ],
    },
    {
        "id": "gemini",
        "title": "Gemini CLI",
        "tools": ["gemini"],
        "fields": [
            _field("GEMINI_PKG", "npm 包名", placeholder="@google/gemini-cli"),
            _field("GEMINI_VERSION", "锁定版本", placeholder="0.66.0"),
        ],
    },
    {
        "id": "qwen",
        "title": "Qwen Code",
        "tools": ["qwen"],
        "fields": [
            _field("QWEN_CODE_PKG", "npm 包名",
                   placeholder="@qwen-code/qwen-code"),
            _field("QWEN_CODE_VERSION", "锁定版本", placeholder="0.26.2"),
        ],
    },
    {
        "id": "copilot",
        "title": "GitHub Copilot",
        "tools": ["copilot"],
        "fields": [
            _field("COPILOT_PKG", "npm 包名", placeholder="@github/copilot"),
            _field("COPILOT_VERSION", "锁定版本", placeholder="1.0.105"),
        ],
    },
    {
        "id": "iflow",
        "title": "iFlow CLI",
        "tools": ["iflow"],
        "fields": [
            _field("IFLOW_PKG", "npm 包名", placeholder="@iflow-ai/iflow-cli"),
            _field("IFLOW_VERSION", "锁定版本", placeholder="0.5.19"),
        ],
    },
]


# ---------------------------------------------------------------------------
# pick / adhoc 校验
# ---------------------------------------------------------------------------
_CATALOG_ID_RE = re.compile(r"^[a-z0-9_-]+$")
# 内联工具的包名规则必须与引擎的 _catalog_valid_pkg_spec 一致：
# 不得含空白、不得以 - 开头（避免参数注入）。
_ADHOC_RE = re.compile(r"^(apt|npm|snap):([A-Za-z0-9@][A-Za-z0-9._+/@=:~-]*)$")
_ADHOC_SPEC_RE = re.compile(r"^[A-Za-z0-9@][A-Za-z0-9._+/@=:~-]*$")


def normalize_adhoc_id(token: str) -> tuple[str, str, str]:
    """把 ``backend:spec`` 转为 ``(id, backend, spec)``。

    id 的生成规则与 ``engine/lib/profile.sh`` 保持一致：
    包名转小写、非 ``[a-z0-9_-]`` 字符换成 ``-``，再去掉首尾的 ``-``。
    """
    if not isinstance(token, str):
        raise ValidationError("内联工具标识必须是字符串")
    match = _ADHOC_RE.fullmatch(token)
    if match is None:
        raise ValidationError(f"非法的内联工具标识：{token!r}")
    backend, spec = match.groups()
    if spec.startswith("-") or _ADHOC_SPEC_RE.fullmatch(spec) is None:
        raise ValidationError(f"非法的内联工具包名：{token!r}")
    ident = re.sub(r"[^a-z0-9_-]", "-", spec.lower()).strip("-")
    if not ident:
        raise ValidationError(f"无法从内联标识生成工具 id：{token!r}")
    return ident, backend, spec


def validate_pick(tokens: list[str], catalog_ids: set[str]) -> list[str]:
    """校验并返回原始 token 列表；catalog id 非法、内联标识非法或 id 重复时抛错。"""
    if not isinstance(tokens, list):
        raise ValidationError("pick 必须是数组")
    seen: set[str] = set()
    out: list[str] = []
    for token in tokens:
        if not isinstance(token, str) or not token:
            raise ValidationError("pick 中的每一项都必须是非空字符串")
        if ":" in token:
            ident, _backend, _spec = normalize_adhoc_id(token)
            if ident in catalog_ids:
                raise ValidationError(f"内联工具 id 与 catalog 冲突：{ident!r}")
        else:
            if _CATALOG_ID_RE.fullmatch(token) is None or token.startswith("-"):
                raise ValidationError(f"非法的 catalog 工具 id：{token!r}")
            if token not in catalog_ids:
                raise ValidationError(f"catalog 中不存在工具：{token!r}")
            ident = token
        if ident in seen:
            raise ValidationError(f"pick 中存在重复工具 id：{ident!r}")
        seen.add(ident)
        out.append(token)
    return out


def validate_params(params: dict, reset_keys: list[str]) -> None:
    """校验参数键值都在白名单内，且值符合对应格式。"""
    if not isinstance(params, dict):
        raise ValidationError("params 必须是对象")
    for key, value in params.items():
        if key not in PARAM_KEYS:
            raise ValidationError(f"未知参数：{key!r}")
        if not isinstance(value, str):
            raise ValidationError(f"参数 {key} 的值必须是字符串")
        if not PARAM_SPECS[key]["validator"](value):
            raise ValidationError(f"参数 {key} 的值格式非法")
    if not isinstance(reset_keys, list):
        raise ValidationError("reset_params 必须是数组")
    for key in reset_keys:
        if key not in PARAM_KEYS:
            raise ValidationError(f"未知参数：{key!r}")


# ---------------------------------------------------------------------------
# ui.env 读写（三态：未出现=继承，""=显式空，值=覆盖）
# ---------------------------------------------------------------------------
def apply_param_changes(existing: dict[str, str], params: dict[str, str],
                        reset_keys: list[str]) -> dict[str, str]:
    """在已有参数上应用三态修改，未触碰的键保持不变。"""
    merged = dict(existing)
    for key in reset_keys:
        merged.pop(key, None)
    for key, value in params.items():
        merged[key] = value
    return merged


_QUOTED_RE = re.compile(r"^'((?:[^']|'\\'')*)'(?:\s+#.*)?\s*$", re.S)


def read_env_file(path) -> dict[str, str]:
    """读取 ui.env，只保留白名单键，并还原 shell 单引号转义。"""
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    result: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in PARAM_KEYS:
            continue
        if value == "":
            result[key] = ""
            continue
        quoted = _QUOTED_RE.fullmatch(value)
        if quoted is None:
            # 与 shell 一致：未加引号时，空白之后的 "#" 开始行内注释；
            # 紧贴值的 "#"（如 7890#x）属于值本身。
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        else:
            value = quoted.group(1).replace("'\\''", "'")
        result[key] = value
    return result


def _shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def render_ui_env(mapping: dict[str, str]) -> str:
    """渲染 shell 可 source 的 ui.env；顺序稳定。"""
    lines = ["# managed by os-config web ui"]
    for key in sorted(PARAM_KEYS):
        if key not in mapping:
            continue
        value = mapping[key]
        if value == "":
            lines.append(f"{key}=")
        else:
            lines.append(f"{key}={_shell_quote(value)}")
    return "\n".join(lines) + "\n"


def write_ui_env(path, mapping: dict[str, str], backup_dir) -> str | None:
    """原子写入 ui.env（0600）；旧文件先备份，返回备份路径或 None。"""
    path = Path(path)
    backup_dir = Path(backup_dir)
    backup_path: str | None = None

    if path.exists():
        backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(backup_dir, 0o700)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
        backup = backup_dir / f"ui.env.bak.{stamp}.{os.getpid()}"
        backup.write_bytes(path.read_bytes())
        os.chmod(backup, 0o600)
        backup_path = str(backup)

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".ui.env.", dir=str(path.parent))
    try:
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(render_ui_env(mapping))
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    os.chmod(path, 0o600)
    return backup_path


# ---------------------------------------------------------------------------
# 路径安全
# ---------------------------------------------------------------------------
def safe_static_path(root: Path, rel: str) -> Path | None:
    """把静态资源的相对路径限制在 root 内；非法或越界返回 None。"""
    if not isinstance(rel, str) or not rel or "\x00" in rel:
        return None
    rel_path = Path(rel)
    if rel_path.is_absolute() or any(part == ".." for part in rel_path.parts):
        return None
    try:
        root_resolved = Path(root).resolve()
        candidate = (root_resolved / rel_path).resolve()
    except (OSError, ValueError, RuntimeError):
        return None
    if not candidate.is_relative_to(root_resolved):
        return None
    return candidate


_RUN_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$")


def safe_run_id(name: str) -> str | None:
    """run_id 形如 ``YYYYMMDD-HHMMSS-<6hex>``，非法返回 None。"""
    if not isinstance(name, str) or _RUN_ID_RE.fullmatch(name) is None:
        return None
    return name
