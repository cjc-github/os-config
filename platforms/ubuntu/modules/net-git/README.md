# net-git

apt 安装 git，并写入全局 `user.name`/`user.email` 与 `http.proxy`/`https.proxy` 配置。

## 默认代理地址

Git 与 `net-proxy` 共用代理配置。默认 `PROXY_ENABLED=true`；`PROXY_HOST` 留空时，从当前 IPv4 推导同网段 `.1` 地址，`PROXY_PORT` 留空时使用 `7890`。

例如当前 IPv4 为 `192.168.114.147`，Git 的 `http.proxy` 和 `https.proxy` 默认配置为：

```text
http://192.168.114.1:7890
```

设置 `PROXY_ENABLED=false` 可显式关闭 Git 代理配置；显式填写 host/port 则覆盖自动值。

## 前置依赖

- `base`（sys-base 提供的 apt/curl 等基础工具）
- `NEEDS_SUDO=1`：apt install git 通过 sudo 执行

## 安装/配置做了什么

1. **注册 trap + 等待 apt 锁**：`setup_traps`；仅在需要安装 Git 时调用 `wait_for_apt_lock`。
2. **安装 git**：`cmd_exists git` 为真则跳过；否则通过 apt 安装并重试。
3. **配置身份**：`GIT_USER_NAME`/`GIT_USER_EMAIL` 非空时配置；当前值相同则跳过；任一变量为空时分别输出 warning、跳过对应配置，并给出可直接执行的 `git config --global` 命令。
4. **检查代理主机**：配置前执行一次 `ping`；失败时停止并打印网卡/IP、路由和防火墙排查步骤。
5. **配置代理**：连通后对 `http.proxy`、`https.proxy` 逐键比较并按需写入。
6. **强制重写**：`--force` 可重写身份和代理配置，但不会强制重新安装已存在的 Git 软件包。

> 安装阶段先用 ICMP ping 确认代理主机可达；验证阶段再执行 `curl -x <代理地址> https://github.com`，真实检查代理 TCP 端口、HTTPS CONNECT、TLS 和目标站点访问。

## 验证项

- `git` 命令可用并打印版本。
- `PROXY_ENABLED=true` 时，代理主机可以 ping 通，`curl -x` 可以通过该代理访问 `PROXY_TEST_URL`，且 `http.proxy`、`https.proxy` 等于解析后的代理 URL。
- `PROXY_ENABLED=false` 时不校验 Git 代理值。

## 可配置参数

复制 `config/user.env.example` → `config/user.env` 后修改：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| GIT_USER_NAME | （空） | git 全局 user.name；留空则 warning 后跳过 |
| GIT_USER_EMAIL | （空） | git 全局 user.email；留空则 warning 后跳过 |
| PROXY_ENABLED | true | `false` 时不配置 Git 代理 |
| PROXY_HOST | （空） | 留空时把当前 IPv4 的最后一段替换为 `1` |
| PROXY_PORT | （空） | 留空时使用 `7890` |
| PROXY_TEST_URL | https://github.com | `curl -x` 的真实代理访问目标 |
| PROXY_CONNECT_TIMEOUT | 5 | curl 连接超时，单位秒 |
| PROXY_MAX_TIME | 15 | curl 整体请求超时，单位秒 |

## 手动补充 Git 身份

如果安装日志提示身份未设置，可执行：

```bash
git config --global user.name "你的姓名"
git config --global user.email "your-email@example.com"
```

可用以下命令确认配置：

```bash
git config --global --get user.name
git config --global --get user.email
```

## 用法

```bash
./setup.sh --module git
./setup.sh --module git --force
./setup.sh --module git --verify-only
```
