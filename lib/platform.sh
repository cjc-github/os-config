#!/usr/bin/env bash
# platform.sh —— 操作系统平台与 CPU 架构识别
# PLATFORM 按操作系统族划分（ubuntu/windows/macos/kylin/...），版本号不进入目录名。
# CPU 架构由 detect_architecture 单独识别，避免把 arch 与操作系统平台混为一类。

# 主识别函数：输出操作系统平台名到 stdout，失败 return 1。
# OS_RELEASE_FILE 可在测试中覆盖，默认读取 /etc/os-release。
detect_platform() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  [[ -r "$os_release_file" ]] || { log_error "无法读取 $os_release_file"; return 1; }

  local ID='' VERSION_ID='' ID_LIKE=''
  # shellcheck disable=SC1090
  . "$os_release_file" 2>/dev/null || true
  local id="${ID,,}" vid="${VERSION_ID:-}" id_like="${ID_LIKE,,}"
  log_debug "os-release: ID=$id VERSION_ID=$vid ID_LIKE=$id_like"

  case "$id/$vid" in
    ubuntu/22.04|ubuntu/24.04)
      echo ubuntu
      ;;
    ubuntu/*)
      log_error "已识别 Ubuntu $vid，但当前 ubuntu 平台仅验证了 22.04 和 24.04"
      return 1
      ;;
    kylin/*|kylin-desktop/*|ubuntukylin/*)
      log_error "已识别麒麟系统（ID=$id VERSION_ID=$vid），但 kylin 平台模块尚未实现"
      return 1
      ;;
    *)
      log_error "暂不支持当前系统：ID=${id:-<未知>} VERSION_ID=${vid:-<未知>}"
      return 1
      ;;
  esac
}

# CPU 架构是平台的独立属性，不用于选择 platforms/<name> 目录。
detect_architecture() {
  local machine
  machine="$(uname -m 2>/dev/null || true)"
  case "$machine" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7*) echo armhf ;;
    i386|i486|i586|i686) echo i386 ;;
    riscv64|s390x|ppc64el) echo "$machine" ;;
    '') echo unknown ;;
    *) echo "$machine" ;;
  esac
}

# 列出某平台目录下所有可用模块（输出：name<TAB>dir 顺序按目录字母序）
list_platform_modules() {  # <platform_dir>
  local pdir="$1" m name
  [[ -d "$pdir/modules" ]] || return 0
  for m in "$pdir/modules"/*/; do
    [[ -f "$m/module.conf" ]] || continue
    name=$(awk -F= '/^NAME=/{print $2; exit}' "$m/module.conf")
    [[ -n "$name" ]] || continue
    printf '%s\t%s\n' "$name" "$m"
  done
}

# 自检：调用平台自带 detect.sh（双保险）。返回 0/1
platform_selfcheck() {  # <platform_dir>
  local pdir="$1"
  [[ -f "$pdir/detect.sh" ]] || return 0
  bash "$pdir/detect.sh"
}
