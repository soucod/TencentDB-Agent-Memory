#!/usr/bin/env bash
set -euo pipefail
source .cnb/scripts/common.sh

# 如果你确实要求必须有 token，再检查
CNB_TOKEN="${CNB_TOKEN:-}"

# ============================================================
# 第一步：安装 pnpm（使用公共镜像）
# ============================================================
# corepack 使用公共镜像下载 pnpm，因为：
# 1. pnpm 是公共包，不需要私有 registry
# 2. corepack 不支持 token 认证
# 3. 公共镜像无需认证，更可靠
export COREPACK_NPM_REGISTRY="https://registry.npmmirror.com"

log "Enable corepack & pnpm@10 (using public mirror: ${COREPACK_NPM_REGISTRY})"
corepack enable
corepack prepare pnpm@10.0.0 --activate

log "pnpm version: $(pnpm -v), node: $(node -v)"

# ============================================================
# 第二步：配置项目依赖源（使用 CNB 私有源）
# ============================================================
# CNB_NPM_REGISTRY：若未设置则给默认值（兼容 set -u）
CNB_NPM_REGISTRY="${CNB_NPM_REGISTRY:-https://registry.npmmirror.com/}"

# 可选：规范化，确保以 / 结尾，避免 auth 路径不匹配
[[ "$CNB_NPM_REGISTRY" == */ ]] || CNB_NPM_REGISTRY="${CNB_NPM_REGISTRY}/"

export CNB_NPM_REGISTRY

log "CNB_NPM_REGISTRY=$CNB_NPM_REGISTRY"

log "Write .npmrc for CNB npm registry"
# 降低并发与拉长重试，减轻 npm.cnb.cool 等 Registry 的 429（Too Many Requests）风险
cat > .npmrc <<EOF
registry=${CNB_NPM_REGISTRY}
always-auth=false
//${CNB_NPM_REGISTRY#https://}:_authToken=${CNB_TOKEN}
network-concurrency=8
fetch-retries=5
fetch-retry-mintimeout=20000
fetch-retry-maxtimeout=120000
EOF

log "Install deps"
pnpm install
