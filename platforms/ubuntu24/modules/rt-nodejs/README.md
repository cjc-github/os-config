# rt-nodejs

通过 nvm 安装指定版本 nvm + node LTS，并（可选）配置 npm 镜像源。

## 前置依赖

- `base`（sys-base 提供的 curl 等基础工具，用于下载 nvm 安装脚本）
- `NEEDS_SUDO=0`：nvm/node 均装在用户家目录 `~/.nvm`

> **关键说明**：本模块安装的 nvm/node 会被 runner 在调用 ai-* 模块前通过 `runner_activate_node_env()` 自动 source nvm + `nvm use default` 注入 PATH，无需在此修改 `~/.bashrc`。

## 安装/配置做了什么

1. **注册 trap**：`setup_traps`
2. **安装 nvm**：`~/.nvm/nvm.sh` 存在则跳过；`--force` 时先 `rm -rf ~/.nvm`；从 GitHub 下载 `nvm $NVM_VERSION` 的 install.sh 到 `/tmp/nvm-install.sh`（`register_tmpfile` + `with_retry` 重试 3 次 curl），再 `bash` 运行安装
3. **加载 nvm**：在当前进程 `export NVM_DIR` + `source ~/.nvm/nvm.sh`（非交互）
4. **装 node LTS**：`nvm version-remote --lts` 取最近可用 LTS 版本（失败则按 `NODE_LTS_MAJOR` 拼）；若当前 node 已装且版本一致则跳过，否则 `nvm install --lts`；`nvm alias default node` 设默认；`nvm use default` 让后续步骤能用 node/npm
5. **配置 npm 镜像（可选）**：`NPM_REGISTRY` 非空时，读当前 `npm config get registry`，与预期相同则跳过；`--force` 时重设

## 验证项

- `node` 命令可用（打印 `node --version`）
- `npm` 命令可用（打印 `npm --version`）
- verify 会显式 `source ~/.nvm/nvm.sh` + `nvm use default`（因 verify 可单独调用）

## 可配置参数

集中在 `config/versions.env`，修改版本只需改那里一处：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| NVM_VERSION | v0.40.1 | nvm 版本（GitHub release tag） |
| NODE_LTS_MAJOR | 22 | node LTS 主版本（满足 claude≥20 / codex≥18 / opencode≥18 最低要求） |
| NPM_REGISTRY | （空） | npm 镜像，如 `https://registry.npmmirror.com`；留空则不改 npm config |

## 幂等行为

- 安装型：`~/.nvm/nvm.sh` 存在则跳过 nvm 安装；node 已装且版本 == 目标 LTS 则跳过 `nvm install`
- 配置型：`npm config get registry` 当前值 == 目标则跳过
- `--force` 时：删除 `~/.nvm` 重装 nvm；强制 `nvm install --lts`；重设 npm registry

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap
- `with_retry`：curl 下载 nvm 安装脚本重试 3 次
- `register_tmpfile`：注册 `/tmp/nvm-install.sh` 用于退出清理

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module nodejs

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module nodejs --force

# 只验证
./setup.sh --module nodejs --verify-only
```
