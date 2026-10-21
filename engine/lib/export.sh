#!/usr/bin/env bash
# engine/lib/export.sh —— 导出当前机器状态为 profile（export 动词）
# ---------------------------------------------------------------------------
# 用途：换机器复刻。扫描 catalog，把已安装的 package 与已记录的 config
#       汇总成一个可直接使用的 profiles/*.conf，并附上导出时的生效参数
#       （写在注释里，供新机器核对 config/user.env）。
# 不要加 set -e。
# ---------------------------------------------------------------------------

EXPORT_OUTPUT="${EXPORT_OUTPUT:-$PROJECT_DIR/profiles/exported.conf}"

# _export_params —— 输出当前生效参数（注释形式，供人工核对）
_export_params() {
  printf '#\n# —— 导出时的生效参数（复制到新机器的 config/user.env）——\n'
  local key val
  for key in MIRROR_APT_URL MIRROR_APT_PORTS_URL MIRROR_SKIP_APT \
             MIRROR_SKIP_APT_UPDATE APT_UPGRADE \
             PROXY_ENABLED PROXY_HOST PROXY_PORT PROXY_TEST_URL \
             PROXY_CONNECT_TIMEOUT PROXY_MAX_TIME NO_PROXY \
             GIT_USER_NAME GIT_USER_EMAIL SSH_KEY_TYPE JOURNALD_MAX_USE \
             NODE_VERSION NODE_LTS_MAJOR NVM_VERSION NPM_REGISTRY; do
    val="${!key-}"
    if [[ -n "$val" ]]; then
      printf '#   %s=%s\n' "$key" "$val"
    else
      printf '#   %s=<未设置，走默认值>\n' "$key"
    fi
  done
}

# export_run —— 扫描 catalog 并写出 profile
export_run() {
  local -a installed=() config_ids=()
  local id
  log_section "export：把当前机器状态导出为 profile"

  for id in "${CAT_ORDER[@]}"; do
    if [[ "${CAT_TYPE[$id]}" == config ]]; then
      if state_has "$id"; then
        config_ids+=("$id")
        installed+=("$id")
      fi
    else
      if _engine_tool_installed "$id"; then
        installed+=("$id")
      fi
    fi
  done

  if (( ${#installed[@]} == 0 )); then
    log_warn "未发现已安装的工具或已应用的配置，未生成 profile"
    log_warn "先执行一次 install，或用 --pick 指定要导出的选择"
    return 1
  fi

  log_info "已安装的 catalog 条目：$(( ${#installed[@]} - ${#config_ids[@]} )) 个包 + ${#config_ids[@]} 个配置动作"

  # 按 catalog 原始顺序输出，保证 profile 解析结果与当前一致
  local -a ordered=()
  for id in "${CAT_ORDER[@]}"; do
    local i
    for i in "${installed[@]}"; do
      [[ "$i" == "$id" ]] && { ordered+=("$id"); break; }
    done
  done

  mkdir -p -- "$(dirname -- "$EXPORT_OUTPUT")" \
    || { log_error "无法创建目录：$(dirname -- "$EXPORT_OUTPUT")"; return 1; }

  local tmp
  tmp="$(mktemp "${EXPORT_OUTPUT}.XXXXXX")" \
    || { log_error "无法创建临时文件"; return 1; }

  {
    printf '# ===========================================================================\n'
    printf '# %s —— 由 ./setup.sh export 生成\n' "$(basename -- "$EXPORT_OUTPUT")"
    printf '# 生成时间：%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '# 用法：./setup.sh install --profile %s\n' "$(basename -- "${EXPORT_OUTPUT%.conf}")"
    printf '#\n'
    printf '# 本文件只含工具选择。参数不会写进 profile，请把新机器的\n'
    printf '# config/user.env 按下方注释核对一遍。\n'
    printf '# ===========================================================================\n'
    printf '\n'
    printf '[%s]\n' "$(basename -- "${EXPORT_OUTPUT%.conf}")"
    printf 'desc=由 export 生成（%s 项）\n' "${#ordered[@]}"
    printf 'extends=\n'
    printf 'tools=%s\n' "$(_export_join "${ordered[@]}")"
    printf '\n'
    _export_params
  } >"$tmp" || { rm -f -- "$tmp"; log_error "写入失败：$tmp"; return 1; }

  chmod 644 -- "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$EXPORT_OUTPUT"; then
    rm -f -- "$tmp"
    log_error "无法写入：$EXPORT_OUTPUT"
    return 1
  fi

  log_ok "已导出 ${#ordered[@]} 项 → $EXPORT_OUTPUT"
  log_info "新机器复刻：cp config/user.env.example config/user.env（按导出注释填）"
  log_info "            ./setup.sh install --profile $(basename -- "${EXPORT_OUTPUT%.conf}")"
  printf '\n%s\n' "导出的 profile（${#ordered[@]} 项）："
  local item
  for item in "${ordered[@]}"; do
    printf '  %-14s %s\n' "$item" "${CAT_DESC[$item]:-}"
  done
  return 0
}

# _export_join —— 逗号+空格拼接，供 profile 解析
_export_join() {
  local out="" i
  for i in "$@"; do
    out+="${out:+, }$i"
  done
  printf '%s\n' "$out"
}
