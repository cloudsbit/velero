### 构建velero镜像

```sh
# registry为github的ghcr.io
root@DESKTOP-MV37U94:velero# podman build --pull --network host --platform linux/amd64 \
  -t ghcr.io/cloudsbit/velero:main-linux-amd64 \
  --build-arg GOPROXY=https://goproxy.cn \
  --build-arg PKG=github.com/velero-io/velero \
  --build-arg BIN=velero --build-arg VERSION=main \
  --build-arg GIT_SHA=$(git rev-parse HEAD) \
  --build-arg GIT_TREE_STATE=dirty \
  --build-arg REGISTRY=ghcr.io/cloudsbit \
  -f Dockerfile .
[1/2] STEP 1/15: FROM golang:1.27-trixie AS velero-builder
Resolving "golang" using unqualified-search registries (/etc/containers/registries.conf.d/000-search.conf)
Trying to pull docker.io/library/golang:1.27-trixie...
Getting image source signatures
Copying blob e34fd850821b done   |
Copying blob a6dd1c05fbba done   |
Copying blob 411d2dc8717d done   |
Copying blob e8a88afca2bd done   |
Copying blob 91d8d09967d5 done   |
Copying blob 83d129a974dd done   |
Copying blob 4f4fb700ef54 skipped: already exists
Copying config 35d05408c4 done   |
Writing manifest to image destination
[1/2] STEP 2/15: ARG GOPROXY
--> 0c500c09dfe3
[1/2] STEP 3/15: ARG BIN
--> c6187522c54d
[1/2] STEP 4/15: ARG PKG
--> 6e13b34a5174
[1/2] STEP 5/15: ARG VERSION
--> 5f60d68a779b
[1/2] STEP 6/15: ARG REGISTRY
--> ad5ec4b9b735
[1/2] STEP 7/15: ARG GIT_SHA
--> 36e6fcfdaa2b
[1/2] STEP 8/15: ARG GIT_TREE_STATE
--> 6f850911fa44
[1/2] STEP 9/15: ARG TARGETOS
--> 27c0aec91e87
[1/2] STEP 10/15: ARG TARGETARCH
--> b7f29419933a
[1/2] STEP 11/15: ARG TARGETVARIANT
--> 6ba8bb4fcecf
[1/2] STEP 12/15: ENV CGO_ENABLED=0     GO111MODULE=on     GOPROXY=${GOPROXY}     GOOS=${TARGETOS}     GOARCH=${TARGETARCH}     GOARM=${TARGETVARIANT}     LDFLAGS="-X ${PKG}/pkg/buildinfo.Version=${VERSION} -X ${PKG}/pkg/buildinfo.GitSHA=${GIT_SHA} -X ${PKG}/pkg/buildinfo.GitTreeState=${GIT_TREE_STATE} -X ${PKG}/pkg/buildinfo.ImageRegistry=${REGISTRY}"
--> 96196b30a92e
[1/2] STEP 13/15: WORKDIR /go/src/github.com/velero-io/velero
--> 1695b8b54479
[1/2] STEP 14/15: COPY . /go/src/github.com/velero-io/velero
--> eb1f5f51bde8
[1/2] STEP 15/15: RUN mkdir -p /output/usr/bin &&     export GOARM=$( echo "${GOARM}" | cut -c2-) &&     go build -o /output/${BIN}     -ldflags "${LDFLAGS}" ${PKG}/cmd/${BIN} &&     go build -o /output/velero-restore-helper     -ldflags "${LDFLAGS}" ${PKG}/cmd/velero-restore-helper &&     go build -o /output/velero-helper     -ldflags "${LDFLAGS}" ${PKG}/cmd/velero-helper &&     go clean -modcache -cache
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_CHOWN: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_DAC_OVERRIDE: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_FOWNER: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_FSETID: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_KILL: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_NET_BIND_SERVICE: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_SETFCAP: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_SETGID: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_SETPCAP: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_SETUID: operation not permitted"
time="2026-11-13T09:35:29+08:00" level=warning msg="can't raise ambient capability CAP_SYS_CHROOT: operation not permitted"
go: downloading github.com/fatih/color v1.19.0
go: downloading k8s.io/klog/v2 v2.140.0
go: downloading github.com/spf13/cobra v1.10.2
go: downloading github.com/cockroachdb/errors v1.13.0
go: downloading github.com/kubernetes-csi/external-snapshotter/client/v8 v8.6.0
go: downloading github.com/spf13/pflag v1.0.10
go: downloading k8s.io/apiextensions-apiserver v0.36.0
go: downloading k8s.io/apimachinery v0.36.1
go: downloading k8s.io/client-go v0.36.1
go: downloading sigs.k8s.io/controller-runtime v0.24.0
go: downloading github.com/bombsimon/logrusr/v3 v3.1.0
go: downloading github.com/sirupsen/logrus v1.9.4
go: downloading k8s.io/api v0.36.1
go: downloading github.com/vmware-tanzu/crash-diagnostics v0.4.3
go: downloading github.com/prometheus/client_golang v1.23.2
go: downloading k8s.io/utils v0.0.0-20260210185600-b8788abfbbc2
go: downloading github.com/evanphx/json-patch/v5 v5.9.11
go: downloading golang.org/x/mod v0.41.0
go: downloading github.com/mattn/go-colorable v0.1.15
go: downloading github.com/mattn/go-isatty v0.0.21
go: downloading github.com/go-logr/logr v1.4.4
go: downloading github.com/cockroachdb/logtags v0.0.0-20230118201751-21c54148d20b
go: downloading github.com/cockroachdb/redact v1.1.5
go: downloading github.com/getsentry/sentry-go v0.46.0
go: downloading sigs.k8s.io/randfill v1.0.0
go: downloading k8s.io/kube-openapi v0.0.0-20260317180543-43fb72c5454a
go: downloading sigs.k8s.io/structured-merge-diff/v6 v6.4.0
go: downloading github.com/google/gnostic-models v0.7.1
go: downloading google.golang.org/protobuf v1.36.12
go: downloading golang.org/x/oauth2 v0.36.0
go: downloading github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822
go: downloading golang.org/x/net v0.62.0
go: downloading golang.org/x/term v0.47.0
go: downloading golang.org/x/text v0.43.0
go: downloading github.com/google/uuid v1.6.0
go: downloading github.com/gobwas/glob v0.2.3
go: downloading k8s.io/cli-runtime v0.36.0
go: downloading sigs.k8s.io/yaml v1.6.0
go: downloading github.com/kubernetes-csi/external-snapshot-metadata v1.0.0
go: downloading golang.org/x/sys v0.49.0
go: downloading github.com/netresearch/go-cron v0.15.0
go: downloading github.com/petar/GoLLRB v0.0.0-20210522233825-ae3b015fd3e9
go: downloading github.com/prometheus/client_model v0.6.2
go: downloading github.com/prometheus/common v0.68.1
go: downloading go.yaml.in/yaml/v3 v3.0.4
go: downloading sigs.k8s.io/json v0.0.0-20250730193827-2d320260d730
go: downloading github.com/hashicorp/go-hclog v1.6.3
go: downloading github.com/hashicorp/go-plugin v1.7.0
go: downloading google.golang.org/grpc v1.83.2
go: downloading k8s.io/kube-aggregator v0.36.0
go: downloading github.com/gogo/protobuf v1.3.2
go: downloading github.com/kr/pretty v0.3.1
go: downloading github.com/pkg/errors v0.9.1
go: downloading gopkg.in/inf.v0 v0.9.1
go: downloading github.com/json-iterator/go v1.1.12
go: downloading go.yaml.in/yaml/v2 v2.4.4
go: downloading github.com/fxamacker/cbor/v2 v2.9.2
go: downloading golang.org/x/time v0.15.0
go: downloading github.com/pmezard/go-difflib v1.0.1-0.20181226105442-5d4384ee4fb2
go: downloading github.com/liggitt/tabwriter v0.0.0-20181228230101-89fcab3d43de
go: downloading github.com/moby/term v0.5.0
go: downloading github.com/velero-io/kopia v0.0.0-20260616052725-d83462d382c9
go: downloading github.com/beorn7/perks v1.0.1
go: downloading github.com/cespare/xxhash/v2 v2.3.0
go: downloading github.com/prometheus/procfs v0.20.1
go: downloading github.com/kubernetes-csi/external-snapshot-metadata/client v1.0.0
go: downloading gomodules.xyz/jsonpatch/v2 v2.4.0
go: downloading github.com/kcp-dev/logicalcluster/v3 v3.0.5
go: downloading github.com/vladimirvivien/gexe v0.4.0
go: downloading go.starlark.net v0.0.0-20241226192728-8dfa5b98479f
go: downloading github.com/gorilla/websocket v1.5.4-0.20250319132907-e064f32e3674
go: downloading k8s.io/streaming v0.36.1
go: downloading github.com/golang/protobuf v1.5.4
go: downloading github.com/hashicorp/yamux v0.1.2
go: downloading github.com/oklog/run v1.1.0
go: downloading google.golang.org/genproto/googleapis/rpc v0.0.0-20260526163538-3dc84a4a5aaa
go: downloading github.com/kr/text v0.2.0
go: downloading github.com/rogpeppe/go-internal v1.14.1
go: downloading google.golang.org/genproto v0.0.0-20260319201613-d00831a3d3e7
go: downloading github.com/go-openapi/swag v0.26.0
go: downloading github.com/go-openapi/jsonreference v0.21.5
go: downloading github.com/modern-go/concurrent v0.0.0-20180306012644-bacd9c7ef1dd
go: downloading github.com/modern-go/reflect2 v1.0.3-0.20250322232337-35a7c28c31ee
go: downloading github.com/davecgh/go-spew v1.1.2-0.20180830191138-d8f796af33cc
go: downloading github.com/x448/float16 v0.8.4
go: downloading github.com/aws/aws-sdk-go-v2 v1.41.12
go: downloading github.com/aws/aws-sdk-go-v2/config v1.32.17
go: downloading github.com/aws/aws-sdk-go-v2/credentials v1.19.16
go: downloading github.com/aws/aws-sdk-go-v2/feature/s3/manager v1.22.18
go: downloading github.com/aws/aws-sdk-go-v2/service/s3 v1.101.0
go: downloading github.com/aws/aws-sdk-go-v2/service/sts v1.42.1
go: downloading golang.org/x/sync v0.24.0
go: downloading github.com/fsnotify/fsnotify v1.9.0
go: downloading github.com/kcp-dev/kcp/cli v0.27.1
go: downloading github.com/kcp-dev/kcp/sdk v0.27.1
go: downloading github.com/emicklei/go-restful/v3 v3.13.0
go: downloading github.com/go-openapi/jsonpointer v0.23.1
go: downloading gopkg.in/evanphx/json-patch.v4 v4.13.0
go: downloading github.com/go-openapi/swag/cmdutils v0.26.0
go: downloading github.com/go-openapi/swag/conv v0.26.0
go: downloading github.com/go-openapi/swag/fileutils v0.26.0
go: downloading github.com/go-openapi/swag/jsonname v0.26.0
go: downloading github.com/go-openapi/swag/jsonutils v0.26.0
go: downloading github.com/go-openapi/swag/loading v0.26.0
go: downloading github.com/go-openapi/swag/mangling v0.26.0
go: downloading github.com/go-openapi/swag/netutils v0.26.0
go: downloading github.com/go-openapi/swag/stringutils v0.26.0
go: downloading github.com/go-openapi/swag/typeutils v0.26.0
go: downloading github.com/go-openapi/swag/yamlutils v0.26.0
go: downloading github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.18.23
go: downloading github.com/aws/aws-sdk-go-v2/service/signin v1.0.11
go: downloading github.com/aws/aws-sdk-go-v2/service/sso v1.30.17
go: downloading github.com/aws/aws-sdk-go-v2/service/ssooidc v1.35.21
go: downloading github.com/aws/smithy-go v1.27.1
go: downloading github.com/Azure/azure-sdk-for-go/sdk/azcore v1.22.0
go: downloading github.com/Azure/azure-sdk-for-go/sdk/azidentity v1.13.1
go: downloading github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/storage/armstorage v1.8.1
go: downloading github.com/Azure/azure-sdk-for-go/sdk/storage/azblob v1.7.0
go: downloading github.com/RoaringBitmap/roaring v1.9.4
go: downloading github.com/aws/aws-sdk-go-v2/internal/configsources v1.4.23
go: downloading github.com/aws/aws-sdk-go-v2/internal/v4a v1.4.24
go: downloading github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.9
go: downloading github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.13.23
go: downloading github.com/aws/aws-sdk-go-v2/aws/protocol/eventstream v1.7.10
go: downloading github.com/aws/aws-sdk-go-v2/service/internal/checksum v1.9.15
go: downloading github.com/aws/aws-sdk-go-v2/service/internal/s3shared v1.19.23
go: downloading go.opentelemetry.io/otel v1.45.0
go: downloading go.opentelemetry.io/otel/trace v1.45.0
go: downloading github.com/hashicorp/cronexpr v1.1.3
go: downloading go.uber.org/zap v1.28.0
go: downloading github.com/edsrzf/mmap-go v1.2.0
go: downloading github.com/Azure/azure-sdk-for-go/sdk/internal v1.12.0
go: downloading github.com/klauspost/compress v1.19.2
go: downloading github.com/klauspost/pgzip v1.2.6
go: downloading github.com/gofrs/flock v0.13.0
go: downloading github.com/AzureAD/microsoft-authentication-library-for-go v1.7.2
go: downloading golang.org/x/crypto v0.58.1-0.20261009181718-2f1f834330b2
go: downloading github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.7.23
go: downloading golang.org/x/exp v0.0.0-20260410095643-746e56fc9e2f
go: downloading github.com/zeebo/blake3 v0.2.4
go: downloading github.com/chmduquesne/rollinghash v4.0.0+incompatible
go: downloading github.com/kcp-dev/apimachinery/v2 v2.0.1-0.20250223115924-431177b024f3
go: downloading github.com/natefinch/atomic v1.0.1
go: downloading github.com/klauspost/reedsolomon v1.14.0
go: downloading github.com/moby/spdystream v0.5.1
go: downloading go.uber.org/multierr v1.11.0
go: downloading go.opentelemetry.io/otel/metric v1.45.0
go: downloading cloud.google.com/go/storage v1.62.3
go: downloading google.golang.org/api v0.283.0
go: downloading github.com/minio/minio-go/v7 v7.2.0
go: downloading cloud.google.com/go v0.123.0
go: downloading github.com/kylelemons/godebug v1.1.0
go: downloading github.com/pkg/browser v0.0.0-20240102092130-5ac0b6a4141c
go: downloading github.com/go-logr/stdr v1.2.2
go: downloading go.opentelemetry.io/auto/sdk v1.2.1
go: downloading github.com/klauspost/cpuid/v2 v2.3.0
go: downloading cloud.google.com/go/auth v0.20.0
go: downloading cloud.google.com/go/compute/metadata v0.9.0
go: downloading cloud.google.com/go/iam v1.7.0
go: downloading github.com/googleapis/gax-go/v2 v2.22.0
go: downloading github.com/GoogleCloudPlatform/opentelemetry-operations-go/exporter/metric v0.55.0
go: downloading go.opentelemetry.io/contrib/detectors/gcp v1.44.0
go: downloading go.opentelemetry.io/otel/sdk/metric v1.45.0
go: downloading go.opentelemetry.io/otel/sdk v1.45.0
go: downloading github.com/klauspost/crc32 v1.3.0
go: downloading github.com/dustin/go-humanize v1.0.1
go: downloading github.com/minio/crc64nvme v1.1.1
go: downloading github.com/minio/md5-simd v1.1.2
go: downloading github.com/zeebo/xxh3 v1.1.0
go: downloading gopkg.in/ini.v1 v1.67.2
go: downloading github.com/golang-jwt/jwt/v5 v5.3.1
go: downloading google.golang.org/genproto/googleapis/api v0.0.0-20260526163538-3dc84a4a5aaa
go: downloading cloud.google.com/go/monitoring v1.24.3
go: downloading github.com/GoogleCloudPlatform/opentelemetry-operations-go/internal/resourcemapping v0.55.0
go: downloading github.com/GoogleCloudPlatform/opentelemetry-operations-go/detectors/gcp v1.33.0
go: downloading github.com/bits-and-blooms/bitset v1.12.0
go: downloading cloud.google.com/go/auth/oauth2adapt v0.2.8
go: downloading go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.67.0
go: downloading github.com/rs/xid v1.6.0
go: downloading github.com/tinylib/msgp v1.6.1
go: downloading github.com/google/go-cmp v0.7.0
go: downloading github.com/onsi/gomega v1.40.0
go: downloading go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc v0.67.0
go: downloading github.com/google/s2a-go v0.1.9
go: downloading github.com/googleapis/enterprise-certificate-proxy v0.3.16
go: downloading github.com/envoyproxy/go-control-plane/envoy v1.37.0
go: downloading github.com/philhofer/fwd v1.2.0
go: downloading github.com/felixge/httpsnoop v1.0.4
go: downloading github.com/spiffe/go-spiffe/v2 v2.7.0
go: downloading github.com/cncf/xds/go v0.0.0-20260202195803-dba9d589def2
go: downloading github.com/go-jose/go-jose/v4 v4.1.6
go: downloading github.com/envoyproxy/protoc-gen-validate v1.3.3
go: downloading cel.dev/expr v0.25.2
--> b0030edd192e
[2/2] STEP 1/4: FROM paketobuildpacks/ubuntu-noble-run-tiny:latest
Resolving "paketobuildpacks/ubuntu-noble-run-tiny" using unqualified-search registries (/etc/containers/registries.conf.d/000-search.conf)
Trying to pull docker.io/paketobuildpacks/ubuntu-noble-run-tiny:latest...
Getting image source signatures
Copying blob 6a1b1e4c363a done   |
Copying blob 8d7e7a011dc7 done   |
Copying blob d98139f6879d done   |
Copying config 6c307cd36e done   |
Writing manifest to image destination
[2/2] STEP 2/4: LABEL maintainer="Xun Jiang <xun.jiang@broadcom.com>"
--> 7ce8698b5567
[2/2] STEP 3/4: COPY --from=velero-builder /output /
--> ae98d30b7fd6
[2/2] STEP 4/4: USER cnb:cnb
[2/2] COMMIT ghcr.io/cloudsbit/velero:main-linux-amd64
--> f4ad9992ef75
Successfully tagged ghcr.io/cloudsbit/velero:main-linux-amd64
f4ad9992ef75c640ad10c150cfdbb61dd6c85cbfd016f10b5d2537f8d86c4714
```

### 构建成功后推送

```sh
# 登录ghcr.io
echo "ghp_OWxxxxxX" | podman login ghcr.io -u cloudsbit  --password-stdin

root@DESKTOP-MV37U94:velero# podman push ghcr.io/cloudsbit/velero:main-linux-amd64
Getting image source signatures
Copying blob 038c6287fea6 done   |
Copying blob 9a3800049195 done   |
Copying blob d14ad30e3fe5 done   |
Copying blob 585a3c005741 done   |
Copying config f4ad9992ef done   |
Writing manifest to image destination
```

###  查某个镜像的全部 tag

```sh
root@DESKTOP-MV37U94:velero# podman search --list-tags ghcr.io/cloudsbit/velero
NAME                      TAG
ghcr.io/cloudsbit/velero  main-linux-amd64
```

### 容器编译二进制 + 极简 Dockerfile

```sh
# FIXME：暂时在wsl中因为代理的原因不通...
# ① 复用 Makefile 的 builder 容器编译（podman 路径）
CONTAINER_TOOL=podman make build                        # → _output/bin/linux/amd64/velero
CONTAINER_TOOL=podman make build BIN=velero-restore-helper
CONTAINER_TOOL=podman make build BIN=velero-helper

# ② 两行 Dockerfile 秒级打包
cat > Dockerfile.dev <<'EOF'
FROM paketobuildpacks/ubuntu-noble-run-tiny:latest
COPY _output/bin/linux/amd64/velero _output/bin/linux/amd64/velero-restore-helper _output/bin/linux/amd64/velero-helper /
EOF
podman build -t 127.0.0.1:5000/velero:main-linux-amd64 -f Dockerfile.dev .
podman push --tls-verify=false 127.0.0.1:5000/velero:main-linux-amd64 10.88.0.5:5000/velero:main-linux-amd64
```

本地编译二进制：

```sh
root@DESKTOP-MV37U94:velero# make local
GOOS=linux \
GOARCH=amd64 \
GOBIN=$(pwd)/.go/bin \
VERSION=main \
REGISTRY=velero \
PKG=github.com/velero-io/velero \
BIN=velero \
GIT_SHA=a1943013314d5c02a5bf0e3437bd594fdb39abad \
GIT_TREE_STATE=dirty \
OUTPUT_DIR=$(pwd)/_output/bin/linux/amd64 \
./hack/build.sh
```

### 指定TAG

```sh
# 登录ghcr.io
echo "ghp_OWxxxxxX" | podman login ghcr.io -u cloudsbit  --password-stdin

# (指定tab)构建velero镜像
podman build --pull --network host --platform linux/amd64 \
  -t ghcr.io/cloudsbit/velero:v1.19.0-dryrun.1 \
  --build-arg GOPROXY=https://goproxy.cn \
  --build-arg PKG=github.com/velero-io/velero \
  --build-arg BIN=velero --build-arg VERSION=main \
  --build-arg GIT_SHA=$(git rev-parse HEAD) \
  --build-arg GIT_TREE_STATE=dirty \
  --build-arg REGISTRY=ghcr.io/cloudsbit \
  -f Dockerfile .

# push镜像
podman push ghcr.io/cloudsbit/velero:v1.19.0-dryrun.1
```

