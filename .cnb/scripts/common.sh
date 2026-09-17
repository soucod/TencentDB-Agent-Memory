#!/usr/bin/env bash
# 仅在直接执行本文件时启用严格模式；被 source 时不改变调用方 shell 选项（如 ci_report.sh）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

log() { printf "\n[%s] %s\n" "$(date '+%F %T')" "$*"; }

# 用于生成唯一版本/产物名，避免 npm 版本冲突
short_sha() {
  git rev-parse --short=8 HEAD
}

build_ts() {
  date '+%Y%m%d%H%M%S'
}

# 将“环境名”映射到 vite mode
vite_mode_of() {
  case "$1" in
    production) echo "production" ;;
    prepare) echo "prepare" ;;
    test) echo "test" ;;
    dev) echo "dev" ;;
    local) echo "local.development" ;;
    *) echo "dev" ;;
  esac
}

# 将 BUILD_TARGET（apps 子目录名）映射为 pnpm -F 的包名；fork 中 AV 沙箱不在 @vben scope。
pnpm_pkg_filter_of() {
  local target="${1:-web-antd}"
  case "$target" in
    web-ele-playground) printf '%s' '@avwq/web-ele-playground' ;;
    *) printf '%s' "@vben/${target}" ;;
  esac
}

# 解析 Vite 构建产物目录：优先使用 build.sh 写入的绝对路径，否则按 BUILD_TARGET 推导
dist_dir_of() {
  local marker="artifacts/.dist-path"
  if [[ -f "$marker" ]]; then
    tr -d '\r\n' <"$marker"
    return 0
  fi
  local target="${BUILD_TARGET:-web-antd}"
  if [[ -f index.html && -d dist ]]; then echo dist; else echo "apps/${target}/dist"; fi
}

run_vite_build() {
  local mode="$1"
  if [[ "${APP_DIR:-}" == "." ]]; then
    command pnpm exec vite build --mode "$mode"
  else
    command pnpm -F "${PKG_FILTER}" exec vite build --mode "$mode"
  fi
}
