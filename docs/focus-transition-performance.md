# 专注会话提交路径性能

## 可重复工作负载

基线为执行时 main 的 c564fe333f；两侧使用同一份工作树、同一份测试文件，只回退
Sources/TinyBuddyCore/FocusSessionEngine.swift、FocusSessionStore.swift 与
TinyBuddyTimeEnvironment.swift 的生产改动。测试环境为 arm64 macOS 27.2（26B123）、
Apple M2（16 GB）、Apple Swift 6.4，-c release。

FocusSessionTransitionPerformanceTests.testTransitionCommitBenchmark 在同一进程内
构造 666 / 2000 / 8000 / 16000 条已完成会话：历史按生产归档的追加顺序（startedAt 升序），
每天最多 6 条、无重叠，每条带 started/ended 两条决策事件。每个规模先跑一次预热周期，再跑
5 个 start/pause/resume/end 周期，取每次操作 5 个样本的中位数；随后测量 5 次
foregroundProjectChanged 无状态变化报告（无打开会话）的中位数。

两种持久化：memory 是 FocusSessionArchivePersisting 内存桩，隔离引擎自身成本；
file 是生产用的 FocusSessionFileStore（JSON 编码、原子替换、保留 .bak 备份）。

~~~sh
TINYBUDDY_FOCUS_TRANSITION_BENCHMARK=1 TINYBUDDY_FOCUS_TRANSITION_SIZES=666,2000,8000,16000 \
  ./script/swiftpm.sh test -c release --filter FocusSessionTransitionPerformanceTests

# 基线：只回退生产实现，保留同一份测试
git stash push -- Sources/TinyBuddyCore/FocusSessionEngine.swift \
  Sources/TinyBuddyCore/FocusSessionStore.swift Sources/TinyBuddyCore/TinyBuddyTimeEnvironment.swift
# 重跑上面的命令
git stash pop
~~~

## 测量结果（中位数，毫秒）

| 存储 | 历史条数 | start 基线 | start 本轮 | 加速 | no-op 基线 | no-op 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| memory | 666 | 12.04 | 0.53 | 22.8× | 0.384 | 0.0008 | 480× |
| memory | 2,000 | 37.56 | 1.42 | 26.4× | 1.081 | 0.0034 | 318× |
| memory | 8,000 | 155.08 | 5.43 | 28.6× | 4.306 | 0.0129 | 334× |
| memory | 16,000 | 312.39 | 10.92 | 28.6× | 8.868 | 0.0253 | 350× |
| file | 666 | 32.06 | 20.14 | 1.59× | 0.369 | 0.0008 | 461× |
| file | 2,000 | 96.29 | 58.50 | 1.65× | 1.065 | 0.0033 | 323× |
| file | 8,000 | 381.53 | 229.67 | 1.66× | 4.236 | 0.0126 | 336× |
| file | 16,000 | 756.63 | 458.09 | 1.65× | 7.467 | 0.0247 | 302× |

pause/resume/end 与 start 同量级（同一实现路径），表中省略。用户可见的 file 路径
包含完整持久化；memory 的差距说明剩余成本主要在 JSON 编码与磁盘写入，而不是本轮
改动的引擎逻辑。

FocusSessionArchive.isSemanticallyValid（每次持久化提交都会执行）单独测量：

| 历史条数 | 基线 | 本轮 | 加速 |
| --- | ---: | ---: | ---: |
| 666 | 1.085 | 0.289 | 3.75× |
| 2,000 | 3.121 | 0.858 | 3.64× |
| 8,000 | 12.352 | 3.552 | 3.48× |
| 16,000 | 24.608 | 6.900 | 3.57× |

这些是同一台机器的 Release 中位数。绝对耗时很小；收益主要是把「历史规模 × 每次变更」
的线性放大压回去，避免长期使用后暂停/恢复/结束出现数百毫秒的主线程停顿。

## 根因与改动（调用位置）

1. **无状态变化的报告仍做整档校验**：FocusSessionEngine.applyLocked 原先先
   validate(working) 再比较 working != previous。前台应用切换、空闲轮询、
   Git 活动、重复手动命令等都会进入这里，即使什么都不改也要扫完整历史。
   现在先判断是否变化；已提交状态在进程内通过一次校验后，no-op 直接返回。
   首次 no-op 仍执行校验，因此非法载入归档的拒绝语义不变。
2. **每次提交重新生成全部证据**：generateEvidenceForSessions 对每条会话做
   SHA-256 与字符串构造。现在 updatedEvidence 只为 historyChanges 返回的变更行
   重新生成，其余沿用上一版已提交记录。证据是会话内容的纯函数，未变更行的复用结果与
   全量重算等价（由新增差分测试固定）。
3. **每次提交构造两份字典 + 全集 + 排序键**：historyChanges 增加追加、原位修改、
   单条删除三种保序快路径，只有编辑/拆分/合并/撤销等改变顺序的形状才回退到原字典差分。
4. **每次提交重建提醒缓存**：rebuildReminderCache 原先遍历全部会话；现在按变更行
   增删当天的已结束时长与唯一打开会话槽位。
5. **整行排序的写时复制与 retain/release**：引擎校验与归档校验只排序索引（indices），
   不再搬运 177 字节的 FocusSession 值；输入已按开始时间有序时（生产追加归档的常态）
   直接做相邻检查，不排序。边界排序对相同 startedAt 用原始下标保证与稳定排序一致。
6. **每次归档校验的分配**：isSemanticallyValid 改为单趟扫描，复用 Set 而不是
   map/flatMap/compactMap 四个中间数组。
7. **isValidDayIdentifier 每条会话构造一个 Calendar**：归档校验对每条会话调用它，
   原实现每条都创建 Calendar/TimeZone/Locale/DateComponents 并做一次格式化回读。
   现在 1583 年及以后使用固定宽度解析 + 公历闰年规则；1582 年公历切换之前仍走原
   Calendar 回读，避免历史日期语义变化。空白字段检查也改为不分配字符串的 Unicode
   标量判断，覆盖 CharacterSet.whitespacesAndNewlines 的全部码位（包括 U+200B）。

## 等价性与回归覆盖

新增 FocusSessionIncrementalCommitTests：每个 start/pause/resume/end、
历史编辑、删除、撤销之后，把引擎的提醒指标、历史聚合快照与证据内容分别与
「从当前全部会话重新计算」的结果对比。证据比较忽略随机生成器产生的记录 ID 与
决策解释 ID，其余字段逐项相等。另有 testNoOpReportsDoNotRepublishOrRewriteIncrementalState
固定 no-op 不改变会话与证据。
针对审核指出的缺口，另外覆盖：载入的证据信封缺项在启动时补齐并在后续增量提交中保留；
崩溃恢复写入失败后内存证据仍反映 crashRecovery 决策；墙钟回拨超过容差时无变化报告
重新执行完整校验（返回 rejectedInvalid，与旧实现一致）；删除会话后提醒总时长按归档
顺序精确重算。

TinyBuddyTimeEnvironmentTests 新增两组：把快速日期校验与实际 Calendar 回读在
1583–2400 的月/闰边界与 2401–9999 的稳定样本上逐值比较；并固定 1582 年公历切换、
0001/0999/9999、非法月份/Day、泰文数字等边界。FocusSessionFileStoreTests
新增乱序非重叠、乱序重叠、空白字段（含 U+200B）与非法公历日期用例。

验证范围选择 **Full suite**：改动触及核心引擎的不变量校验、持久化归档校验与
共享日期语义。执行 ./script/swiftpm.sh test：TinyBuddyCoreTests 1,095 项
（2 项 opt-in 跳过）与 TinyBuddyAppTests 741 项（2 项默认跳过）均 0 失败，退出码 0；
git diff --check 通过。
没有运行 GUI 回归、script/regression_gate.sh、release-install：这些会启动真实 App、
使用真实持久化环境或替换安装包，超出本次无外部写入授权。

## 残留下界

- **持久化仍是整档 O(历史) 编码与写入**：file 16,000 条约 458 ms，其中引擎逻辑约
  13 ms，其余是 JSON 编码、原子替换与备份写入。按内容缓存每行编码片段可以把这部分降到
  几十毫秒，但会在常驻内存里再保留一份接近归档大小的缓存（16,000 条约 10 MB，含证据
  更大），与本次降低长期内存占用的目标冲突，因此没有实施。生产归档当前规模（本机
  666 条、约 1.5 MB）下该成本约 20 ms。
- **每次变更仍扫描全部会话做不变量检查**：16,000 条约 7 ms（原 312 ms 的其余部分）。
  进一步降低需要维护增量索引（ID 集合、有序开始时间、重叠邻接），改动面明显大于收益。
- **受影响提醒日按归档顺序重算**：每次提交会为受影响的日期重扫一遍会话（通常 1 天，
  16,000 条约 1 ms）；超过 16 个受影响日期（例如一次撤销）回退到单趟全量重建。
  这样与全量重建逐位一致，不再有浮点增删的阈值漂移。
- **证据归档的 id 稳定性**：未变化会话的证据记录（含随机 id）现在跨提交保持，
  不再每次变更全部换新；未发现消费者依赖这一随机值，但这是可观察的内部差异。
- **载入证据的首次对账是一次性的**：归档证据信封非空时，第一次成功提交会按当前规则
  全量重建一次证据（与旧实现「每次提交全量重建」的首次提交结果一致），之后才增量
  更新；缺项在启动时补齐，崩溃恢复写入失败时在内存中重建。代价是每次启动后的第一次
  成功提交多一次 O(历史) 证据生成（16,000 条约 200 ms，666 条约 10 ms），不发生在
  启动路径上。孤立的多余证据条目不会被主动清理。
- **无变化报告的校验缓存绑定墙钟**：缓存记录的时刻与 validate 使用同一次墙钟读数；
  时钟回拨到该时刻之前会重新执行完整校验，与旧实现一致；只向前推进的时钟不会重复校验。
- **项目切换的提醒槽位分两趟处理**：先清空所有被结束的打开会话，再写入新的打开会话，
  不再依赖变更列表里的 UUID 排序。
- 本轮只测 CPU 耗时，没有单独测分配量、RSS 或真实 GUI 帧率；性能测试是 opt-in，
  默认不进入 CI。
