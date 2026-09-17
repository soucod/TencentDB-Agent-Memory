#!/usr/bin/env bash
# ==========================================
# 非生产部署成功后：按仓库 / tag 前缀清理陈旧未使用的应用镜像
# 不执行全库 prune；仅处理 CNB 推送的制品坐标，避免动 JDK/nginx 等基础镜像。
# 由 deploy-onprem 等在目标机上 bash -s 注入执行。
# ==========================================

# -------------------------------------------
# 将 PODMAN_APP_IMAGE_MAX_AGE（默认 72h）解析为小时数，用于计算截止时间戳。
#
# @param $1 时长字符串，如 72h、48h
# @return 通过 stdout 输出小时整数
# -------------------------------------------
_podman_gc_parse_hours() {
    local raw="${1:-72h}"
    if [[ "$raw" =~ ^([0-9]+)h$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ^([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "72"
    fi
}

# -------------------------------------------
# 规范化「仓库」字符串用于与 podman images 第一列比较。
#
# @param $1 原始 Repository 字段
# @param $2 期望的 app_repo（如 registry/namespace/name）
# -------------------------------------------
_podman_gc_repo_matches() {
    local got="$1"
    local want="$2"
    [[ -z "$want" ]] && return 1
    got="${got#localhost/}"
    [[ "$got" == "$want" ]] && return 0
    [[ "$got" == */"$want" ]] && return 0
    return 1
}

# -------------------------------------------
# 判断候选镜像 ID 是否出现在容器 Image 列表中（短 ID / 全 sha 前缀匹配，避免 Podman ancestor 过滤器差异）。
#
# @param $1 候选镜像 ID
# @param $2 由「所有容器的 .Image」拼成的字符串（空格分隔）
# @return 0=仍被引用, 1=未被引用
# -------------------------------------------
_podman_gc_id_referenced_in_blob() {
    local id="$1"
    local blob="$2"
    local x
    for x in $blob; do
        [[ -z "$x" ]] && continue
        if [[ "$x" == "$id"* ]] || [[ "$id" == "$x"* ]]; then
            return 0
        fi
    done
    return 1
}

# -------------------------------------------
# 仅删除脚本部署的应用镜像：给定制品仓库、可选 tag 前缀、最大存活时间。
# 条件：仓库匹配、（可选）tag 以前缀开头、创建时间早于 cutoff、无任何容器引用该镜像。
#
# @param $1 app_repo — 例如 ${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}
# @param $2 tag_prefix — 可选；非空时只处理 Tag 以此开头的条目（joyfulmotion 模块）；morninglight 传空
# @param $3 max_age — 可选；默认取环境变量 PODMAN_APP_IMAGE_MAX_AGE 或 72h
# -------------------------------------------
podman_gc_deployed_app_images() {
    local app_repo="${1:?app_repo required}"
    local tag_prefix="${2:-}"
    local max_age="${3:-${PODMAN_APP_IMAGE_MAX_AGE:-72h}}"

    if ! command -v podman >/dev/null 2>&1; then
        echo "🧹 [podman_gc] 跳过：未安装 podman"
        return 0
    fi

    local hours
    hours=$(_podman_gc_parse_hours "$max_age")
    local now cutoff
    now=$(date +%s)
    cutoff=$((now - hours * 3600))

    echo "🧹 [podman_gc] 仓库=${app_repo} tag_prefix=${tag_prefix:-<全部>} 保留窗口=${hours}h 截止 UNIX=${cutoff}"

    local used_blob=""
    local cid uimg uref
    for cid in $(podman ps -aq 2>/dev/null); do
        [[ -z "$cid" ]] && continue
        uimg=$(podman inspect "$cid" --format '{{.Image}}' 2>/dev/null || true)
        uref=$(podman inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null || true)
        [[ -n "$uimg" ]] && used_blob+="${uimg} "
        [[ -n "$uref" ]] && used_blob+="${uref} "
    done

    local processed=""
    local repo tag img_id
    while IFS='|' read -r repo tag img_id; do
        [[ -z "$img_id" ]] && continue
        if [[ " $processed " == *" $img_id "* ]]; then
            continue
        fi
        if ! _podman_gc_repo_matches "$repo" "$app_repo"; then
            continue
        fi
        if [[ -n "$tag_prefix" ]]; then
            if [[ "$tag" == "<none>" ]] || [[ -z "$tag" ]]; then
                continue
            fi
            case "$tag" in
                "${tag_prefix}"*) ;;
                *) continue ;;
            esac
        fi

        if [[ -n "$tag" && "$tag" != "<none>" ]]; then
            if [[ " $used_blob " == *" ${repo}:${tag} "* ]]; then
                continue
            fi
        fi
        if _podman_gc_id_referenced_in_blob "$img_id" "$used_blob"; then
            continue
        fi

        local created created_sec
        created=$(podman inspect "$img_id" --format '{{.Created}}' 2>/dev/null || true)
        [[ -z "$created" ]] && continue
        created_sec=$(date -d "$created" +%s 2>/dev/null || echo "")
        [[ -z "$created_sec" ]] && continue
        if [[ "$created_sec" -ge "$cutoff" ]]; then
            continue
        fi

        echo "🧹 [podman_gc] 删除陈旧镜像 ${repo}:${tag} (${img_id:0:12}) created=${created}"
        podman rmi "$img_id" 2>/dev/null || echo "🧹 [podman_gc] 跳过（仍有关联或无权限）: ${img_id:0:12}"
        processed+=" $img_id"
    done < <(podman images --noheading --format '{{.Repository}}|{{.Tag}}|{{.ID}}' 2>/dev/null)
}
