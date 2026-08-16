# rt-log

安装日志查看工具（lnav/bat/logrotate），持久化 journald 并限容，调优 logrotate，并在 `~/.bashrc` 注入 `oslogs` 系列别名。

## 前置依赖

- `base`（sys-base 提供的 apt 等基础工具）
- `NEEDS_SUDO=1`：apt install、改 `/etc/systemd/journald.conf`、写 `/etc/logrotate.d/` 均需 sudo

## 安装/配置做了什么

1. **注册 trap + 等待 apt 锁**：`setup_traps`；`wait_for_apt_lock`
2. **安装日志工具**：`lnav`/`batcat`/`logrotate` 三个都已装则跳过；否则 `apt-get install -y lnav bat logrotate`（`with_retry` 重试 3 次）；bat 在 ubuntu 上是 `batcat`，若 `bat` 命令不存在则建软链 `~/.local/bin/bat -> batcat`
3. **journald 持久化 + 限容**：逐键读 `Storage`/`SystemMaxUse`/`ForwardToSyslog` 当前值，全部已是目标值则跳过；否则 `sudo cp` 备份（带日期 `.bak`，仅首次），`sed` 改三键（`Storage=persistent` / `SystemMaxUse=$JOURNALD_MAX_USE` / `ForwardToSyslog=no`），并 `systemctl restart systemd-journald`
4. **logrotate 调优**：`mktemp` 生成临时配置（`register_tmpfile`），内容为 `/var/log/*.log` weekly + `rotate $LOGROTATE_KEEP_WEEKS` + compress；`sudo diff` 与现有一致则跳过；否则 `sudo cp` 写 `/etc/logrotate.d/99-os-config`
5. **oslogs 别名**：`backup_file ~/.bashrc`；搜 `# >>> os-config oslogs >>>` 标记块，已存在则跳过；`--force` 时 `sed` 删旧块后重写；追加 `oslogs-system`/`oslogs-auth`/`oslogs-apt`/`oslogs-syslog`/`oslogs` 别名；提示新 shell 生效

## 验证项

- `lnav` 命令可用（打印版本）
- `bat` 或 `batcat` 命令可用（打印版本）
- `logrotate` 命令可用（打印版本）
- journald 已配置 `Storage=persistent`（默认即视为通过）
- `journalctl --disk-usage` 可读
- `~/.bashrc` 含 `# >>> os-config oslogs >>>` 别名块

## 可配置参数

复制 `config/user.env.example` → `config/user.env` 后修改：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| JOURNALD_MAX_USE | 200M | journald `SystemMaxUse` 上限 |
| LOGROTATE_KEEP_WEEKS | 4 | logrotate `rotate N` 保留周数 |

## 幂等行为

- 安装型：`cmd_exists lnav`/`batcat`/`logrotate` 全部为真则跳过 apt install
- 配置型：journald 三键当前值 == 目标则跳过 sed/restart；logrotate `sudo diff` 一致则跳过；oslogs 标记块存在则跳过
- `--force` 时：重写 journald/logrotate 配置与 oslogs 别名块

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap
- `with_retry`：apt install lnav/bat/logrotate 重试 3 次
- `wait_for_apt_lock`：执行 apt 命令前等待 apt 锁释放
- `register_rollback`（经 `backup_file`）：备份 `~/.bashrc`；另对 `journald.conf` 手动 `sudo cp` 带 `.bak.<日期>` 备份
- `register_tmpfile`：注册 `mktemp` 生成的临时文件用于退出清理

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module log

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module log --force

# 只验证
./setup.sh --module log --verify-only
```
