# net-proxy

把 `HTTP_PROXY`/`HTTPS_PROXY`/`http_proxy`/`https_proxy`/`NO_PROXY`/`no_proxy` 持久化写入 `~/.bashrc` 的 os-config 标记块。本模块不安装任何代理软件，只负责 shell 环境变量配置。

## 默认代理地址

默认 `PROXY_ENABLED=true`。当 `PROXY_HOST` 和 `PROXY_PORT` 留空时：

1. 优先从默认路由取得当前使用的本机 IPv4；失败时使用首个非 loopback IPv4。
2. 只把 IPv4 的最后一段替换为 `1`。例如 `192.168.114.147` 解析成 `192.168.114.1`。
3. 端口使用 `7890`，最终 URL 为 `http://192.168.114.1:7890`。

可显式填写 host/port 覆盖自动值，或设置 `PROXY_ENABLED=false` 完全关闭代理配置。

## 前置依赖

- `base`（sys-base 提供的基础工具）
- `NEEDS_SUDO=0`：仅写 `~/.bashrc`，无需 sudo

## 安装/配置做了什么

1. **解析配置**：关闭时不修改文件；启用时解析或自动推导代理 host/port，并校验地址和端口。
2. **注册回滚**：修改前通过 `register_rollback` 备份 `~/.bashrc`；原文件不存在时，失败会删除新文件。
3. **连通性检查**：执行一次 `ping` 检查代理主机；失败时停止写入并打印网卡/IP、路由和防火墙排查步骤。
4. **幂等检查**：查找 `# >>> os-config proxy begin >>>` 标记块；已存在则跳过；`--force` 时删除旧块后重写。
5. **追加标记块**：使用 `printf %q` 安全写入大小写两套代理变量和 `NO_PROXY`；提示新 shell 生效。

> 安装阶段先用 ICMP ping 确认代理主机可达；验证阶段再执行 `curl -x <代理地址> https://github.com`，真实检查代理 TCP 端口、HTTPS CONNECT、TLS 和目标站点访问。

## 验证项

- `PROXY_ENABLED=false` 时按跳过处理。
- 启用时使用与安装脚本相同的规则解析代理地址，并重新执行 ping 连通性检查。
- 执行 `curl -x "$proxy_url" "$PROXY_TEST_URL"`；默认通过代理访问 `https://github.com`。
- `~/.bashrc` 含受管标记块，且块内 `HTTPS_PROXY` 等于解析后的代理 URL。

## 可配置参数

复制 `config/user.env.example` → `config/user.env` 后修改：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| PROXY_ENABLED | true | `false` 时不写 shell 代理配置 |
| PROXY_HOST | （空） | 留空时把当前 IPv4 的最后一段替换为 `1` |
| PROXY_PORT | （空） | 留空时使用 `7890` |
| PROXY_TEST_URL | https://github.com | `curl -x` 的真实代理访问目标 |
| PROXY_CONNECT_TIMEOUT | 5 | curl 连接超时，单位秒 |
| PROXY_MAX_TIME | 15 | curl 整体请求超时，单位秒 |
| NO_PROXY | localhost,127.0.0.1,::1 | 不走代理的主机列表 |

## 用法

```bash
./setup.sh --module proxy
./setup.sh --module proxy --force
./setup.sh --module proxy --verify-only
```
