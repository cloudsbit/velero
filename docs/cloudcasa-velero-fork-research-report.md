# CloudCasa（catalogicsoftware/velero）对 Velero 的定制化改造调研报告

> **对比对象**：`https://github.com/catalogicsoftware/velero`（CloudCasa/Catalogic 的 Velero fork）vs `https://github.com/velero-io/velero`（上游官方）
> **调研日期**：2026-11-13　**调研方式**：GitHub Compare API 提交级/文件级 diff + 关键实现源码阅读 + 公开资料佐证
> **对比基线**：fork 的 `v1.18.4.x` 分支 = 上游 tag `v1.18.4` + 32 个提交（195 个文件变更，即当前全部净定制量）；历史定制全貌取自 `v1.14.0.x` 分支（= 上游 `v1.14.0` + 152 个提交）

---

## 目录

1. [结论速览](#1-结论速览)
2. [Fork 概况与维护模式](#2-fork-概况与维护模式)
3. [架构级定制（最重要）](#3-架构级定制最重要)
4. [功能级定制](#4-功能级定制)
5. [可靠性与兼容性修复清单](#5-可靠性与兼容性修复清单)
6. [安全与合规](#6-安全与合规)
7. [构建与 CI/CD](#7-构建与-cicd)
8. [维护策略分析与借鉴](#8-维护策略分析与借鉴)
9. [附录：关键新增文件清单](#9-附录关键新增文件清单)

---

## 1. 结论速览

CloudCasa 把上游 Velero 从"独立备份工具"改造成 **"CloudCasa SaaS 服务的集群内备份执行引擎"**。定制围绕一条主线展开：**让 SaaS 控制面（kubeagent + amds 插件）接管调度/过期/同步/仓库管理，Velero 引擎退化为"每个备份 job 一个进程"的纯执行器**。在此之上叠加了存储加密、按名选择资源、PVC 备份方法体系、KubeVirt 支持等能力。

| # | 定制 | 类型 | 关键实现 |
|---|---|---|---|
| 1 | **Per-Job 引擎 + 实例隔离**：每个备份 job 启动一个 `cloudcasa-backup-helper` 进程（即 velero server），通过 label `cloudcasa.io/helper-instance` 在 cache 和所有 controller 层面隔离 CR | 架构 | `pkg/instance/scope.go`、`pkg/controller/instance_scope.go`、env `CC_HELPER_INSTANCE` |
| 2 | **禁用 6 个 controller**：backup-sync、gc、schedule、server-status-request、backup-repo、download-request（调度/过期/同步/仓库全部由 CloudCasa 侧接管） | 架构 | `pkg/cmd/server/server.go` `cloudcasaUnusedControllers` |
| 3 | **CRD group 重命名** `velero.io` → `cloudcasa.io`（13 个 CRD 全部改名，含 RBAC marker 与 YAML） | 架构 | `replace_group_names.py`、`config/crd/*/bases/cloudcasa.io_*.yaml` |
| 4 | **amds 插件捆绑**：velero 镜像内捆绑 `catalogicsoftware/amds-veleroplugin`（agent 通信核心插件）+ 自维护的 aws/gcp/kubevirt 插件 fork | 架构 | `plugins.ini`、`build-plugins.sh` |
| 5 | **对象存储 bundle 加密层**：`encryptingObjectStore` 装饰器包装任意 ObjectStore 插件，写加密/读解密 | 安全 | `pkg/persistence/bundlecrypt/`、`encrypting_object_store.go` |
| 6 | **进度回传机制**：快照/PVC 进度写入 ConfigMap（`cloudcasa-io-snapshot-updater-<jobid>`），agent 读取后上报 SaaS | 协同 | `internal/catalogic/types.go`（PvcSnapshotProgressData） |
| 7 | **按名称精确选择资源**：`Backup/Restore.Spec.IncludeNamedResources`（含依赖资源联动与排除） | 功能 | `pkg/apis/velero/v1/{backup,restore}_types.go`、`pkg/restore/named_resources_test.go` |
| 8 | **PVC 备份方法体系**：无 CSI 快照的 copy 备份（"CloudCasa method"）、按 PVC/StorageClass 配置备份方法、block PVC 在线备份、无挂载 PVC 支持 | 功能 | `pkg/backup/actions/csi/pvc_action.go`、`internal/catalogic` PluginConfig |
| 9 | **KubeVirt VM 支持**：VM 备份/恢复状态钩子上报、KubeVirt CBT 增量备份、VM 换名恢复（连带复制其使用的资源） | 功能 | `pkg/util/kubevirt/`、`pkg/restore/vm_rename*` |
| 10 | **只读 BSL 降级写入**：BSL ReadOnly 时把 restore 结果写本地文件 | 功能 | `pkg/util/backup_store/{local_writer,artifact_writer,backup_store_writer}.go` |
| 11 | **Immutable object store 支持**：BSL 打 `cloudcasa.io/object-lock` 注解后所有 controller 跳过对象存储删除 | 功能 | `labels_annotations.go`、`backup_deletion_controller.go` |
| 12 | 大量**可靠性修复**（约 30 项）+ CVE 修复 + Go 升级 + UBI9/Red Hat 认证 + Jenkins 多架构 CI | 质量/工程 | 详见 §5/§6/§7 |

> 背景注：CloudCasa 2023 年初的形态是"管理用户已有 Velero"的 SaaS 服务，后来转向**原生备份引擎**路线——本 fork 正是原生路线的产物，Velero 在其中仅作为执行引擎存在（见 [CloudCasa 博客](https://cloudcasa.io/blog/new-service-offering-to-manage-and-run-velero-backups-at-enterprise-scale)、[TechTarget 报道](https://www.techtarget.com/news/CloudCasa-brings-GUI-to-open-source-backup-tool-Velero/843361)、[cloudcasa.io/solutions/velero-backup](https://cloudcasa.io/solutions/velero-backup)）。

---

## 2. Fork 概况与维护模式

### 2.1 基本盘

| 项 | 值 |
|---|---|
| fork 父仓库 | `velero-io/velero`（GitHub fork 关系确认） |
| 默认分支 | `v1.14.0.x`（较旧基线；新工作在 `v1.18.4.x`） |
| 最新跟踪版本 | `v1.18.4.x` = 上游 `v1.18.4` + 32 提交，2026-11-12 仍在推送 |
| 版本分支序列 | `v1.9.2.x → v1.11.1.x → v1.14.0.x → v1.18.4.x`（每个分支 = 上游对应 tag + CloudCasa 全量定制，通常 squash 成一个 "Velero vX with CloudCasa's changes" 大提交） |
| module/import path | **未改名**，仍是 `github.com/vmware-tanzu/velero`（刻意保持，方便与上游 diff/cherry-pick） |
| 活跃开发者 | David Zaninovic、Swanand Shende、Sebastian Głąb、jongarner、Md Islam、Raghuram Devarakonda 等；另有 `cloudcasabot` 机器人 |

### 2.2 分支体系

- **工单分支**：约 90 个 `KUBEDR-XXXX_<dev>` / `Swanand-KubeDR-*` / `jg-KUBEDR-*` 分支 —— KubeDR 是其内部 Kubernetes 灾备产品线工单号，可见开发流程：工单分支 → PR 合入版本分支 → CI 出镜像。
- **发布分支**：`release-0.5`…`release-1.9`（CloudCasa agent 版本线）、`production-*`（按日期命名）、`prod-sh-*`。
- **CI/工具分支**：`jenkinsfile`、`fix-buildx`、`jg-redhat-build*`（Red Hat 认证）、`plugin-interface-v2`。

### 2.3 对上游的跟踪方式

每个上游 release tag 对应一条 fork 版本分支；升级 = 以 tag 为基线重新落地全量定制（一个大提交），再由 `cloudcasabot` 持续自动 bump 内部插件镜像（`ci: update amds-veleroplugin to 3.1.0-master.NNN`、`ci: bump velero image to v1.18.4-master.NNN`）。上游个别 PR 也会被单独 cherry-pick（如 #7953、#8021、#8591、#8021-expose-pv-patch-max-timeout）。

---

## 3. 架构级定制（最重要）

### 3.1 Per-Job 引擎与实例隔离（与上游最大的模型差异）

上游模型：**一个** velero server Deployment 通过 controller 处理整个 namespace 的所有 Backup/Restore CR。

CloudCasa 模型（`pkg/instance/scope.go` 注释原文："scopes an engine process to the custom resources of one CloudCasa job, so several engines can share a namespace without processing each other's work"）：

```
CloudCasa SaaS 控制面
   └─ kubeagent（每集群一个）
        ├─ 创建 Backup/Restore CR，打 label：cloudcasa.io/helper-instance = <jobID>
        ├─ 启动该 job 专属引擎进程 cloudcasa-backup-helper（即 velero server，
        │   env: CC_HELPER_INSTANCE=<jobID>）
        └─ 多个引擎进程共享同一 velero namespace，互不越界
```

实现要点：
- `instance.Scope` 依据 env `CC_HELPER_INSTANCE` 构造 label selector；cache 层（`DefaultNamespaces` + cache label selector）与**每个 controller 的 event predicate** 双重过滤（`pkg/controller/instance_scope.go`）。
- `KindMode` 区分 `Owned`（Backup/Restore/DeleteBackupRequest 等按 label 认领）与 `Shared`（BSL/VSL 所有引擎共享只读；被禁用 controller 对应的 kind 只读）。
- 无 label 的 CR 由"共享引擎"（空 instance ID）兜底处理（`absentSelector`）。
- 进程改名：`rename cloudcasa-velero to cloudcasa-backup-helper`（KUBEDR-8406）。

**动机**：SaaS 侧可精确按 job 计量、限流、隔离与排障；单 job 引擎崩溃不影响其他 job；免去上游复杂的并发排队（backup-queue controller 保留但作用域化）。

### 3.2 接管上游的"平台职责"：禁用 6 个 controller

`pkg/cmd/server/server.go` 新增：

```go
var cloudcasaUnusedControllers = []string{
    ControllerBackupSync,          // 备份元数据同步 —— CloudCasa 自己做
    ControllerGarbageCollection,   // TTL 过期 GC —— CloudCasa 自己调度过期
    ControllerSchedule,            // cron 调度 —— CloudCasa SaaS 调度
    ControllerServerStatusRequest, // 状态查询 —— 走 agent
    ControllerBackupRepo,          // kopia 仓库管理 —— "does not use Velero repositories"
    ControllerDownloadRequest,     // 日志/内容下载 —— 走 agent
}
```

含义：**CloudCasa 引擎不用 Velero 的 BackupRepository（kopia 统一仓库）体系**，卷数据走自己的 copy/mover 方法（见 §4.2），元数据/调度/生命周期全由 SaaS 控制面决定。引擎只保留 backup、restore、backup-deletion、backup-operations、backup-finalizer、restore-operations、restore-finalizer、backup-queue、BSL 校验等"纯执行"controller。

### 3.3 CRD group 重命名：velero.io → cloudcasa.io

- 全部 13 个 CRD YAML 改为 `cloudcasa.io_backups.yaml` 等（`config/crd/{v1,v2alpha1}/bases/`），由脚本 `replace_group_names.py` 批量完成（commit "Use custom CRD's with cloudcasa.io as group name" + "Remove CRD's with old velero.io groupname"）。
- Go 类型中的 kubebuilder RBAC marker 同步改为 `groups=cloudcasa.io`。
- **CSI 相关 label/annotation 也整体改名**：`VolumeSnapshotClassSelectorLabel`、`VolumeGroupSnapshotClassDefaultLabel` 等从 `velero.io/csi-*` 改为 `cloudcasa.io/csi-*` —— 效果是**上游官方 velero-plugin-for-csi 不会误识别/误操作这些对象**，CSI 快照生命周期完全由 CloudCasa 代码接管。
- 新增自有注解族（`pkg/apis/velero/v1/labels_annotations.go`）：
  - `cloudcasa.io/object-lock`（不可变对象存储标记）
  - `cloudcasa.io/bundle-key-file` / `cloudcasa.io/bundle-encryption-required`（bundle 加密）
  - `cloudcasa.io/csi-volumegroupsnapshot-member-handles`（VGS 成员快照句柄）
  - `cloudcasa.io/volume-group`（VGS 分组 label）
  - `cloudcasa.io/csi-sc-vsc-mapping-` 前缀（StorageClass→VolumeSnapshotClass 映射）
  - `cloudcasa.io/snapshot-class-required-drivers`（agent 下发：哪些 CSI 驱动必须显式配置 snapshot class，禁止自动创建）
  - `cloudcasa-source-azure-file-share-*`（Azure Files 迁移定位注解）

### 3.4 与 SaaS 的协同机制：amds 插件 + ConfigMap 进度回传

- **amds-veleroplugin**（`catalogicsoftware/amds-veleroplugin:3.1.0-master.NNN`）：无公开仓库/文档的内部插件，由 bot 频繁 bump，固定捆绑进 velero 镜像（`/plugins/catalogicsoftware-velero-plugin`），是引擎与 agent/SaaS 之间的桥梁（推测职责：job 指令接收与状态回报；commit "Bundle the amds plugin 3.1.0-master.484, as v1.14.0.x does" 表明它是引擎镜像的固定组成部分）。
- **ConfigMap 进度总线**：备份/恢复过程中把 `PvcSnapshotProgressData{JobId, Message, State, SnapshotProgress, Pvc{...}}` 写入 ConfigMap（前缀 `cloudcasa-io-snapshot-updater-`，KUBEDR-6163 又把 jobid 写入 agent 使用的 configmap），kubeagent 读取后上报 SaaS —— 实现了引擎→agent→SaaS 的进度链路，且"PV Details"页数据也在恢复期收集（commit "Collect info for PV Details tab while restoring from CSI snapshot"）。
- **插件配置注入**：`PluginConfig{SnapshotWherePossible, CsiSnapshotTimeout, StorageClassBackupMethodMap, KubevirtCbtEnabled}` 来自 ConfigMap（前缀 `cloudcasa-io-velero-csi-plugin-`）—— SaaS/agent 通过 ConfigMap 向引擎下发 CSI 行为参数。
- **插件客户端超时**：`StartTimeout: 5 * time.Minute`（plugin client config，防插件启动挂死）。
- **只读 BSL 降级**：BSL 为 ReadOnly（灾备恢复集群场景）时，restore 结果/产物改写本地文件（`pkg/util/backup_store/local_writer.go` 等三个新增 writer），供 agent 收集后另行上传。

### 3.5 对象存储 bundle 加密层（安全架构改动）

- 新增 `pkg/persistence/bundlecrypt`：对称加密原语（固定 `KeySize` 校验）。
- 新增 `encryptingObjectStore`：**装饰器模式包装任意 ObjectStore 插件** —— `PutObject` 全部加密后写、`GetObject` 自动解密；BSL 注解 `cloudcasa.io/bundle-key-file` 指向 agent 放置的密钥文件时自动启用；`cloudcasa.io/bundle-encryption-required=true` 时读取到未加密对象直接拒绝。
- 效果：**与存储后端无关的端到端加密**（S3/GCS/Azure 均适用），密钥由 CloudCasa 侧管理（KUBEDR-8255 "Encrypt bundle files written to a storage location"）。

---

## 4. 功能级定制

### 4.1 按名称精确选择资源（Named Resources）

```go
// BackupSpec / RestoreSpec 新增
IncludeNamedResources map[string]string
// key = 复数资源名，value = 逗号分隔标识符（namespaced 用 "ns/name"，cluster-scoped 用 "name"）
```

- 备份：只备份点名资源（SaaS 下发用户在 UI 勾选的对象）。
- 恢复：恢复点名资源及其**依赖资源**（"Restore dependent resources of named resources"、"Honour explicit exclusions for named-resource dependents" —— 依赖项仍受显式排除约束）。
- 配套修复：单个 PVC 恢复失败等边界问题。

这是 SaaS "按工作负载/按对象粒度备份" 的底层支撑。

### 4.2 PVC/PV 备份方法体系（storage 层最大定制）

| 能力 | 说明 | 来源 |
|---|---|---|
| **CloudCasa copy method** | 不依赖 CSI 快照，直接 copy PVC 数据备份/恢复（KUBEDR-5709 "Support copy and restore of PVC without using CSI snapshots"），并维护 `liveCopyDrivers` 驱动清单（linode、smb.csi.k8s.io 等） | 多个 commit |
| **按 PVC / 按 StorageClass 配置方法** | KUBEDR-5960 "Allow changing the backup method per PVC"；`StorageClassBackupMethodMap`（StorageClass→snapshot/copy 映射，下发到 CSI 插件）；KUBEDR-8088 先检查 storage class 与 PVC 备份方法 | commit |
| **`SnapshotWherePossible`** | 能快照就快照的开关型策略 | PluginConfig |
| **可禁用快照** | KUBEDR-5808 "Support disabling snapshotting" | commit |
| **block PVC 在线备份** | KUBEDR-6731 "Enable live backup of block PVCs" | commit |
| **无挂载（unattached）PVC** | 跳过/恢复未挂载 PVC（KUBEDR-4917、6327）、短卷名（7481）、修复 unattached PV 崩溃（6409） | commit |
| **DR volumes 支持** | KUBEDR-6803 | commit |
| **Azure Files 专项** | 恢复前 sleep 并可配置（KUBEDR-5222/5228）、PVC 注解更新（5917）、CSI 驱动恢复（5953/6076）、NFS 卷跳过快照、跳过 `azlocal.csi.azure.com` 驱动（8132）、azurefilemover 配套注解 | commit |
| **动态供给增强** | Retain 策略卷恢复时允许动态 PV 供给；WaitForFirstConsumer Pending 状态跳过 PV patch（KUBEDR-5970）；stale PV↔PVC 引用处理（7501）；per-restore storage-class 配置 | commit |
| **VGS（卷组快照）定制** | `group_snapshot_cloudcasa.go`；VGS 成员句柄注解；`cloudcasa.io/volume-group` 分组 label；StorageClass→VSC 映射注解 | 代码+注解 |
| **快照类治理** | 仅认 `cloudcasa.io/csi-volumesnapshot-class` label（KUBEDR-6988）；允许指定使用的 volumesnapshotclass；必需显式配置的驱动 fail fast | commit |

### 4.3 KubeVirt 支持（虚拟机灾备）

- **状态上报钩子**："Added hooks to trap and report backup and restore status of KubeVirt VMs"（`pkg/util/kubevirt/kubevirt_vm_status_reporter.go`）+ 修复 VM 恢复状态误报。
- **CBT 增量备份**：KUBEDR-8002 "Implement KubeVirt CBT backup"（`KubevirtCbtEnabled` 配置项；`pvc_action_kubevirt_cloudcasa_test.go`）。
- **换名恢复**：KUBEDR-8315 "Restore a VM under a new name with copies of what it uses"（`pkg/restore/vm_rename*`、`restore_finalizer_vm_rename*`）—— VM 及其使用的 PVC/Disk 等以副本形式在新名字下恢复。
- 配套自维护 kubevirt-velero-plugin fork（`v0.9.1.1`、`v0.7.1.3`）。

### 4.4 其他

- **备份取消**："Implement cancel in Velero backup"（上游只有数据面 CR 的 cancel，这里补了 Backup 级取消）。
- **hook 日志**：`pkg/backup/hook_log_cloudcasa_test.go` 对应的 hook 日志能力。
- **exec hook 超时**：防 restore 卡死（见 §5）。
- **namespace metadata 恢复**：修复 existing-resource-policy 下 namespace metadata 未恢复（7519 分支也在做 namespace metadata restore）。
- **保留旧版 PVR controller**：`pod_volume_restore_controller_legacy.go` 兼容旧 agent。

---

## 5. 可靠性与兼容性修复清单

来自 v1.14.0.x 152 提交 + v1.18.4.x 净 diff，按主题归类：

| 主题 | 修复 |
|---|---|
| CSI 快照安全 | `DeleteVolumeSnapshot` 竞态导致存储快照丢失；finalize 阶段快照丢失；VolumeSnapshot 删除流程资源泄漏；`WaitUntilVSCHandleIsReady` 轮询改 watch；stale TypeMeta panic（live VS Status 拷贝） |
| 恢复健壮性 | exec hook 超时（防 restore 卡死）；PV patch 失败处理；backup deletion controller 重试；BSL 获取重试；locked objectstore 删除错误忽略 |
| 删除安全 | 不可变对象存储跳过删除（KUBEDR-8121）；`DeleteItemAction` handler 与 VSC 删除动作增强（含 VGS 用例） |
| 度量与日志 | `recordBackupMetrics` nil pointer / Prometheus counter panic；CSI 快照问题排查日志；对象存储交互日志；快照进度 VSC 解析失败上报；去掉杂音日志（KUBEDR-7640、5932）；kube-root-ca.crt 已存在告警忽略 |
| 引擎行为 | 仓库管理器不初始化（KUBEDR-6969，配合"不用 Velero 仓库"模型）；时间戳格式修复（day/month 混淆，KUBEDR 内部注释详细记载）；plugin client StartTimeout |
| 上游同步 | cherry-pick 上游 #7953（PV patch max timeout 暴露）、#8021、#8591（async op finalize） |

---

## 6. 安全与合规

| 项 | 内容 |
|---|---|
| CVE 修复 | CVE-2023-45288、CVE-2024-24786（KUBEDR-5712）、CVE-2024-45337（KUBEDR-6292）、CVE-2024-24790 |
| Go 工具链 | 1.21 → 1.22.7（KUBEDR-6517）→ 1.26（KUBEDR-7845） |
| 基础镜像 | 切换 `paketobuildpacks/run-jammy-tiny` → **UBI9**（`registry.access.redhat.com/ubi9/ubi`，USER 1001，maintainer 改 CloudCasa） |
| Red Hat 认证 | `ci: add redhat certification to velero pipeline`（KUBEDR-7520 "Include labels in velero build and use ubi9"，独立 redhat-build 分支×3） |
| 数据加密 | bundle 层端到端加密（见 §3.5） |
| Dockerfile | 移除 restic 构建段；移除 GCR 构建 |

---

## 7. 构建与 CI/CD

- **`plugins.ini` 组合插件镜像清单**（核心配置）：

```ini
[plugin:aws]    image = cloudcasaAgent.azurecr.io/catalogicsoftware/velero-plugin-for-aws:v1.14.4.1   # 自维护 fork
[plugin:gcp]    image = cloudcasaAgent.azurecr.io/catalogicsoftware/velero-plugin-for-gcp:v1.14.4.1   # 自维护 fork
[plugin:azure]  image = velero/velero-plugin-for-microsoft-azure:v1.14.4                              # 官方
[plugin:kubevirt] image = cloudcasaAgent.azurecr.io/catalogicsoftware/kubevirt-velero-plugin:v0.9.1.1 # 自维护 fork
[plugin:amds]   image = catalogicsoftware/amds-veleroplugin:3.1.0-master.515                          # 内部 agent 桥接插件
[velero]        image = catalogicsoftware/velero:v1.18.4-master.28
```

- `build-plugins.sh`：按 plugins.ini 多架构组装"合并插件镜像"（`fix TTY in makefile`、multiarch buildx）。
- **CI**：`Jenkinsfile`（mbartosik 引入，替换 hardcoded domain 为 env）、`fix-buildx`、移除 GCR、私有 **Azure Container Registry**（`cloudcasaAgent.azurecr.io`）、Red Hat 认证流水线。
- **自动化**：`cloudcasabot` 每次内部插件发版自动 bump `plugins.ini` 与镜像 tag（`v1.18.4-master.N`，偶数递增），引擎与插件解耦发版。
- **VERSION 文件**：fork 自管版本号（如 v1.14.0.4 → v1.14.0.12）。

---

## 8. 维护策略分析与借鉴

### 8.1 模式总结

```
上游 tag ──(squash 全量定制为一个 KUBEDR 大提交)──► fork 版本分支 vX.Y.Z.x
                                                    │
                    cloudcasabot 自动 bump 内部插件 ◄─┘ 持续迭代（工单分支→PR）
```

1. **最小 diff 原则**：不改 module path、不改目录骨架、定制收敛在少数新包（`internal/catalogic`、`pkg/instance`、`pkg/util/kubevirt`、`pkg/persistence/bundlecrypt`）+ 精准修改点，升级成本 = 一次 squash 重放。
2. **引擎做减法**：与其改造上游 controller，不如直接禁用不属于引擎职责的 6 个 controller，把平台能力还给控制面 —— 这是"工具改引擎"路线的关键取舍。
3. **命名空间殖民**：CRD group 改为 `cloudcasa.io`，label/annotation 全部前缀化，与上游生态（官方 CSI 插件等）隔离，避免双系统互踩。
4. **通信走 K8s 原语**：引擎↔agent↔SaaS 用 ConfigMap（进度/配置）+ CR label（认领）+ env（身份），不引入额外中间件。
5. **装饰器扩展点**：ObjectStore 加密用装饰器包裹插件接口实现，不动上游持久化主流程。

### 8.2 对我们 fork（cloudsbit/velero）的借鉴点

| CloudCasa 做法 | 可借鉴场景 |
|---|---|
| per-job 引擎 + instance label | 多租户/多 job 隔离、按 job 计量与排障 |
| `IncludeNamedResources` | 细粒度选择性备份（按对象勾选），上游无此 API |
| StorageClassBackupMethodMap / per-PVC method | 异构存储下按类配置快照 vs copy 策略 |
| encryptingObjectStore 装饰器 | 任意对象存储后端的无差别加密 |
| 只读 BSL 本地 writer | 灾备恢复集群（只读挂载备份存储）场景 |
| Version-branch + squash 重放 | 跟踪上游版本的工程纪律 |
| cloudcasabot 自动 bump | 引擎与插件解耦的自动化发版 |

### 8.3 风险与代价

- **上游漂移**：默认分支仍停在 v1.14（落后上游 main 约 2342 提交），升级全靠人工 squash 重放；v1.18.4.x 上的 32 提交里大多数是 CI commit，功能定制的重放体量不小。
- **深度耦合内部插件**：amds 无公开文档，脱离 CloudCasa SaaS 无法独立使用该镜像。
- **命名分裂**：CRD group 改名后与上游生态（Helm chart、官方插件、社区工具）互不兼容。

---

## 9. 附录：关键新增文件清单

**架构/协同**：
- `pkg/instance/scope.go`(+test) — 引擎实例作用域
- `pkg/controller/instance_scope.go`(+test) — controller 级 CR 过滤
- `internal/catalogic/{types,utils}.go`(+test) — CloudCasa 公共类型/工具（进度数据、PluginConfig、注解常量、namespace 常量）
- `plugins.ini`、`build-plugins.sh`、`Jenkinsfile`、`VERSION`、`replace_group_names.py`

**加密/存储**：
- `pkg/persistence/bundlecrypt/bundlecrypt.go`(+test) — 加密原语
- `pkg/persistence/encrypting_object_store.go`(+test) — 加密 ObjectStore 装饰器
- `pkg/util/backup_store/{artifact_writer,backup_store_writer,local_writer}.go`(+test) — 只读 BSL 本地写入

**功能**：
- `pkg/util/kubevirt/{kubevirt_vm_status_reporter,vm_options}.go`(+test) — KubeVirt
- `pkg/restore/vm_rename_cloudcasa_test.go`、`pkg/controller/restore_finalizer_vm_rename_cloudcasa_test.go` — VM 换名恢复
- `pkg/util/csi/group_snapshot_cloudcasa.go`(+test) — VGS 定制
- `pkg/restore/named_resources_test.go`、`pkg/controller/backup_deletion_actions_cloudcasa_test.go` 等 — 功能测试（命名资源、删除动作）
- `pkg/controller/pod_volume_restore_controller_legacy.go` — 旧版 PVR 兼容
- `pkg/constant/constant.go`（fork 版新增常量）

**重灾区修改文件**（非新增）：`pkg/backup/{backup,item_backupper,item_collector}.go`、`pkg/restore/restore.go`、`pkg/backup/actions/csi/pvc_action.go`、`pkg/restore/actions/csi/pvc_action.go`、`pkg/controller/{backup_controller,backup_deletion_controller,backup_finalizer_controller,restore_controller,restore_finalizer_controller}.go`、`internal/volume/volumes_information.go`、`internal/volumehelper/volume_policy_helper.go`、`pkg/util/kube/pvc_pv.go`、`pkg/util/csi/volume_snapshot.go` —— 即备份/恢复引擎的 PVC/CSI 决策路径是定制修改最密集的区域。

---

*报告基于公开 GitHub 数据与源码分析；amds 插件职责等少量内部机制为合理推断，已标注。*
