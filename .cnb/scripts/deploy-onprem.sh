#!/usr/bin/env bash
set -euo pipefail
source .cnb/scripts/common.sh

ENV_NAME="${1:?env required, e.g. production/dev/local}"

: "${ONPREM_HOST:?ONPREM_HOST required}"
: "${ONPREM_PORT:=22}"
: "${ONPREM_USER:?ONPREM_USER required}"
: "${ONPREM_NGINX_DIR:?ONPREM_NGINX_DIR required}"
: "${ONPREM_SSH_PRIVATE_KEY:?ONPREM_SSH_PRIVATE_KEY required}"

# 源目录：与 build.sh 一致（artifacts/.dist-path 或 apps/<BUILD_TARGET>/dist）
DIST_DIR="$(dist_dir_of)"

# 目标目录：按环境分开，避免 local 和 dev 互相覆盖
# 例如：/usr/share/nginx/html/av-admin-vben/dev/ 或 .../av-admin-vben/local/
REMOTE_DIR="${ONPREM_NGINX_DIR}/${ENV_NAME}"

if [[ ! -d "${DIST_DIR}" ]]; then
  log "ERROR: 构建目录 ${DIST_DIR} 不存在，请先执行 build"
  exit 1
fi

log "Install rsync + ssh client"
apt-get update -qq
apt-get install -y -qq rsync openssh-client

KEY_FILE="$(mktemp)"
echo "${ONPREM_SSH_PRIVATE_KEY}" > "${KEY_FILE}"
chmod 600 "${KEY_FILE}"

SSH_OPTS="-i ${KEY_FILE} -p ${ONPREM_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 确保远程目录存在
log "Ensure remote directory exists: ${REMOTE_DIR}"
ssh ${SSH_OPTS} "${ONPREM_USER}@${ONPREM_HOST}" "mkdir -p ${REMOTE_DIR}"

log "Rsync ${DIST_DIR}/ -> ${ONPREM_USER}@${ONPREM_HOST}:${REMOTE_DIR}/"
rsync -az --delete \
  -e "ssh ${SSH_OPTS}" \
  "${DIST_DIR}/" "${ONPREM_USER}@${ONPREM_HOST}:${REMOTE_DIR}/"

# 非生产：在 nginx 宿主机上仅清理本仓库（CNB 前端制品）的陈旧未使用镜像，不影响 JDK/nginx 基础镜像
GC_SHOULD_RUN=0
case "${ENV_NAME}" in local|dev|test) GC_SHOULD_RUN=1;; esac
ONPREM_CNB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_REPO_GC="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}"
if [[ "${GC_SHOULD_RUN}" == "1" ]] && [[ -n "${CNB_DOCKER_REGISTRY:-}" ]] && [[ -n "${CNB_REPO_SLUG_LOWERCASE:-}" ]]; then
  log "Podman GC on on-prem host (repo only): ${APP_REPO_GC}"
  ssh ${SSH_OPTS} "${ONPREM_USER}@${ONPREM_HOST}" bash -s <<GC_EOF || true
$(cat "${ONPREM_CNB_DIR}/podman_gc_app_images.sh")
podman_gc_deployed_app_images "${APP_REPO_GC}" "" "${PODMAN_APP_IMAGE_MAX_AGE:-72h}"
GC_EOF
fi

rm -f "${KEY_FILE}"

log "Deploy to on-prem completed: ${REMOTE_DIR}"
