#!/bin/bash
# ==========================================
# CNB CI/CD 自动化测试与报告脚本 (Vue/TypeScript 前端版)
# 项目: av-admin-vben monorepo 共用
# 功能: 根 `pnpm run lint`、`check:type`、`av:testkit-smoke`、单 app Vite 构建、代码质量扫描；仅在失败时自动创建 Issue
# ==========================================

SCRIPT_EXIT_CODE=0

# ==========================================
# 1. 环境检查与信息收集
# ==========================================
echo "======================================================"
echo "📊 CNB CI/CD 前端测试报告脚本启动"
echo "======================================================"

REPO_SLUG="${CNB_REPO_SLUG:-avwq/avwq/av-admin-vben}"
BRANCH="${CNB_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"
COMMIT_SHA="${CNB_COMMIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')}"
COMMIT_MSG="$(git log -1 --pretty=format:'%s' 2>/dev/null || echo 'unknown')"
COMMIT_AUTHOR="$(git log -1 --pretty=format:'%an' 2>/dev/null || echo 'unknown')"
COMMIT_TIME="$(git log -1 --pretty=format:'%ci' 2>/dev/null || echo 'unknown')"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
PIPELINE_START_TIME=$(date +%s)

echo "仓库: ${REPO_SLUG}"
echo "分支: ${BRANCH}"
echo "提交: ${COMMIT_SHA} - ${COMMIT_MSG}"
echo "提交者: ${COMMIT_AUTHOR}"

# ==========================================
# 2. Git 变更统计
# ==========================================
echo ""
echo "======================================================"
echo "📈 Git 变更统计"
echo "======================================================"

GIT_FILES_CHANGED=0
GIT_INSERTIONS=0
GIT_DELETIONS=0
GIT_DIFF_SUMMARY="无变更信息"

if git rev-parse HEAD~1 >/dev/null 2>&1; then
    GIT_DIFF_STAT=$(git diff --shortstat HEAD~1 HEAD 2>/dev/null || echo "")
    if [ -n "$GIT_DIFF_STAT" ]; then
        GIT_FILES_CHANGED=$(echo "$GIT_DIFF_STAT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
        GIT_INSERTIONS=$(echo "$GIT_DIFF_STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        GIT_DELETIONS=$(echo "$GIT_DIFF_STAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
        GIT_DIFF_SUMMARY="${GIT_FILES_CHANGED} 个文件变更, +${GIT_INSERTIONS} / -${GIT_DELETIONS}"
    fi
    echo "$GIT_DIFF_SUMMARY"

    echo ""
    echo "变更文件列表 (最多 30 个):"
    git diff --name-status HEAD~1 HEAD 2>/dev/null | head -30 || echo "(无法获取)"
else
    echo "首次提交或浅克隆，跳过 diff 统计"
fi

# ==========================================
# 3. Lint（与 monorepo 根 `pnpm run lint` 对齐）
# ==========================================
echo ""
echo "======================================================"
echo "🔍 Lint（pnpm run lint）"
echo "======================================================"

ESLINT_STATUS="⏭️ 跳过"
ESLINT_ERRORS=0
ESLINT_WARNINGS=0
ESLINT_DURATION=0
ESLINT_START_TIME=$(date +%s)

# 使用根 package.json 的 lint 脚本（vsh lint），避免单仓 ./src 路径在 monorepo 根失效
if command -v pnpm &>/dev/null && [ -f "package.json" ] && grep -q '"lint"' package.json 2>/dev/null; then
    pnpm run lint 2>&1 | tee /tmp/eslint_output.log
    ESLINT_EXIT_CODE=${PIPESTATUS[0]}

    ESLINT_END_TIME=$(date +%s)
    ESLINT_DURATION=$((ESLINT_END_TIME - ESLINT_START_TIME))

    if [ $ESLINT_EXIT_CODE -eq 0 ]; then
        ESLINT_STATUS="✅ 通过"
    else
        ESLINT_STATUS="❌ 有问题"
        SCRIPT_EXIT_CODE=1
    fi

    ESLINT_ERRORS=$(grep -cE "error " /tmp/eslint_output.log 2>/dev/null || echo "0")
    ESLINT_WARNINGS=$(grep -cE "warning " /tmp/eslint_output.log 2>/dev/null || echo "0")
    ESLINT_PROBLEM_TOTAL=$(grep -oE "[0-9]+ problem" /tmp/eslint_output.log 2>/dev/null | tail -1 | grep -oE "[0-9]+" || echo "0")

    if [ "$ESLINT_PROBLEM_TOTAL" != "0" ] && [ -n "$ESLINT_PROBLEM_TOTAL" ]; then
        ESLINT_ERRORS="$ESLINT_PROBLEM_TOTAL"
    fi

    echo "${ESLINT_STATUS} (耗时: ${ESLINT_DURATION}s, 错误: ${ESLINT_ERRORS}, 警告: ${ESLINT_WARNINGS})"
else
    echo "pnpm、package.json 不可用或缺少 lint 脚本，跳过 Lint 检查"
fi

# ==========================================
# 4. TypeScript 类型检查
# ==========================================
echo ""
echo "======================================================"
echo "📝 TypeScript 类型检查"
echo "======================================================"

TS_STATUS="⏭️ 跳过"
TS_ERRORS=0
TS_DURATION=0
TS_START_TIME=$(date +%s)

if command -v pnpm &>/dev/null && [ -f "package.json" ]; then
    # 优先与 monorepo 根 `pnpm run check:type`（turbo typecheck）对齐
    if grep -q '"check:type"' package.json 2>/dev/null; then
        pnpm run check:type 2>&1 | tee /tmp/ts_output.log
    elif grep -q '"ts:check"' package.json 2>/dev/null; then
        pnpm ts:check 2>&1 | tee /tmp/ts_output.log
    else
        npx vue-tsc --noEmit 2>&1 | tee /tmp/ts_output.log
    fi
    TS_EXIT_CODE=${PIPESTATUS[0]}

    TS_END_TIME=$(date +%s)
    TS_DURATION=$((TS_END_TIME - TS_START_TIME))

    if [ $TS_EXIT_CODE -eq 0 ]; then
        TS_STATUS="✅ 通过"
    else
        TS_STATUS="❌ 有类型错误"
        SCRIPT_EXIT_CODE=1
    fi

    TS_ERRORS=$(grep -cE "error TS" /tmp/ts_output.log 2>/dev/null || echo "0")
    echo "${TS_STATUS} (耗时: ${TS_DURATION}s, 类型错误: ${TS_ERRORS})"
else
    echo "pnpm 不可用，跳过 TypeScript 类型检查"
fi

# ==========================================
# 4b. @avwq/framework-testkit smoke（与根 `pnpm run av:testkit-smoke` 对齐）
# ==========================================
echo ""
echo "======================================================"
echo "🧪 AV framework testkit smoke"
echo "======================================================"

TESTKIT_STATUS="⏭️ 跳过"
TESTKIT_DURATION=0
TESTKIT_START_TIME=$(date +%s)

if command -v pnpm &>/dev/null && [ -f "package.json" ] && grep -q '"av:testkit-smoke"' package.json 2>/dev/null; then
    pnpm run av:testkit-smoke 2>&1 | tee /tmp/testkit_output.log
    TESTKIT_EXIT_CODE=${PIPESTATUS[0]}

    TESTKIT_END_TIME=$(date +%s)
    TESTKIT_DURATION=$((TESTKIT_END_TIME - TESTKIT_START_TIME))

    if [ $TESTKIT_EXIT_CODE -eq 0 ]; then
        TESTKIT_STATUS="✅ 通过"
    else
        TESTKIT_STATUS="❌ 失败"
        SCRIPT_EXIT_CODE=1
    fi

    echo "${TESTKIT_STATUS} (耗时: ${TESTKIT_DURATION}s)"
else
    echo "pnpm、package.json 不可用或缺少 av:testkit-smoke 脚本，跳过 testkit smoke"
fi

# ==========================================
# 5. 构建测试
# ==========================================
echo ""
echo "======================================================"
echo "🔨 Vite 构建测试"
echo "======================================================"

BUILD_STATUS="⏭️ 跳过"
BUILD_DURATION=0
BUILD_START_TIME=$(date +%s)

if command -v pnpm &>/dev/null; then
    # 使用 dev 环境构建测试（monorepo：在选定 app 内构建，与 .cnb/scripts/build.sh 一致）
    BT="${BUILD_TARGET:-web-antd}"
    NODE_OPTIONS="--max-old-space-size=8192" pnpm -F "@vben/${BT}" exec vite build --mode dev 2>&1 | tee /tmp/build_output.log
    BUILD_EXIT_CODE=${PIPESTATUS[0]}

    BUILD_END_TIME=$(date +%s)
    BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))

    if [ $BUILD_EXIT_CODE -eq 0 ]; then
        BUILD_STATUS="✅ 构建成功"
    else
        BUILD_STATUS="❌ 构建失败"
        SCRIPT_EXIT_CODE=1
    fi

    # 构建产物大小统计（与 build.sh / common.sh dist_dir_of 口径一致）
    BUILD_SIZE="N/A"
    if [ -f ".cnb/scripts/common.sh" ]; then
        # shellcheck disable=SC1091
        . ".cnb/scripts/common.sh"
        _DIST_DIR="$(dist_dir_of)"
    else
        _DIST_DIR="apps/${BUILD_TARGET:-web-antd}/dist"
    fi
    if [ -d "$_DIST_DIR" ]; then
        BUILD_SIZE=$(du -sh "$_DIST_DIR" 2>/dev/null | cut -f1 || echo "N/A")
    fi

    BUILD_WARNINGS=$(grep -cE "warning" /tmp/build_output.log 2>/dev/null || echo "0")
    echo "${BUILD_STATUS} (耗时: ${BUILD_DURATION}s, 产物大小: ${BUILD_SIZE}, 警告: ${BUILD_WARNINGS})"
else
    BUILD_SIZE="N/A"
    BUILD_WARNINGS=0
    echo "pnpm 不可用，跳过构建测试"
fi

# ==========================================
# 6. 代码质量扫描
# ==========================================
echo ""
echo "======================================================"
echo "📊 代码质量扫描"
echo "======================================================"

VUE_FILE_COUNT=0
TS_FILE_COUNT=0
TOTAL_SRC_FILES=0
TODO_COUNT=0
FIXME_COUNT=0
CONSOLE_LOG_COUNT=0
ANY_TYPE_COUNT=0

# Monorepo：与 BUILD_TARGET / build.sh 选定的 app 一致，用于本节源码扫描（非仓库根单仓 src/）
APP_ROOT="apps/${BUILD_TARGET:-web-antd}"
SRC_DIR="${APP_ROOT}/src"
if [ -d "$SRC_DIR" ]; then
    VUE_FILE_COUNT=$(find "$SRC_DIR" -name "*.vue" -type f 2>/dev/null | wc -l)
    TS_FILE_COUNT=$(find "$SRC_DIR" \( -name "*.ts" -o -name "*.tsx" \) -type f 2>/dev/null | wc -l)
    TOTAL_SRC_FILES=$((VUE_FILE_COUNT + TS_FILE_COUNT))

    TODO_COUNT=$(grep -rn "TODO" "$SRC_DIR" --include="*.vue" --include="*.ts" --include="*.tsx" 2>/dev/null | wc -l)
    FIXME_COUNT=$(grep -rn "FIXME" "$SRC_DIR" --include="*.vue" --include="*.ts" --include="*.tsx" 2>/dev/null | wc -l)
    CONSOLE_LOG_COUNT=$(grep -rn "console\.log" "$SRC_DIR" --include="*.vue" --include="*.ts" --include="*.tsx" 2>/dev/null | wc -l)
    ANY_TYPE_COUNT=$(grep -rn ": any" "$SRC_DIR" --include="*.vue" --include="*.ts" --include="*.tsx" 2>/dev/null | wc -l)
fi

echo "Vue 组件: ${VUE_FILE_COUNT}"
echo "TypeScript 文件: ${TS_FILE_COUNT}"
echo "TODO 标记: ${TODO_COUNT}"
echo "FIXME 标记: ${FIXME_COUNT}"
echo "console.log: ${CONSOLE_LOG_COUNT}"
echo "any 类型: ${ANY_TYPE_COUNT}"

# 按业务域统计（当前 app 下 src/views、src/api、src/components）
echo ""
BT_LABEL="${BUILD_TARGET:-web-antd}"
echo "--- 业务域文件统计 (${APP_ROOT}) ---"
DOMAIN_STATS=""
VIEWS_DIR="${APP_ROOT}/src/views"
API_DIR="${APP_ROOT}/src/api"
COMP_DIR="${APP_ROOT}/src/components"

if [ -d "$VIEWS_DIR" ]; then
    VIEWS_VUE=$(find "$VIEWS_DIR" -name "*.vue" -type f 2>/dev/null | wc -l)
    DOMAIN_STATS="${DOMAIN_STATS}\n| ${BT_LABEL}/src/views | ${VIEWS_VUE} |"
    echo "${BT_LABEL}/src/views: ${VIEWS_VUE} 个 Vue 组件"
fi
if [ -d "$API_DIR" ]; then
    API_TS=$(find "$API_DIR" -name "*.ts" -type f 2>/dev/null | wc -l)
    DOMAIN_STATS="${DOMAIN_STATS}\n| ${BT_LABEL}/src/api | ${API_TS} |"
    echo "${BT_LABEL}/src/api: ${API_TS} 个 API 文件"
fi
if [ -d "$COMP_DIR" ]; then
    COMP_VUE=$(find "$COMP_DIR" -name "*.vue" -type f 2>/dev/null | wc -l)
    DOMAIN_STATS="${DOMAIN_STATS}\n| ${BT_LABEL}/src/components | ${COMP_VUE} |"
    echo "${BT_LABEL}/src/components: ${COMP_VUE} 个通用组件"
fi

# ==========================================
# 7. 依赖信息
# ==========================================
echo ""
echo "======================================================"
echo "📦 依赖信息"
echo "======================================================"

DEP_COUNT=0
DEV_DEP_COUNT=0
if [ -f "package.json" ]; then
    DEP_COUNT=$(grep -c '"' package.json 2>/dev/null | head -1 || echo "0")
    # 粗略统计 dependencies 和 devDependencies
    DEP_COUNT=$(node -e "const p=require('./package.json'); console.log(Object.keys(p.dependencies||{}).length)" 2>/dev/null || echo "0")
    DEV_DEP_COUNT=$(node -e "const p=require('./package.json'); console.log(Object.keys(p.devDependencies||{}).length)" 2>/dev/null || echo "0")
fi
echo "生产依赖: ${DEP_COUNT}"
echo "开发依赖: ${DEV_DEP_COUNT}"

# ==========================================
# 8. 生成报告（失败时创建 Issue）
# ==========================================
echo ""
echo "======================================================"
echo "📝 生成报告"
echo "======================================================"

PIPELINE_END_TIME=$(date +%s)
PIPELINE_DURATION=$((PIPELINE_END_TIME - PIPELINE_START_TIME))
PIPELINE_MINUTES=$((PIPELINE_DURATION / 60))
PIPELINE_SECONDS=$((PIPELINE_DURATION % 60))

if [ $SCRIPT_EXIT_CODE -eq 0 ]; then
    OVERALL_STATUS="✅ 通过"
    ISSUE_LABEL="ci-passed"
else
    OVERALL_STATUS="❌ 失败"
    ISSUE_LABEL="ci-failed"
fi

if [ "$SCRIPT_EXIT_CODE" -ne 0 ]; then
    ISSUE_TITLE="[${BRANCH}][${OVERALL_STATUS}] CI 前端测试报告 - ${TIMESTAMP}"

    ISSUE_BODY_FILE=$(mktemp)
    cat > "$ISSUE_BODY_FILE" << EOF
## 📋 CI/CD 前端自动化测试报告

### 基本信息
- **仓库**: ${REPO_SLUG}
- **分支**: \`${BRANCH}\`
- **提交**: \`${COMMIT_SHA}\` - ${COMMIT_MSG}
- **提交者**: ${COMMIT_AUTHOR}
- **提交时间**: ${COMMIT_TIME}
- **报告时间**: ${TIMESTAMP}
- **总耗时**: ${PIPELINE_MINUTES}分${PIPELINE_SECONDS}秒

### 总体结果: ${OVERALL_STATUS}

---

### 🔍 ESLint 代码检查
- **状态**: ${ESLINT_STATUS}
- **耗时**: ${ESLINT_DURATION}秒
- **错误数**: ${ESLINT_ERRORS}
- **警告数**: ${ESLINT_WARNINGS}

### 📝 TypeScript 类型检查
- **状态**: ${TS_STATUS}
- **耗时**: ${TS_DURATION}秒
- **类型错误**: ${TS_ERRORS}

### 🔨 Vite 构建测试
- **状态**: ${BUILD_STATUS}
- **耗时**: ${BUILD_DURATION}秒
- **产物大小**: ${BUILD_SIZE}
- **构建警告**: ${BUILD_WARNINGS}

### 📈 Git 变更
- **变更概要**: ${GIT_DIFF_SUMMARY}

### 📊 代码质量

| 指标 | 数值 |
|------|------|
| Vue 组件数 | ${VUE_FILE_COUNT} |
| TypeScript 文件数 | ${TS_FILE_COUNT} |
| 源文件总数 | ${TOTAL_SRC_FILES} |
| TODO 标记 | ${TODO_COUNT} |
| FIXME 标记 | ${FIXME_COUNT} |
| console.log 残留 | ${CONSOLE_LOG_COUNT} |
| any 类型使用 | ${ANY_TYPE_COUNT} |

### 📁 业务域统计
| 目录 | 文件数 |
|------|--------|$(echo -e "$DOMAIN_STATS")

### 📦 依赖信息
- **生产依赖**: ${DEP_COUNT}
- **开发依赖**: ${DEV_DEP_COUNT}

### 🖥️ 环境信息
- **Node.js**: $(node --version 2>/dev/null || echo 'unknown')
- **pnpm**: $(pnpm --version 2>/dev/null || echo 'unknown')
- **OS**: $(uname -sr 2>/dev/null || echo 'unknown')

---
*此 Issue 由 CNB CI/CD 前端自动化测试脚本自动创建*
EOF

    echo "Issue 标题: ${ISSUE_TITLE}"

    # ==========================================
    # 9. 创建 Issue (via cnb_api.sh)
    # ==========================================
    ISSUE_BODY=$(cat "$ISSUE_BODY_FILE")
    rm -f "$ISSUE_BODY_FILE"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/cnb_api.sh"

    cnb_api_create_issue "$REPO_SLUG" "$ISSUE_TITLE" "$ISSUE_BODY" "$ISSUE_LABEL"
else
    echo "总体通过，跳过创建 Issue（避免成功构建产生噪音）"
fi

# ==========================================
# 10. 完成
# ==========================================
echo ""
echo "======================================================"
echo "📊 CI/CD 前端测试报告脚本执行完成"
echo "总体结果: ${OVERALL_STATUS}"
echo "======================================================"

exit $SCRIPT_EXIT_CODE
