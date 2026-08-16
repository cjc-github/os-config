#!/usr/bin/env bash
# platform.sh —— 平台识别
# 主入口 detect_platform：解析 /etc/os-release，输出平台标识（ubuntu24/ubuntu22/...）。
# 失败返回 1。setup.sh 在调用前会 source 本文件。

# 主识别函数：输出平台名到 stdout，失败 return 1
detect_platform() {
  [[ -r /etc/os-release ]] || { log_error "无法读取 /etc/os-release"; return 1; }
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  local id="${ID:-}" vid="${VERSION_ID:-}"
  log_debug "os-release: ID=$id VERSION_ID=$vid"
  case "$id/$vid" in
    ubuntu/24.04) echo ubuntu24 ;;
    ubuntu/24.10) echo ubuntu2410 ;;
    ubuntu/22.04) echo ubuntu22 ;;
    *) return 1 ;;
  esac
}

# 列出某平台目录下所有可用模块（输出：name<TAB>dir 顺序按目录字母序）
list_platform_modules() {  # <platform_dir>
  local pdir="$1" m name f
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
  # shellcheck disable=SC1090
  bash "$pdir/detect.sh"
}
