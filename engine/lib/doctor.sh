#!/usr/bin/env bash
# engine/lib/doctor.sh —— 环境体检（doctor 动词）
# ---------------------------------------------------------------------------
# 用途：新机器初始化失败时一次性定位原因——sudo、磁盘、apt 锁、网络、
#       清单一致性、目录权限。全部只读，不改任何东西。
# 返回值：0=全部通过（允许 warn），1=存在 fail
# 不要加 set -e。
# ---------------------------------------------------------------------------

declare -g  DOCTOR_OK=0
declare -g  DOCTOR_WARN=0
declare -g  DOCTOR_FAIL=0

# _doctor_check <名字> <提示> <函数>
# 检查函数约定：0=ok 1=fail 2=warn；输出留在函数里（用 log_*）
_doctor_check() {
  local name="$1" hint="$2" fn="$3" rc
  log_info "[doctor] $name —— $hint"
  "$fn"
  rc=$?
  case "$rc" in
    0)
      log_ok "[doctor] $name：通过"
      DOCTOR_OK=$((DOCTOR_OK + 1))
      ;;
    2)
      log_warn "[doctor] $name：需关注"
      DOCTOR_WARN=$((DOCTOR_WARN + 1))
      ;;
    *)
      log_error "[doctor] $name：未通过"
      DOCTOR_FAIL=$((DOCTOR_FAIL + 1))
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 各项检查
# ---------------------------------------------------------------------------
_doctor_catalog() {
  local n="${#CAT_ORDER[@]}"
  if (( n == 0 )); then
    log_error "catalog 为空，无法工作"
    return 1
  fi
  log_info "catalog 条目：$n 个"
  return 0
}

_doctor_sudo() {
  if sudo_available; then
    log_info "sudo 可用（sudo -n true 通过）"
    return 0
  fi
  if cmd_exists sudo; then
    log_warn "sudo 存在但免密不可用；非交互场景需要先 sudo -v"
    return 2
  fi
  log_error "缺少 sudo，所有需要提权的动作都无法执行"
  return 1
}

_doctor_disk() {
  local avail out
  out="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')" || out=""
  if [[ ! "$out" =~ ^[0-9]+$ ]]; then
    log_warn "无法读取根分区剩余空间"
    return 2
  fi
  avail=$((out / 1024))
  log_info "根分区剩余：${avail}MB"
  if (( avail < 512 )); then
    log_error "磁盘剩余不足 512MB，安装大概率失败"
    return 1
  fi
  if (( avail < 2048 )); then
    log_warn "磁盘剩余不足 2GB，建议先清理"
    return 2
  fi
  return 0
}

_doctor_apt_lock() {
  if cmd_exists fuser && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    log_error "dpkg 锁被占用（可能有其他 apt/dpkg 在运行）"
    return 1
  fi
  log_info "dpkg 锁未被占用"
  return 0
}

_doctor_commands() {
  local -a missing=()
  local c
  for c in curl git; do
    cmd_exists "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    log_warn "缺少基础命令：${missing[*]}（多数配置动作依赖它们）"
    return 2
  fi
  log_info "基础命令齐全：curl git"
  return 0
}

_doctor_mirror() {
  local url="${MIRROR_APT_URL:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu}"
  cmd_exists curl || return 2
  if curl -fsSI -o /dev/null --connect-timeout 5 --max-time 10 "$url" 2>/dev/null; then
    log_info "镜像源可达：$url"
    return 0
  fi
  log_warn "镜像源不可达：$url（换源动作可能失败）"
  return 2
}

_doctor_proxy() {
  [[ "${PROXY_ENABLED:-true}" == "true" ]] || { log_info "代理未启用，跳过"; return 0; }
  cmd_exists curl || return 2
  local host port url rc
  host="${PROXY_HOST:-}"; port="${PROXY_PORT:-7890}"
  if [[ -z "$host" ]]; then
    host="$(_doctor_default_host)" || { log_warn "无法推导代理主机"; return 2; }
  fi
  url="http://${host}:${port}"
  if check_proxy_host_reachable "$host"; then
    log_info "代理主机可达：$host"
  else
    rc=$?
    if (( rc == 2 )); then
      log_warn "缺少 ping，无法检查代理主机"
      return 2
    fi
    log_warn "代理主机不可达：$host（代理类动作会失败）"
    return 2
  fi
  if ensure_proxy_curl_connectivity "$url" >/dev/null 2>&1; then
    log_info "代理连通性正常：$url"
    return 0
  fi
  log_warn "代理不可用：$url（shell/Git 代理写入后无法访问外网）"
  return 2
}

# 与 util.sh 的代理推导同源，但 doctor 只在 util 未给出主机时兜底
_doctor_default_host() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "${ip%.*}.1"
}

_doctor_manifest() {
  if [[ ! -f "$STATE_FILE" ]]; then
    log_info "尚无状态清单（尚未执行过写操作）"
    return 0
  fi
  local -A seen=()
  local line tool action artifact _ts missing=0 total=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS='|' read -r tool action artifact _ts <<<"$line"
    [[ "$artifact" != "-" ]] || continue
    total=$((total + 1))
    # "a b" 形式的多个路径（artifacts 展开后可能含空格分隔的多项）
    local p
    for p in $artifact; do
      if [[ ! -e "$p" ]]; then
        log_warn "清单记录的产物已消失：$p（tool=$tool）"
        missing=$((missing + 1))
      fi
    done
    seen["$tool"]=1
  done <"$STATE_FILE"
  log_info "清单产物：$total 项，缺失 $missing 项，涉及 ${#seen[@]} 个工具"
  if (( missing > 0 )); then
    log_warn "产物缺失说明配置被外部改动过；可运行 verify --fix 修复"
    return 2
  fi
  return 0
}

_doctor_state_dir() {
  if [[ ! -d "${STATE_DIR:-}" ]]; then
    log_info "状态目录尚未创建（首次写操作时创建）"
    return 0
  fi
  local mode
  mode="$(stat -c '%a' -- "$STATE_DIR" 2>/dev/null || echo "")"
  if [[ "$mode" == "700" ]]; then
    log_info "状态目录权限 700：$STATE_DIR"
    return 0
  fi
  log_warn "状态目录权限为 ${mode:-未知}（期望 700）：$STATE_DIR"
  return 2
}

_doctor_profiles() {
  local n="${#PROF_ORDER[@]}"
  if (( n == 0 )); then
    log_warn "profiles 为空，只能用 --pick/--all 选择"
    return 2
  fi
  log_info "profiles：$n 个（${PROF_ORDER[*]}）"
  return 0
}

# ---------------------------------------------------------------------------
# 编排入口
# ---------------------------------------------------------------------------
doctor_run() {
  DOCTOR_OK=0; DOCTOR_WARN=0; DOCTOR_FAIL=0
  events_emit run_start "\"verb\":\"doctor\",\"dry_run\":false,\"phase\":\"doctor\",\"ids\":[]"
  log_section "doctor：环境体检"

  _doctor_check "catalog"  "数据层是否可加载"                 _doctor_catalog
  _doctor_check "profiles" "选择清单是否可用"                 _doctor_profiles
  _doctor_check "sudo"     "提权能力"                         _doctor_sudo
  _doctor_check "disk"     "磁盘剩余空间"                     _doctor_disk
  _doctor_check "apt-lock" "是否有其他包管理进程占用"           _doctor_apt_lock
  _doctor_check "commands" "基础命令是否齐全"                 _doctor_commands
  _doctor_check "mirror"   "APT 镜像源是否可达"               _doctor_mirror
  _doctor_check "proxy"    "代理主机与连通性"                 _doctor_proxy
  _doctor_check "manifest" "状态清单与磁盘是否一致"            _doctor_manifest
  _doctor_check "state"    "状态目录权限"                     _doctor_state_dir

  log_section "doctor 汇总：通过 $DOCTOR_OK / 需关注 $DOCTOR_WARN / 未通过 $DOCTOR_FAIL"
  if (( DOCTOR_FAIL > 0 )); then
    log_error "存在未通过项，请先处理后再执行 install"
    return 1
  fi
  if (( DOCTOR_WARN > 0 )); then
    log_warn "存在需关注项，不影响继续使用"
  fi
  events_emit run_end "\"verb\":\"doctor\",\"phase\":\"doctor\",\"ok\":$DOCTOR_OK,\"skipped\":$DOCTOR_WARN,\"failed\":$DOCTOR_FAIL,\"rc\":$([[ $DOCTOR_FAIL -eq 0 ]] && echo 0 || echo 1),\"rolled_back\":false"
  return $(( DOCTOR_FAIL > 0 ? 1 : 0 ))
}
