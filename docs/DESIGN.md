# os-config 项目设计

> 状态：v4（在 v3 基础上：install.sh 接入 `parse_install_args` 支持 `--force/-f/--debug/--help`；`utils.sh` 被 source 时自动 `load_user_config`；ai-* 模块 npm install 加速参数 + 镜像源 `--registry` + 旧目录清理避免 ENOTEMPTY；新增 `.gitignore`；OPENCODE 版本锁定 1.18.18）。
> 如需批注，请直接在文档中行内添加 `> 批注：…`。

---

## 一、设计目标与原则

1. **平台优先**：主脚本先识别平台，再加载该平台的模块集。当前只实现 `ubuntu24`，其它平台目录留空占位。
2. **模块化 + 配置驱动**：每个功能是一个独立模块；用户通过 `config/modules.conf` 勾选要装的模块（加一行模块名就启用），也可用命令行参数覆盖。
3. **每个模块 = 安装 + 验证 + 文档**：`install.sh` 做安装/配置，`verify.sh` 做运行验证（退出码 0 = 成功），`README.md` 给人看的「做了什么」说明。
4. **固定版本**：所有可装软件的版本号集中到 `config/versions.env`，避免版本漂移。
5. **依赖显式声明**：模块在 `module.conf` 里声明 `DEPS=`，运行器自动拓扑排序（保证 `nodejs` 先于 `claude/codex/opencode`）。
6. **幂等 + 可回滚**：重复执行不报错、不重复安装（`command -v` 判断，`--force` / `-f` 可强制）；改 dotfiles 前先备份；脚本失败时 trap 自动回滚到备份。
7. **日志留痕 + 进展可见**：彩色终端输出 + 落盘到 `logs/`（`logs/` 已被 `.gitignore` 忽略，不入库）；对耗时命令（npm install / curl / nvm install）实时显示进度并落盘 LOG_FILE。
8. **异常处理统一**：所有 install.sh 头部调 `setup_traps` + `parse_install_args "$@"` 注册 trap 与解析参数；网络/不可靠命令用 `with_retry` 包装；apt 命令前等 dpkg 锁。

---

## 二、权限模型

- 脚本**以普通用户身份运行**（不整体切 root），原因：nvm/npm 是用户级，整体 root 会导致全局包装到 root 的 home，后续普通用户用不到。
- **apt 等系统级命令前加 `sudo`**；nvm/npm/git config/写 `~/.bashrc` 等**用户级操作不加 sudo**。
- 启动时检测：`sudo -n true` 能否免密 sudo；不能则在需要 sudo 的模块处提示并要求交互输入密码（或 `--no-sudo` 跳过该模块）。
- 模块可在 `module.conf` 标记 `NEEDS_SUDO=1`，runner 在执行前校验 sudo 可用性。

> 批注：

---

## 三、目录结构

```
os-config/
├── setup.sh                          # 唯一入口：识别平台 → 读配置 → 排序 → 逐模块 install+verify
├── .gitignore                        # 忽略 logs/、*.bak.*、config/user.env、*.tmp 等
├── lib/                              # 平台无关的共享工具函数
│   ├── log.sh                        # 彩色输出 + 日志落盘（含脱敏）
│   ├── platform.sh                   # 平台识别（/etc/os-release 解析）
│   ├── runner.sh                     # 模块加载、依赖排序、install/verify 调度、node-env 注入、失败汇总
│   └── utils.sh                      # load_user_config / parse_install_args / run_step(_verbose) / 幂等 / sudo / 异常处理工具集（A-H 八项）
├── config/
│   ├── modules.conf                  # 启用的模块清单（每行一个模块名，# 注释）
│   ├── versions.env                  # 所有固定版本号 + NPM_REGISTRY（占位，见「版本锁定流程」）
│   ├── user.env.example              # 用户可覆盖变量（代理端口、git user/email、MIRROR_*…）
│   └── user.env                      # 由 user.env.example 复制；含私密信息，.gitignore 忽略不入库
├── platforms/
│   ├── ubuntu24/
│   │   ├── detect.sh                 # 判定规则：ID=ubuntu && VERSION_ID=24.04；成功/失败都走 log
│   │   └── modules/
│   │       ├── sys-mirrors/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── sys-base/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── net-git/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── net-ssh/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── net-proxy/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── rt-nodejs/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── rt-log/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── rt-screen/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── ai-claude/{install.sh,verify.sh,module.conf,README.md}
│   │       ├── ai-codex/{install.sh,verify.sh,module.conf,README.md}
│   │       └── ai-opencode/{install.sh,verify.sh,module.conf,README.md}
│   ├── ubuntu22/        (空，占位)
│   ├── macos/           (空，占位)
│   └── arch/            (空，占位)
├── docs/
│   └── DESIGN.md                    # 本设计文档
├── .gitignore                       # 忽略 logs/、*.bak.*、config/user.env、*.tmp、IDE/系统杂项
└── logs/                            # 运行时自动生成；.gitignore 已忽略，不入库
```

语义分组前缀（`sys-` 系统基础 / `net-` 网络与工具 / `rt-` 运行时 & 个人配置 / `ai-` 上层 AI CLI）的字母序决定默认执行顺序；`module.conf` 里的 `DEPS=` 做依赖兜底。

> 批注：

---

## 四、模块契约

每个模块目录固定四件套（`uninstall.sh` 可选）：

| 文件 | 作用 |
|---|---|
| `install.sh` | 执行安装/配置。开头 `source` 共享库（会自动 `load_user_config`）+ `setup_traps` + `parse_install_args "$@"`；幂等判断；改 dotfiles 前 `register_rollback` 备份；结束返回 0/非0 |
| `verify.sh` | 验证可用性。跑 `--version` 或 smoke test，退出码即结论 |
| `module.conf` | 元数据：`NAME=`、`DESC=`、`DEPS=`（逗号分隔模块名）、`NEEDS_SUDO=0/1` |
| `README.md` | 给人看的「做了什么」说明：前置依赖、逐条安装步骤、验证项、可配置参数表、幂等行为、本模块接入的异常处理、用法示例 |
| `uninstall.sh`（可选） | 回滚该模块改动（删包、还原备份、清理配置项） |

### `install.sh` 头部统一注释块

每个 install.sh 顶部都有固定格式注释，便于查阅：

```
# 模块：<name>  ——  <一句话作用>
# 平台：ubuntu24
# 作用：<详细说明>
# 依赖：<DEPS>
#
# 【可配置参数】（集中在 config/versions.env 或 config/user.env）
#   <变量名>=<默认值>   # 说明
#   实查最新稳定版：<npm view / curl 命令>
#
# 【行为标志】
#   $FORCE=1 / $DEBUG=1   （由 parse_install_args 解析命令行 --force/-f/--debug 注入；或 setup.sh 注入）
#
# 【注入变量】
#   $MODULE_NAME / $MODULE_DIR / $LOG_FILE
```

### install.sh 头部统一调用顺序

每个 install.sh 在 `source` 共享库之后，应按固定顺序调用：

```bash
. "$PROJECT_DIR/lib/utils.sh"   # 顺带触发 load_user_config（幂等，已加载则跳过）
. "$PROJECT_DIR/lib/log.sh"
setup_traps                       # 注册 EXIT/INT/TERM/ERR trap
parse_install_args "$@"           # 解析 --force/-f/--debug/--help；不调用则命令行参数无效
[[ "${DEBUG:-0}" == "1" ]] && set -x
```

> 关键：`utils.sh` 只**提供** `parse_install_args` 函数，不会自动解析命令行。各 install.sh 必须显式调用 `parse_install_args "$@"`，否则 `./install.sh --force` 不会生效（FORCE 始终为 0，永远走幂等跳过分支）。

### 模块名 → 目录映射规则

- 配置和 CLI **统一用不带前缀的 `NAME`**（即 `module.conf` 里的 `NAME=git`，对应目录 `net-git`）。
- runner 启动时扫描 `platforms/<plat>/modules/*/module.conf`，构建 `NAME → 目录` 映射表，并按目录前缀排序作为兜底执行序。
- `modules.conf` 和 `--module` 都写 `NAME`，前缀只在目录层体现，对用户透明。

### runner 注入的环境变量与 node-env 激活

```bash
# runner.sh 调用每个模块前注入：
#   $PLATFORM_DIR   -> platforms/ubuntu24
#   $MODULE_DIR     -> 该模块绝对路径
#   $MODULE_NAME    -> 该模块的 NAME
#   $FORCE          -> 是否强制重装（setup.sh --force 注入；install.sh 内 parse_install_args 也能覆盖）
#   $DEBUG          -> 调试模式（同上）
#   $LOG_FILE       -> 本次运行日志路径
#
# 版本/用户配置：install.sh 内部用 `: "${VAR:=default}"` 读取
#   - 经 setup.sh 入口：setup.sh 在调用 install.sh 前 source config/versions.env + user.env 进环境
#   - 直接跑 ./install.sh：utils.sh 被 source 时自动调 load_user_config（幂等），同样加载上述两个文件
#     （用 _USER_CONFIG_LOADED 标记避免重复 source）
#
# install.sh 命令行参数（由 utils.sh:parse_install_args 解析，setup.sh 入口与直接跑都生效）：
#   --force / -f   FORCE=1  忽略幂等判断，强制重装/重写
#   --debug         DEBUG=1 后续 `set -x` 跟踪
#   --help / -h     打印帮助后退出 0
#   未知参数         安静跳过（未来扩展友好，不报错）
#   等价环境变量：FORCE=1 / DEBUG=1（命令行优先级更高）
#
# node-env 激活（关键）：
#   rt-nodejs 安装 nvm 后，runner 在调用 ai-*（ai-claude/ai-codex/ai-opencode）等
#   声明 DEPS 含 nodejs 的模块前，自动执行：
#     export NVM_DIR="$HOME/.nvm"
#     [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
#     nvm use --silent default   # 把 default 版本 node/npm 注入当前 PATH
#   保证非交互脚本里 node/npm 可用，无需依赖 ~/.bashrc 的加载。
```

> 批注：

---

## 五、主脚本 `setup.sh` 流程

```
1. set -euo pipefail; source lib/utils.sh lib/log.sh lib/platform.sh lib/runner.sh
2. 解析 CLI 参数（--module / --all / --list / --dry-run / --force / --keep-going /
                 --install-only / --verify-only / --platform / --no-sudo / --help）
3. detect_platform  ->  PLATFORM=ubuntu24（不支持则退出并提示"暂未支持，可 --platform 强制"）
4. 检测 sudo 可用性（NEEDS_SUDO 模块需要时）；加载 config/versions.env + config/user.env
5. 确定启用模块集合：
     - 默认：读 config/modules.conf（NAME 列表）
     - --module a,b：只跑这些 + 其依赖（依赖展开结果在 --dry-run 显式列出）
     - --all：该平台 modules/ 下全部
6. 解析 DEPS 做拓扑排序（按前缀兜底排序）；检测循环依赖则报错退出
7. for mod in $ORDERED:
     若 mod 声明 DEPS 含 nodejs：激活 nvm + node PATH（仅一次）
     runner 调用：bash $MODULE_DIR/install.sh
       install.sh 内部头部：
         source utils.sh   → 自动 load_user_config（幂等加载 versions.env + user.env）
         setup_traps       → 注册 EXIT/INT/TERM/ERR trap
         parse_install_args "$@"  → 解析 --force/-f/--debug/--help
         [[ $DEBUG == 1 ]] && set -x
       apt 模块：wait_for_apt_lock 等 dpkg 锁释放
       网络/npm 命令：with_retry 3 <sec> -- <cmd> 重试
       ai-* 模块：装前清理 prefix/lib/node_modules/<pkg> 旧目录避免 ENOTEMPTY
                + npm install -g --no-audit --no-fund --prefer-offline --registry=$NPM_REGISTRY
       临时文件：register_tmpfile 注册，trap 时自动清理
       改 dotfiles 前：register_rollback 备份并注册回滚
       失败时：trap ERR 打印失败命令/行号/退出码 + rollback_on_exit 回滚备份
     [ --install-only ] && continue
     runner 调用：bash $MODULE_DIR/verify.sh
8. 汇总报告（成功 / 安装失败 / 验证失败 / 跳过）+ 失败模块名醒目列出 + 日志路径；失败则 exit 非0
```

> 批注：

---

## 六、平台识别 `lib/platform.sh`

基于 `/etc/os-release`，**精确匹配版本号**（避免把 24.10 当 24.04）：

```bash
detect_platform() {
  . /etc/os-release          # ID, VERSION_ID, VERSION_CODENAME
  case "$ID/$VERSION_ID" in
    ubuntu/24.04) echo ubuntu24 ;;
    ubuntu/22.04) echo ubuntu22 ;;
    *) return 1 ;;            # 未支持 -> setup.sh 报错退出；可 --platform 强制覆盖
  esac
}
```

- 若需支持 24.10，单独加一行 `ubuntu/24.10) echo ubuntu2410 ;;` 与对应目录。
- 每个 `platforms/<plat>/detect.sh` 可被 runner 调用做自检（双保险）；detect.sh 自身也加载 `lib/log.sh`，成功 `log_ok`、失败 `log_error`，输出风格与模块一致。

> 批注：

---

## 七、配置文件

### `config/modules.conf`（勾选式配置）

```
# 每行一个模块名（NAME，不带前缀），# 开头注释。加哪行就装哪个。
# 注意：mirrors 放最前面（换源后才装 base 的 apt 包，加速下载）
mirrors
base
git
ssh
proxy
nodejs
log
screen
claude
codex
opencode
```

### `config/versions.env`（固定版本，占位 → 见「版本锁定流程」锁定）

```bash
# —— 基础运行时 ——
NVM_VERSION=v0.40.1            # 占位：锁定前用 git ls-remote 确认最新 tag
NODE_LTS_MAJOR=22              # nvm install --lts 的主版本（满足所有 CLI 的 node≥18/20）

# —— 大模型 CLI（固定版本，避免漂移）——
CLAUDE_CODE_PKG=@anthropic-ai/claude-code
CLAUDE_CODE_VERSION=2.1.228    # 占位：锁定前用 npm view 确认

CODEX_PKG=@openai/codex
CODEX_VERSION=0.147.0

OPENCODE_PKG=opencode-ai       # 注意：npm 包名是 opencode-ai，不是 opencode
OPENCODE_VERSION=1.18.18       # 锁定于 2026-08-16：npm view opencode-ai version

# —— npm 镜像（国内可选；不需要可留空）——
# 常见候选：npmmirror（阿里，推荐） / tencent https://mirrors.cloud.tencent.com/npm/
NPM_REGISTRY=https://registry.npmmirror.com
```

> 关键：ai-* 模块的 `npm install -g` 命令额外通过 `--registry="$NPM_REGISTRY"` 强制使用此镜像，
> 避免用户层 `~/.npmrc` 没改/被改回官方源时仍能命中镜像。

### `config/user.env.example`（代理/git 身份等可覆盖项）

```bash
# —— 国内镜像源（sys-mirrors 模块；最先执行，加速后续一切 apt 安装）——
# amd64/i386 用 MIRROR_APT_URL；arm64/riscv64/ppc64el 用 MIRROR_APT_PORTS_URL
# 常见候选：清华 tuna.tsinghua / ali mirrors.aliyun / ustc mirrors.ustc
MIRROR_APT_URL=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
MIRROR_APT_PORTS_URL=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
MIRROR_SKIP_APT=false          # true 跳过 apt 源重写（公司内网/离线/空气隔离环境已自备源）
MIRROR_SKIP_APT_UPDATE=false   # true 不执行 apt update（完全离线）

PROXY_HOST=127.0.0.1
PROXY_PORT=7890              # 已存在的代理端口
NO_PROXY=localhost,127.0.0.1,::1
GIT_USER_NAME=
GIT_USER_EMAIL=
SSH_KEY_TYPE=ed25519        # 默认非交互生成 ed25519
SSH_KEY_PASSPHRASE=         # 留空 = 无 passphrase（非交互）

# 日志模块
JOURNALD_MAX_USE=500M
LOGROTATE_KEEP_WEEKS=4
```

> 批注：

---

## 八、版本锁定流程

`versions.env` 的版本号**先标占位，再按本流程锁定后提交**：

1. **npm 包**：`npm view <pkg> version`（如 `npm view @openai/codex version`、`npm view opencode-ai version`、`npm view @anthropic-ai/claude-code version`），取最新稳定版写入。
2. **nvm**：`curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+'` 取最新 tag。
3. **node LTS 主版本**：固定 22（满足 claude≥20 / codex≥18 / opencode≥18 的最低要求），如需切 20 单独改 `NODE_LTS_MAJOR`。
4. 锁定后在 `versions.env` 顶部注释「锁定于 YYYY-MM-DD」，并提交。

> 说明：本设计文档里给的 `2.1.228 / 0.147.0 / 1.16.0 / v0.40.1` 均为占位参考值，**以锁定步骤的实查结果为准**。

> 批注：

---

## 九、CLI 选项

### `setup.sh` 全局选项

| 用法 | 说明 |
|---|---|
| `./setup.sh` | 跑 `modules.conf` 里启用的模块 |
| `./setup.sh --module git,nodejs` | 只跑指定模块（自动补依赖；`--dry-run` 会显式列出被补的依赖） |
| `./setup.sh --all` | 跑当前平台全部模块 |
| `./setup.sh --list` | 列出可用模块（NAME / DEPS / NEEDS_SUDO） |
| `./setup.sh --dry-run` | 只打印执行计划（含依赖展开）不执行 |
| `./setup.sh --install-only` | 只跑 install，跳过 verify |
| `./setup.sh --verify-only` | 只跑 verify |
| `./setup.sh --force` | 忽略幂等判断强制重装（注入 `$FORCE=1` 给所有 install.sh） |
| `./setup.sh --keep-going` | 遇错不停，跑完再汇总 |
| `./setup.sh --no-sudo` | 跳过 NEEDS_SUDO 的模块 |
| `./setup.sh --platform ubuntu24` | 强制指定平台（测试用） |
| `./setup.sh --debug` | 开 `set -x` 调试（注入 `$DEBUG=1`） |
| `./setup.sh --help` | 帮助 |

### `install.sh` 单跑时的选项（由 `parse_install_args` 解析）

不经过 `setup.sh`，在模块目录直接跑也支持：

| 用法 | 说明 |
|---|---|
| `./install.sh` | 默认幂等：已装且版本一致就跳过 |
| `./install.sh --force` 或 `./install.sh -f` | 忽略幂等，强制重装/重写 |
| `./install.sh --debug` | 开 `set -x` 调试 |
| `./install.sh --help` 或 `./install.sh -h` | 打印本模块用法后退出 0 |
| `FORCE=1 ./install.sh` | 等价 `--force`（环境变量兜底，命令行优先级更高） |
| `DEBUG=1 ./install.sh` | 等价 `--debug` |

> 关键：`utils.sh` 只**提供** `parse_install_args` 函数，install.sh 必须显式调用 `parse_install_args "$@"` 才能让 `--force` 生效；否则命令行参数被静默忽略，`FORCE` 始终为 0。

> 批注：

---

## 十、Ubuntu24 模块清单与依赖链

| 模块 | DEPS | NEEDS_SUDO | install 主要内容 | verify 主要内容 | 异常处理接入 |
|---|---|---|---|---|---|
| `sys-mirrors` | — | 1 | **系统最先跑**：识别架构（amd64→archive / arm64→ports）→ 定位 deb822 源文件 `/etc/apt/sources.list.d/ubuntu.sources`（Ubuntu 24.04 不用 sources.list）→ 幂等 grep 已是镜像则跳过 → 备份 + `sed -E` 替换 URIs 为清华源（可覆盖 `MIRROR_APT_URL`）→ `sudo apt update` 验证 | `ubuntu.sources` 存在；URIs 不再指向 ubuntu.com；`apt-get check` 通过 | setup_traps / wait_for_apt_lock / register_rollback(备份 source 文件) / with_retry(apt update 2×10s) |
| `sys-base` | mirrors | 1 | `sudo apt update && sudo apt -y upgrade`，装 `curl wget ca-certificates gnupg unzip` | `curl --version` 等 | setup_traps / wait_for_apt_lock / with_retry(3×5s) |
| `net-git` | base | 1 | `sudo apt install -y git`；`git config --global user.name/email`；`git config --global http.proxy/https.proxy` | `git --version`；`git config --get http.proxy` 非空 | setup_traps / wait_for_apt_lock / with_retry(3×5s) |
| `net-ssh` | base | 1 | `sudo apt install -y openssh-client openssh-server`；**非交互** `ssh-keygen -t $SSH_KEY_TYPE -N "$SSH_KEY_PASSPHRASE" -f ~/.ssh/id_$SSH_KEY_TYPE`（已存在则跳过） | `ssh -V`；密钥存在性 | setup_traps / wait_for_apt_lock / with_retry(3×5s) |
| `net-proxy` | base | 0 | 只管 **shell 环境变量代理**：把 `HTTP_PROXY/HTTPS_PROXY/NO_PROXY` 写入 `~/.bashrc`（标记块检查，幂等） | grep `.bashrc` 含标记块 | setup_traps / register_rollback（备份 .bashrc） |
| `rt-nodejs` | base | 0 | 装 nvm → 加载 nvm.sh → `nvm install --lts` → `nvm alias default node` → 配 npm 镜像 | `node --version && npm --version` | setup_traps / with_retry(curl 3×2s) / run_step_verbose(curl -# / nvm install / nvm-install.sh) / register_tmpfile(/tmp/nvm-install.sh) |
| `rt-log` | base | 1 | 安装日志工具（`lnav bat logrotate`）；journald 持久化 + 限容；logrotate 调优；`oslogs` 别名到 `~/.bashrc` | `lnav --version && bat --version`；`journalctl --disk-usage`；`oslogs` 别名存在 | setup_traps / wait_for_apt_lock / with_retry(3×5s) / register_tmpfile(mktemp) / register_rollback(.bashrc) |
| `rt-screen` | base | 0 | 检测 `gsettings` → 三个键设值（idle-delay=0 / lock-enabled=false / lock idle-delay=0）；**不存在则降级** `xset`；Server 版跳过 | 回读 `gsettings get ...` 或标记 skipped | setup_traps |
| `ai-claude` | nodejs | 0 | `parse_install_args "$@"` 解析 --force；幂等（claude --version 与 $CLAUDE_CODE_VERSION 一致则跳过，提示用 --force 或 -f 强制重装）；装前清理 `prefix/lib/node_modules/$PKG` 旧目录 + `.$pkg-*` npm 拋留临时目录避免 ENOTEMPTY；`npm install -g --loglevel=info --foreground-scripts --no-audit --no-fund --prefer-offline --registry=$NPM_REGISTRY --fetch-timeout=120000 --fetch-retry-maxtimeout=120000 $CLAUDE_CODE_PKG@$CLAUDE_CODE_VERSION` | `claude --version` | setup_traps / parse_install_args / run_step_verbose(npm 进度可见 + 强制镜像) |
| `ai-codex` | nodejs | 0 | 同上（包名 `@openai/codex`，包名含 @scope 临时目录通配按 `pkg_base` 匹配） | `codex --version` | 同上 |
| `ai-opencode` | nodejs | 0 | 同上（包名 `opencode-ai`，注意不是 `opencode`） | `opencode --version` | 同上 |

### proxy / git 边界厘清

- `git config http.proxy` 归入 **git 模块**（它是 git 的配置）。
- **proxy 模块**只负责 shell 环境变量代理（给 npm/curl 等用），不再 `DEPS=git`，改为 `DEPS=base`，消除与 git 的耦合。

依赖链总览：

```
mirrors (deb822 ubuntu.sources → 清华源；换源后 apt update 验证)
  │
  ▼
base ─┬─ git          (含 git 自身代理配置)
      ├─ ssh
      ├─ proxy        (shell 环境变量代理, 不依赖 git)
      ├─ nodejs ─┬─ claude      (runner 先激活 nvm)
      │          ├─ codex
      │          └─ opencode
      ├─ log          (lnav/bat + journald/logrotate)
      └─ screen
```

> 批注：

---

## 十一、固定版本（部分已锁定）

从官方 npm/发布渠道初步核对（2026-08），**实查为准**：

| 包 | 当前值 | 状态 |
|---|---|---|
| `@anthropic-ai/claude-code` | `2.1.228`（2.1.x 稳定线） | 占位，待 `npm view` 实查锁定 |
| `@openai/codex` | `0.147.0` | 占位，待 `npm view` 实查锁定 |
| `opencode-ai` | `1.18.18` | ✅ 已锁定（2026-08-16，`npm view opencode-ai version`） |
| nvm + node LTS 22 | — | 满足三者最低要求 |

> 两个易错点：
> (1) opencode 的 npm 包名是 **`opencode-ai`**，不是 `opencode`；
> (2) codex 另有 `curl https://chatgpt.com/codex/install.sh | sh` 的独立安装器（不依赖 node），但本项目统一走 npm 以保持版本可锁。

> 批注：

---

## 十二、回滚与幂等

### 备份（register_rollback）

- install 前由 `utils.sh:register_rollback <path>` 备份受影响 dotfiles：`cp ~/.bashrc ~/.bashrc.bak.<ts>`，并注册到回滚列表 `_ROLLBACK_PAIRS`。
- 失败时返回非0（不静默吞错，让调用方决定 abort 还是 continue）。
- 备份清单同时落盘 `$LOG_FILE`，便于 `uninstall.sh` 还原或人工恢复。
- 旧函数名 `backup_file` 保留为 `register_rollback` 的转发别名，向后兼容。

### 幂等分两类

| 类型 | 判定方式 | 例子 |
|---|---|---|
| 安装型 | `command -v <bin>` + 版本比较 | node、git、ssh、claude、codex、opencode |
| 配置型 | 读取配置值/标记块是否已存在且符合预期 | `git config --get http.proxy`、`.bashrc` 是否含 `os-config proxy` 标记块、`gsettings get` 当前值、journald `Storage=` 当前值 |

- 配置型幂等：写入前先 grep / get 当前值，已一致则跳过，`--force` 强制重写。
- `uninstall.sh`（可选）：`npm uninstall -g <pkg>`、`git config --global --unset http.proxy`、从 `.bashrc` 删代理行、还原 `.bak`。

> 批注：

---

## 十三、异常处理（A-H 八项，全部已实现）

所有异常处理工具集中在 [lib/utils.sh](file:///home/test/github/os-config/lib/utils.sh) 的「异常处理工具集」段；每个 install.sh 头部调一次 `setup_traps` 即接入。

### 工具函数清单

| 函数 | 对应项 | 作用 |
|---|---|---|
| `register_tmpfile <path>` + `cleanup_tmpfiles` | **A 中断恢复** | 注册临时文件，trap 时自动清理 `/tmp/nvm-install.sh` 等，避免残留 |
| `with_retry <max> <sleep> -- <cmd...>` | **B 网络重试** | 命令重试 N 次（apt 用 3×5s，npm/curl 用 3×2s）；必须用 `--` 分隔参数与命令 |
| `trap_err_handler` | **C 错误定位** | `set -e` 触发时打印「命令 + 行号 + 退出码」，方便定位 |
| `setup_traps` | **A + C 一键** | 注册 EXIT/INT/TERM/ERR 四种 trap；防重复（`_TRAPS_SET` 标志） |
| `register_rollback <file>` | **F + H** | 备份并注册到 `_ROLLBACK_PAIRS`；**失败返回非0**（不静默吞错） |
| `rollback_on_exit <rc>` | **G + H** | trap EXIT 时调用；`rc != 0` 时恢复所有已注册备份到原文件，并提示「请检查失败原因后重跑（--force 可跳过幂等判断）」 |
| `wait_for_apt_lock` | **E apt 锁等待** | 等待 `/var/lib/dpkg/lock` 等释放（最多 60s），避开 unattended-upgrades 占用 |
| runner 内 `_FAIL_LIST` / `_VERIFY_FAIL_LIST` / `_SKIP_LIST` | **D 失败汇总醒目** | 汇总时醒目列出失败/跳过的模块名（`✗ 安装失败的模块：claude codex`） |

### A-H 八项机制对应关系

```
A 中断恢复     → setup_traps 注册 EXIT/INT/TERM trap；register_tmpfile + cleanup_tmpfiles
B 网络重试     → with_retry 包装 curl / npm install / apt install
C 错误定位     → trap_err_handler 打印失败命令 + 行号 + 退出码
D 失败汇总     → runner 维护 _FAIL_LIST/_VERIFY_FAIL_LIST/_SKIP_LIST 三个数组，汇总醒目列出
E apt 锁等待   → wait_for_apt_lock（仅 NEEDS_SUDO 的 apt 模块用）
F 备份失败可控 → register_rollback 失败返回非0，调用方在 set -e 下直接退出，不会继续改原文件
G 半配置清理   → rollback_on_exit 失败时恢复所有已注册备份（包括只改了一半的 .bashrc）
H 简易回滚     → register_rollback + rollback_on_exit 组合，覆盖 install 失败时的 dotfiles 恢复
```

### trap 触发示例（实测）

```
[INFO] 已备份：/tmp/.../.bashrc -> /tmp/.../.bashrc.bak.xxx
[INFO] 故意跑一个会失败的命令...
[ERROR] [test-fail.sh] 命令失败：           ← C 项 trap_err_handler
[ERROR]   命令: false
[ERROR]   行号: 11
[ERROR]   退出码: 1
[ERROR] 脚本失败（rc=1），回滚以下文件到备份：  ← G+H 项 rollback_on_exit
[INFO]   已回滚：/tmp/.../.bashrc <- /tmp/.../.bashrc.bak.xxx
[WARN] 回滚完成。请检查失败原因后重跑（--force 可跳过幂等判断）
```

> 批注：

---

## 十四、verbose 输出与进展可见性

### `run_step_verbose` 函数

[lib/utils.sh](file:///home/test/github/os-config/lib/utils.sh) 提供 `run_step_verbose`，与 `run_step` 同接口，区别：

```bash
run_step_verbose() {
  local desc="$1"; shift
  log_info "  ▸ $desc"
  "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}" >&2   # 同时打终端 + 落盘 LOG_FILE
  local rc=${PIPESTATUS[0]}                          # 取原命令退出码（不被 tee 影响）
  if [[ $rc -eq 0 ]]; then log_ok "  ✓ $desc"; return 0
  else                       log_error "  ✗ $desc (exit=$rc)"; return $rc; fi
}
```

### 接入 npm install（关键）

[ai-claude](file:///home/test/github/os-config/platforms/ubuntu24/modules/ai-claude/install.sh) / [ai-codex](file:///home/test/github/os-config/platforms/ubuntu24/modules/ai-codex/install.sh) / [ai-opencode](file:///home/test/github/os-config/platforms/ubuntu24/modules/ai-opencode/install.sh) 三个 install.sh：

```bash
run_step_verbose "npm install -g $PKG@$VERSION (registry=$NPM_REGISTRY)" \
  npm install -g --loglevel=info --foreground-scripts \
  --no-audit --no-fund --prefer-offline \
  --registry="$NPM_REGISTRY" \
  --fetch-timeout=120000 --fetch-retry-maxtimeout=120000 \
  "$PKG@$VERSION"
```

npm 参数的作用：

- `--loglevel=info`：打印每一步关键事件（fetching / extracting / linking / renamed 等），比默认的 notice 详细。
- `--foreground-scripts`：让 `postinstall` 等 lifecycle 脚本输出到前台（claude-code/opencode 有 postinstall hook，默认会被 npm 吞掉）。
- `--no-audit` / `--no-fund`：跳过冗余 HTTP 请求（约省 1-3s），不打扰用户。
- `--prefer-offline`：优先本地缓存，重跑显著加速（npm 把包缓存到 ~/.npm/_cacache）。
- `--registry="$NPM_REGISTRY"`：**强制**走 `config/versions.env` 里的国内镜像，绕开用户层 `~/.npmrc` 未改/被改回官方源的情况。
- `--fetch-timeout / --fetch-retry-maxtimeout 120000`：拉长超时窗口，配合国内到镜像的偶发抖动。

### 装前清理避免 ENOTEMPTY（关键经验）

`npm install -g` 升级已存在包时，npm 会先把旧目录 rename 成 `.<pkg>-XXXX` 临时目录再替换；若旧目录非空（残留文件 / 上次失败半状态 / npm 自身残留 .tmp 目录），rename 失败报 `ENOTEMPTY`。

三个 ai-* 模块在 `npm install` 前主动清理：

```bash
prefix=$(npm config get prefix)
nm_dir="$prefix/lib/node_modules"
# 1) 清理目标包旧目录（旧版残留）
[[ -d "$nm_dir/$PKG" ]] && rm -rf "$nm_dir/$PKG"
# 2) 清理 npm 上次失败留下的 .<pkg>-* 临时目录
shopt -s nullglob
for d in "$nm_dir"/."$pkg_base"-* "$nm_dir"/."$PKG"-*; do
  [[ -d "$d" ]] && rm -rf "$d"
done
shopt -u nullglob
```

> 注意：包名含 `@scope` 时（如 `@anthropic-ai/claude-code`），目录名是 `@scope/pkg`，
> 通配 `.@scope-pkg-*` 不准，要改用 `pkg_base=${PKG##*/}` 后按 `.$pkg_base-*` 匹配。

### 接入 rt-nodejs 的耗时命令

- `curl` 下载 nvm 安装脚本：`-fL#` 显示进度条（替代默认 `-s` 静默），用 `run_step_verbose` 包装。
- `bash /tmp/nvm-install.sh`：用 `run_step_verbose`，nvm 安装脚本的 git clone / nvm.sh / bash_completion 输出可见。
- `nvm install --lts`：用 `run_step_verbose`，node 二进制下载/解压进度可见。

### 效果

跑实际安装时，npm 自身的 fetch/extract/link 输出实时刷新到终端，结束后这些日志在 `logs/setup-*.log` 里也能查（因为 `tee -a LOG_FILE`）。

> 批注：

---

## 十五、自测方案

呼应「确保能正常运行」：

1. **静态检查**：`bash -n` 全部脚本 + `shellcheck -x` 看新增警告（SC1090/SC1091 source 警告可忽略）。
2. **grep 验收**：
   - `setup_traps` 出现在 10 个 install.sh
   - `with_retry` 出现在 8 个 install.sh（apt / npm / curl 模块；net-proxy / rt-screen 例外）
   - `wait_for_apt_lock` 出现在 4 个 apt install.sh
   - `register_tmpfile` 出现在 2 个 install.sh（rt-nodejs / rt-log）
3. **dry-run**：`./setup.sh --all --dry-run` 必须显示 10 模块依赖拓扑展开 + 计划打印全过。
4. **隔离 HOME 实测**（不污染真实环境）：
   ```bash
   TMPHOME=$(mktemp -d); cp ~/.bashrc "$TMPHOME/.bashrc"
   HOME="$TMPHOME" ./setup.sh --module proxy --no-sudo
   ```
5. **失败回滚实测**（关键）：跑一个故意 `false` 失败的脚本，验证：
   - trap ERR 打印「命令 / 行号 / 退出码」
   - rollback_on_exit 把 `.bashrc` 恢复到原状（grep proxy 块 = 0）
   - 备份文件存在
6. **容器化全流程自测**（关键）：用 docker 跑全流程，干净环境复现新机初始化。
   ```bash
   # 干跑看计划
   docker run --rm -v "$PWD:/os" -w /os ubuntu:24.04 \
     bash -lc 'apt-get update && apt-get install -y sudo bash && ./setup.sh --list --dry-run'
   # 全流程实跑（容器内模拟普通用户 + sudo 免密）
   docker run --rm -v "$PWD:/os" -w /os ubuntu:24.04 \
     bash -lc 'apt-get update && apt-get install -y sudo bash && \
               useradd -m test && echo "test ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
               su - test -c "cd /os && ./setup.sh --all"'
   ```
7. **每模块 verify**：install 后自动跑 `verify.sh`，失败即视为模块未通过。
8. 失败可 `docker run ... ./setup.sh --module <x> --force` 单模块复现排错。
9. **npm 进展可见性**：跑 ai-* 模块时终端应实时显示 npm 的 fetch/extract/link 输出，LOG_FILE 中也有完整记录。

> 批注：

---

## 十六、其它实现细节

- **日志脱敏**：`lib/log.sh` 对匹配 `(sk-|token|password|passphrase)=` 的值打码后再落盘。
- **代理模块**：只设 shell 环境变量代理，不安装代理软件；端口走 `user.env` 可改。
- **失败处理**：默认遇错停（`set -e`），`--keep-going` 跑完全部再汇总；失败模块名醒目列出。
- **可扩展**：新增平台只需加 `platforms/<新平台>/detect.sh + modules/`，主脚本零改动。
- **每个模块都有 README.md**：30-64 行，包含前置依赖 / 逐条安装步骤 / 验证项 / 可配置参数表 / 幂等行为 / 本模块接入的异常处理 / 用法示例。

> 批注：

---

## 十七、待确认 / 下一步

### 已完成
- [x] 按设计结构 scaffold 出全部骨架（入口 + lib + config + 各模块三件套 + README.md）
- [x] 实现 10 个 ubuntu24 模块的 install.sh + verify.sh（mirrors/base/git/proxy/ssh/nodejs/log/screen/claude/codex/opencode）
- [x] nvm PATH 注入机制（runner 在 ai-* 前自动 source nvm + nvm use default）
- [x] 异常处理 A-H 八项全部接入并实测生效
- [x] verbose 输出：npm --loglevel=info --foreground-scripts / curl -# / nvm install / run_step_verbose 落盘
- [x] 每个模块 README.md（10 个）
- [x] `lib/utils.sh` 新增 `load_user_config`（utils.sh 被 source 时自动加载 versions.env + user.env，幂等）+ `parse_install_args`（解析 --force/-f/--debug/--help）
- [x] 三个 ai-* install.sh 接入 `parse_install_args "$@"`，支持直接 `./install.sh --force`
- [x] ai-* 模块 npm install 加速参数（--no-audit/--no-fund/--prefer-offline/--fetch-timeout）+ `--registry=$NPM_REGISTRY` 强制镜像
- [x] ai-* 模块装前清理 `prefix/lib/node_modules/<pkg>` 旧目录 + `.<pkg>-*` 临时目录，避免 ENOTEMPTY
- [x] 三个 ai-* 模块幂等提示统一为「用 --force 或 -f 强制重装」
- [x] `config/versions.env` 锁定 OPENCODE_VERSION=1.18.18
- [x] `.gitignore`：忽略 logs/、*.bak.*、config/user.env、*.tmp、IDE/系统杂项

### 待做
- [ ] 把 `versions.env` 中 `CLAUDE_CODE_VERSION` / `CODEX_VERSION` 按「版本锁定流程」实查锁定（OPENCODE 已锁）
- [ ] git commit 全部成果
- [ ] docker 容器化全流程自测（环境没 docker，需提供或换路径）
- [ ] 其它平台实现（ubuntu22/macos/arch）—— 需要时再扩展

> 批注：

---

## 批注区

> 在此处集中记录你的批注，也可在对应小节行内添加 `> 批注：…`。
