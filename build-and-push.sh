#!/usr/bin/env bash
# build-and-push.sh — 本地编译 Velero 并推送到内网 registry (podman 路径)
#
# 两种模式:
#   默认   编译 Velero 镜像(多阶段 Dockerfile,容器内编译)并推送
#   -b     只编译本地二进制到 _output/bin/<os>/<arch>/,不构建镜像
#
# 构建加速(国内环境):
#   - 基础镜像自动"种子"到内网 registry(幂等,缺了才拉/推), FROM 重写为内网路径走 LAN;
#     内网 registry 不可达时自动回退到镜像加速链(daocloud/163 已死,现仅 1ms.run 可用)
#   - 镜像构建使用自动生成的 _output/Dockerfile.dev(不改上游 Dockerfile):
#     RUN 注入 go module/编译缓存挂载, 移除 go clean —— Go 依赖只下载一次
#   - 二进制模式(-b)用 bind mount 把 Go 缓存持久化到 .go/pkg 与 .go/go-build
#     (与 Makefile 的 build-dirs 缓存目录约定一致, 宿主机可直接复用)
#
# 用法:
#   ./build-and-push.sh                          # 默认推 cloudsbit/velero:<VERSION> (裸版本 tag)
#   ./build-and-push.sh -t v1.19.0-dryrun.1      # 指定版本号(同时烧录进 buildinfo)
#   ./build-and-push.sh -b                       # 只编译本地二进制(不构建/推送镜像)
#   ./build-and-push.sh -b -P linux/arm64        # -b 可用 PLATFORM 环境变量交叉编译
#   ./build-and-push.sh -l                       # 额外推 :latest
#   ./build-and-push.sh -a                       # 额外推架构后缀 tag (<VERSION>-linux-amd64)
#   ./build-and-push.sh -n                       # 不用层缓存全量重编(缓存挂载仍生效)
#   ./build-and-push.sh -P                       # 强制重拉基础镜像(默认本地有就复用)
#   ./build-and-push.sh --push-only              # 跳过构建,只推送已有镜像
#   ./build-and-push.sh -N ""                    # 扁平路径(无 namespace)
#   ./build-and-push.sh --gen-dockerfile-only    # 只生成 Dockerfile.dev 并退出(调试)
#
# 可用环境变量覆盖默认值: REGISTRY / NAMESPACE / REPO / PLATFORM / GOPROXY_BUILDER / BASE_SEED

set -euo pipefail
cd "$(dirname "$0")"

# ============================ 可调参数 ============================
REGISTRY="${REGISTRY:-192.168.1.177:5000}"     # 内网 HTTP registry (registry:2, 无认证)
NAMESPACE="${NAMESPACE-cloudsbit}"             # 仓库 namespace,传空串则用扁平路径
REPO="${REPO:-velero}"
PLATFORM="${PLATFORM:-linux/amd64}"
GOPROXY_BUILDER="${GOPROXY_BUILDER:-https://goproxy.cn}"
BASE_SEED="${BASE_SEED-$REGISTRY}"             # 基础镜像种子库前缀,设为空串可禁用 FROM 重写

VERSION="main"
BIN_MODE=0
NO_CACHE=0
PUSH_ONLY=0
ALSO_LATEST=0
ALSO_ARCH=0
PULL_BASE=0
GEN_ONLY=0

usage() { sed -n '2,27p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--version)   VERSION="$2";     shift 2 ;;
        -N|--namespace) NAMESPACE="$2";   shift 2 ;;
        -b|--binaries)  BIN_MODE=1;       shift   ;;
        -n|--no-cache)  NO_CACHE=1;       shift   ;;
        --push-only)    PUSH_ONLY=1;      shift   ;;
        -l|--latest)    ALSO_LATEST=1;    shift   ;;
        -a|--arch-tag)  ALSO_ARCH=1;      shift   ;;
        -P|--pull-base) PULL_BASE=1;      shift   ;;
        --gen-dockerfile-only) GEN_ONLY=1; shift  ;;
        -h|--help)      usage                     ;;
        *) echo "未知参数: $1 (见 --help)"; exit 1 ;;
    esac
done

# 主 tag = 裸版本号 (如 v1.19.0-dryrun.1); 架构后缀 tag 为可选 (-a)
PRIMARY_TAG="${VERSION}"
ARCH_TAG="${VERSION}-${PLATFORM//\//-}"        # 例: v1.19.0-dryrun.1-linux-amd64
if [[ -n "$NAMESPACE" ]]; then
    FULL_IMAGE="${REGISTRY}/${NAMESPACE}/${REPO}"
    REGISTRY_BUILD_ARG="${REGISTRY}/${NAMESPACE}"   # 编译进 buildinfo.ImageRegistry
    REPO_PATH="${NAMESPACE}/${REPO}"                # registry API 路径
else
    FULL_IMAGE="${REGISTRY}/${REPO}"
    REGISTRY_BUILD_ARG="${REGISTRY}"
    REPO_PATH="${REPO}"
fi

log() { echo "[build-and-push] $*"; }
# 内网 registry 是 HTTP 明文: HTTP_PROXY 不清洗会被本机代理 (Privoxy) 劫持报 500
# 注意 "$@" 必须显式转发: 函数不会自动把参数传给内部的 env
proxy_clean() {
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
        NO_PROXY='*' no_proxy='*' "$@"
}

# ============================ 预检 ============================
for cmd in podman git curl; do
    command -v "$cmd" >/dev/null || { log "缺少命令: $cmd"; exit 1; }
done
git -c safe.directory='*' rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { log "不在 git 仓库内"; exit 1; }

# git 元数据 (对齐 Makefile:141-146 的口径)
GIT_SHA="$(git -c safe.directory='*' rev-parse HEAD)"
if [[ -n "$(git -c safe.directory='*' status --porcelain 2>/dev/null)" ]]; then
    GIT_TREE_STATE="dirty"
else
    GIT_TREE_STATE="clean"
fi

# ==================== 本地二进制编译模式 (-b) ====================
# 容器内 Go 交叉编译 hack/build.sh (CGO_ENABLED=0);
# Go 缓存 bind mount 到 .go/ 宿主目录, 跨构建持久且比 buildah cache mount 更直观
compile_binaries() {
    local os="${PLATFORM%%/*}" arch="${PLATFORM##*/}"
    local outdir="_output/bin/${os}/${arch}"
    [[ -f hack/build.sh ]] || { log "找不到 hack/build.sh"; exit 1; }
    mkdir -p "$outdir" .go/pkg .go/go-build
    log "编译本地二进制 (${os}/${arch}) → ${outdir}/"
    log "编译列表: velero velero-restore-helper velero-helper  (VERSION=${VERSION})"
    log "Go 缓存持久化: .go/pkg (GOMODCACHE), .go/go-build (GOCACHE)"
    proxy_clean podman run --rm --network host \
        -v "$PWD":/src \
        -v "$PWD/.go/pkg":/go/pkg \
        -v "$PWD/.go/go-build":/root/.cache/go-build \
        -w /src \
        -e "GOPROXY=${GOPROXY_BUILDER}" \
        -e "PKG=github.com/velero-io/velero" \
        -e "GOOS=${os}" -e "GOARCH=${arch}" \
        -e "VERSION=${VERSION}" \
        -e "REGISTRY=${REGISTRY_BUILD_ARG}" \
        -e "GIT_SHA=${GIT_SHA}" \
        -e "GIT_TREE_STATE=${GIT_TREE_STATE}" \
        -e "OUTDIR=${outdir}" \
        docker.io/library/golang:1.27-trixie \
        /bin/sh -ec '
            for b in velero velero-restore-helper velero-helper; do
                echo "[compile] ${b}"
                BIN=${b} GOBIN=/tmp/gobin OUTPUT_DIR=/src/${OUTDIR} ./hack/build.sh
            done
        '
    log "编译完成:"
    ls -lh "$outdir"
}

if [[ $BIN_MODE -eq 1 ]]; then
    compile_binaries
    exit 0
fi

# ==================== 镜像构建模式 (默认) ====================
[[ -f Dockerfile ]] || { log "当前目录找不到 Dockerfile"; exit 1; }

# insecure registry 声明: HTTP 明文 registry 必需 (等价 buildx 的 buildkitd.toml)
if ! grep -rqs "location = \"${REGISTRY}\"" /etc/containers/registries.conf /etc/containers/registries.conf.d/ 2>/dev/null; then
    log "registries.conf 缺少 ${REGISTRY} 的 insecure 声明,写入 drop-in"
    [[ $EUID -eq 0 ]] || { log "需要 root 写 registries.conf.d,或先手动配置"; exit 1; }
    mkdir -p /etc/containers/registries.conf.d
    printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "${REGISTRY}" \
        > "/etc/containers/registries.conf.d/010-local-registry.conf"
fi

# ==================== 基础镜像种子(幂等) ====================
# 从上游 Dockerfile 提取 FROM 镜像; docker.io 短名约定: 无 "/" 补 library/
mapfile -t BASE_IMGS < <(sed -E -n 's/^FROM([[:space:]]+--[a-zA-Z-]+=[^[:space:]]+)?[[:space:]]+([^[:space:]]+)([[:space:]]+AS[[:space:]]+.*)?$/\2/p' Dockerfile)
mapfile -t BASE_PATHS < <(for img in "${BASE_IMGS[@]}"; do
    if [[ $img == */* ]]; then echo "$img"; else echo "library/$img"; fi
done)

seed_has() {   # $1 = 种子库 repo:tag, 如 library/golang:1.27-trixie
    local repo="${1%:*}" tag="${1##*:}" code
    code="$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json' \
        "http://${REGISTRY}/v2/${repo}/manifests/${tag}")"
    [[ $code == 200 ]]
}

ensure_base_seed() {
    FROM_SEED=""
    if ! curl -sf --noproxy '*' --max-time 5 -o /dev/null "http://${REGISTRY}/v2/"; then
        log "警告: ${REGISTRY} 不可达,基础镜像种子跳过,FROM 走原镜像源"
        return 0
    fi
    local i path ref
    for i in "${!BASE_PATHS[@]}"; do
        path="${BASE_PATHS[$i]}"
        ref="docker.io/${path}"
        if seed_has "$path"; then
            log "基础镜像已在种子库: ${path}"
            continue
        fi
        if ! podman image exists "$ref"; then
            log "本地与种子库都缺基础镜像,拉取 ${ref} (走镜像加速链)"
            proxy_clean podman pull -q "$ref" || { log "基础镜像拉取失败: ${ref}"; exit 1; }
        fi
        log "推送基础镜像种子到 ${REGISTRY}: ${path}"
        podman tag "$ref" "${REGISTRY}/${path}"
        proxy_clean podman push -q "${REGISTRY}/${path}"
    done
    FROM_SEED="$BASE_SEED"
}

# ==================== 生成构建用 Dockerfile (不动上游文件) ====================
# ① RUN 注入 go module/编译缓存挂载, 移除 go clean (否则缓存每次被清空)
# ② FROM 重写到种子库 (LAN 拉取); FROM_SEED 为空则保持原样
DEV_DOCKERFILE="_output/Dockerfile.dev"
generate_dev_dockerfile() {
    mkdir -p _output
    awk -v seed="$FROM_SEED" \
        -v mount="--mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build" '
    {
        line = $0
        if (line ~ /go clean -modcache -cache/) {
            if (n > 0) sub(/&& \\$/, "", out[n-1])
            next
        }
        if (line ~ /^RUN /) sub(/^RUN /, "RUN " mount " ", line)
        if (seed != "" && line ~ /^FROM/) {
            img = line
            sub(/^FROM([ \t]+--[a-zA-Z-]+=[^ \t]+)?[ \t]+/, "", img)
            sub(/[ \t]+AS[ \t]+.*$/, "", img)
            i = index(line, img)
            if (i > 0) {
                pfx = (img ~ /\//) ? "" : "library/"
                line = substr(line, 1, i-1) seed "/" pfx img substr(line, i + length(img))
            }
        }
        out[n++] = line
    }
    END { for (j = 0; j < n; j++) print out[j] }
    ' Dockerfile > "$DEV_DOCKERFILE.tmp"
    mv "$DEV_DOCKERFILE.tmp" "$DEV_DOCKERFILE"
    # 生成结果校验,失败回退上游 Dockerfile
    if ! grep -q -- '--mount=type=cache' "$DEV_DOCKERFILE" \
        || grep -q 'go clean -modcache' "$DEV_DOCKERFILE" \
        || [[ $(grep -c '^FROM' "$DEV_DOCKERFILE") -ne $(grep -c '^FROM' Dockerfile) ]] \
        || [[ $(grep -c 'go build -o /output/' "$DEV_DOCKERFILE") -lt 3 ]]; then
        log "警告: Dockerfile.dev 生成校验失败,回退使用上游 Dockerfile"
        DEV_DOCKERFILE="Dockerfile"
    fi
}

# ============================ 构建 ============================
if [[ $PUSH_ONLY -eq 0 ]]; then
    ensure_base_seed
    generate_dev_dockerfile
    if [[ $GEN_ONLY -eq 1 ]]; then
        log "已生成 ${DEV_DOCKERFILE} (FROM 种子重写: ${FROM_SEED:-无}):"
        cat "$DEV_DOCKERFILE"
        exit 0
    fi

    log "构建 ${FULL_IMAGE}:${PRIMARY_TAG}  (VERSION=${VERSION} GIT_SHA=${GIT_SHA:0:9} GIT_TREE_STATE=${GIT_TREE_STATE})"
    # --network host: 让容器内 go 拉取 goproxy.cn / 访问宿主环回代理
    # 不传 --pull: podman build 默认 pull=missing,基础镜像本地已有就复用,-P 强制重拉
    BUILD_ARGS=(
        --network host
        --platform "${PLATFORM}"
        -t "${FULL_IMAGE}:${PRIMARY_TAG}"
        --build-arg "GOPROXY=${GOPROXY_BUILDER}"
        --build-arg PKG=github.com/velero-io/velero
        --build-arg BIN=velero
        --build-arg "VERSION=${VERSION}"
        --build-arg "GIT_SHA=${GIT_SHA}"
        --build-arg "GIT_TREE_STATE=${GIT_TREE_STATE}"
        --build-arg "REGISTRY=${REGISTRY_BUILD_ARG}"
        -f "$DEV_DOCKERFILE"
        .
    )
    [[ $NO_CACHE -eq 1 ]] && BUILD_ARGS+=( --no-cache )
    if [[ $PULL_BASE -eq 1 ]]; then
        BUILD_ARGS+=( --pull=true )
    fi
    proxy_clean podman build "${BUILD_ARGS[@]}"
    log "构建完成"
else
    log "跳过构建 (--push-only)"
fi

# ============================ 推送 ============================
push_ref() {
    log "推送 $1"
    proxy_clean podman push --quiet "$1"
}

push_ref "${FULL_IMAGE}:${PRIMARY_TAG}"

if [[ $ALSO_LATEST -eq 1 ]]; then
    podman tag "${FULL_IMAGE}:${PRIMARY_TAG}" "${FULL_IMAGE}:latest"
    push_ref "${FULL_IMAGE}:latest"
fi

if [[ $ALSO_ARCH -eq 1 ]]; then
    podman tag "${FULL_IMAGE}:${PRIMARY_TAG}" "${FULL_IMAGE}:${ARCH_TAG}"
    push_ref "${FULL_IMAGE}:${ARCH_TAG}"
fi

# ============================ 验证 ============================
log "验证远端 registry"
TAGS="$(curl -sf --noproxy '*' --max-time 10 "http://${REGISTRY}/v2/${REPO_PATH}/tags/list")" \
    || { log "验证失败: registry 不可达"; exit 1; }
log "远端 tags: ${TAGS}"
log "完成: ${FULL_IMAGE}:${PRIMARY_TAG}"
