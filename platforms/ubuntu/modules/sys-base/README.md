# sys-base

`sys-base` 是 Ubuntu 基础工具集合：把常用软件按分类整理，通过二维配置选择“启用哪些分类、分类内安装哪些工具”，再统一执行 APT 安装和验证。

## 配置文件

默认读取：

```text
config/base-tools.conf
```

配置分为两级：

```ini
[archive]
enabled=true
zip=true
unzip=true
tar=true
sevenzip=true
rar=false
```

规则：

1. `enabled=false`：跳过整个分类；
2. `enabled=true` 且工具为 `true`：选择该工具；
3. 只接受 `true` / `false`；
4. 未在软件目录中注册的分类或工具会直接报错，避免拼写错误被静默忽略；
5. 安装和验证都只处理最终选中的工具。

可通过环境变量临时指定另一份配置：

```bash
BASE_TOOLS_CONFIG=/path/to/server-base.conf ./setup.sh --module base
```

相对路径以项目根目录为基准。

## 软件目录

工具逻辑名称与 Ubuntu APT 软件包、验证命令的映射集中在：

```text
platforms/ubuntu/modules/sys-base/packages.catalog
```

格式为：

```text
分类标识|分类说明|工具标识|APT 软件包|验证命令|工具说明
```

例如：

```text
file-transfer|文件传输|lrzsz|lrzsz|rz sz|ZMODEM rz/sz 文件传输
archive|压缩解压|xz|xz-utils|xz|XZ 压缩解压
network|网络诊断|ping|iputils-ping|ping|网络连通性检查
```

因此用户选择的是易懂的逻辑工具名，不需要记住 `rz -> lrzsz`、`xz -> xz-utils`、`ping -> iputils-ping` 之类的软件包映射。

## 内置分类

| 配置节 | 分类 | 示例工具 |
|---|---|---|
| `core` | 核心依赖 | ca-certificates、curl、wget、gnupg |
| `file-transfer` | 文件传输 | lrzsz、rsync |
| `archive` | 压缩解压 | zip、unzip、tar、gzip、bzip2、xz、7zip、RAR 解压 |
| `development` | 开发基础 | git、build-essential、make、cmake、ninja、shellcheck |
| `network` | 网络诊断 | ping、dig、netstat、traceroute、tcpdump、telnet、aria2 |
| `system` | 系统管理 | htop、btop、tree、lsof、jq、tmux、strace、ripgrep、fd |
| `editor` | 文本编辑 | vim、nano |

Docker、Node.js、AI CLI 等带软件源、版本管理或复杂配置的软件仍应保留为独立模块，不放入 `sys-base`。

## 安装行为

```bash
./setup.sh --module base
```

执行流程：

1. 读取 `base-tools.conf`；
2. 根据 `packages.catalog` 解析实际 APT 软件包；
3. 去重并显示分类选择；
4. 执行 `apt-get update`；
5. `APT_UPGRADE=true` 时才执行全系统升级；
6. 普通模式仅安装缺少的软件包；
7. runner 随后调用 `verify.sh` 验证所选软件包和命令。

多个逻辑工具映射到同一个软件包时，只会安装一次。

## 强制重新安装

```bash
./setup.sh --module base --force
```

`--force` 会对配置中选中的软件包执行：

```bash
apt-get --reinstall install ...
```

它不会安装配置中关闭的工具。

## 其他用法

```bash
# 只看模块执行计划
./setup.sh --module base --dry-run

# 只执行安装，不验证
./setup.sh --module base --install-only

# 只验证配置中选中的基础工具
./setup.sh --module base --verify-only

# 直接执行模块（同样读取默认配置）
./platforms/ubuntu/modules/sys-base/install.sh
./platforms/ubuntu/modules/sys-base/verify.sh
```

## APT 升级配置

`config/user.env` 中可以设置：

```bash
APT_UPGRADE=false
```

默认只刷新软件索引并安装所选工具，不执行全系统升级。只有显式设为 `true` 才会运行非交互式 `apt-get upgrade`。
