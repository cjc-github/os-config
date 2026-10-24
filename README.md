# os-config

声明式的开发环境初始化脚本：用**清单（profile）**选择要装什么，用**五动词**驱动软件与配置的完整生命周期。

```text
选择清单  →  依赖闭包  →  install / update / remove / verify / status
```

> 当前实现的引擎：**Ubuntu 22.04 / 24.04**（amd64 与 arm64 自动区分镜像源）
> 与 **Windows 10/11**（PowerShell 5.1+，`setup.ps1`）。
> 两个引擎共用同一份 `catalog/` 与 `profiles/` 数据，平台差异只体现在后端与动作实现里。

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
- 字段值支持 `$VAR`、`${VAR}`、`${VAR:-默认值}` 展开（`desc` / `group` 是文案，不展开），例如 `packages=${CLAUDE_CODE_PKG:-@anthropic-ai/claude-code}`。

字段校验在 `catalog_validate` 中完成：非法 id、未知字段、重复字段、非法的 backend/track、缺失的 packages/action、指向不存在工具的 `deps`，都会在加载阶段直接报错。

### 2. profile —— 声明“要什么”

`profiles/*.conf` 是一份选择清单，可以继承：

```ini
[default]
desc=默认环境
extends=minimal
tools=@archive, @transfer, proxy, nodejs, @ai, syslog, nosuspend
```

- `tools` 支持三种写法：工具 id、`@分组`、`后端:包`（内联注册，无需改 catalog）。内联 id 的规则（包名转小写、非法字符换 `-`、去掉首尾 `-`）在 CLI、引擎与 Web UI 三处保持一致。
- `extends` 会先并入父清单的全部工具，再追加自己的（按顺序去重）。
- 内置四份清单：`minimal` → `default` → `dev` 逐层扩展，`ai` 单独一套。

### 3. 七动词 —— 声明“做什么”

| 动词 | 语义 | 顺序 | 读写 |
|---|---|---|---|
| `install` | 安装/应用（已装即跳过，幂等） | 依赖闭包，依赖优先 | 写 |
| `update` | 更新到目标版本（配置类等价 install） | 依赖优先 | 写 |
| `remove` | 卸载/还原配置 | **逆序**，被依赖者先删 | 写 |
| `verify` | 校验，不修改；`--fix` 时未通过会自动 apply 后复验 | 依赖优先 | 读（`--fix` 为写） |
| `status` | 展示当前状态 | 依赖优先 | 读 |
| `export` | 扫描本机已装包与已应用配置，导出为 profile | 不需要选择 | 读 |
| `doctor` | 环境体检（sudo/磁盘/apt 锁/网络/清单一致性） | 不需要选择 | 读 |

`type=config` 的动作按约定实现 `action_<名字>_apply|remove|verify|status` 四个动词（status 只读，输出一行摘要；缺失时才回退为通用状态输出）。

写动词会取 `state/.lock` 独占锁，避免两个运行互相踩清单快照；残留锁（持有者已退出）会被自动清理。

## 命令行参数

| 参数 | 说明 |
|---|---|
| `--profile <名>` | 使用 `profiles/` 中的清单 |
| `--pick <a,b,@组,apt:jq>` | 临时指定选择 |
| `--all` | 选择 catalog 中全部工具 |
| `--list` | 列出 catalog 与 profile，然后退出 |
| `--json` | 与 `--list` 连用，输出 JSON（供 Web UI 读取） |
| `--dry-run` | 只打印计划，不写盘 |
| `--force` | 忽略幂等判断，强制重做 |
| `--fix` | 与 `verify` 连用：校验未通过时自动 apply 修复后复验 |
| `--keep-going` | 单项失败不中断，跑完再汇总 |
| `--no-sudo` | 跳过需要提权的项 |
| `--yes` | 非交互确认（自动回答 y） |
| `--output <路径>` | 与 `export` 连用，指定导出的 profile 路径 |
| `--debug` | 调试日志 |

`--profile`、`--pick`、`--all` **三选一**，同时给出会报错（退出码 2）。不加选择时默认 `--profile default`；`export` 与 `doctor` 不需要选择。`--fix` 只能配 `verify`，`--output` 只能配 `export`，用错组合同样报错退出 2。

## 换机器复刻

```bash
# 旧机器
./setup.sh export                        # → profiles/exported.conf
# 把 config/user.env 与 profiles/exported.conf 拷到新机器（参数按导出注释核对）

# 新机器
./setup.sh doctor                        # 先体检，确认 sudo/磁盘/网络都正常
./setup.sh install --profile exported    # 按导出清单安装
./setup.sh verify --fix --profile exported   # 兜底：校验并自动修复偏差
```

`export` 会扫描 catalog，把实际已安装的 package 与清单里已记录的 config 写成一份 profile（默认 `profiles/exported.conf`，已 gitignore）；生效参数写在文件末尾的注释里，供新机器核对 `config/user.env`。

## 重要默认值

配置写在 `config/user.env`（从 `config/user.env.example` 复制）；`config/versions.env` 放版本与 npm 源默认值。模板里列出的每个键都真的会被引擎读取。

- `MIRROR_APT_URL` / `MIRROR_APT_PORTS_URL`：默认清华 TUNA；amd64 用前者，arm64/riscv64 等用 `-ports`。换源前会把原文件持久备份到 `state/actions/mirrors/`，因此 `remove mirrors` 可跨运行还原。
- `MIRROR_SKIP_APT=true`：不改写 APT 源（公司内网等已自备源的环境用）。
- `MIRROR_SKIP_APT_UPDATE=true`：不执行 `apt update`（完全离线环境）。
- `APT_UPGRADE=true`：换源并 `apt update` 之后追加一次系统全量 `apt-get upgrade`；跳过 `apt update` 时不执行。
- `PROXY_ENABLED=true`：默认写入 shell 与 Git 代理。`PROXY_HOST` 留空时取当前 IPv4 并把最后一段替换为 `1`，`PROXY_PORT` 留空时用 `7890`。写入前 ping 代理主机，验证阶段用 `curl -x` 真实访问 `PROXY_TEST_URL`（默认 `https://github.com`），超时取 `PROXY_CONNECT_TIMEOUT`（默认 5s）与 `PROXY_MAX_TIME`（默认 15s）。`NO_PROXY` 默认 `localhost,127.0.0.1,::1`。
- `GIT_USER_NAME` / `GIT_USER_EMAIL`：任一为空则跳过对应项并给出 `git config --global` 提示；`verify` 阶段会校验这两项是否与期望一致。
- `SSH_KEY_TYPE=ed25519`：默认非交互生成 ed25519 密钥。SSH **服务端**不由本文件控制——`openssh-server` 是 catalog 条目，用 `--pick openssh-server` 或写进 profile 启用（旧配置里的 `SSH_INSTALL_SERVER` 已废弃，加载时会提示）。
- `NODE_VERSION=`：留空时装 `NODE_LTS_MAJOR` 下的最新版本，填写完整版本则精确锁定。`NVM_VERSION` 指定 nvm 自身版本，`NPM_REGISTRY` 指定 npm 源。
- `CLAUDE_CODE_PKG` / `CLAUDE_CODE_VERSION`：Claude Code 的 npm 包名与锁定版本；`CODEX_PKG` / `CODEX_VERSION` 与 `OPENCODE_PKG` / `OPENCODE_VERSION` 同理。默认值写在 `config/versions.env`，要临时换版本可在 Web UI 的对应工具参数里改。
- `JOURNALD_MAX_USE=200M`：journald 持久化上限。

## 安全性与失败处理

- 需要 sudo 时优先 `sudo -n`，交互终端则 `sudo -v`；非交互环境需预先准备凭据，或用 `--no-sudo` 跳过。
- 受管文件改写前 `register_rollback`：原文件存在则备份、不存在则记录为新建；失败时统一回滚，临时文件一并清理。
- 每个配置动作都满足 apply/remove 对称：apply 改了系统设置或用户配置（gsettings、npm config）会先记录原值，remove 按原值还原；apply 建的每个产物 verify 都会检查；没法完全还原时如实报 skipped 而不是成功。
- 每次运行有独立日志，目录/文件权限收紧为 `700/600`，token、密码、Bearer Authorization、URL 凭据在落盘前脱敏。
- apt/dpkg 操作前 `wait_for_apt_lock`；重试由 `with_retry` 统一处理。
- npm 全局安装失败且输出含 `ENOTEMPTY` 时，只清理 `.<package>-*` 隐藏 rename 残留并重试一次，不动正式包目录。
- `--keep-going` 时单项失败不触发回滚、最终仍返回非零；否则首个失败即回滚。
- 写动词（含 `verify --fix`）取 `state/.lock` 独占锁：并发运行会直接报错而不是互相覆盖清单；残留锁按 pid 探测后自动清理，只释放自己持有的锁。
- `doctor` 是纯只读体检，不改任何东西；它会把"清单记录的产物已消失"判为需关注并提示用 `verify --fix` 收敛。

## Web UI

`ui.sh` 在本机启动一个只监听 `127.0.0.1` 的网页界面：勾选工具、修改参数、预览计划，并查看逐行日志与每项结果。

```bash
./ui.sh                       # 启动并自动打开浏览器
./ui.sh --no-open --port 8765 # 只打印地址，指定端口
./ui.sh --help
```

- 依赖 `python3` >= 3.10（启动时校验版本），只用标准库；`--host` 仅接受 `127.0.0.1` 或 `localhost`。
- 顶栏「执行动词」下拉框覆盖引擎五个**与选择相关**的动词：安装 / 更新 / 卸载 / 校验 / 状态；选「卸载」会先弹确认框。工具面板里的「卸载所选」仍按已安装清单逐项确认。`export` 与 `doctor` 不需要选择，目前只在命令行提供。
- 「预览计划」按当前动词生成依赖闭包计划；只读动词（校验/状态）没有 dry-run 短路，预览一律改用安装动词生成，不会真的去跑校验。
- 首次启动若需要 sudo，会先执行 `sudo -v` 预授权，之后每 50 秒刷新凭据；授权失败只让需要提权的动作不可用，不影响页面启动。
- 每次启动生成一次性 token，终端打印 `http://127.0.0.1:<port>/?token=...`；未带 token 的请求一律返回 401。
- 页面修改的参数写入 `config/ui.env`（权限 0600），优先级高于 `config/user.env`，不会覆盖 `user.env`；口令类字段不回显明文。字段旁的“恢复默认”会清除该项覆盖，删除 `config/ui.env` 可整体还原。
- 参数面板按所选工具分组，覆盖 `config/user.env` 与 `config/versions.env` 里所有会被引擎读取的键（镜像源与换源开关、代理与超时、Git 身份、SSH 密钥、journald 限容、Node/nvm/npm、AI CLI 的包名与版本）。
- 运行记录在 `state/ui/runs/<run_id>/`（`run.log`、`events.jsonl`、`meta.json`），服务日志在 `state/ui/server.log`；这些路径均被 `.gitignore` 忽略。
- 安全边界：只绑定本机回环地址，无远程访问；token 经环境变量传给服务，不出现在进程参数中。

## 目录结构

```text
setup.sh                 唯一入口（七动词）
setup.ps1                Windows 引擎入口（动词与选择参数同 setup.sh）
ui.sh                    Web UI 启动器（Linux，本机回环 + 一次性 token）
ui.ps1                   Web UI 启动器（Windows 原生）
ui/                      Web UI 服务与静态资源（Python 标准库）
  server.py              HTTP/SSE 服务、运行编排（按平台选 setup.sh/setup.ps1）
  schema.py              参数白名单、adhoc id、路径与文件名校验
  static/                index.html / app.js / style.css
catalog/                 声明式数据层：base.catalog、config.catalog
profiles/                选择清单：minimal/default/dev/ai（exported.conf 由 export 生成，gitignore）
engine/
  lib/catalog.sh         目录加载与校验
  lib/profile.sh         清单解析、继承、tokens 解析
  lib/graph.sh           依赖闭包与拓扑/逆序
  lib/backends.sh        后端适配器（apt/npm/snap）
  lib/engine.sh          七动词编排器
  lib/doctor.sh          doctor 动词：环境体检
  lib/export.sh          export 动词：扫描本机状态导出 profile
  lib/events.sh          结构化事件（JSONL，供 Web UI 实时日志）
  lib/list_json.sh       catalog/profile 的 JSON 序列化
  lib/state.sh           state/manifest.conf 清单读写 + 并发锁
  lib/rollback.sh        备份/回滚/临时文件
  lib/log.sh             终端 + 文件日志（脱敏）
  lib/util.sh            配置加载、步骤、重试、sudo、代理、nvm
  actions/*.sh           配置动作：mirrors/proxy/git/ssh/syslog/nosuspend/nodejs
  lib-win/*.ps1          Windows 引擎库（上面 lib/*.sh 的逐函数移植）
  actions-win/*.ps1      Windows 配置动作：proxy/git/ssh/nodejs
state/                   运行时状态（manifest + 每动作持久备份 + .lock）
tests/run.sh             不依赖 Bats 的回归测试（含 Windows 引擎用例，有 PowerShell 才跑）
.github/workflows/ci.yml  CI：ubuntu 全套，windows 跑 Windows 引擎用例
docs/DESIGN.md           详细设计
docs/FEATURES.md         功能清单（当前已支持的能力，按平台标注）
logs/                    运行时日志（.gitignore 忽略）
```

catalog 条目用 `platforms=linux|win|linux,win` 标注适用平台，并用 `win_backend` /
`win_packages` / `win_commands` / `win_artifacts` 描述 Windows 侧的差异
（例如 `[dnsutils]` 在 Linux 上装 `dnsutils` 验 `dig`，在 Windows 上验 `nslookup`）。
未声明 `platforms` 的条目只在 Linux 生效，Windows 引擎会打印"不适用于当前平台"后跳过。

## 自测

```bash
./tests/run.sh            # Bash 回归用例，断言 catalog/profile/graph/state/rollback/后端/引擎/动作/并发锁/export/doctor/Web UI
./tests/run.sh graph      # 只跑显示名或用例函数名里含 graph 的用例
python3 -m unittest discover -s tests -p 'test_*.py' -v   # Web UI 服务端用例
node --test tests/test_app_js.js                          # 前端用例
```

过滤条件匹配不到任何用例时返回非零，不会出现“跑了 0 个用例却显示通过”。

Windows 引擎同样有回归覆盖：`export 产物可被 profile 解析器读回`、
`export 产物不破坏同目录其它 profile`、`Windows 导出的 profile 可读回`、
`Windows 命令探测不把别名当已安装`、`Windows list --json 的 artifacts 展开`、
`Windows rollback 事件带 restored 列表`、`Windows catalog 缺 win_backend 报错可读`、
`Windows config 动作真的被分派`、`Windows 空口令下 ssh-keygen 可用`、
`Windows 原生调用保留空参数`、`Windows winget 安装真的传参数`、
`Windows winget 索引按表头解析`、`Windows npm ENOTEMPTY 重试`、
`Windows proxy 动作全生命周期`、`Windows git 动作全生命周期`、
`Windows nodejs 动作全生命周期`、`Windows 非交互提权明确报错`。
上述用例在环境里找不到 `powershell`/`pwsh` 时自动记为跳过（仍留一条通过断言，
避免零断言被误判成失败）；winget / npm 两个安装后端用 `global:winget.exe` /
`global:npm` 函数遮蔽外部命令来记录真实入参，不真的装任何软件。
Bash 侧对应新增 `内联条目不被平台门跳过`（--pick backend:pkg 的临时条目曾被
平台门静默跳过，两个引擎同病）。

少数 Bash 用例断言 POSIX 权限位（600/700）、依赖符号链接或需要原生
python3/node，在 Windows 的 Git Bash 上必然失败——那是环境差异而非缺陷，
套件会按平台把它们记为 `skip` 并在总计里单独计数，不会染红。

CI（`.github/workflows/ci.yml`）：ubuntu 跑全套 + Web UI 服务端 + 前端；
windows 跑 Windows 引擎用例。

测试全部在临时目录中进行：`HOME`、`STATE_DIR`、`PATH` 都被重定向，`apt-get`/`snap`/`npm`/`sudo`/`fuser`/`ping`/`ip` 均为 fake，不会改动宿主机 `/etc`。

真实 APT、systemd、网络下载仍建议在干净的 Ubuntu 22.04 / 24.04 虚拟机或容器中做一次集成验证。
