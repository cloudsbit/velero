# Velero Backup/Restore DryRun 功能实施计划（issue #448）

## Context

在当前 clone 分支实现 issue #448 讨论的备份/恢复 DryRun 功能。核心语义：**完整跑通备份/恢复流水线**（采集、过滤、插件 ItemAction 的 yaml 修改与 additional items 照常），但**不产生任何真实副作用**——不写集群资源、不建快照、不做数据移动；仅照常上传 log、results、resource list，让用户预演"哪些资源会被处理"。

已确认的决策：
- backup dry-run 时**全部跳过**快照创建（native 云快照 + CSI VolumeSnapshot + DataUpload）
- CLI（`velero backup create` / `velero restore create`）**新增 `--dry-run` flag**，语义为"CR 照常创建，由 server 执行演练"（与 kubectl 客户端语义不同，help 文本中说明）
- 字段类型用普通 `bool`（unset=false 即非 dry run，无需区分指针三态）
- restore 侧被跳过创建的资源在 resource list 中用新 action 标记 `dryrun`（现有值为 created/updated/failed/skipped，自由字符串）

## 一、API 定义（新字段 + 生成物）

1. `pkg/apis/velero/v1/backup_types.go`：BackupSpec 末尾新增
   ```go
   // +optional
   // DryRun specifies that this backup should be a dry run: the full backup
   // workflow runs (item collection, plugins, filters), but no tarball is
   // created/uploaded and no snapshots, PodVolumeBackups or DataUploads are
   // created. Logs, results and the backup resource list are uploaded as usual.
   DryRun bool `json:"dryRun,omitempty"`
   ```
2. `pkg/apis/velero/v1/restore_types.go`：RestoreSpec 末尾新增同款 `DryRun bool`（注释对应 restore 语义：跳过资源 create/patch、PVR/DataDownload 创建）。
3. 运行 `hack/update-3generated-crd-code.sh` 重新生成：`zz_generated.deepcopy.go`、`config/crd/v1/bases/velero.io_backups.yaml`、`velero.io_restores.yaml`、`velero.io_schedules.yaml`（Schedule 内嵌 BackupSpec，自动获得该字段）、v2alpha1 产物、`config/crd/v1/crds/crds.go`。
4. `pkg/builder/backup_builder.go`、`pkg/builder/restore_builder.go`：新增 `DryRun(bool)` 链式方法（参照 `SnapshotVolumes` L216 的写法）。

## 二、Backup 侧改动（guard 均为 `backup.Spec.DryRun`）

1. **tarball 不创建/不上传** — `pkg/controller/backup_controller.go` `runBackup`（L881-1026）：
   - dry run 时跳过 `os.CreateTemp` 创建 tarball 临时文件（L893-898）
   - `BackupWithResolvers` 的 `backupFile` 参数本就是 `io.Writer`，dry run 传 `io.Discard`（序列化照常但全部丢弃，tarball 不落盘）
   - `persistBackup`（L1070）：dry run 时 `backupContents` 传 nil → `object_store.go seekAndPutObject` 对 nil 直接跳过（已验证 L735-738 nil 安全），即只上传 metadata/log/resource-list/results/volumeInfo 等
   - `closeAndRemoveFile`、`recordBackupMetrics` 均已 nil 安全（已验证）
2. **native 快照跳过** — `pkg/backup/item_backupper.go` `takePVSnapshot`（L610）：入口处 dryRun → log "would create snapshot" 后 return nil
3. **PVB 跳过** — `pkg/backup/item_backupper.go` L314 `backupPodVolumes` 调用点：dryRun → 跳过（PVB 创建在 `pkg/podvolume/backupper.go:380`，不再触达）
4. **CSI PVC BIA 跳过 VS/DU 创建** — `pkg/backup/actions/csi/pvc_action.go` `Execute`（L279-338 区间）：`validatePVCAndPV` 之后、`getVolumeSnapshotReference`（内部 L262 创建 VS）之前：dryRun → log 后返回 `item, nil, "", nil, nil`（无 operationID、无 VS、无 DataUpload L646、不等待 VSC）
5. **exec hooks 跳过** — `pkg/backup/backup.go` `handleItemBlockPreHooks`（L922）/`handleItemBlockPostHooks`（L944）：dryRun → 跳过 `HandleHooks` 调用（pod exec 是真实副作用），log 记录
6. 其余照常：BIA yaml 修改、additional items、resource list 记录、progress patch、metrics、phase 流转。dry run 无 item operations → `backup_finalizer_controller.go` L200 `len(operations)>0` 天然为 false，finalizer 自动跳过 tarball 下载/重写，无需改动该控制器（已验证）。
7. **describer**：`pkg/cmd/util/output/backup_describer.go` 增加 DryRun 展示。

## 三、Restore 侧改动（guard 均为 `restore.Spec.DryRun`）

1. **新常量** — `pkg/restore/request.go` L37-41：`ItemRestoreResultDryRun = "dryrun"`。
2. **核心 create/patch 跳过** — `pkg/restore/restore.go` `restoreItem`：
   - create 块（L1911-1923）：dryRun → 跳过 `resourceClient.Create`，`createdObj = obj`，记录 `restoredItems[itemKey]{action: ItemRestoreResultDryRun, ...}`
   - 已存在对象分支（L1947-2101，在 `resetMetadataAndStatus`（L1998）之前）：dryRun → 记录 DryRun action 后 return（真实 restore 此处会按 existingResourcePolicy 做 patch/skip，全部跳过）
   - status 恢复 `UpdateStatus`（L2121-2148）、managedFields patch（L2150-2171）：dryRun 跳过
   - `restorePodVolumeBackups`（L2181 调用点）：dryRun 跳过 → PVR 创建（`pkg/podvolume/restorer.go:212`）不再触达
   - exec hooks（L2185-2203 `hooksWaitExecutor.exec`）：dryRun 跳过
   - CRD 可用性等待（L2205-2214 `crdAvailable`）：dryRun 跳过（CRD 并未真实创建，等待必然失败）
3. **namespace 创建跳过** — `pkg/util/kube/utils.go` `EnsureNamespaceExistsAndIsReady` 增加 `dryRun bool` 参数（仅 restore.go L1039/L1470 两个调用方）：namespace 存在→照常 ready；不存在→log "would create"，返回 `ready=true, nsCreated=true`；`restore.go` L1482 记录 namespace 条目时 action 按 dryRun 选 `DryRun`/`Created`
4. **云盘创建跳过** — `pkg/restore/pv_restorer.go` `executePVAction`（L49-101）：pvRestorer 增加 restore 字段（构造点在 restore.go 的 restorer 构造处）；`CreateVolumeFromSnapshot`（L80）之前 dryRun → log 后 `return obj, nil`（SetVolumeID/volInfoTracker 均跳过）
5. **CSI PVC RIA 跳过 DataDownload** — `pkg/restore/actions/csi/pvc_action.go` `Execute` 分发处（L124）：dryRun 且 SnapshotMoveData → 直接返回 `UpdatedItem: input.Item`（不建 DataDownload L628、不建 CBT 基线 VS L729、不删已有 PVC L292、无 OperationID）。`executeWithoutDataMove`（纯 yaml 修改+additional items）照常执行——符合 issue "normal modifying yaml/returning additional items as usual"
6. **DataUploadRetrieveAction** — `pkg/restore/actions/dataupload_retrieve_action.go` Execute（L114 前）：dryRun → 跳过 DataUploadResult ConfigMap 创建，仍返回 `SkipRestore: true`
7. **finalizer 兼容**（已验证无需改动）：`internal/volume/utils.go RestoredPVCFromRestoredResourceList` 只认 `(created)` 后缀 → dryrun 条目自然被排除，`patchDynamicPVWithVolumeInfo` 不触发；hook tracker 无条目，`WaitRestoreExecHook` 无操作
8. Restore 对象自身的 status/progress patch（restore.go L807/957、restore_controller 各处）照常——这是 Velero 自身的 bookkeeping
9. **describer**：`pkg/cmd/util/output/restore_describer.go` 增加 DryRun 展示

## 四、CLI

1. `pkg/cmd/cli/backup/create.go`：CreateOptions 加 `DryRun bool`；BindFlags 加 `--dry-run`（help 注明：创建 Backup CR，server 执行演练，tarball/快照/数据移动均跳过，log 与 resource list 照常上传）；BuildBackup（L470 后）加 `.DryRun(o.DryRun)`
2. `pkg/cmd/cli/restore/create.go`：同上（Run 方法 L354-399 的字面量构造中加 `DryRun: o.DryRun`）
3. schedule create **不加**该 flag（周期性 dry run 无意义），但 spec 层字段随 Schedule 模板自动可用

## 五、测试与文档

- 单测：
  - `pkg/controller/backup_controller_test.go`：dry run → PutBackup 收到 nil Contents（mock backupStore 断言）、phase 走到 Completed
  - `pkg/backup/backup_test.go` / `pkg/restore/restore_test.go`：dry run 下 takePVSnapshot 跳过、restoreItem 不产生 create 调用且 restoredItems action=dryrun、namespace 缺失时不创建且记 dryrun
  - `pkg/cmd/cli/backup/create_test.go`、`pkg/cmd/cli/restore/create_test.go`：flag→spec 映射
- `changelogs/unreleased/` 新增 changelog 文件
- 插件生态约定（issue 要求"encourage plugins to check spec.DryRun"）：在字段注释/flag help/changelog 中说明外部插件应检查 `spec.dryRun` 避免自行创建集群资源

## 六、验证

1. `hack/update-3generated-crd-code.sh` 后 `git diff` 确认 4 个 CRD yaml + deepcopy 正确
2. `go build ./...`
3. `go test ./pkg/apis/... ./pkg/backup/... ./pkg/restore/... ./pkg/controller/... ./pkg/persistence/... ./pkg/cmd/cli/... ./pkg/builder/...`
4. 如有可用集群（可选手测）：
   - `velero backup create test-dry --dry-run`：phase Completed；对象存储中无 `.tar.gz` 但有 `velero-backup.json`/`-resource-list.json.gz`/-logs.gz/-results.gz；集群中无 PVB/VolumeSnapshot/DataUpload
   - `velero restore create --from-backup <x> --dry-run`：phase Completed；集群无新资源/无 PVR/DataDownload；resource list 条目为 `name(dryrun)`；logs/results 正常