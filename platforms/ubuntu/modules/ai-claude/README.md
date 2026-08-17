# ai-claude

通过 npm 全局安装固定版本的 Claude Code CLI（`@anthropic-ai/claude-code`）。

## 前置依赖

- `nodejs`：提供 nvm、Node.js 和 npm。
- `NEEDS_SUDO=0`：全局包安装在 nvm 用户目录，不使用 sudo。
- runner 和模块脚本都会优先激活 `nvm use default`，避免系统 Node/npm 抢占 PATH。

## 安装行为

1. 加载用户配置和固定版本，激活 nvm default，并确认 `node`、`npm` 可用。
2. 若 `claude --version` 已等于 `${CLAUDE_CODE_VERSION}`，且没有 `--force`，则幂等跳过。
3. 首次正常执行 `npm install -g ${CLAUDE_CODE_PKG}@${CLAUDE_CODE_VERSION}`，使用配置的 `NPM_REGISTRY`。
4. 普通 npm 失败直接保留原退出码，不删除正式包目录。
5. 只有错误输出明确包含 `ENOTEMPTY` 时，才删除 npm prefix 下 `.<package>-*` 隐藏 rename 残留；scoped 包按 `@scope/.package-*` 处理，然后重试一次。
6. 安装后优先使用 npm prefix 的绝对命令路径自检，避免当前 shell 的 PATH 尚未刷新。

## 验证项

- 优先激活 nvm default。
- `claude` 命令必须可用并能输出版本。
- 实际版本与固定版本不一致时输出 warning；当前实现仍将命令可用视为验证通过。

## 配置

配置集中在 `config/versions.env`：

| 变量 | 当前默认值 | 说明 |
|---|---|---|
| `CLAUDE_CODE_PKG` | `@anthropic-ai/claude-code` | npm 包名 |
| `CLAUDE_CODE_VERSION` | `2.1.228` | 固定版本号 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm registry；留空时使用 npm 自身配置 |

查询包版本：

```bash
npm view @anthropic-ai/claude-code version
```

## 用法

```bash
./setup.sh --module claude
./setup.sh --module claude --force
./setup.sh --module claude --verify-only
```
