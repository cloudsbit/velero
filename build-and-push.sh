#!/usr/bin/env bash
# build-and-push.sh — 本地编译 Velero 镜像并推送到内网 registry (podman 路径)
#
# 等价于 `make container`(单架构) + `make push`,绕开 Makefile 的 docker-only 守卫。
# 前提: Dockerfile 为多阶段自包含(容器内编译 velero/velero-restore-helper/velero-helper)。
#
# 用法:
#   ./build-and-push.sh                        # 默认 cloudsbit/velero:main-linux-amd64
#   ./build-and-push.sh -t v1.19.0             # 自定义版本号
#   ./build-and-push.sh -l                     # 额外推 :latest
#   ./build-and-push.sh -n                     # 不用缓存全量重编
#   ./build-and-push.sh --push-only            # 跳过构建,只推送已有镜像
#   ./build-and-push.sh -N ""                  # 扁平路径(无 namespace)
#
# 可用环境变量覆盖默认值: REGISTRY / NAMESPACE / REPO / PLATFORM / GOPROXY_BUILDER

set -euo pipefail
cd "$(dirname "$0")"

# ============================ 可调参数 ============================
REGISTRY="${REGISTRY:-192.168.1.177:5000}"     # 内网 HTTP registry (registry:2, 无认证)
NAMESPACE="${NAMESPACE-cloudsbit}"             # 仓库 namespace,传空串则用扁平路径
REPO="${REPO:-velero}"
PLATFORM="${PLATFORM:-linux/amd64}"
GOPROXY_BUILDER="${GOPROXY_BUILDER:-https://goproxy.cn}"

VERSION="main"
NO_CACHE=0
PUSH_ONLY=0
ALSO_LATEST=0

usage() { sed -n '2,17p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--version)   VERSION="$2";     shift 2 ;;
        -N|--namespace) NAMESPACE="$2";   shift 2 ;;
        -n|--no-cache)  NO_CACHE=1;       shift   ;;
        --push-only)    PUSH_ONLY=1;      shift   ;;
        -l|--latest)    ALSO_LATEST=1;    shift   ;;
        -h|--help)      usage                     ;;
        *) echo "未知参数: $1 (见 --help)"; exit 1 ;;
    esac
done

ARCH_TAG="${VERSION}-${PLATFORM//\//-}"        # 例: main-linux-amd64
if [[ -n "$NAMESPACE" ]]; then
    FULL_IMAGE="${REGISTRY}/${NAMESPACE}/${REPO}"
    REGISTRY_BUILD_ARG="${REGISTRY}/${NAMESPACE}"   # 编译进 buildinfo.ImageRegistry
    REPO_PATH="${NAMESPACE}/${REPO}"                # registry API 路径
else
    FULL_IMAGE="${REGISTRY}/${REPO}"
    REGISTRY_BUILD_ARG="${REGISTRY}"
    REPO_PATH="${REPO}"
fi
ARCH_TAG_LATEST="latest"

log() { echo "[build-and-push] $*"; }

# ============================ 预检 ============================
for cmd in podman git curl; do
    command -v "$cmd" >/dev/null || { log "缺少命令: $cmd"; exit 1; }
done
[[ -f Dockerfile ]] || { log "当前目录找不到 Dockerfile"; exit 1; }
git -c safe.directory='*' rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { log "不在 git 仓库内"; exit 1; }

# insecure registry 声明: HTTP 明文 registry 必需 (等价 buildx 的 buildkitd.toml)
if ! grep -rqs "location = \"${REGISTRY}\"" /etc/containers/registries.conf /etc/containers/registries.conf.d/ 2>/dev/null; then
    log "registries.conf 缺少 ${REGISTRY} 的 insecure 声明,写入 drop-in"
    [[ $EUID -eq 0 ]] || { log "需要 root 写 registries.conf.d,或先手动配置"; exit 1; }
    mkdir -p /etc/containers/registries.conf.d
    printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "${REGISTRY}" \
        > "/etc/containers/registries.conf.d/010-local-registry.conf"
fi

# git 元数据 (对齐 Makefile:141-146 的口径)
GIT_SHA="$(git -c safe.directory='*' rev-parse HEAD)"
if [[ -n "$(git -c safe.directory='*' status --porcelain 2>/dev/null)" ]]; then
    GIT_TREE_STATE="dirty"
else
    GIT_TREE_STATE="clean"
fi

# ============================ 构建 ============================
if [[ $PUSH_ONLY -eq 0 ]]; then
    log "构建 ${FULL_IMAGE}:${ARCH_TAG}  (VERSION=${VERSION} GIT_SHA=${GIT_SHA:0:9} GIT_TREE_STATE=${GIT_TREE_STATE})"
    # --network host: 让容器内 go 拉取 goproxy.cn / 访问宿主环回代理
    # 短名解析依赖 /etc/containers/registries.conf.d 里的 unqualified-search-registries
    BUILD_ARGS=(
        --pull --network host
        --platform "${PLATFORM}"
        -t "${FULL_IMAGE}:${ARCH_TAG}"
        --build-arg "GOPROXY=${GOPROXY_BUILDER}"
        --build-arg PKG=github.com/velero-io/velero
        --build-arg BIN=velero
        --build-arg "VERSION=${VERSION}"
        --build-arg "GIT_SHA=${GIT_SHA}"
        --build-arg "GIT_TREE_STATE=${GIT_TREE_STATE}"
        --build-arg "REGISTRY=${REGISTRY_BUILD_ARG}"
        -f Dockerfile .
    )
    [[ $NO_CACHE -eq 1 ]] && BUILD_ARGS+=( --no-cache )
    podman build "${BUILD_ARGS[@]}"
    log "构建完成"
else
    log "跳过构建 (--push-only)"
fi

# ============================ 推送 ============================
# 关键: 清掉 http_proxy — HTTP_PROXY 无 no_proxy 时,对 HTTP registry 的推送会被
# 本机代理 (Privoxy) 劫持报 500
log "推送 ${FULL_IMAGE}:${ARCH_TAG}"
env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
    NO_PROXY='*' no_proxy='*' \
    podman push --quiet "${FULL_IMAGE}:${ARCH_TAG}"

if [[ $ALSO_LATEST -eq 1 ]]; then
    podman tag "${FULL_IMAGE}:${ARCH_TAG}" "${FULL_IMAGE}:${ARCH_TAG_LATEST}"
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
        NO_PROXY='*' no_proxy='*' \
        podman push --quiet "${FULL_IMAGE}:${ARCH_TAG_LATEST}"
fi

# ============================ 验证 ============================
log "验证远端 registry"
TAGS="$(curl -sf --noproxy '*' --max-time 10 "http://${REGISTRY}/v2/${REPO_PATH}/tags/list")" \
    || { log "验证失败: registry 不可达"; exit 1; }
log "远端 tags: ${TAGS}"
log "完成: ${FULL_IMAGE}:${ARCH_TAG}"
