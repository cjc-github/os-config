# sys-base

更新 apt 索引并升级已装系统包，再安装 curl/wget/ca-certificates/gnupg/unzip 基础工具，为后续模块（导入 GPG 密钥、下载安装脚本等）提供前置依赖。

## 前置依赖

- 无（本模块是基础模块，拓扑排序后最先执行）
- `NEEDS_SUDO=1`：apt update/upgrade/install 通过 sudo 执行，需当前用户具备 sudo 权限

## 安装/配置做了什么

1. **注册 trap + 等待 apt 锁**：`setup_traps` 注册异常 trap；`wait_for_apt_lock` 等待 apt 锁释放（检测失败仅告警并继续）
2. **幂等检查**：`curl`/`wget`/`gpg`/`unzip` 四个命令全部已装则跳过后续步骤（`--force` 时强制继续 apt upgrade）
3. **apt update**：刷新 apt 包索引，`with_retry` 重试 3 次
4. **apt upgrade**：非交互升级已装系统包，`with_retry` 重试 3 次
5. **安装基础工具包**：`apt-get install -y curl wget ca-certificates gnupg unzip`，`with_retry` 重试 3 次

## 验证项

- `curl`、`wget`、`ca-certificates`、`gpg`、`unzip` 五个命令均 `cmd_exists`，并打印各自 `--version` 首行

## 可配置参数

无。本模块只做 apt update/upgrade + 固定基础包安装，不涉及版本号或用户参数。

## 幂等行为

- 安装型：`cmd_exists` 检查 curl/wget/gpg/unzip 是否都已装 → 跳过
- `--force` 时：忽略幂等判断，强制再跑一次 apt update/upgrade

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap（失败时清理临时文件 + 回滚备份 + 打印失败命令）
- `with_retry`：apt update / upgrade / install 各重试 3 次
- `wait_for_apt_lock`：执行 apt 命令前等待 apt 锁释放

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module base

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module base --force

# 只验证
./setup.sh --module base --verify-only
```
