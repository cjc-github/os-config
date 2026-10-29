# os-config 功能清单（支持项）

> 本文只列**当前已实现**的能力，不包含规划与缺口。两个引擎共用同一份 `catalog/`
> 与 `profiles/` 数据，行为逐函数对应；能力按平台标注：
> **[双]** = Bash 与 Windows 两端都有，**[Linux]** / **[Windows]** = 平台专属。
>
> 现状：Bash 引擎覆盖 Ubuntu 22.04/24.04（amd64/arm64 自动区分镜像源）；
> Windows 引擎覆盖 Windows 10/11（PowerShell 5.1+）。

## 一、入口与动词

| 能力 | 平台 |
|---|---|
| 七个动词：`install` / `update` / `remove` / `verify` / `status` / `export` / `doctor` | [双] |
| 选择方式三选一：`--profile <名字>` / `--pick <a,b,@组,backend:包>` / `--all` | [双] |
| `--pick` 内联写法：`@分组` 与 `backend:包`（如 `winget:Git.Git`、`apt:jq`） | [双] |
| `--list` 人类可读目录；`--list --json` 机器可读（供 Web UI 消费） | [双] |
| `--dry-run` 只打印计划，不碰盘、不写清单 | [双] |
| `--force` 忽略幂等判断强制重做 | [双] |
| `verify --fix`：校验未通过时自动 apply 修复后复验，复验不过判失败 | [双] |
| `--keep-going`：单项失败不中断，跑完汇总并保留成功项（不触发整体回滚） | [双] |
| `--yes` 非交互确认；`--debug` 调试日志；`-h`/`--help` | [双] |
| `export --output <路径>` 指定导出位置 | [双] |
| 提权开关：`--no-sudo`（Linux）/ `--no-elevate`（Windows，接受 `--no-sudo` 别名） | [双] |
| 退出码约定：0 成功；1 有失败项；2 参数或数据错误；100 = skipped（不进退出码） | [双] |

## 二、数据层（catalog 与 profile）

- **catalog 条目字段** [双]：`type`、`backend`、`packages`、`version`、`commands`、`track`、`deps`、`desc`、`group`、`action`、`artifacts`、`sudo`
- **跨平台字段** [双]：`platforms`（`linux`/`win`/`linux,win`，缺省 `linux`）、`win_backend`、`win_packages`、`win_commands`、`win_version`、`win_artifacts`、`win_deps`、`win_action`
- **104 个工具/动作条目**，15 个分组：`core`/`transfer`/`archive`/`network`/`system`/`editor`/`development`/`config`/`runtime`/`ai`/`security`/`remote`/`netutil`/`systool`/`devtool`
- **profile 机制** [双]：`extends` 继承、`@分组` 展开、`backend:包` 内联、token 去重；内置 `minimal`/`ai`/`default`/`dev` 四份
- **配置分层** [双]：`config/versions.env` → `config/user.env` →（Web UI 场景）`config/ui.env`，后者覆盖前者
- **变量展开** [双]：`$VAR`、`${VAR}`、`${VAR:-默认值}`；`desc`/`group`/`artifacts` 不做展开（避免二次解释）
- **数据校验** [双]：标识符合法性、包名安全（禁空白与前导 `-`）、backend 白名单、`track=pin` 必须有 `version`、`deps` 必须已定义；拒绝键重复、段前键值、未知字段、循环继承
- **平台门** [双]：条目 `platforms` 不含当前平台时打印“不适用于当前平台”后跳过；Linux 专属条目（mirrors/syslog/nosuspend 等）在 Windows 上自动跳过

## 三、引擎编排

- **依赖闭包与拓扑排序** [双]：选中项的依赖一并纳入，依赖优先
- **remove 逆序** [双]：被依赖者先删，并提示连带依赖方与选集外已安装的依赖方
- **幂等** [双]：写入前比对现值，已是目标值则跳过
- **dry-run 门** [双]：在任何后端/动作代码之前短路
- **失败回滚** [双]：文件改动（存在的从备份还原、新建的删除）与 state 清单快照一起回滚；`verify` 失败不回滚文件；`--keep-going` 失败保留改动
- **并发写锁** [双]：pid 目录锁；残留锁（pid 已死）清理后重试；pid 文件缺失/为空永不回收；只释放自己持有的锁；只读运行不碰他人快照
- **结构化事件** [双]：JSONL 事件流（`run_start`/`item_start`/`item_end`/`run_end`/`rollback`），两端字段名与顺序一致，同一解析器可消费
- **日志** [双]：终端 + 文件双写；凭据脱敏（key=value、sk-/gh* 令牌、Bearer、URL 凭据）；日志不可写时降级为仅终端
- **重试** [双]：固定间隔重试（安装类操作）
- **提权** [双]：sudo 预授权（Linux）/ UAC 提权重跑自身并透传退出码（Windows）；非交互且无权限时明确报错不挂住
- **export 动词** [双]：扫描本机已装工具与已应用配置，生成可被两端解析器读回的 profile；空结果返回非零且不写文件

## 四、包管理后端

| 后端 | 平台 | 能力 |
|---|---|---|
| apt | [Linux] | 五动词、版本 pin、安装前/后状态判定 |
| snap | [Linux] | 五动词、update 补装缺失包 |
| npm | [双] | 全局安装/卸载、版本 pin、registry 配置、安装后命令自检（`--version` 有输出）、ENOTEMPTY 定向清理并重试一次 |
| winget | [Windows] | 已装判定（退出码 0/20 + 表格解析，兼容两种表格布局）、`--exact`/`--version`/`--scope user`、user 域失败自动回退 machine 域、全量查询一次建立内存索引 |
| builtin | [Windows] | 系统自带条目（CA 证书、OpenSSH、ping/nslookup/netstat/tracert 等），“无需安装/无法由本工具卸载” |

## 五、配置动作

| 动作 | 平台 | 能力 |
|---|---|---|
| proxy | [双] | 从本机 IPv4 推导代理地址（末段换 1，可显式指定 host/port）、BEGIN/END 托管块写入（`~/.bashrc` / `$PROFILE`）、整块字符串幂等比对、curl 经代理真实访问验证、`PROXY_ENABLED=false` 时要求无残留块 |
| git | [双] | `user.name`/`user.email` 配置（留空则提示手工命令）、`http.proxy`/`https.proxy` 代理键、原值备份（空值=原本未设置）、remove 只还原代理键不碰身份、部分失败保留记录 |
| ssh | [双] | ed25519/rsa 密钥生成、passphrase 支持、`created.txt` 跟踪只删本动作创建的密钥、私钥权限校验（NTFS ACL / 600 模式）、`~/.ssh` 从不删除 |
| nodejs | [双] | 版本管理器安装（nvm / fnm）、`NODE_LTS_MAJOR` 取大版最新或 `NODE_VERSION` 精确 pin、npm 6 键镜像配置（registry/audit/fund/prefer-offline/fetch-timeout/fetch-retry-maxtimeout）、shell 环境托管块、remove 按原值还原并清理托管块 |
| mirrors | [Linux] | APT 源切换（amd64/i386 与 arm64/riscv64/ppc64el 自动区分主源与 ports 源）、转义安全的替换、`MIRROR_SKIP_APT`/`MIRROR_SKIP_APT_UPDATE`/`APT_UPGRADE` 开关、备份还原 |
| syslog | [Linux] | journald 限容 drop-in、`oslogs` 别名、bat 软链、只删自己创建的软链、缺结束标记时拒绝删除 |
| nosuspend | [Linux] | 关闭桌面息屏与自动锁屏、还原用户原值 |

## 六、doctor 环境体检（只读）

- **Bash 10 项** [Linux]：catalog 数据层、profiles 清单、sudo 提权、磁盘剩余、apt 锁占用、基础命令、APT 镜像可达性、代理连通性、清单与磁盘一致性、state 目录权限
- **Windows 9 项** [Windows]：catalog 数据层、profiles 清单、提权身份、磁盘剩余、基础命令（curl/git）、winget 可用性与版本、代理连通性、清单与磁盘一致性、state 目录
- 单项失败不中断序列；汇总“通过/需关注/未通过”，仅未通过项影响退出码

## 七、Web UI

- 启动器双平台：`ui.sh`（Linux）/ `ui.ps1`（Windows 原生）；服务端按平台自动
  选择引擎（Windows 上跑 `setup.ps1`，其余跑 `setup.sh`），上层无需区分
- 只监听本机（127.0.0.1/localhost），每次启动生成一次性 token；未带 token 的请求一律 401
- catalog 浏览：分组展示、每组标题右侧「全选/全不选」一键切换（只作用于当前搜索过滤后可见的条目）、搜索/过滤、按条目勾选
- profile 预设一键填入；adhoc 内联条目（`backend:包`）添加与校验
- 参数面板：配置项实时编辑、密钥类字段一键清除开关；改动写入 `config/ui.env`（权限 0600）
- 计划预览：dry-run 结果渲染（将执行的动作与顺序）
- 执行与观测：实时事件流、按工具分组的日志区、日志复制/下载、按工具与阶段定位日志
- 结果表：每项状态（ok/planned/skipped/failed）汇总；失败时展示回滚横幅
- 卸载流程：已装列表 + 确认弹窗后执行 remove
- 状态与历史：当前状态/已装视图、历史运行记录与日志回放
- sudo 预授权与可用性检查（Linux；Windows 无 sudo 预授权概念，徽标自动隐藏，提权由引擎在需要时走 UAC）

## 八、测试与自测

- 不依赖外部框架的回归套件：catalog 解析/校验、profile 继承与解析、依赖闭包、state 清单与锁、rollback、util（代理/重试/校验）、三个后端适配器（全部 fake）、引擎五动词编排、动作脚本接口与行为、并发锁、export、doctor、入口参数
- Windows 引擎用例（有 PowerShell 才跑，否则记跳过）：导出的 profile 读回、别名探测、list --json 的 artifacts 展开、rollback 事件、catalog 校验报错、config 动作分派、空口令 ssh-keygen（含沙箱 HOME 全生命周期）、原生调用空参数、winget 安装入参、winget 索引按表头解析、npm ENOTEMPTY 重试、proxy/git/nodejs 三动作全生命周期、非交互提权明确报错
- 安装后端用函数遮蔽记录真实入参（`global:winget.exe` / `global:npm`），不真的装任何软件
- Web UI 服务端用例（Python unittest）与前端用例（node --test）
- 平台跳过：断言 POSIX 权限位/符号链接/原生 python3·node 的用例在 MSYS 下记 skip 并单独计数
- 过滤按显示名或用例函数名；匹配不到任何用例时返回非零（不会“跑了 0 个却显示通过”）
- CI：ubuntu 跑全套 + 服务端 + 前端；windows 跑 Windows 引擎用例
- 测试全程在临时目录中进行：`HOME`/`STATE_DIR`/`PATH` 重定向，`apt-get`/`snap`/`npm`/`sudo`/`fuser`/`ping`/`ip`/`ssh-keygen` 均为 fake，不改动宿主机配置
