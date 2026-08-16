# net-ssh

apt 安装 openssh-client/openssh-server，并在 `~/.ssh` 下非交互生成 SSH 密钥对（ed25519/rsa）。

## 前置依赖

- `base`（sys-base 提供的 apt 等基础工具）
- `NEEDS_SUDO=1`：apt install openssh 通过 sudo 执行

## 安装/配置做了什么

1. **注册 trap + 等待 apt 锁**：`setup_traps`；`wait_for_apt_lock`
2. **安装 openssh**：`cmd_exists ssh` 为真则跳过 apt install；否则 `apt-get install -y openssh-client openssh-server`（`with_retry` 重试 3 次）
3. **创建 ~/.ssh 目录**：`mkdir -p ~/.ssh` 并 `chmod 700`
4. **非交互生成密钥**：`~/.ssh/id_${SSH_KEY_TYPE}` 已存在则跳过；否则按 `SSH_KEY_TYPE` 选择算法：`ed25519` 用 `ssh-keygen -t ed25519`，`rsa` 用 `ssh-keygen -t rsa -b 4096`；comment 含 `用户@主机 日期`；passphrase 取自 `SSH_KEY_PASSPHRASE`（留空即无 passphrase）；不支持的类型报错退出
5. **修正密钥权限**：私钥 `chmod 600`、公钥 `chmod 644`

## 验证项

- `ssh` 命令可用（打印 `ssh -V`）
- `~/.ssh/id_${SSH_KEY_TYPE}` 私钥与对应 `.pub` 公钥均存在
- 私钥权限为 `600`（否则告警，不视为失败）

## 可配置参数

复制 `config/user.env.example` → `config/user.env` 后修改：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| SSH_KEY_TYPE | ed25519 | 密钥类型：`ed25519` 或 `rsa` |
| SSH_KEY_PASSPHRASE | （空） | 密钥 passphrase；留空 = 无 passphrase（非交互） |

## 幂等行为

- 安装型：`cmd_exists ssh` → 跳过 apt install
- 密钥生成：`~/.ssh/id_${SSH_KEY_TYPE}` 已存在则跳过
- `--force` 时：本模块未直接读取 `$FORCE`；密钥已存在即跳过（需重生成请先删除旧密钥）

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap
- `with_retry`：apt install openssh 重试 3 次
- `wait_for_apt_lock`：执行 apt 命令前等待 apt 锁释放

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module ssh

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module ssh --force

# 只验证
./setup.sh --module ssh --verify-only
```
