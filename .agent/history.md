# Maintenance Loop History

用于记录每一次 Maintenance Loop 的结果。请按 `.agent/loop.md` 的 Record 阶段追加条目，并按 Maintain 阶段维护本文件：

- 本文件始终保留最近约 10 条轮次记录。
- 当条目数超过 10 条时，最旧的条目原样移动到 `.agent/archive/` 目录下的归档文件（如 `history-YYYY-MM-DD.md`；不存在则创建，头部注明用途与归档时间）；归档条目不丢失、不改写。
- 观察与决策阶段核对历史时，同时读取本文件与 `.agent/archive/` 归档，避免重复处理已完成的问题。

## Loop 6：2026-08-09：建立 Evidence-driven Maintenance Loop 基础设施（memory.md + 归档目录）

**Loop 编号**
- Loop 6（本文件第 6 条记录；既有 5 条记录未编号，本轮起按 Record 契约显式编号）。

**日期**
- 2026-08-09

**观察结果**
- 现有 `.agent/` 体系（loop.md/rules.md/history.md）已运行多轮，但对照"Evidence-driven Maintenance Loop"目标存在结构性缺口：
  - `memory.md` 不存在；loop.md 入口与 Observe 阶段未要求读取长期项目知识。
  - Decide 优先级为 6 级旧版（Bug/稳定性/性能/错误处理/测试缺口/用户体验），缺"数据正确性风险"与"可维护性问题"。
  - Record 字段缺"Loop 编号"与"观察结果"。
  - 归档位置约定为 `.agent/history-archive.md`，与目标要求的 `.agent/archive/` 目录不一致。
  - rules.md 禁止清单未显式列出"删除用户数据/修改凭证"。
- 工作区干净（`git status --short` 无输出）；仓库基线（Swift 6.0/macOS 14、SwiftPM + XcodeGen、XCTest 双测试目录、TinyBuddyCore 职责边界、组合快照唯一真相、时间模型）经 `Package.swift`、根级 `AGENTS.md`/`CLAUDE.md` 与 loop.md 项目基线核实。
- 已核实无其他可复用维护体系：`.agents/`、`.codex/`、`.pi/`、`skills/` 为空或仅承载空 skills 目录；`.opencode/` 仅含 opencode 自身运行时状态。

**选择的问题及证据**
- 选择"完善 `.agent/` 维护体系基础设施"：本次为纯文档设施建立，不进入代码修改路径。
- 证据：loop.md 入口文本为"先读取本文件和 `.agent/rules.md`"（无 memory.md）；Decide 优先级列表原文为 6 级；Record 字段列表原文 6 项（无 Loop 编号/观察结果）；loop.md/rules.md/history.md 契约文本中的 8 处 `.agent/history-archive.md` 引用与目标归档目录要求不一致；rules.md 禁止清单原文无"删除用户数据/修改凭证"。
- 完成标准：四个文件自洽、六阶段硬性检查齐备、归档引用统一指向 `.agent/archive/`、业务文件零改动。

**原因分析**
- 目标要求长期可维护的 Evidence-driven Loop：Observe 必须先读 rules/memory/history，Decide 需覆盖数据正确性与可维护性两类风险，Record 需要跨轮追踪编号，历史需要受控归档。现有体系缺 memory 层与这些契约字段，属结构性缺口而非单点问题；本次仅增补与引用更新，不改动既有契约与历史记录。

**修改内容**
- `.agent/memory.md`（新建）：长期项目知识种子（技术栈/进程架构/组合快照唯一真相/时间模型/模块边界/构建测试验证约定/已解决的重要问题/避免重复核查信息/体系自身定位）。
- `.agent/loop.md`：入口与 Observe 要求先读 `memory.md`；Observe 增加"禁止直接修改代码"与必读三项；Decide 优先级并入目标 7 级版本；Record 补齐 Loop 编号与观察结果字段；归档位置统一为 `.agent/archive/`。
- `.agent/rules.md`：必须清单增加"执行前读 loop/rules/memory/最近 history"；禁止清单显式化"删除用户数据/修改凭证"；归档引用更新为 `.agent/archive/`。
- `.agent/history.md`：头部归档契约更新为 `.agent/archive/`；追加本条 Loop 6 记录。
- `.agent/archive/README.md`（新建）：归档目录用途说明。

**验证结果**
- 逐文件重读 loop.md/rules.md/memory.md/history.md：六阶段流程与硬性检查齐备（Observe 必读三项 + 禁止直接改代码；Evidence 无证据不修改；Decide 7 级优先级；Execute 最小修改；Verify 用项目现有验证流程；Record 九字段）；入口契约要求的文件（loop.md/rules.md/memory.md/最近 history.md/`.agent/archive/`）全部存在；契约文本（loop.md/rules.md/history.md 头部）中的归档引用已全部统一为 `.agent/archive/`，既有历史记录体内的旧引用为当时事实记载，按契约保持不变。
- `git status --short`：仅 `.agent/**` 下文件变更；`Sources/`、`Tests/`、`Widget/`、`script/`、`docs/`、`AGENTS.md`、`CLAUDE.md`、`project.yml` 零改动。
- `git diff --check`：通过。
- 按 loop.md 既有边界（仅 `.agent/` 基础设施改动不跑 `swift test`），本轮不运行测试。

**剩余风险**
- 归档目录首次落地，尚未实际触发归档动作（history.md 现为 6 条 < 10 条阈值）；后续轮次按 Maintain 阶段执行时以 `.agent/archive/` 为准。
- 既有 5 条历史记录未编号，Loop 编号从本轮（Loop 6）起显式记录；跨轮去重时以日期+标题为准。
- 本轮为纯文档基础设施改动，未运行 `swift test`（与既有"仅 `.agent/` 基础设施改动"验证边界一致）。

## Loop 7：2026-08-09：无修改轮次（未发现可验证的高价值问题）

**Loop 编号**
- Loop 7。

**日期**
- 2026-08-09

**观察结果**
- 工作区：`git status --short` 仅 `.agent/history.md`、`.agent/loop.md`、`.agent/rules.md` 已修改（用户/前一轮 Loop 6 基础设施未提交内容），`?? .agent/archive/`、`?? .agent/memory.md` 未跟踪；`Sources/`、`Tests/`、`Widget/`、`script/`、`docs/` 全部干净，无用户在途修改冲突。
- 最近提交：`943d743`（config `-f` 短形式修复）、`d206124`（Loop 升级）、`31319b5`（恢复重试 generation 测试）、`2732086`（带值选项修复）、`6a9b488`（刷新提交日与恢复预算）、`13b0953`（焦点查询/升级防护）等，活跃区域集中在 Git 只读验证、恢复重试与焦点/快照防护。
- 历史记录：`history.md` 现有 6 条（Loop 6 起编号），无未完成事项；各轮"剩余风险"均为"Git 若新增带值选项需同步维护 `valueTakingOptions`"一类的维护提示，非可验证缺陷。
- `rg "TODO|FIXME|HACK|XXX"`：匹配项全部为 `script/` 下 `mktemp` 模板 `XXXXXX`，无真实标记。
- 高风险代码：`try!`/`fatalError` 无匹配；唯一 `precondition(!days.isEmpty)` 位于 `FocusHistoryAggregation.swift:541`，为 week 聚合内部契约，调用方保证非空，无外部输入触发路径。
- 测试基线：`swift test --filter GitCommandExecutorTests` 33 个全绿；全量 `swift test` 1543 个测试 0 失败；`swift build` 无编译警告。

**选择的问题及证据**
- 无。逐项核对后未发现真实可复现且可验证的高价值问题，各候选淘汰理由：
  - GitCommandExecutor 只读验证：历史 4 轮已处理同根因问题；当前 `valueTakingOptions = {--file, -f, --blob, --type, --default}` 完备，config 各读 action（`--get/--get-all/--get-regexp/--get-urlmatch/--get-color/--get-colorbool/--list`）与 symbolic-ref/reflog/multi-pack-index/interpret-trailers 分支逐一核对无新缺陷，无新失败、新复现或新 Git 语义证据，按规则不重复处理。
  - multi-pack-index `--object-dir` 带值选项：`verify` 放行、`write/expire/repack` 拒绝，带值参数不影响判断，无缺陷。
  - `FocusHistoryAggregation` precondition：无复现条件与外部触发证据，内部契约假设。
  - 测试缺口：无跳过掩盖失败（XCTSkip 均为环境条件），1543 测试全绿。

**原因分析**
- 最近多轮持续收敛 Git 只读验证边界，该方向已完备；其余模块在当前观察范围（工作区、提交历史、测试、静态信号）内无真实缺陷证据。按 loop.md 契约，无证据即无修改，不为了产生修改而修改。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录，属契约要求的 Record 阶段）。

**验证结果**
- `swift test --filter GitCommandExecutorTests`：33 个测试通过（基线）。
- `swift test` 全量：1543 个测试，0 失败。
- `swift build`：无警告。
- `git diff --check`：通过（history.md 追加仅新增行）。
- `git status --short` 复查：业务文件零改动；`.agent/` 下历史文件中本条目为唯一新增，用户/前一轮修改原样保留。

**剩余风险**
- 本轮为无修改轮次，无新增风险；既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- `31319b5` 新增的恢复重试测试依赖真实主队列计时窗口，极慢 CI 下存在既有时序脆弱性，无新失败证据，留待出现实际失败时处理。

## Loop 8：2026-08-11：无修改轮次（未发现可验证的高价值问题）

**Loop 编号**
- Loop 8。

**日期**
- 2026-08-11

**观察结果**
- 工作区：`git status --short` 与 `git diff --check` 均无输出，仓库干净；无用户在途修改冲突。
- 最近提交：`bd41c65`（Loop 6/7 基础设施提交）、`943d743`（config `-f` 修复）、`d206124`（Loop 升级）、`31319b5`（恢复重试 generation 测试）、`2732086`（带值选项修复）；活跃区域仍集中在 Git 只读验证、恢复重试与焦点/快照防护。
- `rg "TODO|FIXME|HACK|XXX"`：匹配项全部为 `script/` 下 `mktemp` 模板 `XXXXXX`；Swift 代码无真实待办标记。
- 高风险模式扫描：`try!`/`fatalError` 无匹配；`as!`/隐式解包仅 `TinyBuddyApp.swift:147-148` 两个启动期属性（在 `applicationDidFinishLaunching` 初始化，标准模式）；唯一 `precondition(!days.isEmpty)` 在 `FocusHistoryAggregation.swift:541`，Loop 7 已评估为内部契约（调用链保证非空）。
- XCTSkip 均为环境条件（Git/App Group 不可用），非掩盖失败。
- 测试基线：`swift test --filter GitCommandExecutorTests` 33 个测试全绿。
- 全面代码扫描（explore 子代理，约 88 次工具调用覆盖 Core/App/script/Tests）：结论"仓库防御性极强"，绝大多数经典缺陷模式均有防护与测试；产出 5 个低风险候选（见下）。

**选择的问题及证据**
- 无。五个候选逐一核对后均未通过证据门槛，淘汰理由：
  - **候选 A：脚本 focus_block 用 UTC 桶计数 + 死代码**（`script/update_git_completion_count.sh:716-719`）。已确认 `local_hour`/`local_minute`/`block_minute` 三个变量计算后从未使用（死代码真实存在），`focus_block=$((epoch / 1800))` 是 UTC 30 分钟桶。但 `git log -S` 追溯证明：提交 `4ecc4a9`（Harden time boundary reliability）将 focus_block **有意**从本地字符串块 `%sT%s:%02d` 改为 UTC 桶，并同步更新缓存字段校验（`is_focus_block` 字符串校验 → `is_unsigned`）与 DST fallback 测试（`testScriptCountsDistinctUTCFocusBucketsAcrossLosAngelesDSTFallback` 断言同一本地块两次事件 count=2）。focusBlockCount 消费链（脚本 → trusted snapshot → combined snapshot → `GitActivityExperiencePresentation`）中，精确数值不被 HUD/Widget 展示（`FocusHistoryPresentationConsistencyTests` 强制 HUD/Widget 用 `focusDuration`，禁止 `presentation.focusCountText`），只用于 PetStatus 布尔（>0）、活动变化判断与 release 校验输出。结论：UTC 桶是有意设计语义，死代码是清理疏漏；改动风险高（破坏 DST 语义与既有测试）而用户可见收益≈0，不构成"高价值可验证问题"。
  - **候选 B：`TinyBuddyTimeContext(...)!` 强制解包**（`GitActivityRefreshCoordinator.swift:2334-2341` static fallback、`Widget/TinyBuddyWidget.swift:336-344`）。failable init 的静态/兜底路径，`Date(timeIntervalSince1970: 0)` 与 `TimeZone(secondsFromGMT: 0)` 当前恒安全，不可复现崩溃，按契约"缺少可复现证据"淘汰。
  - **候选 C：`FocusSessionQueryService.execute` 的 `page.last!`**（`FocusSessionQueryService.swift:82`）。逐行复核防护链：`limit > 0` guard → `startIndex < totalCount` guard → `pageCount = min(limit, totalCount - startIndex) >= 1` → `page` 恒非空，`page.last!` 当前安全。该函数曾因非正 limit 越界 trap（注释记载，已修复），此处的 force-unwrap 属防御性加固建议而非缺陷；无新失败/新复现证据，不构成新一轮依据。
  - **候选 D：`FocusHistoryAggregation.makeWeek` 的 `precondition(!days.isEmpty)` + `days[0]`**。调用链 `isoWeekDayIdentifiers(through:)` 兜底保证至少 1 天，已证安全；Loop 7 已评估同一处。
  - **候选 E：存储清理把属性读取失败文件当最旧处理**（`TinyBuddyStorageCleanupService.swift:406-408`）。`?? Date.distantPast` 是有意的降级策略（无法读取属性 → 最旧优先清理），删除本身有 `try?` 兜底，最坏情况为可读但属性读不到的旧文件被优先删除；属语义选择非缺陷。

**原因分析**
- 最近多轮持续收敛 Git 只读验证与刷新协调边界，该方向已完备；本轮全面扫描（含探索代理独立覆盖 Core/App/script/Tests）未发现任何可复现的缺陷或用户可见偏差。五个候选要么是有意设计（UTC 桶、distantPast 降级）、要么当前恒安全（force-unwrap、page.last!、precondition），均缺少"新失败、新复现、新指标或新用户反馈"这类触发新一轮的证据。按 loop.md 契约，无证据即无修改，不为了产生修改而修改。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录，属契约要求的 Record 阶段）。

**验证结果**
- `swift test --filter GitCommandExecutorTests`：33 个测试通过（基线）。
- `git diff --check`：通过（history.md 追加仅新增行）。
- `git status --short` 复查：业务文件零改动；`.agent/` 下历史文件中本条目为唯一新增。

**剩余风险**
- 本轮为无修改轮次，无新增风险。留待后续轮次的候选（均低风险、非缺陷）：脚本 focus_block 的 3 行死代码（`local_hour`/`local_minute`/`block_minute`）可随时作为纯清理移除，行为零变化；`FocusSessionQueryService` 的 `page.last!` 与 `TinyBuddyTimeContext(...)!` 属防御性加固，若未来相关 guard 收紧需先处理。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- `31319b5` 新增的恢复重试测试依赖真实主队列计时窗口，极慢 CI 下存在既有时序脆弱性，无新失败证据，留待出现实际失败时处理。

## Loop 9：2026-08-11：无修改轮次（仓库状态与 Loop 8 逐字节一致，未发现新的可验证问题）

**Loop 编号**
- Loop 9。

**日期**
- 2026-08-11

**观察结果**
- 工作区：`git status --short` 无输出、`git diff --check` 通过、无未跟踪文件；`git diff origin/main..HEAD` 为空，HEAD（`041980f`）即 Loop 8 提交，仓库业务代码自 Loop 8 以来**逐字节未变**。
- 最近提交：`041980f`（Record Loop 8 no-op）自上一轮以来是唯一提交，且只改 `.agent/history.md`；业务文件（Sources/Tests/Widget/script）无任何新改动。
- 历史去重：`history.md` 现有 8 条记录（Loop 6-8 编号，前 5 条未编号）；Loop 8 已对脚本 dead code、`page.last!`、`TinyBuddyTimeContext(...)!`、`precondition` 等候选逐条给出淘汰依据，本轮候选若同根因即构成重复。
- `rg "TODO|FIXME|HACK|XXX"`：Swift/脚本代码无真实待办标记（仅 `script/` 下 `mktemp` 模板 `XXXXXX`）。
- 高风险模式：`try!`/`fatalError` 无匹配；候选 force-unwrap 现场逐一复核均为安全：
  - `ManualFocusMenuBarController.swift:81` `engine!`：`if engine == nil { stop() } else if statusItem == nil { start(with: engine!) }`，else 分支已排除 nil，安全。
  - `TinyBuddyDataValidator.swift:446/454` `previousVersion!`：前置 `guard previousVersion != nil else { return }`，安全。
  - `TinyBuddyTransactionLog.swift:352` `data(using: .utf8)!`：String 到 UTF-8 的 Data 编码恒成功，惯用法。
  - `FocusSessionQueryService.swift:82` `page.last!`：Loop 8 候选 C，防护链已验证恒非空。
  - `FocusNotificationManager.swift:134` `URL(string:)!`：字面量常量 URL，恒有效。
- `precondition(!days.isEmpty)`（`FocusHistoryAggregation.swift:541`）：Loop 7/8 已评估为内部契约（`isoWeekDayIdentifiers(through:)` 兜底保证至少 1 天），无新证据。
- 测试基线：`swift test` 全量 **1543 个测试、0 失败**（后台运行，耗时约 212s）；构建随测试编译成功，无失败。

**选择的问题及证据**
- 无。逐项核对后未发现任何相对 Loop 8 的新证据，各候选淘汰理由：
  - **脚本 focus_block 区域内 dead code**（`script/update_git_completion_count.sh:716-719` 的 `local_hour`/`local_minute`/`block_minute` 三行已核实仍计算后未使用）：Loop 8 已确认 `focus_block=$((epoch / 1800))` 为**有意**的 UTC 桶设计（提交 `4ecc4a9`，且有 DST fallback 测试锁定语义），dead code 属零行为纯清理。本轮无新失败、新复现、新指标或新用户反馈，同根因重复，按契约不处理。
  - force-unwrap 四处与 `precondition`：均无复现证据，先前轮次已复核安全，不构成新一轮依据。
  - 测试缺口：1543 测试全绿，XCTSkip 均为环境条件（Git/App Group 不可用），无失败掩盖。
- 完成标准：na（无修改轮次）。

**原因分析**
- 仓库自 Loop 8 无任何业务代码变化，观察范围（工作区、提交历史、静态信号、全量测试）内不存在"新的失败、新复现、新指标或新用户反馈"；所有候选要么与历史已完成问题同根因（dead code、precondition、page.last!），要么经现场复核恒安全（四处 force-unwrap），缺少触发新一轮的证据门槛。按 loop.md 契约"无证据即无修改，不为了产生修改而修改"。

**修改内容**
- 无（仅 `.agent/history.md` 追加本条记录，属契约要求的 Record 阶段）。

**验证结果**
- `swift test` 全量：1543 个测试，0 失败（基线，后台运行记录）。
- `git diff --check`：通过（history.md 追加仅新增行）。
- `git status --short` 复查：业务文件零改动，`.agent/` 下历史文件中本条目为唯一新增；HEAD == origin/main，工作区干净。

**剩余风险**
- 本轮为无修改轮次，无新增风险。留待后续轮次（需新证据）：脚本 focus_block 区域 3 行 dead code 可随时作为纯清理移除（行为零变化）；`FocusSessionQueryService` 的 `page.last!` 与 `TinyBuddyTimeContext(...)!` 属防御性加固，若未来相关 guard 收紧需先处理。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- `31319b5` 新增的恢复重试测试依赖真实主队列计时窗口，极慢 CI 下存在既有时序脆弱性，无新失败证据，留待出现实际失败时处理。

## Loop 10：2026-08-11：修复 Widget 历史数据与中性占位的自恢复展示

**Loop 编号**
- Loop 10。

**日期**
- 2026-08-11

**观察结果**
- 起始工作区在 `main`，与 `origin/main` 同步，但存在 6 个未提交的 Widget/共享展示改动及其回归测试；本轮未覆盖或回滚这些在途修改。
- 对照 Loop 9：此前全量基线为 1543 个测试通过，业务文件没有变化；本轮新增改动集中在 `TinyBuddyDisplayPresentation`、`TinyBuddyWidgetTimelinePolicy`、Widget provider 及对应测试。
- 旧实现仅以 Git activity 字段决定 `showsActivityMetrics`，且稳定 `.idle` 状态始终不自调度；这会使仅有 `FocusHistoryPublication` 的合法快照隐藏 Widget 指标，也会使无数据的首次/跨日占位在缺失 App reload 时永久停留。
- `git diff --check` 通过；未发现 TODO/FIXME 等新的可验证线索。

**选择的问题及证据**
- 选择 Widget 在合法历史-only 快照和无数据占位下无法可靠展示/自恢复这一单一跨层问题。
- 复现条件：activity slice 的两个可选计数均为 `nil`、但 focus-history publication 存在；或 timeline entry 为 neutral `.idle` 且无可渲染数据，App-side reload 缺失。
- 完成标准：历史-only 快照显示 metrics；有数据的空日保持 push-only；无数据 idle 按慢速 cadence 重读；跨日 neutral rollover 在边界后进行一次有界 probe；自调度不跨越本地日边界。

**原因分析**
- Widget 的主要 focus 指标来自权威 focus-history publication，而旧的可见性门槛只检查 Git activity 字段；同时 timeline 的 `.never` fallback 没有覆盖“占位尚未具备数据、但后续提交会出现”的可恢复状态。

**修改内容**
- `Sources/TinyBuddyCore/TinyBuddyDisplayPresentation.swift`：将有效的 focus-history metric 纳入 Widget metrics 可见性判定，同时保留 stale/loading/授权异常的隐藏规则。
- `Sources/TinyBuddyCore/TinyBuddyWidgetTimelinePolicy.swift`：为无可渲染数据的 neutral idle 增加慢速重试；增加有界的跨日 rollover probe。
- `Widget/TinyBuddyWidget/TinyBuddyWidget.swift`：识别占位 entry，接入 idle 自恢复与跨日 probe。
- `Tests/TinyBuddyCoreTests/TinyBuddyDisplayPresentationTests.swift`、`Tests/TinyBuddyCoreTests/TinyBuddyWidgetTimelinePolicyTests.swift`、`Tests/TinyBuddyAppTests/WidgetFallbackRenderingTests.swift`：补充 history-only、占位自恢复、边界和共享快照回归覆盖。

**验证结果**
- `swift test --filter TinyBuddyWidgetTimelinePolicyTests`：15 个测试通过。
- `swift test --filter TinyBuddyDisplayPresentationTests`：27 个测试通过。
- `swift test --filter WidgetFallbackRenderingTests`：11 个测试通过。
- `swift test`：1550 个测试通过，0 失败。
- `git diff --check`：通过。
- `./script/tb-install.sh`：Xcode Debug 构建成功，Apple Development 签名验证通过，安装并启动成功。
- 独立 `codesign --verify --deep --strict`：已安装 App 的嵌套签名验证通过；运行中的 `TinyBuddy` executable 路径来自已安装 bundle，且安装产物与构建产物一致。

**剩余风险**
- 未单独实测 WidgetKit 的系统调度；本轮源码测试覆盖 timeline policy/provider wiring，已完成本机签名安装与 App 启动验证。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。

## Loop 11：2026-08-12：消除恢复重试测试的真实计时依赖（注入确定性调度器）

**Loop 编号**
- Loop 11。

**日期**
- 2026-08-12

**观察结果**
- 起始工作区干净（`git status --short` 无输出），HEAD == origin/main（`de3da20`）；业务代码自 Loop 10（`6049a63` Widget 修复）以来逐字节未变，`de3da20` 仅改 `.agent/history.md`。
- 最近提交：`de3da20`（Record signed local app verification）、`6049a63`（Fix Widget fallback rendering and self-healing）、`d58c31c`/`041980f`（Loop 9/8 no-op）。
- `rg "TODO|FIXME|HACK|XXX"`：Swift/脚本代码无真实待办标记（仅 `script/` 下 `mktemp` 模板 `XXXXXX`）。
- 高风险模式：`try!`/`fatalError` 无匹配；force-unwrap 候选仅 `FocusSessionQueryService.swift:82 page.last!`（Loop 8/9 已评估恒安全，无新证据）。
- **关键发现（新失败证据）**：全量 `swift test` 1550 个测试**偶发 1 失败**——6 次运行中 1 次失败（该次恰与另一个全量测试并行编译，高负载环境），5 次单独运行全绿（16:40 完整日志、4 次串行循环、1 次最终验证）。失败详情最初被过滤管道丢失，无法直接确认失败测试名；无 xctest 崩溃报告（0 unexpected，普通断言失败）。
- 历史预告：Loop 8/9/10 均记录 `testSuccessfulRefreshCancelsQueuedRecoveryRetryWithoutConsumingResetBudget`（`6a9b488` 的回归测试）"依赖真实主队列计时窗口（0.2s/0.5s），极慢 CI 下存在既有时序脆弱性，留待出现实际失败时处理"。

**选择的问题及证据**
- 选择"消除恢复重试回归测试的真实计时依赖"这一稳定性问题（Loop 优先级第 2 位）。
- 复现条件：全量测试与另一构建/测试进程并行、或慢环境（真实主队列 `asyncAfter` 0.2s/0.5s 窗口调度延迟导致超时）。本次已实际观察到 1 次全量失败，且 coordinator 的恢复重试排队（`scheduleRecoveryRetryIfNeeded`）是全测试套件中唯一经真实主队列计时驱动的恢复路径，与历史三次预告的脆弱测试吻合。
- 影响范围：CI/慢机下偶发全量失败，掩盖真实回归信号。
- 完成标准：恢复重试排队改为可注入延迟执行器（默认主队列行为不变）；该测试改用 `DeterministicScheduler` 虚拟时间驱动；目标测试重复运行 100% 确定；`GitActivityRefreshCoordinatorTests` 97 个测试与全量 1550 个测试全绿。

**原因分析**
- `testSuccessfulRefreshCancelsQueuedRecoveryRetryWithoutConsumingResetBudget` 用真实主队列 `asyncAfter(deadline: .now() + 0.5)` 等待已排队重试触发、用 0.2s `minimumRefreshSpacing` 让重试在测试时间内触发，验证 generation 取消与预算恢复。高负载下主队列调度延迟使等待窗口（timeout 1.0s）超时或断言窗口漂移，产生 flaky。项目已有 `DeterministicScheduler`（`Tests/TinyBuddyAppTests/Helpers/`，支持 `schedule(after:)` 与虚拟时间推进），但此前未接线到 coordinator。

**修改内容**
- `Sources/TinyBuddy/GitActivityRefreshCoordinator.swift`
  - 新增可注入延迟执行器 `scheduleAfterDelay: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void`（属性 + init 参数，默认 `DispatchQueue.main.asyncAfter`，产品行为不变）。
  - `scheduleRecoveryRetryIfNeeded` 的恢复重试排队由 `DispatchQueue.main.asyncAfter(...)` 改为 `scheduleAfterDelay(minimumRefreshSpacing) { ... }`。
- `Tests/TinyBuddyAppTests/GitActivityRefreshCoordinatorTests.swift`
  - `RefreshHarness` 新增 `let scheduler = DeterministicScheduler()`，并在 coordinator 构造时注入 `scheduleAfterDelay`。
  - `testSuccessfulRefreshCancelsQueuedRecoveryRetryWithoutConsumingResetBudget`：移除真实 `asyncAfter(0.5)` 等待，改为 `scheduler.advanceTime(by: 0.2)` 确定性触发已排队的恢复重试（步骤 3 验证 generation 取消，步骤 5 验证恢复后重试成功）。

**验证结果**
- `swift test --filter GitActivityRefreshCoordinatorTests`：97 个测试通过（0 失败）。
- 目标测试重复运行 10 次：全部通过（确定性，无真实计时依赖）。
- `swift test` 全量：1550 个测试，0 失败。
- `git diff --check`：通过。
- `git status --short` 复查：仅 `Sources/TinyBuddy/GitActivityRefreshCoordinator.swift` 与 `Tests/TinyBuddyAppTests/GitActivityRefreshCoordinatorTests.swift` 两处改动（+28/-13），无越界修改；`.agent/` 下追加 Loop 11 记录并归档最旧 1 条。

**剩余风险**
- 偶发失败详情未能直接捕获（过滤管道丢失），无法 100% 证实失败测试即此测试；但该测试是 coordinator 中唯一经真实计时驱动的恢复重试路径，且历史三次预告同一风险，本次修复消除了该路径的全部真实计时依赖，逻辑上覆盖了观察到的失败模式。若后续再次出现偶发失败，优先检查其余真实计时依赖（如 `DeterministicEndToEndFaultSimulationTests` 的 3.0s REPRO 窗口）。
- 其他测试未注入 `scheduleAfterDelay`，默认仍走主队列，行为不变；RefreshHarness 注入 scheduler 后，其他依赖恢复重试排队的测试隔离性反而更好（重试只在 `advanceTime` 时触发）。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- `.agent/` 首次实际触发归档：`history.md` 现保留 10 条，最旧 1 条（2026-08-09 Loop 升级）原样移入 `.agent/archive/history-2026-08-12.md`。

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
