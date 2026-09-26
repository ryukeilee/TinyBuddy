# Maintenance Loop History

用于记录每一次 Maintenance Loop 的结果。请按 `.agent/loop.md` 的 Record 阶段追加条目，并按 Maintain 阶段维护本文件：

- 本文件始终保留最近约 10 条轮次记录。
- 当条目数超过 10 条时，最旧的条目原样移动到 `.agent/archive/` 目录下的归档文件（如 `history-YYYY-MM-DD.md`；不存在则创建，头部注明用途与归档时间）；归档条目不丢失、不改写。
- 观察与决策阶段核对历史时，同时读取本文件与 `.agent/archive/` 归档，避免重复处理已完成的问题。
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

## Loop 26：2026-09-23：修复回归门禁 Widget 阶段哈希校验从未执行（空洞通过）

**Loop 编号**
- Loop 26。

**日期**
- 2026-09-23。

**观察结果**
- 工作区：`git status --short` 与 `git diff --check` 均无输出，干净；`git stash list` 为空；HEAD == `origin/main` == `2d1d8ce`（Loop 25 的提交 `Evaluate the regression gate's sustained CPU budget`），自 Loop 25 以来无新提交。
- 读取 `.agent/loop.md`、`.agent/rules.md`、`.agent/memory.md`、`.agent/history.md`（10 条：Loop 16–25）与 `.agent/archive/`（含 Loop 9–16 等历史条目，用于去重核对）。
- 静态信号：`rg "TODO|FIXME|HACK|XXX" Sources Tests Widget script` 仅命中 `mktemp` 的 `XXXXXX` 模板，无真实待办；窄测基线 `./script/swiftpm.sh test --filter RegressionGateScriptTests`：11 个测试 0 失败（环境健康检查）。
- 关键发现（`script/regression_gate.sh` 的 `run_widget_reload`，stage 6 widget-reload）：
  - `local expected_hash` / `local executable_hash` 被赋值后全脚本再无任何引用（`git show HEAD:script/regression_gate.sh | grep -c '\$expected_hash\|\$executable_hash'` = 0），注释却写着 “Verify the widget process executable hash matches our build”；赋值与 `stage_pass` 之间没有任何比较，找到进程即无条件 PASS。
  - 运行侧哈希取 `"/proc/$widget_pid/exe"`：macOS 无 `/proc`（`ls -d /proc` → `No such file or directory`），该分支必然失败并回退为 `"$PS_BIN" -p "$widget_pid" -o comm= | xargs | shasum -a 256`，即对**路径文本**取哈希。实测：`ps -p 972 -o comm= | xargs | shasum -a 256` = `c672d5d312dbf9c782f6f8905ebb3f189b4e970dda2a0cd767d1d0faa3a9cc23`，而该可执行文件真实哈希为 `56e74a201fd1d51ceef613f4c7a0ddab6be506900682488aa6ac42d85ec71de3`。
  - 校验目标来自注册表首条记录而非本次构建：`pluginkit -m -A -D -v -i com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension` 只返回 `/Applications/TinyBuddy.app/Contents/PlugIns/TinyBuddyWidgetExtension.appex`（注册时间 2026-09-15），运行中的 widget 进程（pid 972）恰是这一已安装副本；`project.yml` 将 widget 作为 app-extension 内嵌（`Contents/PlugIns/TinyBuddyWidgetExtension.appex`），`script/build_and_run.sh:721` 也是从被验证的 app bundle 以同一路径推导 appex。
- 去重核对：Loop 24/25 修的是同一门禁的 stage 5（探针采样、持续 CPU 预算），未触及 stage 6；`history.md` 与 `.agent/archive/` 中没有任何关于 `expected_hash`/`executable_hash` 的记录。

**选择的问题及证据**
- 选择「`script/regression_gate.sh` 的 stage 6（widget-reload）声称校验 widget 进程可执行文件哈希与本次构建一致，实际从不比较哈希、且校验基准取自注册表首条记录，导致找到进程即无条件 PASS」这一稳定性/错误处理问题（Loop 优先级第 2、5 位）。
- 与已完成轮次的差异：Loop 24 是探针失败被伪造成全零采样，Loop 25 是 `evaluate_resource_budgets` 的 AWK 从未使用 `cpuCap`/`cpuSamples`；本轮是另一个 stage 的校验整体未执行、且校验对象错误，属新证据（新复现、新静态证据），不是同根因重复处理。
- 复现条件（确定性，不需要真实 App）：source 门禁脚本（入口有 `BASH_SOURCE` 守卫），注入 `APP_BUNDLE`（假 app bundle，含内容为 `build-under-test-widget-binary` 的自有 widget 可执行文件）、`PLUGINKIT_BIN`（注册另一个 appex）、`PS_BIN`（分别桩化 `-axo pid=,comm=` 与 `-p <pid> -o comm=`）与 `WIDGET_TIMEOUT=1`，再调用 `run_widget_reload`。
  - 修复前（HEAD 脚本）：运行进程指向注册的已安装副本、与构建的 widget 二进制不同时，仍输出 `>>> PASS: widget-reload`、`STAGE-STATUS=0`、`OVERALL_STATUS=0`。
  - 修复后（同一 harness）：`>>> FAIL: widget-reload — running widget executable is not the build under test: pid=4242 running=…/registered/… expected=…/build/TinyBuddy.app/Contents/PlugIns/…`、`STAGE-STATUS=1`、`OVERALL_STATUS=1`；运行进程指向本次构建的 widget 时 `>>> PASS: widget-reload` 并打印 `sha256=…`。
- 影响范围：`script/regression_gate.sh` 的 `--stage 6`、`--quick` 与默认全量运行的 widget-reload 阶段；「widget 进程不是本次构建的产物」「可执行文件缺失或已被替换」都会以 PASS 记录，门禁据以宣称校验过 widget 可执行文件。
- 完成标准：找到 widget 进程后必须把该进程自身报告的可执行文件内容哈希与本次构建的 widget 可执行文件哈希比较，路径不可解析或哈希不一致时 fail closed；注册缺失仍是 SKIP；新增测试在修复前失败、修复后通过。

**原因分析**
- 原实现从未完成它声称的校验：`expected_hash`/`executable_hash` 赋值后无人读取；运行侧哈希来源 `"/proc/$widget_pid/exe"` 是 Linux 语义，在 macOS 上必然失败，回退分支又把 `ps -o comm=` 的路径文本当作可执行文件内容哈希；校验基准取 `pluginkit` 返回的首条 appex，而本次构建与已安装副本注册同一 bundle id（顺序不确定），因此「匹配本次构建」既没有比较，也没有以本次构建为基准。该 stage 此前没有任何自动化测试，缺陷无从暴露。
- 仓库已有的正确模式可直接复用：`script/build_and_run.sh:verify_running_bundle_process` 先从运行进程读回其自身可执行文件路径，再对**该文件**取 sha256 与期望值比较，不一致即失败；`"$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXTENSION_NAME.appex"` 也是该脚本既有的 appex 推导方式。

**修改内容**
- `script/regression_gate.sh`（仅 `run_widget_reload`，+39/−12）：
  - 注册表结果改名 `registered_executable`，只用于发现运行中的 widget 进程（保留“未注册 → SKIP”“注册的可执行文件缺失 → SKIP”语义与消息）。
  - 新增校验基准 `expected_executable="$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXTENSION_NAME.appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"`；该文件缺失 → `stage_fail "widget executable is missing from the build under test: …"`（构建产物不完整不再以 SKIP 掩盖）；随后计算 `expected_hash`。
  - 删除 `"/proc/$widget_pid/exe"` 与路径文本哈希；改为读取运行进程自身报告的可执行文件路径（自动 trim 空白）：路径为空或文件不存在 → `stage_fail "widget process executable is missing before verification: …"`；再对该文件取 sha256，与 `expected_hash` 不一致 → `stage_fail "running widget executable is not the build under test: …"`。
  - PASS 时打印 `verified running widget extension: pid=… executable=… sha256=…`，使校验可审计（原输出只打印期望路径，与实际校验对象无关）。
- `Tests/TinyBuddyAppTests/RegressionGateScriptTests.swift`（+186）：新增 6 个确定性测试与夹具（`runWidgetReload` + 假 `pluginkit`/`ps` + 临时 app bundle，`WIDGET_TIMEOUT=1`，无需真实 App 或进程）：
  - `testWidgetReloadFailsWhenRunningExecutableIsNotTheBuildUnderTest`（核心回归：运行已安装副本 → FAIL、`OVERALL_STATUS=1`、无 PASS）；
  - `testWidgetReloadVerifiesRunningExecutableOfTheBuildUnderTest`（运行本次构建 → PASS 且输出 `sha256=`）；
  - `testWidgetReloadFailsWhenBuildUnderTestHasNoWidgetExecutable`；
  - `testWidgetReloadFailsWhenRunningExecutableCannotBeResolved`（路径不可解析 → FAIL）；
  - `testWidgetReloadSkipsWhenNoWidgetExtensionIsRegistered`（未注册 → 仍 SKIP、`STAGE-STATUS=77`、`OVERALL_STATUS=0`）；
  - `testWidgetReloadTargetsTheBuildUnderTestInsteadOfProcPaths`（静态：脚本不再出现 `/proc/`，且以 `Contents/PlugIns/$WIDGET_EXTENSION_NAME.appex` 为校验目标）。
  - 辅助：新增 `writeExecutableFile(_:at:)`（按完整路径写可执行文件）；既有 `writeExecutable(_:named:in:)` 改为其薄封装，行为不变。
- 撤销方法：`git checkout -- script/regression_gate.sh Tests/TinyBuddyAppTests/RegressionGateScriptTests.swift`；从 `.agent/history.md` 删除本条，并把 `.agent/archive/history-2026-09-23.md` 中的 Loop 16 原样移回。

**验证结果**
- 红→绿（同一 harness，仅更换被 source 的门禁脚本）：修复前 `>>> PASS: widget-reload`/`OVERALL_STATUS=0` → 修复后 `>>> FAIL: widget-reload — running widget executable is not the build under test: …`/`OVERALL_STATUS=1`；运行本次构建的场景修复前后均 PASS，修复后额外打印 `sha256=…`。
- 反向验证（新测试确实约束修复）：把工作区脚本临时替换为 `git show HEAD:script/regression_gate.sh` 后运行 `./script/swiftpm.sh test --filter RegressionGateScriptTests`：17 个测试 15 个断言失败，6 个新测试中 5 个失败、`testWidgetReloadSkipsWhenNoWidgetExtensionIsRegistered` 通过（符合“既有 SKIP 语义保留”预期）；随后按 sha256 恢复修复后脚本（与运行前留存副本一致：`36830775a03942cd89d804e02c27c6eb398ab7c23a3174b767e4b190fae86db2`）。
- 修复后 `./script/swiftpm.sh test --filter RegressionGateScriptTests`：17 个测试（Loop 24/25 的 11 个 + 本轮 6 个），0 失败。
- 修复后 `./script/swiftpm.sh test --filter 'RegressionGateScriptTests|ResourceStabilityScriptTests'`：30 个测试，0 失败（姊妹脚本 13 个既有测试未受影响）。
- 真实系统校验（只读，未启动、未终止任何 App）：source 门禁脚本后以 `APP_BUNDLE=/Applications/TinyBuddy.app`、`WIDGET_TIMEOUT=2` 直接调用 `run_widget_reload`，对真实 `pluginkit`/`ps`/`shasum` 与该机运行中的 widget 进程（pid 972）校验通过：`verified running widget extension: pid=972 executable=/Applications/TinyBuddy.app/Contents/PlugIns/TinyBuddyWidgetExtension.appex/Contents/MacOS/TinyBuddyWidgetExtension sha256=56e74a201fd1d51ceef613f4c7a0ddab6be506900682488aa6ac42d85ec71de3`、`>>> PASS: widget-reload`、`OVERALL_STATUS=0`（该哈希正是修复前实测的真实可执行文件哈希，而旧回退分支给出的是路径文本哈希 `c672d5d3…`）。
- `/bin/bash -n script/regression_gate.sh`：通过；`bash script/regression_gate.sh --list-stages`（rc=0）、`--help`（rc=0）、`--stage 0`（rc=2，参数校验未变）。
- `git diff --check`：通过；`git status --short`：仅 `script/regression_gate.sh` 与 `Tests/TinyBuddyAppTests/RegressionGateScriptTests.swift`（外加本轮 `.agent/` 记录/归档）。
- 验证级别：按 `AGENTS.md` 取 **Focused**（脚本层局部实现改动 + 同一测试类扩展，不触及共享契约、持久化、跨进程边界或 App/Widget 共享状态）；未运行 `swift test` 全量，理由见剩余风险。

**剩余风险**
- 未端到端运行 `--stage 6` / `--quick` / 全量门禁：该路径会 `pkill -x TinyBuddy`（终止本机已安装运行的 App）并构建启动 Debug App，属未授权的外部状态变更（本轮任务约束明确禁止）；本轮以注入式 harness + 一次只读真实系统调用覆盖 stage 逻辑。
- 行为语义变化（已实证，需用户知悉）：当系统为该 bundle id 注册的 widget 扩展不是本次构建的 appex（本机当前注册的就是 `/Applications/TinyBuddy.app` 的副本）时，修复前该阶段以「已安装副本」通过，修复后会 FAIL 并明确指出运行中的 widget 不是 build under test。这是 fail closed 的正确结论，但会改变本机此前的 PASS 观感；若该场景应视为环境条件而非门禁失败，需用户决定保留 FAIL 还是改为 SKIP（本轮按 Loop 24 的 fail-closed 原则选择 FAIL）。
- `run_widget_reload` 仍以 bundle id 的注册表（`pluginkit`）作为发现入口；若 macOS 只注册了本次构建的扩展而 `$PS_BIN -p … -o comm=` 输出与 `$APP_BUNDLE` 存在符号链接/路径差异，哈希比较不受影响（比较内容而非路径），但该路径未在真实 Debug 构建上验证。
- 同 stage 内既有未处理项：当 widget 进程中途消失时仍走既有 `stage_fail "widget extension did not start within …s"` 超时分支（最长 `WIDGET_TIMEOUT`，默认 30s），本轮未改动该分支语义。
- Loop 24 遗留候选仍在：`evaluate_resource_budgets` 不校验表头与字段数字性（无新证据、未发现可达的生产输入路径）。
- Loop 25 遗留候选仍在：新启用的持续 CPU 阈值未经真实 Debug App 端到端校准（需授权运行 `--stage 5`）。
- 未处理项（本轮观察到的其他候选，留待后续轮次并保持单一问题边界）：`GIT_COLD_WALL_TOLERANCE`、`WIDGET_START_TOLERANCE`、`APP_RUNTIME_TIMEOUT` 定义后从未被引用；`record_baseline` 写出的 `TINYBUDDY_BASELINE_GIT_COLD_*`、`TINYBUDDY_BASELINE_RESOURCE_*` 与 `resolve_baseline_value` 生成的键名（`TINYBUDDY_BASELINE_<STAGE>_<KEY>`）不匹配，且除 COLD/WARM start 外无人读取。
- 既有维护提示仍有效：Git 未来若新增带值选项需同步维护 `valueTakingOptions`（保守方向：误拒优于误放行）。

## Loop 27：2026-09-23：无修改轮次（未发现新的可验证剩余风险）

**Loop 编号**
- Loop 27。

**日期**
- 2026-09-23。

**观察结果**
- 起始工作区干净；当前分支 `hp/tinybuddy/t-0010-evidence-driven-maintenance-loop`，HEAD `d5e9dbb`，与 `origin/main` 一致。最近提交为 Loop 26 的 stage 6 widget 可执行文件哈希校验修复。
- 阅读近期 history 和 archive 去重。静态搜索 `rg -n "TODO|FIXME|HACK|XXX" Sources Tests Widget script` 只命中 `mktemp` 模板，无真实待办；`git diff --check` 起始状态干净。
- 复核 Loop 26 遗留的 baseline 记录疑点：`record_baseline` 对 Git/resource 记录了变量，但 `resolve_baseline_value` 只在 app cold/warm 两处被调用；未找到该差异导致当前门禁错误判定的复现或新失败证据。Loop 26 另记的端到端运行限制仍不适合在本轮触碰（会结束运行中的 App）。

**选择的问题及证据**
- 无。Loop 26 修复已在当前 HEAD；其余已知候选是历史观察而非本轮出现的新复现/失败/指标。依据 loop.md 的证据门槛，本轮不把静态疑点扩大为产品修改。
- 完成标准：工作区仅包含本轮 history 记录及按规则进行的最旧记录归档，无业务文件改动；diff 检查通过。

**原因分析**
- 观察范围内未发现新的证据确立一个比既有候选更值得处理且能安全验证的风险。对历史遗留疑点不重复制造任务，也不执行会结束已安装 App 的端到端门禁。

**修改内容**
- 无业务修改。`.agent/history.md` 追加本条，并依 Maintain 规则将 Loop 17 原样移至 `.agent/archive/history-2026-09-23.md`。

**验证结果**
- `git status --short --branch`、`git show --format=fuller --no-patch HEAD`：确认分支/提交状态。
- `rg -n "TODO|FIXME|HACK|XXX" Sources Tests Widget script`：仅模板命中。
- `rg` 核查 `record_baseline`/`resolve_baseline_value` 的调用关系及现有 baseline 测试搜索：未发现该历史疑点的现行失败用例；未运行 Swift 测试（本轮无业务代码更改）。
- 验证级别：文档/维护记录级；按契约仅需内容、范围和 diff 验证。

**剩余风险**
- Loop 26 记录的 baseline 度量键未被当前 resolver 消费，仍是待进一步确定预期契约的维护候选；本轮没有运行端到端 regression gate。未改动或掩盖该风险。

## Loop 28：2026-09-25：复核 Widget runtime gate 失败为构建环境不满足验证前提

**Loop 编号**
- Loop 28。

**日期**
- 2026-09-25。

**观察结果**
- 起始工作区干净；HEAD/origin/main 为 `692eb0e`。HEAD 是 `Project live focus duration without minute snapshot writes`，涉及焦点实时投影与测试，不修改 regression gate。
- `.agent/history.md` Loop 26 记录 stage 6 的目标是验证运行中 Widget executable 与本轮构建一致；注册表只用于发现进程。Loop 26 的只读实测显示注册扩展和运行进程均来自 installed bundle。当前 `script/regression_gate.sh:627-699` 仍先从 `APP_BUNDLE` 取 expected executable，再要求运行进程 executable hash 匹配。
- `threads/t-0015.md` 在当前仓库中不存在（`find` 未找到）；相关可查证的既有证据在 `.agent/history.md` Loop 26。`.agent/archive/` 全部检索未发现相同 widget runtime gate 问题的其他已处理条目。
- 当前门禁入口/生命周期（`script/regression_gate.sh:713`、`:853-854`）包含终止 App/Widget 的行为；本轮未运行门禁或操作已安装状态。

**选择的问题及证据**
- 不作代码修改。已记录的“注册的 installed extension 存在，但没有 workspace/build-under-test extension process”不能证明 gate 缺陷：stage 6 明确比较运行中 executable 与当前 `APP_BUNDLE` 的构建产物；仅有同 bundle id 的 installed 注册扩展，不满足该验证前提。将其改为 PASS/SKIP 或放宽匹配会削弱验证，而当前没有证据表明门禁能在正确启动 workspace extension 后仍错误失败。
- 复现/修复完成标准：需在不改注册、不终止进程的环境中，观察到本轮构建的 Widget 被正常启动却仍被 gate 错误判定；现有证据不满足该标准。

**原因分析**
- 这是运行环境未提供 build-under-test Widget 进程的验证限制，而不是已证实的 gate 误判。历史 Loop 26 已分别证明“非本轮构建的 installed executable 应失败”以及真实 installed bundle 被正确识别；本轮没有新的反例。

**修改内容**
- 无业务修改；仅追加本条并将 Loop 18 原样归档至 `.agent/archive/history-2026-09-25.md`。

**验证结果**
- 只读检查 `git status`、HEAD 变更摘要、当前 `run_widget_reload` 实现、历史/归档及 `threads/t-0015.md` 文件存在性；未执行测试或 runtime gate（该 gate 路径可能终止 App/Widget，明确禁止）。
- 验证级别：维护记录/静态复核；没有代码变化，按契约不运行 Swift 测试。
- 最终对照 diff、`git diff --check` 与 `git status --short`。

**剩余风险**
- workspace extension 的真实启动路径未验证；没有 `threads/t-0015.md` 的原始上下文，结论仅基于 Loop 26 的仓库记录和当前脚本。要进一步端到端验证需可安全启动 build-under-test Widget 的隔离环境；不得通过改动已安装注册状态或终止用户进程获得证据。

## Loop 29：2026-09-26：通过二分定位缩短焦点历史分页游标查找

**观察结果**
- 起始工作区干净，HEAD/origin/main=`f8d60fa`；阅读 Loop 契约、近期 history 与 archive。最近 performance commits 聚焦实时 focus snapshot/persistence；本轮不重复。
- `FocusSessionQueryService.execute` 每个分页先全量过滤、排序，然后用 `firstIndex(where:)` 线性定位 cursor；`FocusSessionQueryPerformanceTests.testFullPaginationTime` 以 10,000 sessions、100 pages 可复现该成本。
- 同一测试修复前两次均通过，耗时 0.729s（[0.719304, 0.735418, 0.731971]）及 0.742s（[0.752031, 0.737059, 0.736963]）。

**选择的问题及证据**
- 对已排序结果的 cursor 定位为 O(n)，每个分页重复扫描；采用二分查找应降为 O(log n)，且完成标准是排序/分页既有测试通过、全分页相同 workload 性能下降显著。

**修改内容**
- `Sources/TinyBuddyCore/FocusSessionQueryService.swift`：用排序次序的二分查找替代 `firstIndex(where:)`，其余过滤、排序、cursor-miss 及分页结果语义不变。

**验证结果**
- 修复后同测试 workload 耗时 0.628s（[0.621527, 0.627593, 0.634967]）、0.630s（[0.636541, 0.629228, 0.625150]）；相对两轮基线中位数 0.7355s，减少约 14.4%（耗时约减少 0.106s/100 pages）。环境 Swift 6.4 / Xcode 27，arm64，本机 SwiftPM Debug。
- `./script/swiftpm.sh test --filter 'FocusSessionQueryTests|FocusSessionQueryPerformanceTests'`：34 tests，0 failures；`./script/swiftpm.sh build`：通过。Focused/module validation；无持久化或跨进程契约变化。
- 曾尝试 `TINYBUDDY_FOCUS_BENCHMARK_MODE=baseline ... test --filter SustainedFocusPersistenceBenchmarkTests`，该 unrelated historical comparator 测试失败（基线模式预期 apply passes 480、实际 0）；该失效探针未用于本轮数据。后续分页基准为 HEAD/候选同一 XCT workload 的成功对照。

**剩余风险**
- 每次查询仍需调用 provider、过滤和排序，因此只优化 cursor 定位；总体提升依赖页数/数据量。本轮未运行全量测试。
