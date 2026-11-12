# Phase 5 汇编稿（阶段产出原文，供报告发布员整合，非最终交付）

## 元信息
- 报告标题：Velero 代码库架构解读：这台「搬家公司」是怎么搭起来的
- 日期：2026-11-12
- 执行模式：完整（Workflow A，5 章，全部 1 轮审稿 PASS）
- 研究对象：本地代码库 `//wsl.localhost/Ubuntu/home/johnny/work/plus-k8s/velero`（fork 自 velero-io/velero，dev 分支，HEAD `71374158a`，2026-11-11，v1.19 时代）
- 引用约定：仓库内文件统一映射为 `https://github.com/velero-io/velero/blob/main/<相对路径>`，相对路径均经本地实读核对

---

## [PART:toc] 目录（Phase 4 产出）

## 目录

- [引言](#引言)
- [1. 全库骨架与入口：cmd/ 三个 main、pkg/cmd/ 24 个子命令的角色切换及 pkg/ 与 internal/ 边界](#1-全库骨架与入口)
- [2. 工单与调度中心：config/crd、pkg/apis 的 13 种 CRD 与 pkg/controller 的 19 个 reconciler](#2-工单与调度中心)
- [3. 打包与拆包流水线：pkg/backup 与 pkg/restore 主流程、itemblock 并行及还原优先级](#3-打包与拆包流水线)
- [4. 两间仓库与外包接口：pkg/persistence、pkg/repository 的 Kopia 仓库与 pkg/plugin 的 go-plugin 机制](#4-两间仓库与外包接口)
- [5. 卷数据搬运队：pkg/podvolume 与 pkg/datamover 双通路、exposer/uploader/nodeagent 组件及 VGDP 独立 Pod](#5-卷数据搬运队)
- [结论](#结论)
- [参考文献](#参考文献)
- [待完善事项](#待完善事项)

---

## [PART:intro] 引言（Phase 4 产出）

Velero 是 Kubernetes 集群备份、恢复与迁移的常用工具，官方文档把它的形态讲得极简：集群里一个单副本 Deployment 服务端，加一个本地 CLI（[How Velero Works](https://velero.io/docs/main/how-velero-works/)）。可一旦克隆下代码库，「简单」两个字就站不住了：`pkg/` 下有 36 个一级子包、约 830 个 `.go` 文件，配置里躺着 13 种 CRD，`pkg/controller` 里排着 19 个 reconciler，根命令还一次挂出 24 个一级子命令（[ARCHITECTURE.md](https://github.com/velero-io/velero/blob/main/ARCHITECTURE.md)、[pkg/cmd/velero/velero.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/velero/velero.go)）。一个备份工具为什么要拆成这样？读代码的人又为什么容易迷路？

因为这座仓库同时叠了三件事。其一，**一个二进制，多重身份**：`cmd/` 里有 3 个 main，同一个可执行文件靠换子命令，就在笔记本、Deployment、DaemonSet、临时 Pod 和插件进程之间切换角色——5 个一级命令被隐藏（`server`、`run-plugins` 等），`node-agent` 反倒顶层可见。其二，**声明式工单**：13 种 CRD 是工单模板，19 个 reconciler 是值班调度员，且分 server 15 + node-agent 4 两处注册；CLI 创建备份的核心不过一次 `client.Create(...)`，打印 submitted 就能退出（[pkg/cmd/cli/backup/create.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/backup/create.go)）。其三，**控制面与数据面分离**：总装点只有一个 `pkg/cmd/server/server.go`，调度中心只管工单，重体力的卷数据搬运被交给独立 Pod（[pkg/cmd/server/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go)）。三条线一叠加，目录看着就像迷宫。

本报告基于 v1.19 时代（dev 分支，HEAD `71374158a`，2026-11-11）的真实代码，用「搬家公司」的类比把这座仓库从头逛一遍：先认骨架与入口，再看工单与调度，接着走打包/拆包流水线，然后清点两间仓库与外包插件接口，最后追到卷数据搬运队。目的不是背目录，而是弄清这些零件为什么非得这么摆。

---

## [PART:ch1] 第 1 章通过稿

### 1. 全库骨架与入口：一个二进制，四张工牌

**论点**：把 Velero 想成一家搬家公司。官方招牌只写两块——「门店前台」和「集群里的调度中心」：[README.md](https://github.com/velero-io/velero/blob/main/README.md) 说它由「一个跑在集群里的服务端 + 一个本地命令行客户端」组成，[ARCHITECTURE.md](https://github.com/velero-io/velero/blob/main/ARCHITECTURE.md) 补充服务端是「单副本 Deployment 里的一组控制器」。但代码显示，这家公司只招了**一个全能员工**（`velero` 可执行文件），给他备了 24 张工牌（子命令）：戴哪张干哪份活。看懂这一点，比记住任何目录名都重要。

#### 一、三个 main：一个主角，两个「门童」

`cmd/` 下只有三个 `main`。主角 [cmd/velero/velero.go](https://github.com/velero-io/velero/blob/main/cmd/velero/velero.go) 有效代码仅几行：取 `filepath.Base(os.Args[0])` 当命令名，再 `velero.NewCommand(baseName).Execute()` —— 它自己不干活，只把「接待台」支起来，能力全来自后面挂上的子命令。

另两个 helper 极简到近乎不像程序。[cmd/velero-helper/velero-helper.go](https://github.com/velero-io/velero/blob/main/cmd/velero-helper/velero-helper.go) 只认参数 `pause`，然后 `time.Sleep` 睡到几乎永远；VGDP 设计文档记载早期 exposer 正是用 `velero-helper pause` 撑住临时 backupPod/restorePod（[design/Implemented/vgdp-micro-service/vgdp-micro-service.md](https://github.com/velero-io/velero/blob/main/design/Implemented/vgdp-micro-service/vgdp-micro-service.md)）；当前代码已改由 `data-mover` / `pod-volume` 命令承担，详见第 5 章。[cmd/velero-restore-helper/velero-restore-helper.go](https://github.com/velero-io/velero/blob/main/cmd/velero-restore-helper/velero-restore-helper.go) 是「等签收的人」：每秒查 `/restores/*/.velero/<恢复 UID>` 的完成标记，全齐就删目录退出；它被作为 `restore-wait` 初始化容器注入用户 Pod，默认命令常量即 `/velero-restore-helper`（[pkg/restore/actions/pod_volume_restore_action.go](https://github.com/velero-io/velero/blob/main/pkg/restore/actions/pod_volume_restore_action.go)）。**可以理解为**：两个是要塞进别人 Pod 的占位员，不带 K8s 客户端和命令框架，越小越不和业务容器打架。

「发布给用户的」和「跑在集群里的」不是一回事：[.goreleaser.yml](https://github.com/velero-io/velero/blob/main/.goreleaser.yml) 只编译 `./cmd/velero/velero.go`，覆盖 linux/darwin/windows 多架构；[Dockerfile](https://github.com/velero-io/velero/blob/main/Dockerfile) 却一次 `go build` 出三个二进制并以非 root `cnb:cnb` 运行。两个 helper 从不单独发布，只随集群镜像进场。

#### 二、24 张工牌：一份花名册，三种身份

打开 [pkg/cmd/velero/velero.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/velero/velero.go)，`c.AddCommand(...)` 一口气挂了 24 个一级子命令，按「谁会去敲它」分三类：

- **用户命令（18 个）**：backup、schedule、restore、get、describe、create、delete、install、uninstall、version、plugin、client、completion、repo、bug、backup-location、snapshot-location、debug
- **集群常驻进程（2 个）**：`server`、`node-agent`
- **内部临时进程（4 个）**：`run-plugins`、`data-mover`、`pod-volume`、`repo-maintenance`

代码显示共 5 个一级命令设 `Hidden: true`：`server`（[pkg/cmd/server/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go)）、`run-plugins`（[pkg/cmd/server/plugin/plugin.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/plugin/plugin.go)，Short 直接写 "INTERNAL COMMAND ONLY"）、`data-mover`（[pkg/cmd/cli/datamover/data_mover.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/datamover/data_mover.go)）、`pod-volume`（[pkg/cmd/cli/podvolume/podvolume.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/podvolume/podvolume.go)）、`repo-maintenance`（[pkg/cmd/cli/repomantenance/maintenance.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/repomantenance/maintenance.go)）。值得注意的是，`node-agent` 顶层并不隐藏，它是可见的「Work with node-agent」（[pkg/cmd/cli/nodeagent/node_agent.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/nodeagent/node_agent.go)），隐藏的是其 `server` 子命令。

「同一个二进制换子命令换角色」在安装代码里有铁证：Deployment 容器参数是 `[]string{"server"}`（[pkg/install/deployment.go](https://github.com/velero-io/velero/blob/main/pkg/install/deployment.go)），node-agent DaemonSet 是 `[]string{"node-agent", "server"}`（[pkg/install/daemonset.go](https://github.com/velero-io/velero/blob/main/pkg/install/daemonset.go)）；VGDP 设计文档给出的临时搬运 Pod 命令是 `velero data-mover backup ...` / `velero data-mover restore ...`；`run-plugins` 则是被 go-plugin 框架拉起的子进程。同一个镜像、同一个可执行文件，靠 argv 第一个词就分身成调度中心、节点代理、临时搬运工、插件服务四种角色 —— **可以理解为同一个人换工牌，而非四套人马**。

顺带解释一个容易数错的点：`pkg/cmd/cli/` 有 23 个目录，根命令却是 24 个子命令。`serverstatus/` 只是被 `version`、`plugin get` 引用的查询辅助包，不挂根命令（[pkg/cmd/cli/serverstatus/server_status.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/serverstatus/server_status.go)）；根命令另从 `pkg/cmd/server/` 引入 `server` 和 `run-plugins`，22 + 2 = 24 正好对上。分工上，`pkg/cmd/cli/` 放「人用的命令族」，`pkg/cmd/server/` 放「集群常驻进程」的入口、配置与内置插件服务，两者被 `pkg/cmd/velero/velero.go` 挂到同一棵命令树。

#### 三、`velero server`：调度中心的开机自检清单

顺着 `server` 走进 [pkg/cmd/server/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go)。`newServer` 先备齐外部依赖：经 `client.Factory` 取 K8s 标准客户端、动态客户端、controller-runtime 客户端、聚合发现客户端和 rest.Config（[pkg/client/factory.go](https://github.com/velero-io/velero/blob/main/pkg/client/factory.go)）；`process.NewRegistry(...).DiscoverPlugins()` 扫描插件目录；组装含 Velero v1/v2alpha1、core、CSI snapshot 等多组 API 的 Scheme；创建 controller-runtime Manager 且把缓存限定在安装命名空间。

`run()` 像一份开机自检：确认命名空间存在 → 起发现助手并每 5 分钟刷新 → 检查 Velero CRD 是否齐全 → 检查 node-agent DaemonSet 在不在 → 初始化仓库管理器 → 注册 Prometheus 指标 → 把上次宕机时卡在 InProgress 的备份/恢复工单标为失败 → 最后 `runControllers()`。`runControllers()` 才是派单现场：起 `/metrics` 服务、造出插件管理器与对象存储取用器，按 `--disable-controllers` / `--restore-only` 过滤后逐个 `NewXxxReconciler(...).SetupWithManager(mgr)`，末了一句 `s.mgr.Start(s.ctx)` 把所有控制器一次性跑起来。值得注意的是，备份器和恢复器不是包里现成的单例，而是在这里现场装配、把发现助手、动态客户端、Pod 命令执行器、卷备份工厂、插件管理器一并注入给 reconciler —— **可以理解为调度中心开工前才给每个班组配齐工具**。官方文档描述的用户视角流程（`velero backup create` 只创建一个 `Backup` 对象、由 `BackupController` 干活）也与此吻合（[site/content/docs/main/how-velero-works.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/how-velero-works.md)、[How Velero Works](https://velero.io/docs/main/how-velero-works/)）。

#### 四、`pkg/` 36 个一级子包的分组地图

| 组别 | 包含的包 | 一句话职责 |
|---|---|---|
| 前台与接线 | `cmd`、`client`、`install` | 命令树、连 K8s 的工厂（[pkg/client/factory.go](https://github.com/velero-io/velero/blob/main/pkg/client/factory.go)）、把 CRD/RBAC/Deployment/DaemonSet 装进集群（[pkg/install/install.go](https://github.com/velero-io/velero/blob/main/pkg/install/install.go)） |
| 工单模板与字典 | `apis`、`constant`、`features`、`buildinfo`、`label`、`types` | CRD 的 Go 类型、常量、特性开关、版本信息、标签 |
| 调度中心 | `controller` | 19 个 reconciler 盯着工单干活（[pkg/controller/backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go)） |
| 打包与拆包 | `backup`、`restore`、`archive`、`kuberesource`、`discovery` | 资源打包 tar.gz、解包还原、资源发现与工具 |
| 外包接口 | `plugin` | go-plugin 框架、插件生命周期与内置动作插件 |
| 两间仓库 | `persistence`、`repository`、`kopia`、`uploader` | 资源 tar 包的对象存储、Kopia 统一仓库、上传/下载器 |
| 卷数据搬运队 | `podvolume`、`datamover`、`datapath`、`exposer`、`nodeagent`、`podexec`、`restorehelper`、`cbtservice` | 卷的暴露、搬运、节点代理与辅助容器 |
| 异步长任务进度 | `itemblock`、`itemoperation`、`itemoperationmap` | 并行工作池与长任务进度记账 |
| 资源改写与辅助 | `resourcemodifiers`、`metrics`、`builder`、`test`、`util` | 还原时改资源（[pkg/resourcemodifiers/resource_modifiers.go](https://github.com/velero-io/velero/blob/main/pkg/resourcemodifiers/resource_modifiers.go)）、指标、测试构造、通用工具 |

（36 个一级子包为本次本地清点，各组职责可在 [pkg/cmd/velero/velero.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/velero/velero.go) 与 [pkg/cmd/server/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go) 的 import 与装配关系中逐一核对）

#### 五、`pkg/` 与 `internal/`：营业区与后厨

Go 层面，`internal` 不是命名习惯而是编译器强制的可见性规则：官方规定「当 go 命令看到导入路径含 `internal` 的包时，会校验发起导入的代码是否位于以 `internal` 父目录为根的目录树内」（[Go 1.4 Internal packages](https://go.dev/doc/go1.4#internalpackages)）。本仓库 module 是 `github.com/velero-io/velero`（[go.mod](https://github.com/velero-io/velero/blob/main/go.mod)），故 `internal/` 下 9 个一级子包（credentials、delete、hook、resourcepolicies、restartabletest、storage、velero、volume、volumehelper）只能被本仓库代码使用；server 自己就大量引用，例如 [internal/credentials/getter.go](https://github.com/velero-io/velero/blob/main/internal/credentials/getter.go) 只是聚合 FileStore 与 SecretStore 的小结构。**可以理解为**：`pkg/` 是对外营业区的标准手册，`internal/` 是后厨配方，外人拿不到。

但这条边界并不固定。[changelogs/CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md) 明确写着 `Move internal/resourcemodifiers to pkg/resourcemodifiers for plugin reuse (#10759)` —— 动机白纸黑字是「供插件复用」：插件是独立进程/独立 module，想 import 就必须放到可导出的 `pkg/` 下，如今代码确实落在 [pkg/resourcemodifiers/resource_modifiers.go](https://github.com/velero-io/velero/blob/main/pkg/resourcemodifiers/resource_modifiers.go)。同一份 CHANGELOG 还记录 v1.19 破坏性变更「仓库与 module 路径从 `vmware-tanzu/velero` 改为 `velero-io/velero`」。两条合起来恰好说明：**这条边界由 import 路径决定，谁需要跨出去，谁就得搬家**。

#### 小结

代码显示的骨架是：一个 `velero` 二进制 + 两个极简 helper，靠 24 个子命令在笔记本、Deployment、DaemonSet、临时 Pod、插件进程之间切换身份；`pkg/cmd/server` 是唯一把 K8s 客户端、插件、仓库和 19 个控制器接起来的总装配点；`pkg/` 36 个包按「前台 / 工单 / 调度 / 打包 / 仓库 / 外包 / 搬运」排成一条搬家流水线，而 `internal/` 是编译器替团队守住的后厨。**可以理解为**：先看懂「一个人换工牌」，后面几章的所有目录都只是他手里不同的工具。

#### 本章速查

| 指标 | 数据 | 来源 |
|---|---|---|
| `cmd/` 下 main 数 | 3（velero / velero-helper / velero-restore-helper） | [cmd/velero/velero.go](https://github.com/velero-io/velero/blob/main/cmd/velero/velero.go)、[Dockerfile](https://github.com/velero-io/velero/blob/main/Dockerfile) |
| 根命令一级子命令 | 24（用户 18 / 常驻 2 / 内部 4） | [pkg/cmd/velero/velero.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/velero/velero.go) |
| 设为 Hidden 的一级命令 | 5（server / run-plugins / data-mover / pod-volume / repo-maintenance） | [pkg/cmd/server/plugin/plugin.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/plugin/plugin.go)、[pkg/cmd/cli/datamover/data_mover.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/datamover/data_mover.go) |
| `pkg/` 一级子包 / `internal/` 子包 | 36 / 9 | 本地清点 |
| Deployment / DaemonSet 启动参数 | `["server"]` / `["node-agent","server"]` | [pkg/install/deployment.go](https://github.com/velero-io/velero/blob/main/pkg/install/deployment.go)、[pkg/install/daemonset.go](https://github.com/velero-io/velero/blob/main/pkg/install/daemonset.go) |

---

## [PART:ch2] 第 2 章通过稿

### 2. 工单与调度中心：13 种 CRD 与 19 个 reconciler

第 1 章说清了「同一个二进制换子命令换角色」，本章回答：CLI 敲下回车后，活儿交给谁。Velero 的地基是**声明式**——官方文档写明，每一次按需备份、定时备份、恢复都是一个用 CRD 定义的自定义资源，存进 etcd，再由服务端的一组控制器认领并完成（[site/content/docs/main/how-velero-works.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/how-velero-works.md)、[ARCHITECTURE.md](https://github.com/velero-io/velero/blob/main/ARCHITECTURE.md)、[How Velero Works](https://velero.io/docs/main/how-velero-works/)）。

打个比方：CRD 是印好的**工单模板**，一个填好的 Backup 对象就是**一张工单**，etcd 是**工单柜**；控制器是**值班调度员**，盯着柜子里有没有新单、状态有没有变；CLI 只是**前台收件窗口**。代码是直白的证据：`CreateOptions.Run` 先 `BuildBackup` 组装对象，核心只有一句 `o.client.Create(context.TODO(), backup, ...)`，随后打印 `Backup request %q submitted successfully.`；即便加了 `--wait`，CLI 也只是另起一个 SharedInformer 订阅这张工单的 `Status.Phase`，遇到终态才返回，并明说「可以安全按 ctrl-c，备份会在后台继续」（[pkg/cmd/cli/backup/create.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/backup/create.go)）。

#### 论据一：柜子里有 13 种工单模板

按 `config/crd/` 的 bases 目录清点，v1 有 11 个、v2alpha1 有 2 个，合计 **13 种 CRD**，全部属于 `velero.io` 组、全部为 `Namespaced` 作用域。有个清点口径的坑：`pkg/apis/velero/v1/` 若只按 `*_types.go` 通配只能数到 9 个，因为 [pod_volume_restore_type.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v1/pod_volume_restore_type.go) 与 [volume_snapshot_location_type.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v1/volume_snapshot_location_type.go) 用的是单数 `type.go`；以 CRD 清单为准才不漏。

| 工单名称 | 版本 | 用它记录什么 |
|---|---|---|
| [Backup](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backups.yaml) | v1 | 一次备份：过滤条件、快照开关、TTL、存储位置、状态 |
| [Restore](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_restores.yaml) | v1 | 一次恢复：源备份、命名空间映射、还原策略 |
| [Schedule](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_schedules.yaml) | v1 | Cron 表达式，到点自动生成 Backup 工单 |
| [BackupStorageLocation](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backupstoragelocations.yaml) | v1 | 资源 tar 包存哪个对象存储桶、凭证、访问模式 |
| [VolumeSnapshotLocation](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_volumesnapshotlocations.yaml) | v1 | 云厂商卷快照存哪、provider 配置 |
| [BackupRepository](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backuprepositories.yaml) | v1 | Kopia 统一仓库的连接信息与维护状态 |
| [PodVolumeBackup](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_podvolumebackups.yaml) | v1 | 单个 Pod 卷的文件系统备份任务 |
| [PodVolumeRestore](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_podvolumerestores.yaml) | v1 | 单个 Pod 卷的恢复任务 |
| [DeleteBackupRequest](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_deletebackuprequests.yaml) | v1 | 删除一个或多个备份的异步请求单 |
| [DownloadRequest](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_downloadrequests.yaml) | v1 | 从对象存储取备份内容/日志的请求单 |
| [ServerStatusRequest](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_serverstatusrequests.yaml) | v1 | 查询服务端状态与插件清单的请求单 |
| [DataUpload](https://github.com/velero-io/velero/blob/main/config/crd/v2alpha1/bases/velero.io_datauploads.yaml) | v2alpha1 | 把快照数据搬进统一仓库的任务单 |
| [DataDownload](https://github.com/velero-io/velero/blob/main/config/crd/v2alpha1/bases/velero.io_datadownloads.yaml) | v2alpha1 | 从统一仓库把卷数据搬回目标卷的任务单 |

后两张是较新的卷数据搬运工单，版本仍标 alpha，与 v1 的成熟工单分开演进（[pkg/apis/velero/v2alpha1/data_upload_types.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v2alpha1/data_upload_types.go)、[data_download_types.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v2alpha1/data_download_types.go)）。

#### 论据二：Backup 工单怎么填、状态戳怎么盖

`BackupSpec` 就是填写栏（[pkg/apis/velero/v1/backup_types.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v1/backup_types.go)），按用途可归四类：**搬哪些房间**（IncludedNamespaces/ExcludedNamespaces、IncludedResources/ExcludedResources、四组 Cluster/NamespaceScopedResources 过滤、LabelSelector 与 OrLabelSelectors）；**大件怎么办**（SnapshotVolumes、SnapshotMoveData、DefaultVolumesToFsBackup、VolumeSnapshotLocations、DataMover、BackupType 的 Full/Incremental、UploaderConfig、CSISnapshotTimeout）；**存哪留多久**（StorageLocation、TTL）；**附加动作**（Hooks、OrderedResources、ResourcePolicy、ItemOperationTimeout、DryRun）。栏里还有一个标了 `Deprecated` 的 `DefaultVolumesToRestic`，注释要求改用 `DefaultVolumesToFsBackup`——v1.19 移除 Restic 的痕迹在类型定义里也看得见。

状态戳是 `BackupStatus.Phase`。常见的「New → InProgress → Completed」是简化版：代码里的 kubebuilder 枚举实际有 **13 个值**，CRD YAML 的 `phase.enum` 与之逐条一致（[velero.io_backups.yaml](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backups.yaml)）：除 New / FailedValidation / InProgress / Completed / PartiallyFailed / Failed / Deleting，还多了并发排队的 Queued、ReadyToStart，以及异步收尾的 WaitingForPluginOperations、Finalizing 及两者的 PartiallyFailed 变体。`BackupStatus` 还记 QueuePosition（排队名次）、Progress.TotalItems/ItemsBackedUp、各类计数与 ValidationErrors；`Backup` 上的 printcolumn 让 `kubectl get backup` 直接显示 Status/Errors/Warnings/Started 四列。

分这么细是有原因的：并发备份把「新建」与「可执行」拆开了。这套并发模型自 v1.18 引入（[changelogs/CHANGELOG-1.18.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.18.md)、[design/Implemented/concurrent-backup-processing.md](https://github.com/velero-io/velero/blob/main/design/Implemented/concurrent-backup-processing.md)）：`backupReconciler.SetupWithManager` 用 predicate 只放行 `Phase == ReadyToStart` 的 Update 事件，`CreateFunc` 直接返回 false，并设 `MaxConcurrentReconciles: b.concurrentBackups`（[pkg/controller/backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go)）；新单先由 `backupQueueReconciler` 置为 Queued 并写 QueuePosition，等并发额度够、且与运行中及排在前面的工单无命名空间重叠，才改成 ReadyToStart（[pkg/controller/backup_queue_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_queue_controller.go)）。

#### 论据三：19 个值班调度员，分两地上班

`pkg/controller/` 下 `*_controller.go` 共 **19 个**（非测试 `.go` 共 21 个，另两个是 `interface.go` 与 `backup_tracker.go`）。19 个全部实现 controller-runtime 的 `SetupWithManager(mgr ctrl.Manager) error`，注册却分两处：[pkg/cmd/server/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go) 装 15 个控制面控制器，[pkg/cmd/cli/nodeagent/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/nodeagent/server.go) 装 4 个卷数据控制器；后者正是第 5 章的 node-agent DaemonSet，15+4=19，正好印证控制面/数据面分离。

这里有一处**以代码为准的口径修正**：[pkg/controller/interface.go](https://github.com/velero-io/velero/blob/main/pkg/controller/interface.go) 确实定义了 `Interface{ Run(ctx context.Context, workers int) error }`，但检索全仓非测试代码，除定义本身没有任何引用，19 个 reconciler 也无一个实现 `Run`。所以它是当前未被使用的遗留接口，不宜当作现行调度抽象；现行统一契约是 `ctrl.NewControllerManagedBy(mgr).For(...).Complete(b)` 加 `Reconcile(ctx, req) (ctrl.Result, error)`（[backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go)）。（推测它属于更早的手写 informer 时代，此历史成因未在本次代码阅读中确证。）server.go 还有一层开关：控制器先过 `enabledRuntimeControllers` 白名单与 `removeControllers(...)`，代码里有一段会一次性把 backup、backup-deletion、backup-finalizer、backup-operations、gc、schedule 共 6 个加入禁用列表，最后 `s.mgr.Start(s.ctx)` 统一拉起。

| 控制器（均在 pkg/controller/） | 归类 | 谁注册 | 一句话职责 |
|---|---|---|---|
| [backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go) | 备份类 | server | 执行备份主线 |
| [backup_deletion_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_deletion_controller.go) | 备份类 | server | 处理删除请求 |
| [backup_finalizer_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_finalizer_controller.go) | 备份类 | server | 异步操作收尾 |
| [backup_operations_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_operations_controller.go) | 备份类 | server | 跟踪 BIA 异步操作 |
| [backup_queue_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_queue_controller.go) | 调度清理类 | server | 排队与叫号 |
| [restore_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/restore_controller.go) | 恢复类 | server | 执行恢复主线 |
| [restore_finalizer_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/restore_finalizer_controller.go) | 恢复类 | server | 恢复异步收尾 |
| [restore_operations_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/restore_operations_controller.go) | 恢复类 | server | 跟踪 RIA 异步操作 |
| [download_request_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/download_request_controller.go) | 恢复类 | server | 生成下载内容 |
| [backup_storage_location_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_storage_location_controller.go) | 存储仓库类 | server | 校验 BSL 可用 |
| [backup_repository_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_repository_controller.go) | 存储仓库类 | server | 仓库维护 |
| [backup_sync_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_sync_controller.go) | 存储仓库类 | server | 对象存储→etcd 同步 |
| [schedule_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/schedule_controller.go) | 调度清理类 | server | Cron 到点建 Backup |
| [gc_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/gc_controller.go) | 调度清理类 | server | 按 TTL 清理过期备份 |
| [server_status_request_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/server_status_request_controller.go) | 调度清理类 | server | 应答状态查询 |
| [pod_volume_backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/pod_volume_backup_controller.go) | 卷数据类 | node-agent | 单卷备份 |
| [pod_volume_restore_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/pod_volume_restore_controller.go) | 卷数据类 | node-agent | 单卷恢复 |
| [data_upload_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/data_upload_controller.go) | 卷数据类 | node-agent | 快照数据上传 |
| [data_download_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/data_download_controller.go) | 卷数据类 | node-agent | 卷数据下载 |

#### 分析：把一次备份的控制面链路串起来

① CLI 建 Backup 对象 POST 进 etcd 后即可退出（[pkg/cmd/cli/backup/create.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/backup/create.go)）；② 官方文档描述的四步——客户端建对象、BackupController 发现并校验、查 API server 收集资源、上传备份文件——正是这条链（[how-velero-works.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/how-velero-works.md)）；③ 队列控制器把 New 变 Queued 再变 ReadyToStart（[concurrent-backup-processing.md](https://github.com/velero-io/velero/blob/main/design/Implemented/concurrent-backup-processing.md)）；④ `Reconcile` 取对象、`prepareBackupRequest` 校验，用 `kubeutil.PatchResource` 把 Phase 改成 InProgress 并写 StartTimestamp，注释明确「patch 失败时工单仍是 New，可再次 reconcile」（[backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go)）；⑤ `runBackup` 建临时 tar 文件、取插件动作、用 `backupStore.BackupExists` 查重，再调 `b.backupper.BackupWithResolvers(...)` 把活交给 pkg/backup 引擎；⑥ 结果写回 Status.Phase 与各类计数，落盘对象存储，状态再 patch 回 etcd；过期由 gc_controller 按 TTL 清理、对象存储与 etcd 不一致时以对象存储为真相源同步。

**为什么备份不是一条命令跑到底，而是一张状态会变的工单？** 从代码能读出四点：**可观测**——状态、进度、错误数都写在工单上，`kubectl` 直接看得见；**可重试**——每次只认领特定 Phase，patch 失败或 server 重启都能从工单当前状态续办；**状态可持久**——工单在 etcd 而非某个进程内存里；**CLI 可退出**——前台只递单。代价是状态机变复杂（13 个 Phase、5 组控制器接力），这是换取可靠性的取舍（分析性判断）。

#### 小结

`config/crd` + `pkg/apis` 定义 13 种「工单模板」，`pkg/controller` 的 19 个 reconciler 分驻 server 与 node-agent 两处「值班」，靠 `Status.Phase` 这张状态戳接力把一张工单从 New 送到 Completed。理解了工单与调度，第 3 章的打包引擎与第 5 章的搬卷队就都有了挂载点。

#### 本章速查

| 指标 | 数据 | 来源 |
|---|---|---|
| CRD 总数 | 13（v1 11 + v2alpha1 2），全 `velero.io` / `Namespaced` | [config/crd/v1/bases/velero.io_backups.yaml](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backups.yaml) 等 13 个 bases 文件 |
| BackupPhase 枚举值 | 13 个 | [pkg/apis/velero/v1/backup_types.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v1/backup_types.go) |
| `*_controller.go` | 19 个（server 15 + node-agent 4） | [pkg/cmd/server/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go)、[pkg/cmd/cli/nodeagent/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/nodeagent/server.go) |
| 并发度开关 | `MaxConcurrentReconciles = concurrentBackups` | [pkg/controller/backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go) |
| 默认 TTL / GC 频率 | 30 天 / 每小时 | [site/content/docs/main/how-velero-works.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/how-velero-works.md) |

---

## [PART:ch3] 第 3 章通过稿

### 3. 打包与拆包流水线：备份是复制，恢复是谈判

**论点**：把 Velero 想成搬家公司，一次备份是「照清单把东西装箱、贴标签、封进一个 tar.gz 纸箱」，一次恢复是「把纸箱搬进一栋已经住了人、户型还可能不同的新房子，按依赖顺序一件件摆回去」。前半段只跟「读」打交道，后半段要跟一个活的集群协商——这就是两条流水线看似对称、实则不对称的根因。官方网页只给了用户视角的一句话流程（[How Velero Works](https://velero.io/docs/main/how-velero-works/)），真正的分工得看代码。

#### 一、备份：清单 → 装箱 → 贴标签

调度的手在 [pkg/controller/backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go)：`backupReconciler` 调 `b.backupper.BackupWithResolvers(...)`，把 `backupFileWriter`、插件解析器、pluginManager 一并递入。入口 [pkg/backup/backup.go](https://github.com/velero-io/velero/blob/main/pkg/backup/backup.go) 的 `BackupWithResolvers` 先架起 `gzip.NewWriter` + `tar.NewWriter` ——「先摆好纸箱和封箱胶带」，再写版本文件。

**列清单**：`getNamespaceIncludesExcludes` 与 `GetScopeResourceIncludesExcludes` 把 BackupSpec 的包含/排除规则算成过滤器，`getResourceHooks` 与 `ResolveActions` 备好 hooks 和 BIA/ItemBlockAction。随后 [pkg/backup/item_collector.go](https://github.com/velero-io/velero/blob/main/pkg/backup/item_collector.go) 的 `getAllItems()` 遍历 `discoveryHelper.Resources()` 的每个 API 组，用 `dynamicFactory` 动态客户端 `List/Get`，把对象 JSON 暂写临时目录。规则都写在代码里：core 组由 `sortCoreGroup` 强制按 pods → pvcs → pvs → 其他排序；`ShouldInclude(gr.String())` 定某类要不要登记；`cohabitatingResources` 去掉同名资源在多 API 组的重复；`LabelSelector`/`OrLabelSelectors` 经 `listResourceByLabelsPerNamespace` 下发。集群级/命名空间级不是开关，而是落到归档路径：[pkg/archive/filesystem.go](https://github.com/velero-io/velero/blob/main/pkg/archive/filesystem.go) 的 `GetScopeDir` 规定 namespace 为空走 `cluster/`、非空走 `namespaces/<ns>/`。用户还可用 `OrderedResources` 指定顺序（[design/Implemented/backup-resources-order.md](https://github.com/velero-io/velero/blob/main/design/Implemented/backup-resources-order.md)），`item_collector.go` 的 `sortResourcesByOrder` 给排前的对象打 `orderedResource=true`——这正是后面「装箱分块」的依据。

**逐件装箱**：[pkg/backup/item_backupper.go](https://github.com/velero-io/velero/blob/main/pkg/backup/item_backupper.go) 的 `backupItem` 先 `itemInclusionChecks` 剔除带 `velero.io/exclude-from-backup` 标签、正在删除的对象并**重查**过滤，`BackedUpItems` 去重；`executeActions` 依次跑匹配的 BIA（可改写对象、返回 `additionalItems` 与 `operationID`）；最后 `json.Marshal`、由 `archive.GetVersionedItemFilePath` 定箱内位置，**加锁**写入 tar。附加依赖在此补齐：[pkg/backup/actions/backup_pv_action.go](https://github.com/velero-io/velero/blob/main/pkg/backup/actions/backup_pv_action.go) 的 PVCAction 从 PVC 的 `Spec.VolumeName` 找出 PV 返回，`executeActions` 先在同一 ItemBlock 内 `FindItem`，找不到才用动态客户端回集群取并递归 `backupItem`。Pod 的 pre/post hooks 在 backup.go 按块执行，post hook 须 `waitUntilPVBsProcessed` 等卷备份完成。

**贴标签、封箱、入库**：异步 BIA 完成后 `FinalizeBackup` 把 tar.gz 重新解开，把 `PostOperationItems` 补采进包，`buildFinalTarball` 合并更新；控制器 `persistBackup` 把 tar 包、`velero-backup.json`、日志与 warnings/errors 写入 BackupStore。[site/content/docs/main/output-file-format.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/output-file-format.md) 印证：备份即 gzip 压缩的 tar，桶里另存一份 `velero-backup.json`。

#### 二、装箱怎么并行、长任务怎么记进度

「箱」在代码里叫 ItemBlock：[pkg/itemblock/itemblock.go](https://github.com/velero-io/velero/blob/main/pkg/itemblock/itemblock.go) 中它只是一组 `ItemBlockItem`（GR + Unstructured + PreferredGVR），`FindItem` 按 GR/命名空间/名字查重；[pkg/backup/itemblock.go](https://github.com/velero-io/velero/blob/main/pkg/backup/itemblock.go) 的 `addKubernetesResource` 从临时 JSON 读回对象、再跑一遍过滤后装块。`BackupWithResolvers` 按清单攒块，规则很生活化：**只有「当前与下一件都是 orderedResource 且同类资源」才继续塞进同一箱**，否则封箱投递到 `WorkerPool.GetInputChannel()`。[pkg/backup/item_block_worker_pool.go](https://github.com/velero-io/velero/blob/main/pkg/backup/item_block_worker_pool.go) 用固定 goroutine 守着缓冲 `max(workers,10)` 的 channel，每工人调 `backupItemBlock`，后者跑 pre hooks → 逐件 `backupItem` → post hooks。回程由另一 goroutine 经 `itemBlockReturn` 收，每秒把 `status.progress` patch 回 Backup CR。

「一备份一池」是 v1.18 之后才成立的。[design/Implemented/concurrent-backup-processing.md](https://github.com/velero-io/velero/blob/main/design/Implemented/concurrent-backup-processing.md) 说明：新增 `Queued`/`ReadyToStart` 两个 phase 与 `QueuePosition`，新增 `backupQueueReconciler` 排队，`backupReconciler` 改为只认 `ReadyToStart` 并以 `MaxConcurrentReconciles: concurrentBackups` 并发，worker pool 从「控制器启动时一份」挪到「每次 reconcile 一份」，全 Pod 最大线程数变为 `itemBlockWorkerCount × concurrentBackups`；为避免同一工作负载被两个备份同时动，首版用**命名空间重叠检测**兜底。

「贴标签」的另一层是长任务进度：[pkg/itemoperation/shared.go](https://github.com/velero-io/velero/blob/main/pkg/itemoperation/shared.go) 的 `OperationStatus` 有 New/InProgress/Completed/Failed 四态，[pkg/itemoperation/backup_operation.go](https://github.com/velero-io/velero/blob/main/pkg/itemoperation/backup_operation.go) 记录 BIA 名、`OperationID`、`PostOperationItems`，[pkg/itemoperationmap/backup_operation_map.go](https://github.com/velero-io/velero/blob/main/pkg/itemoperationmap/backup_operation_map.go) 用带互斥锁的 map 缓存并 `encode.ToJSONGzip` → `PutBackupItemOperations` 把进度**写进对象存储**。控制器据此把 phase 置为 `WaitingForPluginOperations`。源头见 [design/Implemented/biav2-design.md](https://github.com/velero-io/velero/blob/main/design/Implemented/biav2-design.md)：BIA v2 的 `Execute` 允许返回 `operationID` 把长任务丢后台，并新增 `Progress`/`Cancel` 两个 RPC。

#### 三、恢复：拆箱时按依赖顺序摆放

[pkg/restore/restore.go](https://github.com/velero-io/velero/blob/main/pkg/restore/restore.go) 的 `RestoreWithResolvers` 先算好选择器、包含排除、资源策略、RIA v2 动作、hooks 执行器与 `pvRestorer`，再进 `execute()`。拆箱第一步 `UnzipAndExtractBackup`（[pkg/archive/extractor.go](https://github.com/velero-io/velero/blob/main/pkg/archive/extractor.go)，gzip→tar 解到临时目录），第二步 `Parser.Parse`（[pkg/archive/parser.go](https://github.com/velero-io/velero/blob/main/pkg/archive/parser.go)）把目录还原成 `map[groupResource]*ResourceItems`，`ItemsByNamespace` 用空串表示集群级。

顺序是恢复与备份最大的不同：`execute` 先**单独**还原 CRD（硬编码 `HighPriorities: []string{"customresourcedefinitions"}`），再 `discoveryHelper.Refresh()`，才用 `getOrderedResourceCollection` 处理其余——CRD 没先建好，集群根本无法解析自定义资源。`getOrderedResources` 把高优先级放最前、其余按字母序居中、低优先级垫底；默认表在 [pkg/cmd/server/config/config.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/config/config.go)（23 项高优先、5 项低优先），[site/content/docs/main/restore-reference.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/restore-reference.md) 给出同一清单并说明可用 `--restore-resource-priorities` 覆盖。

具体一件怎么摆看 `restoreItem`：用**对象原始**命名空间做过滤，`EnsureNamespaceExistsAndIsReady` 保证目标命名空间存在，`isCompleted` 跳过已完成对象，`restoredItems` 去重，mirror pod 直接跳过；随后跑 RIA v2（同时传入 `Item` 与 `ItemFromBackup`，亦可返回 `OperationID`）、应用资源修饰符、把命名空间改写为映射值、`addRestoreLabels`。辅助包各司其职：[pkg/kuberesource/kuberesource.go](https://github.com/velero-io/velero/blob/main/pkg/kuberesource/kuberesource.go) 是「资源常量表」；[pkg/resourcemodifiers/resource_modifiers.go](https://github.com/velero-io/velero/blob/main/pkg/resourcemodifiers/resource_modifiers.go) 从 ConfigMap 读规则，按命名空间、groupResource glob、名称正则、LabelSelector 匹配后打 JSONPatch/JSONMergePatch/StrategicMergePatch；[pkg/restorehelper/util.go](https://github.com/velero-io/velero/blob/main/pkg/restorehelper/util.go) 定义 `restore-wait` init container，[pkg/restore/actions/init_restorehook_pod_action.go](https://github.com/velero-io/velero/blob/main/pkg/restore/actions/init_restorehook_pod_action.go) 据此在还原 Pod 前插入该容器挂住卷数据；[pkg/restore/pv_restorer.go](https://github.com/velero-io/velero/blob/main/pkg/restore/pv_restorer.go) 调快照插件 `CreateVolumeFromSnapshot` 把 PV 接回云盘；[pkg/restore/prioritize_group_version.go](https://github.com/velero-io/velero/blob/main/pkg/restore/prioritize_group_version.go) 按「用户指定 → 目标集群首选 → 源集群首选 → 共同最高 K8s 版本优先级」挑 API 版本。

#### 四、分析：为什么恢复比备份难

笔者的判断是，这不是实现偷懒，而是问题性质不同。备份面对只读快照，代码几乎只需「过滤 → 序列化 → 写入」；恢复面对**可能已经住了人、且户型不同**的活集群，因此多出四层备份侧完全没有的东西：

1. **已存在资源**——官方默认非破坏性（[restore-reference.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/restore-reference.md)），`restoreItem` 发现同名且内容不同即跳过并记 warning，ServiceAccount 是例外、走字段合并，仅 `--existing-resource-policy=update` 才 best-effort patch；
2. **排序是刚需而非可选**——备份侧只有可选 `OrderedResources` 与 core 组固定顺序；恢复侧必须先 CRD、再刷 discovery、再按 23 项默认优先级；
3. **目标适配**——资源修饰符、命名空间映射、PV 重命名与 claimRef 重写、API 版本协商、restore hooks 的 init container 全只在恢复侧；
4. **原地恢复要动现有对象**——[pkg/restore/inplace/preflight.go](https://github.com/velero-io/velero/blob/main/pkg/restore/inplace/preflight.go) 的 `CheckPVCNotInUse` 在碰现有 PVC/PV 之前先查有没有 Pod 占用；备份永不修改源集群。

#### 小结

一条备份是「清单（item_collector）→ 分块（itemblock）→ 并行装箱（worker pool + item_backupper）→ 封箱入库（gzip/tar + persistBackup）」，进度靠 `status.progress` 与 item operations 进度牌；一条恢复是「解包（extractor + parser）→ 先 CRD 后其余的依赖顺序摆放（priorities）→ 逐件协商（RIA v2 / 修饰符 / 已存在策略 / PV 修正 / hooks）」。同一套 tar.gz，装的时候是复制，摆的时候是谈判。

#### 本章速查

| 指标 | 数据 | 来源 |
|---|---|---|
| 默认恢复高/低优先级资源 | 23 类 / 5 类 | [pkg/cmd/server/config/config.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/config/config.go) |
| ItemBlock 输入 channel 缓冲 | `max(workers, 10)` | [pkg/backup/item_block_worker_pool.go](https://github.com/velero-io/velero/blob/main/pkg/backup/item_block_worker_pool.go) |
| 全 Pod 最大 ItemBlock 线程数 | `itemBlockWorkerCount × concurrentBackups` | [design/Implemented/concurrent-backup-processing.md](https://github.com/velero-io/velero/blob/main/design/Implemented/concurrent-backup-processing.md) |
| 长任务状态机 | New / InProgress / Completed / Failed 四态 | [pkg/itemoperation/shared.go](https://github.com/velero-io/velero/blob/main/pkg/itemoperation/shared.go) |
| 备份产物格式 | gzip 压缩 tar + `velero-backup.json` | [site/content/docs/main/output-file-format.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/output-file-format.md) |

---

## [PART:ch4] 第 4 章通过稿

### 4. 两间仓库与外包接口：档案柜、Kopia 仓库与标准插座

第 3 章讲清了「怎么打包、怎么拆包」，本章只回答两件事：**东西最终存在哪、外部能力怎么接进来**。代码给出的答案是三条边界——`pkg/persistence` 管档案、`pkg/repository` 与 `pkg/uploader` 管大件、`pkg/plugin` 管「谁来干」。共同点是三处都没把能力写死在主流程里，而是各留了一层可替换接口。

#### 论据一：第一间仓库是「档案柜 + 地址条」

打开 [pkg/persistence/object_store.go](https://github.com/velero-io/velero/blob/main/pkg/persistence/object_store.go)，`BackupStore` 接口列了 28 个方法，`BackupInfo` 带 10 个 `io.Reader`：备份 tar 包、`velero-backup.json` 元数据、日志、results、PodVolumeBackups、VolumeSnapshots、ItemOperations、资源清单、CSI 快照类、卷信息；恢复侧另有日志、结果、已恢复资源清单、卷信息。`PutBackup` 一次写入 9 个对象，其中日志上传是尽力而为、元数据失败即中止、tar 包失败要回滚删元数据。`GetDownloadURL` 覆盖 14 种目标，签名 URL 有效期 `DownloadURLTTL = 10 * time.Minute`。文件名规则集中在 [pkg/persistence/object_store_layout.go](https://github.com/velero-io/velero/blob/main/pkg/persistence/object_store_layout.go)：根前缀下分 `backups/`、`restores/`、`metadata/`、`plugins/`、`kopia/`（及历史 `restic/`）六个一级目录，一次备份落在 `<prefix>/backups/<name>/`，含 `velero-backup.json`、`<name>.tar.gz`、`<name>-logs.gz`、`<name>-results.gz`、`<name>-volumeinfo.json.gz` 等。官方文档 [site/content/docs/main/output-file-format.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/output-file-format.md) 只画了简化示意，并说明 tar 内是 `resources/<资源类型>/namespaces/...` 的 JSON 目录树；代码清单明显更全，这正是「以代码为准」的差别。

「存哪个桶」写在 [config/crd/v1/bases/velero.io_backupstoragelocations.yaml](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backupstoragelocations.yaml)：`spec` 必填 `provider` 与 `objectStorage`（其 `bucket` 必填、`prefix` 可选），另有 `credential`、`config`、`default`、`accessMode`、`validationFrequency`，`status.phase` 仅 `Available`/`Unavailable`。`objectBackupStoreGetter.Get()` 从 BSL 取 bucket/prefix 去 `Init` ObjectStore 插件，并会处理用户传入的 `credentialsFile`；[changelogs/CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md) 已把凭证改走 Secret 引用列为破坏性变更。生活化地说：BSL 是档案柜的「地址条」，`ObjectStoreLayout` 是格子编号规则。

#### 论据二：第二间仓库是「带去重的大件仓库」

为什么不把卷数据也塞进上间柜子？设计文档 [design/Implemented/unified-repo-and-kopia-integration/unified-repo-and-kopia-integration.md](https://github.com/velero-io/velero/blob/main/design/Implemented/unified-repo-and-kopia-integration/unified-repo-and-kopia-integration.md) 给出权威区分：**Backup Storage** 是用户提供的对象存储/文件系统，「不属于 BR 方案本身，通常不提供备份相关能力」；**Backup Repository** 是 Velero 自带、夹在 data mover 与 storage 之间的一层，负责去重、压缩、静态加密、快照管理与增量数据的统一组织。文档明确批评 Restic 时代「data mover 与仓库是不可分割的整体，无法把仓库能力给其他 mover 复用、也无法扩展」，并称 Kopia 模块划分更清晰、性能更好，故改用它。一句话：第一间仓库原样保存「文件」，第二间仓库要理解「内容」。

三层分工均以代码为准：[pkg/repository/provider/provider.go](https://github.com/velero-io/velero/blob/main/pkg/repository/provider/provider.go) 的 `Provider` 接口是「仓库管理员」，方法为 `InitRepo`/`ConnectToRepo`/`PrepareRepo`/`BoostRepoConnect`/`PruneRepo`/`Forget`；[pkg/repository/provider/unified_repo.go](https://github.com/velero-io/velero/blob/main/pkg/repository/provider/unified_repo.go) 是统一仓库实现，其 `RepoParam` 同时握住 `*BackupStorageLocation` 与 `*BackupRepository`，且把前缀拼成 `path.Join(prefix, repoBackend, repoName) + "/"`——说明第二间仓库**复用同一个桶**，只在下面开自己的子目录；后端由 [pkg/repository/udmrepo/service/service.go](https://github.com/velero-io/velero/blob/main/pkg/repository/udmrepo/service/service.go) 的 `Create()` 无条件 `return kopialib.NewKopiaRepoService(logger)`，无任何分支。[pkg/uploader/provider/provider.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/provider/provider.go) 的 `Provider` 只有 `RunBackup`/`RunRestore`/`Close`，按 `uploaderType` 只分 `kopia` 与 `velero-block`。**需要纠偏的是** [pkg/kopia/kopia_log.go](https://github.com/velero-io/velero/blob/main/pkg/kopia/kopia_log.go)：`pkg/kopia/` 主要是把 Kopia 日志桥接到 logrus/zap 的适配文件，并非仓库核心，真正的 Kopia 库适配在 `udmrepo/kopialib` 包中。

台账是 [config/crd/v1/bases/velero.io_backuprepositories.yaml](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backuprepositories.yaml)：`spec` 记 `backupStorageLocation`、`repositoryType`、`volumeNamespace`、`maintenanceFrequency`、`repositoryConfig`，`status.phase` 为 `New`/`Ready`/`NotReady`。v1.19 移除 Restic 有硬证据：[CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md)「Restic removal」写明「completely removed in 1.19」，而 [changelogs/CHANGELOG-1.15.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.15.md)「Deprecation of Restic」显示弃用自 1.15 开始；代码侧 `NewUploaderProvider` 的 switch 无 restic 分支、[pkg/uploader/types.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/types.go) 常量只有 `kopia`/`velero-block`、service 只造 Kopia。**但要精确**：BackupRepository CRD 的 `repositoryType` enum 仍留 `restic` 与标为 Deprecated 的 `resticIdentifier`，`object_store_layout.go` 也仍保留 `restic/` 子目录——移除的是数据面实现，兼容痕迹尚在。CHANGELOG-1.19 另记新仓库哈希算法由 `BLAKE2B-256-128` 改为 `HMAC-SHA256-128`（存量仓库不变）。

#### 论据三：外包接口是「标准插座 + 外包供应商」

插件不是库，是**独立进程**。[pkg/plugin/framework/handshake.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/framework/handshake.go) 定义 `ProtocolVersion: 2` 与魔法 cookie `VELERO_PLUGIN=hello`「对暗号」，注释写明协议不兼容变动时必须 bump；[pkg/plugin/framework/server.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/framework/server.go) 的 `Serve()` 调 `plugin.Serve(...)` 并设 `GRPCServer: plugin.DefaultGRPCServer`。[pkg/plugin/clientmgmt/process/process.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/clientmgmt/process/process.go) 注释直接写「creates a new go-plugin Client that has its own unique exec.Cmd for launching the plugin process」，`dispense()` 取回的是「a gRPC-based client」。上游 [hashicorp/go-plugin](https://github.com/hashicorp/go-plugin) 亦确认插件以子进程运行、只设计为走本机可靠网络，且「A panic in a plugin doesn't panic the plugin user」。

发现与重启由三处协作：[pkg/plugin/clientmgmt/process/registry.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/clientmgmt/process/registry.go) 的 `DiscoverPlugins()` 先把 `os.Args[0]`（Velero 自身二进制）加入命令表，再扫描插件目录发现可执行文件，逐个询问 `PluginLister` 列出自己提供什么；[pkg/plugin/clientmgmt/manager.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/clientmgmt/manager.go) 按 `(kind, name)` 查注册表、以 `info.Command` 为键缓存进程；[pkg/plugin/clientmgmt/process/restartable_process.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/clientmgmt/process/restartable_process.go) 的 `ResetIfNeeded()` 检测到 `exited()` 即自动重启，`resetLH()` 重新 dispense 并 `Reinitialize` 全部已注册插件，连续失败超过 10 次才报错。

[pkg/plugin/framework/common/plugin_kinds.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/framework/common/plugin_kinds.go) 定义了 9 个 `PluginKind` 常量，但 `AllPluginKinds()` 只暴露 8 类给插件作者（第 9 类 `PluginLister` 由框架内部使用）：

| # | PluginKind | 职责 |
|---|---|---|
| 1 | ObjectStore | 对象桶读写，第一间仓库的底层驱动 |
| 2 | VolumeSnapshotter | 云盘快照 |
| 3 | BackupItemAction | 备份单个资源时改写（v1，同步） |
| 4 | BackupItemActionV2 | 同上，v2 支持异步长任务 |
| 5 | RestoreItemAction | 恢复单个资源时改写（v1） |
| 6 | RestoreItemActionV2 | 同上，v2 |
| 7 | DeleteItemAction | 删除备份时联动清理外部资源 |
| 8 | ItemBlockAction | 参与第 3 章的「分块」决策 |

v1 与 v2 的差别见 [design/Implemented/biav2-design.md](https://github.com/velero-io/velero/blob/main/design/Implemented/biav2-design.md)：为支持「`Execute()` 返回后仍在后台跑」的长任务，v2 的 `ExecuteResponse` 多出 `operationID`，服务新增 `Progress`、`Cancel` 两个 RPC；文档同时说明会写 v1 适配器，使老插件返回空 operationID、新方法做 no-op。`manager.go` 里 `GetBackupItemActions()` 与 `GetBackupItemActionsV2()` 并存、`PluginKindsAdaptableTo` 把 v1 映射到 v2，正是这套兼容策略的落地。

有意思的是，Velero 连自家动作也走这套插座：[pkg/cmd/server/plugin/plugin.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/plugin/plugin.go) 的 `run-plugins` 是 `Hidden: true` 的一级隐藏命令，一口气注册 34 个内置动作插件（BIA v1 3 个 + 1 个受 APIGroupVersions 特性开关控制、RIA v1 17 个、DeleteItemAction 2 个、BIA v2 4 个、RIA v2 4 个、ItemBlockAction 3 个）。第三方怎么装？[site/content/docs/main/overview-plugins.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/overview-plugins.md) 写明安装时至少要用 `--plugins` 加一个 ObjectStore 或 VolumeSnapshotter 插件，装完可用 `velero plugin add/remove <registry/image:version>` 增删，「无需修改 Velero 代码库」。

#### 分析：为什么这么分

**事实层面**可见的收益：崩溃隔离（子进程 + 自动重启）、第三方云厂商独立接入、协议版本可演进（handshake + v1→v2 适配器）、仓库后端可替换（`udmrepo.BackupRepoService` 抽象 + service.go 单点构造）。**代价同样写在代码里**：每次调用要跨进程 gRPC 序列化、协议版本必须严格匹配、v1/v2 双份接口与适配器长期并存、进程生命周期要 registry + restartable process + `CleanupClients()` 三处维护，连内置动作都要多起一个隐藏命令进程。**笔者的判断是（观点）**：把稳定主流程放进程内、把易变的外部设备放进程外，是用一点通信开销换取故障边界与生态扩展，对备份工具划算；但 v1/v2 并存也确实让 `pkg/plugin/clientmgmt` 成为全库最绕的一层。

| 维度 | 第一间（pkg/persistence） | 第二间（pkg/repository + pkg/uploader） |
|---|---|---|
| 存什么 | 资源 JSON、tar.gz、日志、结果、各类清单 | 卷数据（文件/块），带快照、去重、增量 |
| 谁提供 | 用户 bucket，BSL CRD 描述 | Velero 自建仓库，BackupRepository CRD 描述 |
| 桶中落位 | `<prefix>/backups/<name>/...` | **同桶** `<prefix>/<repoBackend>/<repoName>/` |
| 后端 | ObjectStore 插件 | Kopia（udmrepo/kopialib）+ kopia/velero-block uploader |
| 核心接口 | `BackupStore` | repo `Provider` / uploader `Provider` |

#### 小结

第 3 章「打包完的箱子」于是有了去处：清单与元数据进第一间档案柜，卷内容进第二间带去重的仓库，而两间柜子的钥匙（对象存储、卷快照）都通过 `pkg/plugin` 这排标准插座交给外包供应商。下一章顺着第二间仓库往下走，看 DataUpload/DataDownload 与 node-agent 组成的「卷数据搬运队」如何把字节真正送进去。

#### 本章速查

| 指标 | 数据 | 来源 |
|---|---|---|
| `BackupStore` 接口方法 / `BackupInfo` 的 io.Reader | 28 / 10 | [pkg/persistence/object_store.go](https://github.com/velero-io/velero/blob/main/pkg/persistence/object_store.go) |
| `GetDownloadURL` 目标种类 / 签名 URL 有效期 | 14 种 / 10 分钟 | 同上 |
| `ObjectStoreLayout` 一级子目录 | 6 个 | [pkg/persistence/object_store_layout.go](https://github.com/velero-io/velero/blob/main/pkg/persistence/object_store_layout.go) |
| go-plugin 握手 | `ProtocolVersion: 2`、`VELERO_PLUGIN=hello`、gRPC | [pkg/plugin/framework/handshake.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/framework/handshake.go) |
| `AllPluginKinds()` / 常量总数 | 8 / 9（差额 `PluginLister`） | [plugin_kinds.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/framework/common/plugin_kinds.go) |
| `run-plugins` 内置插件注册数 | 34 | [pkg/cmd/server/plugin/plugin.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/plugin/plugin.go) |
| uploader 合法类型 | `kopia`、`velero-block` | [pkg/uploader/types.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/types.go) |

---

## [PART:ch5] 第 5 章通过稿

### 5. 卷数据搬运队：第 4 章讲「存哪」，本章讲「怎么搬」

第 4 章交代了两间仓库和外包接口，本章只回答一件事：磁盘上的字节怎么被搬到仓库门口。K8s 资源是 etcd 里的 JSON，能整包打成 tar.gz；PV 里的数据却散落在节点磁盘、云盘或 CSI 快照上，既读不进 API Server，也塞不进 tar 包。所以仓库根的架构说明把分工写得很直白：卷数据由内置 file-system backup 与 data mover 搬运，对象存储与卷快照操作则交给 provider 插件（[ARCHITECTURE.md](https://github.com/velero-io/velero/blob/main/ARCHITECTURE.md)、[site/content/docs/main/file-system-backup.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/file-system-backup.md)）。这就是「控制面递单、数据面搬货」的分界。

用搬家打比方：**临时搭个中转棚** → **叉车**把货叉起 → **专车**拉走 → 进**仓库**。四段各自落到真实代码：中转棚是 [pkg/exposer/types.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/types.go) 与 [pkg/exposer/csi_snapshot.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/csi_snapshot.go)；叉车是 [pkg/uploader/provider/provider.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/provider/provider.go) 的 `RunBackup/RunRestore`；专车是 [pkg/exposer/pod_volume.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/pod_volume.go) 与 [pkg/cmd/cli/datamover/backup.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/datamover/backup.go) 启动的 VGDP 独立 Pod；仓库只在第 4 章展开，本章仅在 [pkg/datamover/backup_micro_service.go](https://github.com/velero-io/velero/blob/main/pkg/datamover/backup_micro_service.go) 里看到 `RepositoryType` 被固定为 `BackupRepositoryTypeKopia`。

#### 论据一：通路 A，文件系统备份（PodVolumeBackup）

这条通路读的是**正在被 Pod 挂载的活动文件系统**。官方文档写明它用 Kopia 模块搬数据，代价是数据不是同一时刻的快照、且 node-agent 常需 root/特权模式，因为它从宿主机 hostPath 读卷（[site/content/docs/main/file-system-backup.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/file-system-backup.md)）。代码把这条路走得很具体：[pkg/exposer/host_path.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/host_path.go) 按 Pod UID 拼出 `/host_pods/<uid>/volumes|volumeDevices/...` 路径，交回一个 `datapath.AccessPoint`；[pkg/controller/pod_volume_backup_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/pod_volume_backup_controller.go) 用 `exposer.NewPodVolumeExposer` 建临时 Pod；备份主控 [pkg/podvolume/backupper.go](https://github.com/velero-io/velero/blob/main/pkg/podvolume/backupper.go) 逐个卷递出 PVB 工单并 `WaitAllPodVolumesProcessed`（对应第 3 章 post hook 的等待）。DaemonSet 侧的 `host-pods` 卷与 `MountPropagationHostToContainer` 由 [pkg/install/daemonset.go](https://github.com/velero-io/velero/blob/main/pkg/install/daemonset.go) 装配，[pkg/nodeagent/node_agent.go](https://github.com/velero-io/velero/blob/main/pkg/nodeagent/node_agent.go) 定义 `host-pods` 常量与 Linux/Windows 两套 DaemonSet 名。

恢复时有个「先别启动」的问题：PVC 已建好但卷数据还没落地，业务容器不能抢跑。[pkg/restorehelper/util.go](https://github.com/velero-io/velero/blob/main/pkg/restorehelper/util.go) 定义 initContainer 名 `restore-wait`（并兼容旧名 `restic-wait`），[pkg/restore/actions/pod_volume_restore_action.go](https://github.com/velero-io/velero/blob/main/pkg/restore/actions/pod_volume_restore_action.go) 把它插到 initContainers 最前面、命令指向 `/velero-restore-helper`，而 [cmd/velero-restore-helper/velero-restore-helper.go](https://github.com/velero-io/velero/blob/main/cmd/velero-restore-helper/velero-restore-helper.go) 每秒轮询 `/restores/<卷>/.velero/<restore UID>` 完成标记——这正是第 1 章两个 helper 的落点之一。

历史上这条路走 Restic：统一仓库设计文档写明「当时用 Restic 搬 PV 文件、并保留 legacy Restic 路径以兼容旧备份」（[design/Implemented/unified-repo-and-kopia-integration/unified-repo-and-kopia-integration.md](https://github.com/velero-io/velero/blob/main/design/Implemented/unified-repo-and-kopia-integration/unified-repo-and-kopia-integration.md)）。代码现状是 Kopia：uploader 类型校验只接受 `kopia` 与 `block`（[pkg/uploader/types.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/types.go)），v1.19 的 Breaking Changes 明确「fs-backup 的 Restic 路径完全移除」（[changelogs/CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md)）。

#### 论据二：通路 B，CSI 快照数据移动（DataUpload / DataDownload）

设计文档把这条链定义为「Velero → BIA/RIA V2 → Data Mover Plugin → DUCR/DDCR → 内置 data mover」，其中 DUCR/DDCR 即 DataUpload/DataDownload 这两种 CR 工单；BIA V2 的 `Execute` 返回 `operationID` 后备份进入 `WaitingForPluginOperations`，由 `Progress` 轮询到完成（[design/Implemented/volume-snapshot-data-movement/volume-snapshot-data-movement.md](https://github.com/velero-io/velero/blob/main/design/Implemented/volume-snapshot-data-movement/volume-snapshot-data-movement.md)）。工单本身是 v2alpha1 CRD：[pkg/apis/velero/v2alpha1/data_upload_types.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v2alpha1/data_upload_types.go) 的 `DataUploadSpec` 带 `snapshotType`、`csiSnapshot`、`sourcePVC`、`datamover`、`parentSnapshot`，状态机 8 个枚举（New/Accepted/Prepared/InProgress/Canceling/Canceled/Completed/Failed），CRD 清单见 [config/crd/v2alpha1/bases/velero.io_datauploads.yaml](https://github.com/velero-io/velero/blob/main/config/crd/v2alpha1/bases/velero.io_datauploads.yaml)。

数据怎么被「摆到能下手的位置」？[pkg/controller/data_upload_controller.go](https://github.com/velero-io/velero/blob/main/pkg/controller/data_upload_controller.go) 用 `NewCSISnapshotExposer` 调 `Expose()` 建 backupPod，再 `GetExposed()` 等卷就绪，最后 `CreateMicroServiceBRWatcher` 监控结果。exposer 的两种模式写在 [pkg/exposer/types.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/types.go)：`by-file-system` 与 `by-block-device`，[pkg/exposer/csi_snapshot.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/csi_snapshot.go) 据此把卷映射为 `Filesystem` 或 `Block` 模式。恢复侧的 RIA v2 在主仓内可见：[pkg/restore/actions/csi/pvc_action.go](https://github.com/velero-io/velero/blob/main/pkg/restore/actions/csi/pvc_action.go) 构造 `DataDownload` 并用 `Progress` 读 `BytesDone/TotalBytes`。官方文档进一步把内置搬运工分成 `velero-fs`（Kopia 文件系统级）与 `velero-block`（直读块设备、接 CSI CBT）（[site/content/docs/main/csi-snapshot-data-movement.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/csi-snapshot-data-movement.md)）。

#### 论据三：搬运队组件分工

| 组件（代码路径） | 职责 | 类比 |
|---|---|---|
| [pkg/exposer/types.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/types.go)、[csi_snapshot.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/csi_snapshot.go)、[host_path.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/host_path.go) | 把快照或活动卷暴露成 `ByPath` 文件路径或块设备，返回 `ExposeResult.ByPod` | 中转棚 |
| [pkg/uploader/provider/provider.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/provider/provider.go)、[types.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/types.go) | `NewUploaderProvider` 按 `uploaderType` 选 kopia 或 block，暴露 `RunBackup/RunRestore/Close` | 叉车 |
| [pkg/datapath/data_path.go](https://github.com/velero-io/velero/blob/main/pkg/datapath/data_path.go)、[types.go](https://github.com/velero-io/velero/blob/main/pkg/datapath/types.go)、[manager.go](https://github.com/velero-io/velero/blob/main/pkg/datapath/manager.go) | `AsyncBR` 契约、`AccessPoint`、回调与并发上限（`ConcurrentLimitExceed`） | 装卸调度台 |
| [pkg/datamover/backup_micro_service.go](https://github.com/velero-io/velero/blob/main/pkg/datamover/backup_micro_service.go)、[pkg/podvolume/backup_micro_service.go](https://github.com/velero-io/velero/blob/main/pkg/podvolume/backup_micro_service.go)、[pkg/cmd/cli/datamover/backup.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/datamover/backup.go) | VGDP-MS：在独立 Pod 内等工单 `InProgress`、起 data path、发 Event 回传结果 | 专车 |
| [pkg/cmd/cli/nodeagent/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/nodeagent/server.go)、[pkg/nodeagent/node_agent.go](https://github.com/velero-io/velero/blob/main/pkg/nodeagent/node_agent.go) | DaemonSet 上注册 4 个 reconciler（PVB/PVR/DataUpload/DataDownload），负责 Accept/Expose/监控 | 调度中心 |
| [pkg/cbtservice/service.go](https://github.com/velero-io/velero/blob/main/pkg/cbtservice/service.go)、[csi_service_impl.go](https://github.com/velero-io/velero/blob/main/pkg/cbtservice/csi_service_impl.go) | `GetAllocatedBlocks/GetChangedBlocks` 块级增量，实现走 CSI SnapshotMetadataService iterator | 变更清单 |
| [pkg/podexec/pod_command_executor.go](https://github.com/velero-io/velero/blob/main/pkg/podexec/pod_command_executor.go) | 用 pod exec API 在容器内执行 exec hook；属资源流水线，不在数据面 | 随车叮嘱 |
| [pkg/restorehelper/util.go](https://github.com/velero-io/velero/blob/main/pkg/restorehelper/util.go)、[cmd/velero-restore-helper](https://github.com/velero-io/velero/blob/main/cmd/velero-restore-helper/velero-restore-helper.go) | `restore-wait` initContainer 名与完成标记轮询 | 验收员 |

#### 论据四：架构演进

设计文档给出的迁移理由有五条：避免 hostPath 带来的特权升级、可按卷粒度配 CPU/内存、单个 VGDP 崩溃不拖累他人、避免动态挂载 PV 导致 node-agent 重启、以及让增量备份不再因 Pod UID 变化而退化成全量（[design/Implemented/vgdp-micro-service/vgdp-micro-service.md](https://github.com/velero-io/velero/blob/main/design/Implemented/vgdp-micro-service/vgdp-micro-service.md)）。该文档同时写明 node-agent 仍保留，因为 PVB/PVR 还要 root/特权。代码印证了两套命令并存：DataUpload 侧 [pkg/exposer/csi_snapshot.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/csi_snapshot.go) 起 `/velero data-mover backup`，PVB 侧 [pkg/exposer/pod_volume.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/pod_volume.go) 起 `/velero pod-volume backup`，`RestartPolicy` 均为 `Never`。版本节奏上，v1.18 加了 data mover 缓存卷、增量大小可观测、数据面事件诊断（[changelogs/CHANGELOG-1.18.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.18.md)）；v1.19 引入 block data mover（对接 [CSI Changed Block Tracking](https://kubernetes.io/blog/2025/09/25/csi-changed-block-tracking/)）、原地恢复、默认 prepare 队列长度 5，并完成 Restic 移除（[changelogs/CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md)；设计见 [design/Implemented/block-data-mover/block-data-mover.md](https://github.com/velero-io/velero/blob/main/design/Implemented/block-data-mover/block-data-mover.md)、[design/Implemented/volume-data-inplace-restore/volume-data-inplace-restore.md](https://github.com/velero-io/velero/blob/main/design/Implemented/volume-data-inplace-restore/volume-data-inplace-restore.md)）。**各设计提案与发布版本的精确一一对应关系未在代码中确认**，上述仅依据 changelog 条目。

#### 分析：两条通路其实共用同一副骨架

代码显示，PVB 与 DU/DD 的差别只在「货从哪来」：hostPath 读活动卷，还是 exposer 把 CSI 快照挂成 backupPVC；「货怎么装、往哪送」完全复用 [pkg/datapath/data_path.go](https://github.com/velero-io/velero/blob/main/pkg/datapath/data_path.go) 的 `StartBackup/StartRestore` → [pkg/uploader/provider/provider.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/provider/provider.go) → Kopia 仓库（[pkg/datamover/util.go](https://github.com/velero-io/velero/blob/main/pkg/datamover/util.go) 把 `velero-fs` 映射为 `kopia`、`velero-block` 映射为 `block`）。可以理解为：**exposer 决定入口、uploader 决定搬法、仓库决定出口**，三者被 [pkg/datapath/manager.go](https://github.com/velero-io/velero/blob/main/pkg/datapath/manager.go) 的并发闸门串起来。这正是全库「控制面/数据面分离」的贯彻：CR 只承载状态与结果（[data_upload_types.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v2alpha1/data_upload_types.go) 的 `snapshotID`、`progress`、`node`），真正吃 CPU/内存、可能因大卷 OOM 的活儿被隔离进一次性 Pod，且只有控制器有权改写工单。

#### 小结

第 4 章的仓库是「货存哪」，本章是「谁去搬、走哪条路」。中转棚 → 叉车 → 专车 → 仓库，四段都能在代码里点名；而 19 个 reconciler 中属于数据面的 4 个，就在 [pkg/cmd/cli/nodeagent/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/nodeagent/server.go) 的 `SetupWithManager` 四连注册里——调度中心始终不碰货物本身。

#### 本章速查

| 指标 | 数据 | 来源 |
|---|---|---|
| 卷数据内置通路 | 2 条：file-system backup(PVB) / CSI snapshot data movement(DU·DD) | [ARCHITECTURE.md](https://github.com/velero-io/velero/blob/main/ARCHITECTURE.md) |
| node-agent 注册的控制器 | 4 个：PVB / PVR / DataUpload / DataDownload | [pkg/cmd/cli/nodeagent/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/nodeagent/server.go) |
| DataUpload 状态枚举 | 8 个 | [pkg/apis/velero/v2alpha1/data_upload_types.go](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v2alpha1/data_upload_types.go) |
| exposer 访问模式 / uploader 合法类型 | 2 种 / 2 种 | [pkg/exposer/types.go](https://github.com/velero-io/velero/blob/main/pkg/exposer/types.go)、[pkg/uploader/types.go](https://github.com/velero-io/velero/blob/main/pkg/uploader/types.go) |
| 内置 data mover 名 | `velero-fs` / `velero-block` | [site/content/docs/main/csi-snapshot-data-movement.md](https://github.com/velero-io/velero/blob/main/site/content/docs/main/csi-snapshot-data-movement.md) |
| restore-wait 轮询间隔 / VGDP 默认 prepare 队列 | 1 秒 / 5（v1.19 起） | [cmd/velero-restore-helper/velero-restore-helper.go](https://github.com/velero-io/velero/blob/main/cmd/velero-restore-helper/velero-restore-helper.go)、[changelogs/CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md) |

---

## [PART:conclusion] 结论（Phase 4 产出）

回到开头：迷路不是因为 36 个包，而是「一个二进制换多重身份、声明式把执行拆成异步状态机、控制面与数据面各管一段」三件事叠加。分清**谁投递、谁调度、谁搬货**，骨架就归位。读完五章，值得记住的是：

1. **总装点只有一个**。3 个 main、24 个子命令虽散，服务端开机全在 [pkg/cmd/server/server.go](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go)：`newServer` → `run` 自检 → `runControllers` 逐个 `SetupWithManager` → `mgr.Start`。
2. **CLI 是投递员，不是施工队**。创建只是一次 `Create`，代价是 BackupPhase 有 13 个枚举；[pkg/controller/interface.go](https://github.com/velero-io/velero/blob/main/pkg/controller/interface.go) 的 `Run(ctx, workers)` 全仓无引用，属遗留接口，现行契约是 controller-runtime 的 `SetupWithManager` + `Reconcile`。
3. **备份是复制，恢复是谈判**。恢复多出已存在资源、排序、目标适配、原地恢复四层不对称，CRD 须先单独还原再刷新 discovery。
4. **「两间仓库」不是两个桶**。[pkg/repository/provider/unified_repo.go](https://github.com/velero-io/velero/blob/main/pkg/repository/provider/unified_repo.go) 把 Kopia 仓库拼进同一个 BSL 桶的子目录，`pkg/kopia/` 只是日志桥接层；v1.19 移除 Restic 属数据面实现移除，`restic/` 兼容痕迹仍在（[changelogs/CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md)）。
5. **分离是贯穿全库的主轴**：19 个控制器分 server 15 + node-agent 4 两处注册，卷数据进 VGDP 独立 Pod，插件跑在可自动重启的独立进程（[pkg/plugin/clientmgmt/process/restartable_process.go](https://github.com/velero-io/velero/blob/main/pkg/plugin/clientmgmt/process/restartable_process.go)）。换来可靠性、可扩展性与按卷配资源，代价是状态机复杂、跨进程开销和 v1/v2 双份接口——这就是「备份工具为何这么大」的答案。

**逛库顺序**：`cmd/velero/velero.go` 认门 → `pkg/cmd/server/server.go` 看总装 → 挑一张 Backup 工单，从 `create.go` 跟到 `backup_controller.go` 再到 `pkg/backup/backup.go` → 顺 status 落盘看 `pkg/persistence` → 最后才碰 `pkg/datamover` 与 VGDP。先竖切一条「从提交到归档」，再横向铺开。

留个尾巴：1.19.0 明确部分 CSI 驱动（如 Ceph RBD）尚不支持保留父快照的 CBT 增量（[changelogs/CHANGELOG-1.19.md](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md)）；设计提案与版本的精确对应、`.go` 计数统一按约 830 个、`velero-helper` 现行调用点未确认，都待后续核对。

---

## [PART:sources] 参考文献（Phase 4 产出，43 条，分组去重）

**A. 代码与配置（年份 2026 为本报告所依据的 v1.19 代码快照年份）**
- README.md, 2026, 仓库文档 [链接](https://github.com/velero-io/velero/blob/main/README.md)
- ARCHITECTURE.md, 2026, 仓库文档 [链接](https://github.com/velero-io/velero/blob/main/ARCHITECTURE.md)
- Dockerfile, 2026, 构建配置 [链接](https://github.com/velero-io/velero/blob/main/Dockerfile)
- cmd/velero/velero.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/cmd/velero/velero.go)
- cmd/velero-helper/velero-helper.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/cmd/velero-helper/velero-helper.go)
- pkg/cmd/velero/velero.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/cmd/velero/velero.go)
- pkg/cmd/server/server.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/cmd/server/server.go)
- pkg/cmd/cli/nodeagent/server.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/nodeagent/server.go)
- pkg/cmd/cli/backup/create.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/cmd/cli/backup/create.go)
- config/crd/v1/bases/velero.io_backups.yaml, 2026, CRD 清单 [链接](https://github.com/velero-io/velero/blob/main/config/crd/v1/bases/velero.io_backups.yaml)
- config/crd/v2alpha1/bases/velero.io_datauploads.yaml, 2026, CRD 清单 [链接](https://github.com/velero-io/velero/blob/main/config/crd/v2alpha1/bases/velero.io_datauploads.yaml)
- pkg/apis/velero/v1/backup_types.go, 2026, API 定义 [链接](https://github.com/velero-io/velero/blob/main/pkg/apis/velero/v1/backup_types.go)
- pkg/controller/backup_controller.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/controller/backup_controller.go)
- pkg/controller/interface.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/controller/interface.go)
- pkg/backup/backup.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/backup/backup.go)
- pkg/backup/item_block_worker_pool.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/backup/item_block_worker_pool.go)
- pkg/restore/restore.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/restore/restore.go)
- pkg/persistence/object_store.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/persistence/object_store.go)
- pkg/persistence/object_store_layout.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/persistence/object_store_layout.go)
- pkg/repository/provider/unified_repo.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/repository/provider/unified_repo.go)
- pkg/repository/udmrepo/service/service.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/repository/udmrepo/service/service.go)
- pkg/plugin/framework/handshake.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/plugin/framework/handshake.go)
- pkg/plugin/clientmgmt/process/restartable_process.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/plugin/clientmgmt/process/restartable_process.go)
- pkg/exposer/csi_snapshot.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/exposer/csi_snapshot.go)
- pkg/datamover/backup_micro_service.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/datamover/backup_micro_service.go)
- pkg/podvolume/backupper.go, 2026, 代码 [链接](https://github.com/velero-io/velero/blob/main/pkg/podvolume/backupper.go)

**B. 设计提案（design/Implemented）**
- design/Implemented/unified-repo-and-kopia-integration/unified-repo-and-kopia-integration.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/unified-repo-and-kopia-integration/unified-repo-and-kopia-integration.md)
- design/Implemented/volume-snapshot-data-movement/volume-snapshot-data-movement.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/volume-snapshot-data-movement/volume-snapshot-data-movement.md)
- design/Implemented/vgdp-micro-service/vgdp-micro-service.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/vgdp-micro-service/vgdp-micro-service.md)
- design/Implemented/block-data-mover/block-data-mover.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/block-data-mover/block-data-mover.md)
- design/Implemented/concurrent-backup-processing.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/concurrent-backup-processing.md)
- design/Implemented/biav2-design.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/biav2-design.md)
- design/Implemented/volume-data-inplace-restore/volume-data-inplace-restore.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/volume-data-inplace-restore/volume-data-inplace-restore.md)
- design/Implemented/backup-resources-order.md, 2026, 设计提案 [链接](https://github.com/velero-io/velero/blob/main/design/Implemented/backup-resources-order.md)

**C. 官方文档与变更日志**
- site/content/docs/main/how-velero-works.md, 2026, 官方文档 [链接](https://github.com/velero-io/velero/blob/main/site/content/docs/main/how-velero-works.md)
- site/content/docs/main/output-file-format.md, 2026, 官方文档 [链接](https://github.com/velero-io/velero/blob/main/site/content/docs/main/output-file-format.md)
- site/content/docs/main/restore-reference.md, 2026, 官方文档 [链接](https://github.com/velero-io/velero/blob/main/site/content/docs/main/restore-reference.md)
- site/content/docs/main/overview-plugins.md, 2026, 官方文档 [链接](https://github.com/velero-io/velero/blob/main/site/content/docs/main/overview-plugins.md)
- site/content/docs/main/csi-snapshot-data-movement.md, 2026, 官方文档 [链接](https://github.com/velero-io/velero/blob/main/site/content/docs/main/csi-snapshot-data-movement.md)
- changelogs/CHANGELOG-1.19.md, 2026, 变更日志 [链接](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.19.md)
- changelogs/CHANGELOG-1.18.md, 2026, 变更日志 [链接](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.18.md)
- changelogs/CHANGELOG-1.15.md, 2026, 变更日志 [链接](https://github.com/velero-io/velero/blob/main/changelogs/CHANGELOG-1.15.md)

**D. 在线网页与外部资料**
- How Velero Works, 2026, 在线文档 [链接](https://velero.io/docs/main/how-velero-works/)
- Velero Docs — File System Backup, 2026, 在线文档 [链接](https://velero.io/docs/main/file-system-backup/)
- hashicorp/go-plugin, n.d., 开源库 [链接](https://github.com/hashicorp/go-plugin)
- Go 1.4 Internal packages, 2014, 语言规范 [链接](https://go.dev/doc/go1.4#internalpackages)
- CSI Changed Block Tracking (Kubernetes Blog, 2025), 2025, 技术博客 [链接](https://kubernetes.io/blog/2025/09/25/csi-changed-block-tracking/)

---

## [PART:pending] 待完善事项（主理人据审稿建议与研究边界汇总；无审稿警告）

- 全部 5 章均在第 1 轮审稿通过（PASS），无 REVISE、无第 3 轮强制通过，**无遗留审稿警告**。
- **研究边界（如实标注，非错误）**：
  1. `design/Implemented/` 各设计提案与具体发布版本的精确一一对应关系未逐一比对，报告仅依据 changelog 条目陈述版本节奏。
  2. `pkg/` 下 `.go` 文件计数存在 821/542 与 836/557 两种口径（统计层级差异），报告统一采用「约 830 个 `.go`、36 个一级子包」。
  3. `velero-helper pause` 是 VGDP 设计文档记载的早期用法；当前代码中 CSI 侧跑 `/velero data-mover backup`、PVB 侧跑 `/velero pod-volume backup`，该二进制仍被 Dockerfile 编译，但**其现行调用点未在代码中确认**。`velero-restore-helper` 则仍被 `restore-wait` initContainer 使用。
  4. 备份侧创建 `DataUpload` 的生产代码未在主仓确认（设计文档把 BIA V2 归给外部 CSI Data Mover 插件）；恢复侧 RIA v2 在主仓可见。
  5. v1.19 块级 CBT 增量**不宜理解为全量支持**：changelog 明确部分 CSI 驱动（如 Ceph RBD）在 1.19.0 尚不支持保留父快照的增量。
  6. 正文引用的代码行号基于本次 dev 分支快照（`71374158a`），链接指向 `main` 分支，后续分支演进可能产生行号漂移；建议以函数名而非行号为锚复核。
- **审稿人非阻塞建议（已在汇编稿中处理）**：第 1 章移除「修正参数卡」的编辑口吻并给分组地图补链接；第 2 章给 13 CRD / 19 controller 表格逐项补链接、补 v1.18 版本锚点；第 3 章补 `sortResourcesByOrder` 所属文件；第 4 章把「只有一个文件」改为「主要是」、收窄凭证处理的因果表述；第 5 章给组件表逐项补链接、补 DUCR/DDCR 释义、删除无来源的版本号；各章「新增来源清单」「给主编的口径提示」等编辑附记已移出正文。

---

## [PART:disclaimer] 免责声明（固定文案）

> 本报告由 AI 深度研究团队生成，重要决策请经专业人员核验。所有引用来源请用户在重要场景下二次核验时效性与真实性。
