菜单栏常驻刷新优化与验证（2026-10-06）

基线为 `main` / `origin/main` 的 `1b67af63cb50ea2685f7fe99b1844b1cc5496f22`，开始时工作区干净，并通过 `git fetch origin main` 确认一致。测量环境为 macOS 27.0.1、arm64、SwiftPM Debug。

检查了菜单栏、`FocusSessionAppBridge`、HUD 手动专注时长、HUD/Widget 时间线与 Git 刷新协调。菜单栏原先在所有状态下每 2 秒执行一次刷新；持续手动专注时，`ManualFocusControlState` 的时长字段还会使完整状态比较每次都通过，重复设置仅显示整数分钟的标题。Bridge 的输入检测同时负责确认自动专注、idle、跨日和提醒，HUD 秒数对用户有可见信息增量，因此本次只修改菜单栏投影。

空闲、暂停由既有提交回调和事件通知更新，不再设置定时器。关闭弹层的持续专注按累计专注时长的下一个分钟边界调度；打开弹层按秒边界调度。一次刷新只读取一次引擎状态，复用到弹层；标题只比较状态种类、项目名及整数分钟。增加 Git 最近项目、时钟变化、前台激活、唤醒事件的即时同步，并在弹层自动关闭时释放隐藏内容和恢复分钟精度。

测量使用真实 `ManualFocusMenuBarController`、`NSStatusItem`、系统 `Timer` 和 `FocusSessionEngine`，会话存储隔离在内存中。每个场景预热 5 秒，再采样 65 秒；弹层均关闭，不激活测试界面。记录定时器回调数与 `proc_pid_rusage(RUSAGE_INFO_V4)` 的 CPU、wakeups、physical footprint。基线只加入定时器工厂插桩，不改变原来的 2 秒重复调度。

| 场景 | 周期执行次数，前 → 后 | CPU 时间 ms，前 → 后 | 进程 wakeups，前 → 后 | 稳态 footprint 增量 KiB，前 → 后 |
| --- | --- | --- | --- | --- |
| 空闲常驻 | 33 → 0 | 2.969 → 2.818 | 646 → 614 | +16 → 0 |
| 持续手动专注 | 33 → 1 | 4.512 → 2.860 | 659 → 614 | −48 → −48 |
| 非活跃界面、暂停专注 | 33 → 0 | 2.926 → 2.740 | 646 → 613 | −144 → −48 |

确定收益是菜单栏周期执行减少 100% / 97% / 100%，也消除了空闲和暂停状态的常驻菜单栏定时器。三个修改后窗口内 footprint 均未增长。窗口结束时 footprint 的前后差异分别为 −96、−80、+64 KiB，最后一项约 0.5%，未观察到与优化相关的持续增长。

CPU 和 wakeups 是 XCTest 进程的总计，包含其自身约 10Hz 的基础活动；CPU 绝对值很小，不能据此宣称整个 App 的 CPU 降幅。这里确认的是实际菜单栏执行路径的周期工作下降；整 App Debug 对比见下文；未做长时间内存 soak 或签名 Release 验收。

复现命令：

```sh
./script/benchmark_menu_refresh.sh --baseline 1b67af63cb50ea2685f7fe99b1844b1cc5496f22
./script/benchmark_menu_refresh.sh
```

`--baseline` 将指定版本导出到临时目录，只复制测量测试、插入定时器工厂，然后执行相同采样，结束后删除自己创建的目录；不会修改当前工作区或安装的 App。默认分支与完整 `--baseline` 分支均已实际执行。最终基线复现仍为三个场景各 33 次执行，CPU 分别为 3.525 / 4.656 / 3.287 ms；机器活动不同，不用跨时段的小 CPU 差异重新估算整 App 收益。脚本只用于本地验证，依赖 Bash、Git、tar、Python 3 与 Swift，不进入 App 的签名运行时边界。

验证级别选择 **Focused**：最终生产 diff 仅涉及一个 App 菜单栏控制器，不改变 Core 公共接口、持久化模型、共享快照、Git 扫描或签名设置。SwiftPM 编译了直接消费者，并运行了用户要求涉及的已有相邻回归；没有运行不相关的全套测试或 Release 安装。

实际执行的主要验证：

- 基线：`TINYBUDDY_MENU_BENCHMARK=1 ./script/swiftpm.sh test --filter ManualFocusMenuBarControllerTests`（当时测量测试尚未拆分文件）。
- 相邻回归：`TINYBUDDY_MENU_BENCHMARK=1 ./script/swiftpm.sh test --filter 'ManualFocusMenuBarControllerTests|FocusHistoryPresentationConsistencyTests|PetViewModelTests|FocusSessionAppBridgeResetGateTests|FocusSessionEngineManualControl|FocusNotificationDeliveryTests|TinyBuddyWidgetReloadCoordinatorTests|TinyBuddyWidgetTimelinePolicyTests|GitActivityRefreshCoordinatorTests'`：83 个 Core、169 个 App 测试通过。该进程先运行其他测试，故其内存绝对值不用于最终性能对比。
- 独立修改后采样：`./script/benchmark_menu_refresh.sh`，测量测试通过，结果见上表。
- 最终 UI 路径：`./script/swiftpm.sh test --filter 'ManualFocusMenuBarControllerTests|FocusHistoryPresentationConsistencyTests'`：12 个测试通过，涵盖即时提交回调、开始/暂停/恢复/结束、分钟边界、唤醒/时钟/Git/注册项目事件、停止后清理、真实弹层开关、自动关闭和过期关闭回调。
- `/bin/bash -n script/benchmark_menu_refresh.sh`、`git diff --check`。

弹层验证曾失败：呈现阶段读取 `isShown` 不能可靠启动秒级调度，仅接 `didShow` 也未通过真实窗口测试。最终按控制器拥有的弹层呈现生命周期调度，关闭回调清理引用；修正后相关测试通过。最终弹层修正没有改变表中弹层关闭的采样路径，因此没有重复其已通过的 210 秒采样。

未更改 Bridge 的 5–15 秒输入检测和提醒评估、HUD 活跃手动专注的秒级更新、Git 的低电量/后台策略或 Widget 自调度。相邻自动化回归覆盖了这些策略，桌面 Widget 的实际渲染、长时间自然开发及真实睡眠/唤醒、跨日、低电量操作仍未逐项手工重现；相邻自动化测试覆盖相关策略，不能替代所有真实环境验证。


实际 App 对比

用户授权临时退出当前 App，依次运行 main 与候选 Debug，不替换 `/Applications`。界面工具无法定位运行中的 accessory 实例，用户不在电脑前，因此使用 `script/prepare_app_resource_scenario.py` 给两份 `git archive` 导出的临时源码加入相同驱动。驱动在启动恢复后调用现有 `PetViewModel` 手动开始、暂停、恢复、结束路径，读取真实引擎、HUD、历史投影和原生进程资源计数；没有模拟计数或修改生产启动逻辑。弹层保持关闭，所有采样 `NSApp.isActive=false`，HUD 与后台服务正常运行。会话实际写入历史，测量没有删除历史或重置用户配置。

两份临时项目分别以 `xcodebuild -project TinyBuddy.xcodeproj -scheme TinyBuddy -configuration Debug -derivedDataPath <独立目录> -destination platform=macOS build` 构建，再直接启动各自 bundle 的 executable。候选仅覆盖菜单栏控制器。使用现有签名配置，没有运行 `release-install`、修改 signing 或安装包。构建曾有一次驱动的 optional registry 访问编译错误，修正后两版构建通过。

完整场景在启动后 60/125 秒采样空闲，135 秒开始手动专注、140/205 秒采样持续专注，215 秒暂停、220/285 秒采样暂停，295/300 秒恢复/结束。下表为原生进程与子进程累计计数的窗口差值（定时任务在后台可被 coalesce，65 秒是计划窗口，不是严格实时 deadline）。

| 场景 | wakeups，main → 候选 | CPU 时间 ms，main → 候选 | footprint 窗口增量 MiB，main → 候选 |
| --- | --- | --- | --- |
| 空闲常驻 | 44 → 10 | 1.174 → 0.263 | +0.016 → 0 |
| 持续手动专注、界面非活跃 | 277 → 132 | 29.024 → 20.805 | +1.938 → +1.047 |
| 暂停、界面非活跃 | 55 → 53 | 1.229 → 2.614 | −1.984 → +1.000 |

暂停窗口包含异步状态提交的采样边界，不用其 CPU/内存变化声称收益。CPU 绝对值很小；明确收益是原有 2 秒无信息增量刷新被去掉，以及实际 App 空闲/持续专注窗口 wakeups 的下降。Bridge、HUD 可见秒数、Git、Widget 自调度仍执行。

第一轮候选在暂停/恢复/结束采样点出现引擎/HUD 控制状态已转换、历史投影仍旧的现象。没有直接判为通过；两版追加单调时钟追踪（`--transition-trace`），记录 command、history emitted、main callback、combined write outcome、HUD readback、Widget reload request。基线复测也捕获到同样的瞬时旧投影。实际从命令执行到 HUD 重读，main 四次转换为 116/111/101/109 ms，候选为 101/96/112/116 ms；combined 写入均 `saved`，随后发出 Widget reload 请求。后台多个 overdue 定时任务集中执行，采样可紧跟在命令后、早于其异步 main callback，不能把计划相隔 1–5 秒当作实际提交延迟。两版都约 0.12 秒内完成，未发现候选的提交及时性回退。当前复现脚本额外输出采样 uptime，方便后续严格计算窗口；这一输出字段追加后仅作 Python 编译验证，没有重跑整 App。

内存：首轮 idle footprint main 39.47 MB、候选 44.84 MB，存在启动绝对值差异；第二轮 main 45.11 MB、候选 47.78 MB，两版 idle 窗口完全平稳；第二轮结束候选 55.07 MB，低于 main 58.74 MB。运行顺序会累积真实会话，进程布局、异步服务也不同，因此这些绝对值不能证明内存下降或稳定的候选增量。隔离控制器测试没有持续增长；整 App 没有观察到对应的持续增长趋势，但短窗口不能排除长时间内存问题。

两版启动 Git 均报告既有 `gitActivityRefresh.scriptExecution.partialRecovery`，没有为测量修改授权目录；共享快照只读 verifier 在 main 专注与候选结束后验证 schema/day/status 正确。未把它当作签名 Release 验收。

Xcode 构建自动注册过临时 Debug Widget。完成后使用 `pluginkit -a /Applications/TinyBuddy.app/Contents/PlugIns/TinyBuddyWidgetExtension.appex` 恢复 canonical 注册；最终 `pluginkit -m -A -v -i com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension` 只有一个 `/Applications` 条目。原安装版 executable SHA-256 前后完全一致，并已直接重新启动，进程路径为 `/Applications/TinyBuddy.app/Contents/MacOS/TinyBuddy`。恢复启动初期只读 verifier 曾返回 `legacyMirrorMismatch`，随后启动刷新完成，同一读取通过（schema 3、当日、idle）。未替换安装包，未删除用户记录。

本地证据位于忽略目录 `.build/perf-evidence/`：`baseline-scenario-runtime.log`、`candidate-scenario-runtime.log`、`baseline-trace-runtime.log`、`candidate-trace-runtime.log` 和对应构建日志。隔离控制器证据为 `/tmp/tinybuddy-menu-before.log` 与 `/tmp/tinybuddy-menu-final-resources.log`。它们不提交，以免把机器本地信息写入仓库。

## 最终启动对比与验收复核

使用上述两份已经成功构建的 Debug bundle，确认导出源码仅 `ManualFocusMenuBarController.swift` 不同，并通过 `cmp` 确认候选控制器与最终工作区完全相同。两版启动/转换插桩相同。追加三组交替顺序的实际进程启动，读取现有的、绑定本次 PID 的 HUD 可见且关键状态已恢复标记，以及 `Cold start completed duration`。每次只终止脚本自己启动的进程；如果已有 TinyBuddy App 运行则拒绝执行，不使用全局 `pkill`。启动测量在手动操作驱动触发前结束，因此不产生新的测试会话，但正常启动服务仍可能更新原有持久化状态。

```sh
python3 script/benchmark_app_startup.py \
  .build/perf-baseline/Build/Products/Debug/TinyBuddy.app \
  .build/perf-candidate/Build/Products/Debug/TinyBuddy.app \
  --evidence-dir .build/perf-evidence/startup-final
```

| 组别（运行顺序） | 基线首次可用 ms | 候选首次可用 ms |
| --- | --- | --- |
| 1（基线 → 候选） | 489 | 445 |
| 2（候选 → 基线） | 435 | 437 |
| 3（基线 → 候选） | 442 | 435 |
| 中位数 | 442 | 437 |

这些是 App 内既有启动时钟至已恢复可见 HUD 的时长，**不是清空系统缓存的冷启动，也不是包含动态链接的完整进程启动耗时**。脚本另记从创建进程至读到日志的 `observed_ms`，包含日志查询成本，不用于声称界面延迟。5 ms 的中位数差异不可视为明确启动收益；结果只支持没有明显启动回退。没有为这种微小差异再改动关键启动恢复路径。

最终验证级别仍为 Focused。本轮实测 `./script/swiftpm.sh test --filter 'ManualFocusMenuBarControllerTests|FocusHistoryPresentationConsistencyTests'`：12 个测试通过，编译成功；完整基线复现测量测试通过。Python 两份工具通过 `ast.parse` 语法检查，Bash 通过 `bash -n`。既有两版 Xcode 构建日志均为 `BUILD SUCCEEDED`。当时检查 `pluginkit -m -A -v` 只显示原 `/Applications` 条目；启动脚本不显式构建、安装或注册 Widget，但 macOS 可能在直接启动测试 bundle 时自动登记其扩展。后续安装使用包含重复记录的 `-D` 检查发现两个测试注册，处理见下节。最终生产改动仍仅一个菜单栏控制器，不涉及 Core、数据格式或跨进程协议。

覆盖审计：空闲 CPU/内存/wakeups 有真实 App 和隔离控制器对比；启动/首次可用有三组真实 App 对比；常用开始/暂停/恢复/结束有命令至 HUD 重读追踪与提交正确性证据，弹层开关有真实 AppKit 测试；高频菜单栏后台刷新有真实系统 Timer 的前后执行次数及资源计数。明确改善为不必要的周期工作及空闲/持续专注的后台唤醒，不宣称内存绝对值、启动或命令响应都有可靠下降。未发现新增明显回归；未完成长时间 soak、系统缓存冷启动、真实跨日/睡眠/低电量手工验证或签名 Release 安装，不能将本次结果扩展为这些场景的验收。

本轮补充原始证据：`.build/perf-evidence/menu-baseline-reproduction.log`、`menu-final-tests.log`、`startup-final.log`、`startup-final/startup-results.json` 与逐次 PID 绑定标记日志。

## 用户授权的本机签名安装

性能验证后，用户明确授权签名、替换安装包、启动与提交推送。macOS 27 不支持本项目的 profile-free App Group 合约，因此使用本机 Apple Development 签名与匹配 profiles，而不是分发或公证流程：

```sh
xcodegen generate
TINYBUDDY_SIGNING_MODE=signed ./script/build_and_run.sh release-install
```

工程重新生成没有产生 diff。第一次签名构建通过，但原子安装前的 `pluginkit -m -A -D -v` 检查发现 `.build/perf-baseline` 与 `.build/perf-candidate` 两份测试 bundle 的重复注册，因此失败关闭，未替换正式 App。只用 `pluginkit -r` 移除这两个已知性能测试扩展的注册，保留 canonical 注册，然后同一安装命令重试通过。

最终 `release-install` 的四个 stage 均 passed，`overall.status` 为 `state=passed` / `exit_status=0`，存在锁清理后的 `release-complete`。已验证 `/Applications/TinyBuddy.app` 的 App 与 Widget 运行路径及哈希匹配安装包，HUD 可见、保存的目录授权身份保持不变、启动 Git 刷新为有效 partial；HUD 与 Widget 消费相同 schema 3、revision 和当日快照。完整日志位于 `.build/perf-evidence/install-final-retry.log`，终态证据目录名为 `20261006-181443-38343`（系统临时目录下的 `TinyBuddyReleaseEvidence`）。本次是本机安装验证，**不是完整 `release-acceptance` 或分发验收**；没有重复运行已通过的相同输入 `release-verify`。
