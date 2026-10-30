#!/usr/bin/env bash
# engine/lib/catalog.sh —— catalog 数据层解析器
# 把 catalog/*.catalog 解析进一组关联数组；纯数据，不执行任何安装。
# 不要加 set -e。

declare -gA CAT_TYPE=() CAT_BACKEND=() CAT_PACKAGES=() CAT_VERSION=()
# version 字段的原始表达式（未展开），仅用于校验失败时提示用户改哪个变量
declare -gA CAT_VERSION_SRC=()
declare -gA CAT_COMMANDS=() CAT_TRACK=() CAT_DEPS=() CAT_DESC=()
declare -gA CAT_GROUP=() CAT_ACTION=() CAT_ARTIFACTS=() CAT_SUDO=()
declare -ga CAT_ORDER=()

# ---------------------------------------------------------------------------
# 平台相关字段（Windows 引擎 setup.ps1 读取；Bash 引擎只解析、不参与逻辑）
#
#   platforms    = linux | win | linux,win   （缺省 linux）
#   win_backend  = winget | builtin | npm
#   win_packages = winget 包 id（空格分隔；与 apt 包名不同）
#   win_commands = Windows 上的验证命令（缺省回落 commands）
#   win_version  = Windows 上锁定的版本（缺省回落 version）
#   win_artifacts= Windows 上的产物路径（展开规则同 artifacts）
#   win_deps     = 仅 Windows 生效的额外依赖
#   win_action   = Windows 上使用的动作脚本名（缺省回落 action）
#
# Bash 引擎故意不校验这些字段的内容：跨平台白名单（winget/builtin）只在
# Windows 侧有意义，在这里校验会逼迫 Linux 引擎认识它不实现的后端。
# 缺少 platforms 的条目在 Windows 上被视为不适用并被跳过。
# ---------------------------------------------------------------------------
declare -gA CAT_PLATFORMS=() CAT_WIN_BACKEND=() CAT_WIN_PACKAGES=()
declare -gA CAT_WIN_COMMANDS=() CAT_WIN_VERSION=() CAT_WIN_ARTIFACTS=()
declare -gA CAT_WIN_DEPS=() CAT_WIN_ACTION=()

CATALOG_DIR="${CATALOG_DIR:-$PROJECT_DIR/catalog}"
CATALOG_FILE=""

catalog_reset() {
  CAT_TYPE=() CAT_BACKEND=() CAT_PACKAGES=() CAT_VERSION=()
  CAT_COMMANDS=() CAT_TRACK=() CAT_DEPS=() CAT_DESC=()
  CAT_GROUP=() CAT_ACTION=() CAT_ARTIFACTS=() CAT_SUDO=()
  CAT_PLATFORMS=() CAT_WIN_BACKEND=() CAT_WIN_PACKAGES=()
  CAT_WIN_COMMANDS=() CAT_WIN_VERSION=() CAT_WIN_ARTIFACTS=()
  CAT_WIN_DEPS=() CAT_WIN_ACTION=()
  CAT_ORDER=()
}

# catalog_expand_vars <raw> —— 变量替换
#   支持 $VAR、${VAR}、${VAR:-默认值}：变量为空或未定义时使用默认值。
#   只识别 $VAR 形式；文案里的单个 $ 不会被误吞。
catalog_expand_vars() {
  local raw="$1" out="" prefix name def val
  while [[ "$raw" =~ ^([^\$]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}?(.*)$ ]]; do
    prefix="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    def="${BASH_REMATCH[4]}"
    val="${!name-}"
    if [[ -z "$val" ]]; then val="$def"; fi
    out+="$prefix"
    out+="$val"
    raw="${BASH_REMATCH[5]}"
  done
  out+="$raw"
  printf '%s' "$out"
}

_catalog_valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }
# 包名会做词拆分后传给 apt/npm/snap：不得含空白，也不得以 - 开头（避免参数注入）。
_catalog_valid_pkg_spec() { [[ "$1" =~ ^[A-Za-z0-9@][A-Za-z0-9._+/@=:~-]*$ ]]; }

# _catalog_backend_supported <backend> —— 该后端名是否已登记
#
# 正常路径读 BACKEND_SUPPORTED（engine/lib/backends.sh），避免两处白名单不一致。
# 但 catalog.sh 是可以单独 source 的数据层解析器，未加载 backends.sh 时
# BACKEND_SUPPORTED 整个数组不存在——bash 5.2 在 set -u 下访问未声明关联数组的
# 下标会直接报 "unbound variable"（已实测），因此这里显式判断数组是否已声明，
# 未声明时退回内置列表。setup.sh 与 tests/run.sh 都会先加载 backends.sh，
# 走的是第一条分支。
_catalog_backend_supported() {
  local b="$1"
  if declare -p BACKEND_SUPPORTED >/dev/null 2>&1; then
    [[ -n "${BACKEND_SUPPORTED[$b]+x}" ]] && return 0
    return 1
  fi
  case "$b" in
    apt|npm|snap|winget|builtin) return 0 ;;
    *) return 1 ;;
  esac
}

# catalog_define <id> —— 为临时（profile 内联 backend:spec）工具注册条目
catalog_define_adhoc() {
  local id="$1" backend="$2" packages="$3" commands="$4" desc="${5:-临时指定}"
  _catalog_valid_id "$id" || return 1
  _catalog_valid_pkg_spec "$packages" || {
    log_error "临时工具 $id 的包名非法：$packages（不得含空白或以 - 开头）"
    return 1
  }
  if [[ -n "${CAT_TYPE[$id]+x}" ]]; then
    if [[ "${CAT_TYPE[$id]}" == package \
          && "${CAT_BACKEND[$id]}" == "$backend" \
          && "${CAT_PACKAGES[$id]}" == "$packages" ]]; then
      return 0
    fi
    log_error "临时工具 $id 与已有 catalog 条目冲突（已有：${CAT_TYPE[$id]} ${CAT_BACKEND[$id]:-} ${CAT_PACKAGES[$id]:-}；请求：package $backend $packages）"
    return 1
  fi
  CAT_ORDER+=("$id")
  CAT_TYPE[$id]=package
  CAT_BACKEND[$id]="$backend"
  CAT_PACKAGES[$id]="$packages"
  CAT_VERSION[$id]=""
  CAT_COMMANDS[$id]="$commands"
  CAT_TRACK[$id]=latest
  CAT_DEPS[$id]=""
  CAT_DESC[$id]="$desc"
  CAT_GROUP[$id]=adhoc
  CAT_ACTION[$id]=""
  CAT_ARTIFACTS[$id]=""
  CAT_SUDO[$id]=0
  # 内联条目在两个平台都可用：用户在 Windows 上手写 winget:xxx 是常见用法。
  # 必须是空格分隔：catalog_load_file 把 platforms 的逗号规范化成空格，
  # _engine_platform_ok 按空格分词匹配。这里写逗号会让 " linux,win " 既不含
  # " linux " 也不含 " win "，内联工具在两个引擎上都被平台门静默跳过。
  CAT_PLATFORMS[$id]="linux win"
  CAT_WIN_BACKEND[$id]="$backend"
  CAT_WIN_PACKAGES[$id]="$packages"
  CAT_WIN_COMMANDS[$id]="$commands"
  CAT_WIN_VERSION[$id]=""
  CAT_WIN_ARTIFACTS[$id]=""
  CAT_WIN_DEPS[$id]=""
  CAT_WIN_ACTION[$id]=""
}

# catalog_load_file <file>
catalog_load_file() {
  local file="$1" raw line key value id="" line_no=0
  local -A seen_key=()

  [[ -f "$file" ]] || { log_error "catalog 文件不存在：$file"; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%%#*}"
    line="$(util_trim "$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      id="$(util_trim "${BASH_REMATCH[1]}")"
      _catalog_valid_id "$id" || { log_error "catalog 非法工具标识：$file:$line_no（$id）"; return 1; }
      if [[ -n "${CAT_TYPE[$id]+x}" ]]; then
        log_error "catalog 工具重复定义：$id（$file:$line_no）"
        return 1
      fi
      CAT_ORDER+=("$id")
      CAT_TYPE[$id]=package
      CAT_BACKEND[$id]=""
      CAT_PACKAGES[$id]=""
      CAT_VERSION[$id]=""
      CAT_VERSION_SRC[$id]=""
      CAT_COMMANDS[$id]=""
      CAT_TRACK[$id]=latest
      CAT_DEPS[$id]=""
      CAT_DESC[$id]=""
      CAT_GROUP[$id]=misc
      CAT_ACTION[$id]=""
      CAT_ARTIFACTS[$id]=""
      CAT_SUDO[$id]=0
      # 平台字段：缺省 linux（未声明的条目在 Windows 上不适用，由 Windows 引擎跳过）
      CAT_PLATFORMS[$id]="linux"
      CAT_WIN_BACKEND[$id]=""
      CAT_WIN_PACKAGES[$id]=""
      CAT_WIN_COMMANDS[$id]=""
      CAT_WIN_VERSION[$id]=""
      CAT_WIN_ARTIFACTS[$id]=""
      CAT_WIN_DEPS[$id]=""
      CAT_WIN_ACTION[$id]=""
      seen_key=()
      continue
    fi

    [[ -n "$id" ]] || { log_error "catalog 键值出现在任何 [工具] 段之前：$file:$line_no"; return 1; }
    [[ "$line" == *=* ]] || { log_error "catalog 格式错误：$file:$line_no（应为 key=value）"; return 1; }

    key="$(util_trim "${line%%=*}")"
    value="$(util_trim "${line#*=}")"
    # desc/group 是给人看的文案，不做变量展开：文案里的 $ 不应被静默改写。
    # artifacts 也不在这里展开：它由 catalog_expand_artifacts 在使用时展开，
    # 否则同一个路径会被展开两次（值里再出现 $ 就会被二次解释）。
    # win_artifacts 同理（${PSPROFILE} 这类标记只在 Windows 侧解析）。
    case "$key" in
      desc|group|artifacts|win_artifacts) ;;
      *) value="$(catalog_expand_vars "$value")" ;;
    esac
    # version 留一份原始表达式：展开后为空时，校验报错才能指出是哪个
    # 环境变量被设成了空值（例如 $CODEX_VERSION）。
    [[ "$key" == "version" ]] && CAT_VERSION_SRC[$id]="$value"
    [[ -n "${seen_key[$key]+x}" ]] && { log_error "catalog 键重复：$file:$line_no（$id.$key）"; return 1; }
    seen_key[$key]=1

    case "$key" in
      type)      CAT_TYPE[$id]="$value" ;;
      backend)   CAT_BACKEND[$id]="$value" ;;
      packages)  CAT_PACKAGES[$id]="$value" ;;
      version)   CAT_VERSION[$id]="$value" ;;
      commands)  CAT_COMMANDS[$id]="$value" ;;
      track)     CAT_TRACK[$id]="$value" ;;
      deps)      CAT_DEPS[$id]="${value//,/ }" ;;
      desc)      CAT_DESC[$id]="$value" ;;
      group)     CAT_GROUP[$id]="$value" ;;
      action)    CAT_ACTION[$id]="$value" ;;
      artifacts) CAT_ARTIFACTS[$id]="$value" ;;
      sudo)      CAT_SUDO[$id]="$value" ;;
      # 平台字段：Bash 引擎只存储，不参与校验与逻辑（见文件头说明）。
      # platforms 与 deps 同样把逗号规范化成空格，保证 Windows 引擎
      # （engine/lib-win/Catalog.ps1）读到的值一致，--list --json 可逐字段比对。
      platforms)     CAT_PLATFORMS[$id]="${value//,/ }" ;;
      win_backend)   CAT_WIN_BACKEND[$id]="$value" ;;
      win_packages)  CAT_WIN_PACKAGES[$id]="$value" ;;
      win_commands)  CAT_WIN_COMMANDS[$id]="$value" ;;
      win_version)   CAT_WIN_VERSION[$id]="$value" ;;
      win_artifacts) CAT_WIN_ARTIFACTS[$id]="$value" ;;
      win_deps)      CAT_WIN_DEPS[$id]="${value//,/ }" ;;
      win_action)    CAT_WIN_ACTION[$id]="$value" ;;
      *) log_error "catalog 未知字段：$file:$line_no（$id.$key）"; return 1 ;;
    esac
  done <"$file"
}

# catalog_load <dir> —— 按文件名顺序加载目录下全部 *.catalog
catalog_load() {
  local dir="${1:-$CATALOG_DIR}" file
  catalog_reset
  [[ -d "$dir" ]] || { log_error "catalog 目录不存在：$dir"; return 1; }
  local -a files=()
  while IFS= read -r file; do files+=("$file"); done < <(find "$dir" -maxdepth 1 -type f -name '*.catalog' | sort)
  (( ${#files[@]} > 0 )) || { log_error "catalog 目录为空：$dir"; return 1; }
  for file in "${files[@]}"; do
    catalog_load_file "$file" || return 1
  done
  catalog_validate || return 1
}

catalog_validate() {
  local id type backend track dep
  for id in "${CAT_ORDER[@]}"; do
    type="${CAT_TYPE[$id]}"
    case "$type" in
      package)
        # 与 BACKEND_SUPPORTED（engine/lib/backends.sh）保持一致：
        # apt/npm/snap 由 Bash 引擎实现，winget/builtin 只由 Windows 引擎实现。
        # 此处放行五个名字，让共享 catalog 可写 backend=winget；在 Linux 上
        # 遇到未实现的后端会在 backend_dispatch 明确报错（rc 2）。
        backend="${CAT_BACKEND[$id]}"
        _catalog_backend_supported "$backend" || {
          log_error "catalog [$id] backend 非法：${backend:-<空>}（应为 apt/npm/snap/winget/builtin）"
          return 1
        }
        [[ -n "${CAT_PACKAGES[$id]}" ]] || { log_error "catalog [$id] 缺少 packages"; return 1; }
        ;;
      config)
        [[ -n "${CAT_ACTION[$id]}" ]] || { log_error "catalog [$id] 缺少 action"; return 1; }
        # action 会拼进 engine/actions/<action>.sh 路径；限制为标识符以防路径穿越。
        [[ "${CAT_ACTION[$id]}" =~ ^[a-z][a-z0-9_-]*$ ]] || {
          log_error "catalog [$id] action 非法：${CAT_ACTION[$id]}（仅允许小写字母、数字、_、-）"
          return 1
        }
        ;;
      *) log_error "catalog [$id] type 非法：${type:-<空>}（应为 package/config）"; return 1 ;;
    esac
    track="${CAT_TRACK[$id]}"
    [[ "$track" == pin || "$track" == latest ]] || { log_error "catalog [$id] track 非法：$track"; return 1; }
    if [[ "$track" == pin && -z "${CAT_VERSION[$id]}" ]]; then
      # 常见成因：config/user.env 或 config/ui.env 里把该版本变量设成了空值。
      # catalog 的 packages 用 ${VAR:-默认} 有兜底，version 没有——空值会
      # 直接让整个 catalog 加载失败（所有工具都不可用），所以这里必须
      # 报得足够具体，让用户知道该改哪个键。
      local src="${CAT_VERSION_SRC[$id]:-}"
      log_error "catalog [$id] track=pin 但缺少 version${src:+（配置项 $src 被设为空值？清空会回落到默认锁定版本）}"
      return 1
    fi
    for dep in ${CAT_DEPS[$id]}; do
      [[ -n "${CAT_TYPE[$dep]+x}" ]] || { log_error "catalog [$id] 依赖未定义的工具：$dep"; return 1; }
    done
  done
}

# catalog_expand_artifacts <id> —— 展开 artifacts 路径（~ 与环境变量）
# 展开只在这里做一次：catalog 加载时不再展开 artifacts，避免二次解释。
catalog_expand_artifacts() {
  local id="$1" path
  for path in ${CAT_ARTIFACTS[$id]}; do
    path="$(catalog_expand_vars "$path")"
    printf '%s\n' "${path/#\~/$HOME}"
  done
}
