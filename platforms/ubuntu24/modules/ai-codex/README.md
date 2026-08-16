# ai-codex

通过 npm 全局安装 `@openai/codex` 的固定版本（OpenAI Codex CLI）。

## 前置依赖

- `nodejs`（rt-nodejs 提供的 nvm + node LTS + npm）
- `NEEDS_SUDO=0`：npm 全局包装在 nvm 用户目录下，无需 sudo

> **关键说明**：runner 在调用本模块前会自动 source nvm + `nvm use default` 注入 PATH；本脚本内对 nvm 的激活只是兜底，方便单独运行本脚本。

## 安装/配置做了什么

1. **注册 trap**：`setup_traps`
2. **前置检查 node**：`cmd_exists node` 为假则兜底 `source ~/.nvm/nvm.sh` + `nvm use default`；仍不可用则报错退出
3. **幂等检查**：`cmd_exists codex` 且解析出的版本号 == `CODEX_VERSION` → 跳过（`--force` 时继续重装）
4. **安装**：`npm install -g $CODEX_PKG@$CODEX_VERSION`（`with_retry` 重试 3 次，npm install -g 会覆盖现有版本）

## 验证项

- `codex` 命令可用（解析打印版本号）
- 实际版本 == `CODEX_VERSION`（不一致仅告警，不视为失败）
- verify 也会兜底 `source ~/.nvm/nvm.sh` + `nvm use default`

## 可配置参数

集中在仓库根目录 `config/versions.env`，修改版本只需改那里一处：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| CODEX_PKG | @openai/codex | npm 包名 |
| CODEX_VERSION | 0.147.0 | 固定版本号 |

实查最新稳定版：`npm view @openai/codex version`

## 幂等行为

- 安装型：`cmd_exists codex` 且解析版本 == `CODEX_VERSION` → 跳过
- `--force` 时：忽略幂等判断，`npm install -g` 覆盖现有版本

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap
- `with_retry`：`npm install -g` 重试 3 次

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module codex

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module codex --force

# 只验证
./setup.sh --module codex --verify-only
```
