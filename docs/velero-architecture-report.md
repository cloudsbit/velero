# Velero 代码库整体架构研究报告

> **研究范围**：本仓库 HEAD `a19430133`（dev 分支，fork 自 vmware-tanzu/velero，module 名保持 `github.com/velero-io/velero`，Go 1.27）。
> **架构代际**：对应上游 v1.16+ 架构 —— ItemBlock 并行备份、BackupItemAction v2（异步操作）、统一 kopia 仓库（restic 代码已移除）、VGDP + 微服务数据搬运、BackupVolumeInfo 卷信息模型。
> **本文目的**：从代码出发梳理 Velero 的完整架构：进程拓扑、CRD、控制器、备份/恢复引擎、数据平面、插件体系、CLI 与横切机制。所有结论均标注源码位置（相对仓库根目录）。

---

## 目录

1. [项目定位与设计哲学](#1-项目定位与设计哲学)
2. [仓库顶层结构](#2-仓库顶层结构)
3. [运行形态与进程拓扑](#3-运行形态与进程拓扑)
4. [API 层：CRD 与状态机](#4-api-层crd-与状态机)
5. [控制器层](#5-控制器层)
6. [备份引擎（pkg/backup）](#6-备份引擎pkgbackup)
7. [恢复引擎（pkg/restore）](#7-恢复引擎pkgrestore)
8. [对象存储持久化（pkg/persistence）](#8-对象存储持久化pkgpersistence)
9. [数据平面：datapath / exposer / uploader / repository](#9-数据平面)
10. [插件体系（pkg/plugin）](#10-插件体系pkgplugin)
11. [CLI 体系（pkg/cmd）](#11-cli-体系pkgcmd)
12. [横切机制](#12-横切机制)
13. [端到端核心流程总览](#13-端到端核心流程总览)
14. [构建、部署与测试](#14-构建部署与测试)
15. [本 fork 与上游的差异点](#15-本-fork-与上游的差异点)
16. [附录：关键入口速查表](#16-附录关键入口速查表)

---

## 1. 项目定位与设计哲学

Velero 是 Kubernetes 集群的**备份/恢复/迁移**工具，核心能力：灾备恢复、跨集群迁移、生产数据复制到开发/测试环境。

代码层面的四条设计主线：

| 设计主线 | 体现 |
|---|---|
| **CR 驱动、控制器模式** | 一切操作（备份/恢复/调度/删除/数据搬运）都是自定义资源，由 reconciler 驱动状态机推进，天然可审计、可重入、可分布式协作 |
| **控制面/数据面分离** | `velero server`（Deployment，控制面）只编排 CR；真正的卷数据传输由 `node-agent`（DaemonSet）派生的微服务 Pod 完成 |
| **插件化** | 对象存储、云盘快照、item 级备份/恢复动作全部通过 gRPC 插件（hashicorp/go-plugin）扩展，核心仓库只含内置插件与框架 |
| **引擎与策略解耦** | 过滤（includes/excludes、resourcePolicies）、恢复改写（resourcemodifiers）、快照决策（volume policies）均为数据驱动的策略层 |

官方架构入口 `ARCHITECTURE.md`（仅 43 行）明确：server 是单副本 Deployment + 一组 controller；卷数据两条路径（内置 file-system backup 与 CSI 快照数据搬移）；设计提案在 `design/`，已实现的归档到 `design/Implemented/`。

---

## 2. 仓库顶层结构

| 目录/文件 | 职责 |
|---|---|
| `cmd/` | 3 个二进制入口：`velero`（主程序，所有子命令）、`velero-helper`（无限挂起的 pause 占位进程）、`velero-restore-helper`（restore-wait init 容器） |
| `pkg/` | 全部核心业务库（34 个一级子包，见下表） |
| `internal/` | 不对外暴露的实现：credentials、delete、hook、resourcepolicies、storage、velero、volume、volumehelper、restartabletest |
| `config/` | CRD manifests（`config/crd/v1/bases/` 11 个 + `config/crd/v2alpha1/bases/` 2 个，经 `go:embed` 打进二进制供 `velero install` 使用）、RBAC 样例 |
| `design/` | 84 篇设计文档：顶层 6 篇（`_template.md`、`vsv2-design.md`、`upload-progress.md` 等）+ `design/Implemented/` 78 篇已实现设计（csi-snapshots、unified-repo-and-kopia-integration、concurrent-backup-processing、vgdp-micro-service、volume-data-inplace-restore 等） |
| `hack/` | 构建/代码生成/CI 脚本：`build.sh`、`update-*.sh`（proto、CRD、deepcopy codegen）、`run-e2e-kind.sh`、`release-tools/` |
| `test/` | ginkgo e2e 与性能测试（`test/e2e/` 约 20 个场景目录、`test/perf/`、`test/util/`） |
| `examples/` | minio 本地对象存储、nginx-app 入门示例、resource-modifier 示例 |
| `site/` | velero.io 官网源码（Hugo，含 v0.3.0→v1.19 全部版本文档） |
| `changelogs/`、`assets/`、`tilt-resources/`、`third_party/` | 变更日志、logo、Tilt 开发环境 manifests、代码生成模板 |

**pkg/ 一级子包速查**：

| 包 | 职责 | 包 | 职责 |
|---|---|---|---|
| `apis` | CRD 类型（v1 / v2alpha1 / shared） | `metrics` | Prometheus 指标 |
| `archive` | 备份 tar 读写/解析 | `nodeagent` | node-agent 探测与模板继承 |
| `backup` | 备份执行引擎 | `persistence` | 对象存储 BackupStore 抽象 |
| `builder` | 测试用 fluent 对象构造器（43 个） | `plugin` | 插件框架（4 层） |
| `buildinfo` | 版本信息构建注入 | `podexec` | exec hook 执行器 |
| `cbtservice` | 块级变更跟踪（CBT）服务 | `podvolume` | 文件系统备份（FSB） |
| `client` | client Factory 与 CLI 配置 | `repository` | 统一备份仓库管理（kopia） |
| `cmd` | CLI / server / 插件命令 | `resourcemodifiers` | 恢复期资源改写 |
| `constant` | 常量（controller 名等） | `restore` | 恢复执行引擎 |
| `controller` | 全部 reconciler（44 个 .go） | `restorehelper` | restore-wait init 容器常量 |
| `datamover` | DU/DD 的微服务桥接 action | `types` | 共享类型（JobConfigs 等） |
| `datapath` | 数据面抽象（VGDP/微服务 watcher） | `uploader` | 上传器抽象（kopia / velero-block） |
| `discovery` | API discovery helper | `util` | kube/filesystem 等通用工具 |
| `exposer` | 卷/快照"暴露"抽象 | 其余 | `features`、`install`、`itemblock`、`itemoperation`、`itemoperationmap`、`kopia`、`kuberesource`、`label`、`test` |

---

## 3. 运行形态与进程拓扑

### 3.1 二进制与运行时形态

三个二进制（v1.16 起合并进**单一 velero 镜像**，`Dockerfile`）：

| 二进制 | 入口 | 形态 |
|---|---|---|
| `velero` | `cmd/velero/velero.go` → `pkg/cmd/velero/velero.go:59 NewCommand()` | CLI + 两种服务进程 |
| `velero-helper` | `cmd/velero-helper/velero-helper.go` | 仅一个 `pause` 参数，`time.Sleep` 无限挂起，用于让数据面 hosting pod 保持 Running |
| `velero-restore-helper` | `cmd/velero-restore-helper/velero-restore-helper.go` | 恢复目标 Pod 的 init 容器：轮询 `/restores/<dir>/.velero/<restore-UID>` 完成标记，全部就绪后退出，保证业务容器启动时卷数据已恢复完 |

`velero` 的四种运行时进程形态：

1. **`velero server`** — 集群内 Deployment（控制面），运行 15 个 controller（`pkg/cmd/server/server.go`）。
2. **`velero node-agent server`** — 集群内 DaemonSet（节点数据面代理），运行 4 个 controller（`pkg/cmd/cli/nodeagent/server.go`）。
3. **`velero data-mover backup|restore`** — 数据搬运微服务，由 exposer 在 hosting Pod 内启动（实现 `pkg/cmd/cli/datamover/` + `pkg/datapath/`）。
4. **`velero run-plugins`** — 隐藏命令，velero 自身作为内置插件宿主（`pkg/cmd/server/plugin/plugin.go:44`）。

### 3.2 velero server 启动流程

`pkg/cmd/server/server.go`（1222 行），配置定义 `pkg/cmd/server/config/config.go`：

1. `newServer()`：校验 uploader-type（默认 kopia）、QPS/burst → 创建 kubeClient / dynamicClient / controller-runtime client → `pluginRegistry.DiscoverPlugins()`（扫描 `/plugins` 目录）→ Scheme 注册（velero v1/v2alpha1、volumesnapshot v8、volumegroupsnapshot 等）→ `ctrl.NewManager`（cache 限定 velero namespace）→ credentials FileStore/SecretStore。
2. `s.run()`：信号处理 / 可选 pprof（:6060）→ 校验 velero namespace 与 CRD 安装情况 → `initDiscoveryHelper`（每 5 分钟刷新）→ `checkNodeAgent`（检查 node-agent DaemonSet）→ `initRepoManager`（repo key Secret、RepoLocker/Ensurer/Manager）→ metrics :8085 → `setupBeforeControllerRun`（**把重启遗留的 InProgress Backup/Restore 标记为 Failed** 并联动取消 DU/DD/PVB/PVR）→ `runControllers` 启动全部 reconciler。

### 3.3 node-agent 启动

`pkg/cmd/cli/nodeagent/server.go:398-521`：构建 manager 后创建 **PVB / PVR / DataUpload / DataDownload** 4 个 controller；随后对本节点残留任务执行 `AttemptPVBResume / AttemptPVRResume / AttemptDataUploadResume / AttemptDataDownloadResume`（node-agent 重启后续传）；读取 node-agent-configmap（priorityClass、loadAffinity、backupPVC、cache PVC 等）与数据路径并发配置；校验 `host_pods` hostPath 挂载可读到本节点 Pod 卷。

### 3.4 Feature flags

机制 `pkg/features/feature_flags.go`，枚举 `pkg/apis/velero/v1/constants.go:40-48`，仅存两个（历史 flag 随功能 GA 移除）：

| Flag | 含义 |
|---|---|
| `EnableCSI` | 启用 CSI 快照集成路径（替代云厂商 VolumeSnapshotter 插件），影响 PV/PVC 备份分支与快照决策 |
| `EnableAPIGroupVersions` | 备份归档多 API group 版本，恢复时按优先级选版本 |

---

## 4. API 层：CRD 与状态机

类型定义 `pkg/apis/velero/v1/`、`pkg/apis/velero/v2alpha1/`；manifests `config/crd/*/bases/`（共 13 个）。**无 clientset/informers codegen**（无 `pkg/generated`），统一使用 controller-runtime client + dynamic client，仅 deepcopy 为生成代码。

### 4.1 v1 CRD（11 个）

| CR | spec 关键字段（一句话） |
|---|---|
| `Backup` | included/excluded namespaces+resources（含 cluster/namespaced 细分变体）、labelSelector/orLabelSelectors、snapshotVolumes、TTL、storageLocation、volumeSnapshotLocations、defaultVolumesToFsBackup、hooks、snapshotMoveData、resourcePolicies、DryRun（fork 新增） |
| `Restore` | backupName/scheduleName、namespaceMapping、过滤、restorePVs、restoreStatus、preserveNodePorts、hooks、existingResourcePolicy、existingVolumeDataPolicy、resourceModifiers、DryRun（fork 新增） |
| `Schedule` | template（内嵌 BackupSpec）+ cron、paused、skipImmediately、useOwnerReferencesInBackup |
| `BackupStorageLocation`（BSL） | provider、config、credential、objectStorage（bucket/prefix/caCert）、default、accessMode（ReadWrite/ReadOnly） |
| `VolumeSnapshotLocation`（VSL） | provider、config、credential（云厂商原生快照） |
| `DownloadRequest` | target{kind,name}，kind 共 14 种（BackupLog/Contents/VolumeSnapshots/ItemOperations/ResourceList/Results、Restore*、CSI*、VolumeInfos） |
| `DeleteBackupRequest` | backupName（单字段，触发备份删除） |
| `PodVolumeBackup`（PVB） | node、pod、volume、BSL、uploaderType、tags、cancel、parentSnapshot |
| `PodVolumeRestore`（PVR） | pod、volume、BSL、snapshotID、sourceNamespace、cancel |
| `BackupRepository` | volumeNamespace + BSL + repositoryType 三元组唯一定位一个 kopia 仓库；maintenanceFrequency、repositoryConfig |
| `ServerStatusRequest` | 空spec，server 填 status（版本、插件列表） |

### 4.2 v2alpha1 CRD（2 个，数据面）

| CR | spec 关键字段 |
|---|---|
| `DataUpload`（DU） | snapshotType（CSI）、csiSnapshot{VS/StorageClass/SnapshotClass}、sourcePVC/Namespace、BSL、dataMoverConfig、cancel、operationTimeout |
| `DataDownload`（DD） | targetVolume{pvc/pv/namespace/fsType}、snapshotID、BSL、cancel |

### 4.3 关键状态机

- **Backup**：`New → Queued → ReadyToStart → InProgress → (WaitingForPluginOperations[PartiallyFailed]) → Finalizing[PartiallyFailed] → Completed/PartiallyFailed/Failed`；校验失败 `FailedValidation`；删除走 `Deleting → Deleted`。阶段流转逻辑在 `pkg/controller/backup_controller.go:299-341`。
- **Restore**：`New → InProgress → (WaitingForPluginOperations) → Finalizing → Completed/PartiallyFailed/FailedValidation/Failed`（`pkg/controller/restore_controller.go:229-293`）。
- **PVB/PVR/DU/DD**（数据面四兄弟共用）：`New → Accepted → Prepared → InProgress → Completed/Failed/Canceled`，finalizer + `Spec.Cancel` 取消语义，`cancelDelayInProgress` 宽限期（`pkg/controller/pod_volume_backup_controller.go:127-405` 等）。

---

## 5. 控制器层

### 5.1 velero server 侧（15 个 controller，`pkg/controller/`）

启动顺序见 `pkg/cmd/server/server.go`，常量 `pkg/constant/constant.go`；除 BSL 外均可被 `--disable-controllers` 禁用；`--restore-only` 自动禁用 backup/schedule/deletion/backup-operations/gc。

| Controller | Watch | 职责一句话 |
|---|---|---|
| `backup-storage-location_controller.go` | BSL（SpecChange） | 验证对象存储可达性，置 Available/Unavailable |
| `backup_queue_controller.go` | Backup（New）+ 周期源 | 并发限制（`--concurrent-backups`）下按 `QueuePosition` 排队，检测 namespace 通配冲突 |
| `backup_controller.go` | Backup（ReadyToStart） | 备份主控制器：校验 → InProgress → `runBackup` 调引擎（:881）→ 上传 tarball |
| `backup_operations_controller.go` | Backup（周期轮询） | 推进 `WaitingForPluginOperations` 阶段的异步 BackupItemOperation（如 CSI 快照/DU），完成后转 Finalizing |
| `backup_finalizer_controller.go` | Backup（Finalizing） | 调 `FinalizeBackup` 重写 tar（吸收异步操作产物，:223），上传后置终态 |
| `backup_sync_controller.go` | BSL（周期 resync，无事件） | 把对象存储中的备份元数据同步为集群内 Backup CR（默认 1min），清理孤儿备份（:350） |
| `backup_deletion_controller.go` | DeleteBackupRequest | 全量删除：DeleteItemActions 插件 → 原生快照 → repo 快照 `BatchForget` → moved snapshot → CSI VS → BSL 文件 |
| `backup_repository_controller.go` | BackupRepository + BSL | 保证 repo 就绪（Initialize/Connect），周期触发 kopia maintenance Job（:470），写回 `RecentMaintenance` |
| `restore_controller.go` | Restore | 恢复主控制器：校验 → 下载 tarball → `RestoreWithResolvers` → 上传 logs/results/resource-list |
| `restore_operations_controller.go` | Restore（周期轮询） | 推进异步 RestoreItemOperation，超时取消（:328） |
| `restore_finalizer_controller.go` | Restore（Finalizing） | 等 post-restore hook、podvolume 恢复完成（multiHookTracker），置终态 |
| `schedule_controller.go` | Schedule（SpecChange） | cron 到期时按模板创建 Backup CR（`submitBackup` :267） |
| `download_request_controller.go` | DownloadRequest | 生成带 TTL 的预签名下载 URL，过期删 CR |
| `server_status_request_controller.go` | ServerStatusRequest | 填写 server 版本与插件列表 |
| `gc_controller.go` | Backup（已过期谓词 :83-97） | 对超 TTL 备份创建 DeleteBackupRequest |

**备份被拆成 4 个 controller 协作**（queue → backup → operations → finalizer），是"长任务不阻塞 reconcile、异步操作可恢复"的关键设计。

### 5.2 node-agent 侧（4 个 controller）

| Controller | 文件 | 职责 |
|---|---|---|
| `pod_volume_backup_controller` | `pkg/controller/pod_volume_backup_controller.go` | FSB 编排：exposer 暴露源卷 hostPath → 启动 `velero pod-volume backup` 微服务 Pod → MicroServiceBRWatcher 监听 → 回写 PVB |
| `pod_volume_restore_controller` | `pkg/controller/pod_volume_restore_controller.go:134` | PVR 镜像流程；完成标记由微服务写入文件，controller 读取回写 |
| `data_upload_controller` | `pkg/controller/data_upload_controller.go` | 数据搬移备份编排：csiSnapshotExposer 暴露快照 → `velero data-mover backup` → kopia 入库 |
| `data_download_controller` | `pkg/controller/data_download_controller.go:142` | 数据搬移恢复编排：genericRestoreExposer 建 restore PVC/Pod → 搬完后 `RebindVolume` 绑回目标 PVC |

四者共用同一 phase 机、finalizer/cancel 模式与 `VgdpCounter` 并发闸（`pkg/exposer/vgdp_counter.go:26`，按 DU/DD/PVB/PVR 分类动态限流）。

---

## 6. 备份引擎（pkg/backup）

### 6.1 核心类型

| 类型 | 位置 | 说明 |
|---|---|---|
| `Backupper` 接口 | `pkg/backup/backup.go:84` | `Backup / BackupWithResolvers / FinalizeBackup` |
| `kubernetesBackupper` | `pkg/backup/backup.go:117` | 唯一实现，持有 kbClient、dynamicFactory、discoveryHelper、podVolumeBackupperFactory、backupStoreGetter 等 |
| `BackupFormatVersion = "1.1.0"` | `pkg/backup/backup.go:78` | 写入 tar 内 `metadata/version` |
| `Request` | `pkg/backup/request.go:74` | 一次备份的全部物化状态：namespace/resource 过滤器、ResolvedActions、VolumeSnapshots、BackedUpItems 去重表、VolumesInformation、WorkerPool 等 |
| `itemCollector` | `pkg/backup/item_collector.go:47` | 阶段 1：抓取候选 item 并**序列化到临时目录**，输出 `kubernetesResource` |
| `itemBackupper` | `pkg/backup/item_backupper.go:65` | 阶段 2：单 item 过滤/action/快照/写 tar |
| `BackupItemBlock` + `ItemBlockWorkerPool` | `pkg/backup/itemblock.go:31`、`item_block_worker_pool.go:19` | 并行备份单元（关联 item 同线程处理）+ worker 池 |
| `tarWriter` | `pkg/backup/backup.go:1307` | `tar.Writer + sync.Mutex`（多 worker 并发写同一 tar） |

### 6.2 备份执行完整序列

入口：`backupReconciler.runBackup`（`pkg/controller/backup_controller.go:881`）→ `BackupWithResolvers`（`pkg/backup/backup.go:272`）：

1. 打开 gzip→tar，写 `metadata/version`（1.1.0）。
2. 构建 namespace 过滤（含通配符展开、ArgoCD 管理 namespace 警告，backup.go:176/202）。
3. 构建 resource 过滤：旧式全局 includes/excludes 或新式 scope 分离 + **resourcePolicies 合并**（cluster-scoped / namespaced 两套解析，backup.go:339-403、1406、1472）。
4. 解析 hooks 与 BackupItemAction v1/v2、ItemBlockAction resolver（backup.go:413-419）。
5. `itemCollector.getAllItems()`（backup.go:466）：按 discovery 的 API group 遍历，core group 按 pods→pvcs→pvs 优先；资源级过滤、cohabitating 去重（extensions/apps 同名资源）、namespace label selector 收集、OrderedResources 排序；list 结果**落盘临时文件**，patch `status.progress.totalItems`。
6. 主循环（backup.go:641-693）：逐 item 组装 ItemBlock；`executeItemBlockActions`（:761）调 ItemBlockAction.GetRelatedItems 把关联 item 拉进同一 block；block 投入 WorkerPool **并行执行**。
7. worker 内 `backupItemBlock`（:857）：Pod pre hooks → 逐 item `backupItem` → post hooks（等待 PVB 完成）。
8. 收尾：为已备份 CR 补备份 CRD（:1055）、等全部 PVB、patch progress、输出 skipped volume 摘要。
9. 阶段交棒：有异步操作 → `WaitingForPluginOperations`（operations controller 轮询）→ `Finalizing` → `FinalizeBackup`（backup.go:1112，重跑 itemBackupper 生成更新表，`buildFinalTarball` :1263 流式重写 tar，`putVolumeInfos` :1386 上传 BackupVolumeInfo）→ Completed。

### 6.3 单 item 处理（`itemBackupper.backupItem`，item_backupper.go:92）

1. **四层过滤**：`velero.io/exclude-from-backup` label → namespace I/E → cluster-scoped 资源排除 → resource include 检查 → 策略 name 过滤 → deletionTimestamp 跳过。
2. `BackedUpItems` 去重；Pod 解析 volume，`volumeHelperImpl.ShouldPerformFSBackup` 决定 FSB 卷集合。
3. **`executeActions`**（:408）—— BackupItemAction 在此执行：`ShouldUse` 匹配 → 策略 `Skip` → CSI feature 检查 → `Execute` 返回 (updatedItem, additionalItems, operationID, postOperationItems)；`operationID` 非空生成异步 `itemoperation.BackupOperation`；AdditionalItems 递归备份（优先在 ItemBlock 内 `FindItem`，避免 API 调用）。
4. **PV 特判**：`takePVSnapshot`（:616）—— 按 volume policy 判断是否快照 → CSI PV 且 EnableCSI 时跳过（交给 CSI 插件）→ zone 解析 → 遍历 VSL 用 `VolumeSnapshotter` 插件 `CreateSnapshot`，记录 `volume.Snapshot`。
5. **Pod 特判**：`backupPodVolumes`（:389）为 FSB 卷创建 PVB CR。
6. 写 tar：`archive.GetVersionedItemFilePath` 生成路径 `resources/<group>/<resource>/<namespace>/<name>.json`（多版本特性写 `<version>/` 子路径）。

### 6.4 快照决策总表（一个 PV 的四种归宿）

| 条件 | 路径 |
|---|---|
| 云盘 PV + VSL 匹配 | VolumeSnapshotter 插件原生快照（`takePVSnapshot`） |
| CSI PV + `EnableCSI` | CSI 插件 BIA v2 创建 VolumeSnapshot（异步 operation），或 `snapshotMoveData=true` 时生成 DataUpload CR |
| Pod 卷 + FSB 策略/注解 | PVB CR → node-agent kopia 文件系统备份 |
| 策略 skip / dryRun | 跳过并记入 skipped volume |

### 6.5 dryRun 支持（fork 新增，commit 16817af77）

`Backup.Spec.DryRun` / `Restore.Spec.DryRun` + CLI `--dry-run`：完整跑业务工作流（采集、过滤、插件 action、namespace 映射），但**零副作用**——tar 写 `io.Discard`、不传 tarball（`persistBackup` 传 nil，backup_controller.go:1087）、hooks/PVB/PV 快照/DataUpload/建 namespace/Create/Patch 全部跳过；日志、results、resource-list 照常上传供审阅。插件契约要求插件在创建集群内资源前自行检查该字段。

---

## 7. 恢复引擎（pkg/restore）

### 7.1 核心类型

| 类型 | 位置 | 说明 |
|---|---|---|
| `Restorer` 接口 | `pkg/restore/restore.go:98` | `Restore / RestoreWithResolvers` |
| `kubernetesRestorer` | `restore.go:112` | 持有 discoveryHelper、dynamicFactory、namespaceClient、resourcePriorities、pvRenamer |
| `restoreContext` | `restore.go:385` | 单次恢复全部上下文：过滤器、chosenGrpVersToRestore、pvsToProvision、renamedPVs、informer factory |
| `pvRestorer` | `pkg/restore/pv_restorer.go:44` | 从原生快照 `CreateVolumeFromSnapshot` + `SetVolumeID` |
| `prioritize_group_version.go` | `chooseAPIGroupVersionsToRestore` :77 | 多版本备份的版本选择 |
| `Request` | `pkg/restore/request.go` | RestoredItems 状态表；结果常量 created/updated/failed/skipped/**dryrun**（fork） |

### 7.2 恢复优先级

默认优先级定义于 `pkg/cmd/server/config/config.go:113 defaultRestorePriorities`，可被 `--restore-resource-priorities` 覆盖：

`customresourcedefinitions → namespaces → storageclasses → volumesnapshot* → datauploads → pv → pvc → clusterroles/roles → serviceaccounts → rolebindings → secrets → configmaps → limitranges → pods → replicasets → … → endpoints`。
排序算法 `getOrderedResources`（restore.go:690）：高优先级 → 其余按字母序 → 低优先级；且 `execute()` **先以 CRD-only 单独跑一轮**再刷新 discovery（restore.go:825-869），保证自定义资源可恢复。

### 7.3 恢复执行完整序列

入口：`restoreReconciler.runValidatedRestore`（`pkg/controller/restore_controller.go:678`，从 backupStore 下载 tarball 并取 PVB/VS/VolumeInfos）→ `RestoreWithResolvers`（restore.go:189）→ `restoreContext.execute()`（:722）：

1. `archive.NewExtractor.UnzipAndExtractBackup` 解压 tar；`archive.NewParser.Parse` 解析 `resources/` 目录结构。
2. namespace 通配符按备份内实际 namespace 展开；可选 `chooseAPIVersionsToRestore`。
3. CRD 先行 pass → discovery 刷新。
4. `getOrderedResourceCollection`（:2722）：按优先级遍历，应用资源/namespace 过滤、IncludeClusterResources、策略过滤；`getSelectedRestoreableItems`（:2831）做 **namespaceMapping** 与 label selector 过滤。
5. informer 缓存预热（`--disable-informer-cache` 可关）。
6. 逐资源 `processSelectedResource`（:991）：datauploads 强制留在 velero namespace；`EnsureNamespaceExistsAndIsReady` 从 tar 内 namespace 对象重建目标 namespace（dryRun 感知）→ `restoreItem`。

### 7.4 单 item 恢复（`restoreItem`，restore.go:1414）

1. 排除检查（mustInclude 豁免）→ 确保 namespace 存在 → 跳过已完成 Pod/Job、mirror pod → `restoredItems` 去重。
2. **PV 分支按 BackupVolumeInfo.BackupMethod 分派**（:1546-1645）：
   - NativeSnapshot → `shouldRenamePV`（namespace remap 时重命名为 `velero-clone-<uuid>`）+ `remapClaimRefNS` + `pvRestorer` 从快照建卷；
   - PVB / CSISnapshot / DataUpload → 加入 `pvsToProvision`，PV 不直接恢复，由 PVC 动态重供给；
   - Retain 无快照 → 原样恢复。
3. `resetMetadataAndStatus`；**RestoreItemAction 循环**（:1683-1811）：`getApplicableActions`（AppliesTo + label selector）→ Execute → OperationID 记异步 RestoreOperation → AdditionalItems 递归恢复 → `WaitForAdditionalItems`。
4. PVC 特判：删 `spec.volumeName` 改动态供给、renamedPVs 引用改写；`ResourceModifiers` 应用（:1864）；打 `velero/backup-name`、`velero/restore-name` 标签。
5. **写集群**（:1908-2148）：不存在则 Create；已存在按 `Spec.ExistingResourcePolicy` —— `none` → warning skipped；`update` → patch 差异；ServiceAccount 特殊 merge。
6. Status 恢复（`velero.io/restore-status` 注解控制）；Pod：有 PVB 则异步 `restorePodVolumeBackups` + 异步 exec hooks；CRD 等待 available。

### 7.5 恢复资源改写

`pkg/resourcemodifiers`：按 JSON Patch / merge patch / strategic-merge patch 规则（ConfigMap 提供）在恢复期改写对象（如改镜像、改 storageclass）；另有内置 RIA：`change_storageclass_action.go`、`change_image_name_action.go`（按 ConfigMap 映射）。

---

## 8. 对象存储持久化（pkg/persistence)

- `BackupStore` 接口 `pkg/persistence/object_store.go:59`（PutBackup/GetBackup*/PutRestore*/GetDownloadURL…）。
- `objectBackupStoreGetter.Get`（:139）：校验 bucket/prefix → **CA 证书**（优先 `CACertRef` Secret，其次内联）→ **BSL 凭证**经 `internal/credentials` 落盘临时文件传给 ObjectStore 插件 → `objectStore.Init(config)`。
- `PutBackup`（:275）上传顺序：log → metadata → tarball（失败回滚）→ podvolumebackups / volumesnapshots / itemoperations / resource-list / results / volumeinfo（任一失败清理已传对象）。
- 目录布局由 `ObjectStoreLayout`（`object_store_layout.go:19`）定义，顶层 `backups/ restores/ restic/ metadata/ plugins/ kopia/`；单个备份对象键：
  - `backups/<name>/velero-backup.json`、`<name>.tar.gz`、`<name>-logs.gz`、`-podvolumebackups.json.gz`、`-volumesnapshots.json.gz`、`-itemoperations.json.gz`、`-resource-list.json.gz`、`-results.gz`、`-volumeinfo.json.gz`、`-csi-volumesnapshots[-contents/-classes].json.gz`
  - `restores/<name>/restore-<name>-{logs,results,resource-list,itemoperations,volumeinfo}.*`
- 对象读写最终落到 **ObjectStore 插件**（`pkg/plugin/velero/object_store.go:26`：Init/PutObject/GetObject/ObjectExists/List*/DeleteObject/CreateSignedURL）。

---

## 9. 数据平面

### 9.1 分层模型

```
node-agent controller（CR 编排：PVB/PVR/DU/DD）
   └─ exposer（把卷/快照暴露成可读路径：Expose → Peek → GetExposed → CleanUp）
        └─ datapath（AsyncBR 抽象：进程内 VGDP 或 微服务 watcher）
             └─ uploader provider（kopia / velero-block）
                  └─ udmrepo / kopialib（统一仓库接口）
                       └─ BSL 对象存储（ObjectStore 插件）
```

### 9.2 pkg/datapath —— 数据传输框架

- `AsyncBR` 接口（`pkg/datapath/types.go:69`）：Init/StartBackup/StartRestore/Cancel/Close + `Callbacks`（OnCompleted/Failed/Cancelled/Progress）。
- `Manager`（`manager.go:34`）：按 jobName 跟踪实例，`CreateGenericDataPath`（**进程内 VGDP**）与 `CreateMicroServiceBRWatcher`（**微服务模式**）两种，超并发返回 `ConcurrentLimitExceed`。
- `generalDataPath`（`data_path.go:104`）：Init 时 `RepositoryEnsurer.EnsureRepo` 确保 BackupRepository CR → `BoostRepoConnect` 打开 kopia 仓库 → `provider.NewUploaderProvider`；StartBackup/StartRestore 在 goroutine 中执行并转发进度回调。
- `MicroServiceBRWatcher`（`micro_service_watcher.go`）：**控制面与搬运 Pod 之间通过 K8s Event（`Data-Path-Started/Progress/Completed/Failed/Canceled`）+ Pod 状态 + termination message 通信**；pod 终止后从 container message 反序列化结果并收集日志（:406/:460）。

### 9.3 pkg/exposer —— 快照/卷"暴露"抽象

| 实现 | 文件 | 作用 |
|---|---|---|
| `podVolumeExposer` | `pkg/exposer/pod_volume.go:128` | 建 hosting Pod 挂源卷 **hostPath**（HostToContainer），运行 `velero pod-volume backup\|restore` |
| `csiSnapshotExposer` | `pkg/exposer/csi_snapshot.go` | 备份端：等 VS Ready → 在 velero ns 复制 VS/VSC（Retain）→ 按 storageClass 映射建 **backup PVC**（从快照恢复）→ 建 **backup Pod** 运行 `velero data-mover backup`（继承 node-agent DS 的 label/annotation/toleration） |
| `genericRestoreExposer` | `pkg/exposer/generic_restore.go` | 恢复端：等目标 PVC 未绑定 → 建 restore PVC + restore Pod 运行 `velero data-mover restore` → 完成后 `RebindVolume` 绑回目标 PVC |

### 9.4 pkg/uploader —— 上传器抽象

- Provider 接口（`pkg/uploader/provider/provider.go:47`）：`RunBackup / RunRestore`（返回 snapshotID、empty、totalBytes、incrementalBytes 等，支持 CBT 参数）。
- 实现：**kopia**（`kopia.go` → `pkg/uploader/kopia/snapshot.go:157`，文件系统/块设备双模式）与 **velero-block**（`block.go`，CBT 块增量）；`pkg/podvolume/util.go:166` 把旧 `restic` 类型映射为 kopia（**restic 代码已整体移除**，仅 CRD 字段保留兼容）。

### 9.5 pkg/repository —— 统一备份仓库

- `BackupRepository` CR 以 `{VolumeNamespace, BackupLocation, RepositoryType}` 唯一定位（`pkg/repository/backup_repo_op.go:33`）；`Ensurer`（`ensurer.go:56`）负责创建并等待 Ready。
- key 管理：所有仓库共用 Secret `velero-repo-credentials`（`pkg/repository/keys/keys.go:39`）。
- Manager（`pkg/repository/manager/manager.go:37`）：InitRepo/PrepareRepo/PruneRepo/UnlockRepo/Forget/BatchForget；provider 表**只有 kopia**（:113），读写用 `RepoLocker` 共享/排他锁。
- `udmrepo`（`pkg/repository/udmrepo/repo.go:112`）：Velero 自定义的统一仓库接口，`kopialib/` 以 kopia 库为后端，backend 支持 s3/gcs/azure/file_system。
- **maintenance**：每次维护是一个 K8s Job（`velero repo-maintenance`，`pkg/repository/maintenance/maintenance.go:553`，继承 velero 镜像/env/SA；配置可按 repo 或 global 来自 ConfigMap；保留最近 3 个 job），结果写回 `BackupRepository.Status.RecentMaintenance`。

### 9.6 pkg/podvolume —— 文件系统备份（FSB）

- server 侧 `Backupper.BackupPodVolumes`（`pkg/podvolume/backupper.go:234`）：校验 uploader → 检查 pod 所在节点有 node-agent（`nodeagent.IsRunningInNode`）→ EnsureRepo → 为每个符合条件的卷创建 PVB CR 并等待全部完成。
- 卷选择：注解 `backup.velero.io/backup-volumes[-exclude]`（`pkg/util/podvolume/pod_volume.go:233`）或 `defaultVolumesToFsBackup` opt-out，或 volume policy 的 `fs-backup` action（`internal/volumehelper/volume_policy_helper.go:316`）。
- 微服务侧：`backup_micro_service.go:130 / restore_micro_service.go:123 RunCancelableDataPath` —— 进程入口 `velero pod-volume backup|restore`，内部走 VGDP → kopia；恢复完成写 completion mark（:317）供 restore-helper init 容器探测。

### 9.7 pkg/nodeagent

`pkg/nodeagent/node_agent.go`：`IsRunningInNode`（:123）、`GetPodSpec/GetConfigs`、`GetLabelValue/GetAnnotationValue/GetTolerations`（供 data mover hosting Pod 继承 DS 上的第三方注解）、`GetHostPodPath`（:291，hostPath 路径计算）。

### 9.8 四条数据路径

```
A. FSB 备份     backup_controller → pkg/backup → 创建 PVB
                → node-agent PVB controller → podVolumeExposer(hostPath) → `velero pod-volume backup`
                → VGDP → kopia → 统一仓库 → BSL

B. DU 备份      CSI BIA v2 创建 DataUpload(SnapshotType=csi)
                → node-agent DU controller → csiSnapshotExposer(backup PVC + backup Pod)
                → `velero data-mover backup` → VGDP → kopia/block → BSL → 清理快照暴露资源

C. DD 恢复      CSI RIA v2 创建 DataDownload
                → node-agent DD controller → genericRestoreExposer(restore PVC + restore Pod)
                → `velero data-mover restore` → kopia.Restore → RebindVolume 绑回目标 PVC

D. PVR 恢复     restore_item RIA 注入 restore-wait init 容器
                → node-agent PVR controller → podVolumeExposer → `velero pod-volume restore`
                → kopia.Restore 写卷路径 → completion mark → init 容器放行业务容器
```

---

## 10. 插件体系（pkg/plugin）

### 10.1 四层架构

| 层 | 目录 | 职责 |
|---|---|---|
| 接口定义层 | `pkg/plugin/velero/` | 插件作者实现的纯 Go 接口（无 gRPC 依赖） |
| framework 层 | `pkg/plugin/framework/` | hashicorp/go-plugin 粘合：Server 端注册/Serve（`server.go:123/259`）、Client 端 stub、握手（`handshake.go:27`，ProtocolVersion 2）、action resolver |
| clientmgmt 层 | `pkg/plugin/clientmgmt/` | 主进程侧：Manager、registry、进程管理（`process/`，崩溃自动重启 `restartable_process.go`） |
| proto/generated 层 | `pkg/plugin/proto/`、`pkg/plugin/generated/` | `.proto` 与 protoc 生成代码（`hack/update-2proto.sh`） |

### 10.2 插件类型全表（`pkg/plugin/framework/common/plugin_kinds.go`）

| PluginKind | 说明 |
|---|---|
| `ObjectStore` | 备份存储后端（S3/GCS/Azure Blob…） |
| `VolumeSnapshotter` | 云盘原生快照 |
| `BackupItemAction` v1/v2 | 备份 item 动作；v2 支持异步（operationID + Progress/Cancel） |
| `RestoreItemAction` v1/v2 | 恢复 item 动作；v2 同上 + AreAdditionalItemsReady |
| `DeleteItemAction` | 删除备份时联动清理插件资源 |
| `ItemBlockAction` | 并行备份分块：GetRelatedItems 把关联 item 拉进同一 ItemBlock |
| `PluginLister` | 内部：插件进程自描述（发现用） |

v1 插件经 `PluginKindsAdaptableTo` 自动适配注册为 v2 kind（`process/registry.go:211` 双注册）。注意：**PodVolumeBackup/Restore 不是插件**，是 CRD + node-agent controller。

### 10.3 发现与加载

`pkg/plugin/clientmgmt/process/registry.go`：`DiscoverPlugins()`(:76) 先加入 `os.Args[0]`（velero 自身，`run-plugins` 宿主）再递归扫描插件目录；`listPlugins()`(:190) 逐个启动子进程 dispense PluginLister 自描述注册。外部插件通过 `velero plugin add IMAGE`（`pkg/cmd/cli/plugin/add.go`：以 initContainer 挂到 velero Deployment）或 `velero install --plugins` 安装；velero-plugin-for-aws/gcp/azure/csi 为独立仓库。

### 10.4 内置插件（约 30 个，注册于 `pkg/cmd/server/plugin/plugin.go:53-195`）

**BackupItemAction**（`pkg/backup/actions/`）：

| 插件 | 作用 |
|---|---|
| `velero.io/pv`（PVCAction） | 备份 PVC 时把绑定的 PV 加入 additionalItems |
| `velero.io/pod` | 收集 Pod 引用的全部 PVC |
| `velero.io/service-account` | 把 SA 关联的 ClusterRoleBinding/ClusterRole 纳入备份 |
| `velero.io/crd-remap-version` | 特定 CRD v1→v1beta1 版本适配 |
| CSI v2：`csi-pvc-backupper`、`csi-volumesnapshot{,content,class}-backupper` | 创建/传递 VolumeSnapshot 族对象；`snapshotMoveData` 时生成 DataUpload |

**RestoreItemAction**（`pkg/restore/actions/`）节选：`add-pvc-from-pod`、`pod`（重置调度字段）、`pod-volume-restore`（注入数据恢复 init 容器）、`init-restore-hook`、`service`（重置 ClusterIP/nodePort）、`service-account`（merge 拉取 secret）、`role/cluster-role-bindings`（subject namespace 重映射）、`change-storage-class`、`change-image-name`、`job`（去 controller-uid label）、`pvc`、`secret`、`apiservice`、`dataupload`；CSI v2：`csi-pvc-restorer`（含 DataDownload 发起与 in-place restore 预检查 `pkg/restore/inplace/preflight.go`）等。

**ItemBlockAction**：pvc、pod、service-account。**DeleteItemAction**：`dataupload-delete`、`csi-volumesnapshotcontent-delete`。

---

## 11. CLI 体系（pkg/cmd）

根命令 `pkg/cmd/velero/velero.go:59 NewCommand()`；client Factory `pkg/client/factory.go:40`（kube/dynamic/controller-runtime/discovery 客户端；kubeconfig 优先级 `--kubeconfig` → `KUBECONFIG` → in-cluster；namespace `VELERO_NAMESPACE` → 配置文件 → 默认 `velero`）。

```
velero
├── backup            create/delete/describe/download/get/logs        pkg/cmd/cli/backup/
├── schedule          create/delete/describe/get/pause/unpause(fork)   pkg/cmd/cli/schedule/
├── restore           create/delete/describe/get/logs                 pkg/cmd/cli/restore/
├── server            控制面主进程                                     pkg/cmd/server/server.go
├── node-agent        节点代理主进程                                   pkg/cmd/cli/nodeagent/
├── run-plugins       (隐藏) 内置插件宿主                              pkg/cmd/server/plugin/plugin.go
├── install/uninstall CRD+RBAC+Deployment+DaemonSet 生成               pkg/cmd/cli/install/
├── plugin            add/get/remove                                  pkg/cmd/cli/plugin/
├── backup-location   create/delete/get/set                           pkg/cmd/cli/backuplocation/
├── snapshot-location create/get/set                                  pkg/cmd/cli/snapshotlocation/
├── repo              get                                             pkg/cmd/cli/repo/
├── repo-maintenance  (fork) 维护 Job 入口                             pkg/cmd/cli/repomantenance/
├── data-mover        (fork) backup/restore 微服务入口                 pkg/cmd/cli/datamover/
├── pod-volume        (fork) backup/restore 微服务入口                 pkg/cmd/cli/podvolume/
├── get/describe/create/delete  kubectl 风格聚合入口（别名机制）
├── debug             打包诊断 bundle（crash-diagnostics）             pkg/cmd/cli/debug/
├── version / completion / bug / client config
```

输出格式化：`-o table|json|yaml`（`pkg/cmd/util/output/`，table 走 `metav1.Table` 打印器；describe 有 JSON 结构化版本）。`velero backup/restore logs|download` 经 **DownloadRequest CR** → controller 生成预签名 URL。

---

## 12. 横切机制

### 12.1 指标（pkg/metrics/metrics.go）

`velero_` 前缀 Prometheus 指标族：备份（tarball_size、total/attempt/success/partial_failure/failure/deletion_*、duration_seconds、last_successful_timestamp、items_total/errors、last_status）、恢复（restore_*）、快照（volume_snapshot_*、csi_snapshot_*）、pod volume（enqueue/dequeue、operation_latency）、data mover（data_upload/download_success/failure/cancel）、schedule_expected_interval_seconds、repo_maintenance_*。:8085 暴露。

### 12.2 internal/ 包

| 包 | 职责 |
|---|---|
| `internal/credentials` | 凭据 FileStore/SecretStore/getter（BSL、VSL、repo key 的临时落盘） |
| `internal/hook` | item hook handler、wait exec handler、hook tracker（备份/恢复钩子） |
| `internal/resourcepolicies` | 卷资源策略解析与匹配（skip/fs-backup 等 action，含 fork 扩展的 cluster/namespaced 过滤策略） |
| `internal/delete` | DeleteItemAction handler + CSI VSC 删除动作 |
| `internal/storage` | BSL 只读/默认校验 |
| `internal/volume` | 原生快照、VSL 工具、VolumesInformation 汇总 |
| `internal/volumehelper` | VolumePolicyHelper（FSB 决策） |
| `internal/velero` | 默认镜像名、ServerStatusRequest 工具 |

### 12.3 其他

- `pkg/discovery/helper.go:39`：API discovery 缓存 + 定时 Refresh；按 verbs 过滤、跳过子资源；EnableAPIGroupVersions 时用 `ServerGroupsAndResources`。
- `pkg/kuberesource`：GroupResource 常量表。
- `pkg/itemoperation` + `pkg/itemoperationmap`：异步 item 操作类型与结果内存 map（供 DownloadRequest 导出 JSON）。
- `pkg/podexec`：exec hook 在 Pod 内执行命令（SPDY）。

---

## 13. 端到端核心流程总览

### 13.1 备份全流程

```
用户/CLI ──创建──► Backup CR (New)
   │
Schedule controller（定时）──┘
BackupQueue controller ──► ReadyToStart（并发排队）
Backup controller:
  校验 → InProgress
  └─ pkg/backup 引擎:
     itemCollector 抓取+落盘 → ItemBlock 拆分 → WorkerPool 并行
       每个 item: 过滤 → BIA 插件 → PV 快照决策(native/CSI/FSB) → 写 tar
     Pod hooks(pre/post) ；FSB 卷 → 创建 PVB CR
  ──► WaitingForPluginOperations（如有异步操作）
BackupOperations controller: 轮询 BackupItemOperation（CSI VS / DU）→ 完成转 Finalizing
BackupFinalizer controller: FinalizeBackup 重写 tar（吸收 postOperationItems）
  ──► persistence.PutBackup 上传 tarball+元数据 ──► Completed
BackupSync controller: 对象存储元数据 → 集群内 Backup CR（只读 BSL 恢复集群可见）
GC controller: TTL 到期 → DeleteBackupRequest
BackupDeletion controller: DeleteItemActions → 原生快照 → repo BatchForget → CSI → BSL 文件 → Deleted
```

### 13.2 恢复全流程

```
用户 ──► Restore CR → Restore controller:
  校验(找 backup) → InProgress → 下载 tarball → pkg/restore 引擎:
    解压 → CRD 先行恢复 + discovery 刷新 → 优先级排序
    逐资源: namespaceMapping → EnsureNamespace → restoreItem
      PV 分派(native 快照建卷 / 动态重供给) → RIA 插件 → Create/Patch
    Pod: PVR 创建 + restore-wait init 容器 + exec hooks
  ──► RestoreOperations / RestoreFinalizer ──► Completed
```

### 13.3 数据搬移（snapshot data movement）

```
备份: CSI BIA(csi-pvc-backupper) → VolumeSnapshot + DataUpload CR
  node-agent DU controller → csiSnapshotExposer: VS→backup PVC→backup Pod
  → kopia 把快照数据搬入统一仓库 → DU Completed → 清理
恢复: CSI RIA(csi-pvc-restorer) → DataDownload CR
  node-agent DD controller → genericRestoreExposer: restore PVC + restore Pod
  → kopia.Restore → RebindVolume → 目标 PVC 绑定恢复出的 PV
```

---

## 14. 构建、部署与测试

- **镜像**：单一 velero 镜像含 3 个二进制（`Dockerfile`：golang:1.27-trixie 构建 + ubuntu-noble-run-tiny 运行时）；`Dockerfile-Windows` 仅 velero。node-agent DaemonSet 复用同一镜像，仅 entrypoint 不同。
- **Makefile 主要 target**：`build`（经 `hack/build-image` 容器跑 `hack/build.sh`，8 平台交叉编译到 `_output/bin/`）、`local`、`container`/`push-manifest`（docker buildx 多架构）、`test`/`test-e2e`/`test-perf`、`update`/`verify`/`lint`（代码生成与检查）、`release`（goreleaser）、`changelog`、`gen-docs`。
- **代码生成**：CRD yaml（`hack/update-3generated-crd-code.sh`）、deepcopy、proto（`hack/update-2proto.sh`）。
- **Tilt 本地开发**：`Tiltfile` + `tilt-resources/` —— 部署 velero Deployment/CRD/可选 minio，live_update 热重载，支持 Delve 调试（:2345），可挂接 provider 插件仓库。
- **e2e**（ginkgo，`hack/run-e2e-kind.sh` 驱动 kind 集群）：`test/e2e/` 覆盖 basic、backup、backups（deletion/ttl/sync）、bsl-mgmt、pv-backup、schedule、resource-filtering、resourcemodifiers、resourcepolicies、inplacerestore、migration、nodeagentconfig、parallelfilesdownload/upload、repomaintenance、scale、upgrade 等；`test/perf/` 性能测试；`test/util/velero` 为 CLI 封装。

---

## 15. 本 fork 与上游的差异点

| 差异 | 位置 |
|---|---|
| **备份/恢复 dryRun 模式** | `Backup/Restore.Spec.DryRun`、CLI `--dry-run`、引擎内 dryRun 分支（见 §6.5/§7） |
| **细粒度资源过滤策略** | resourcePolicies 扩展出 clusterScopedFilterPolicy / namespacedFilterPolicies（备份 `request.go:97-111`、`backup.go:1406/1472`；恢复 `restore.go` 对应 resolve） |
| **Schedule pause/unpause** | `pkg/cmd/cli/schedule/pause.go` |
| **CLI 新增** | `data-mover`、`pod-volume backup/restore`、`repo-maintenance`（暴露微服务入口便于运维） |
| **恢复结果新增 dryrun 状态** | `pkg/restore/request.go:41-43` |
| 仓库根私有文件 | `build_to_registry2.toml`、`cc_compare.json`、`restore-hooks_product-requirements.md` |

其余（ItemBlock 并行、BIA/RIA v2、VGDP 微服务、统一 kopia 仓库、BackupVolumeInfo 等）与上游 v1.16+ 主线一致。

---

## 16. 附录：关键入口速查表

| 想看什么 | 去哪 |
|---|---|
| server 启动/控制器注册 | `pkg/cmd/server/server.go`、`pkg/cmd/server/config/config.go` |
| 备份引擎主流程 | `pkg/backup/backup.go:272 BackupWithResolvers` |
| 单 item 备份/过滤/action | `pkg/backup/item_backupper.go:92` |
| item 采集与落盘 | `pkg/backup/item_collector.go:211 getAllItems` |
| 恢复引擎主流程 | `pkg/restore/restore.go:722 ctx.execute()` |
| 单 item 恢复 | `pkg/restore/restore.go:1414 restoreItem` |
| 恢复优先级 | `pkg/cmd/server/config/config.go:113` |
| 控制器全集 | `pkg/controller/`（15 server + 4 node-agent） |
| 数据面抽象 | `pkg/datapath/types.go`、`data_path.go`、`micro_service_watcher.go` |
| 快照/卷暴露 | `pkg/exposer/{pod_volume,csi_snapshot,generic_restore}.go` |
| 上传器 | `pkg/uploader/provider/{provider,kopia,block}.go` |
| 统一仓库 | `pkg/repository/{ensurer,manager,locker}.go`、`udmrepo/repo.go`、`maintenance/` |
| FSB | `pkg/podvolume/{backupper,restorer,backup_micro_service,restore_micro_service}.go` |
| 对象存储布局 | `pkg/persistence/object_store.go`、`object_store_layout.go` |
| 插件框架 | `pkg/plugin/{velero,framework,clientmgmt,proto}/` |
| 内置插件注册 | `pkg/cmd/server/plugin/plugin.go` |
| CRD 类型 | `pkg/apis/velero/v1/`、`v2alpha1/` |
| CLI 根命令 | `pkg/cmd/velero/velero.go` |
| 设计文档 | `design/`（84 篇，已实现归档 `design/Implemented/`） |
| Feature flags | `pkg/features/feature_flags.go`、`pkg/apis/velero/v1/constants.go:40` |
| 指标 | `pkg/metrics/metrics.go` |
| e2e | `test/e2e/`、`hack/run-e2e-kind.sh` |
