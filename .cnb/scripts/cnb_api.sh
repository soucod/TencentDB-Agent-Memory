#!/bin/bash
# ==========================================
# CNB Open API 函数库 v1.1
# 提供 CNB 平台 API 调用的统一封装
# 环境自适应: python3 / node / sed 降级
# v1.1: 适配 eclipse-temurin-22+ / JDK25 镜像 (常缺 curl)，apt 安装工具、wget POST 后备
# ==========================================

if [ -n "$_CNB_API_LOADED" ]; then
    return 0 2>/dev/null || true
fi
_CNB_API_LOADED=1

# -------------------------------------------
# 在 Debian/Ubuntu 系 Maven 镜像中补齐 curl 与 python3，便于 JSON 与 API 调用
# eclipse-temurin-22+ 基础镜像可能刻意移除 curl 以减小 CVE 面
# -------------------------------------------
_cnb_ensure_cli_tools() {
    local need_apt=0
    command -v curl &>/dev/null || need_apt=1
    command -v python3 &>/dev/null || need_apt=1

    if [ "$need_apt" -eq 0 ]; then
        return 0
    fi

    if ! command -v apt-get &>/dev/null; then
        echo "⚠️ 未找到 apt-get，且缺少 curl/python3，请改用含 curl 的镜像或在流水线中预装依赖"
        return 1
    fi

    echo "📦 Maven/Temurin 镜像缺少 curl 或 python3，尝试 apt-get 安装..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq; then
        echo "⚠️ apt-get update 失败"
        return 1
    fi
    if ! apt-get install -y -qq --no-install-recommends curl ca-certificates python3-minimal; then
        echo "⚠️ apt-get install curl/python3-minimal 失败"
        return 1
    fi
    return 0
}

# -------------------------------------------
# 使用 curl 或 wget 发起 POST，将 HTTP 状态码写入全局变量 _CNB_LAST_HTTP_CODE
# 参数: URL JSON文件路径 响应体输出路径
# -------------------------------------------
_cnb_http_post_json_file() {
    local url="$1"
    local jsonfile="$2"
    local outfile="$3"
    _CNB_LAST_HTTP_CODE=""

    if command -v curl &>/dev/null; then
        _CNB_LAST_HTTP_CODE=$(curl -s -w "%{http_code}" -o "$outfile" \
            -X POST "$url" \
            -H "Accept: application/vnd.cnb.api+json" \
            -H "Authorization: Bearer ${CNB_TOKEN}" \
            -H "Content-Type: application/json" \
            -d @"$jsonfile" \
            --connect-timeout 15 \
            --max-time 30)
        return 0
    fi

    if command -v wget &>/dev/null; then
        local hdr
        hdr=$(mktemp)
        wget -q -S -O "$outfile" \
            --content-on-error \
            --header="Accept: application/vnd.cnb.api+json" \
            --header="Authorization: Bearer ${CNB_TOKEN}" \
            --header="Content-Type: application/json" \
            --post-file="$jsonfile" \
            "$url" 2>"$hdr" || true
        _CNB_LAST_HTTP_CODE=$(grep -E '^[[:space:]]*HTTP/' "$hdr" | tail -1 | awk '{ print $2 }')
        rm -f "$hdr"
        [ -n "$_CNB_LAST_HTTP_CODE" ]
        return 0
    fi

    return 1
}

# -------------------------------------------
# 内部函数: 对字符串做 JSON 字符串转义 (用于无 python/node 时的降级路径)
# -------------------------------------------
_cnb_json_escape_string() {
    if command -v python3 &>/dev/null; then
        printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null && return 0
    fi
    if command -v node &>/dev/null; then
        printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>console.log(JSON.stringify(s).slice(1,-1)))' 2>/dev/null && return 0
    fi
    printf '%s' "$1" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e 's/\n/\\n/g'
}

# -------------------------------------------
# 内部函数: 构造 JSON 并写入文件
# -------------------------------------------
_cnb_build_json() {
    local OUT_FILE="$1"
    local TITLE="$2"
    local BODY="$3"
    local LABEL="$4"

    if command -v python3 &>/dev/null; then
        if [ -n "$LABEL" ]; then
            python3 -c "
import json, sys
title = sys.argv[1]
body = sys.argv[2]
label = sys.argv[3]
print(json.dumps({'title': title, 'body': body, 'labels': ['ci-report', label]}))
" "$TITLE" "$BODY" "$LABEL" > "$OUT_FILE" 2>/dev/null
        else
            python3 -c "
import json, sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2]}))
" "$TITLE" "$BODY" > "$OUT_FILE" 2>/dev/null
        fi
        [ $? -eq 0 ] && [ -s "$OUT_FILE" ] && return 0
    fi

    if command -v node &>/dev/null; then
        if [ -n "$LABEL" ]; then
            node -e "
const title = process.argv[1];
const body = process.argv[2];
const label = process.argv[3];
console.log(JSON.stringify({title, body, labels: ['ci-report', label]}));
" "$TITLE" "$BODY" "$LABEL" > "$OUT_FILE" 2>/dev/null
        else
            node -e "
const title = process.argv[1];
const body = process.argv[2];
console.log(JSON.stringify({title, body}));
" "$TITLE" "$BODY" > "$OUT_FILE" 2>/dev/null
        fi
        [ $? -eq 0 ] && [ -s "$OUT_FILE" ] && return 0
    fi

    local ESC_TITLE ESC_BODY
    ESC_TITLE=$(_cnb_json_escape_string "$TITLE")
    ESC_BODY=$(_cnb_json_escape_string "$BODY")
    if [ -n "$LABEL" ]; then
        local ESC_LABEL
        ESC_LABEL=$(_cnb_json_escape_string "$LABEL")
        printf '{"title":"%s","body":"%s","labels":["ci-report","%s"]}' "$ESC_TITLE" "$ESC_BODY" "$ESC_LABEL" > "$OUT_FILE"
    else
        printf '{"title":"%s","body":"%s"}' "$ESC_TITLE" "$ESC_BODY" > "$OUT_FILE"
    fi
    [ -s "$OUT_FILE" ] && return 0

    return 1
}

# -------------------------------------------
# 内部函数: 从 API 响应中提取 Issue 编号
# -------------------------------------------
_cnb_parse_issue_number() {
    local RESP_FILE="$1"

    if command -v python3 &>/dev/null; then
        python3 -c "import json; d=json.load(open(r'''$RESP_FILE''')); print(d.get('number','?'))" 2>/dev/null && return
    fi

    if command -v node &>/dev/null; then
        node -e "const fs=require('fs'); const d=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log(d.number||'?')" "$RESP_FILE" 2>/dev/null && return
    fi

    echo "?"
}

# -------------------------------------------
# 公开函数: 创建 CNB Issue
# -------------------------------------------
cnb_api_create_issue() {
    local REPO_SLUG="$1"
    local TITLE="$2"
    local BODY="$3"
    local LABEL="${4:-}"
    local API_ENDPOINT="${CNB_API_ENDPOINT:-https://api.cnb.cool}"

    echo ""
    echo "======================================================"
    echo "📮 创建 Issue"
    echo "======================================================"

    if [ -z "${CNB_TOKEN}" ]; then
        echo "⚠️ CNB_TOKEN 未设置，跳过 Issue 创建"
        echo "报告内容已输出到构建日志"
        return 0
    fi

    _cnb_ensure_cli_tools || true

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo "⚠️ 无 curl 且无 wget，跳过 Issue 创建"
        echo "报告内容已输出到构建日志"
        return 0
    fi

    echo "🔧 REPO_SLUG=${REPO_SLUG}  CNB_API_ENDPOINT=${API_ENDPOINT}"

    local JSON_FILE
    JSON_FILE=$(mktemp)

    if ! _cnb_build_json "$JSON_FILE" "$TITLE" "$BODY" "$LABEL"; then
        _cnb_build_json "$JSON_FILE" "$TITLE" "$BODY" ""
    fi

    if [ ! -s "$JSON_FILE" ]; then
        echo "⚠️ JSON 构造失败，跳过 Issue 创建"
        rm -f "$JSON_FILE"
        return 1
    fi

    local RESP_FILE="/tmp/cnb_issue_response_$$.json"
    echo "请求: POST ${API_ENDPOINT}/${REPO_SLUG}/-/issues"

    if ! _cnb_http_post_json_file "${API_ENDPOINT}/${REPO_SLUG}/-/issues" "$JSON_FILE" "$RESP_FILE"; then
        echo "⚠️ HTTP 客户端不可用"
        rm -f "$JSON_FILE" "$RESP_FILE"
        return 1
    fi

    local HTTP_STATUS="$_CNB_LAST_HTTP_CODE"
    rm -f "$JSON_FILE"

    if [ "$HTTP_STATUS" -ge 200 ] 2>/dev/null && [ "$HTTP_STATUS" -lt 300 ] 2>/dev/null; then
        local ISSUE_NUMBER
        ISSUE_NUMBER=$(_cnb_parse_issue_number "$RESP_FILE")
        echo "✅ Issue #${ISSUE_NUMBER} 创建成功 (HTTP ${HTTP_STATUS})"
        rm -f "$RESP_FILE"
        return 0
    fi

    echo "⚠️ Issue 创建失败 (HTTP ${HTTP_STATUS})"
    cat "$RESP_FILE" 2>/dev/null || true
    echo ""
    echo "尝试精简 body 重试..."

    local FALLBACK_FILE
    FALLBACK_FILE=$(mktemp)
    local FALLBACK_BODY="CI 测试报告已生成，详情请查看构建日志。"
    _cnb_build_json "$FALLBACK_FILE" "$TITLE" "$FALLBACK_BODY" ""

    local RETRY_RESP="/tmp/cnb_issue_retry_$$.json"
    if _cnb_http_post_json_file "${API_ENDPOINT}/${REPO_SLUG}/-/issues" "$FALLBACK_FILE" "$RETRY_RESP"; then
        local RETRY_STATUS="$_CNB_LAST_HTTP_CODE"
        rm -f "$FALLBACK_FILE"
        if [ "$RETRY_STATUS" -ge 200 ] 2>/dev/null && [ "$RETRY_STATUS" -lt 300 ] 2>/dev/null; then
            local ISSUE_NUMBER
            ISSUE_NUMBER=$(_cnb_parse_issue_number "$RETRY_RESP")
            echo "✅ 精简 Issue #${ISSUE_NUMBER} 创建成功 (HTTP ${RETRY_STATUS})"
        else
            echo "⚠️ 精简 Issue 也失败 (HTTP ${RETRY_STATUS})"
        fi
    else
        rm -f "$FALLBACK_FILE"
        echo "⚠️ 重试请求发送失败"
    fi

    rm -f "$RESP_FILE" "$RETRY_RESP"
    return 0
}
