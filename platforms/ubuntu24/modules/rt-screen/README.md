# rt-screen

自动检测图形环境并关闭息屏/锁屏；多策略：GNOME（gsettings）→ X11（xset）→ Server 版（无图形环境）跳过。

## 前置依赖

- `base`（sys-base 提供的基础工具）
- `NEEDS_SUDO=0`：仅改用户层 gsettings/xset，无需 sudo

## 安装/配置做了什么

1. **注册 trap**：`setup_traps`
2. **GNOME gsettings 策略**（`cmd_exists gsettings` 且处于 GNOME 会话：`XDG_CURRENT_DESKTOP` 含 GNOME 或 `~/.config/dconf` 存在）：读 `session.idle-delay`、`screensaver.lock-enabled`、`screensaver.idle-delay` 当前值，已是目标值则跳过；设 `idle-delay 0`、`lock-enabled false`、`screensaver idle-delay 0`
3. **X11 xset 策略**（GNOME 未命中 且 `cmd_exists xset` 且 `DISPLAY` 可用）：`xset s off; xset -dpms; xset s noblank`
4. **Server 版兜底**：无 `DISPLAY` 且无 gsettings/xset 命中 → 打印跳过提示并退出（如需禁止休眠可手动配 systemd-inhibit 或 logind.conf）

## 验证项

- 无图形环境（无 `DISPLAY` 且无 `gsettings`）→ 标记 skipped 并通过
- GNOME 会话：`gsettings get org.gnome.desktop.session idle-delay` 等于 `0`
- X11：`xset q` 可读（含 `Screen Saver` 段）

## 可配置参数

无。本模块自动检测 GNOME / X11 / Server 环境，不涉及版本号或用户参数。

## 幂等行为

- 配置型（gsettings）：读当前值，已是目标则跳过
- `--force` 时：忽略幂等判断，强制重设 gsettings 的 `idle-delay` / `lock-enabled`
- xset/Server 策略为一次性即时生效命令，不做持久化检查

## 异常处理

- `setup_traps`：注册 EXIT/INT/TERM/ERR trap

## 用法

```bash
# 只跑本模块（自动补依赖）
./setup.sh --module screen

# 跑全部
./setup.sh

# 强制重装
./setup.sh --module screen --force

# 只验证
./setup.sh --module screen --verify-only
```
