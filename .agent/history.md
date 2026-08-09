# Maintenance Loop History

用于记录每一次 Maintenance Loop 的结果。请按 `.agent/loop.md` 的 Record 阶段追加条目，并按 Maintain 阶段维护本文件：

- 本文件始终保留最近约 10 条轮次记录。
- 当条目数超过 10 条时，最旧的条目原样移动到 `.agent/archive/` 目录下的归档文件（如 `history-YYYY-MM-DD.md`；不存在则创建，头部注明用途与归档时间）；归档条目不丢失、不改写。
- 观察与决策阶段核对历史时，同时读取本文件与 `.agent/archive/` 归档，避免重复处理已完成的问题。

## 2026-08-09：将 Maintenance Loop 升级为通用长期维护版本

**发现的问题及证据**
- 现有 `.agent/` 维护体系已成功执行多轮闭环（本轮前 3 条记录），机制验证有效；但作为长期重复执行入口存在三个结构性缺口：
  - `history.md` 无归档机制，只增不减，长期运行必然无限膨胀。
  - Decide 阶段未要求与已完成问题核对，存在重复处理同根因问题的风险。
  - 无修改轮次的结束路径未作为长期运行契约显式化。
- 证据：`loop.md` 原流程为 `Observe → Decide → Execute → Verify → Record` 五阶段；`history.md` 仅追加、无归档说明；rules 中无"同模块需新证据/不重复已完成问题"约束。

**原因分析**
- 原设计面向单轮执行而非长期反复执行，缺少历史增长控制与问题去重两类长期运行必需机制；本次仅升级 Agent 维护基础设施，不修改任何业务代码。

**修改内容**
- `.agent/loop.md`
  - 流程升级为 `Observe → Evidence → Decide → Execute → Verify → Record → Maintain`：新增 Evidence 阶段（证据先于决策、区分事实与猜测、无证据淘汰），新增 Maintain 阶段（历史保留最近约 10 条、旧条目原样归档到 `.agent/history-archive.md`、归档不丢不改、去重查询同时读两个文件）。
  - Decide 阶段增加问题去重：同模块继续优化必须引用新证据；与已完成问题同根因视为重复不处理。
  - 入口与目标明确"无修改轮次"：没有高价值可验证问题即以无修改轮次结束，不为了产生修改而修改。
- `.agent/rules.md`
  - "必须"中新增：同模块优化需新证据、不得重复已完成问题；无高价值问题允许无修改结束；维护历史保留最近约 10 条并原样归档、不删不改不截断。
- `.agent/history.md`
  - 头部更新为 Maintain 阶段契约（保留 10 条、归档规则、去重查询），并追加本轮记录。

**验证结果**
- 逐文件复查 `loop.md` 阶段编号与入口顺序一致（`Observe → Evidence → Decide → Execute → Verify → Record → Maintain`）。
- 历史 3 条旧记录原样保留，未触发归档阈值（<10 条）。
- `git diff --check`：通过。
- `git status --short` 复查：仅 `.agent/` 下三个文件被修改；`Sources/`、`Tests/`、`Widget/`、`script/` 未触碰；用户/前一轮未提交修改（GitCommandExecutor.swift 等）保持原样。

**剩余风险**
- 归档触发阈值（10 条）为约定值，由后续轮次按 Maintain 阶段执行；归档文件 `history-archive.md` 在首次归档时创建。
- 本轮为纯 `.agent/` 基础设施改动，不涉及代码、测试或运行行为，未运行 `swift test`（按 loop.md 中"仅文档或 `.agent/` 基础设施改动"的验证边界执行）。

## 2026-08-09：修复 config 只读验证对 --type/--default 读形式误拒

**发现的问题及证据**
- `GitCommandExecutor.isReadOnlyConfigInvocation` 的带值选项集合（`valueTakingOptions`）仅含 `--file`/`--blob`，导致另外两个真实合法只读形式被误判为写形式 `git config <name> <value>` 而抛 `commandNotAllowed`：
  - `git config --default <value> <name>`：`<value>` 被计入裸参数计数（=2）被拒；
  - `git config --type <type> <name>`：`<type>` 被计入裸参数计数（=2）被拒。
- 用真实 Git 验证语义：`git config --default "fallback" user.name` 退出 0 并输出读取值；`git config --type bool core.ignorecase` 退出 0 输出 `true`；`git config --comment "note" user.name` 退出 129（`--comment` 仅适用于 add/set/replace，属写专用，应保持拒绝）。
- 新增测试在修复前运行均按预期失败：`config --default <value> <name> is a read but was rejected`、`config --type <type> <name> is a read but was rejected`。
- `swift test` 基线（含前一轮改动）：GitCommandExecutorTests 30 个测试全绿。

**原因分析**
- 上一轮（修复 `--file`/`--blob`）记录中已标注此方向风险：带值选项集合不完整；`--default`/`--type` 的分离参数形式同样属于"选项自身携带的值"，不应计入配置键/值计数。

**修改内容**
- `Sources/TinyBuddyCore/GitCommandExecutor.swift`
  - `isReadOnlyConfigInvocation` 的 `valueTakingOptions` 加入 `--type`、`--default`，其携带值在裸参数计数中被跳过；写形式 `git config --type bool <name> <value>` 仍有 2 个真实裸参数，继续被拒绝（安全性不变）。
- `Tests/TinyBuddyCoreTests/GitCommandExecutorTests.swift`
  - 新增 `testReadOnlyAllowsConfigDefaultReadForm`：`config --default <value> <name>` 必须执行成功且输出 fallback，不抛 `commandNotAllowed`。
  - 新增 `testReadOnlyAllowsConfigTypeReadForm`：`config --type <type> <name>` 必须执行成功；并断言写形式 `config --type bool user.name true` 仍抛 `commandNotAllowed`。

**验证结果**
- 修复前运行两个新测试：均失败，确认缺陷真实存在。
- 修复后 `swift test --filter GitCommandExecutorTests`：32 个测试（+2）全部通过。
- `swift test` 全量：1542 个测试（+2），0 失败。
- `git diff --check`：通过。
- `git status --short` 复查：仅 GitCommandExecutor.swift、GitCommandExecutorTests.swift 及上一轮遗留的 GitActivityRefreshCoordinatorTests.swift 有改动，`.agent/` 未跟踪；未触碰用户/前一轮修改。

**剩余风险**
- `--comment` 等写专用选项经真实 Git 验证不应放行，已维持拒绝；若 Git 未来新增读语义的带值选项，需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。
- 本轮只涉及只读验证逻辑，未改变命令执行、超时或取消路径。

## 2026-08-09：补充恢复重试 generation 取消机制的回归测试

**发现的问题及证据**
- 提交 `6a9b488`（Fix refresh commit day read and recovery retry budget）在 `Sources/TinyBuddy/GitActivityRefreshCoordinator.swift` 引入 `directoryRecoveryGeneration`：成功刷新时 `&+= 1`，使已排队的恢复重试闭包通过 `guard self.directoryRecoveryGeneration == recoveryGeneration`（1816-1818 行）检测到 generation 不匹配而直接返回，不再消耗已重置的恢复预算、不再错误标记 `hasExhaustedDirectoryRecovery`。
- 但该排队重试使用真实主队列 `DispatchQueue.main.asyncAfter(deadline: .now() + minimumRefreshSpacing)`（默认 60 秒），现有测试（如 `testInvalidSavedAuthorizationKeepsLowFrequencyRecoveryAndRecoversAutomatically`）时长远小于 60 秒真实时间，排队重试闭包从未真正触发，generation 取消分支无任何测试执行覆盖。
- `swift test` 基线：`GitActivityRefreshCoordinatorTests` 96 个测试全绿。

**原因分析**
- 测试 harness（`RefreshHarness`）将 `minimumRefreshSpacing` 硬编码为 60，无法在测试时间内触发排队的恢复重试闭包，导致 `6a9b488` 的核心稳定性修复（成功刷新后取消陈旧恢复重试）缺乏回归保护。

**修改内容**
- `Tests/TinyBuddyAppTests/GitActivityRefreshCoordinatorTests.swift`
  - `makeHarness` 与 `RefreshHarness.init` 增加 `minimumRefreshSpacing: TimeInterval = 60` 参数（默认值不变，不影响现有测试），并传递给 coordinator。
  - 新增 `testSuccessfulRefreshCancelsQueuedRecoveryRetryWithoutConsumingResetBudget`：用短间距（0.2s）触发真实排队重试，验证 ①授权失效后恢复重试排队；②授权恢复成功刷新后 generation 递增、预算重置；③已排队重试触发时因 generation 不匹配被取消（无额外脚本运行）；④再次授权失效时预算仍可重置（未标记耗尽），恢复重试仍能成功。

**验证结果**
- 新测试单独运行：通过。
- 反向验证：临时禁用 generation guard（`directoryRecoveryGeneration == recoveryGeneration` 分支改为恒通过）后，新测试如预期失败（`scriptRunCount` 变为 2、outcome 为 failed），证明测试能捕获该回归；随后已还原产品代码（`git diff` 确认 coordinator 无改动）。
- `swift test --filter GitActivityRefreshCoordinatorTests`：97 个测试全部通过。
- `swift test` 全量：1537 个测试，0 失败。
- `git diff --check`：通过。

**剩余风险**
- 新测试依赖真实主队列计时（0.2s/0.5s 窗口），在极慢 CI 环境可能存在时序脆弱性，但窗口余量较大且与现有测试模式一致。
- 本轮未修改产品代码，仅补测试；`directoryRecoveryGeneration` 机制本身的正确性未变。

## 2026-08-09：修复 Git 命令只读验证误拒合法只读调用形式

**发现的问题及证据**
- 提交 `18cff91`（Harden Git command read-only and timeout enforcement）引入的 `GitCommandExecutor.isReadOnlyInvocation` 对两类合法只读命令形式存在误判，在 `readOnly` 模式下抛出 `commandNotAllowed`：
  - `git config --file <path> <name>`（读取指定配置文件中的键）：`isReadOnlyConfigInvocation` 将 `--file` 选项携带的路径参数计入裸参数计数（`["/path", "name"]` 共 2 个），被误判为写形式 `git config <name> <value>` 而拒绝。
  - `git reflog <ref>`（`git reflog show <ref>` 的只读简写，如 `git reflog HEAD`）：`reflog` 分支只放行 `show`/`exists`/无 action，`HEAD` 这类 ref 简写被误判为写子命令而拒绝。
- 用真实 Git 验证语义：`git reflog HEAD` 正常输出并返回 0；`git config --file <不存在路径> user.name` 只是普通错误退出（exit=1），并非命令不允许。
- `swift test` 基线：1537 个测试全绿。

**原因分析**
- 裸参数计数没有区分"选项自身携带的值"（`--file <path>`、`--blob <oid>`）与真正的配置键/值；`reflog` 分支按 action 白名单判断，遗漏了 `show` 省略形式。

**修改内容**
- `Sources/TinyBuddyCore/GitCommandExecutor.swift`
  - `isReadOnlyConfigInvocation`：改为逐参数扫描，`--file`/`--blob` 及其后一个参数作为选项值跳过，剩余裸参数计数 ≤ 1 视为只读；写形式 `git config <name> <value>` 和 `git config --file <path> <name> <value>` 仍被拒绝。
  - `reflog` 分支：改为黑名单判断，仅 `expire`/`delete` 两个真实写子命令被拒绝，其余（`show`、`exists`、ref 简写、无参数）放行。
- `Tests/TinyBuddyCoreTests/GitCommandExecutorTests.swift`
  - 新增 `testReadOnlyAllowsConfigFileReadForm`（`config --file` 只读形式必须执行，不抛 `commandNotAllowed`）。
  - 新增 `testReadOnlyAllowsReflogRefReadShorthand`（`reflog HEAD`/`show HEAD`/`exists HEAD` 均不被拒绝）。
  - 新增 `testReadOnlyStillBlocksReflogWriteSubcommands`（`reflog expire`/`reflog delete` 仍被拒绝）。

**验证结果**
- 修复前运行新测试：`testReadOnlyAllowsConfigFileReadForm` 与 `testReadOnlyAllowsReflogRefReadShorthand` 按预期失败，确认缺陷真实存在。
- 修复后运行 `swift test --filter GitCommandExecutorTests`：30 个测试全部通过。
- `swift test` 全量：1540 个测试（新增 3 个），0 失败。
- `git diff --check`：通过。
- 上一轮遗留的 `Tests/TinyBuddyAppTests/GitActivityRefreshCoordinatorTests.swift` 修改未被触碰。

**剩余风险**
- `config` 带值选项只覆盖了 `--file`/`--blob`；Git 未来若增加新的带值选项需要同步维护黑名单，现有写形式仍被正确拒绝，属于保守方向。
- 本轮只涉及只读验证逻辑，未改变命令执行、超时或取消路径。

## 2026-08-09：修复 config 只读验证对 `-f`（`--file` 短形式）读形式误拒

**发现的问题及证据**
- `GitCommandExecutor.isReadOnlyConfigInvocation` 的带值选项集合（`valueTakingOptions`）只含长形式 `--file`/`--blob`/`--type`/`--default`，缺少 `--file` 的短形式 `-f`，导致合法只读调用 `git config -f <path> <name>` 被误判为写形式 `git config <name> <value>`（`<path>` 被计入裸参数计数=2）而抛 `commandNotAllowed`。
- 用真实 Git 验证语义：`git config -f .git/config user.name` 退出 0 并输出读取值（与 `--file` 等价）；写形式 `git config -f <path> <name> <value>` 退出 0 会真实写入，必须在只读模式下保持拒绝。
- 新增测试在修复前运行按预期失败：`config -f <path> <name> is a read but was rejected`。
- 全量基线：1542 个测试全绿。

**原因分析**
- 前两轮（修复 `--file`/`--blob`、`--type`/`--default`）已标注剩余风险："带值选项集合不完整，Git 若新增读语义带值选项需同步维护"；`-f` 是 `--file` 的既有短形式，从未被覆盖，属该剩余风险的一个具体实例。带值选项的短形式同样属于"选项自身携带的值"，不应计入配置键/值计数。

**修改内容**
- `Sources/TinyBuddyCore/GitCommandExecutor.swift`
  - `isReadOnlyConfigInvocation` 的 `valueTakingOptions` 加入 `-f`，其携带的路径在裸参数计数中被跳过；写形式 `git config -f <path> <name> <value>` 仍有 2 个真实裸参数（`<name>`/`<value>`），继续被拒绝（安全性不变）。
  - 同步更新该处注释，标注 `-f` 为 `--file` 的短形式。
- `Tests/TinyBuddyCoreTests/GitCommandExecutorTests.swift`
  - 新增 `testReadOnlyAllowsConfigFileShortFormRead`：`config -f <path> <name>` 必须执行成功（缺失文件是普通 git 错误而非策略拒绝），不抛 `commandNotAllowed`；并断言写形式 `config -f <path> <name> <value>` 仍抛 `commandNotAllowed`。

**验证结果**
- 修复前运行新测试：按预期失败，确认缺陷真实存在。
- 修复后 `swift test --filter GitCommandExecutorTests`：33 个测试（+1）全部通过。
- `swift test` 全量：1543 个测试（+1），0 失败。
- `git diff --check`：通过。
- `git status --short` 复查：仅 GitCommandExecutor.swift、GitCommandExecutorTests.swift 两处改动，无越界修改（观察阶段工作区即为干净状态）。

**剩余风险**
- `git config` 的带值短形式目前仅 `-f`；若 Git 未来新增其他带值短选项或长选项，仍需同步维护 `valueTakingOptions`（保守方向，误拒优于误放行）。组合短选项形式（如 `-f<path>`）与 `--file=<path>` 一样不产生额外裸参数，本就不受影响。
- 本轮只涉及只读验证逻辑，未改变命令执行、超时或取消路径。

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
