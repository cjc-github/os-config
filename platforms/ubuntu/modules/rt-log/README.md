# rt-log

安装 `lnav`、`bat`、`logrotate`，通过 journald drop-in 配置持久化日志，并添加 `oslogs` 别名。

## 配置

```bash
JOURNALD_MAX_USE=200M
```

## 行为

- 使用 `/etc/systemd/journald.conf.d/99-os-config.conf`，不直接修改发行版维护的 `journald.conf`。
- drop-in 包含 `Storage=persistent`、`SystemMaxUse` 和 `ForwardToSyslog=no`。
- 配置改变后必须成功重启 `systemd-journald`，失败会触发回滚。
- 删除旧版本创建的 `/etc/logrotate.d/99-os-config` 宽泛 `/var/log/*.log` 规则，避免和发行版规则重复。
- 使用 `logrotate --debug /etc/logrotate.conf` 做只读配置校验。
- 在 `~/.bashrc` 中维护带标记的 `oslogs` 别名块。

系统配置和用户配置都会在修改前注册回滚；新建文件在失败时会被删除。
