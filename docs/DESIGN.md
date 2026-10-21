# os-config 项目设计

> 状态：v7.1（2026-10-21）。架构从“平台 + 模块三件套”重构为“声明式 catalog + 无状态引擎 + 七动词”。
> 当前实现 Ubuntu 22.04/24.04 的 Bash 引擎；Windows PowerShell 引擎待实现。本文以仓库现有代码为准。

## 一、目标和边界

`os-config` 用一个入口完成开发环境的安装与配置：

1. 选定一份**清单**（profile，或 `--pick` / `--all`；`export`/`doctor` 不需要选择）。
2. 展开**依赖闭包**并拓扑排序。
3. 对每一项分派到**后端适配器**（package）或**配置动作**（config）。
4. 执行七动词之一：`install` / `update` / `remove` / `verify` / `status` / `export` / `doctor`。
5. 汇总成功、跳过、失败，并在失败时回滚本次写操作。

设计目标：新增一个工具**只改数据**（`catalog/*.catalog`）或**只加一个动作脚本**，不需要动引擎。

### 与旧架构的差异（v6 → v7）

| 维度 | v6 | v7 |
|---|---|---|
| 平台 | `platforms/<族>/` 目录 + `detect.sh` | 单引擎，架构差异下沉到后端/动作内部 |
| 工具描述 | 每模块 `module.conf` + `install.sh` + `verify.sh` | `catalog/*.catalog` 数据文件 |
| 选择 | `config/base-tools.conf` + `--module` | `profiles/*.conf` + `--pick`/`--all` |
| 动词 | `install` / `verify` 两种 | `install`/`update`/`remove`/`verify`/`status`/`export`/`doctor` 七种 |
| 后端 | 各模块自己写 apt/npm 命令 | 统一适配器 `apt`/`npm`/`snap` |
| 状态 | 一次性 `.backups` manifest | `state/manifest.conf` + 每动作持久备份 + `.lock` 并发锁 |

## 二、目录结构

```text
setup.sh                    入口：解析动词与选择 → engine_run / doctor_run / export_run
ui.sh                       Web UI 启动器（本机回环 + 一次性 token）
ui/                         Web UI 服务（Python 标准库）与静态资源
catalog/
  base.catalog              系统与工具类的 package/config 条目
  config.catalog            配置类条目
profiles/
  minimal.conf  default.conf  dev.conf  ai.conf     # 仓库自带
  exported.conf             export 动词的默认产物（gitignore）
engine/
  lib/log.sh                终端+文件日志、脱敏、权限
  lib/util.sh               配置加载、run_step、重试、sudo、apt 锁、代理推导、nvm
  lib/rollback.sh           备份/回滚/trap/临时文件
  lib/state.sh              manifest、state/actions/<name>/、并发锁 .lock
  lib/catalog.sh            catalog 解析、校验、变量/artifacts 展开、内联注册
  lib/profile.sh            profile 解析、继承、tokens 解析、resolve
  lib/graph.sh              依赖闭包、拓扑排序、逆序、dependents
  lib/backends.sh           apt / npm / snap 适配器
  lib/engine.sh             七动词编排器（含 verify --fix）
  lib/doctor.sh             doctor 动词：环境体检
  lib/export.sh             export 动词：扫描本机状态导出 profile
  lib/events.sh             结构化事件（JSONL，供 Web UI 实时日志）
  lib/list_json.sh          catalog/profile 的 JSON 序列化
  actions/
    mirrors.sh proxy.sh git.sh ssh.sh syslog.sh nosuspend.sh nodejs.sh
state/
  manifest.conf             已记录工具的产物清单
  actions/<name>/           跨运行的持久备份（如 mirrors 的原源文件）
  .lock                     写运行独占锁（pid 文件）
tests/run.sh                回归测试
docs/DESIGN.md              本文
```

## 三、数据层：catalog

### 条目类型

`type=package`——由包管理器安装：

```ini
[cmake]
type=package
backend=apt              # apt | npm | snap
packages=cmake           # 空格分隔
commands=cmake           # verify 时须可用的命令
track=latest             # latest | pin
version=                 # track=pin 时的精确版本
deps=                    # 空格分隔的工具 id
group=development
desc=CMake 构建工具
```

`type=config`——由动作脚本配置：

```ini
[git]
type=config
action=git               # engine/actions/git.sh
deps=git-cli
artifacts=$HOME/.gitconfig   # 每行一个；支持 $VAR 展开
group=config
desc=配置 git 身份与代理
```

### 通用字段

| 字段 | 适用 | 说明 |
|---|---|---|
| `type` | 必填 | `package` / `config` |
| `backend` | package | `apt` / `npm` / `snap`，须在 `BACKEND_SUPPORTED` 中 |
| `packages` | package | 非空 |
| `action` | config | 非空，对应 `engine/actions/<action>.sh` |
| `commands` | 选填 | verify 校验命令可用性 |
| `track` | 选填 | `latest`（默认）/ `pin` |
| `version` | 选填 | `track=pin` 时使用 |
| `deps` | 选填 | 空格分隔，必须指向已定义工具 |
| `artifacts` | 选填 | 空格分隔的产物路径，支持 `~` / `$VAR`；必须列全动作真正写出的文件，否则 `status` 与 Web UI 的产物清单会漏 |
| `group` | 选填 | `@组名` 展开依据；内联注册的为 `adhoc` |
| `desc` | 选填 | `--list` 展示 |
| `sudo` | 选填 | config 类是否需要提权（package 类由 backend 推断） |

### 校验规则（`catalog_validate`）

加载任一文件后立即校验，任一条不满足即加载失败：

- 分组头只能是 `[id]`，id 匹配 `^[a-z0-9][a-z0-9_-]*$`；
- 未知字段、重复字段、`key=value` 之外的裸行一律拒绝；
- `type` 必须是 `package` 或 `config`；
- `package`：`backend` 必须受支持（`apt`/`npm`/`snap`），`packages` 非空；
- `config`：`action` 非空；
- `track` 只能是 `latest` / `pin`；`track=pin` 时必须有 `version`；
- 所有 `deps` 必须能在最终 catalog 中找到。

`catalog_load <dir>` 按文件名排序加载目录下所有 `*.catalog`，最后统一校验。

### 变量与产物展开

- `catalog_expand_vars`：支持 `$VAR` / `${VAR}` / `${VAR:-默认值}`（未定义或为空时取默认值）；未定义变量展开为空，并保护位置参数 `$1`。`desc` / `group` 是文案字段，不做展开。
- `catalog_expand_artifacts <id>`：展开变量并把行首 `~` 换算为 `$HOME`，每行输出一个路径。artifacts **只在使用时展开一次**（catalog 加载时不展开），否则路径里再出现的 `$` 会被二次解释。

### 内联（adhoc）注册

`--pick apt:jq` 会调用 `catalog_define_adhoc <id> <backend> <packages> <commands> [desc]` 临时注册条目，`group=adhoc`、`track=latest`。已定义的同名 id 直接返回 0（幂等，不覆盖 catalog 定义）。

## 四、选择层：profile

```ini
[default]
desc=默认环境
extends=minimal
tools=@archive, @transfer, proxy, nodejs, @ai, syslog, nosuspend
```

- `tools` token 三种形态：工具 id；`@分组`；`后端:包`（内联注册）。
- 内联 id 的生成规则（`engine/lib/profile.sh`）：包名转小写 → 非 `[a-z0-9_-]` 字符换成 `-` → 去掉首尾所有 `-`。该规则必须与 `ui/schema.py` 的 `normalize_adhoc_id`、`ui/static/app.js` 的 `normalizeAdhocId` 完全一致，否则同一个 `--pick apt:xxx` 在 CLI 与 Web UI 会得到两个不同的 id。
- `extends` 先并入父清单全部工具，再追加自身（按顺序去重，父在前）。
- `profile_tokens <name>` 输出最终 token 流（每行一个，已展开 `extends`）。
- `profile_resolve <tokens...>` 输出最终工具 id 列表：id 直接保留，`@组` 展开为同组全部 id，`后端:包` 内联注册后保留。

内置清单规模（用于回归测试基准）：

| profile | 直接选择 | 解析后工具数 |
|---|---:|---:|
| minimal | mirrors, @core, git, ssh | 7 |
| ai | mirrors, @core, proxy, nodejs, @ai | 10 |
| default | extends minimal + @archive/@transfer/proxy/nodejs/@ai/syslog/nosuspend | 24 |
| dev | extends default + @development/@network/@system/@editor | 52 |

## 五、依赖图：graph

`graph_build <id...>` 做深度优先遍历，得到**依赖优先**的顺序（`GRAPH_ORDER`）。

- 对 `git-cli git ssh` → `git-cli git openssh-client ssh`。
- 对 `nodejs claude` → `ca-certificates curl nodejs claude`。

`graph_reverse` 原地反转 `GRAPH_ORDER`，用于 `remove`（被依赖者先删）：`claude nodejs curl ca-certificates`。

`graph_dependents <id>` 输出依赖该 id 的其它（已构建图内的）工具，例如对 `git` 输出 `git-cli`。

## 六、执行层：引擎

### 动词到动作的映射

| 动词 | package 类 | config 类 | 需要选择 |
|---|---|---|---|
| install | `_backend_<b>_install` | `action_<action>_apply` | 是 |
| update | `_backend_<b>_update` | `action_<action>_apply` | 是 |
| remove | `_backend_<b>_remove` | `action_<action>_remove` | 是 |
| verify | `_backend_<b>_verify` | `action_<action>_verify` | 是（`--fix` 时为写） |
| status | `_backend_<b>_status` | `action_<action>_status`（7 个动作都已实现；缺失时才回退通用输出） | 是 |
| export | 扫描 catalog 中实际已安装的条目，写成 profile | — | 否 |
| doctor | 环境体检（`engine/lib/doctor.sh`），不走 catalog 分派 | — | 否 |

动作脚本在首次使用时才 source（`_engine_source_action`），同一动作只加载一次。

### 编排流程

```text
engine_run <verb> <id...>
  ├─ 校验动词合法
  ├─ graph_build（remove 时再 graph_reverse）
  ├─ 逐项 engine_run_one
  │    ├─ --no-sudo 且需提权 → 返回 100（skipped）
  │    ├─ --dry-run 且是写动词 → 只打印
  │    ├─ verify 且 --fix → _engine_verify_or_fix
  │    │     ├─ 先 verify；通过/skipped 直接返回
  │    │     ├─ 未通过 → dispatch install（apply）→ 再 verify
  │    │     └─ 复验仍不过才判失败
  │    ├─ package → backend_dispatch
  │    └─ config  → action_dispatch + _engine_state_sync
  └─ 汇总：成功 / 跳过 / 失败；失败则返回 1
```

- 非 `--keep-going` 时首个失败即中断（由 trap 触发整体回滚）。
- `--keep-going` 时继续跑完，最终仍返回非零；引擎本身不触发回滚。
- 动作可以用返回码 `100` 表示「skipped」（例如 `nodejs` 卸载时用户拒绝、`syslog` 卸载时没有 sudo 权限），引擎会把它计入「跳过」而不是「成功」或「失败」。
- `--fix` 与 `--dry-run` 同时给出时不修复（dry-run 优先），setup.sh 会给出提示。

### remove 的依赖提示

`graph_dependents` 只看得到本次闭包内的依赖者，因此 remove 前额外扫一遍完整 catalog：

- 依赖本项、**且已经在选集里**的工具 → 提示「它们会先于本项删除」；
- 依赖本项、**不在选集里但已经安装**的工具（config 类查 `state/manifest.conf`，package 类问后端 `_backend_<b>_is_installed`）→ 提示「卸载后可能失效，如需一并卸载请一起选上」。

### Web UI 的动词映射

Web UI 走的是同一套引擎命令（`setup.sh <动词> --pick ...`），五个**与选择相关**的动词全部可达：

| UI | 命令 | 说明 |
|---|---|---|
| 安装 | `install` | 默认动词 |
| 更新 | `update` | package 升到候选版本，config 重新 apply |
| 卸载 | `remove` | 必须带确认，服务端拒绝没有 `confirm` 的请求 |
| 校验 | `verify` | 只读（UI 不提供 `--fix`） |
| 状态 | `status` | 只读，输出各工具当前状态 |

`export` 与 `doctor` 不需要选择，目前只在命令行提供（UI 的整个交互围绕选择展开，接入需要单独设计）。

「预览计划」走 `--dry-run`。引擎只对写动词（install/update/remove）做 dry-run 短路，只读动词会真的执行，因此预览接口统一用写动词生成计划，避免在预览时触发 `curl -x` 之类的副作用。

### 写操作预判

- `_engine_needs_sudo`：package 类的 `apt`/`snap` 视为需要提权；config 类看 `sudo=1`。
- `_engine_is_write_verb`：`install`/`update`/`remove` 是写动词。
- setup.sh 的 `_needs_write_lock`：`install`/`update`/`remove`，以及 `verify --fix`（非 dry-run）需要写锁。

## 七、后端适配器

`BACKEND_SUPPORTED=([apt]=1 [npm]=1 [snap]=1)`，与 `catalog_validate` 的判定必须保持一致。

- **apt**：`dpkg-query` 查状态与版本；install 跳过已装包，update 强制 `apt-get install` 以升级到候选版本；`track=pin` 时安装 `pkg=version`。apt 操作前 `require_sudo` + `wait_for_apt_lock`，并用 `with_retry`。
- **npm**：先 `activate_nvm_default`；`track=pin` 时校验版本一致；安装走 `npm_install_global_fixed`（失败含 `ENOTEMPTY` 时定向清理隐藏残留并重试一次）；安装后 `_npm_selfcheck` 要求命令真的可执行且有版本输出（npm 退出码 0 不等于可执行文件可用）。
- **snap**：install 只装缺失项；update 存在则 `snap refresh`，否则退回 install。

后端只读 `CAT_*` 数组，不认识任何具体工具名。新增后端 = 实现 `_backend_<name>_{install,update,remove,verify,status}` 并登记到 `BACKEND_SUPPORTED`。

## 八、状态层

`state/manifest.conf` 记录 config 类工具的产物清单；package 类不落清单，状态实时查询后端。

```text
state_record <id> <action> [artifact...]     # install/update 后写入
state_forget <id>                            # remove 后清除
state_has <id> / state_artifacts <id>
```

每次写运行开始 `state_snapshot` 把 `manifest.conf` 存到 `.manifest.run.bak`；成功或 `--keep-going` 时 `state_discard_snapshot` 丢弃，失败回滚时 `state_restore_snapshot` 还原，保证文件改动与清单改动一起回退（否则 status/remove 会依据残留清单去找已回滚的产物）。

只有 `install/update/remove` 且非 `--dry-run` 的入口会取快照；`verify --fix` 同样会写清单，也取快照。`verify`（无 `--fix`）、`status` 与 dry-run 不写清单，也不得丢弃或还原快照——否则它们会删掉并发写运行正在使用的回滚基线。`state.sh` 用 `STATE_SNAPSHOT_OWNER` 标记所有权，只有取过快照的运行才能还原/丢弃它。

### 并发锁

快照基线只有一个（`.manifest.run.bak`），两个写运行同时跑会互相覆盖。因此写运行还要取 `state/.lock`：

```text
state_lock_acquire    mkdir 原子取锁，写入 pid；已有锁时
                      ├─ pid 已死 → 清理残留后重试
                      └─ pid 存活 → 报错退出，提示删除锁路径
state_lock_release    只释放自己持有的锁（比对 pid），不误删他人锁
state_locked          当前是否持有锁（供 EXIT trap 判断）
```

只读动词（`verify` 无 `--fix`、`status`、`export`、`doctor`）与 `--dry-run` 不取锁，因此可以与写运行并行。EXIT trap 无条件调用 `state_lock_release`，由它自己判断是否持有。

`state_action_dir <name>` 返回 `state/actions/<name>/`（模式 700），供动作做**跨运行**的持久记录，与一次性回滚不同。典型用例是 `mirrors`：`state/actions/mirrors/changed.txt` + 原文件备份，使 `remove mirrors` 能在任意后续运行中还原到“本动作首次改写前”的状态。

## 九、权限策略

`require_sudo`：

1. `sudo -n true` 成功则直接返回；
2. 交互终端（`-t 0` 且 `-t 1`）执行 `sudo -v`；
3. 非交互且无凭据则失败，提示预先 `sudo -v` 或 `--no-sudo`。

apt/dpkg 前 `wait_for_apt_lock` 轮询 dpkg/apt 锁（默认最多 60s），失败必须向上传播。

## 十、配置动作

约定：`engine/actions/<name>.sh` 提供 `action_<name>_apply <id>` / `_remove` / `_verify` / `_status` 四个动词，由引擎惰性 source。动作脚本**不加 `set -e`**，出错用返回值表达。`_status` 是只读的，输出与 package 类一致的一行摘要（如 `git  name=… email=… proxy=…`）。

| 动作 | sudo | 关键行为 |
|---|---:|---|
| mirrors | 1 | 按架构选 archive/ports 镜像；改前把原源文件持久备份到 `state/actions/mirrors/`；remove 跨运行还原；改完 `apt update`（`MIRROR_SKIP_APT_UPDATE=true` 时跳过）；`MIRROR_SKIP_APT=true` 时不改写源；`APT_UPGRADE=true` 时追加全量 `apt-get upgrade` |
| proxy | 0 | 推导代理地址，ping 主机，写 shell/Git 代理；verify 用 `curl -x` 访问 `PROXY_TEST_URL`，超时取 `PROXY_CONNECT_TIMEOUT` / `PROXY_MAX_TIME` |
| git | 0 | 写全局身份与代理，产物 `$HOME/.gitconfig`；身份为空则 warning 跳过；verify 校验 `user.name`/`user.email` 与代理键；remove 只还原代理键，**保留身份**（有意为之） |
| ssh | 0 | 生成 `$HOME/.ssh/id_<type>` 密钥（默认 ed25519）；remove 只删本动作创建的密钥 |
| syslog | 1 | 写 journald drop-in 与限容配置；产物 `/etc/systemd/journald.conf.d/99-os-config.conf`、`$HOME/.bashrc`、`$HOME/.local/bin/bat`；verify 三者都查；remove 时没有 sudo 也照样清理用户级残留（别名块、bat 软链），系统级部分返回 `100`（skipped） |
| nosuspend | 0 | 关闭桌面息屏/自动锁屏；apply 记录 gsettings 原值到 `state/actions/nosuspend/`，remove **按原值还原**（没有记录才退回发行版默认） |
| nodejs | 0 | nvm 安装 Node LTS，设 default，写 npm registry；apply 记录 npm 配置原值到 `state/actions/nodejs/npmrc.orig`，remove 删除 `~/.nvm` 并**按原值还原 npm 配置**（原本没有的键删掉）；verify 校验 node/npm 版本与 registry；remove 需确认，用户拒绝时返回 `100`（skipped） |

### apply / remove / verify 的对称性

每个动作都必须满足三条：

1. **apply 写什么，remove 就还原什么**——写系统设置（gsettings）要记原值，写用户配置（npm config）要记原值；只删自己创建的东西，不动用户原有的。
2. **apply 建的每个产物，verify 都要查**——例如 syslog 的 bat 软链、nodejs 的 npm registry。
3. **remove 的结果要如实上报**——没能完全还原时返回 `100`（skipped）而不是 `0`，否则引擎会把它计成"成功"。

## 十一、备份与回滚

`register_rollback <file> [user|sudo]`：

1. 原文件存在 → 备份为 `.bak.<ts>.<pid>`，失败时恢复；
2. 原文件不存在 → 记录为新建，失败时删除。

两条硬约束：

- `sudo` 模式下必须先确认 `sudo` 可用再判断文件是否存在。判断失败时**不能**当成“不存在”，否则回滚会把本该还原的文件删掉——此时直接中止注册并返回非零。
- 只有真正登记成功才标记“已注册”。备份失败时不标记，允许重试，避免出现“有标记、无备份”的状态。

`register_tmpfile` 登记临时文件，退出时统一清理。用户文件用普通 `cp/rm`，系统文件用 `sudo cp/rm`。`_ROLLBACK_DONE` 防止 trap 重复执行；`setup_traps` 安装 EXIT/ERR/signal 处理。

## 十二、日志

`lib/log.sh` 同时输出终端与 `logs/setup-<ts>.log`：

- 目录 `700`、文件 `600`；
- 落盘前脱敏 token/password/api key、Bearer Authorization、URL 凭据；
- 终端保留原始输出，便于观察 npm/curl 进度；
- `run_step_verbose[_capture]` 用条件管道读取 `PIPESTATUS[0]`，返回原命令退出码而非 `tee` 的。

## 十三、配置文件

`config/versions.env`（版本与 npm 源）与 `config/user.env`（本机参数）在 `util.sh` 被 source 时以 `set -a` 自动加载（幂等，`_USER_CONFIG_LOADED` 守卫）。`user.env` 已被 `.gitignore` 忽略。

常用变量见 `config/user.env.example`，包括 `MIRROR_APT_URL`/`MIRROR_APT_PORTS_URL`/`MIRROR_SKIP_APT`/`MIRROR_SKIP_APT_UPDATE`/`APT_UPGRADE`、`PROXY_*`、`GIT_USER_*`、`SSH_*`、`JOURNALD_MAX_USE`；版本变量包括 `NVM_VERSION`、`NODE_LTS_MAJOR`、`NODE_VERSION`、`NPM_REGISTRY` 与各 AI CLI 的包名/版本。`config/user.env.example` 里列出的每个键都必须被引擎实际读取；不生效的键不进模板。

SSH 服务端不再由布尔开关控制：`openssh-server` 是 catalog 里的普通条目，用 `--pick openssh-server` 或写进 profile 启用。旧配置里残留的 `SSH_INSTALL_SERVER` 会在加载时被明确提示已废弃（而不是静默忽略）。

安全说明：`user.env` 是普通 shell 文件，`SSH_KEY_PASSPHRASE` 若填写即为明文。

## 十四、测试策略

```bash
./tests/run.sh          # 全部；打印 PASS/FAIL 与总计
./tests/run.sh apt      # 只跑显示名或用例函数名里包含 apt 的用例
```

过滤条件匹配不到任何用例时返回非零，避免“跑了 0 个用例却显示通过”的假阳性。

- 每个用例在 `( ... )` 子 shell 中运行，`HOME`/`STATE_DIR`/`STATE_FILE`/`LOG_FILE`/`PATH` 全部指向临时目录。
- `sudo`/`fuser`/`ip`/`ping`/`apt-get`/`dpkg-query`/`dpkg`/`npm`/`node`/`snap`/`ssh-keygen`/`curl` 均为 fake，不会改动宿主机。
- 覆盖：语法、真实 catalog 加载与关键字段、变量/artifacts 展开（含 `${VAR:-默认值}`、desc 不展开、artifacts 只展开一次）、非法输入拒绝、adhoc 幂等、profile 解析与继承、依赖闭包/逆序、state 权限与并发锁（取放/不误删他人锁/清理残留）、rollback 六种路径（含 sudo 不可用不删文件、备份失败可重试）、util/IPv4/sudo、`with_retry`、代理推导、日志脱敏、semver/命令校验/后端分派、apt/npm/snap 五动词、引擎（install/update/remove/verify/status/dry-run/no-sudo/失败/keep-going/status 回退/缺动作/未知动词、remove 时提示选集外的已安装依赖方、verify --fix 修复后复验与 dry-run 不修复）、动作脚本接口完整性（apply/remove/verify/status 四动词齐备）、mirrors/nodejs/nosuspend/ssh 辅助函数、proxy 写入/幂等/重写/移除、nodejs 卸载被拒绝算 skipped 与卸载还原 npm 配置、nosuspend 按原值还原、syslog 无 sudo 仍清用户级残留与 verify 查 bat 软链、export（生成/空状态/文件名即 profile 名）、doctor（跑完全部检查/提示清单产物缺失）、`--fix` 与 `--output` 的参数组合校验、内联 id 去首尾短横、废弃配置键有提示、`setup.sh` 入口参数。

## 十五、export 与 doctor

### export —— 把本机状态导出为 profile

`engine/lib/export.sh`，动词 `export`，不需要选择，只读（唯一写的是输出的 profile 文件）。

```text
export_run
  ├─ 遍历 CAT_ORDER：
  │    ├─ type=config → state_has <id>（清单里有即视为已应用）
  │    └─ type=package → _engine_tool_installed <id>（问后端）
  ├─ 全空 → 提示先 install 或用 --pick，返回 1
  └─ 按 catalog 原始顺序写 <EXPORT_OUTPUT>：
       ├─ 头注释：生成时间、用法、参数提示
       ├─ [名] desc / extends= / tools=…（名取自输出文件名）
       └─ 尾注释：21 个生效参数的当前值（空值标为 <未设置，走默认值>）
```

- 默认输出 `profiles/exported.conf`（已 gitignore，因机器而异）；`--output <路径>` 可改名，profile 名取自文件名。
- 只导出工具选择，**不导出参数**——参数属于 `config/user.env`，写在注释里供人工核对，避免把代理、邮箱这类本机信息固化进可提交文件。
- 新机器复刻：`install --profile exported` → `verify --fix --profile exported` 兜底收敛。

### doctor —— 环境体检

`engine/lib/doctor.sh`，动词 `doctor`，不需要选择，纯只读，不走 catalog 分派（`setup.sh` 在选择解析之前直接调用 `doctor_run`）。

十项检查，每项结论为 通过 / 需关注（warn，不影响退出码）/ 未通过（fail）：

| 检查 | 判定 |
|---|---|
| catalog | 条目数为 0 → fail |
| profiles | 为空 → warn（只能用 --pick/--all） |
| sudo | `sudo -n true` 通过 → ok；sudo 存在但免密不可用 → warn；无 sudo → fail |
| disk | 根分区剩余 <512MB → fail；<2GB → warn |
| apt-lock | `fuser` 能占到 dpkg 锁 → fail |
| commands | 缺 curl/git → warn |
| mirror | `curl -fsSI` 访问 `MIRROR_APT_URL`（默认 TUNA）失败 → warn |
| proxy | `PROXY_ENABLED=true` 时 ping 代理主机 + `curl -x` 真实访问；任一失败 → warn |
| manifest | 清单记录的产物路径消失 → warn，提示用 `verify --fix` |
| state | `state/` 权限不是 700 → warn |

有 fail 则 `doctor_run` 返回 1（setup.sh 退出码 1），全 ok/warn 返回 0。网络检查都带超时（5s 连接 / 10s 整体），不会长时间卡住。

## 十六、扩展

**加一个软件**：在 `catalog/*.catalog` 加一个 `[id]` 条目（package），必要时把它加入某个 profile 的 `tools`。

**加一个配置**：写 `engine/actions/<name>.sh`，实现四个动词函数（apply/remove/verify/status），然后在 catalog 里加 `type=config` 条目并声明 `artifacts`。

**加一个后端**：实现 `_backend_<name>_<verb>` 五个函数，登记 `BACKEND_SUPPORTED`，并在 `catalog_validate` 的允许列表中同步。

**加一项体检**：在 `engine/lib/doctor.sh` 里写 `_doctor_<check>` 函数（0=ok / 1=fail / 2=warn），在 `doctor_run` 里用 `_doctor_check` 登记一行。

**加一个平台**：实现对应引擎（Windows 为 `setup.ps1` + `engine/lib-win/`），复用同一套 catalog 与 profile 数据；平台差异只体现在后端与动作实现中。
