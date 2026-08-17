# sys-base

刷新 APT 索引并确保后续模块需要的基础工具已安装。

## 配置

```bash
APT_UPGRADE=false
```

默认只执行 `apt-get update` 和安装依赖，不做全系统升级。只有 `APT_UPGRADE=true` 时才执行非交互 `apt-get -y upgrade`。

## 安装包

```text
curl wget ca-certificates gnupg unzip iputils-ping
```

其中 `iputils-ping` 供代理模块执行主机连通性检查。APT 操作前会等待 apt/dpkg 锁，网络操作失败时使用统一重试。

## 验证项

- `curl`、`wget`、`gpg`、`unzip`、`ping` 命令可用。
- `ca-certificates` 的 dpkg 状态为 `install ok installed`。

## 用法

```bash
./setup.sh --module base
APT_UPGRADE=true ./setup.sh --module base
./setup.sh --module base --verify-only
```
