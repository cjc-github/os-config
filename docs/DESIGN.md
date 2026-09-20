# os-config 项目设计

> 状态：v7（2026-09-20）。架构从“平台 + 模块三件套”重构为“声明式 catalog + 无状态引擎 + 五动词”。
> 当前实现 Ubuntu 22.04/24.04 的 Bash 引擎；Windows PowerShell 引擎待实现。本文以仓库现有代码为准。

## 一、目标和边界

`os-config` 用一个入口完成开发环境的安装与配置：

1. 选定一份**清单**（profile，或 `--pick` / `--all`）。
2. 展开**依赖闭包**并拓扑排序。
3. 对每一项分派到**后端适配器**（package）或**配置动作**（config）。
4. 执行五动词之一：`install` / `update` / `remove` / `verify` / `status`。
5. 汇总成功、跳过、失败，并在失败时回滚本次写操作。

设计目标：新增一个工具**只改数据**（`catalog/*.catalog`）或**只加一个动作脚本**，不需要动引擎。

### 与旧架构的差异（v6 → v7）

| 维度 | v6 | v7 |
|---|---|---|
| 平台 | `platforms/<族>/` 目录 + `detect.sh` | 单引擎，架构差异下沉到后端/动作内部 |
| 工具描述 | 每模块 `module.conf` + `install.sh` + `verify.sh` | `catalog/*.catalog` 数据文件 |
| 选择 | `config/base-tools.conf` + `--module` | `profiles/*.conf` + `--pick`/`--all` |
| 动词 | `install` / `verify` 两种 | `install`/`update`/`remove`/`verify`/`status` 五种 |
| 后端 | 各模块自己写 apt/npm 命令 | 统一适配器 `apt`/`npm`/`snap` |
| 状态 | 一次性 `.backups` manifest | `state/manifest.conf` + 每动作持久备份 |

## 二、目录结构

```text
setup.sh                    入口：解析动词与选择 → engine_run
catalog/
  base.catalog              系统与工具类的 package/config 条目
  config.catalog            配置类条目
profiles/
  minimal.conf  default.conf  dev.conf  ai.conf
engine/
  lib/log.sh                终端+文件日志、脱敏、权限
  lib/util.sh               配置加载、run_step、重试、sudo、apt 锁、代理推导、nvm
  lib/rollback.sh           备份/回滚/trap/临时文件
  lib/state.sh              manifest 与 state/actions/<name>/
  lib/catalog.sh            catalog 解析、校验、变量/artifacts 展开、内联注册
  lib/profile.sh            profile 解析、继承、tokens 解析、resolve
  lib/graph.sh              依赖闭包、拓扑排序、逆序、dependents
  lib/backends.sh           apt / npm / snap 适配器
  lib/engine.sh             五动词编排器
  actions/
    mirrors.sh proxy.sh git.sh ssh.sh syslog.sh nosuspend.sh nodejs.sh
state/
  manifest.conf             已记录工具的产物清单
  actions/<name>/           跨运行的持久备份（如 mirrors 的原源文件）
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
| `artifacts` | 选填 | 每行一个产物路径，支持 `$HOME` / `~` |
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

- `catalog_expand_vars`：支持 `$VAR` / `${VAR}`，未定义变量展开为空，并保护位置参数 `$1`。
- `catalog_expand_artifacts <id>`：展开变量并把行首 `~` 换算为 `$HOME`，每行输出一个路径。

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

| 动词 | package 类 | config 类 |
|---|---|---|
| install | `_backend_<b>_install` | `action_<action>_apply` |
| update | `_backend_<b>_update` | `action_<action>_apply` |
| remove | `_backend_<b>_remove` | `action_<action>_remove` |
| verify | `_backend_<b>_verify` | `action_<action>_verify` |
| status | `_backend_<b>_status` | `action_<action>_status`，缺失则通用回退 |

动作脚本在首次使用时才 source（`_engine_source_action`），同一动作只加载一次。

### 编排流程

```text
engine_run <verb> <id...>
  ├─ 校验动词合法
  ├─ graph_build（remove 时再 graph_reverse）
  ├─ 逐项 engine_run_one
  │    ├─ --no-sudo 且需提权 → 返回 100（skipped）
  │    ├─ --dry-run 且是写动词 → 只打印
  │    ├─ package → backend_dispatch
  │    └─ config  → action_dispatch + _engine_state_sync
  └─ 汇总：成功 / 跳过 / 失败；失败则返回 1
```

- 非 `--keep-going` 时首个失败即中断（由 trap 触发整体回滚）。
- `--keep-going` 时继续跑完，最终仍返回非零；引擎本身不触发回滚。

### 写操作预判

- `_engine_needs_sudo`：package 类的 `apt`/`snap` 视为需要提权；config 类看 `sudo=1`。
- `_engine_is_write_verb`：`install`/`update`/`remove` 是写动词。

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
state_has <id> / state_artifacts <id> / state_list
```

每次运行开始 `state_snapshot` 把 `manifest.conf` 存到 `.manifest.run.bak`；成功或 `--keep-going` 时 `state_discard_snapshot` 丢弃，失败回滚时 `state_restore_snapshot` 还原，保证文件改动与清单改动一起回退（否则 status/remove 会依据残留清单去找已回滚的产物）。

`state_action_dir <name>` 返回 `state/actions/<name>/`（模式 700），供动作做**跨运行**的持久记录，与一次性回滚不同。典型用例是 `mirrors`：`state/actions/mirrors/changed.txt` + 原文件备份，使 `remove mirrors` 能在任意后续运行中还原到“本动作首次改写前”的状态。

## 九、权限策略

`require_sudo`：

1. `sudo -n true` 成功则直接返回；
2. 交互终端（`-t 0` 且 `-t 1`）执行 `sudo -v`；
3. 非交互且无凭据则失败，提示预先 `sudo -v` 或 `--no-sudo`。

apt/dpkg 前 `wait_for_apt_lock` 轮询 dpkg/apt 锁（默认最多 60s），失败必须向上传播。

## 十、配置动作

约定：`engine/actions/<name>.sh` 提供 `action_<name>_apply <id>` / `_remove` / `_verify`（`_status` 可选），由引擎惰性 source。动作脚本**不加 `set -e`**，出错用返回值表达。

| 动作 | sudo | 关键行为 |
|---|---:|---|
| mirrors | 1 | 按架构选 archive/ports 镜像；改前把原源文件持久备份到 `state/actions/mirrors/`；remove 跨运行还原；改完 `apt update` |
| proxy | 0 | 推导代理地址，ping 主机，写 shell/Git 代理；verify 用 `curl -x` 访问 `PROXY_TEST_URL` |
| git | 1 | 写全局身份与代理，产物 `$HOME/.gitconfig`；身份为空则 warning 跳过 |
| ssh | 0 | 生成 `$HOME/.ssh/id_<type>` 密钥（默认 ed25519） |
| syslog | 1 | 写 journald drop-in 与限容配置；产物 `/etc/systemd/journald.conf.d/99-os-config.conf`、`$HOME/.bashrc` |
| nosuspend | 0 | 关闭桌面息屏/自动锁屏 |
| nodejs | 0 | nvm 安装 Node LTS，设 default，写 npm registry |

## 十一、备份与回滚

`register_rollback <file> [user|sudo]`：

1. 原文件存在 → 备份为 `.bak.<ts>.<pid>`，失败时恢复；
2. 原文件不存在 → 记录为新建，失败时删除。

`register_tmpfile` 登记临时文件，退出时统一清理。用户文件用普通 `cp/rm`，系统文件用 `sudo cp/rm`。`_ROLLBACK_DONE` 防止 trap 重复执行；`setup_traps` 安装 EXIT/ERR/signal 处理。

## 十二、日志

`lib/log.sh` 同时输出终端与 `logs/setup-<ts>.log`：

- 目录 `700`、文件 `600`；
- 落盘前脱敏 token/password/api key、Bearer Authorization、URL 凭据；
- 终端保留原始输出，便于观察 npm/curl 进度；
- `run_step_verbose[_capture]` 用条件管道读取 `PIPESTATUS[0]`，返回原命令退出码而非 `tee` 的。

## 十三、配置文件

`config/versions.env`（版本与 npm 源）与 `config/user.env`（本机参数）在 `util.sh` 被 source 时以 `set -a` 自动加载（幂等，`_USER_CONFIG_LOADED` 守卫）。`user.env` 已被 `.gitignore` 忽略。

常用变量见 `config/user.env.example`，包括 `MIRROR_APT_URL`/`MIRROR_APT_PORTS_URL`、`PROXY_*`、`GIT_USER_*`、`SSH_*`、`JOURNALD_MAX_USE`；版本变量包括 `NVM_VERSION`、`NODE_LTS_MAJOR`、`NODE_VERSION`、`NPM_REGISTRY` 与各 AI CLI 的包名/版本。

安全说明：`user.env` 是普通 shell 文件，`SSH_KEY_PASSPHRASE` 若填写即为明文。

## 十四、测试策略

```bash
./tests/run.sh          # 全部；打印 PASS/FAIL 与总计
./tests/run.sh apt      # 只跑名字包含 apt 的用例
```

- 每个用例在 `( ... )` 子 shell 中运行，`HOME`/`STATE_DIR`/`STATE_FILE`/`LOG_FILE`/`PATH` 全部指向临时目录。
- `sudo`/`fuser`/`ip`/`ping`/`apt-get`/`dpkg-query`/`dpkg`/`npm`/`node`/`snap`/`ssh-keygen`/`curl` 均为 fake，不会改动宿主机。
- 覆盖：语法、真实 catalog 加载与关键字段、变量/artifacts 展开、非法输入拒绝、adhoc 幂等、profile 解析与继承、依赖闭包/逆序、state 权限、rollback 六种路径、util/IPv4/sudo、`with_retry`、代理推导、日志脱敏、semver/命令校验/后端分派、apt/npm/snap 五动词、引擎（install/remove/dry-run/no-sudo/失败/keep-going/status 回退/缺动作/未知动词）、动作脚本接口完整性、mirrors/nodejs/nosuspend/ssh 辅助函数、proxy 写入/幂等/重写/移除、`setup.sh` 入口参数。

## 十五、扩展

**加一个软件**：在 `catalog/*.catalog` 加一个 `[id]` 条目（package），必要时把它加入某个 profile 的 `tools`。

**加一个配置**：写 `engine/actions/<name>.sh`，实现三个动词函数，然后在 catalog 里加 `type=config` 条目并声明 `artifacts`。

**加一个后端**：实现 `_backend_<name>_<verb>` 五个函数，登记 `BACKEND_SUPPORTED`，并在 `catalog_validate` 的允许列表中同步。

**加一个平台**：实现对应引擎（Windows 为 `setup.ps1` + `engine/lib-win/`），复用同一套 catalog 与 profile 数据；平台差异只体现在后端与动作实现中。
