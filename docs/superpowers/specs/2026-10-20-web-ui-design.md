# os-config Web UI 设计

日期：2026-10-20
状态：已与用户对齐，待实现

## 1. 背景

`os-config` 目前是纯 Bash 的声明式环境初始化工具：`catalog/*.catalog` 声明工具，
`profiles/*.conf` 声明选择，`setup.sh` 用 `install/update/remove/verify/status`
五个动词执行。

使用门槛在于：重装机器或补装工具时，用户需要记住 profile 名称、工具 id 和
`config/user.env` 中的参数名，再在终端里敲命令、盯着滚动输出判断哪一项失败。

本项目为它增加一个本机 Web 界面：打开页面先看到一份可编辑的基础清单，
勾选工具、填写参数，点「完成」后在这台机器上执行，日志实时滚动，并逐项显示
成功/失败。

## 2. 目标

- 新机器：打开页面，选 profile 预设或逐项勾选，点一次完成即可跑完整套初始化。
- 旧机器：延续上次选择，快速补装；修改参数后重新 apply；显式卸载不再需要的项。
- 用户能清楚看到：将要执行什么（含自动补齐的依赖）、正在执行什么、每一项的结果。
- Web UI 只是 `setup.sh` 的外壳。依赖解析、sudo、幂等、回滚、日志脱敏全部复用
  现有引擎，不在 Python/JS 中重写任何安装逻辑。

## 3. 非目标 / 反目标

- 不支持远程机器；只管理运行 UI 的这台机器。
- 不支持 Windows（现有 PowerShell 引擎尚未实现）。
- 不支持并发运行（同一时刻只允许一个 UI 触发的 install/remove/verify 任务）。
  终端里另行运行 `setup.sh` 不在锁的保护范围内，这是 v1 的已知限制。
- 不改造后端 `status` 的文本输出；「是否已安装」统一用只读的 `verify` 动词判定。
- v1 不提供「取消正在执行的任务」。中途取消涉及回滚语义，风险高，留到后续版本。
- 不在页面里编辑 `catalog/*.catalog` 或 `profiles/*.conf` 的定义。
  允许临时添加 `apt:包名` / `npm:包名` / `snap:包名`（引擎已支持）。
- 不把 sudo 密码送进浏览器。
- v1 不做 `update` 动词。
- 不引入前端框架、构建步骤或第三方 Python 依赖。

## 4. 关键决策

### D1. 取消勾选 ≠ 卸载
取消勾选只表示「本次不处理」。卸载是独立入口，需要用户显式选择并二次确认，
确认框列出将被还原/删除的产物。理由：破坏性操作不能藏在取消勾选后面。

### D2. v1 动词范围
页面的主要动作是 `install`；执行结束可自动 `verify`；第二入口是 `remove`。
`update` 不做。

### D3. 基础清单的默认值
优先读取上次保存的选择（`state/ui/selection.json`）；没有则解析 `default`
profile。顶部提供 minimal / default / dev / ai 预设一键载入。

### D4. 依赖自动补齐且可见
勾选 `git` 会自动带上 `git-cli`。界面对自动加入项标注「依赖自动加入」，
并展示依赖来源。执行计划以引擎 dry-run 的结果为准，前端推断仅用于即时反馈。

### D5. 参数只显示相关项（只暴露引擎真正消费的参数）
按已选工具映射参数组：

| 工具 id | 参数 |
|---|---|
| mirrors | `MIRROR_APT_URL`, `MIRROR_APT_PORTS_URL` |
| proxy | `PROXY_ENABLED`, `PROXY_HOST`, `PROXY_PORT` |
| git | `GIT_USER_NAME`, `GIT_USER_EMAIL`；选中时提示「代理由 proxy 参数复用」 |
| ssh | `SSH_KEY_TYPE`, `SSH_KEY_PASSPHRASE` |
| syslog | `JOURNALD_MAX_USE` |
| nodejs / ai | `NODE_VERSION`, `NODE_LTS_MAJOR`, `NPM_REGISTRY` |

当前引擎未消费的参数（`APT_UPGRADE`、`MIRROR_SKIP_APT`、
`MIRROR_SKIP_APT_UPDATE`、`PROXY_TEST_URL`、`PROXY_CONNECT_TIMEOUT`、
`PROXY_MAX_TIME`、`NO_PROXY`、`SSH_INSTALL_SERVER`）不进入 UI，避免出现
「能改但无效」的控件。`openssh-server` 作为普通 catalog 工具直接勾选。

未选中的工具不显示其参数。空值展示引擎默认推导规则（例如代理地址留空时的
自动推导），而不是自行填死默认值。

### D6. 参数写入独立的 `config/ui.env`，并区分「未设置 / 显式空 / 有值」
新增 `config/ui.env`，由引擎在 `config/user.env` 之后加载（后加载覆盖前者）。
UI 每次执行前生成该文件，旧版本备份到 `state/ui/env-backups/`。
不修改用户手写的 `config/user.env`。`config/ui.env` 加入 `.gitignore`。

- 只写入用户在界面中实际改动过的键。未改动的键不出现在 `ui.env` 中，
  因此不会遮蔽 `user.env` 里手写的值。
- 三种状态：未设置（省略该键，继承 user.env / 引擎默认）、显式空（写
  `KEY=`）、有值（写 `KEY='value'`）。
- 参数面板的回显优先级：`ui.env` > `user.env` > 空/默认提示。
- 「恢复默认」= 从 `ui.env` 删除该键，重新继承。
- 密码类参数（`SSH_KEY_PASSPHRASE`）不回显已保存值；未触碰则省略，
  另有显式「清除已保存口令」开关用于写入空值。

### D7. sudo 在终端授权
`./ui.sh` 启动时在终端执行 `sudo -v`（可跳过），并由后台保活循环定期
`sudo -n -v` 续期；服务退出时停止循环。浏览器端只查询
`sudo -n true` 是否成功，并在未授权时提示用户回终端执行 `sudo -v`。
密码不经过 HTTP。

### D8. 后端与访问范围
- Python 3 标准库（Ubuntu 自带 3.10），无第三方依赖。
- 只监听 `127.0.0.1`，默认端口 `8765`，可通过 `--port` 改。
- 启动时生成随机 token（`secrets.token_urlsafe`）。所有 `/api/*` 请求和 SSE
  必须携带 token；启动后自动打开浏览器并附带 token。
- 同一时刻只允许一个执行任务，用文件锁 + 内存状态双重保护。

### D9. 执行后自动 verify（可关）
`install` 正常结束后，对同一选择再执行一次 `verify`，结果映射回每一行。
apply 成功不等于配置生效，verify 才是引擎定义的校验。界面提供开关，默认开启。
`remove` 后不自动 verify。

### D10. 运行记录
当前任务实时输出；结束后可从 `state/ui/runs/<run_id>/` 浏览历史（只读，
`meta.json`、`run.log`、`events.jsonl` 均由引擎或服务端生成并已脱敏）。

### D11. 失败处理策略
执行默认带 `--keep-going`（界面上是默认勾选、可关闭的选项）：
- 开启：单项失败后继续，保留成功项，最后汇总失败项。
- 关闭：沿用引擎默认行为，首个失败触发回滚。
界面必须写明两种模式的差异，不能静默替用户选择。

### D12. 结果判定来源
不解析人类可读日志来判断每项结果。引擎通过事件文件输出结构化记录，
UI 以事件为准，日志只用于展示。
理由：日志格式是给人看的，未来会变；事件是稳定接口。

### D13. 临时包的保存与校验
`state/ui/selection.json` 分开保存：
- `tools`：catalog 工具 id 列表（或从 profile 展开的结果）
- `adhoc`：用户临时输入的原始 token，例如 `apt:jq`、`npm:@scope/pkg`

回放时把两者拼成 `--pick`，不能只存解析后的 id（否则 `apt:jq` 会变成
catalog 里不存在的 `jq`）。提交前在服务端做：
- 宽松的包名正则：`^(apt|npm|snap):[A-Za-z0-9@._+/-]+$`
- 拒绝以 `-` 开头、含换行/控制字符、含空白的包名
- 按引擎相同规则归一化 id；若与 catalog 已有 id 冲突，直接报错让用户改名，
  不静默复用已有条目

### D14. 「已安装」状态用 verify 探测
后端 `status` 只打印文本且返回码恒为 0，不能作为机器判定依据。
UI 的「检查当前状态」调用只读的 `verify` 动词，通过事件拿到每项的
`ok/failed`。卸载页默认只列出 catalog 与 manifest 记录，不在打开时自动
执行 verify（避免慢机器上首屏卡住）。

### D15. 结果分两个阶段展示
安装与校验各自有独立事件和结果，界面每行显示两个状态徽标：
「安装：成功/跳过/失败」与「校验：通过/未通过/未执行」。
- 安装发生整体回滚时，不执行自动 verify，校验列显示「未执行」。
- 关闭 `--keep-going` 时，首个失败之后的项不伪造结果，显示「未执行」。
- `run_end.rolled_back = true` 时，界面明确显示「已回滚到本次运行前状态」。

## 5. 架构

```text
浏览器 (vanilla HTML/CSS/JS)
   │  HTTP + SSE，仅 127.0.0.1，带 token
   ▼
ui/server.py (Python 3 标准库)
   ├─ 静态文件服务（ui/static/）
   ├─ /api/* 路由
   ├─ 选择与参数校验（白名单）
   ├─ 写 config/ui.env（原子写 + 备份）
   ├─ 子进程：./setup.sh <verb> --pick ...
   └─ 读取 OS_CONFIG_EVENTS 事件文件 → SSE
   ▼
setup.sh → engine/lib/* → catalog/actions（既有逻辑）
```

### 5.1 引擎最小改动

1. **`--list --json`**
   输出机器可读的 catalog 与 profile：
   - catalog：`id`, `type`, `backend`, `packages`, `commands`, `track`, `deps`,
     `desc`, `group`, `action`, `sudo`, `version`, `artifacts`
   - profile：`name`, `desc`, `extends`, 原始 `tools`，以及解析后的工具 id 列表
     （复用 `profile_tokens` / `profile_resolve`，保证与 CLI 结果一致）
   复用现有加载与校验，不另写一套解析器。`artifacts` 用于卸载确认框列出
   将被还原的文件。

2. **结构化事件文件**
   新增环境变量 `OS_CONFIG_EVENTS`（文件路径）。设置后追加 JSONL。
   事件写入统一由 `engine/lib/events.sh` 的 `events_emit` 完成；写失败必须
   静默忽略，绝不能影响安装。事件中的 id 只来自 catalog，不含用户原始输入。
   ```json
   {"event":"run_start","verb":"install","phase":"install","ids":["git-cli","git"]}
   {"event":"item_start","id":"git","verb":"install","phase":"install"}
   {"event":"item_end","id":"git","verb":"install","phase":"install","status":"ok","rc":0}
   {"event":"item_end","id":"ssh","verb":"install","phase":"install","status":"failed","rc":1}
   {"event":"rollback","phase":"install","restored":["/home/u/.gitconfig"]}
   {"event":"run_end","verb":"install","phase":"install","ok":5,"skipped":0,"failed":1,"rc":1,"rolled_back":false}
   ```
   `status` 取值 `ok` / `skipped` / `failed` / `planned`（dry-run 专用）。
   未执行到的项不伪造 `failed`；UI 用计划顺序减去已收到的事件推导出 `not_run`。
   `rollback_on_exit` 在真正执行回滚时发出 `rollback` 事件，`run_end.rolled_back`
   由 setup.sh 汇总。verify 阶段以独立的一组事件输出（`phase:"verify"`）。

3. **加载 `config/ui.env`**
   在 `load_user_config` 中，`user.env` 之后加载 `config/ui.env`（存在才加载）。
   这样 UI 生成的参数覆盖 user.env，同时不破坏用户手写文件。

4. **新增 `--yes`（非交互确认）**
   `setup.sh` 解析 `--yes` 并导出 `ASSUME_YES=1`；`util.sh` 的 `confirm()`
   在 `ASSUME_YES=1` 时直接返回成功。UI 的 `remove` 始终带 `--yes`。
   不改 `--force` 的既有语义（`--force` 仍表示忽略幂等判断）。
   否则 nodejs 的 remove 在无 TTY 下会读 stdin 失败、取消删除却返回 0。

5. **`--no-color` 不需要新增**：引擎在非 TTY 下已自动禁用颜色。

### 5.2 执行流程

1. 浏览器提交 `{verb, pick, params, reset_params, verify_after, keep_going, force, dry_run, confirm}`。
2. 服务端校验工具 id、临时包 token、参数键和值；非法请求返回 400，不执行。
3. 生成 `config/ui.env`（原子写、0600、备份旧文件；只写用户改动过的键）。
4. 先跑一次计划预览（dry-run + events），把有序计划与依赖来源返回给前端；
   页面初始打开的「基础清单」即这次预览。执行按钮点击后不再二次请求确认。
5. 真正执行：`subprocess.Popen` 启动
   `setup.sh <verb> --pick <ids,adhoc> [--keep-going] [--yes]`，
   stdout/stderr 合并按行读取，同时 tail 事件文件。
6. SSE 推送：`log`、`plan`、`item`、`rollback`、`summary`、`done` 六类消息。
7. 若 `verify_after`、install 返回 0 且未发生回滚，再执行 `verify`，
   同样通过事件映射结果；校验失败不影响安装结果，但汇总中单独列出。
8. 结束时把本次选择（`tools` + `adhoc`）写入 `state/ui/selection.json`；
   参数变更已写入 `config/ui.env`。执行失败也保存，便于修正后重试。

### 5.3 文件与目录

```text
ui.sh                         启动器（生成 token、sudo 预授权、启动 Python、开浏览器）
ui/
  server.py                   HTTP + SSE + 子进程编排
  schema.py                   catalog/参数白名单与校验、env 文件读写
  static/
    index.html
    app.js
    style.css
engine/lib/events.sh          新增：JSONL 事件写入（写失败静默）
config/ui.env                 UI 生成的参数（gitignored）
state/ui/selection.json       上次选择（工具 + 原始 adhoc token，0600）
state/ui/env-backups/         ui.env 历史备份
state/ui/run.lock             执行互斥锁
state/ui/runs/<run_id>/       每次运行的历史（meta.json / run.log / events.jsonl）
```

## 6. HTTP API

所有响应 `application/json`（日志历史除外）。所有请求校验 token；
POST 还校验 `Content-Type: application/json`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 返回 index.html；`?token=` 校验后注入/交给前端 |
| GET | `/api/catalog` | catalog、分组、profile（含解析结果） |
| GET | `/api/state` | 上次选择、sudo 是否可用、当前是否有任务 |
| POST | `/api/plan` | 入参 `{verb, pick}`；返回 dry-run 有序计划、依赖来源、警告 |
| POST | `/api/run` | 启动任务，返回 `run_id`；已有任务时 409 |
| GET | `/api/events?token=` | SSE 事件流；重连时先回放环形缓冲 |
| POST | `/api/sudo/check` | 执行 `sudo -n true`，返回是否已授权 |
| GET | `/api/installed` | 返回 `state/manifest.conf` 条目、catalog 的 artifacts，以及 catalog 工具清单；不主动执行 verify |
| GET | `/api/status?pick=` | 按需触发只读 `verify`，用事件返回每项当前是否满足；供「检查当前状态」和卸载页使用 |
| GET | `/api/history` | `state/ui/runs/` 下运行列表（按 `started` 倒序、只接受安全 `run_id`） |
| GET | `/api/history/<run_id>` | 返回该次运行的 meta、事件与日志文本（只读，日志限制大小） |

SSE 使用命名事件（`event: <name>` + `data: <json>`）：

```text
event: log
data: {"line":"[INFO] [git] ..."}

event: item
data: {"id":"git","phase":"install","status":"ok","rc":0}

event: item
data: {"id":"git","phase":"verify","status":"ok","rc":0}

event: rollback
data: {"restored":["/home/u/.gitconfig"]}

event: summary
data: {"phase":"install","ok":5,"skipped":0,"failed":1,"rc":1,"rolled_back":false}

event: done
data: {"exit":1,"rolled_back":false,"run_id":"20261020-120000-abcdef"}
```

## 7. 安全模型

- 只绑定 `127.0.0.1`，不提供远程访问开关。
- 每次启动随机 token；`secrets.compare_digest` 比较。
- 静态文件只从 `ui/static/` 读取，拒绝 `..` 与绝对路径。
- 不执行浏览器传来的任意命令；动词限定为 `install|verify|remove`。
- 工具 id 白名单校验：`^[a-z0-9_-]+$`，或
  `^(apt|npm|snap):[A-Za-z0-9@._+/-]+$`；临时包不得以 `-` 开头，
  不得包含空白、换行或控制字符。
- adhoc 归一化 id 与 catalog 现有 id 冲突时直接拒绝，不执行。
- 参数键必须是服务端白名单；值做类型/格式校验，禁止换行、控制字符和 NUL。
- 写 `ui.env` 时使用单引号包裹并转义单引号（`'\''`），防止 shell 注入；
  文件权限 0600，原子替换。
- 历史记录只读，`run_id` 白名单匹配 `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`，拒绝路径分隔符。
- 不在页面显示 `user.env` / `ui.env` 中未列入白名单的键值。
- `SSH_KEY_PASSPHRASE` 在界面上以密码框显示；不回显已保存值（显示占位符
  「已设置，留空保持不变」）。引擎日志落盘前已有脱敏。

## 8. 前端界面

单页，无框架，原生 JS。区域划分：

1. **顶部栏**：项目名、profile 预设下拉、sudo 状态、当前任务状态。
2. **工具清单（左/主区）**：按 group 分组的卡片或列表；搜索框；
   每项显示勾选框、名称、描述、类型徽标（apt/npm/snap/config）、依赖标记。
   已安装状态按需点击「检查当前状态」后显示，不阻塞首屏。
3. **参数面板**：只显示已选工具对应的参数组；提供「恢复默认」。
4. **计划预览**：按引擎返回顺序列出将执行的项，标注自动加入的依赖及来源。
5. **执行区**：主按钮「开始安装」（remove 模式下为「确认卸载」，需二次确认）。
   执行中禁用按钮，显示进度与当前项。
6. **日志面板**：等宽字体，自动滚动到底部；可暂停自动滚动、复制、下载。
7. **结果汇总**：每行显示「安装」与「校验」两个状态徽标；成功/跳过/失败计数；
   失败项高亮并可跳转到对应日志行；发生回滚时显著提示「已回滚到运行前状态」。
8. **标签页**：安装 / 卸载 / 历史记录。

交互细节：
- 首次打开自动加载上次选择或 default profile，并显示计划预览。
- 任何勾选/参数变化会防抖后重新请求 `/api/plan`。
- 执行前如 `sudo -n` 不可用且选择中含需要提权的项，提示回终端授权，
  仍允许继续（引擎会给出明确失败）。
- 失败时不隐藏成功项；执行结束保留完整日志供查看。

## 9. 错误与边界处理

- 无选择：禁用执行按钮并提示。
- profile 解析失败/catalog 校验失败：页面展示引擎错误原文，不吞掉。
- 任务进行中重复提交：409，前端禁用按钮。
- SSE 断线：自动重连并回放缓冲；任务结束后关闭。
- 服务端异常：写 `state/ui/server.log`，页面显示通用错误与日志路径。
- 浏览器关闭不终止已启动的任务；重开页面可看到任务仍在运行并接入事件流
  （事件环形缓冲保存在服务进程内存中）。
- 端口占用：报错并提示 `--port`。
- 非 Ubuntu：启动时提示引擎主要支持 Ubuntu 22.04/24.04，但不阻止启动。

## 10. 测试

- 引擎新增能力：`tests/run.sh` 增加用例覆盖
  `--list --json` 可解析且字段完整（含 artifacts）、事件文件格式与
  `phase/status/rolled_back`、`config/ui.env` 覆盖顺序、`--yes` 让确认类
  remove 在非交互下继续执行。
- Python：`tests/test_ui_server.py` 使用标准库 `unittest`，覆盖
  参数白名单、三种参数状态（省略/空/有值）、shell 转义、工具 id 与
  adhoc token 校验、id 冲突、路径穿越、token 校验、历史文件名校验。
- 端到端（手动）：`--dry-run` 路径、最小安装（`--pick git`）、失败注入
  （不存在的 npm 包）、remove 还原（含 nodejs）、sudo 未授权提示、
  关闭 `--keep-going` 时的回滚展示。
- 回归：现有 `./tests/run.sh` 必须全部通过。

## 11. 交付物

- `ui.sh`、`ui/server.py`、`ui/schema.py`、`ui/static/{index.html,app.js,style.css}`
- 引擎改动：
  - `engine/lib/events.sh`（新增事件写入）
  - `engine/lib/util.sh`（加载 `ui.env`、`confirm()` 支持 `ASSUME_YES`）
  - `setup.sh`（`--list --json`、`--yes`、事件 run_start/run_end）
  - `engine/lib/engine.sh`（每项事件）
  - `engine/lib/rollback.sh`（rollback 事件）
- 测试与 README 更新
- `config/ui.env`、`state/ui/` 加入 `.gitignore`

## 12. 留给实现者的决定

以下已在评审中收敛，不再是开放问题：
- 临时包保存原始 token，npm 作用域包允许 `@` 与 `/`，id 冲突直接拒绝。
- 已安装状态用 `verify` 探测，不改造后端 `status`。
- remove 通过新增 `--yes` 实现非交互确认。
- 并发锁只覆盖 UI 启动的任务；终端并发运行属于已知限制。
- 事件包含 `phase`，rollback 单独发事件，未执行项由 UI 推导。

仍需实现者决定：
- 事件文件的读写细节（轮询间隔、缓冲区大小、SSE 环形缓冲长度）。
- 前端的具体视觉样式与布局断点。
- profile 预设载入视为替换当前选择，而非合并（确认此语义即可）。
- `--list --json` 的 Bash JSON 转义实现方式。
- `install` 默认不带 `--force`，保持幂等跳过语义；界面可提供「强制重做」开关。
