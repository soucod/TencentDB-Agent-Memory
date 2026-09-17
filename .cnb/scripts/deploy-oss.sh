#!/usr/bin/env bash
set -euo pipefail
source .cnb/scripts/common.sh

ENV_NAME="${1:?env required}"

# 通用 OSS 凭证（从 secrets 注入）
: "${OSS_ACCESS_KEY_ID:?OSS_ACCESS_KEY_ID is required}"
: "${OSS_ACCESS_KEY_SECRET:?OSS_ACCESS_KEY_SECRET is required}"
: "${OSS_ENDPOINT:?OSS_ENDPOINT is required}"

# 根据 ENV_NAME 映射到对应的 OSS_BUCKET_*、OSS_PREFIX_*、RELEASE_*_OSS_REGION 变量
# secrets 中定义: OSS_BUCKET_PROD, OSS_PREFIX_PROD, RELEASE_PRODUCTION_OSS_REGION 等
case "${ENV_NAME}" in
  production)
    BUCKET_VAR="OSS_BUCKET_PROD"
    PREFIX_VAR="OSS_PREFIX_PROD"
    REGION_VAR="RELEASE_PRODUCTION_OSS_REGION"
    ;;
  prepare)
    BUCKET_VAR="OSS_BUCKET_PREPARE"
    PREFIX_VAR="OSS_PREFIX_PREPARE"
    REGION_VAR="RELEASE_PREPARE_OSS_REGION"
    ;;
  test)
    BUCKET_VAR="OSS_BUCKET_TEST"
    PREFIX_VAR="OSS_PREFIX_TEST"
    REGION_VAR="RELEASE_TEST_OSS_REGION"
    ;;
  dev)
    BUCKET_VAR="OSS_BUCKET_DEV"
    PREFIX_VAR="OSS_PREFIX_DEV"
    REGION_VAR="RELEASE_DEV_OSS_REGION"
    ;;
  local)
    BUCKET_VAR="OSS_BUCKET_LOCAL"
    PREFIX_VAR="OSS_PREFIX_LOCAL"
    REGION_VAR="RELEASE_LOCAL_OSS_REGION"
    ;;
  *)
    log "ERROR: Unknown ENV_NAME '${ENV_NAME}'. Supported: production, prepare, test, dev, local"
    exit 1
    ;;
esac

# 间接引用变量值
OSS_BUCKET="${!BUCKET_VAR:?${BUCKET_VAR} is required}"
OSS_PREFIX="${!PREFIX_VAR:?${PREFIX_VAR} is required}"
OSS_REGION_RAW="${!REGION_VAR:?${REGION_VAR} is required}"

# ossutil 2.0 的 --region 需要 "cn-shanghai" 格式，secrets 中是 "oss-cn-shanghai"
# 去掉 "oss-" 前缀
OSS_REGION="${OSS_REGION_RAW#oss-}"

# 处理 prefix：如果是 "/" 或空，则目标路径只用 bucket；否则拼接 prefix
if [[ "${OSS_PREFIX}" == "/" || -z "${OSS_PREFIX}" ]]; then
  OSS_DEST="oss://${OSS_BUCKET}/"
else
  # 确保 prefix 以 / 结尾
  OSS_DEST="oss://${OSS_BUCKET}/${OSS_PREFIX%/}/"
fi

# 构建输出目录：由 build.sh 写入 artifacts/.dist-path，或按 BUILD_TARGET 推导
DIST_DIR="$(dist_dir_of)"

# ossutil 2.0 版本号和下载地址
OSSUTIL_VERSION="2.2.0"
OSSUTIL_URL="https://gosspublic.alicdn.com/ossutil/v2/${OSSUTIL_VERSION}/ossutil-${OSSUTIL_VERSION}-linux-amd64.zip"
OSSUTIL_DIR="${HOME}/.local/bin"

log "Install ossutil ${OSSUTIL_VERSION} if missing"
if ! command -v ossutil >/dev/null 2>&1; then
  mkdir -p "${OSSUTIL_DIR}"
  TEMP_DIR=$(mktemp -d)
  log "Downloading ossutil ${OSSUTIL_VERSION} from ${OSSUTIL_URL}"
  curl -fsSL "${OSSUTIL_URL}" -o "${TEMP_DIR}/ossutil.zip"
  unzip -q "${TEMP_DIR}/ossutil.zip" -d "${TEMP_DIR}"
  mv "${TEMP_DIR}/ossutil-${OSSUTIL_VERSION}-linux-amd64/ossutil" "${OSSUTIL_DIR}/ossutil"
  chmod +x "${OSSUTIL_DIR}/ossutil"
  rm -rf "${TEMP_DIR}"
  export PATH="${OSSUTIL_DIR}:${PATH}"
  log "ossutil ${OSSUTIL_VERSION} installed successfully"
fi

log "Upload ${DIST_DIR}/ to ${OSS_DEST} (region: ${OSS_REGION}, recursive + update)"
# ossutil 2.0 使用 --region 指定区域（签名 v4 必需），-e/-i/-k 传递凭证，-r 递归，-u 增量，-f 强制不交互
ossutil cp -r "${DIST_DIR}/" "${OSS_DEST}" \
  --region "${OSS_REGION}" \
  -e "${OSS_ENDPOINT}" \
  -i "${OSS_ACCESS_KEY_ID}" \
  -k "${OSS_ACCESS_KEY_SECRET}" \
  -u -f
