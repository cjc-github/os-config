# os-config

按操作系统族组织的模块化开发环境初始化脚本：平台识别 → 依赖排序 → 安装 → 验证 → 汇总。

> 当前实际支持：**Ubuntu 22.04 / 24.04（统一使用 `ubuntu`）**。`windows`、`macos`、`kylin` 为操作系统族占位目录，尚未实现模块；即使通过 `--platform` 强制选择也会明确失败。CPU 架构（如 amd64、arm64）单独识别，不再作为 `platforms/` 下的平台类别。

## 快速开始

```bash
cp config/user.env.example config/user.env   # 可选：按需修改
./setup.sh --platform ubuntu --list
./setup.sh --platform ubuntu --all --dry-run
./setup.sh                                   # Ubuntu 22.04/24.04 上自动识别为 ubuntu
```

常用的定向执行方式：

```bash
./setup.sh --module nodejs,claude
./setup.sh --module proxy --force
./setup.sh --verify-only --module git,ssh
./tests/run.sh
```

## 平台分类

`platforms/` 的一级目录按**操作系统族**划分，而不是按发行版版本或 CPU 架构划分：

- Ubuntu 22.04 和 24.04 都映射到 `platforms/ubuntu/`；
- Windows、macOS、麒麟分别使用 `platforms/windows/`、`platforms/macos/`、`platforms/kylin/`；
- amd64、arm64 等 CPU 架构记录在 `SYSTEM_ARCH`，由各模块在确有差异时自行选择实现。

## 重要默认值

- `APT_UPGRADE=false`：默认只执行 `apt update` 和安装所需包，不做全系统升级。
- `GIT_USER_NAME`/`GIT_USER_EMAIL`：任一值留空时，不修改对应的 Git 全局身份配置，并在 warning 中给出 `git config --global user.name "你的姓名"` 或 `git config --global user.email "your-email@example.com"` 命令。
- `PROXY_ENABLED=true`：默认写入 shell 和 Git 代理配置；`PROXY_HOST` 留空时取当前 IPv4 并只把最后一段替换为 `1`，`PROXY_PORT` 留空时使用 `7890`。写入前会 ping 代理主机；验证阶段还会执行 `curl -x <代理地址> https://github.com`，真实检查代理端口、HTTPS CONNECT 和外网访问。失败时打印网卡/IP、路由、防火墙和代理端口排查说明。设置 `PROXY_ENABLED=false` 可显式关闭。
- `SSH_INSTALL_SERVER=false`：默认只安装 SSH 客户端，不安装 `openssh-server`。
- `NODE_VERSION=`：留空时安装 `NODE_LTS_MAJOR` 指定主版本下的最新远端版本；填写完整版本可精确锁定。
- `MIRROR_SKIP_APT=false`：默认会配置 Ubuntu APT 镜像；不希望改源时请显式设为 `true`。

## 命令行参数

| 参数 | 说明 |
|---|---|
| `--module a,b` | 只跑指定模块，并自动补齐依赖 |
| `--all` | 按稳定的模块顺序跑全部模块 |
| `--list` | 显示 NAME、目录、依赖、sudo 和描述 |
| `--dry-run` | 只打印计划，不执行模块脚本 |
| `--install-only` | 只安装，不验证 |
| `--verify-only` | 只验证，不安装 |
| `--force` | 强制重装或重写受管配置 |
| `--keep-going` | 模块失败后继续跑无关模块；最终仍返回非零 |
| `--no-sudo` | 跳过 `NEEDS_SUDO=1` 模块，其下游依赖模块会标记 blocked |
| `--platform ubuntu` | 强制选择操作系统族，主要用于测试 |
| `--debug` | 打开调试日志 |

`--install-only` 与 `--verify-only`、`--all` 与 `--module` 不能同时使用。

## 模块清单

模块目录使用分类前缀：`sys-` 表示系统类、`net-` 表示网络类、`rt-` 表示运行环境类、`ai-` 表示 AI 工具类。前缀只用于整理目录，不属于模块名；执行模块时应使用 `module.conf` 中的 `NAME`。例如 `rt-log` 的实际模块名是 `log`，应执行：

```bash
./setup.sh --module log
```

| NAME | 目录 | 依赖 | sudo | 作用 |
|---|---|---|---:|---|
| `mirrors` | `sys-mirrors` | — | 1 | 配置 Ubuntu deb822/legacy APT 镜像并验证 |
| `base` | `sys-base` | mirrors | 1 | apt update、可选 upgrade、安装基础工具（含 ping） |
| `git` | `net-git` | base | 1 | 安装 Git；空身份 warning 后跳过；代理推导、ping，并用 curl 验证 GitHub 访问 |
| `ssh` | `net-ssh` | base | 1 | 安装客户端、生成密钥；服务端为可选项 |
| `proxy` | `net-proxy` | base | 0 | 推导并 ping 代理主机，写入代理变量并用 curl 验证 GitHub 访问 |
| `nodejs` | `rt-nodejs` | base | 0 | 安装 nvm 和指定 Node 主版本/完整版本 |
| `log` | `rt-log` | base | 1 | 安装日志工具，持久化并限容 journald，校验 logrotate，添加 `oslogs` 别名 |
| `screen` | `rt-screen` | base | 0 | 配置并验证 GNOME 或 X11 的息屏/锁屏策略 |
| `claude` | `ai-claude` | nodejs | 0 | 安装固定版本 Claude Code CLI |
| `codex` | `ai-codex` | nodejs | 0 | 安装固定版本 Codex CLI |
| `opencode` | `ai-opencode` | nodejs | 0 | 安装固定版本 OpenCode CLI |

依赖关系：

```text
mirrors → base ─┬─ git
                ├─ ssh
                ├─ proxy
                ├─ nodejs ─┬─ claude
                │          ├─ codex
                │          └─ opencode
                ├─ log
                └─ screen
```

## 安全性与失败处理

- 需要 sudo 时，交互终端会执行 `sudo -v`；非交互环境需预先准备 sudo 凭据。
- 受管文件修改前会注册回滚：原文件存在则备份，原文件不存在则在失败时删除新建文件。
- 系统文件使用 sudo 模式备份和恢复；本次备份清单会写入运行日志旁的 manifest。
- 日志目录/文件权限尽量收紧为 `700/600`，token、密码、Bearer Authorization 和 URL 凭据会在落盘前脱敏。
- npm 全局安装首次正常执行；只有确认错误包含 `ENOTEMPTY` 时，才删除 npm 的隐藏 rename 残留并重试，不删除正式包目录。
- `--keep-going` 只允许无关模块继续；依赖失败的模块会 blocked，整个命令最终返回非零。

## 目录结构

```text
setup.sh                 唯一入口
config/                  模块清单、版本与用户配置
lib/                     日志、平台识别、runner、公共工具
platforms/ubuntu/        Ubuntu 22.04/24.04 共用的 11 个模块
platforms/windows/       Windows 占位目录
platforms/macos/         macOS 占位目录
platforms/kylin/         麒麟操作系统占位目录
tests/run.sh             不依赖 Bats 的快速回归测试
docs/DESIGN.md           详细设计
logs/                    运行时日志（已被 .gitignore 忽略）
```

## 自测

```bash
./tests/run.sh
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
./setup.sh --platform ubuntu --all --dry-run
```

自动测试覆盖参数冲突、Ubuntu 22.04/24.04 到 `ubuntu` 的映射、CPU 架构独立识别、拓扑/blocked 状态、keep-going 返回码、元数据重名、日志脱敏、用户与 fake-sudo 回滚、npm `ENOTEMPTY` 修复，Git 空身份 warning，以及代理地址自动推导、默认端口、ping 连通性、`curl -x` 访问 GitHub、失败诊断和安全写入。
