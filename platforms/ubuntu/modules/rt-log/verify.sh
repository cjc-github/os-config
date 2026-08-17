#!/usr/bin/env bash
# rt-log/verify —— 验证日志工具、journald drop-in、logrotate 和 shell 别名。
set -euo pipefail

: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
. "$PROJECT_DIR/lib/utils.sh"
. "$PROJECT_DIR/lib/log.sh"
: "${JOURNALD_MAX_USE:=200M}"
fail=0

if cmd_exists lnav; then log_ok "lnav: $(lnav --version 2>&1 | head -1)"; else log_error "lnav 未安装"; fail=1; fi
if cmd_exists bat; then
  log_ok "bat: $(bat --version 2>&1 | head -1)"
elif cmd_exists batcat; then
  log_ok "batcat: $(batcat --version 2>&1 | head -1)"
else
  log_error "bat/batcat 未安装"; fail=1
fi
if cmd_exists logrotate; then log_ok "logrotate: $(logrotate --version 2>&1 | head -1)"; else log_error "logrotate 未安装"; fail=1; fi

dropin=/etc/systemd/journald.conf.d/99-os-config.conf
for expected in 'Storage=persistent' "SystemMaxUse=$JOURNALD_MAX_USE" 'ForwardToSyslog=no'; do
  if sudo grep -Fxq "$expected" "$dropin" 2>/dev/null; then
    log_ok "journald $expected"
  else
    log_error "$dropin 缺少：$expected"
    fail=1
  fi
done
if journalctl --disk-usage >/dev/null 2>&1; then log_ok "journalctl --disk-usage 可读"; else log_error "journalctl --disk-usage 不可读"; fail=1; fi
if sudo logrotate --debug /etc/logrotate.conf >/dev/null 2>&1; then log_ok "logrotate 配置校验通过"; else log_error "logrotate 配置校验失败"; fail=1; fi
if sudo test -e /etc/logrotate.d/99-os-config; then
  log_error "仍存在旧版宽泛规则 /etc/logrotate.d/99-os-config"
  fail=1
fi
if [[ -f "$HOME/.bashrc" ]] && file_contains "$HOME/.bashrc" "# >>> os-config oslogs >>>"; then
  log_ok "~/.bashrc 含 oslogs 别名"
else
  log_error "$HOME/.bashrc 未找到 oslogs 别名"
  fail=1
fi
exit "$fail"
