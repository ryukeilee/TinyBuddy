# Maintenance Loop History

用于记录每一次 Maintenance Loop 的结果。请按 `.agent/loop.md` 的 Record 阶段追加条目，并按 Maintain 阶段维护本文件：

- 本文件始终保留最近约 10 条轮次记录。
- 当条目数超过 10 条时，最旧的条目原样移动到 `.agent/archive/` 目录下的归档文件（如 `history-YYYY-MM-DD.md`；不存在则创建，头部注明用途与归档时间）；归档条目不丢失、不改写。
- 观察与决策阶段核对历史时，同时读取本文件与 `.agent/archive/` 归档，避免重复处理已完成的问题。



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

## Loop 22：2026-09-19：修复 Widget 注册回滚测试夹具缺少新函数依赖

**Loop 编号**
- Loop 22。

**日期**
- 2026-09-19。

**观察结果**
- 起始工作区干净，`HEAD == origin/main == d5485cd`；最近提交 `d5485cd`（`Clean release candidate Widget registration`）新增了 `unregister_release_candidate_widget_registration` 并在 `install_release_app` / `verify_release_app_fresh` 前置调用，提交未同步更新 `ReleaseSigningAndWidgetContractTests` 的函数抽取夹具。
- `rg "TODO|FIXME|HACK|XXX"` 仅命中 `mktemp` 的 `XXXXXX` 模板，无真实待办；`/bin/bash -n script/build_and_run.sh` 与初始 `git diff --check` 通过。
- 首次运行 `swift test --filter 'BuildAndRunScriptTests|ReleaseSigningAndWidgetContractTests|WidgetConfigConsistencyTests'`：79 个测试中 4 个失败；两个 clean-install 回滚/注册失败测试均出现 `/bin/bash: ... unregister_release_candidate_widget_registration: command not found`，证明失败来自测试夹具未提供新 helper，而非产品断言。

**选择的问题及证据**
- 选择“Widget 注册回滚测试夹具未跟随生产脚本新增函数依赖更新”这一测试稳定性问题。
- 复现条件：运行上述 79 个受影响测试；`install_release_app` 已调用新 helper，但两个测试只抽取旧函数集合，`set -euo pipefail` 下直接以命令不存在退出，掩盖了实际回滚行为。
- 影响范围：Widget/Release 注册回滚测试门禁不可用；完成标准是两个夹具抽取新 helper 及其必需的 `find_widget_extension`/`WIDGET_EXTENSION_NAME` 输入后，相关测试恢复通过且生产代码不变。

**原因分析**
- `d5485cd` 的脚本依赖图新增了 helper，但测试通过 `shellFunction(named:)` 手工抽取函数，未同步新增依赖；首个夹具在补 helper 后还暴露了 `find_widget_extension` 依赖所需的 `WIDGET_EXTENSION_NAME` 未初始化。

**修改内容**
- `Tests/TinyBuddyAppTests/ReleaseSigningAndWidgetContractTests.swift`：
  - clean-install activation failure 夹具抽取 `find_widget_extension` 与 `unregister_release_candidate_widget_registration`，并设置 `WIDGET_EXTENSION_NAME`；保留其 `registered_widget_paths` fake 实现。
  - stale-registration failure 夹具抽取 `unregister_release_candidate_widget_registration`，使现有的 fake `find_widget_extension` 继续生效。

**验证结果**
- 修复前：`swift test --filter 'BuildAndRunScriptTests|ReleaseSigningAndWidgetContractTests|WidgetConfigConsistencyTests'` 复现 79 个测试中 4 个失败。
- 修复后：两个针对性 `ReleaseSigningAndWidgetContractTests` 通过（2 个，0 失败）。
- 修复后完整受影响筛选：`swift test --filter 'BuildAndRunScriptTests|ReleaseSigningAndWidgetContractTests|WidgetConfigConsistencyTests'` 79 个测试通过，0 失败。
- `/bin/bash -n script/build_and_run.sh`：通过；`git diff --check`：通过。
- 最终工作区检查确认仅测试文件与本轮 `.agent/` 记录/归档发生改动。

**剩余风险**
- 本轮为测试夹具修复，未重复运行完整 `swift test`，也未执行会改变外部状态的 App 安装、发布或替换流程。
- 生产脚本 `d5485cd` 本身沿用已有发布测试/签名约束覆盖；若后续再新增 shell helper，函数抽取型夹具仍需同步更新依赖集合。

## Loop 23：2026-09-19：修复资源采样探针把 rusage 缓冲写进栈上指针变量导致崩溃与零计数

**Loop 编号**
- Loop 23。

**日期**
- 2026-09-19

**观察结果**
- 起始工作区含 Loop 22 遗留改动（`Tests/TinyBuddyAppTests/ReleaseSigningAndWidgetContractTests.swift`、`.agent/history.md`、未跟踪的 `.agent/archive/history-2026-09-19.md`），本轮未覆盖或回滚；HEAD == origin/main == `d5485cd`，自 Loop 22 以来无新提交。
- 环境：Swift 6.4 / Xcode 27（arm64），负载均值约 2.3–4.4；`rg "TODO|FIXME|HACK|XXX"` 仅命中 `mktemp` 模板，无真实待办；`git diff --check` 通过。
- `./script/swiftpm.sh test` 全量（Loop 21/22 均未执行过）首次暴露确定性失败：`TinyBuddyAppTests.ResourceStabilityScriptTests.testProbeProcessReturnsCumulativeDarwinCountersForCurrentProcess`（App 616 个测试中 3 个断言失败，两次全量运行结果一致），报错 `resource probe failed for PID ...: `（探针无输出、非零退出）。

**选择的问题及证据**
- 选择“资源采样探针 `script/process_resource_probe.swift` 把指针变量地址而非采样缓冲地址交给 `proc_pid_rusage`，导致内核写入栈上（SIGABRT）且只能读到全零计数”这一数据正确性/稳定性问题（Loop 优先级第 3、2 位）。
- 复现条件（确定性）：`./script/verify_resource_stability.sh --probe-process <pid>` 无输出并 exit 1；裸二进制（`swiftc script/process_resource_probe.swift -o probe && ./probe <pid>`）稳定 `Abort trap: 6`（exit 134，无 stderr）。lldb 显示 SIGABRT 发生在 `proc_pid_rusage` 返回之后（栈金丝雀）；把同一调用改为写入 4096 字节堆缓冲仍然崩溃，排除缓冲过小；对照实验中把 `withMemoryRebound` 传入真实缓冲地址后立即返回真实计数。
- 影响范围：`script/verify_resource_stability.sh` 的 `probe_process`/`record_sample` 在 `set -e` 下首次采样即失败退出，可选资源稳定性验证器不可用；`script/regression_gate.sh` 用 `|| echo "0,0,0,0"` 吞掉探针失败，即使不崩溃也只能得到全零计数，使 disk-read 与 interrupt/idle wakeup 预算成为空检查（既有测试仅校验 4 个字段可解析为数字，全零可以通过）。
- 完成标准：探针把 rusage 结果写回自身采样缓冲并返回真实计数；`ResourceStabilityScriptTests` 全绿；测试新增“解析后的 `cpu_time_ns` 必须大于 0”断言，使静默全零无法再通过；全量 `swift test` 0 失败。

**原因分析**
- libproc 的 `int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer)` 声明为 `void **`，但内核把第三个参数当作出参缓冲地址。原实现先把 `&usage` 转成 `rusage_info_t?` 存进局部变量 `usagePointer`，再把 `&usagePointer`（指针变量自身的地址）交给内核；内核把 296 字节的 `rusage_info_v4` 写进该栈槽位，越过栈金丝雀触发 SIGABRT，而在未触发崩溃的布局下读到的 `usage` 仍是零初始化值，故计数恒为 0。改为直接传入采样缓冲地址后，`ri_user_time`/`ri_system_time` 等字段返回真实值。

**修改内容**
- `script/process_resource_probe.swift`：删除中间指针变量，改为 `withUnsafeMutablePointer(to: &usage)` + `withMemoryRebound(to: rusage_info_t?.self, capacity: MemoryLayout<rusage_info_v4>.size / MemoryLayout<rusage_info_t?>.size)` 直接传入采样缓冲地址，并加注释说明该 API 的实参语义；错误处理、字段拼接与 CSV 输出不变。
- `Tests/TinyBuddyAppTests/ResourceStabilityScriptTests.swift`：`testProbeProcessReturnsCumulativeDarwinCountersForCurrentProcess` 在既有断言之外新增解析后的 4 个计数与 `cpu_time_ns > 0` 断言（仅强化，未削弱既有断言）。

**验证结果**
- 修复前（仅加断言）：`./script/swiftpm.sh test --filter ResourceStabilityScriptTests` 复现 13 个测试 5 个失败，含 `resource probe failed for PID 63061` 与 `XCTAssertGreaterThan failed: ("0") is not greater than ("0")`。
- 修复后：`./script/swiftpm.sh test --filter ResourceStabilityScriptTests` 13 个测试 0 失败。
- 真实进程采样：`./script/verify_resource_stability.sh --probe-process <sleep pid>` 输出表头 + `58154,0,0,0`，exit 0（修复前为无输出 + exit 1）。
- `/bin/bash -n script/verify_resource_stability.sh`、`/bin/bash -n script/regression_gate.sh`：通过。
- `./script/swiftpm.sh test` 全量：TinyBuddyCoreTests 1009 + TinyBuddyAppTests 616 = 1625 个测试，0 失败（修复前同一命令为 3 个失败）。
- `git diff --check`：通过；`git status --short` 复查：本轮业务改动仅上述 2 个文件，Loop 22 改动原样保留，无越界修改。

**剩余风险**
- `script/regression_gate.sh` 仍以 `"$PROBE_BINARY" "$app_pid" 2>/dev/null || echo "0,0,0,0"` 静默吞掉探针失败并回退到全零样本，使资源预算在探针失效时产生空洞通过（本轮已验证的新证据，留待下一轮按单一问题处理）。
- 本轮未运行 `./script/verify_resource_stability.sh` 完整 600 秒流程与 `./script/regression_gate.sh`（需构建并长时间采样本地 App），故修复只在单测与单次真实进程采样层面验证；采样与预算评估逻辑未改动。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`；`commitPendingSwitch` 死代码可留作纯清理候选。

## Loop 24：2026-09-22：修复回归门禁资源阶段在探针失败时伪造全零采样（空洞通过）

**Loop 编号**
- Loop 24。

**日期**
- 2026-09-22。

**观察结果**
- 工作区：`git status --short` 无输出，干净；HEAD == `cbf42ef`（Scope repository-change refresh to affected repositories），与 `origin/main` 一致；自 Loop 23 以来无新提交（Loop 23 的探针修复已随 `f34eeaa` 落地）。
- 读取 `.agent/loop.md`、`.agent/rules.md`、`.agent/memory.md`、`.agent/history.md`（10 条：Loop 14–23）与 `.agent/archive/`。Loop 23 在「剩余风险」留下两条未处理项：(a) `script/regression_gate.sh` 用 `"$PROBE_BINARY" "$app_pid" 2>/dev/null || echo "0,0,0,0"` 吞掉资源探针失败并回退全零样本；(b) 完整 600 秒 `verify_resource_stability.sh` 与 `regression_gate.sh` 尚未真实运行。
- `rg "TODO|FIXME|HACK|XXX" script Tests Sources Widget`：仅 `mktemp` 模板命中，无真实待办；`git diff --check` 通过。
- 环境：Swift 6.4 / Xcode 27（arm64）；当前运行中的 TinyBuddy 来自 `/Applications/TinyBuddy.app`（pid 1322），本工作树 `.build/xcode` 不存在。
- 候选核对：`script/regression_gate.sh:run_resource_monitor` 有两处探针采样（warm 基线、监控循环），均在探针失败时注入 `0,0,0,0`；`evaluate_resource_budgets` 只用 `$8+0`… 计算 delta 与每分钟唤醒率，全零样本必然得到 `diskDelta=0`、`interrupt/idle wakeups=0/min` → `PASS`。姊妹脚本 `verify_resource_stability.sh` 的 `probe_process`/`record_sample` 在探针失败时直接中止，两者行为不一致。候选 (b) 属验证债务而非缺陷，按契约不单独处理（保留在本轮剩余风险）。

**选择的问题及证据**
- 选择「`script/regression_gate.sh` 的资源阶段在 Darwin rusage 探针失败时伪造全零采样，使 disk-read 与 interrupt/idle wakeup 预算空洞通过」这一问题（Loop 优先级第 2 位稳定性风险 + 第 5 位错误处理问题；同时是本仓库规则明确禁止的「隐藏错误、吞掉失败」）。
- 复现条件（确定性，不需要真实 App）：用 `sed -n '1,/^# Entry point$/p'` 取出未修改的 stage 代码到临时文件，桩化 `PS_BIN`（`comm=` 打印 `fake-app-binary`，其余打印 `1000 0.0`）、`PROBE_BINARY`（stderr 打印模拟 rusage 失败并 `exit 1`），用自建 `/bin/sleep 60` 进程 + `APP_NAME=sleep` 满足 `pgrep -x`，`RESOURCE_DURATION=1`，然后调用 `run_resource_monitor`。
  - 修复前（HEAD 的 stage 代码）：`>>> PASS: resource-monitor`、`OVERALL_STATUS=0`；采样 CSV 为 `10,1000,0.0,0,1,warm,0,0,0,0` 与 `20,1000,0.0,0,1,sample,0,0,0,0` —— 探针完全失败仍 PASS。
  - 修复后（source 真实脚本的同一 harness）：`>>> FAIL: resource-monitor — resource probe unavailable for PID ...`、`OVERALL_STATUS=1`、CSV 仅剩表头（无任何伪造样本行）。
- 影响范围：`script/regression_gate.sh` 的 `--stage 5`、`--quick` 与默认全量运行的 resource-monitor 阶段。探针一旦失效（Loop 23 已实证 `proc_pid_rusage` 崩溃过），磁盘读与系统唤醒预算成为空洞通过，能量/资源回归不会被门禁发现。
- 完成标准：探针失败或输出格式不合法时该阶段必须 fail closed（不写任何伪造的全零采样）；新增测试在修复前失败、修复后通过。

**原因分析**
- `run_resource_monitor` 用 `... 2>/dev/null || echo "0,0,0,0"` 同时丢弃了探针 stderr 与其失败状态，把「无法测量」伪装成「测量值为 0」；`evaluate_resource_budgets` 只把字段做数值化（`$8 + 0`），因此全零样本必然满足 disk-read 上限（`0 <= 67108864`）与 wakeup 上限（`0/min <= 600`），形成空洞通过。该脚本此前没有任何自动化测试，两处采样点重复且无输出校验。
- 正确的失败语义在姊妹脚本中已经存在（`verify_resource_stability.sh:probe_process` 校验 4 个非负整数字段并在失败时中止），本仓库规则也要求保留失败的可见性；缺的是把该语义落到回归门禁上。

**修改内容**
- `script/regression_gate.sh`：
  - 新增 `probe_counters()`：调用探针并对输出用 `awk` 校验「恰好 4 个非负整数字段」，失败时向 stderr 打印 `resource probe failed for PID ...`（含探针自身诊断）或 `resource probe returned malformed counters for PID ...` 并返回 1（与 `verify_resource_stability.sh:probe_process` 同语义）。
  - `run_resource_monitor` 的 warm 基线与监控采样两处改为 `if ! probe_raw="$(probe_counters "$app_pid")"; then stage_fail "resource probe unavailable for PID $app_pid; disk read and wakeup budgets cannot be evaluated"; return "$STAGE_FAIL"; fi`，删除 `|| echo "0,0,0,0"` 兜底。
  - 入口处新增 sourced 守卫 `if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi`，使测试能直接 source 脚本调用 stage helper（执行脚本时 CLI 行为完全不变）。
- `Tests/TinyBuddyAppTests/RegressionGateScriptTests.swift`（新增，6 个测试）：source 脚本不触发 CLI；`probe_counters` 接受合法计数、拒绝探针失败、拒绝字段缺失/非数字；resource-monitor 在探针失败时 fail closed（桩化 ps/probe + 自建 stand-in 进程，断言 FAIL、`OVERALL_STATUS=1`、采样文件仅剩表头）；脚本不再包含 `"0,0,0,0"` 兜底。

**验证结果**
- `./script/swiftpm.sh test --filter RegressionGateScriptTests`：6 个测试，0 失败。
- `./script/swiftpm.sh test --filter 'RegressionGateScriptTests|ResourceStabilityScriptTests'`：19 个测试，0 失败（含姊妹脚本 13 个既有测试，确认 `process_resource_probe.swift` 与预算契约未变）。
- `/bin/bash -n script/regression_gate.sh`：通过；`bash script/regression_gate.sh --list-stages`、`--help`、`--stage 0`（exit 2）确认执行路径与参数校验未变。
- 修复前后 harness 证据见上（同一 harness，`PASS` → `FAIL`）；`git show HEAD:script/regression_gate.sh | grep -n '0,0,0,0'` 为 2 处，修复后 `grep` 无匹配。
- `git diff --check`：通过；`git status --short`：仅 `script/regression_gate.sh`（修改）与 `Tests/TinyBuddyAppTests/RegressionGateScriptTests.swift`（新增）。
- 验证级别：按 `AGENTS.md` 取 **Focused**。本改动是脚本层局部实现改动，不触及共享契约、持久化、跨进程边界或 App/Widget 共享状态，故运行直接受影响的测试类、脚本语法检查与最小真实路径检查；未运行 `swift test` 全量（生产 Swift 代码与既有测试断言未变，Loop 23 在 `f34eeaa`/`cbf42ef` 基线有 1625 测试 0 失败的证据，新增测试类已在窄测中编译并全绿）。

**剩余风险**
- 未真实运行 `./script/regression_gate.sh --stage 5` / `--quick`：该路径会 `teardown_app`（`pkill -x TinyBuddy`）并启动 Debug 构建，而本机运行中的 TinyBuddy 来自 `/Applications/TinyBuddy.app`（pid 1322）；为避免终止用户已安装运行的 App 并引入无授权的外部状态变更，本轮用桩化 harness 覆盖 stage 逻辑，未做端到端门禁运行（Loop 23 的 (b) 仍未闭环）。
- 同一函数内的第二个空洞通过点（本轮不作为单一问题）：`evaluate_resource_budgets` 接收 `-v cpuCap`/`-v cpuSamples`，但其 AWK 从不使用这两个变量，`TINYBUDDY_GATE_SUSTAINED_CPU_PERCENT`（默认 15）实际上从未参与判定（证据：`grep -n "cpuCap\|cpuSamples" script/regression_gate.sh` 仅命中定义与 `-v` 传参处）；持续 CPU 预算留待后续轮次。
- `evaluate_resource_budgets` 本身仍不校验表头与字段数字性（本轮由 `probe_counters` 在上游拦截非法输出），若未来出现绕过采样入口的输入，仍需补强。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。

## Loop 25：2026-09-22：修复回归门禁持续 CPU 预算从未参与判定（空洞通过）

**Loop 编号**
- Loop 25。

**日期**
- 2026-09-22。

**观察结果**
- 工作区：`git status --short` 无输出，干净；HEAD == `67e6b0d`（Loop 24 的提交，Coordinator 已 fast-forward 到 `main` 并推送），当前分支 `hp/tinybuddy/t-0004-loop-24` 与 `main` 一致，无需 rebase/merge。
- 读取 `.agent/loop.md`、`.agent/rules.md`、`.agent/memory.md`、`.agent/history.md`（10 条：Loop 15–24）与 `.agent/archive/`。Loop 24 记录中列为候选 (2) 的问题即本轮任务首选；候选 (1)（端到端跑 `--quick`/`--stage 5`）按本轮任务约束仍不执行，候选 (3)（`evaluate_resource_budgets` 不校验表头与字段数字性）无新证据、留待后续轮次。
- `rg "TODO|FIXME|HACK|XXX" script Tests Sources Widget`：仅 `mktemp` 模板命中，无真实待办；`git diff --check` 通过。
- 候选核对（`script/regression_gate.sh`）：`SUSTAINED_CPU_PERCENT`/`SUSTAINED_CPU_SAMPLES` 在 L83–86 定义为「Resource stability: sustained CPU percent / consecutive samples」，并作为 `-v cpuCap`/`-v cpuSamples` 传入 `evaluate_resource_budgets`（L545–546），但其 AWK 程序体内除 `-v` 传参与 `cpuTime` 暂存外再无任何引用 —— 该预算从不参与判定；`warmCPUTime`/`finalCPUTime` 被赋值后闲置。姊妹脚本 `verify_resource_stability.sh:399` 有完整实现（`cpuRun` 连续计数 + `cpuRate >= cpuCap` 判定），两者语义不一致。环境：Swift 6.4 / Xcode 27（arm64）。

**选择的问题及证据**
- 选择「`script/regression_gate.sh:evaluate_resource_budgets` 的持续 CPU 预算恒不生效，使 `TINYBUDDY_GATE_SUSTAINED_CPU_PERCENT`（默认 15、连续 3 个采样窗口）成为空洞通过」这一问题（Loop 优先级第 4 位性能问题 + 第 5 位错误处理问题；与 Loop 24 同属门禁空洞通过但根因不同：Loop 24 是采样数据被伪造，本轮是预算判定整体缺失，因此不是重复问题）。
- 复现条件（确定性，不需要真实 App）：source 门禁脚本后直接调用 `evaluate_resource_budgets`（Loop 24 加入的 source 守卫使该调用可行），喂入「warm + 3 个采样窗口」的 CSV，每个窗口的累计 CPU 时间增量为 10s 内 2s CPU（即 20%），并设 `TINYBUDDY_GATE_SUSTAINED_CPU_PERCENT=15`、`TINYBUDDY_GATE_SUSTAINED_CPU_SAMPLES=3`。
  - 修复前（HEAD 的 AWK）：`RSS delta=0KB threads delta=0 disk=0bytes interrupt_wakeups=0.0/min idle_wakeups=0.0/min` + `PASS`，exit 0 —— 20% 持续超过 15% 预算仍被放过。
  - 修复后：`sustained CPU 20% for 3 samples;`，exit 1。
- 影响范围：`script/regression_gate.sh` 的 resource-monitor 阶段（`--stage 5`、`--quick` 与默认全量运行）；任何持续 CPU 回归（忙等、轮询加剧、快照/Widget 反复重算）都不会被门禁发现，该阶段的能量预算实际只覆盖 RSS/线程/磁盘/唤醒四项。
- 完成标准：持续 CPU 预算按与 `verify_resource_stability.sh` 相同的语义参与判定（由累计 CPU 时间导出的窗口速率、连续 N 个窗口达到预算即失败）；新增测试在修复前失败、修复后通过。

**原因分析**
- `evaluate_resource_budgets` 只实现了 RSS delta、线程 delta、disk delta 与 interrupt/idle wakeup 速率四项判定，AWK 程序从未使用 `cpuCap`/`cpuSamples`。常量定义、注释与 `-v` 传参齐备，造成「该预算已实现」的假象，实际判定缺失。姊妹脚本 `verify_resource_stability.sh` 早在 `99e9422` 就实现了同一预算，回归门禁由 `55415f2` 复制该 AWK 时漏掉了这一段，且脚本此前无任何自动化测试，漏项无从暴露。

**修改内容**
- `script/regression_gate.sh`（`evaluate_resource_budgets` 的 AWK，纯新增 15 行，不改动既有四项判定）：
  - warm 行记录 `previousSampleElapsed = warmElapsed`、`previousSampleCPUTime = warmCPUTime`，并置 `havePreviousSample = 1`；
  - 每个 warm 之后的行按 `cpuRate = (cpuTime - previousSampleCPUTime) * 100 / ((elapsed - previousSampleElapsed) * 1000000000)` 计算窗口速率；`cpuRate >= cpuCap` 时 `cpuRun++`，否则 `cpuRun = 0`；`cpuRun >= cpuSamples` 时 `fail("sustained CPU " cpuRate "% for " cpuRun " samples")`（与 `verify_resource_stability.sh` 完全一致，含 `>=` 边界语义）。
- `Tests/TinyBuddyAppTests/RegressionGateScriptTests.swift`：新增 5 个测试（超预算 20%/3 窗口 → 失败；10% → 通过；20% 后回落到 10% → 连续计数清零、通过；恰好 15% → 失败（边界与姊妹脚本一致）；`TINYBUDDY_GATE_SUSTAINED_CPU_PERCENT`/`_SAMPLES` 覆盖生效）。

**验证结果**
- 修复前/后同一 harness（仅替换 source 的门禁脚本）：20%/3 窗口 `PASS`(exit 0) → `sustained CPU 20% for 3 samples;`(exit 1)；10%/3 窗口两态均 `PASS`；20%→10%→10% 两态均 `PASS`（无单窗口误报）；恰好 15% `PASS` → `FAIL`（`>=` 语义）。
- 覆盖项实测：`TINYBUDDY_GATE_SUSTAINED_CPU_PERCENT=50` 时 20% 通过；`_SAMPLES=1` 时单窗口即失败；`_SAMPLES=4` 时 3 窗口通过；`TINYBUDDY_GATE_DISK_READ_DELTA_BYTES=100` 时 101 字节仍失败（既有预算未被破坏）。
- `./script/swiftpm.sh test --filter RegressionGateScriptTests`：11 个测试，0 失败（Loop 24 的 6 个 + 本轮新增 5 个）。
- `./script/swiftpm.sh test --filter 'RegressionGateScriptTests|ResourceStabilityScriptTests'`：24 个测试，0 失败（姊妹脚本 13 个既有测试未变动，确认其探针与预算契约不受影响）。
- `/bin/bash -n script/regression_gate.sh` 通过；`--list-stages`、`--help`、`--stage 0`（exit 2）确认执行路径与参数校验未变。
- `git diff --check` 干净；`git status --short` 仅 `script/regression_gate.sh`（修改）与 `Tests/TinyBuddyAppTests/RegressionGateScriptTests.swift`（修改，同文件追加测试）。
- 验证级别：按 `AGENTS.md` 取 **Focused**。改动是脚本层纯新增判定 + 同目标测试类扩展，不触及共享契约、持久化、跨进程边界或 App/Widget 共享状态；未运行 `swift test` 全量（生产 Swift 代码与既有测试断言未变，Loop 23/24 在同一代码基线的全量 0 失败证据输入未变，本轮新增测试已在窄测中编译并全绿）。

**剩余风险**
- 新启用的阈值未在真实 Debug App 上端到端校准：门禁采样间隔为 10s（`RESOURCE_DURATION` 默认 60 → 约 6 个窗口），姊妹脚本默认 30s；若真实 Debug App 冷启动后的采样窗口持续超过 15%，门禁会在阈值层面失败（属阈值问题而非缺陷），调整路径是既有的 `TINYBUDDY_GATE_SUSTAINED_CPU_PERCENT`/`TINYBUDDY_GATE_SUSTAINED_CPU_SAMPLES` 覆盖。本轮未运行 `--stage 5`/`--quick`，故该阈值未经真实运行验证。
- Loop 24 候选 (1) 仍未闭环：未端到端运行 `--stage 5`/`--quick`（会 `pkill -x TinyBuddy` 终止本机已安装运行的 App 并构建启动 Debug App，属仓库外可见状态变更）。
- Loop 24 候选 (3) 仍未处理：`evaluate_resource_budgets` 不校验表头与字段数字性；CPU 判定沿用 `$7 + 0` 数值化，非数字字段会退化为 0 速率。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）；Loop 23 的完整 600 秒 `verify_resource_stability.sh` 仍未真实运行。
