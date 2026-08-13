# TinyBuddy 长期项目知识（Memory）

本文件保存稳定、可复用的仓库长期知识，供 Maintenance Loop 的 Observe 阶段读取，避免重复核查已确认的事实。只写已核实的稳定信息；逐轮修改细节、临时日志与大量测试输出一律不写入本文件，请查阅 `.agent/history.md`（及其归档 `.agent/archive/`）。若发现本文件与仓库当前内容不一致，以仓库现状为准，并在记录中说明。

## 项目定位与技术栈

- TinyBuddy 是 macOS 14 桌面伴侣 HUD：SwiftUI 悬浮桌面宠物 + 共享每日 Git 活动统计 + 焦点会话引擎，App 与桌面 Widget 呈现同一份轻量生产力状态。
- Swift 6.0（`swiftLanguageMode(.v6)`），目标平台 macOS 14（`Package.swift` 的 `platforms: [.macOS(.v14)]`）。
- 工程入口：Swift Package Manager（`Package.swift` 定义 target）与 XcodeGen（`project.yml` 是 Xcode 工程事实来源，生成 `TinyBuddy.xcodeproj`）。

## 进程架构与共享状态

- 三个进程通过 App Group `group.com.ryukeili.TinyBuddy` 协作：
  - `script/update_git_completion_count.sh`：Bash Git 扫描器（App 唯一的 Git 读取方），解析授权扫描根下的 reflog，写入 App Group preferences 原始计数。
  - `TinyBuddy`（App）：拥有全部状态；`GitActivityRefreshCoordinator` 校验脚本输出并提交。
  - `TinyBuddyWidgetExtension`：只读 WidgetKit 消费者（`repairOnLoad: false`），从不写入。
- 组合快照是唯一真相：`TinyBuddyCombinedSnapshotStore` 合并宠物、Git 活动与焦点历史切片，revision 单调、带 schema 版本（V3 为新写入格式，V2/V1 为旧读者镜像）；写入采用双槽 A/B 事务 + 独立校验的 `committedRevision` 标记，崩溃不会暴露撕裂状态。HUD、Widget、遥测与 Release 校验必须读同一份已提交组合快照。
- 开发中断恢复是唯一独立通道（不经组合快照）：脚本在成功刷新时把路径无关的场景（base64 fingerprint/name/branch、工作树计数、最近提交、活动/捕获时间）以 v1 13 字段制表符格式写入 App Group 键 `tinybuddy.developmentInterruption.snapshot.v1`，App 经 `DevelopmentInterruptionSnapshotStore` 读取（7 天过期窗口 + 5 分钟未来容忍，主 App 启动时清理过期值，重置服务一并清除该键），HUD 的"继续上次开发"面板展示；失败/跳过刷新不覆盖旧场景，仅持久化 fingerprint 与展示名、永不写仓库路径。跨进程契约测试见 `GitActivityRefreshScriptTests` 与 `DevelopmentInterruptionSnapshotTests`。
- 时间模型：`TinyBuddyTimeEnvironment` 是本地日边界的权威来源，所有快照、焦点与 Git 活动归属共用同一日边界；`TinyBuddyTimeCalibrator`/`TinyBuddyTimeContinuityRecord` 处理时钟、DST 与日变化。

## 模块职责边界

- `Sources/TinyBuddyCore/`：全部共享业务逻辑（存储、焦点会话引擎/协调器/规则/证据/编辑、Git 活动存储、项目身份注册、组合快照 + 迁移器、数据完整性/修复/隔离、存储清理、时间模型、Widget 表现模型、隐私脱敏、诊断）。
- `Sources/TinyBuddy/`：薄 SwiftUI HUD + 生命周期接线，不承载业务规则。
- `Widget/TinyBuddyWidget/`：单一 Widget 入口，只读。
- `Sources/TinyBuddyReleaseInstaller/`、`Sources/TinyBuddyReleaseVerifier/`：签名发布工作流的窄 CLI 助手。
- 焦点会话：`FocusSessionEngine` 是生命周期权威；会话按项目不重叠，由 `ProjectIdentity` + 时间范围标识；手动菜单栏控制与自动 Git 活动归属共享同一引擎/存储。

## 构建、测试与验证约定

- 构建：`swift build` / `./script/swiftpm.sh build`（隔离缓存的仓库包装）。涉及 App/Widget/签名/启动时按需使用 `./script/build_and_run.sh` 的最小相关模式。
- 测试：XCTest。`Tests/TinyBuddyCoreTests/`（确定性核心）+ `Tests/TinyBuddyAppTests/`（App 行为；`Helpers/` 提供 `DeterministicRandom`、`DeterministicScheduler`、`EventTimeline`、`FaultScenario`）。标准入口 `swift test`，窄测 `swift test --filter <TestName>`。
- 静态门禁：仓库无独立 lint；使用编译器、受影响测试与 `git diff --check`。Git 刷新脚本改动需 `/bin/bash -n script/update_git_completion_count.sh`。
- 发布门禁：`./script/build_and_run.sh release-install`（事务式安装/替换）、`release-verify`（已装签名 App 与 Widget 注册校验）、`release-acceptance`（终端发布门禁）；性能/资源门禁 `./script/benchmark_git_refresh.sh`、`./script/regression_gate.sh`。这些会改变外部状态，未经用户明确授权不执行。
- 工程文件变更：目标/资源/entitlement/签名或新增源文件时先改 `project.yml` 再 `xcodegen generate`；`script/tb-install.sh` 会在工程过期时自动重建。

## 已解决的重要问题（避免重复处理与重复核查）

- `GitCommandExecutor` 只读验证（`readOnly` 模式）系列修复已完成，结论如下：
  - `git config` 合法只读形式：`--file <path>`、`-f <path>`、`--blob <oid>`、`--type <type>`、`--default <value>`；这些选项携带的值不参与裸参数计数。写形式 `git config <name> <value>`（含 `--type`/`-f` 变体）仍被拒绝。
  - `git reflog` 采用黑名单：仅 `expire`/`delete` 为写子命令被拒，`show`/`exists`/ref 简写/无参数放行。
  - 维护提示：若 Git 未来新增带值选项，需同步维护 `valueTakingOptions`（保守方向：误拒优于误放行）。
- 恢复重试取消机制（`GitActivityRefreshCoordinator.directoryRecoveryGeneration`）：成功刷新递增 generation，使已排队的恢复重试检测到不匹配而失效，不消耗重置后的恢复预算、不误标 `hasExhaustedDirectoryRecovery`；已有回归测试覆盖。
- 上述问题的复现、验证过程与测试见 `.agent/history.md`；本处仅保留结论性知识。

## `.agent/` 体系自身定位

- 入口：`.agent/loop.md`（七阶段契约：Observe → Evidence → Decide → Execute → Verify → Record → Maintain；Maintain 负责历史归档）。
- 规则：`.agent/rules.md`（工作边界，与根级 `AGENTS.md`/`CLAUDE.md` 及用户请求一起生效）。
- 历史：`.agent/history.md` 保留最近约 10 条轮次记录；旧条目原样归档到 `.agent/archive/`（日常 Loop 以 `history.md` 近期记录为准，核对去重时再读归档）。
- 本文件只存长期知识；逐轮细节一律查 `history.md` 与归档。
