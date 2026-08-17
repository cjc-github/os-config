# rt-nodejs

通过 nvm 安装受控的 Node.js 版本，设置 nvm default，并按需配置 npm registry。

## 配置

```bash
NVM_VERSION=v0.40.1
NODE_LTS_MAJOR=22
NODE_VERSION=              # 可选完整版本，如 22.x.y
NPM_REGISTRY=https://registry.npmmirror.com
```

- `NODE_VERSION` 非空：精确安装该完整版本。
- `NODE_VERSION` 为空：通过 `nvm version-remote "$NODE_LTS_MAJOR"` 解析指定主版本的最新远端版本。
- `NPM_REGISTRY` 非空：写入 npm registry；为空时保留 npm 自身配置。

## 安装行为

1. 已存在的 `~/.nvm/nvm.sh` 可直接复用；不会因为 `--force` 删除整个 `~/.nvm`。
2. 需要安装 nvm 时，下载固定版本 installer 到 `mktemp` 文件，注册退出清理后执行。
3. 安装或复用目标 Node 版本，并将具体版本设置为 nvm `default` alias。
4. 耗时命令通过 verbose 日志显示进度，失败退出码向上传播。

## 验证项

- nvm 可加载。
- `node`、`npm` 可用。
- `NODE_VERSION` 非空时验证完整版本；否则验证 Node 主版本等于 `NODE_LTS_MAJOR`。
- nvm default 能解析到目标版本。

## 用法

```bash
./setup.sh --module nodejs
./setup.sh --module nodejs --force
./setup.sh --module nodejs --verify-only
```
