# TinyBuddy Maintenance Loop

## 目标

持续优化当前已有功能。每次 Loop 只处理一个最高价值、真实存在且可验证的优化点；Loop 不以新增功能为目标。

本 Loop 是可重复执行的入口。执行前先读取本文件和 `.agent/rules.md`，并遵守仓库根目录 `AGENTS.md` 的完整规则；Loop 结束时把结果追加到 `.agent/history.md`。

## 入口与运行方式

从仓库根目录开始，让智能体依次读取 `.agent/loop.md`、`.agent/rules.md` 和最近的 `.agent/history.md`（必要时含归档文件 `.agent/history-archive.md`），然后按下方 `Observe → Evidence → Decide → Execute → Verify → Record → Maintain` 顺序执行一次。没有单独的脚本入口；本文件就是 Loop 的操作契约，任何后续智能体都应从这里开始，并以仓库当前内容和新证据为准。

本 Loop 面向长期重复执行，每一轮都是独立、可自证的闭环。不存在"必须产出修改"的压力：若 Observe 与 Decide 之后没有真实且可验证的高价值问题，就以无修改轮次结束并记录依据；不为了产生修改而修改。

## 项目基线

以下基线已从当前仓库的 `README.md`、`Package.swift`、`project.yml`、`CLAUDE.md`、`AGENTS.md`、`Sources/`、`Widget/`、`Tests/`、`script/` 和 `docs/` 核对。后续 Loop 若发现基线变化，应以仓库当前内容为准并在记录中说明。

- **语言与框架**：Swift 6.0（`swiftLanguageMode(.v6)`），目标为 macOS 14；应用使用 SwiftUI，Widget 使用 WidgetKit。
- **工程入口**：Swift Package Manager 由 `Package.swift` 定义；`project.yml` 是 XcodeGen 的 Xcode 工程事实来源，生成 `TinyBuddy.xcodeproj`。
- **测试方式**：XCTest，分为 `Tests/TinyBuddyCoreTests/` 和 `Tests/TinyBuddyAppTests/`。标准全量入口是 `swift test`；`./script/swiftpm.sh test` 提供隔离缓存的仓库包装入口；可用 `swift test --filter <TestName>` 做窄测。
- **构建方式**：`swift build` 或 `./script/swiftpm.sh build` 用于 SwiftPM 构建；涉及 App/Widget、启动或签名时按需使用 `./script/build_and_run.sh` 的最小相关模式。目标、资源、entitlement 或新源文件改变时，先更新 `project.yml`，再运行 `xcodegen generate`（`script/tb-install.sh` 也会检查过期工程）。
- **静态检查**：仓库没有独立 lint；使用编译器、受影响测试和 `git diff --check`。只有修改 Git 刷新脚本时才运行 `/bin/bash -n script/update_git_completion_count.sh`。
- **工程规则**：`AGENTS.md` 是详尽规则与完成标准，`CLAUDE.md` 是快速摘要；`project.yml` 对 Xcode 目标结构、资源、签名和 entitlements 具有权威性。不要用本 Loop 文档替代这些规则。
- **文档结构**：`README.md` 是使用与验证说明；`docs/superpowers/specs/` 保存规格，`docs/superpowers/plans/` 保存计划。根目录已有 `.agents/`、`.codex/`，但当前只承载技能目录，没有可复用的维护 Loop，因此本入口位于 `.agent/`。

## 执行流程

### 1. Observe（观察）

收集原始状态，不要先猜解决方案：

- 检查项目状态、未提交改动和是否存在用户正在进行的修改：`git status --short`、`git diff`。
- 阅读最近代码变化：`git log -5 --oneline --decorate`，再查看与候选区域相关的提交和 diff。
- 检查已有问题、失败记录、回归说明和仓库内的维护线索；只使用当前任务授权范围内的 issue、日志或用户反馈。
- 搜索 `TODO`、`FIXME` 及同类标记，确认它们对应真实可复现的问题，而不是把标记本身当成问题：`rg -n "TODO|FIXME" Sources Tests Widget script`。
- 检查测试状态：先找受影响的测试，再运行最窄的相关测试；若无法确定影响范围，记录理由并使用 `swift test`。
- 检查用户反馈或错误信息（如果存在）。外部系统未提供或未获授权时，不要擅自访问；不要把未验证的猜测写成事实。

观察结束前确认工作区边界：不得覆盖、回滚或清理用户已有修改；不读取凭证、私密数据或无关项目。

### 2. Evidence（证据整理）

把观察到的原始状态整理成针对候选问题的可验证证据，先于决策固化事实：

- 为每个候选问题记录：复现条件、影响范围、证据来源、可验证的完成标准（“什么结果算修复”）。
- 明确区分“已验证事实”与“未验证猜测”：猜测不得写入历史记录，也不得作为决策依据。
- 若某候选问题缺少可复现证据或无法验证，直接淘汰，不进入 Decide。
- 若所有候选都未通过证据门槛，本轮无修改结束，并在历史中记录观察范围与淘汰理由。

### 3. Decide（决策）

从证据已成立的候选问题中只选择一个真实存在且可验证的问题。按下列优先级排序：

1. Bug
2. 稳定性风险
3. 性能问题
4. 错误处理不足
5. 测试缺口
6. 用户体验问题

同一优先级下，优先选择用户影响更大、复现和验证更清晰、改动更小且回滚风险更低的项。必须写清楚“为什么现在处理它”和“什么结果算修复”；不能为了凑一轮而制造问题，也不能同时处理多个优化点。

选择问题时，先与 `.agent/history.md`（必要时含 `.agent/history-archive.md`）核对，避免重复处理已完成的问题：

- 同一模块可以继续优化，但必须引用新的证据：新的失败、新的复现、新的指标或新的用户反馈，并在记录中说明与已完成轮次的差异；仅凭“还能改得更好”不构成新一轮。
- 若候选问题与历史中已完成的问题同根因，视为重复问题，不重复处理；除非出现了历史记录中未覆盖的新证据。
- 每轮只处理一个问题；其余候选即使有价值也留给后续轮次，可在记录中列出以便追踪。

### 4. Execute（执行）

进行最小必要修改，只围绕选定问题和其证明测试展开。允许新增或调整测试来固定真实行为，但不得以削弱断言、跳过测试或改写预期来制造通过。

禁止：

- 新增功能或扩大用户可见范围
- 大规模重构、无关格式化或修改架构方向
- 升级依赖或改变工具链
- 删除已有行为、绕过错误或隐藏失败
- 覆盖用户修改、执行破坏性清理，或读取/写入不在任务范围内的数据

### 5. Verify（验证）

修改后必须基于证据验证，不得以“应该可以”结束：

- 运行受影响的窄测试；共享逻辑、App 行为、Git 刷新、焦点会话、数据完整性或 Widget 表现变化稳定后，再运行一次 `swift test`。
- 根据改动类型运行对应构建/静态检查：Swift 代码用 `swift build`（必要时再用 `./script/swiftpm.sh build`）；Git 刷新脚本用 `/bin/bash -n script/update_git_completion_count.sh`；构建、签名、Widget 或启动行为用最小相关的 `./script/build_and_run.sh` 模式；性能或资源改动用 `./script/benchmark_git_refresh.sh` 或仓库规定的回归门禁。
- 仅文档或 `.agent/` 基础设施改动时，验证路径、内容、`git diff --check` 和业务文件未被修改即可，不为文档变更强行执行无关的 App/Release 流程。
- 总是复查 `git diff` 和 `git status --short`，确认改动范围、测试结果和用户修改均符合预期。
- 若验证产生新证据，回到 Execute 针对同一个问题继续修复；最多连续修复 3 轮（每轮均包含修改与验证）。第 3 轮仍失败时停止，记录阻塞和剩余风险，不得声称已完成。
- Release 安装、发布、部署或替换已安装 App 属于外部状态变更；除非用户明确授权，不执行这些操作。已有成功的 release 证据只有在输入未变更且证据完整时才能复用。

### 6. Record（记录）

把本轮结果追加到 `.agent/history.md`，每轮一个条目，至少包含：

- 日期（`YYYY-MM-DD`）
- 发现的问题及证据
- 原因分析
- 修改内容（含受影响的仓库相对路径）
- 验证结果（实际执行的命令、通过/失败及关键输出）
- 剩余风险、未完成项或阻塞原因

记录应保持简洁、可审计、可复现；不得写入凭证、私密数据、绝对用户路径或未经脱敏的诊断内容。无修改轮次也要记录观察范围、未发现可验证问题的依据和剩余风险。

### 7. Maintain（维护历史，长期运行用）

`.agent/history.md` 是历史记录的唯一入口，必须防止其无限膨胀：

- **保留近期记录**：`history.md` 始终保留最近约 10 条轮次记录（以条目为单位），保证近期上下文立即可读。
- **归档旧记录**：当 `history.md` 中条目数超过 10 条时，把最旧的条目按原样移动到 `.agent/history-archive.md`（归档文件不存在则创建，头部注明用途与归档时间）；归档条目不丢失、不改写、保持完整可审计。
- **归档时机**：每次 Record 追加后执行归档检查；归档属于 `.agent/` 基础设施维护，不计入"问题修改"，也不触发额外验证。
- **去重查询**：Observe/Decide 阶段核对历史时，同时读 `history.md` 与 `history-archive.md`，避免因归档导致重复处理已完成的问题。

## Loop 结束条件

有修改时，只有在单一问题的修改已完成并通过适用验证、历史已更新、且工作区检查确认没有越界改动时，才可报告本轮完成；若观察后没有真实且可验证的问题，则以历史记录为依据结束无修改轮次。失败或证据不足时，明确报告已验证内容和剩余风险，并把后续工作留给下一轮。
