# 专注历史查询性能

## 可重复工作负载

基线为执行时工作树所在提交 `768871913afa805b7738253ab305fe02e03cee6c`；工作树内
未提交改动只涉及手动专注项目选择器与复核视图的项目选择，不含历史查询路径。
测试环境为 arm64 macOS 27.0.1（26A434）、Apple M2（16 GB）、Apple Swift 6.4，
使用 Release 编译。

`HistoryQueryPerformanceTests.testHistoryQueryScenarioBaseline` 使用生产接线：
`FocusSessionQueryService` 的 provider 返回内存会话数组，`projectResolver` 直接调用
真实 `TinyBuddyProjectRegistry.resolve(projectKey:)`（60 个已注册项目，会话以历史别名
键存储，必须逐个解析到规范身份），经 `HistoryQueryController` 以生产页面大小 50 消费。

数据集为 8,000 / 16,000 条会话，跨越 730 个真实公历日（UTC 固定参考日 `2026-07-22`
向前，按每日行数分配时段），只有最新一天保留一个进行中与一个已暂停会话（与真实档案
一致，开放会话只可能属于当天），其余为已结束会话，半数带决策事件。

provider 数组顺序有三种模式，`TINYBUDDY_HISTORY_BENCHMARK_ORDER` 选择：

| 模式 | 含义 | 与生产的关系 |
| --- | --- | --- |
| `chronological`（默认） | 严格按 `startedAt` 最旧在前 | 从未被重写过的档案：`FocusSessionEngine` 在会话开始时 `append` |
| `edited` | 在 `chronological` 基础上把每 50 行中的 1 行移到末尾 | 被用户编辑过的档案：`editSession`/`splitSession`/`mergeSessions` 都是 `remove(at:)` + `append(contentsOf:)`，替换行重新追加到末尾，`undoLastEdit` 也会重建数组 |
| `shuffled` | 固定种子完全打乱 | **不可达**的乱序代理，给出这一个乱序布局的测量值（代理，不是乱序比例区间，也不是 introsort 时间的可证上界） |

`edited` 的 2% 是「被用户编辑过的档案」的代表性假设，**真实重写行占比未测量**：编辑完全
由用户驱动、无上限（8,000 条里 160 行 ≈ 80–160 次分割/合并即可达到），实际比例可能更高；
`shuffled` 只给出更坏顺序下的成本区间。三种模式在两侧测量中数据完全相同。

场景对应用户可见操作：

| 场景 | 对应操作 |
| --- | --- |
| `refreshFirstPage` | 打开历史列表：项目选项 + 第一页 |
| `serviceProjects` / `serviceFirstPage` / `serviceFilterOnly` | 三次服务读取各自的份额（`serviceFilterOnly` 为 `status == .ended` 整档筛选，不含排序） |
| `fullPagination` | 从首页滚动到历史末尾（`refresh()` + 全部 `loadMore()`） |
| `keywordFilterSwitch` / `dayRangeFilterSwitch` / `projectFilterSwitch` / `statusFilterSwitch` | 筛选切换与「最近七天」下钻（防抖为 0 的立即刷新） |
| `reviewViewLoad` | 进入复核视图：默认 `.ended` 筛选的首屏 |

每个场景先**单独预热一次**（不计时），再做三次计时样本取中位数。测量包含 provider
读取、项目解析、筛选、排序、分页累积与控制器状态发布；**只测耗时，不测分配量或 RSS**。
不含 SwiftUI 绘制与系统调度抖动。会话详情切换本身只做 O(1) 的证据字典读取，其查询成本
由 `dayRangeFilterSwitch`（日期下钻）与 `reviewViewLoad` 覆盖。

```sh
for order in chronological edited shuffled; do
  TINYBUDDY_HISTORY_BENCHMARK=1 TINYBUDDY_HISTORY_BENCHMARK_SIZES=8000,16000 \
  TINYBUDDY_HISTORY_BENCHMARK_ORDER=$order \
    ./script/swiftpm.sh test -c release --filter HistoryQueryPerformanceTests
done
```

本次测量的原始输出保存在本机 `.build/history-query-perf/`（六份：优化前/后 × 三种顺序，
每行一条 `scenario` 中位数），未提交到仓库。只有中位数、没有离散度；一次独立复核（见下）
用同一命令复现 8,000/chronological 的优化列，与本文比值 1.06–1.10，方向一致。

复测基线时使用同一份测试文件与同一数据集，只回退查询服务本身：

```sh
git stash push -- Sources/TinyBuddyCore/FocusSessionQueryService.swift
# 重跑上面的三条命令
git stash pop
```

## 测量结果

同机、同命令、同数据集、同测量文件（优化前后各三次样本的中位数），单位毫秒。

### `edited`（被重写过的档案，生产可达）

| 场景 | 8,000 基线 | 8,000 优化 | 加速 | 16,000 基线 | 16,000 优化 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 45.87 | 5.86 | 7.8× | 93.75 | 11.15 | 8.4× |
| `serviceProjects` | 21.59 | 2.27 | 9.5× | 44.33 | 4.17 | 10.6× |
| `serviceFilterOnly` | 20.89 | 0.66 | 31.8× | 42.65 | 1.29 | 33.0× |
| `serviceFirstPage` | 24.37 | 3.53 | 6.9× | 49.81 | 7.03 | 7.1× |
| `fullPagination` | 4,061.3 | 626.7 | 6.5× | 15,919.2 | 2,470.2 | 6.4× |
| `keywordFilterSwitch` | 97.07 | 9.75 | 10.0× | 189.58 | 18.13 | 10.5× |
| `dayRangeFilterSwitch` | 90.14 | 8.41 | 10.7× | 175.98 | 15.85 | 11.1× |
| `projectFilterSwitch` | 89.81 | 8.90 | 10.1× | 175.96 | 16.59 | 10.6× |
| `statusFilterSwitch` | 94.00 | 11.62 | 8.1× | 185.18 | 22.39 | 8.3× |
| `reviewViewLoad` | 46.81 | 5.88 | 8.0× | 91.72 | 11.25 | 8.2× |

### `chronological`（从未重写过，生产可达）

| 场景 | 8,000 基线 | 8,000 优化 | 加速 | 16,000 基线 | 16,000 优化 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 45.48 | 4.37 | 10.4× | 90.41 | 8.25 | 11.0× |
| `serviceProjects` | 22.16 | 2.21 | 10.0× | 43.88 | 4.06 | 10.8× |
| `serviceFilterOnly` | 21.36 | 0.72 | 29.7× | 42.61 | 1.30 | 32.7× |
| `serviceFirstPage` | 23.31 | 2.08 | 11.2× | 47.06 | 4.15 | 11.3× |
| `fullPagination` | 3,817.1 | 397.8 | 9.6× | 15,249.6 | 1,593.7 | 9.6× |
| `keywordFilterSwitch` | 94.75 | 7.84 | 12.1× | 189.23 | 14.76 | 12.8× |
| `dayRangeFilterSwitch` | 88.33 | 6.86 | 12.9× | 176.45 | 13.12 | 13.4× |
| `projectFilterSwitch` | 88.17 | 7.40 | 11.9× | 175.92 | 14.03 | 12.5× |
| `statusFilterSwitch` | 90.94 | 8.75 | 10.4× | 181.19 | 16.78 | 10.8× |
| `reviewViewLoad` | 45.65 | 4.35 | 10.5× | 90.59 | 8.47 | 10.7× |

### `shuffled`（固定种子乱序代理，不可达）

| 场景 | 8,000 基线 | 8,000 优化 | 加速 | 16,000 基线 | 16,000 优化 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 78.46 | 40.07 | 2.0× | 158.39 | 81.34 | 1.9× |
| `serviceProjects` | 21.28 | 1.87 | 11.4× | 42.27 | 3.30 | 12.8× |
| `serviceFilterOnly` | 21.46 | 0.71 | 30.1× | 42.86 | 1.42 | 30.2× |
| `serviceFirstPage` | 58.39 | 37.90 | 1.5× | 116.19 | 78.36 | 1.5× |
| `fullPagination` | 9,207.2 | 6,140.8 | 1.5× | 37,566.2 | 25,393.3 | 1.5× |
| `keywordFilterSwitch` | 131.76 | 47.63 | 2.8× | 264.81 | 101.59 | 2.6× |
| `dayRangeFilterSwitch` | 120.71 | 42.05 | 2.9× | 242.90 | 90.76 | 2.7× |
| `projectFilterSwitch` | 121.24 | 42.85 | 2.8× | 243.12 | 86.56 | 2.8× |
| `statusFilterSwitch` | 156.51 | 79.41 | 2.0× | 317.35 | 163.91 | 1.9× |
| `reviewViewLoad` | 78.32 | 39.49 | 2.0× | 158.80 | 91.00 | 1.7× |

### 收益来源与量级

排序规则未变（排序键与 tie-break 与改动前相同），减少项目解析是主要收益来源；本次没有
单独测定排序与分配成本。同一份 `shuffled` 数据里 `serviceFilterOnly`（整档筛选、
不排序）在 30× 左右，而 `serviceFirstPage`（同样整档筛选 + 排序）只有 1.5×：乱序输入下
排序成为主导项，两侧都变慢，优化后仍然更优、没有回退。`edited` 里那 2% 被重新追加的行
已经足以让排序明显变贵（16,000 条 `serviceFirstPage` 4.15 → 7.03 ms，`fullPagination`
1,593.7 → 2,470.2 ms），因此加速比从 `chronological` 的 9.6–13.4× 降到 6.4–11.1×。

总滚动成本仍是「页数 × 每页重读并排序整档」，即数据量翻倍时总耗时约为 4 倍：三个模式下
8,000 → 16,000 的 `fullPagination` 实测分别为 4.0×、3.9×、4.1×，与页数同时加倍一致。
该结论只覆盖这两个规模与这三种顺序，不是对所有数据量的普遍保证。平均每页（`edited`）
8,000 条 160 页 3.9 ms，16,000 条 320 页 7.7 ms。

## 实现与一致性边界

`FocusSessionQueryService` 的每次查询原先对**每一条会话**调用一次 `projectResolver`，
而 `TinyBuddyProjectRegistry.resolve(projectKey:)` 要线性扫描身份图（id、别名、大小写
折叠回退），实测约 2.6 µs/条：8,000 条历史下一次「项目选项 + 首页」就要 46 ms，每翻
一页都要重付一次。改动如下：

1. **每次查询只解析一次「不同项目上下文」**（`ProjectResolutionMemo`）。项目身份谓词
   （`projectKey`、关键词）也按已解析项目缓存，关键词只对每个项目名做一次
   `lowercased()`，而不是每条会话一次。
2. **解析与筛选一趟，随后排序**：不再先整档 map 出一份带解析身份的副本再筛选；排序改为
   对本次查询自己的数组原地进行（写时复制保证 provider 持有的数组不会被修改）。
3. **无筛选查询直接把 provider 的数组值排成展示顺序，只为返回页解析并物化行**：除排序触发的整档写时
   复制缓冲外，不再为每一页额外分配一份整档数组，也不再为不返回的行解析项目身份。列表
   默认状态（无任何筛选）走这条路径。
4. **行本地筛选（day 区间、status）不再触发项目解析**：只有返回的页面行携带解析后的
   项目身份，未返回的行不会被任何消费者观察到。

保持不变：游标语义与二分查找、`hasMore`、`totalEstimatedCount`（含无匹配时返回
`.empty`）、排序键（`startedAt` 降序、`id.uuidString` 升序）、`projects()` 的「最新名称 +
名称大小写不敏感排序」规则，以及 `nil`/空关键词的既有筛选语义。`FocusSessionQuerying`
协议签名未变，直接消费者（`HistoryQueryController`、历史列表与复核视图）无需改动。

### 逐条边界（对应两轮独立复核提出的问题）

- **游标连续性（未改变，非本次引入）**：二分查找定位「严格排在游标键之后」的第一行，
  只有**不存在这样的行**（搜索落在结果集末尾或之后）才返回 `nil`，让上层从首页重启。
  若游标自身所在行在中途被删除但后面仍有匹配行，则从下一行继续，服务不会因此跳行或
  重复行。**注意**：已经被加载、之后被删除的行会一直留在控制器的累积列表里，直到下一次
  `reload()`；这对任何已加载行都成立，与游标无关（`appendPage` 只对新增行去重与修序，
  不删除已加载行）。原实现的注释比实际行为说得更宽，本次把注释与文档改为与行为一致，
  **没有改变行为**。
- **记忆化的一致性单位是「精确输入上下文」**：解析器对同一输入返回同一结果时与逐条解析
  完全等价。生产解析器是**加锁可变注册表的实时投影**，严格地说：注册表在同一趟内保持
  不变时两者结果完全一致；同一输入若跨并发变更，memo 取首次结果，逐条实现可能取到变更
  前后的两个值。但不要把它说成「整个项目在趟内一致」：memo 的键是
  含 `key` 与 `displayName` 的 `FocusProjectContext`，同一逻辑项目的两种历史上下文
  （旧别名与当前规范键）可以分别落在注册表并发变更的两侧。memo 只存在于单次调用内、
  不跨请求缓存，因此不会把陈旧身份带给后续查询。注册表变更后的收敛路径是既有的：
  历史列表订阅 `TinyBuddy.projectRegistryDidChange` 并 `reload()`；复核视图也订阅该通知，
  但只刷新项目选择器、**不重载列表**，其列表要到下一次会话变更通知时才随 `reload()` 收敛。
- **内存**：本次**没有测量**分配量或 RSS，只测了耗时。结构上，无筛选翻页不再为每页
  物化第二份整档数组、只物化 `limit` 行，但原地排序仍会因写时复制产生一份整档缓冲；
  带筛选路径仍按全部会话数 `reserveCapacity`（与旧 `filter` 一致）。因此只能确认
  「每页少物化一份整档数组」，不能宣称内存占用整体下降。
- **残留下界**：每次翻页仍要重新读取并排序整档历史（带筛选条件时还要重新筛选）。跨页缓存派生结果可以消除该
  成本，但需要显式的数据版本失效信号：生产代码中 `notifyChanges` 只由复核编辑路径调用，
  会话自动/手动开始结束只触发视图 `reload()`，不会给查询服务提供可作为缓存键的版本，
  缓存会让翻页读到陈旧行；因此本次没有引入，也没有为极端滚动长期保留第二份历史快照。（第二轮把
  每页的排序对象从整行改成 32 字节排序键，见 §第二轮：排序键分页；「不引入跨页缓存」的理由不变。）

渲染侧的微基准显示 `Date.formatted(date:time:)` 每行约 0.85–1.3 µs，缓存
`Date.FormatStyle` 只快 6–14%，不足以支撑改动，因此没有修改行渲染；`FocusHistoryListView`
在会话状态变更通知后 `reload()`（回到第一页）是既有的「不保留陈旧行」交互，未改动。

## 回退保护

除性能测量外，`FocusSessionQueryTests` 增加八项确定性断言（不使用耗时阈值）：

- `testFilteredQueryResolvesEachDistinctProjectOnce`：2,000 条、5 个项目的带筛选查询与
  `projects()` 各自对解析器的调用不超过 10 次（旧实现为 2,000+ 次）。
- `testUnfilteredPageResolvesOnlyVisibleRows`：无筛选首页在 2,000 条、500 个项目的输入下
  解析调用不超过 50 次，且返回行仍带解析后的项目身份。
- `testRowLocalFilterDoesNotResolveNonVisibleRows`：仅 status 筛选时不解析非可见行。
- `testMemoisedQueryMatchesPerRowReferenceImplementation`：用 9 种查询（无筛选、日期区间、
  状态、项目、关键词大小写、空关键词、组合筛选）走完整个结果集，把服务返回的页面与测试内
  朴素的「逐条解析」参考实现逐字段比较（行内容、顺序、解析后项目身份、`nextCursor`、
  `hasMore`、`totalEstimatedCount`，以及 `estimatedCount`）。输入是无重复 id 的乱序排列，
  并额外断言遍历**自行终止于结果集耗尽**、每条匹配行恰好被访问一次、没有重复行——这几条
  不依赖参考实现与服务共用的游标搜索形状。

其余四项覆盖复核指出的具体缺口：

- `testIdenticalTimestampsAcrossPageBoundaryVisitEveryRowOnce`：12 条共享 `startedAt` 的行
  恰好跨页（每页 5），断言按 uuid 升序、每条只访问一次。
- `testPaginationContinuesAfterCursorRowDeletion`：两页之间删除游标行与它前一行，断言从
  下一个存活行继续、不跳行不重复（即冻结既有行为）。
- `testSinglePageUsesOneIdentityPerInputContext`：解析器在两次查询间改名，断言**单页内**
  只出现一种身份、且同一输入上下文每趟只解析一次（把并发注册表变更的边界写成可验证契约）。
- `testProjectSummaryTieBreakMatchesPerRowResolution`：同一项目的两个历史上下文共享时间戳
  时，`projects()` 摘要与逐行解析的归并结果一致（最新名称 + 稳定排序）。

在**回退到改动前实现**时实测这八项：三项解析次数断言失败（2,000 / 2,005 次 vs 阈值 10 / 50），
`testSinglePageUsesOneIdentityPerInputContext` 失败（逐行实现各解析一次、同页出现两种身份），
其余四项（差分 + 遍历完整性、跨页同时间戳、游标行删除、摘要 tie-break）**全部通过**。
即：优化后的页面输出与改动前在 9 种查询、全部页面上逐字段一致、遍历覆盖每条匹配行一次，
而唯一有意改变的语义（同页单一身份）被显式固定为契约。该差分守住的是固定（且无副作用）
解析器下的页面等价性；参考实现复用了同形游标搜索，游标算法本身由既有游标测试与本轮新增
的跨页/删行断言独立覆盖。

### 声明状态（第 5 轮独立复核的最终判定）

| 声明 | 判定 | 边界 |
| --- | --- | --- |
| A 记忆化与逐条解析一致 | 部分支持 | 稳定、无副作用解析器下逐字段相同；注册表同趟内并发变更时允许不同（已写成契约并有测试） |
| B 无筛选只解析返回页且外部不可观察 | 部分支持 | 解析次数与页内容有测试支撑；「任何外部消费者」过宽：注入的解析器与实时注册表变更可观察 |
| C 性能数字可信 | 部分支持 | 表格全部数值与六份原始日志一致、工作负载与预热方法明确；只有中位数、无离散度，未独立重跑六组 benchmark |
| D 内存没有变差 | 不支持 | 未测分配量或 RSS，只能证明无筛选页少物化一份整档数组 |
| E 残留下界与未设缓存理由 | 支持 | 每页仍重读并排序（带筛选条件时还要筛选）；生产缺少覆盖所有会话变化的缓存失效版本（第二轮的每页成本见 §第二轮：排序键分页） |

## 验证范围与独立复核

选择 **Module/contract**：改动集中在 `TinyBuddyCore` 的查询服务，跨 Core/App 边界但公开
API 与协议签名不变，直接消费者只有 `HistoryQueryController`（历史列表与复核视图）；
不涉及持久化、共享快照、跨进程协议或发布安装。

```sh
swift build
./script/swiftpm.sh test --filter TinyBuddyCoreTests
./script/swiftpm.sh test
TINYBUDDY_HISTORY_BENCHMARK=1 ./script/swiftpm.sh test -c release --filter HistoryQueryPerformanceTests
```

在最终修订上执行 `./script/swiftpm.sh test`（两个测试包，退出码 0）：
`TinyBuddyCoreTests` 1,044 项通过（1 项为 opt-in 性能测试，默认跳过）；
`TinyBuddyAppTests` 717 项通过（2 项默认跳过）；均 0 失败。`git diff --check` 通过。
日志在 `.build/history-query-perf/full-test-suite.log`。

本改动经过三轮跨模型独立只读复核（Codex `gpt-6-sol`，`delegate_task`，每轮独立
`clientRequestId` 与 `taskId`）。

第 1 轮确认了排序键、二分比较、`hasMore`/`nextCursor`/计数、`projects()` 折叠与排序规则、
写时复制保护，以及「未引入跨页缓存」的理由；并指出：性能 fixture 的日期是无效公历日、
输入本来已降序（两者合起来放大了加速比）、预热说明不准确、文档声称覆盖内存却只测耗时、
「无超线性退化」措辞不准确、游标注释比实际行为说得更宽。以上均已修正并重测。

第 2 轮进一步指出并已修正：游标说明中「控制器去重与顺序修复会覆盖删行情形」过强
（`appendPage` 不会移除已加载的被删行，需要下一次 `reload()`）；「整趟内项目身份一致」
不成立（一致性单位是精确输入上下文；复核视图订阅注册表通知但只刷新项目选择器、
不重载列表）；`chronological` 不能概括所有生产档案（编辑/分割/合并/撤销会把替换行
重新追加到末尾，规则重算未接线但布局更差），
于是新增 `edited` 模式并把 `shuffled` 降级为不可达的乱序代理；fixture 在历史各日生成
active/paused 会话不真实，已改为只有最新一天保留开放会话；内存「减少，不是增加」超出
证据，已改为仅声明「每页少物化一份整档数组」。

第 3 轮判定「技术层面没有 blocking」，并指出仍易误导读者的文档措辞与一个测试覆盖缺口
（缺少「记忆化路径 vs 逐条路径」的差分断言）：措辞已按 §逐条边界 与本文按下述方式修正，
差分断言已加入 `testMemoisedQueryMatchesPerRowReferenceImplementation`，并实测在改动前后
都通过（见 §回退保护）。

没有运行 GUI 回归（`script/regression_gate.sh --quick` 会 `pkill` 并启动真实 App、使用真实
持久化环境，超出本次无外部写入授权），也没有运行 `release-install`。因此证据覆盖查询
服务的 CPU 工作量与历史列表的功能行为，不代表已测量真实 GUI 进程的滚动帧率、RSS、整机
能耗，也不代表已知真实档案中重写行的实际占比（`edited` 的 2% 是代表性假设，不是上界）。
`FocusSessionRecalculationEngine` 的重算会把范围内所有被修改的自动会话删除后按字典哈希序
重新追加（布局更接近 `shuffled`），但 `FocusSessionUpgradeCoordinator` 在当前 App target
中没有接线，因此这条路径目前不会影响真实档案的顺序。

## 第二轮：排序键分页（整行排序 → 32 字节键排序）

本轮基线是上一轮结果所在的 `95e436e`（工作树无未提交改动）。数据集、页面大小（50）、三种
provider 顺序、预热与中位数方法与 §可重复工作负载 相同；只新增两个服务级场景：`lastPage`
（把游标放在结果集末尾前一行，测最后一页）与 `serviceFullPagination`（只经查询服务翻完
全部页面，不经控制器累积）。

本轮的数值都来自该合成 fixture（真实注册表解析器 + 真实控制器接线 + 合成会话分布），
**不是真实用户档案的测量**；也没有测真实档案中重写行的占比。取值口径限于本机、
8,000/16,000 两种规模与三种 provider 布局。

```sh
# 基线：只回退查询服务本身，保留同一份测试文件
git stash push -- Sources/TinyBuddyCore/FocusSessionQueryService.swift
for order in chronological edited shuffled; do
  TINYBUDDY_HISTORY_BENCHMARK=1 TINYBUDDY_HISTORY_BENCHMARK_SIZES=8000,16000 \
  TINYBUDDY_HISTORY_BENCHMARK_SAMPLES=3 TINYBUDDY_HISTORY_BENCHMARK_ORDER=$order \
    ./script/swiftpm.sh test -c release --filter HistoryQueryPerformanceTests
done
git stash pop
# 本轮：直接重跑同样三条命令
```

两侧原始输出（每行一条场景中位数）保存在本机 `.build/history-query-perf/r2-base2-<order>.txt`
与 `r2-cand-<order>.txt`；基线提交记录在 `r2-baseline-commit.txt`。单位毫秒，三样本中位数。

### `chronological`（从未重写过，生产可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 5.662 | 3.399 | 1.7× | 10.800 | 6.375 | 1.7× |
| `serviceProjects` | 2.922 | 2.919 | 1.0× | 5.361 | 5.323 | 1.0× |
| `serviceFilterOnly` | 0.955 | 0.157 | 6.1× | 1.864 | 0.282 | 6.6× |
| `serviceFirstPage` | 2.867 | 0.506 | 5.7× | 5.603 | 0.963 | 5.8× |
| `serviceFullPagination` | 453.491 | 83.450 | 5.4× | 1,785.690 | 304.642 | 5.9× |
| `fullPagination` | 531.741 | 160.534 | 3.3× | 2,109.331 | 598.030 | 3.5× |
| `keywordFilterSwitch` | 10.076 | 7.346 | 1.4× | 18.440 | 13.445 | 1.4× |
| `dayRangeFilterSwitch` | 9.013 | 6.537 | 1.4× | 16.525 | 12.033 | 1.4× |
| `projectFilterSwitch` | 9.422 | 7.282 | 1.3× | 17.471 | 13.089 | 1.3× |
| `statusFilterSwitch` | 11.509 | 6.939 | 1.7× | 21.923 | 12.684 | 1.7× |
| `reviewViewLoad` | 5.688 | 3.453 | 1.6× | 10.841 | 6.310 | 1.7× |
| `lastPage` | 2.797 | 0.493 | 5.7× | 5.589 | 0.909 | 6.1× |

### `edited`（被重写过的档案，生产可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 8.250 | 3.676 | 2.2× | 15.919 | 6.977 | 2.3× |
| `serviceProjects` | 3.002 | 2.834 | 1.1× | 5.519 | 5.293 | 1.0× |
| `serviceFilterOnly` | 0.951 | 0.157 | 6.1× | 1.908 | 0.288 | 6.6× |
| `serviceFirstPage` | 5.245 | 0.841 | 6.2× | 10.387 | 1.617 | 6.4× |
| `serviceFullPagination` | 834.038 | 135.192 | 6.2× | 3,358.401 | 512.046 | 6.6× |
| `fullPagination` | 914.824 | 212.770 | 4.3× | 3,668.788 | 804.452 | 4.6× |
| `keywordFilterSwitch` | 12.970 | 7.635 | 1.7× | 24.875 | 13.809 | 1.8× |
| `dayRangeFilterSwitch` | 11.610 | 6.802 | 1.7× | 22.151 | 12.641 | 1.8× |
| `projectFilterSwitch` | 12.078 | 7.527 | 1.6× | 23.072 | 13.475 | 1.7× |
| `statusFilterSwitch` | 16.584 | 7.441 | 2.2× | 32.383 | 13.601 | 2.4× |
| `reviewViewLoad` | 8.351 | 3.772 | 2.2× | 16.203 | 6.880 | 2.4× |
| `lastPage` | 5.180 | 0.825 | 6.3× | 10.517 | 1.567 | 6.7× |

### `shuffled`（固定种子乱序代理，不可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 49.574 | 11.499 | 4.3× | 102.160 | 23.243 | 4.4× |
| `serviceProjects` | 2.202 | 2.287 | 1.0× | 3.879 | 4.285 | 0.9× |
| `serviceFilterOnly` | 0.914 | 0.150 | 6.1× | 1.793 | 0.283 | 6.3× |
| `serviceFirstPage` | 47.396 | 9.127 | 5.2× | 98.177 | 19.308 | 5.1× |
| `serviceFullPagination` | 7,578.589 | 1,476.258 | 5.1× | 31,424.069 | 6,035.094 | 5.2× |
| `fullPagination` | 7,693.328 | 1,550.048 | 5.0× | 31,614.742 | 6,334.768 | 5.0× |
| `keywordFilterSwitch` | 59.166 | 15.983 | 3.7× | 120.472 | 31.974 | 3.8× |
| `dayRangeFilterSwitch` | 52.297 | 14.172 | 3.7× | 106.756 | 27.792 | 3.8× |
| `projectFilterSwitch` | 53.052 | 14.845 | 3.6× | 108.744 | 28.987 | 3.8× |
| `statusFilterSwitch` | 98.946 | 23.258 | 4.3× | 204.058 | 45.945 | 4.4× |
| `reviewViewLoad` | 49.503 | 11.476 | 4.3× | 101.665 | 23.420 | 4.3× |
| `lastPage` | 47.276 | 9.138 | 5.2× | 98.080 | 18.736 | 5.2× |

### 收益来源与量级

每页的查询服务成本下降 5.1–6.7×（`chronological`/`edited` 为 5.4–6.7×，`shuffled` 为
5.1–5.2×；口径为 `serviceFirstPage` / `serviceFullPagination` / `lastPage` 三者）。首尾页成本
在同一量级：`lastPage` 与 `serviceFirstPage` 在每个规模与顺序下都接近（16,000 `chronological`：
0.909 vs 0.963 ms），说明每页成本与游标位置无关；这是单次中位数的比较，不是重复测量的
保证（复测 8,000 行时两者相差约 16%）。整段滚动
每页成本也不随页数上升：`serviceFullPagination` 除以页数后与 `serviceFirstPage` 相等
（16,000 `chronological`：304.642/320 = 0.952 vs 0.963；`edited`：512.046/320 = 1.600 vs
1.617；`shuffled`：6,035.094/320 = 18.86 vs 19.31；8,000 同样吻合）。

`serviceProjects` 在三种顺序下没有呈现一致方向的改善（8,000 `chronological` 1.0×、8,000
`edited` 1.1×、16,000 `shuffled` 0.9×，单次中位数，无离散度数据可据此宣称“在噪声内”）；
改动没有触及该项目摘要路径的依据是 diff
（`projects()` 逐字未改），本轮改的是查询服务的筛选/排序/分页与计数路径（`estimatedCount`
也改用了同一 helper）。

基线选择「整行排序」的原因不是比较器，而是元素搬运：`FocusSession` 是 177 字节、含 4 个引用
计数字段的值类型，排序整行要付整档写时复制拷贝，并在每次交换上付 retain/release 流量。
下列数字来自**未提交的辅助微基准、没有保留原始输出**，只是方向性观察，不能单独当作
可复现证据（本轮的正式证据是上面三张表）：同机 Release、16,000 行、`chronological` 顺序下

| 做法 | 耗时 | 结论 |
| --- | ---: | --- |
| 排序整行（比较器用 `id.uuidString`） | 6.85 ms | 参照 |
| 排序整行（比较器改用 `id < id`） | 6.44 ms | 只快 6%，比较器不是瓶颈 |
| 只做写时复制拷贝、不排序 | 2.10 ms | 拷贝本身占参照的 ~30% |
| 建 32 字节键 + 排序键 + 只物化 50 行 | 0.83 ms | 本轮采用 |
| 其中：按值迭代整行建键 | 3.44 ms | 若写成 `for session in sessions` 会吃掉大部分收益 |
| 其中：按索引读缓冲区建键（每行只取所需字段） | 0.207 ms | 最终实现形态（16.6×） |

同一微基准还否掉了「只选择前 K 行、不全排序」的方案：20,000 行下 `nth` 式选择前三页首屏
（K=50）为 4.38 ms、选择末页（K=N−50）为 10.90 ms，而全排序是 6.73 ms——首屏只快 1.5×，
末页反而更慢，因此没有采用。（同样只是方向性观察，原始输出未保留。）

50,001 个样本（含 00/0a/0f/10/9f/a0/f0/ff 首字节边界与全 0/全 f）上两种排序结果完全相同
（同样为未保留输出的辅助观察；可提交的等价性证据是新增测试）

   排序键的 tie-break 用 `UUID` 字节序而不是 `id.uuidString` 字符串。二者对规范 UUID 等价：
`uuidString` 是定宽带连字符十六进制，字符序与半字节值同序（大小写都不影响相对序），
`UUID` 的 `Comparable` 按 16 字节左到右比较；50,001 个样本（含 00/0a/0f/10/9f/a0/f0/ff
首字节边界与全 0/全 f）上两种排序结果完全相同。该等价性由新增测试
`testDisplayOrderTieBreakMatchesUUIDStringOrdering` 固定为契约，既有
`testTieBreakerUUID`、`testSortStabilityWithIdenticalTimestamps` 继续断言 `uuidString`
升序。

### `fullPagination` 与 `serviceFullPagination` 的差：调用方保留上一页时的整档写时复制

`fullPagination` 的加速（`chronological`/`edited` 3.3–4.6×，`shuffled` 5.0×）低于服务级加速，
差的不是查询服务，而是基准循环自己：
它的 `while case .loaded(let page) = controller.loadState, page.hasMore { await
controller.loadMore() }` 把上一页绑定到整个循环体，`page.sessions` 与控制器累积的
`allSessions` 共享同一份缓冲，于是每次追加都对整档累积数组做一次写时复制。该开销在改动前后
都在（`fullPagination − serviceFullPagination`）：

| 顺序 | 8,000 基线 | 8,000 本轮 | 16,000 基线 | 16,000 本轮 |
| --- | ---: | ---: | ---: | ---: |
| `chronological` | 78.2 ms（0.49/页） | 77.1 ms（0.48/页） | 323.6 ms（1.01/页） | 293.4 ms（0.92/页） |
| `edited` | 80.8 ms（0.51/页） | 77.6 ms（0.49/页） | 310.4 ms（0.97/页） | 292.4 ms（0.91/页） |

即约 0.5 ms/页 @8,000、0.9 ms/页 @16,000：与行数成正比，两侧量级一致（0.49 vs 0.48、
1.01 vs 0.92）。该差值不是纯写时复制的测量：它同时包含 `projects()`、控制器累积维护与
调度差异。与「额外写时复制」解释一致的直接诊断只来自同一份代码、同一会话内的三次测量
（16,000 `chronological`，本轮实现）：`fullPagination` 607.5 ms；把循环改成
`while controller.loadState.currentPage?.hasMore == true`（不再跨 `await` 保留上一页）
318.8 ms；只走服务、完全不经控制器 304.3 ms。生产触发点是行内 `onAppear` 的
`Task { await controller.loadMore() }`，它不显式保留旧页；但 `ForEach(controller.allSessions)`
这类遍历是否让数组在追加期间保持共享没有测过 GUI 生命周期，因此不能断定生产当前不付这份
拷贝。任何长期持有 `loadState` 的页的调用方都会付。

### 残留下界（本轮结束时）

- **`projects()` 未改动，已成为 `refreshFirstPage` 的主导项**：16,000 `chronological` 下
  `serviceProjects` 5.323 ms 占 `refreshFirstPage` 6.375 ms 的 83%（8,000：2.919 / 3.399）。
  同一微基准里把它的「按值迭代整行 + 折叠最新名称」改成按索引读缓冲区，实测 5.95 → 3.59 ms
  （16,000，1.66×）。这是下一个已确认热点，本轮未做：它每次刷新只调用一次、与翻页成本无关，
  本轮范围限定在 `execute` 的每页重复筛选与排序。
- **每页仍是 O(N) 建键 + O(N log N) 键排序**：常数小了 5–6×，形状没变，滚完整档仍然是
  页数 × 整档成本；本轮没有引入跨页缓存（理由见 §实现与一致性边界）。
- **调用方跨追加保留页面时的整档写时复制**（上节），本轮未改。
- **`shuffled` 仍是 ~19 ms/页 @16,000**，它只是不可达的乱序代理；本轮在它上面也有 5.1–5.2×。

### 实现与一致性边界（本轮）

1. 每页对整档做一趟 O(N) 键构建（32 字节 `{startedAt, id, index}`），只排序键，只物化返回页
   的行；无筛选与仅日期/状态筛选时只为返回页解析项目身份，带项目/关键词筛选时仍需对通过
   行本地谓词的每种 distinct 上下文解析一次（与基线相同），`estimatedCount` 同基线一样会解析。
2. 无筛选与带筛选走同一个 helper，删掉了原来 `query.isEmpty` 的双分支和
   `precedesInDisplayOrder` 自由函数。边界语义逐字保留：版本过期先返回 `nil`；版本有效时
   `limit <= 0` 返回 `.empty`；无游标且结果集为空返回 `.empty`（计数为 `nil`）；带游标且游标
   之后没有行时返回 `nil`；此外 `hasMore`、`nextCursor`（改为由 `keys[endIndex - 1]` 构造，
   去掉 `page.last!` 强解包）与 `totalEstimatedCount`（过滤后行数）不变。
3. 二分查找的比较逐字保留，只把比较对象从行换成键；`ProjectResolutionMemo` 的语义、解析时机
   （行本地谓词先判、只在需要项目谓词时解析、带项目/关键词筛选时对通过行本地谓词的每种
   distinct 上下文解析一次、返回页行由 `makePage` 物化并解析）与关键词整趟只 lowercased 一次
   的行为不变。
4. 内存：本轮只测耗时。旧实现的两条路径不同：无筛选路径对 provider 数组做一次整档写时复制
   再原地排序（16,000 行约 2.9 MB 的拷贝），带筛选路径先把匹配行追加进一个独占的结果数组
   （最多同样大小）再排序。新实现不再复制整档行数组，只物化返回页的行，并有一个按 provider
   总行数预留的键数组（32 字节/行，16,000 行约 0.51 MB；预留口径与旧 `matchingSessions` 相同）。
   没有测分配量或 RSS，因此只声称工作缓冲元素的规模与「每页不再复制整档行数组」，不声称实际
   内存占用下降。

### 验证范围与独立复核（本轮）

选择 **Module/contract**：改动集中在 `TinyBuddyCore` 的查询服务，公开 API 与协议签名不变，
唯一生产消费者是 `HistoryQueryController`。执行了：

```sh
./script/swiftpm.sh test --filter 'FocusSessionQueryTests|FocusSessionQueryPerformanceTests'
./script/swiftpm.sh test --filter 'HistoryQueryControllerTests|HistoryQueryPerformanceTests|FocusHistoryPresentationConsistencyTests'
./script/swiftpm.sh test
git diff --check
```

没有运行 GUI 回归、`script/regression_gate.sh`、`benchmark_git_refresh.sh` 或
`release-install`：本轮不涉及 Git 刷新、签名、安装或 Widget，且这些命令会操作外部状态。
因此证据覆盖查询服务的 CPU 工作量、控制器分页累积与历史列表的功能行为，不代表真实 GUI
进程的滚动帧率、RSS 或整机能耗。
