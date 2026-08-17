# sys-mirrors

配置 Ubuntu 22.04/24.04 APT 镜像源。模块只负责 APT；npm registry 由 `rt-nodejs` 根据 `config/versions.env` 配置。

## 前置依赖

- `DEPS=`：无前置模块。
- `NEEDS_SUDO=1`：修改 `/etc/apt` 并执行 apt 命令需要 sudo。

## 安装行为

1. 使用 `dpkg --print-architecture` 识别架构：amd64/i386 使用普通 Ubuntu 镜像，arm64/armhf/riscv64/s390x/ppc64el 使用 ports 镜像。
2. 检查 deb822 文件 `/etc/apt/sources.list.d/ubuntu.sources`，并兼容 Ubuntu 22.04 常见的 legacy `/etc/apt/sources.list`。
3. 仅替换 `archive.ubuntu.com`、`security.ubuntu.com` 或 `ports.ubuntu.com` 的 Ubuntu 地址；自定义或已经是国内镜像的源幂等跳过。
4. 修改前使用 sudo 模式 `register_rollback` 备份；失败时自动恢复，原文件不存在时删除失败过程中创建的新文件。
5. 除非 `MIRROR_SKIP_APT_UPDATE=true`，否则等待 apt/dpkg 锁并执行最多两次 `apt-get update`。

`--force` 会让现有 deb822 文件进入重写流程；legacy 文件仍只在发现海外 Ubuntu 地址时修改。

## 验证项

- 至少存在 deb822 或 legacy APT 源文件。
- `MIRROR_SKIP_APT=false` 时，所有实际源文件都不得继续包含上述海外 Ubuntu 源；发现后直接验证失败，不只是 warning。
- `sudo -n apt-get check` 必须通过；非交互验证前需要可用的 sudo 凭据。

## 配置

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MIRROR_APT_URL` | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu` | amd64/i386 镜像 |
| `MIRROR_APT_PORTS_URL` | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports` | ports 架构镜像 |
| `MIRROR_SKIP_APT` | `false` | `true` 时不重写源，但仍可执行 apt update 和 verify |
| `MIRROR_SKIP_APT_UPDATE` | `false` | `true` 时不执行 apt update |

## 用法

```bash
./setup.sh --module mirrors
./setup.sh --module mirrors --dry-run
MIRROR_APT_URL=https://mirrors.aliyun.com/ubuntu ./setup.sh --module mirrors
MIRROR_SKIP_APT=true ./setup.sh --all
```
