# Ubuntu

Ubuntu 操作系统族平台，当前支持 Ubuntu 22.04 和 24.04，两者共用本目录中的模块。

## 分类规则

- 平台目录名固定为 `ubuntu`，不再按 `ubuntu22`、`ubuntu24` 拆分。
- CPU 架构由 `SYSTEM_ARCH` 单独表示，例如 `amd64`、`arm64`。
- APT 镜像模块同时兼容 legacy `sources.list` 和 deb822 `ubuntu.sources`。

## 使用

```bash
./setup.sh --platform ubuntu --list
./setup.sh --platform ubuntu --all --dry-run
./setup.sh
```

不带 `--platform` 时，Ubuntu 22.04 和 24.04 会自动映射到本目录。
