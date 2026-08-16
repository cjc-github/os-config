# os-config

一键初始化当前操作系统的开发环境：识别平台 → 跑模块 → 装 + 验证。

当前支持平台：**ubuntu24**（其它平台 `ubuntu22` / `macos` / `arch` 为占位目录）。

## 快速开始

```bash
# 1. 配置用户变量（可选；不配也能跑，用默认值）
cp config/user.env.example config/user.env
# 编辑 config/user.env：填 GIT_USER_NAME / GIT_USER_EMAIL / PROXY_PORT 等

# 2. 列出可用模块
./setup.sh --list

# 3. 试跑（不执行任何操作，只打印计划）
./setup.sh --all --dry-run

# 4. 按配置文件 config/modules.conf 跑（默认启用全部模块）
./setup.sh

# 5. 或只跑指定模块（自动补依赖）
./setup.sh --module nodejs,claude
```

## 命令行参数

| 参数 | 说明 |
|---|---|
| `./setup.sh` | 按配置文件 `config/modules.conf` 跑 |
| `--module a,b` | 只跑指定模块（自动补依赖） |
| `--all` | 跑当前平台全部模块 |
| `--list` | 列出可用模块（NAME / DEPS / NEEDS_SUDO） |
| `--dry-run` | 只打印执行计划不执行 |
| `--install-only` | 只跑 install |
| `--verify-only` | 只跑 verify |
| `--force` | 忽略幂等判断强制重装 |
| `--keep-going` | 遇错不停，跑完再汇总 |
| `--no-sudo` | 跳过 NEEDS_SUDO 的模块 |
| `--platform ubuntu24` | 强制指定平台（测试用） |
| `--debug` | 打开调试日志 |
| `-h, --help` | 帮助 |

## 模块清单（ubuntu24）

| 模块名 | 目录 | DEPS | NEEDS_SUDO | 作用 |
|---|---|---|---|---|
| `mirrors` | `sys-mirrors/` | — | 1 | **第一步先跑**：Ubuntu 24.04 deb822 `ubuntu.sources` 换国内清华源（按 amd64/arm64 区分 ports）→ apt update 验证；支持自定义 MIRROR_APT_URL |
| `base` | `sys-base/` | mirrors | 1 | `apt update/upgrade` + 基础工具包（curl/wget/ca-cert/gnupg/unzip） |
| `git` | `net-git/` | base | 1 | 安装 git + 配置 user.name/email + http/https proxy |
| `ssh` | `net-ssh/` | base | 1 | openssh + 非交互生成 ed25519 密钥 |
| `proxy` | `net-proxy/` | base | 0 | shell 环境变量代理（写入 `~/.bashrc` 标记块） |
| `nodejs` | `rt-nodejs/` | base | 0 | nvm + node LTS + npm registry 镜像（npmmirror）+ `prefer-offline/no-audit/no-fund` 提速 |
| `log` | `rt-log/` | base | 1 | lnav/bat + journald 持久化 + logrotate + `oslogs` 别名 |
| `screen` | `rt-screen/` | base | 0 | 关闭息屏/锁屏（gsettings → xset → Server 跳过） |
| `claude` | `ai-claude/` | nodejs | 0 | `@anthropic-ai/claude-code` CLI（npm ENOTEMPTY 自动清理旧目录） |
| `codex` | `ai-codex/` | nodejs | 0 | `@openai/codex` CLI（npm ENOTEMPTY 自动清理旧目录） |
| `opencode` | `ai-opencode/` | nodejs | 0 | `opencode-ai` CLI（npm ENOTEMPTY 自动清理旧目录；包名 opencode-ai，不是 opencode） |

依赖链：

```
mirrors → base ─┬─ git ── proxy
                ├─ ssh
                ├─ nodejs ─┬─ claude
                │          ├─ codex
                │          └─ opencode
                ├─ log
                └─ screen
```

## 目录结构

```
os-config/
├── setup.sh                       # 唯一入口
├── README.md                       # 本文件
├── docs/
│   └── DESIGN.md                   # 详细设计文档（推荐阅读）
├── lib/                           # 共享库（平台无关）
│   ├── log.sh                      # 彩色输出 + 落盘日志（含脱敏）
│   ├── platform.sh                 # 平台识别
│   ├── runner.sh                   # 模块加载、拓扑排序、nvm 注入、install/verify 调度
│   └── utils.sh                    # 幂等判断、备份、确认、命令运行
├── config/
│   ├── modules.conf                # 启用的模块清单
│   ├── versions.env                # 固定版本号（占位，需按 §八流程实查锁定）
│   └── user.env.example            # 用户可覆盖变量（复制为 user.env 生效）
├── platforms/
│   ├── ubuntu24/                   # 已实现
│   │   ├── detect.sh
│   │   └── modules/<prefix>-<name>/
│   │       ├── module.conf         # NAME / DEPS / NEEDS_SUDO
│   │       ├── install.sh          # 安装/配置
│   │       └── verify.sh           # 验证（退出码即结论）
│   ├── ubuntu22/                   # 占位
│   ├── macos/                      # 占位
│   └── arch/                       # 占位
└── logs/                          # 运行时自动生成
```

模块目录前缀（`sys-` / `net-` / `rt-` / `ai-`）只影响视觉顺序，对运行逻辑透明；CLI 和 `modules.conf` 里都用不带前缀的 `NAME`。

## 设计要点

- **平台优先**：主脚本先识别平台再加载模块集
- **模块化 + 配置驱动**：每个功能是独立模块；`modules.conf` 勾选启用
- **每个模块 = 安装 + 验证**：`install.sh` 做，`verify.sh` 验证
- **权限模型**：`apt` 加 `sudo`；nvm/npm/git 不加；`--no-sudo` 跳过 NEEDS_SUDO 模块
- **nvm 注入**：runner 在调用 `DEPS=nodejs` 的模块前自动 `source nvm.sh + nvm use default`
- **幂等 + 可重入**：安装型 `command -v` 判断；配置型 grep 标记块 + 值比较；`--force` 强制重装
- **回滚**：改 dotfiles 前自动备份成 `.bashrc.bak.<ts>`
- **固定版本**：所有可装软件的版本号集中在 `config/versions.env`
- **日志**：终端带色输出 + 落盘到 `logs/`（脱敏 token/password/api_key）

更多细节（权限策略 / nvm PATH 注入 / 版本锁定流程 / 回滚 / 自测方案）见：

> 📄 **[docs/DESIGN.md](docs/DESIGN.md)** —— 完整设计文档

## 自测

```bash
# 静态检查
bash -n setup.sh lib/*.sh platforms/ubuntu24/detect.sh platforms/ubuntu24/modules/*/*.sh

# 计划预览（不执行）
./setup.sh --all --dry-run

# 隔离 HOME 跑不需要 sudo 的模块（不污染真实 .bashrc）
TMPHOME=$(mktemp -d) && cp ~/.bashrc "$TMPHOME/.bashrc"
HOME="$TMPHOME" ./setup.sh --module proxy --no-sudo
rm -rf "$TMPHOME"

# docker 容器全流程复跑
docker run --rm -it -v "$PWD:/os-config" ubuntu:24.04 bash -lc 'cd /os-config && ./setup.sh'
```

## 状态

- ✅ Ubuntu 24.04 完整实现（11 模块：mirrors + base + net*3 + rt*3 + ai*3）
- ✅ 下载提速策略：apt 换清华源（sys-mirrors）+ npm registry npmmirror + prefer-offline/no-audit/no-fund
- ✅ npm 原子替换失败修复：ai-* 安装前清理 prefix/lib/node_modules 旧目录和 `.xxxx-XXXX` 残留临时目录（ENOTEMPTY）
- ⏳ `versions.env` 中大部分版本号仍为占位值，需按 [docs/DESIGN.md §八](docs/DESIGN.md) 流程实查锁定（已锁定：opencode-ai=1.18.18）
- 🚧 其它平台待实现
