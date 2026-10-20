# os-config

声明式的开发环境初始化脚本：用**清单（profile）**选择要装什么，用**五动词**驱动软件与配置的完整生命周期。

```text
选择清单  →  依赖闭包  →  install / update / remove / verify / status
```

> 当前实现的引擎：**Ubuntu 22.04 / 24.04**（amd64 与 arm64 自动区分镜像源）。
> Windows 的 PowerShell 引擎尚未实现，`lib-win/` 与 `setup.ps1` 仍在规划中。

## 快速开始

```bash
cp config/user.env.example config/user.env   # 可选：本机参数
./setup.sh --list                            # 看 catalog 工具与可用 profile
./setup.sh --dry-run                         # 默认 profile=default，只打印计划
./setup.sh install --profile minimal         # 真正安装
```

定向执行：

```bash
./setup.sh install --pick git,ssh,proxy      # 临时指定，不用 profile
./setup.sh install --pick @archive,apt:jq    # 支持 @分组 与 后端:包 内联
./setup.sh verify  --profile dev
./setup.sh remove  --pick apt:jq
./setup.sh status  --pick nodejs,claude
./tests/run.sh                               # 回归测试
```

## 三个概念

### 1. catalog —— 声明“有什么”

`catalog/*.catalog` 是纯数据文件（INI 分组 + `key=value`），描述每个工具是什么、由谁安装、依赖谁。引擎不认识任何具体工具名，只读这份数据。

```ini
[cmake]
type=package
backend=apt
packages=cmake
commands=cmake
group=development
desc=CMake 构建工具

[git]
type=config
action=git
deps=git-cli
artifacts=$HOME/.gitconfig
group=config
desc=配置 git 身份与代理
```

- `type=package`：交给后端适配器（`apt` / `npm` / `snap`）。
- `type=config`：交给配置动作脚本（`action=<名字>` → `engine/actions/<名字>.sh`），并用 `artifacts` 声明它写出的文件，供 `status` 与 `remove` 使用。

字段校验在 `catalog_validate` 中完成：非法 id、未知字段、重复字段、非法的 backend/track、缺失的 packages/action、指向不存在工具的 `deps`，都会在加载阶段直接报错。

### 2. profile —— 声明“要什么”

`profiles/*.conf` 是一份选择清单，可以继承：

```ini
[default]
desc=默认环境
extends=minimal
tools=@archive, @transfer, proxy, nodejs, @ai, syslog, nosuspend
```

- `tools` 支持三种写法：工具 id、`@分组`、`后端:包`（内联注册，无需改 catalog）。
- `extends` 会先并入父清单的全部工具，再追加自己的（按顺序去重）。
- 内置四份清单：`minimal` → `default` → `dev` 逐层扩展，`ai` 单独一套。

### 3. 五动词 —— 声明“做什么”

| 动词 | 语义 | 顺序 |
|---|---|---|
| `install` | 安装/应用（已装即跳过，幂等） | 依赖闭包，依赖优先 |
| `update` | 更新到目标版本 | 依赖优先 |
| `remove` | 卸载/还原配置 | **逆序**，被依赖者先删 |
| `verify` | 只校验，不修改 | 依赖优先 |
| `status` | 展示当前状态 | 依赖优先 |

`type=config` 的动作按约定实现 `action_<名字>_apply|remove|verify`（另有可选的 `_status`，缺失时回退为通用状态输出）。

## 命令行参数

| 参数 | 说明 |
|---|---|
| `--profile <名>` | 使用 `profiles/` 中的清单 |
| `--pick <a,b,@组,apt:jq>` | 临时指定选择 |
| `--all` | 选择 catalog 中全部工具 |
| `--list` | 列出 catalog 与 profile，然后退出 |
| `--dry-run` | 只打印计划，不写盘 |
| `--force` | 忽略幂等判断，强制重做 |
| `--keep-going` | 单项失败不中断，跑完再汇总 |
| `--no-sudo` | 跳过需要提权的项 |
| `--debug` | 调试日志 |

`--profile`、`--pick`、`--all` **三选一**，同时给出会报错（退出码 2）。不加选择时默认 `--profile default`。

## 重要默认值

- `MIRROR_APT_URL` / `MIRROR_APT_PORTS_URL`：默认清华 TUNA；amd64 用前者，arm64/riscv64 等用 `-ports`。换源前会把原文件持久备份到 `state/actions/mirrors/`，因此 `remove mirrors` 可跨运行还原。
- `PROXY_ENABLED=true`：默认写入 shell 与 Git 代理。`PROXY_HOST` 留空时取当前 IPv4 并把最后一段替换为 `1`，`PROXY_PORT` 留空时用 `7890`。写入前 ping 代理主机，验证阶段用 `curl -x` 真实访问 `PROXY_TEST_URL`。
- `GIT_USER_NAME` / `GIT_USER_EMAIL`：任一为空则跳过对应项并给出 `git config --global` 提示。
- `SSH_INSTALL_SERVER=false`：默认只装客户端；`SSH_KEY_TYPE=ed25519`。
- `NODE_VERSION=`：留空时装 `NODE_LTS_MAJOR` 下的最新版本，填写完整版本则精确锁定。
- `JOURNALD_MAX_USE=200M`：journald 持久化上限。

## 安全性与失败处理

- 需要 sudo 时优先 `sudo -n`，交互终端则 `sudo -v`；非交互环境需预先准备凭据，或用 `--no-sudo` 跳过。
- 受管文件改写前 `register_rollback`：原文件存在则备份、不存在则记录为新建；失败时统一回滚，临时文件一并清理。
- 每次运行有独立日志，目录/文件权限收紧为 `700/600`，token、密码、Bearer Authorization、URL 凭据在落盘前脱敏。
- apt/dpkg 操作前 `wait_for_apt_lock`；重试由 `with_retry` 统一处理。
- npm 全局安装失败且输出含 `ENOTEMPTY` 时，只清理 `.<package>-*` 隐藏 rename 残留并重试一次，不动正式包目录。
- `--keep-going` 时单项失败不触发回滚、最终仍返回非零；否则首个失败即回滚。

## Web UI

`ui.sh` 在本机启动一个只监听 `127.0.0.1` 的网页界面：勾选工具、修改参数、预览计划，并查看逐行日志与每项结果。

```bash
./ui.sh                       # 启动并自动打开浏览器
./ui.sh --no-open --port 8765 # 只打印地址，指定端口
./ui.sh --help
```

- 依赖 `python3` >= 3.10，只用标准库；`--host` 仅接受 `127.0.0.1` 或 `localhost`。
- 首次启动若需要 sudo，会先执行 `sudo -v` 预授权，之后每 50 秒刷新凭据；授权失败只让需要提权的动作不可用，不影响页面启动。
- 每次启动生成一次性 token，终端打印 `http://127.0.0.1:<port>/?token=...`；未带 token 的请求一律返回 401。
- 页面修改的参数写入 `config/ui.env`（权限 0600），优先级高于 `config/user.env`，不会覆盖 `user.env`；口令类字段不回显明文。字段旁的“恢复默认”会清除该项覆盖，删除 `config/ui.env` 可整体还原。
- 运行记录在 `state/ui/runs/<run_id>/`（`run.log`、`events.jsonl`、`meta.json`），服务日志在 `state/ui/server.log`；这些路径均被 `.gitignore` 忽略。
- 安全边界：只绑定本机回环地址，无远程访问；token 经环境变量传给服务，不出现在进程参数中。

## 目录结构

```text
setup.sh                 唯一入口（五动词）
ui.sh                    Web UI 启动器（本机回环 + 一次性 token）
ui/                      Web UI 服务与静态资源（Python 标准库）
  server.py              HTTP/SSE 服务、运行编排
  schema.py              参数白名单、adhoc id、路径与文件名校验
  static/                index.html / app.js / style.css
catalog/                 声明式数据层：base.catalog、config.catalog
profiles/                选择清单：minimal/default/dev/ai
engine/
  lib/catalog.sh         目录加载与校验
  lib/profile.sh         清单解析、继承、tokens 解析
  lib/graph.sh           依赖闭包与拓扑/逆序
  lib/backends.sh        后端适配器（apt/npm/snap）
  lib/engine.sh          五动词编排器
  lib/state.sh           state/manifest.conf 清单读写
  lib/rollback.sh        备份/回滚/临时文件
  lib/log.sh             终端 + 文件日志（脱敏）
  lib/util.sh            配置加载、步骤、重试、sudo、代理、nvm
  actions/*.sh           配置动作：mirrors/proxy/git/ssh/syslog/nosuspend/nodejs
state/                   运行时状态（manifest + 每动作持久备份）
tests/run.sh             不依赖 Bats 的回归测试
docs/DESIGN.md           详细设计
logs/                    运行时日志（.gitignore 忽略）
```

## 自测

```bash
./tests/run.sh            # 45 个用例，断言 catalog/profile/graph/state/rollback/后端/引擎/动作
./tests/run.sh graph      # 只跑名字匹配的用例
```

测试全部在临时目录中进行：`HOME`、`STATE_DIR`、`PATH` 都被重定向，`apt-get`/`snap`/`npm`/`sudo`/`fuser`/`ping`/`ip` 均为 fake，不会改动宿主机 `/etc`。

真实 APT、systemd、网络下载仍建议在干净的 Ubuntu 22.04 / 24.04 虚拟机或容器中做一次集成验证。
