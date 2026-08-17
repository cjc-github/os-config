# rt-log

`rt-log` 是日志工具和系统日志配置模块，不是一个名为 `rt-log` 的独立软件。

- `rt-` 是 runtime（运行环境/运行期工具）分类前缀，只用于整理模块目录；
- 模块实际名称由 `module.conf` 中的 `NAME=log` 决定；
- 执行时使用模块名 `log`，而不是目录名 `rt-log`。

```bash
./setup.sh --module log
```

## 前置依赖和权限

- `DEPS=base`：运行前会自动补齐 `base` 依赖；
- `NEEDS_SUDO=1`：安装 APT 软件包、写入 journald 配置和重启日志服务需要 sudo；
- `~/.bashrc` 中的别名配置以当前用户身份写入。

## 配置

在 `config/user.env` 中可以设置：

```bash
JOURNALD_MAX_USE=200M
```

`JOURNALD_MAX_USE` 用于限制 systemd journal 的最大磁盘占用，支持正整数以及 `K`、`M`、`G`、`T`、`P` 单位，例如 `200M` 或 `2G`。

## 安装的软件

模块会通过 APT 确保以下软件已安装：

- `lnav`：交互式日志查看工具；
- `bat`：带语法高亮的文本查看工具；
- `logrotate`：传统日志文件轮转工具。

Ubuntu 的 `bat` 命令可能实际安装为 `batcat`。如果系统存在 `batcat` 但不存在 `bat`，模块会在 `~/.local/bin/bat` 创建符号链接。

## journald 配置

模块使用 drop-in 文件：

```text
/etc/systemd/journald.conf.d/99-os-config.conf
```

不会直接改写发行版维护的 `/etc/systemd/journald.conf`。默认写入：

```ini
[Journal]
Storage=persistent
SystemMaxUse=200M
ForwardToSyslog=no
```

各配置项的作用：

- `Storage=persistent`：将 journal 持久化到磁盘，系统重启后仍可查询；
- `SystemMaxUse=200M`：限制 journal 最大磁盘占用，实际值由 `JOURNALD_MAX_USE` 决定；
- `ForwardToSyslog=no`：不再把 journal 转发给传统 syslog，减少重复记录。

只有 drop-in 内容发生变化或使用 `--force` 时，模块才会在完成其他配置和校验后重启 `systemd-journald`。如果后续步骤或服务重启失败，受管配置会自动回滚。

## logrotate 处理

模块不会创建覆盖全部 `/var/log/*.log` 的新轮转规则，而是：

1. 删除旧版本曾创建的 `/etc/logrotate.d/99-os-config` 宽泛规则，避免与 Ubuntu 自带规则重复；
2. 使用下面的命令只读检查全局 logrotate 配置：

```bash
sudo logrotate --debug /etc/logrotate.conf
```

`--debug` 只用于检查配置和展示计划，不会执行实际日志轮转。

## 日志查看快捷命令

模块会在 `~/.bashrc` 的 os-config 标记块中添加：

| 命令 | 作用 |
|---|---|
| `oslogs-system` | 查看最近的 systemd journal 错误日志 |
| `oslogs-auth` | 查看认证日志；文件不可用时回退到 `systemd-logind` journal |
| `oslogs-apt` | 查看最近的 APT 安装和升级历史 |
| `oslogs-syslog` | 查看最近的 systemd journal 日志 |
| `oslogs` | 依次查看系统错误、认证日志和 APT 历史 |

安装后，新打开的 shell 会自动加载这些别名。要让当前 shell 立即生效，可执行：

```bash
source ~/.bashrc
oslogs
```

部分日志需要管理员权限，执行相应别名时可能要求输入 sudo 密码。

## 验证

只验证模块状态而不重新安装：

```bash
./setup.sh --verify-only --module log
```

验证脚本会检查：

- `lnav`、`bat`/`batcat`、`logrotate` 是否可用；
- journald drop-in 是否存在且内容符合配置；
- `logrotate --debug /etc/logrotate.conf` 是否通过；
- `~/.bashrc` 是否包含 `oslogs` 别名块。

## 是否启用

`config/modules.conf` 使用模块名 `log` 控制是否默认运行该模块：

```text
log
```

如果不希望默认修改 journald 配置或安装日志工具，可以删除或注释这一行；之后仍可通过 `./setup.sh --module log` 单独运行。
