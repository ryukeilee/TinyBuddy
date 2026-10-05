# 专注提醒心跳性能验证

基于执行时最新 `origin/main`：`6447a63`（`Add quick date ranges to focus history`）。

## 改动与复杂度边界

`FocusSessionAppBridge` 的周期提醒读取 `FocusSessionEngine.reminderMetrics`，不再取得 `allSessions`。引擎在初始化、崩溃恢复和成功的会话变更、编辑、撤销后重建按日累计时长；失败持久化不改变缓存。每次读取只查询一天的累计值，并计算最多一个开放会话的实时累计时长和连续区间。连续区间起点也在状态变更时捕获，心跳不搜索决策事件。

提醒请求在进入异步权限查询前捕获固定大小的 `FocusReminderMetrics`，不保留整个会话数组。提醒引擎共用原有门控、冷却、权限、安静时段与状态保存流程。持续活动和持续空闲的无变化检查复用开放会话缓存；空闲结束阈值满足时仍执行原来的验证和持久化。

稳态心跳的会话查询和提醒计算与历史会话数无关，包括当天已经结束的会话。缓存按历史日期存储累计值；其存储量与日期数相关，不在每次心跳分配。真实开始、暂停、恢复、切换、结束和历史编辑仍使用原来的全档事务处理；本次没有改变这些操作的复杂度、心跳频率或持久化格式。

## 可重复基线

```sh
TINYBUDDY_REMINDER_BENCHMARK=1 ./script/swiftpm.sh test -c release --filter FocusReminderHeartbeatTests/testHeartbeatPerformanceBaseline
```

基线使用同一个引擎与不可变数据：旧路径为 `engine.allSessions` 加保留的数组提醒入口（全档查找开放会话、按天过滤、累计）；新路径为缓存指标读取加指标提醒入口。两者共用提醒规则，旧路径相较原实现只查找一次开放会话，是偏保守的扫描基线。测量不含夹具初始化、真实状态变更、通知权限 I/O 或 `UserDefaults` 写入；这些固定工作仍照原流程执行。

每组包含一个活动会话：无关历史组为 100、10,000、100,000 条，分散到过去日期，每天最多 100 条；当天历史组为 100、1,000、10,000 条。先预热，再对 100 次评估测量 5 轮，报告每次耗时中位数。结果被消费并检查语义等价，避免只测到未使用的计算。性能测试要求每组最大历史量相对旧路径至少改善 10 倍，历史量增加 1,000 倍或 100 倍时新路径耗时增长低于 20 倍；该宽松相对门槛用于防止扫描退化，不用于保证特定机器的绝对延迟。

2026-10-05 实测环境：Apple M2，macOS 27.0.1（26A434），Apple Swift 6.4，`-c release`。单位为每次评估的微秒。

| 场景 | 历史会话 | 全档扫描基线 | 缓存指标路径 | 改善倍数 |
| --- | ---: | ---: | ---: | ---: |
| 过去日期 | 100 | 2.167 | 0.655 | 3.3 |
| 过去日期 | 10,000 | 137.067 | 0.684 | 200 |
| 过去日期 | 100,000 | 1,433.357 | 0.699 | 2,050 |
| 当天 | 100 | 11.213 | 0.673 | 16.7 |
| 当天 | 1,000 | 103.237 | 0.672 | 154 |
| 当天 | 10,000 | 1,050.221 | 0.672 | 1,564 |

无关历史增加 1,000 倍，新路径耗时约为 1.068 倍；当天历史增加 100 倍，新路径耗时约为 0.998 倍。该测量包含锁与指标读取以及实际提醒规则计算，不包含 OS 通知服务与持久化开销，因此不能把上述倍数直接解释为整个 App CPU 的改善倍数。

最初将十万条历史集中到单日的测量未完成，已终止该测试子进程。原因是既有 `FocusHistoryAggregationCache` 初始化逐条复制日集合的成本，发生在计时区间外；本次没有修改历史聚合。修正后的完整基线通过，用过去日期十万条和当天一万条覆盖两种增长维度。原未完成日志为 `.build/reminder-heartbeat-release.log`，成功日志为 `.build/reminder-heartbeat-release-corrected.log`。

普通测试还检查心跳接线没有重新使用历史数组、指标读取没有遍历会话或决策事件，并验证反复读取不加载或保存存档。行为测试对照完整历史计算，覆盖暂停/恢复、长时间连续专注、提醒阈值、权限恢复、安静时段、跨日、编辑、删除、撤销、失败持久化和重启修复失败。

## 验证范围

选择 **Module/contract**：改动跨专注提醒的 Core 与 App 边界，增加兼容指标入口和内存派生缓存；没有改变共享快照、持久化模型、迁移或 Widget 数据契约。证据为相关 Core/App XCTest、直接消费者编译、Release 性能基线、最终 diff 与 `git diff --check`。

最终执行：

```sh
./script/swiftpm.sh test --filter 'FocusSession|FocusReminder|FocusNotification|FocusGoal|SustainedFocusPersistenceBenchmark'
TINYBUDDY_REMINDER_BENCHMARK=1 ./script/swiftpm.sh test -c release --filter FocusReminderHeartbeatTests.testHeartbeatPerformanceBaseline
git diff --check
```

Core 334 项：333 通过，默认跳过 1 项 opt-in 性能测试；App 30 项全部通过。性能测试另以 Release 单独运行通过。Debug 与 Release 构建成功，编译器仍报告仓库既有的未使用变量等警告。最终相关测试日志为 `.build/reminder-final-validation.log`。对照最终 diff 复核缓存写入点、失败路径和 App 接线，`git diff --check` 通过；独立只读审查未发现 blocking 问题。

没有运行会停止并启动真实 App 的 `script/regression_gate.sh --quick`，也没有安装或签名验证：该脚本的启动阶段会执行 `pkill`、启动本地 App 并使用真实持久化环境，超出本次无外部写入授权。这里的证据证明提醒热路径的历史规模独立性，不代表已测量真实 GUI 进程的整机能耗、RSS 或长期通知服务延迟。
