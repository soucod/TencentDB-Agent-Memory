#!/usr/bin/env bash
# CNB：将 @avwq/* 子包发布到私服（与 scripts/publish-av-packages.mjs 规则一致）。
# 不在 root 上 pnpm publish，避免把整个 monorepo 打成 GB 级 tarball 导致私服超时。
set -euo pipefail
source .cnb/scripts/common.sh

ENV_NAME="${1:?env required}"
PUBLISH_TAG="${2:-$ENV_NAME}"

# -----------------------------------------------------------------------------
# 发现可发布子包：与 scripts/publish-av-packages.mjs 相同（@avwq/* + publishConfig.registry）
# 输出：相对仓库根目录的路径，每行一个
# -----------------------------------------------------------------------------
discover_publish_dirs() {
  node <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.cwd();
const PREFIXES = [
  'packages/framework',
  'packages/adapter',
  'packages/business',
  'packages/preset',
  'packages/shared',
  'packages/tooling',
];
const dirs = [];
for (const prefix of PREFIXES) {
  const base = path.join(root, prefix);
  if (!fs.existsSync(base)) continue;
  for (const name of fs.readdirSync(base)) {
    const dir = path.join(base, name);
    if (!fs.statSync(dir).isDirectory()) continue;
    const pkgPath = path.join(dir, 'package.json');
    if (!fs.existsSync(pkgPath)) continue;
    const json = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    if (!json.name?.startsWith('@avwq/')) continue;
    if (!json.publishConfig?.registry) continue;
    if (json.private === true) continue;
    dirs.push(path.relative(root, dir).replace(/\\/g, '/'));
  }
}
dirs.sort();
for (const d of dirs) console.log(d);
NODE
}

mapfile -t TARGET_DIRS < <(discover_publish_dirs)

if [[ "${#TARGET_DIRS[@]}" -eq 0 ]]; then
  log "跳过：未找到任何可发布的 @avwq/* 包（需 name 以 @avwq/ 开头且含 publishConfig.registry；本仓库是站点应用而非库）"
  exit 0
fi


SHA="$(short_sha)"
TS="$(build_ts)"

: "${CNB_NPM_REGISTRY:?CNB_NPM_REGISTRY is required}"

# 设置 Node.js 内存限制，防止发布前脚本 OOM
export NODE_OPTIONS="--max_old_space_size=12288"

# npm 不允许同名同版本重复发布，而不同环境的 dist 内容不同，所以必须让"版本唯一"
BASE_VERSION="$(node -p "require('./package.json').version")"
BASE_CORE="${BASE_VERSION%%-*}"   # 去掉 -snapshot 之类 prerelease，避免拼出双 '-'

# 处理 Tag 中的特殊字符（将 / 和 _ 都替换为 -）
SAFE_TAG=$(echo "$PUBLISH_TAG" | sed 's/[\/_]/-/g')

# ============================================================================
# 版本策略：根据分支类型决定版本号格式
# - 备份型分支（av-production, av-prepare, av-test）：带时间戳，每次构建保留历史
# - 覆盖型分支（local, dev, iter* 等）：不带时间戳，覆盖前一个版本
# ============================================================================

# 判断是否为需要备份的分支（保留时间戳）
is_backup_branch() {
  local tag="$1"
  case "$tag" in
    av-production|av-prepare|av-test)
      return 0  # true: 需要备份
      ;;
    *)
      return 1  # false: 覆盖模式
      ;;
  esac
}

# 根据分支类型生成版本号
if is_backup_branch "$SAFE_TAG"; then
  NEW_VERSION="${BASE_CORE}-${SAFE_TAG}.${TS}.${SHA}"
  log "📦 [备份模式] 分支 ${SAFE_TAG} 保留历史版本"
else
  NEW_VERSION="${BASE_CORE}-${SAFE_TAG}"
  log "🔄 [覆盖模式] 分支 ${SAFE_TAG} 将覆盖前一个版本"
fi

# 收集被修改的 package.json 路径，EXIT 时用 git 恢复（不碰 root package.json）
PKGJSON_PATHS=()
for d in "${TARGET_DIRS[@]}"; do
  PKGJSON_PATHS+=("${d}/package.json")
done

# 确保脚本退出时恢复各子包 package.json
trap 'git checkout -- "${PKGJSON_PATHS[@]}" 2>/dev/null || true' EXIT

log "Publish @avwq workspace packages: count=${#TARGET_DIRS[@]}, version=${NEW_VERSION}, tag=${SAFE_TAG}, env=${ENV_NAME}"

# 为每个待发包写入同一版本号（pnpm publish 会将 workspace:* 替换为基于该版本的 semver）
for d in "${TARGET_DIRS[@]}"; do
  log "Bump version: ${d}"
  ( cd "$d" && npm version "${NEW_VERSION}" --no-git-tag-version >/dev/null )
done

# 覆盖型：逐包尝试删除 registry 上同版本（不存在则忽略）
if ! is_backup_branch "$SAFE_TAG"; then
  for d in "${TARGET_DIRS[@]}"; do
    PKG_NAME="$(node -p "require('./${d}/package.json').name")"
    log "尝试删除旧版本（覆盖）: ${PKG_NAME}@${NEW_VERSION}"
    if npm unpublish "${PKG_NAME}@${NEW_VERSION}" --registry "${CNB_NPM_REGISTRY}" --force 2>/dev/null; then
      log "已删除: ${PKG_NAME}@${NEW_VERSION}"
    else
      log "旧版本不存在或无法删除，继续发布..."
    fi
  done
fi

# 逐包发布（与 publish-av-packages.mjs 一致）；--ignore-scripts 避免 prepare/lefthook 等
for d in "${TARGET_DIRS[@]}"; do
  log "Publishing ${d} …"
  publish_args=(
    pnpm publish
    --no-git-checks
    --ignore-scripts
    --access public
    --tag "${SAFE_TAG}"
    --registry "${CNB_NPM_REGISTRY}"
  )
  if [[ "${DRY_RUN:-}" == "1" ]]; then
    log "DRY_RUN=1: append --dry-run (no upload)"
    publish_args+=(--dry-run)
  fi
  ( cd "$d" && "${publish_args[@]}" )
done

log "✅ Publish npm 完成（${#TARGET_DIRS[@]} 个包）"
