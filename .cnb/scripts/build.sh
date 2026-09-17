#!/usr/bin/env bash
set -euo pipefail
source .cnb/scripts/common.sh

ENV_NAME="${1:?env required, e.g. production/dev/local}"
MODE="$(vite_mode_of "$ENV_NAME")"
# 要构建的 workspace：目录 apps/<BUILD_TARGET>；包名由 pnpm_pkg_filter_of（见 common.sh）
BUILD_TARGET="${BUILD_TARGET:-web-antd}"
PKG_FILTER="$(pnpm_pkg_filter_of "$BUILD_TARGET")"
APP_DIR="apps/${BUILD_TARGET}"

log "Build env=${ENV_NAME}, vite mode=${MODE}, target=${BUILD_TARGET} (${PKG_FILTER})"
# Node.js 内存限制：8GB 足够中大型 Vue 3 项目，18GB 过于保守
export NODE_OPTIONS="--max_old_space_size=12288"

if [[ ! -d "$APP_DIR" ]] || [[ ! -f "$APP_DIR/index.html" ]]; then
  if [[ -f index.html ]]; then APP_DIR="."; log "root Vite"; else log "no apps target and no root index.html"; fi
  if [[ "$APP_DIR" != "." ]]; then exit 1; fi
fi

# ============================================================
# 清理 Vite 构建缓存
# 确保配置变更（如 manualChunks）能够生效
# 避免使用 copy-on-write 卷中的旧缓存
# ============================================================
log "🧹 清理 Vite 构建缓存..."
rm -rf node_modules/.cache 2>/dev/null || true
rm -rf node_modules/.vite 2>/dev/null || true
rm -rf "${APP_DIR}/node_modules/.vite" 2>/dev/null || true
rm -rf "${APP_DIR}/dist" 2>/dev/null || true
log "✅ 缓存已清理"

if [[ "$APP_DIR" == "." ]]; then DIST_DIR="dist"; else DIST_DIR="${APP_DIR}/dist"; fi

# 使用 pnpm -F exec：绕开各 app package.json 里写死的 --mode production
# Vite 在有弃用警告时可能返回非零退出码，但构建产物仍然成功
# 因此我们捕获退出码，然后检查输出目录是否存在
VITE_EXIT_CODE=0
run_vite_build "$MODE" || VITE_EXIT_CODE=$?

if [[ $VITE_EXIT_CODE -ne 0 ]]; then
  log "⚠️  Vite 返回退出码 $VITE_EXIT_CODE (可能有弃用警告)"
fi

# 关键检查：输出目录是否存在
if [[ ! -d "$DIST_DIR" ]]; then
  log "❌ 构建失败：${DIST_DIR} 目录不存在"
  if [[ "$APP_DIR" != "." ]]; then exit 1; fi
fi

log "✅ 构建成功：${DIST_DIR} 目录已生成"

SHA="$(short_sha)"
TS="$(build_ts)"
mkdir -p artifacts
# 供 deploy-oss / deploy-onprem 等同一次流水线内读取，避免重复解析 BUILD_TARGET
printf '%s\n' "$(pwd)/${DIST_DIR}" >artifacts/.dist-path

# 产物归档（给附件/Release 用）：在 app 目录下打包 dist，避免压缩包带 apps/... 前缀
# 归档文件名前缀与仓库一致，避免与其它业务仓（如 warmsun）产物混淆
tar -czf "artifacts/av-admin-vben-${ENV_NAME}-${TS}-${SHA}.tar.gz" -C "${APP_DIR}" dist

log "Artifacts:"
ls -lah artifacts
