# Maintenance Loop History

用于记录每一次 Maintenance Loop 的结果。请按 `.agent/loop.md` 的 Record 阶段追加条目，并按 Maintain 阶段维护本文件：

- 本文件始终保留最近约 10 条轮次记录。
- 当条目数超过 10 条时，最旧的条目原样移动到 `.agent/archive/` 目录下的归档文件（如 `history-YYYY-MM-DD.md`；不存在则创建，头部注明用途与归档时间）；归档条目不丢失、不改写。
- 观察与决策阶段核对历史时，同时读取本文件与 `.agent/archive/` 归档，避免重复处理已完成的问题。



## Loop 12：2026-08-13：无修改轮次（main 最新开发中断恢复改动经全量回归验证通过，未发现新的可验证问题）

**Loop 编号**
- Loop 12。

**日期**
- 2026-08-13

**观察结果**
- 工作区：`git status --short` 无输出、`git diff --check` 通过、无未跟踪文件。
- 分支：`agent/optimize-agent-validation` 领先 main 仅 1 个提交 `408b238`（"Optimize agent validation strategy"，只改 `AGENTS.md`，+9/-3，已推送 origin）；main 最新提交 `aec839c`（"Add development interruption recovery"，15 文件 +884/-57）已在分支历史中，是本轮观察的主要对象。
- `aec839c` 静态审查（开发中断恢复功能）：
  - 跨进程格式契约一致：脚本写入 App Group plist 的 `tinybuddy.developmentInterruption.snapshot.v1`，v1 制表符分隔 13 字段（fingerprint/name/branch base64 + staged/modified/untracked/conflicted + commit hash/subject base64 + commit/activity/captured epoch），App `DevelopmentInterruptionSnapshotStore.decode` 逐字段校验（base64 长度上限、计数 0…1,000,000、epoch 有限性与未来容忍 5 分钟、捕获时间不早于活动时间），与脚本写入逐项对应。
  - 生命周期：7 天过期窗口 + 主 App 启动 `clearIfExpired`；刷新失败路径不写入（保留旧值），脚本签名不变时保留原 activity epoch（跨午夜不虚构新活动时间），签名变化且同 fingerprint 时以刷新时间为新活动时间，语义自洽。
  - 测试覆盖：`DevelopmentInterruptionSnapshotTests`（解码/拒绝畸形与未来快照/7 天过期清理）、`GitActivityRealRepositoryFixtureTests.testPublishesDevelopmentInterruptionSceneWithoutRepositoryPath`（真实仓库、无仓库路径泄漏）、`GitActivityRefreshScriptTests.testScriptReusesCachedFingerprintsWithOneBoundedInterruptionRead`（缓存复用 + 有界读取）。
- 静态信号：`rg "TODO|FIXME|HACK|XXX"` 无真实待办（仅 `mktemp` 模板 `XXXXXX`）；`try!`/`fatalError` 无匹配；force-unwrap 无新候选（Loop 8/9 已复核）。
- 脚本基线：`/bin/bash -n script/update_git_completion_count.sh` 通过。
- 测试基线：`swift test` 全量 **1554 个测试、0 失败**（后台运行，约 237s）；这是 `aec839c`（Loop 11 之后、无记录在案验证证据的 884 行跨进程改动）的首次全量回归验证。

**选择的问题及证据**
- 无。逐项核对后未发现相对 Loop 11 的新证据，候选淘汰理由：
  - **开发中断恢复（`aec839c`）**：格式契约、边界（base64/计数/epoch/未来容忍）、生命周期（过期/失败路径/跨午夜保留）、隐私（只持久化 fingerprint 与展示名，无仓库路径）交叉审查未发现缺陷；新增专项测试 + 全量 1554 测试全绿，无新失败、新复现、新指标或新用户反馈，不构成修改依据。
  - 脚本 focus_block dead code、`page.last!`、`TinyBuddyTimeContext(...)!`、`precondition(!days.isEmpty)`：与 Loop 8/9 已评估项同根因，无新证据，不重复处理。
- 完成标准：na（无修改轮次）。

**原因分析**
- 本轮实质价值是首次对 `aec839c` 的 884 行跨进程改动（脚本采集 ↔ App 解码 ↔ HUD 面板 ↔ 重置清理）做全量回归验证：1554 测试全绿、静态审查未发现契约或边界缺陷。按 loop.md 契约"无证据即无修改，不为了产生修改而修改"。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录并按 Maintain 归档最旧 1 条，属契约要求的 Record/Maintain 阶段）。

**验证结果**
- `swift test` 全量：1554 个测试，0 失败（基线，后台运行记录）。
- `/bin/bash -n script/update_git_completion_count.sh`：通过。
- `git diff --check`：通过（history.md 追加仅新增行）。
- `git status --short` 复查：业务文件零改动；`.agent/` 下历史文件为本轮唯一新增。

**剩余风险**
- 本轮为无修改轮次，无新增风险。开发中断恢复面板的端到端运行行为（真实安装 + 启动展示）由用户授权的本机签名安装运行另行验证；其展示层已有 `PetViewRenderingTests` 覆盖，脚本/解码契约有真实仓库测试覆盖。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。

## Loop 13：2026-08-13：无修改轮次（main 最新提交为纯文档变更，内容与实现一致，未发现新的可验证问题）

**Loop 编号**
- Loop 13。

**日期**
- 2026-08-13

**观察结果**
- 工作区：`git status --short` 无输出、无未跟踪文件；HEAD == origin/main == `2027e5a`，仓库干净。
- 分支：main 与 origin/main 同步；其余 agent/codex 工作分支（`agent/focus-source-tracking`、`codex/reduce-resident-energy-wakeups` 等）未合并，不属于 main 当前状态，本轮不观察。
- 最近提交：自 Loop 12（`f6e86b2`）以来唯一新提交是 `2027e5a`（"Document development interruption recovery channel"，仅改 `.agent/memory.md` +1、`AGENTS.md` +8/-3、`CLAUDE.md` +10/-4，共 +12/-7）——纯文档变更，业务代码零变化。
- `2027e5a` 内容核实：三处文档补充的开发中断恢复通道描述（v1 13 字段制表符格式、7 天过期窗口 + 5 分钟未来容忍、成功刷新才写入、失败/跳过不覆盖、路径无关）与 `aec839c` 实现逐项一致；代码实测：`TinyBuddyResetService.swift:330` 重置时清除 `DevelopmentInterruptionSnapshotStore.Key.snapshot`，`PetViewModel.swift:176/703` 启动与刷新时 `clearIfExpired(at:)`，均与文档声明一致。
- 静态信号：`rg "TODO|FIXME|HACK|XXX"` 无真实待办（仅 `script/` 下 `mktemp` 模板 `XXXXXX`）；业务代码自 `aec839c`（Loop 12 已全量验证 1554 测试全绿）以来逐字节未变，无新 try!/fatalError/force-unwrap 候选。
- 测试基线：`swift test --filter GitCommandExecutorTests`：33 个测试通过（环境健康检查）。

**选择的问题及证据**
- 无。逐项核对后未发现相对 Loop 12 的新证据，候选淘汰理由：
  - `2027e5a` 文档提交：内容与 `aec839c` 实现及测试一致（重置清除、过期清理、失败不覆盖、路径无关均已代码核实），无错误或误导声明，不构成修改依据。
  - 脚本 focus_block dead code、`page.last!`、`TinyBuddyTimeContext(...)!`、`precondition(!days.isEmpty)`：与 Loop 8/9/12 已评估项同根因，无新失败、新复现、新指标或新用户反馈，不重复处理。
- 完成标准：na（无修改轮次）。

**原因分析**
- 自 Loop 12 以来唯一提交是纯文档变更，业务代码零变化；文档内容经代码核实与实际实现一致。观察范围（工作区、提交历史、静态信号、窄测基线）内不存在触发新一轮的证据门槛。按 loop.md 契约"无证据即无修改，不为了产生修改而修改"。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录并按 Maintain 归档最旧 1 条，属契约要求的 Record/Maintain 阶段）。

**验证结果**
- `swift test --filter GitCommandExecutorTests`：33 个测试通过（基线，环境健康检查）。
- `git diff --check`：通过（history.md 追加仅新增行）。
- `git status --short` 复查：业务文件零改动；`.agent/` 下历史文件为本轮唯一新增。

**剩余风险**
- 本轮为无修改轮次，无新增风险。开发中断恢复面板的端到端运行行为（真实安装 + 启动展示）仍需用户授权的本机签名安装另行验证（Loop 12 同述）。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- Loop 11 记录的次优先检查点仍无新失败证据：`DeterministicEndToEndFaultSimulationTests` 的 3.0s REPRO 窗口，留待出现实际失败时处理。

## Loop 14：2026-08-13：无修改轮次（未提交的“继续专注”一键恢复功能经独立审查与全量回归验证，未发现新的可验证问题）

**Loop 编号**
- Loop 14。

**日期**
- 2026-08-13

**观察结果**
- 工作区：`git status --short` 显示 8 个已修改文件 + 2 个未跟踪新文件（`Sources/TinyBuddyCore/DevelopmentInterruptionRecovery.swift`、`Tests/TinyBuddyAppTests/PetViewModelDevelopmentInterruptionResumeTests.swift`、`Tests/TinyBuddyCoreTests/DevelopmentInterruptionResumeDecisionTests.swift`）——即开发中断“继续专注”一键恢复功能（334 行改动），尚未提交；`.agent/history.md` 与 `.agent/archive/history-2026-08-13.md` 为 Loop 13 遗留的 Record/Maintain 未提交改动（归档 1 条 + 追加 Loop 13 记录），与业务改动无重叠，原样保留。
- 最近提交：`2027e5a`（Document development interruption recovery channel）；HEAD == origin/main。
- `rg "TODO|FIXME|HACK|XXX"`：无真实待办（仅 `script/` 下 `mktemp` 模板 `XXXXXX`）；`git diff --check` 通过。
- 测试基线：`swift test --filter GitCommandExecutorTests|DevelopmentInterruptionResumeDecisionTests|PetViewModelDevelopmentInterruptionResumeTests`：50 个测试全绿；功能改动自上一轮全量验证（1572 测试 0 失败）以来代码未变，按“输入未变不重复昂贵门禁”复用该全量证据。

**选择的问题及证据**
- 无。本轮对未提交的“继续专注”功能（`aec839c` 开发中断恢复的后续升级）做独立静态审查，逐项核实通过：
  - 精确匹配门控：fingerprint 大小写折叠精确匹配（与注册表 `lowercased()` 约定一致）、kind 为 git、state 为 active、stored fingerprint 非空；名称/别名不参与匹配（测试覆盖仅同名不同 fingerprint、nil fingerprint、archived/temporarilyUnavailable/removed、非 git kind、空 fingerprint 全部 blocked）。
  - 多匹配确定性：active 优先 + 稳定 id 最小（`usableProject`），测试覆盖。
  - 会话冲突：基于引擎当前打开会话（含自动会话，新增 `FocusSessionEngine.currentSessionStatus` 最小扩展）而非 `manualControlState`；同项目 → inProgress(active/paused)，他项目 → blocked；测试覆盖自动会话在 `manualControlState == .idle` 时仍正确判定 inProgress。
  - 一键恢复：`resumeDevelopmentInterruption()` 调用时先重算再走既有 `startManualFocus` 链路（context = 匹配项目 id + displayName），非 `.available` 一律 no-op；测试覆盖无会话启动成功（会话 key = 注册 id）、阻断态 no-op（引擎无新会话、manualControlState 不变）。
  - 边界与隐私：会话记录无仓库路径、defaults 无新增 key（测试覆盖）；`DevelopmentInterruptionSnapshot.swift` 与 `script/update_git_completion_count.sh` 零改动（快照 v1 格式与采集链路未变）；diff 中无新 Git 命令/脚本调用。
  - 生命周期：重算钩子覆盖 init、快照重载、手动状态刷新（含 1s timer，纯计算开销可忽略）、`focusSessionStatsDidChange`、前台恢复、`TinyBuddy.projectRegistryDidChange` 通知；新增观察者随 deinit 移除。
  - 既有候选（脚本 focus_block dead code、`page.last!`、`TinyBuddyTimeContext(...)!`、`precondition(!days.isEmpty)`）：与 Loop 8/9/12/13 同根因，无新失败、新复现、新指标或新用户反馈，不重复处理。
- 完成标准：na（无修改轮次）。

**原因分析**
- 功能实现经 9 项静态审查点逐一核实 + 50 个窄测全绿 + 上一轮 1572 全量全绿，未发现真实可复现缺陷；唯一观察到的冗余（`DevelopmentInterruptionResumeState.matchedProject` 仅测试使用）属最小 API 表面冗余，不构成修改依据。按 loop.md 契约“无证据即无修改，不为了产生修改而修改”。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录并按 Maintain 归档最旧 1 条，属契约要求的 Record/Maintain 阶段）。

**验证结果**
- `swift test --filter GitCommandExecutorTests|DevelopmentInterruptionResumeDecisionTests|PetViewModelDevelopmentInterruptionResumeTests`：50 个测试，0 失败。
- 全量回归：复用上一轮 1572 个测试 0 失败证据（本轮代码未变）。
- `git diff --check`：通过。
- `git status --short` 复查：业务改动（继续专注功能）与 `.agent/` 记录改动均原样保留，无越界修改。

**剩余风险**
- 本轮为无修改轮次，无新增风险。“继续专注”功能尚未提交；用户已授权后续签名安装运行与提交推送，端到端运行行为由安装运行验证（Loop 12/13 同述的待办）。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- Loop 11 记录的次优先检查点仍无新失败证据：`DeterministicEndToEndFaultSimulationTests` 的 3.0s REPRO 窗口，留待出现实际失败时处理。
## Loop 15：2026-08-13：修复 idleDetected 长缺席结束路径残留陈旧 pendingSwitch（切换边界误用）

**Loop 编号**
- Loop 15。

**日期**
- 2026-08-13

**观察结果**
- 工作区：`git status --short` 显示 17 个已修改文件 + 2 个未跟踪新文件——即自动专注确认门功能（`FocusSessionConfirmationGate` 及其测试，前一轮未提交改动），本轮未覆盖或回滚；`.agent/` 无在途修改（Loop 14 记录已随 `2772659` 提交）。最近提交：`2772659`（Loop 14 记录）、`c8c92f9`（继续专注一键恢复）、`2027e5a`（文档）。
- `rg "TODO|FIXME|HACK|XXX"`：无真实待办（仅 `script/` 下 `mktemp` 模板 `XXXXXX`）。
- 在途确认门改动逐点复核中，对照引擎全部 `pendingSwitch` 清理点（12 处）发现唯一不一致：`idleDetected` 长缺席结束路径（`FocusSessionEngine.swift`）结束时**未清空 `pendingSwitch`**，其余所有会话结束路径（`endPausedSessionAfterLongAbsence`、锁屏、解锁、日切、手动接管、`finalizeOpen`、`edit` 等）均清空。

**选择的问题及证据**
- 选择"idleDetected 长缺席结束路径残留陈旧 pendingSwitch"这一数据正确性问题（Loop 优先级第 3 位）。
- 复现条件（确定性）：会话 A 打开 → 前台切到 B（A 暂停、pendingSwitch=(A, away, B)）→ 已暂停状态下 `idleDetected` 且暂停时长 ≥ `longAbsenceThreshold`（A 结束，pendingSwitch 残留）→ 新活动打开 B 会话 → 单次活动切到 C：确认门配置为 `confirmationMinimumActiveDuration ≤ 0`（即时确认）时，确认路径消费陈旧边界：`transitionTime` 把 B 钳制到**自身起点**结束（时长清零），C 从陈旧边界开始，B 的专注时长被错误归属到 C。
- 修复前运行新测试 `test_idle_long_absence_end_clears_stale_pending_switch` 按预期失败（调试输出实证：B endedAt=自身起点、activeDuration=0；C startedAt=陈旧边界而非活动时刻）。
- 完成标准：`idleDetected` 结束路径与其他结束路径一致清空 `pendingSwitch`；新测试全绿；焦点类与全量回归无失败。

**原因分析**
- `idleDetected` 的已暂停分支只处理"暂停超时结束"，遗漏了与 `endPausedSessionAfterLongAbsence` 相同的清理职责（后者清空 `pendingSwitch`）。生产默认阈值（确认门 120s）下陈旧边界总会在被消费前被未确认的首事件替换，实际影响限于即时确认配置（`≤ 0`，恰为全部测试 harness 与"legacy 即时开始"配置所用）；属引擎内既有的潜在数据归属缺陷，此前从未记录或覆盖。

**修改内容**
- `Sources/TinyBuddyCore/FocusSessionEngine.swift`：`idleDetected` 长缺席结束分支在 `endSession` 后补 `pendingSwitch = nil`（一行，与 `endPausedSessionAfterLongAbsence` 一致）。
- `Tests/TinyBuddyCoreTests/FocusSessionEngineTests.swift`：新增 `test_idle_long_absence_end_clears_stale_pending_switch`（确定性时钟驱动真实引擎：A→pending B→idle 结束→B 新会话→C 切换，断言 B 时长 30s 保留、C 从真实活动时刻开始）。

**验证结果**
- 修复前新测试失败（`c.startedAt`=陈旧边界、`b.endedAt`=B 起点、`b.activeDuration`=0）：缺陷真实存在。
- 修复后新测试通过；焦点类 8 个相关测试类 225 个测试 0 失败。
- `swift test` 全量：1595 个测试（+1），0 失败。
- `git diff --check`：通过。
- `git status --short` 复查：本轮改动仅 `FocusSessionEngine.swift` 与 `FocusSessionEngineTests.swift` 各一处；在途确认门改动原样保留，无越界修改。

**剩余风险**
- 生产默认阈值下该路径需"即时确认配置 + 精确时序"才可达，属防御性修复；本次以测试固定行为，无新增风险。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- Loop 11 记录的次优先检查点仍无新失败证据：`DeterministicEndToEndFaultSimulationTests` 的 3.0s REPRO 窗口，留待出现实际失败时处理。

## Loop 16：2026-08-14：修复确认门在生产事件流下永远无法确认持续输入（周期性活动心跳）

**Loop 编号**
- Loop 16。

**日期**
- 2026-08-14

**观察结果**
- 工作区干净（`git status --short` 无输出），HEAD == origin/main == `d0b980c`（Loop 15 记录）；自 Loop 15 以来唯一新提交是 `1ebef5e`（"Gate automatic focus on sustained activity"，+929 行：新增 `FocusSessionConfirmationGate`、`FocusSessionEngine` 确认门接线、规则版本 1.0→1.1、594 行确认门测试），即 Loop 15 观察到的在途确认门改动已提交（含 Loop 15 修复的 `pendingSwitch = nil`）。
- 静态信号：`rg "TODO|FIXME|HACK|XXX"` 无真实待办（仅 `mktemp` 模板）；`try!`/`fatalError` 无匹配；`git diff --check` 通过。
- 接线审查（关键发现）：App 事件流未随提交改动——引擎 `userActivity` 事件仅来自 (a) idle→active 转换（`FocusSessionAppBridge.swift:251`，每轮询周期一次，默认轮询 15s）、(b) 非自动化 Git 提交（`TinyBuddyApp.swift:798`）、(c) 解锁/唤醒/启动单次事件（`reportActiveAfterIdle`）；持续活动期间（`!isNowIdle` 分支，line 253-258）轮询仅递增 `activeCount`（该变量本身是既有无读死变量），不产生任何引擎事件。

**选择的问题及证据**
- 选择"确认门在生产事件流下无法确认持续输入"这一用户影响 Bug（Loop 优先级第 1 位）。
- 复现条件（确定性）：默认 `confirmationMinimumActiveDuration = 120`，而"持续输入（无提交、无 ≥120s idle）"在整个工作时段只产生 1 个引擎事件 → 门累计 0 < 120 → 自动焦点会话**永不启动**；规则 1.0（`1ebef5e^`）下首个事件即 `startSession`，属用户可见回归（HUD/Widget 焦点统计对纯输入型工作静默丢失）。自动项目切换同根因：pending switch 后在新项目持续输入但无事件 → 门无法确认 → 切换永不提交（该路径在门前后均有缺陷，一并修复）。
- 与设计意图矛盾：门文档明示"短暂输入不启动、持续活动确认"，而接线使"持续输入"与"短暂输入"（同为单事件）不可区分。
- 完成标准：新增周期性心跳只喂确认门（不改写已打开同项目会话、零持久化抖动）；确定性测试覆盖 持续输入启动 / 心跳不改写不落盘 / 心跳确认切换；相关窄测全绿；全量回归除预先存在的环境计时失败外无失败。

**原因分析**
- 门的累计模型（事件间隔计入活跃时间）假设生产事件流近似活跃时间；实际接线只在转换/提交/解锁时上报，持续输入在首个事件后静默，门无法确认。修复方向：在活跃轮询分支周期性喂门，同时保持"打开的同项目会话零写入"（活会话本就按设计不产生 journal 写入）。

**修改内容**
- `Sources/TinyBuddyCore/FocusSessionEngine.swift`：新增 `reportSustainedActivity(in:at:)`——按轮询节奏喂确认门；手动会话/无项目直接跳过；无打开会话时确认即 `startSession`；打开会话同项目为纯 no-op（不触碰 `lastUserActivityAt`/`lastStateChangeAt`，零写入）；不同项目走 `differentProjectActivity`（未确认仅累计，已确认按 away 边界切换）。
- `Sources/TinyBuddyCore/FocusSessionCoordinator.swift`：新增 `reportSustainedActivity(at:)`（复用 `focusProject()` 归属逻辑与排除门）。
- `Sources/TinyBuddy/FocusSessionAppBridge.swift`：`checkIdleState` 活跃（`!isNowIdle`）分支每轮询调用 `coordinator.reportSustainedActivity()`（与 `reportUserInput` 同风格，受 `isStopped` 防护）。
- `Tests/TinyBuddyCoreTests/FocusSessionConfirmationGateTests.swift`：新增 3 个确定性测试（生产喂入节奏：转换事件 + 15s 心跳）：`testConfirmationGate_heartbeatStartsSessionForContinuousTyping`（8 个心跳累计 120s 后会话在确认心跳时刻启动，先于首个事件的时间不计入）、`testConfirmationGate_heartbeatDoesNotMutateOrPersistOpenSession`（`.noChange`、`saveCount` 不变）、`testConfirmationGate_heartbeatConfirmsSwitchForContinuousTypingInNewProject`（9 个心跳累计 120s 后按 away 边界切换，away 间隔归属到达项目）。

**验证结果**
- 红→绿：新测试先以编译失败证明 API 缺失；修复后 3 个心跳测试全绿（过程中修正 2 处测试自身错误：门重置后首心跳只开始跟踪需 9 个心跳；B 活跃时长 = away 间隔 135s 属边界设计语义，非缺陷）。
- `swift test --filter 'FocusSessionEngineTests|FocusSessionCoordinatorTests|FocusSessionAppBridgeResetGateTests|FocusSessionDecisionTrackingTests'`：110 个测试 0 失败。
- `swift test` 全量：1598 个测试，仅**预先存在的环境计时失败**：`GitActivityRefreshScriptTests` 脚本超时墙钟断言（~6.5-7.4s > 4.0s 预算）2 个、`testWakeNotificationRetriesWhenFirstWakeRefreshCannotStart` 高负载下偶发 1 个；决定性证据：在**原始树**（`git stash` 暂存本次改动后）该脚本超时测试同样失败（7.4s），且脚本/测试文件自 `aec839c`（Loop 12 全量 1554 绿）以来未变；当前系统负载均值 4.47（WebKit/WindowServer/WeChat 高占用），属环境条件而非代码回归，与本次焦点会话改动零交集。
- `git diff --check`：通过；`git status --short` 复查：仅 4 个目标文件改动（+143），无越界；无用户在途修改。

**剩余风险**
- 全量门禁受本机当前高负载影响：脚本超时墙钟测试与 wake 重试测试在本机重负载下失败（原始树复现，预先存在）；负载回落或换机后应复跑 `swift test` 确认全绿。已记录"脚本超时测试 4.0s 墙钟断言环境敏感"候选，留待出现新证据（脚本或测试变更）时处理。
- 心跳节奏固定为轮询间隔（默认 15s），确认延迟 ≈ 默认最小活跃时长（120s），属确认门设计权衡；纯门语义未改动（未在 idle 时重置门，间隔计入活跃时间符合既有纯机语义与既有测试）。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`；`commitPendingSwitch`（`FocusSessionEngine.swift`）自 `72ac058` 起从未被调用（本次提交还给其死体加了确认门守卫），属既有死代码，可留作纯清理候选。
## Loop 17：2026-08-15：无修改轮次（在途“焦点识别解释”功能经独立审查、全量回归与本机签名安装运行验证通过）

**Loop 编号**
- Loop 17。

**日期**
- 2026-08-15

**观察结果**
- 工作区：`git status --short` 显示 4 个已修改文件 + 3 个未跟踪新文件——即“焦点识别解释”功能（未提交）：`Sources/TinyBuddyCore/FocusRecognitionExplanation.swift`（新增 166 行，纯展示解释器）、`Sources/TinyBuddyCore/FocusSessionEngine.swift`（+84：只读 accessors `confirmationGateSnapshot`/`confirmationCandidateProject`/`pendingSwitchCandidateProject`/`currentSessionMode`/`confirmationMinimumActiveDuration`/`mostRecentDecisionExplanation` + `confirmationCandidate` 展示态）、`Sources/TinyBuddy/PetViewModel.swift`（+32：`refreshFocusRecognitionExplanation` 纯读桥接）、`Sources/TinyBuddy/PetView.swift`（+112：FOCUS CONTROL 面板 info 按钮 + popover 展示）、`Tests/TinyBuddyCoreTests/FocusRecognitionExplanationTests.swift`（392 行，含两个测试类）、`Tests/TinyBuddyAppTests/PetViewModelFocusRecognitionTests.swift`（178 行）、`TinyBuddy.xcodeproj/project.pbxproj`（+4，新源文件注册）。用户/前一轮在途修改，本轮未覆盖或回滚。
- 最近提交：`167ce07`（Loop 16 记录）、`37e134b`（心跳喂确认门）；HEAD == origin/main。
- 依赖类型核实：`FocusSessionConfirmationGate`（`FocusSessionConfirmationGate.swift:20`）与 `FocusSessionDecisionExplanation`（`FocusSessionEvidence.swift:88`）均已在 HEAD 存在。
- `rg "TODO|FIXME|HACK|XXX"`：无真实待办（仅 `script/` 下 `mktemp` 模板 `XXXXXX`）；`git diff --check` 通过。
- 签名身份：本机唯一 Apple Development 身份（`C6B16796...`）。

**选择的问题及证据**
- 无。对在途“焦点识别解释”功能做独立静态审查，逐项核实通过：
  - 职责边界：`FocusRecognitionExplainer` 纯函数分类引擎已持有状态（gate 快照、会话、pendingSwitch、决策证据），不重算确认门决策；注释明确“gate 保持唯一权威”，无决策逻辑复制。
  - 引擎 accessor：全部在锁内读、值类型拷贝、只读；`mostRecentDecisionExplanation` 的“最新”比较（at 时间戳 → 会话序 → 事件序三级 tie-break）与事件流顺序一致（生命周期决策回填到会话边界，同时间戳按事件序裁决），遍历仅内存会话事件且按需调用，非高频路径。
  - `confirmationCandidate` 展示态：每次 gate 喂入（`recordConfirmation` 入口，含 `differentProjectActivity` 内部路径）先赋值再喂门，与 `gate.trackedProjectKey` 一致；gate `reset()` 后 `isTracking=false`，explainer 走 `notEntered` 分支不读候选，陈旧值不可达；注释明示“ignored whenever the gate is not tracking”，属文档化约定而非缺陷。
  - ViewModel 桥接：`refreshFocusRecognitionExplanation` 纯读（引擎 nil 时清空发布值，引擎存在时构造 Context 调 explainer，值相等不重复发布）；App 测试 `testOnDemandRefreshIsPureRead` 覆盖零变异。
  - UI：popover 按需打开时刷新，展示 title/detail/最近判断（脱敏解释原文复用），无新持久化、无新 Git 读取、无仓库路径泄漏。
  - pbxproj：xcodegen 重生成后 diff 仅 +4 行（新文件注册），无无关 churn。
- 既有候选（脚本 focus_block dead code、`page.last!`、`TinyBuddyTimeContext(...)!`、`precondition(!days.isEmpty)`、脚本超时墙钟断言环境敏感）：与 Loop 8/9/12/13/16 同根因，无新失败、新复现、新指标或新用户反馈，不重复处理。
- 完成标准：na（无修改轮次）。

**原因分析**
- 功能实现经 6 项静态审查点逐一核实 + 15 个窄测全绿 + 全量回归无新失败 + 本机签名安装运行验证通过，未发现真实可复现缺陷。按 loop.md 契约“无证据即无修改，不为了产生修改而修改”。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录并按 Maintain 归档最旧 1 条 Loop 7 至 `.agent/archive/history-2026-08-15.md`，属契约要求的 Record/Maintain 阶段）。

**验证结果**
- `swift test --filter 'FocusRecognition|PetViewModelFocusRecognition'`：15 个测试（核心 11 + App 4），0 失败。
- `swift test` 全量：1613 个测试（+15），仅 2 个**预先存在的环境性失败**：`GitActivityRefreshScriptTests` 脚本超时墙钟断言（`testScriptTimesOutSlowRepositoryMetadataAndRetainsItsLastValidResult` 7.49s > 4.0s、`testScriptTimesOutSlowRepositoryParsingAndRetainsItsLastValidResult` 7.26s > 4.0s）——Loop 16 已用原始树复现归因（脚本/测试自 `aec839c` 未变，本机负载环境条件），与本次纯展示层改动零交集。
- `script/tb-install.sh`（用户授权本机签名安装）：工程过期自动 `xcodegen generate` → Debug 构建成功 → Apple Development 签名（Widget + App + 嵌套）验证通过 → 安装 `/Applications/TinyBuddy.app` → 启动成功。
- 安装运行验证：运行中 App（PID 49668）executable 路径来自已安装 bundle；`codesign --verify --deep --strict` 通过；安装 bundle 与构建产物 MD5 一致（`61fb8001766a181eae89878817405154`）。
- `git diff --check`：通过；`git status --short` 复查：本轮改动仅 `.agent/` 记录/归档；在途功能改动原样保留，无越界修改。

**剩余风险**
- 全量门禁仍受本机环境负载影响：脚本超时墙钟测试在本机重负载下失败（预先存在，Loop 16 同述）；负载回落或换机后应复跑 `swift test` 确认全绿。
- 在途“焦点识别解释”功能尚未提交；用户已授权提交推送，随本轮一并处理。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`；`commitPendingSwitch` 死代码可留作纯清理候选；`DeterministicEndToEndFaultSimulationTests` 的 3.0s REPRO 窗口仍无新失败证据。

## Loop 18：2026-08-16：无修改轮次（自 Loop 17 以来业务代码零变化，未发现新的可验证问题）

**Loop 编号**
- Loop 18。

**日期**
- 2026-08-16

**观察结果**
- 工作区：`git status --short` 与 `git diff --check` 均无输出，仓库干净；`git stash list` 为空；HEAD == origin/main == `5520dfd`（Loop 17 记录提交）。
- 最近提交：`5520dfd`（Record Loop 17）、`b658efe`（Explain automatic focus recognition in HUD，+962）；两者均为 Loop 17 轮内提交（2026-08-15 10:39），自 Loop 17 以来业务代码零变化。
- 静态信号：Swift 中无 TODO/FIXME/HACK/XXX；无 `try!`/`fatalError`/XCTSkip；script 中 `mktemp` 模板（`XXXXXX`）为正常用法（grep 工具核实，约 50 处，含 `script/update_git_completion_count.sh` 33 处）。
- 测试基线：`swift test --filter GitCommandExecutorTests`：33 个测试全绿（环境健康检查）。
- 系统负载均值 4.71（仍偏高；Loop 16/17 归因的脚本超时墙钟测试环境失败条件仍存在）。

**选择的问题及证据**
- 无。既有候选逐一核对后均无新证据，淘汰理由：
  - 脚本 focus_block dead code/UTC 桶（Loop 8 有意设计）、`page.last!`、`TinyBuddyTimeContext(...)!`、`precondition(!days.isEmpty)`、`commitPendingSwitch` 死代码、脚本超时墙钟断言环境敏感、`DeterministicEndToEndFaultSimulationTests` 3.0s REPRO 窗口：与 Loop 8/9/12/13/16/17 同根因，无新失败、新复现、新指标或新用户反馈，不重复处理。
- Loop 17 记录的“在途焦点识别解释功能尚未提交”待办已闭环：`b658efe` + `5520dfd` 已提交（10:39）。
- 完成标准：na（无修改轮次）。

**原因分析**
- 自 Loop 17 以来唯一变化是记录提交（`.agent/` 基础设施），业务代码零变化；观察范围（工作区、提交历史、静态信号、窄测基线）内不存在触发新一轮的证据门槛。按 loop.md 契约“无证据即无修改，不为了产生修改而修改”。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录并按 Maintain 归档最旧 1 条 Loop 8 至 `.agent/archive/history-2026-08-16.md`，属契约要求的 Record/Maintain 阶段）。

**验证结果**
- `swift test --filter GitCommandExecutorTests`：33 个测试通过（基线，环境健康检查）。
- `git diff --check`：通过（history.md 追加与归档仅新增/移动行）。
- `git status --short` 复查：业务文件零改动；`.agent/` 下历史文件为本轮唯一新增。

**剩余风险**
- 本轮为无修改轮次，无新增风险。全量门禁仍受本机环境负载影响（脚本超时墙钟测试在重负载下失败，Loop 16 原始树复现归因；负载回落或换机后应复跑 `swift test` 确认全绿）。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`；`commitPendingSwitch` 死代码可留作纯清理候选；`DeterministicEndToEndFaultSimulationTests` 的 3.0s REPRO 窗口仍无新失败证据。

## Loop 19：2026-08-20：修复 Git 刷新脚本超时轮询未按配置秒数生效

**Loop 编号**
- Loop 19。

**日期**
- 2026-08-20

**观察结果**
- 起始工作区干净，HEAD == origin/main == `32f6cd4`；历史含 Loop 9–18 共 10 条记录。
- 静态检查：Swift/脚本无新的真实 TODO/FIXME/HACK/XXX；无 `try!`/`fatalError`；`git diff --check` 通过；`/bin/bash -n script/update_git_completion_count.sh` 通过。
- 窄测基线 `swift test --filter GitCommandExecutorTests`：33 个测试通过。
- 系统负载为 2.13；此前被 Loop 16/17 归因为高负载环境问题的两个超时测试在正常负载下仍失败：metadata 6.02s、parsing 5.90s，均超过 4s 断言。
- 独立复现中，配置 `TINYBUDDY_GIT_REPOSITORY_READ_TIMEOUT_SECONDS=1` 时慢 stat 探测只命中 1 次，但脚本耗时约 6s；`/bin/sleep 0.01` × 100 实测约 4.1s。

**选择的问题及证据**
- 选择 Git 刷新脚本 `run_command_with_timeout` 未按配置墙钟秒数超时这一错误处理/稳定性问题。
- 复现条件：任一有界命令持续运行，尤其慢仓库读操作或解析操作；旧逻辑以 `timeout_seconds * 100` 次轮询代替墙钟计时，实际超时显著超过配置值。
- 影响范围：慢仓库可能使默认 5s 读超时实际等待约 20–30s，默认 30s 解析超时实际等待更久；两个既有超时回归测试在正常负载下失败。
- 完成标准：按配置 deadline 终止命令；慢仓库仍保留有效仓库的 partial 结果；两个超时测试、相关测试、全量测试和 benchmark 通过。

**原因分析**
- 旧实现假设每次 `sleep 0.01` 都耗时 10ms，但当前 macOS 实测约 40ms；100 次轮询因此约 4s，叠加调度和清理后达到约 6s。根因是用名义轮询次数估算墙钟时间，而不是检查真实 deadline。

**修改内容**
- `script/update_git_completion_count.sh`：删除 `poll_count`/`poll_limit`，改为 `deadline=$((SECONDS + timeout_seconds))`，循环内按 `SECONDS` 判断超时；保持 TERM → 0.1s → KILL、返回码 124 和清理语义不变。
- 撤销方法：将上述函数恢复为 Loop 19 前的 `poll_count`/`poll_limit` 实现；历史记录撤销可从 `.agent/archive/history-2026-08-20.md` 移回 Loop 9 并删除本条。

**验证结果**
- `/bin/bash -n script/update_git_completion_count.sh`：通过。
- 真实脚本复现：修复前约 6.0s；修复后约 3.0s，`refresh_outcome=partial`、`retained_repository_count=1`；重复测量 1.0s、1.0s、2.0s。
- `swift test --filter 'GitActivityRefreshScriptTests/testScriptTimesOutSlowRepositoryMetadataAndRetainsItsLastValidResult|GitActivityRefreshScriptTests/testScriptTimesOutSlowRepositoryParsingAndRetainsItsLastValidResult'`：2 个测试通过。
- `swift test --filter 'GitActivityRefreshScriptTests|GitActivityRealRepositoryFixtureTests'`：85 个测试通过。
- `swift test`：1613 个测试通过，0 失败。
- `./script/benchmark_git_refresh.sh`：通过；24 repositories、100 events/repository、expected_events=2400，first=42351ms、incremental=18503ms、cancel=1001ms。
- 最终 `git diff --check`：通过；业务改动仅目标脚本。

**剩余风险**
- `SECONDS` 为整数秒计时，实际终止点可能比配置 deadline 晚不足 1 秒；当前所有超时配置均为整数秒，既有测试和 benchmark 已通过。
- 本轮未执行 App 安装/发布流程；改动仅限 Git 刷新脚本超时实现，不涉及签名、Widget 或安装状态。

## Loop 20：2026-08-28：复核 Git 刷新脚本超时修复，未发现新的可验证问题

**Loop 编号**
- Loop 20。

**日期**
- 2026-08-28

**观察结果**
- 工作区起始状态为 `.agent/history.md` 与 `script/update_git_completion_count.sh` 已修改，`.agent/archive/history-2026-08-20.md` 未跟踪；HEAD 与 `origin/main` 均为 `32f6cd4`。这些在途改动未覆盖或回滚。
- 当前 diff 显示 `run_command_with_timeout` 已从轮询次数改为 `SECONDS` deadline；Loop 19 已记录该问题与修复意图。
- `TODO|FIXME|HACK|XXX` 仅命中脚本 `mktemp` 的 `XXXXXX` 模板，未发现真实待办；归档目录已核对。

**选择的问题及证据**
- 无新的业务问题。当前唯一业务改动正是 Loop 19 已选定的 Git 刷新超时问题，本轮基于新执行结果复核其终态，不重复修改同一根因。
- 复核完成标准：脚本通过语法检查；慢 metadata/parsing 场景按配置超时并保留有效仓库的 `partial` 结果；相关测试、全量测试和 benchmark 通过。

**原因分析**
- 当前实现与 Loop 19 的根因分析一致：以实际 `SECONDS` deadline 替代依赖调度精度的固定轮询次数；本轮所有受影响验证均通过，未产生新的失败或回归证据。

**修改内容**
- 无业务代码修改；保留现有 `script/update_git_completion_count.sh` 在途改动原样。
- `.agent/history.md` 追加本轮记录；按 Maintain 规则将最旧的 Loop 10 原样归档至 `.agent/archive/history-2026-08-28.md`。
- 撤销方法：将归档文件中的 Loop 10 原样移回 `.agent/history.md`，删除本条 Loop 20 记录；不触碰既有脚本改动。

**验证结果**
- `/bin/bash -n script/update_git_completion_count.sh`：通过。
- `swift test --filter 'GitActivityRefreshScriptTests/testScriptTimesOutSlowRepositoryMetadataAndRetainsItsLastValidResult|GitActivityRefreshScriptTests/testScriptTimesOutSlowRepositoryParsingAndRetainsItsLastValidResult'`：2 个测试通过。
- `swift test --filter 'GitActivityRefreshScriptTests|GitActivityRealRepositoryFixtureTests'`：85 个测试通过。
- `swift test`：1613 个测试通过，0 失败。
- `./script/benchmark_git_refresh.sh`：通过；24 repositories、100 events/repository、expected_events=2400，first=36100ms、incremental=12648ms、cancel=1006ms。
- `git diff --check` 与最终 `git status --short` 在记录完成后复查。

**剩余风险**
- `SECONDS` 为整数秒计时，实际终止点可能比配置 deadline 晚不足 1 秒；当前整数秒配置、相关测试和 benchmark 均通过。
- 本轮未执行 App 安装/发布流程；既有脚本改动仍未提交，按规则不执行 commit。

## Loop 21：2026-09-15：恢复 Swift 6.4 下测试门禁的编译与签名契约夹具

**Loop 编号**
- Loop 21。

**日期**
- 2026-09-15。

**观察结果**
- 起始工作区含既有在途改动：`.agent/history.md`、`.agent/rules.md`、`AGENTS.md`、`CLAUDE.md`、`script/update_git_completion_count.sh`，以及两个未跟踪归档文件；本轮未覆盖或回滚。
- HEAD 与 `origin/main` 为 `bb7f219`，最新提交要求 macOS 15+ 的 signed Widget 构建同时具备 App/Widget provisioning profiles 和预期 App Group。
- 首次运行 `swift test --filter 'BuildAndRunScriptTests|WidgetConfigConsistencyTests|ReleaseSigningAndWidgetContractTests'` 未进入测试：Swift 6.4 严格并发检查拒绝 `FocusSessionQueryPerformanceTests` 中跨 `Task` 写入 `canonicalIDs`；修正后又暴露 `TinyBuddyInstanceCoordinatorTests` 两个测试类中跨 `@MainActor Task` 写入角色变量的同类编译错误。
- 编译门禁恢复后，签名契约测试仍有 1 个失败：`ReleaseSigningAndWidgetContractTests` 的 signed 夹具未提供嵌入 provisioning profile，无法满足最新提交新增的 profile 校验。
- `TODO|FIXME|HACK|XXX` 未发现真实待办；三份相关脚本语法检查和 `git diff --check` 通过。

**选择的问题及证据**
- 选择“当前 Swift/Xcode 测试门禁无法完整编译并验证最新签名契约”这一测试稳定性问题。
- 复现条件：使用当前 Xcode 27 / Swift 6.4 执行受影响测试；严格区域隔离报错会在测试目标编译阶段阻断测试，随后 signed 契约夹具因缺少 profile 失败。
- 影响范围：无法运行焦点查询性能、实例协调器以及最新 Widget/App Group 签名契约测试，导致提交后的回归信号不可用。
- 完成标准：受影响测试不再依赖不安全的跨任务可变捕获；signed 夹具提供可验证的 App/Widget profile；相关测试全部通过，生产代码不变。

**原因分析**
- Swift 6.4 对 `Task` 的 sending/region-isolation 检查比原测试写法严格，旧测试通过 `Task` 回写局部变量并在外部读取，无法编译。
- `bb7f219` 在 `verify_code_signing_contract` 中新增了 embedded provisioning profile 和 App Group 校验，但既有 signed 测试只模拟了 `codesign` 输出，没有同步模拟 profile 解码链路。

**修改内容**
- `Tests/TinyBuddyCoreTests/FocusSessionQueryPerformanceTests.swift`：将排序稳定性测试改为 `async throws`，直接 `await` 三次查询，移除跨任务回写和等待。
- `Tests/TinyBuddyAppTests/TinyBuddyInstanceCoordinatorTests.swift`：将两个使用 `@MainActor Task` 的实例协调器测试类标为 `@MainActor`，使角色变量和任务处于同一隔离域。
- `Tests/TinyBuddyAppTests/ReleaseSigningAndWidgetContractTests.swift`：signed 夹具新增 App/Widget embedded profile、`security`/`PlistBuddy` 确定性桩，并接入 `verify_provisioned_app_group`；local 夹具仍保持 profile-free 场景。

**验证结果**
- `swift test --filter FocusSessionQueryPerformanceTests`：8 个测试通过。
- `swift test --filter 'BuildAndRunScriptTests|WidgetConfigConsistencyTests|ReleaseSigningAndWidgetContractTests'`：79 个测试通过。
- `swift test --filter 'FocusSessionQueryPerformanceTests|TinyBuddyInstanceCoordinatorTests|TinyBuddyInstanceCoordinatorCrossProcessTests|ReleaseSigningAndWidgetContractTests'`：29 个测试通过。
- `/bin/bash -n script/update_git_completion_count.sh`、`/bin/bash -n script/build_and_run.sh`、`/bin/bash -n script/tb-install.sh`：通过。
- `git diff --check`：通过；最终检查确认既有在途改动仍保留，新增改动仅限上述 3 个测试文件。

**剩余风险**
- 按测试-only 低影响改动采用 Focused 验证级别，未重复运行完整 `swift test`；未覆盖测试类仍可能包含与当前 Swift 6.4 无关的既有失败。
- 未执行 App 安装、发布或替换已安装产物；本轮未修改生产代码、签名配置或安装状态。
