# os-config 项目设计

> 状态：v6（2026-08-17）。平台按操作系统族分类；当前实现 Ubuntu 22.04/24.04。本文以仓库现有代码为准。

## 一、目标和边界

`os-config` 用一个入口完成开发环境初始化：

1. 识别平台。
2. 加载版本配置和用户配置。
3. 读取模块元数据并校验。
4. 根据依赖进行拓扑排序。
5. 对每个模块执行 `install.sh` 和 `verify.sh`。
6. 汇总成功、失败、验证失败、跳过和 blocked 状态。

当前只实现 `ubuntu`，Ubuntu 22.04 与 24.04 共用该平台目录。`windows`、`macos`、`kylin` 是按操作系统族预留的扩展目录；没有 `modules/*/module.conf` 的占位平台会被入口明确拒绝。CPU 架构不作为平台目录。

## 二、目录结构

```text
setup.sh
lib/
  log.sh
  platform.sh
  runner.sh
  utils.sh
config/
  modules.conf
  versions.env
  user.env.example
platforms/
  ubuntu/
    detect.sh
    modules/<category>-<name>/
      module.conf
      install.sh
      verify.sh
      README.md
  windows/
  macos/
  kylin/
tests/run.sh
```

平台一级目录按操作系统族划分。`SYSTEM_ARCH` 单独记录 CPU 架构（如 `amd64`、`arm64`），不参与平台目录选择。

模块目录前缀只用于分类：

- `sys-`：系统基础与系统配置；
- `net-`：网络与连接工具；
- `rt-`：runtime，运行环境与运行期辅助工具；
- `ai-`：AI 开发工具。

目录前缀不属于模块名。模块引用和命令行参数始终使用 `module.conf` 中的 `NAME`，例如目录 `rt-log` 的模块名是 `log`，运行命令是 `./setup.sh --module log`。

## 三、模块契约

### `module.conf`

```ini
NAME=nodejs
DESC=通过 nvm 安装 Node.js
DEPS=base
NEEDS_SUDO=0
```

runner 会校验：

- `NAME` 必须匹配 `[a-zA-Z0-9_-]+`；
- `NAME` 不能重复；
- `NEEDS_SUDO` 只能是 `0` 或 `1`；
- 依赖名必须合法，拓扑排序时必须能找到；
- 循环依赖会直接报错。

加载顺序保存在 `_M_ORDER`，因此 `--all` 不依赖关联数组的随机键顺序。`--list` 会展示 `DESC`。

### `install.sh`

安装脚本应：

```bash
set -euo pipefail
: "${PROJECT_DIR:=...}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"
setup_traps
parse_install_args "$@"
```

系统级操作使用 sudo；用户目录、nvm、npm 和 Git 用户配置不用 sudo。修改文件前使用：

```bash
register_rollback "$HOME/.bashrc"
register_rollback /etc/example.conf sudo
```

### `verify.sh`

验证脚本只检查状态，不负责修复；退出码 `0` 表示通过，非零表示失败。配置明确禁用的可选功能应按 skipped 通过，而不是误报缺失。

## 四、入口参数

`setup.sh` 支持：

- `--module a,b`
- `--all`
- `--list`
- `--dry-run`
- `--install-only`
- `--verify-only`
- `--force`
- `--keep-going`
- `--no-sudo`
- `--platform ubuntu`
- `--debug`

参数约束：

- `--install-only` 与 `--verify-only` 冲突；
- `--all` 与 `--module` 冲突；
- `--module`、`--platform` 必须有值；
- 平台名和模块名会做格式检查。

## 五、runner 状态模型

每个模块可能处于：

- `ok`：安装和需要的验证均通过；
- `failed`：安装、验证或 sudo 前置检查失败；
- `skipped`：例如被 `--no-sudo` 跳过；
- `blocked`：至少一个依赖不是 `ok`。

默认遇错停止。`--keep-going` 时：

- 失败模块之后的无关模块继续；
- 依赖失败/跳过的下游模块标记 blocked；
- 全部跑完后，只要安装或验证出现失败，runner 最终返回非零。

## 六、平台识别

`lib/platform.sh` 读取 `/etc/os-release`，将发行版版本映射到操作系统族：

```text
ubuntu/22.04 -> ubuntu
ubuntu/24.04 -> ubuntu
```

`detect_architecture` 通过 `uname -m` 单独归一化 CPU 架构，并由 `setup.sh` 导出为 `SYSTEM_ARCH`。例如 `x86_64 -> amd64`、`aarch64 -> arm64`。因此版本号和 CPU 架构都不会成为 `platforms/` 的一级目录。

识别到尚未验证的 Ubuntu 版本或尚未实现的麒麟系统时，会明确报错，不返回虚假的可用平台。`--platform` 可用于测试，但已实现平台自己的 `detect.sh` 仍会做双重检查并告警。测试可通过 `OS_RELEASE_FILE` 指定临时 os-release 文件。

## 七、权限策略

`NEEDS_SUDO=1` 模块运行前调用 `require_sudo`：

1. 优先尝试 `sudo -n true`，不弹提示；
2. 如果当前是交互终端，执行 `sudo -v` 获取凭据；
3. 非交互环境没有凭据时失败，并提示预先执行 `sudo -v`；
4. `--no-sudo` 会跳过特权模块。

apt/dpkg 操作前使用 `wait_for_apt_lock`，锁等待失败必须向上传播，不能静默继续。

## 八、配置文件

### `config/user.env`

推荐从示例复制：

```bash
cp config/user.env.example config/user.env
```

关键默认值：

```bash
APT_UPGRADE=false

MIRROR_SKIP_APT=false
MIRROR_SKIP_APT_UPDATE=false

PROXY_ENABLED=true
PROXY_HOST=
PROXY_PORT=
PROXY_TEST_URL=https://github.com
PROXY_CONNECT_TIMEOUT=5
PROXY_MAX_TIME=15
NO_PROXY=localhost,127.0.0.1,::1

GIT_USER_NAME=
GIT_USER_EMAIL=
# 任一身份字段为空时输出 warning、跳过对应配置，并提示手动执行的 git config --global 命令。

# 例如当前 IPv4 为 192.168.114.147，留空的 PROXY_HOST 会解析为
# 192.168.114.1；PROXY_PORT 会解析为 7890。设置 PROXY_ENABLED=false 可关闭。
# 安装和验证阶段都会 ping 代理主机；verify 还会使用 curl -x 通过代理访问 PROXY_TEST_URL。

SSH_INSTALL_SERVER=false
SSH_KEY_TYPE=ed25519
SSH_KEY_PASSPHRASE=

JOURNALD_MAX_USE=200M
```

安全说明：`user.env` 是普通 shell 配置文件。`SSH_KEY_PASSPHRASE` 若填写，会以明文存在；文件已被 `.gitignore` 忽略，但仍应控制本地权限。

代理解析和检查统一由 `lib/utils.sh` 提供：

1. `PROXY_HOST` 为空时，优先解析 `ip -4 route get 1.1.1.1` 的 `src`；失败时取 `hostname -I` 的首个非 loopback IPv4。
2. 严格校验 IPv4 后，只把最后一段替换为 `1`；不会读取并采用路由输出中的真实 `via` 网关。
3. `PROXY_PORT` 为空时取 `7890`；显式 host/port 会覆盖自动值。
4. 安装和 verify 都执行一次 `ping -n -c 1 -W 2`。ping 失败会停止对应代理操作，并按顺序提示检查本机 IP/网卡、路由和代理主机防火墙。
5. verify 随后执行 `curl -x "$RESOLVED_PROXY_URL" "$PROXY_TEST_URL"`；默认访问 `https://github.com`，连接超时 5 秒、总超时 15 秒。该步骤真实验证代理 TCP 端口、HTTPS CONNECT、TLS 和目标站点访问。
6. curl 失败时提示检查代理程序监听端口、代理主机防火墙以及 HTTPS CONNECT 权限。
6. `GIT_USER_NAME`、`GIT_USER_EMAIL` 分别独立处理，空值只输出 warning，不清除已有 Git 全局身份。

### `config/versions.env`

```bash
NVM_VERSION=v0.40.1
NODE_LTS_MAJOR=22
NODE_VERSION=
NPM_REGISTRY=https://registry.npmmirror.com
```

`NODE_VERSION` 非空时锁定完整 Node 版本；为空时解析 `NODE_LTS_MAJOR` 指定主版本下的远端版本。AI CLI 包名和完整版本也集中在此文件。

## 九、模块设计摘要

| NAME | DEPS | sudo | 关键行为 |
|---|---|---:|---|
| mirrors | — | 1 | 修正 deb822/legacy APT 源，按架构选择 archive/ports 镜像，验证不存在海外 Ubuntu 源 |
| base | mirrors | 1 | apt update、安装基础包（含 `iputils-ping`）；只有 `APT_UPGRADE=true` 才全量升级 |
| git | base | 1 | 安装 Git；身份为空时 warning 后跳过；自动推导代理，ping 后配置，并在 verify 中用 curl 访问 GitHub |
| ssh | base | 1 | 默认只装客户端；服务端由 `SSH_INSTALL_SERVER` 控制 |
| proxy | base | 0 | 默认启用；host 留空时把当前 IPv4 最后一段改为 1，port 留空时取 7890；ping 后安全写入 `.bashrc`，verify 用 curl 验证真实代理访问 |
| nodejs | base | 0 | 使用 nvm 安装指定主版本或完整版本，并设为 default |
| log | base | 1 | journald drop-in、移除旧版宽泛 logrotate 规则、debug 校验、oslogs 别名 |
| screen | base | 0 | GNOME 验证 idle/lock/screensaver 三项；X11 验证 saver、DPMS、blanking |
| claude/codex/opencode | nodejs | 0 | 固定版本 npm 全局安装、nvm default 优先、自检绝对命令路径 |

依赖图：

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

## 十、日志

`lib/log.sh` 同时输出终端和日志文件：

- 日志目录尽量设为 `700`；
- 日志文件尽量设为 `600`；
- 即使调用方预先注入 `LOG_FILE`，也会创建目录和文件；
- 落盘前脱敏 token/password/api key、Bearer Authorization、URL 用户名密码；
- 终端仍保留命令原始输出，便于观察 npm/curl 进度。

`run_step_verbose` 在 `set -e -o pipefail` 下使用条件管道读取 `PIPESTATUS[0]`，确保返回原命令退出码而不是 `tee` 的退出码。

## 十一、备份与回滚

`register_rollback <file> [user|sudo]` 支持两类状态：

1. 原文件存在：创建 `.bak.<timestamp>.<pid>`，失败时恢复；
2. 原文件不存在：记录为本次新建，失败时删除。

用户文件用普通 `cp/rm`，系统文件用 `sudo cp/rm`。`_ROLLBACK_DONE` 防止 signal trap 和 EXIT trap 重复执行。runner 通过 `${LOG_FILE}.backups` manifest 汇总子进程创建的备份。

## 十二、npm ENOTEMPTY 修复

AI CLI 安装不再在安装前删除正式包目录：

1. 首次正常执行 `npm install -g`；
2. 捕获权限为 `600` 的原始输出；
3. 只有输出包含 `ENOTEMPTY` 时，才查询 npm prefix；
4. 只删除 `.<package>-*` 隐藏 rename 残留；
5. scoped 包按 `@scope/.package-*` 处理；
6. 重试一次。

普通失败保留原退出码，正式包目录不会被定向清理逻辑删除。

## 十三、journald 与 logrotate

journald 使用：

```text
/etc/systemd/journald.conf.d/99-os-config.conf
```

而不是直接 `sed /etc/systemd/journald.conf`。写入后 `systemctl restart systemd-journald` 必须成功，否则回滚。

旧实现创建的 `/etc/logrotate.d/99-os-config` 覆盖 `/var/log/*.log`，可能与系统包规则重复；新实现会备份后移除该受管文件，并使用：

```bash
sudo logrotate --debug /etc/logrotate.conf
```

做只读验证。

## 十四、测试策略

运行：

```bash
./tests/run.sh
```

测试不依赖 Bats，也不会修改宿主 `/etc`。当前覆盖：

- 全部 Shell 文件 `bash -n` 和 `git diff --check`；
- setup 参数缺值和冲突；
- Ubuntu 22.04/24.04 操作系统族映射和 CPU 架构独立识别；
- Ubuntu 全模块 dry-run，并验证未实现的占位平台会被拒绝；
- keep-going、blocked 和最终返回码；
- module.conf 重名校验；
- verbose 返回码、日志脱敏、权限；
- 用户文件回滚和 fake-sudo 新文件回滚；
- npm 成功、普通失败、ENOTEMPTY scoped 包修复；
- Git 身份为空时的 warning，以及代理 host 自动推导、默认端口 7890、ping 连通性、`curl -x` 访问 GitHub、失败诊断、安全 shell quoting 和 verify。

真实 APT、systemd、网络下载仍建议分别在干净的 Ubuntu 22.04 和 24.04 虚拟机或容器中做集成测试。

## 十五、扩展新平台

新增平台需要：

1. 以操作系统族创建 `platforms/<platform>/detect.sh`，例如 `windows`、`macos`、`ubuntu`、`kylin`；
2. 创建 `modules/` 和模块三件套；
3. 在 `detect_platform` 中增加发行版到操作系统族的精确映射；CPU 架构差异放在模块内部处理；
4. 为新平台增加 dry-run 和集成测试。

不要让平台识别函数返回尚未实现的目录名。
