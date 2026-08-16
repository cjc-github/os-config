# net-git

apt 安装 git，并写入全局 `user.name`/`user.email` 与 `http.proxy`/`https.proxy` 配置。

## 前置依赖

- `base`（sys-base 提供的 apt/curl 等基础工具）
- `NEEDS_SUDO=1`：apt install git 通过 sudo 执行

## 安装/配置做了什么

1. **注册 trap + 等待 apt 锁**：`setup_traps`；`wait_for_apt_lock`
2. **安装 git**：`cmd_exists git` 为真则跳过 apt install；否则 `apt-get install -y git`（`with_retry` 重试 3 次）
3. **配置 user.name**：`GIT_USER_NAME` 非空时，读当前 `git config --global user.name`，与预期相同则跳过；`--force` 时重写
4. **配置 user.email**：`GIT_USER_EMAIL` 非空时，同 user.name 的比较/跳过/重写逻辑
5. **配置 git http/https 代理**：`PROXY_PORT` 非空时拼 `http://$PROXY_HOST:$PROXY_PORT`，对 `http.proxy`、`https.proxy` 逐键比较当前值，相同则跳过；`--force` 时重写；`PROXY_PORT` 留空则仅告警跳过

## 验证项

- `git` 命令可用（打印 `git --version`）
- `PROXY_PORT` 设置时：`http.proxy`、`https.proxy` 等于 `http://${PROXY_HOST}:${PROXY_PORT}`

## 可配置参数

复制 `config/user.env.example` → `config/user.env` 后修改：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| GIT_USER_NAME | （空） | git 全局 user.name；留空则跳过该项配置 |
| GIT_USER_EMAIL | （空） | git 全局 user.email；留空则跳过该项配置 |
| PROXY_HOST | 127.0.0.1 | 代理主机（与 net-proxy 共用） |
| PROXY_PORT | 7890 | 代理端口；留空则跳过 git 代理配置 |

## 幂等行为

- 安装型：`cmd_exists git` → 跳过 apt install（重装需先 apt remove）
- 配置型：`git config` 读出的当前值与预期值比较，相同则跳过
- `--force` 时：重写 user.name / user.email / http.proxy / https.proxy

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap
- `with_retry`：apt install git 重试 3 次
- `wait_for_apt_lock`：执行 apt 命令前等待 apt 锁释放

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module git

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module git --force

# 只验证
./setup.sh --module git --verify-only
```
