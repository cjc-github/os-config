#!/usr/bin/env bash
# =============================================================================
# 模块：rt-log/verify  ——  验证 rt-log 模块的安装结果
# =============================================================================
#
# 【校验项】
#   - lnav 命令是否可用（打印版本）
#   - bat 或 batcat 命令是否可用（打印版本）
#   - logrotate 命令是否可用（打印版本）
#   - journald 是否配置 Storage=persistent
#   - journalctl --disk-usage 是否可读
#   - ~/.bashrc 是否含 os-config oslogs 别名块
# =============================================================================

set -euo pipefail

# 加载共享库（独立运行也支持）
: "${PROJECT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck source=../../../../lib/utils.sh
. "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=../../../../lib/log.sh
. "$PROJECT_DIR/lib/log.sh"

fail=0

# lnav
if cmd_exists lnav; then
  log_ok "lnav: $(lnav --version 2>&1 | head -1)"
else
  log_error "lnav 未安装"
  fail=1
fi

# bat (batcat 或 bat)
if cmd_exists bat || cmd_exists batcat; then
  if cmd_exists bat; then
    log_ok "bat: $(bat --version 2>&1 | head -1)"
  else
    log_ok "batcat: $(batcat --version 2>&1 | head -1)"
  fi
else
  log_error "bat/batcat 未安装"
  fail=1
fi

# logrotate
if cmd_exists logrotate; then
  log_ok "logrotate: $(logrotate --version 2>&1 | head -1)"
else
  log_error "logrotate 未安装"
  fail=1
fi

# journald 配置
if sudo grep -qE "^Storage=persistent" /etc/systemd/journald.conf 2>/dev/null; then
  log_ok "journald Storage=persistent"
else
  log_warn "journald 未配置 Storage=persistent（可能默认就是）"
fi
# journalctl --disk-usage 能读
if journalctl --disk-usage >/dev/null 2>&1; then
  log_ok "journalctl --disk-usage 可读"
else
  log_error "journalctl --disk-usage 不可读"
  fail=1
fi

# oslogs 别名
if [[ -f "$HOME/.bashrc" ]] && file_contains "$HOME/.bashrc" "# >>> os-config oslogs >>>"; then
  log_ok "~/.bashrc 含 oslogs 别名"
else
  log_error "$HOME/.bashrc 未找到 oslogs 别名"
  fail=1
fi
exit $fail
