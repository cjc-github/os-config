# net-proxy

把 `HTTP_PROXY`/`HTTPS_PROXY`/`http_proxy`/`https_proxy`/`NO_PROXY`/`no_proxy` 持久化写入 `~/.bashrc` 的 os-config 标记块。本模块不安装任何代理软件，只做 shell 环境变量持久化。

## 前置依赖

- `base`（sys-base 提供的基础工具）
- `NEEDS_SUDO=0`：仅写 `~/.bashrc`，无需 sudo

## 安装/配置做了什么

1. **注册 trap**：`setup_traps`
2. **前置检查**：`PROXY_PORT` 为空则告警并跳过整个模块
3. **备份 ~/.bashrc**：`backup_file` 注册回滚备份
4. **幂等检查**：搜 `# >>> os-config proxy begin >>>` 标记块；已存在则跳过；`--force` 时用 `sed` 删除旧块（BEGIN→END）后重写
5. **追加标记块**：向 `~/.bashrc` 追加 `export HTTP_PROXY`/`HTTPS_PROXY`/`http_proxy`/`https_proxy` = `http://$PROXY_HOST:$PROXY_PORT`，以及 `NO_PROXY`/`no_proxy` = `$NO_PROXY`；提示新 shell 生效，当前会话需 `source ~/.bashrc`

## 验证项

- `~/.bashrc` 含 `# >>> os-config proxy begin >>>` 标记块
- 块内 `export HTTPS_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"` 匹配预期值

## 可配置参数

复制 `config/user.env.example` → `config/user.env` 后修改：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| PROXY_HOST | 127.0.0.1 | 代理主机 |
| PROXY_PORT | 7890 | 代理端口；留空则跳过整个 proxy 模块 |
| NO_PROXY | localhost,127.0.0.1,::1 | 不走代理的主机列表 |

## 幂等行为

- 配置型：`file_contains` 检查 `~/.bashrc` 是否已含 os-config proxy 标记块 → 跳过
- `--force` 时：`sed` 删除旧块后重写

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap
- `register_rollback`（经 `backup_file`）：备份 `~/.bashrc` 用于失败回滚

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module proxy

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module proxy --force

# 只验证
./setup.sh --module proxy --verify-only
```
