# rt-screen

自动检测当前图形会话并关闭息屏、锁屏和 blanking：优先 GNOME `gsettings`，其次 X11 `xset`；无图形会话时安全跳过。

## 前置依赖

- `base`
- `NEEDS_SUDO=0`：只修改当前用户会话设置。

## 安装行为

### GNOME

仅当 `XDG_CURRENT_DESKTOP` 包含 `GNOME` 且存在 `DBUS_SESSION_BUS_ADDRESS` 时使用 `gsettings`，设置并校验三项：

```text
org.gnome.desktop.session idle-delay = 0
org.gnome.desktop.screensaver lock-enabled = false
org.gnome.desktop.screensaver idle-delay = 0
```

当前值已经正确时幂等跳过；`--force` 会重设全部三项。检测到 GNOME 但没有可用 D-Bus 会话时会输出 warning，并尝试 X11 策略。

### X11

当 GNOME 策略未应用、`xset` 可用且 `DISPLAY` 非空时执行：

```bash
xset s off
xset -dpms
xset s noblank
```

### 无图形环境

GNOME 和 X11 都不可用时输出 skipped 提示，不修改系统级休眠策略。

## 验证项

- GNOME：同时验证 session idle、锁屏开关和 screensaver idle 三项。
- X11：解析 `xset q`，同时验证 Screen Saver timeout 为 `0`、DPMS 为 Disabled、blanking 为 `no`。
- 无图形环境：按 skipped 处理并通过。

## 用法

```bash
./setup.sh --module screen
./setup.sh --module screen --force
./setup.sh --module screen --verify-only
```
