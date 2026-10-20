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

## 第三轮：项目摘要 slot 累积（每行字典写入 → 每槽一次标量更新）

第二轮的 §残留下界 把 `projects()` 列为下一个已确认热点：16,000 `chronological` 下
`serviceProjects` 5.323 ms 占 `refreshFirstPage` 6.375 ms 的 83%，而它逐行按值迭代整档、
对每行的输入上下文与规范 key 各做一次字符串哈希，并对几乎每一行写一次字典元组。

本轮改为单趟 slot 累积：`withUnsafeBufferPointer` 按索引读取所需标量；解析按精确输入
上下文在一次 pass 内记忆化（与原 `ProjectResolutionMemo` 同一契约，不跨调用缓存）；每个规范
key 一个 `ProjectSummarySlot`，输入上下文命中后只做一次数组元素更新；时间相等时直接比较
`UUID`（字节序与 `uuidString` 升序等价，第二轮已由
`testDisplayOrderTieBreakMatchesUUIDStringOrdering` 固定）而不是构造两个 String。
分组维度（解析后的 key）、最新 `startedAt` 优先、并列取较小 `id.uuidString`、最终展示
排序比较器与公开 API 逐字未变。

本轮只测 `chronological`（默认顺序），方法与 §可重复工作负载 相同：Release、
`TINYBUDDY_HISTORY_BENCHMARK_SAMPLES=5` 的 5 样本中位数、8,000/16,000 两种规模。
两侧在**同一会话内交替测量**（A/B/A/B，各两次）：基线是把
`Sources/TinyBuddyCore/FocusSessionQueryService.swift` 换成 HEAD 版本、保留同一份测试文件。
每格为中位数，单位毫秒：

```sh
cp Sources/TinyBuddyCore/FocusSessionQueryService.swift /tmp/tb-new-service.swift
run() { TINYBUDDY_HISTORY_BENCHMARK=1 TINYBUDDY_HISTORY_BENCHMARK_SIZES=8000,16000 \
  TINYBUDDY_HISTORY_BENCHMARK_SAMPLES=5 \
  ./script/swiftpm.sh test -c release --filter HistoryQueryPerformanceTests; }
run                       # A1 本轮
git checkout HEAD -- Sources/TinyBuddyCore/FocusSessionQueryService.swift
run                       # B1 基线
cp /tmp/tb-new-service.swift Sources/TinyBuddyCore/FocusSessionQueryService.swift
run                       # A2 本轮
git checkout HEAD -- Sources/TinyBuddyCore/FocusSessionQueryService.swift
run                       # B2 基线
cp /tmp/tb-new-service.swift Sources/TinyBuddyCore/FocusSessionQueryService.swift
```

| 场景 | 8,000 基线 B1/B2 | 8,000 本轮 A1/A2 | 倍率 | 16,000 基线 B1/B2 | 16,000 本轮 A1/A2 | 倍率 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `serviceProjects` | 2.947 / 2.925 | 1.890 / 1.883 | 1.56× | 5.470 / 5.348 | 3.427 / 3.450 | 1.57× |
| `refreshFirstPage` | 3.498 / 3.464 | 2.441 / 2.450 | 1.42× | 6.538 / 6.341 | 4.453 / 4.486 | 1.44× |
| `keywordFilterSwitch` | 7.521 / 7.390 | 5.298 / 5.319 | 1.40× | 13.773 / 13.336 | 9.628 / 9.643 | 1.41× |
| `dayRangeFilterSwitch` | 6.863 / 6.585 | 4.535 / 4.559 | 1.48× | 12.566 / 12.083 | 8.347 / 8.367 | 1.47× |
| `projectFilterSwitch` | 7.397 / 7.209 | 5.121 / 5.146 | 1.42× | 13.260 / 13.071 | 9.336 / 9.370 | 1.41× |
| `statusFilterSwitch` | 7.077 / 6.807 | 4.808 / 4.817 | 1.44× | 12.958 / 12.592 | 8.917 / 8.767 | 1.46× |
| `reviewViewLoad` | 3.551 / 3.459 | 2.402 / 2.410 | 1.46× | 6.589 / 6.320 | 4.440 / 4.364 | 1.48× |
| `serviceFirstPage` | 0.507 / 0.513 | 0.532 / 0.533 | 0.96× | 0.972 / 0.982 | 1.024 / 1.031 | 0.95× |
| `serviceFullPagination` | 84.222 / 84.122 | 87.477 / 87.348 | 0.96× | 306.472 / 310.128 | 321.400 / 323.712 | 0.96× |
| `fullPagination` | 163.119 / 164.614 | 167.501 / 167.238 | 0.98× | 607.505 / 615.225 | 628.844 / 628.328 | 0.97× |
| `lastPage` | 0.501 / 0.497 | 0.516 / 0.514 | 0.97× | 0.926 / 0.939 | 0.978 / 0.982 | 0.95× |
| `serviceFilterOnly` | 0.154 / 0.155 | 0.165 / 0.167 | 0.93× | 0.288 / 0.287 | 0.300 / 0.300 | 0.96× |

按用户可见操作看：首屏、复核视图入口与四种筛选切换（都走 `refresh()`）快 29–32%。
`serviceProjects` 自身的倍率（1.56–1.57×）大于 `refreshFirstPage` 的 1.42–1.44×，差值是同一
刷新里 `execute()` 那一半的回退（16,000：`serviceProjects` 5.409 → 3.439，
`serviceFirstPage` 0.977 → 1.028，净 −1.93 ms 与 `refreshFirstPage` 的 −1.97 ms 相符）。

### 未定位机制的回退：`execute()`/翻页路径慢 4–5%

上表里的 `serviceFirstPage` / `lastPage` / `serviceFullPagination` / `fullPagination` 都只走
`execute()`，其实现逐字未改，却一致慢 4–5%（`fullPagination` 含 `refresh()`，净差被摊薄到
2–3%）。同一会话内两次 A 态（1.024 / 1.031 ms）与两次 B 态（0.972 / 0.982 ms）互相一致，
且该差值大于同一份 HEAD 源码在不同会话间的差异（0.957–0.961 vs 0.972–0.982，≤2.6%），
另有一轮独立复核在同一对构建上测得同向的 +2.9–4.0%，因此在本构建对上它是真实的；但它是
否复现于其他构建配置未知，**具体机理未定位**（没有做汇编或符号级对比），也没有尝试更小的
替代改动来规避它，因此不声称存在或不存在这样的改动。如实记录的代价：每页约 +50 µs
（`serviceFirstPage` 16,000 行 0.977 → 1.028 ms），滚完整档 16,000 行多约 17 ms（+2.8%）。

### 测试覆盖（修正与新增）

原 `testProjectSummaryTieBreakMatchesPerRowResolution` 实际上没有执行目标分支：两行的
`startedAt` 相差 1 小时，第二行在「更旧则跳过」处直接 `continue`；两个 id 还是默认随机
`UUID()`；断言不依赖 tie-break，因此删掉并列分支测试仍会通过。本轮：

1. 该测试改为两行**同一 `startedAt`**、固定 id（末字节 `…09` / `…0a`）、断言 summary 取
   较小 `id.uuidString` 的那一行，并对同一批行的**反转 provider 顺序**断言结果相同。
2. 新增 `testProjectSummaryTieBreakMatchesUUIDStringOrdering`：4 个十六进制边界 id
   （末字节 09 / 0a / 90 / a0）、同一时间戳，遍历全部 24 种输入排列，断言胜者恒为
   `id.uuidString` 最小者。
3. 新增 `testProjectSummariesMatchPerRowReference`：60 行、4 个规范项目、每个项目由 3 个
   可区分历史 context 供给、并列竞争发生在每个项目的最大 `startedAt` 处、provider 顺序
   交错，与逐行（不记忆化）参考实现比较。**独立复核发现该 fixture 初版仍然无效**
   （`index % 2` 被 `index % 4` 唯一决定 → 每个 key 只有一个 context；并列行又都早于最终
   最新行），因此重做 fixture，并加入四条自检断言（每个 key ≥ 2 个显示名、并列发生在最大
   `startedAt`、至少一个 key 的胜者不是 provider 首行、至少一个 key 的胜者名字不是
   provider 末行）：fixture 退化时测试会直接失败，而不是继续通过却什么都没测。

变异验证（临时改实现后立即还原）：删除并列分支 → 上述测试失败；把方向反转为较大
`id.uuidString` 胜 → 同样失败。还原后 `FocusSessionQueryTests` 41 项 0 失败。

### 验证范围与独立复核（本轮）

选择 **Module/contract**：改动在一个 `TinyBuddyCore` actor 的一个方法内，公开 API、持久化、
schema、并发边界均未变，唯一生产消费者是 `HistoryQueryController` 与共享该服务的复核视图。
执行了：

```sh
./script/swiftpm.sh test --filter 'FocusSessionQueryTests'
./script/swiftpm.sh test --filter 'HistoryQueryControllerTests'
TINYBUDDY_HISTORY_BENCHMARK=1 TINYBUDDY_HISTORY_BENCHMARK_SAMPLES=5 \
  ./script/swiftpm.sh test -c release --filter HistoryQueryPerformanceTests
./script/swiftpm.sh test
git diff --check
```

完整回归在最终修订上执行：`TinyBuddyCoreTests` 1,053 项（1 项默认跳过的 opt-in 性能测试）、
`TinyBuddyAppTests` 729 项（2 项默认跳过），均 0 失败，退出码 0。本改动经一轮跨模型独立
只读复核（Codex `gpt-6.1-sol`）：复核确认生产实现语义等价（分组维度、记忆化契约、胜出规则
的全部判定用例、最终排序比较器、空输入与版本过期路径、无跨调用缓存、无残留死代码），确认
`referenceProjectSummaries` 用的是改动前的逐行算法而不是新实现的复制，并用 4,608 个 UUID
独立复现了 `UUID` 字节序与 `uuidString` 升序的等价性；阻塞项（第 3 条测试的 fixture 无效）
与文档缺陷已按上节修正。没有运行 GUI 回归、`script/regression_gate.sh`、
`benchmark_git_refresh.sh` 或 `release-install`：本轮不涉及 Git 刷新、签名、安装或 Widget，
且这些命令会操作外部状态。证据覆盖查询服务的 CPU 工作量与历史列表的功能行为，不代表真实
GUI 进程的滚动帧率、RSS 或整机能耗。

### 残留下界（本轮结束时）

- **一次刷新仍读取 provider 两次**（`projects()` 与 `execute()` 各一次），`refreshFirstPage`
  因此仍是「摘要 + 首屏」两段成本之和。合并为一次读取需要让项目选项独立于当前筛选条件，
  并处理两次读取之间数据变化的情形，本轮未做。
- **`projects()` 仍对整档做一趟 O(N) 累积**：16,000 行 3.44 ms，主要成本已是每个精确输入
  上下文的哈希查找与每个规范 key 的槽写入，不再有每行的字典写入与 `uuidString` 分配。
- **`execute()` 每页仍是 O(N) 建键 + O(N log N) 键排序**，且本轮实测该类路径有 4–5% 的
  未定位布局回退（见上）。
- **`shuffled` 顺序本轮未重测**：它只是不可达的乱序代理，第二轮的 5.1–5.2× 结论不受本轮
  影响（本轮改动不含逐页路径）。

## 第四轮：分页累积改分块（消除每页整档复制）+ 反向遍历建键

本轮基线为 `258c29e98531cf522d8fc50ca15257d8e4e314e9`（工作树无未提交改动）。
数据集、页面大小（50）、provider 顺序、预热与中位数方法与 §可重复工作负载 相同；
Release、`TINYBUDDY_HISTORY_BENCHMARK_SAMPLES=5`。

两侧在同一会话内**成对交替**测量并各测两遍：`chronological` 用 B,A,B,A，
`edited` 用 B,A,A,B（首轮 `edited` 用 B,A,B,A 时机器在第二对中途变慢，
B1 2.762 → B2 3.356，A 侧两轮 3.385/3.417，说明那是漂移而不是 A 的回归；改为对调顺序后
两侧两轮都稳定在 B 4.48/4.46、A 4.39/4.41）。每格取两轮最小值。仍是合成 fixture，
不是真实用户档案。

### 定位：瓶颈是每页一次整档复制，不是排序

先加两个临时诊断场景（未保留在最终文件里；A 态一列的原始输出在
`.build/history-perf-r4/cand1-chronological.txt` 的 `DIAG` 行，B 态一列未落盘）：
同一控制器、同一 `loadMore()` 循环，唯一差别是调用方是否把上一页的存储跨 append 保留
（渲染中的 `ForEach` 就是这样的长期持有者）。

| 16,000 条，chronological | 耗时 | 每页 |
| --- | ---: | ---: |
| 只走服务（`serviceFullPagination`） | 318.1 | 0.99 ms |
| 经控制器、调用方不保留页存储 | 333.0 | 1.04 ms |
| 经控制器、调用方保留页存储（旧 `ForEach(allSessions)` 的形态） | 611.8 | 1.91 ms |

即控制器自身分页记账只有 (333.0 − 318.1) / 320 ≈ 0.047 ms/页，而「读者持有累积数组」
在此基础上再增加 (611.8 − 333.0) / 320 ≈ 0.871 ms/页——这个增量就是保留存储造成的成本
（不是单独测得的纯复制耗时），它占滚动到底总耗时的 46%，并且 8,000 → 16,000 时该项为
4.0×（行数翻倍、页数也翻倍），是二次项。旧实现里这个持有者有两个：
`loadState = .loaded(FocusSessionQueryPage(sessions: allSessions, ...))` 和
`List { ForEach(controller.allSessions) }`。`docs/history-pagination-performance.md` 已经处理了
「跨 await 保留旧页」那种，但明确留了「外部消费者若长时间保存旧数组快照，仍可能触发
Swift 写时复制」——`ForEach` 正是这种消费者。**注意**：这是合成工作负载上「读者持有存储」
模型的成本，真实 SwiftUI 列表是否也长期持有到这些行没有测量（见 §残留风险）。

### 改动一：控制器按页分块累积

`HistoryQueryController` 不再维护扁平累积数组，而是
`private(set) var sessionPages: [[FocusSession]]`（每次 append 一个新 chunk），
并提供 `loadedSessionCount`（`reduce` 求和，O(块数)）与 `lastLoadedSessionID`。
`allSessions` 变成计算属性（`flatMap`），只服务诊断与测试的整体断言；列表与复核视图
改为按页嵌套 `ForEach`（外层 `indices`、内层行），并在每次 body 求值时把 `sessionPages`
取一次做快照，保证外层下标与由此渲染的行来自同一个值。于是追加只改外层小数组：
8,000 行 160 页 / 16,000 行 320 页时每页复制量从 1.4 MB / 2.8 MB 降到约 1.3 KB / 2.6 KB。

逐条保持不变的旧行为：`refresh()` 原样发布首屏并在首屏异常时置 `needsInitialNormalization`；
首次追加时的整档去重+排序；稳定页只检查新增行与页边界；检测到顺序跳变时整档重排；
重复 ID 首现优先；只有重复行的页仍推进游标但不追加空 chunk；过期（superseded）结果不触碰
任何累积状态；`totalEstimatedCount` 仍取首屏值。随之改变并已在测试中固定的两点：

1. `loadState.loaded(page).sessions` 现在只装**刚取回的那一页**，不再装整档累积。
   生产代码只用到它的「结果集是否为空」与摘要用的 `totalEstimatedCount`；空态判断改为
   `loadedSessionCount == 0`，与「首屏为空 ⟺ 结果集为空」等价。测试里两处
   `page.sessions == 累积结果` 断言编码的是旧内部表示，已改为分别断言分页载荷
   （`page.sessions == sessions.suffix(50)`）与 chunk 拼接结果。
2. 规范化与顺序修复都替换每行位置，因此把累积折叠成单个 chunk 并重建 UUID 索引；
   chunk 边界不是承诺，行的位置才是。

### 改动二：服务反向遍历建键

`matchingKeys` 从 `buffer.indices` 改为 `buffer.indices.reversed()`。生产会话数组是
append 顺序（最旧在前），反向遍历正好按展示顺序（`startedAt` 降序）产出键，于是排序
拿到「已经是一个降序 run」的输入。排序仍**无条件**执行：没有缓存、没有跨请求状态、
没有需要失效的东西，改变的只是排序的输入顺序。

排序键新增第三级比较 `index`：行可能共享两个排序分量（同一 `startedAt` 与同一 `id`、
其余字段不同）。这类行本身无序，旧实现把这个顺序交给排序，而本机 Swift 的 `sort(by:)`
是稳定的（实测 8 个全等价元素保持输入顺序），因此旧结果是「provider 快照里更靠前的那行」
胜出。反向遍历会把它反过来（实测同一 fixture 旧实现返回 Alpha、只改反向遍历后返回 Beta），
所以用原始行下标做最后一级 tie-break，把结果恢复到与旧实现逐字段相同，并且不再依赖
排序是否稳定。时间与 id 都相等时才会比较下标，真实数据上不产生额外成本。

### 测量结果（两轮最小值，单位毫秒）

#### `chronological`（从未重写过，生产可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 2.113 | 2.072 | 1.02× | 3.795 | 3.713 | 1.02× |
| `serviceProjects` | 1.568 | 1.590 | 0.99× | 2.779 | 2.812 | 0.99× |
| `serviceFilterOnly` | 0.159 | 0.163 | 0.98× | 0.290 | 0.302 | 0.96× |
| `serviceFirstPage` | 0.526 | 0.467 | 1.13× | 1.016 | 0.897 | 1.13× |
| `serviceFullPagination` | 86.740 | 77.184 | 1.12× | 319.717 | 281.906 | 1.13× |
| `fullPagination` | 160.695 | 83.516 | 1.92× | 603.159 | 294.573 | 2.05× |
| `lastPage` | 0.510 | 0.455 | 1.12× | 0.971 | 0.849 | 1.14× |
| `keywordFilterSwitch` | 4.613 | 4.611 | 1.00× | 8.257 | 8.295 | 1.00× |
| `dayRangeFilterSwitch` | 3.883 | 3.873 | 1.00× | 7.042 | 7.108 | 0.99× |
| `projectFilterSwitch` | 4.456 | 4.454 | 1.00× | 7.957 | 8.002 | 0.99× |
| `statusFilterSwitch` | 4.167 | 4.078 | 1.02× | 7.601 | 7.521 | 1.01× |
| `reviewViewLoad` | 2.080 | 2.041 | 1.02× | 3.802 | 3.759 | 1.01× |

#### `edited`（被重写过的档案，生产可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 2.440 | 2.427 | 1.01× | 4.457 | 4.388 | 1.02× |
| `serviceProjects` | 1.536 | 1.588 | 0.97× | 2.724 | 2.797 | 0.97× |
| `serviceFilterOnly` | 0.160 | 0.166 | 0.96× | 0.287 | 0.308 | 0.93× |
| `serviceFirstPage` | 0.876 | 0.816 | 1.07× | 1.708 | 1.590 | 1.07× |
| `serviceFullPagination` | 142.269 | 132.356 | 1.07× | 541.524 | 502.870 | 1.08× |
| `fullPagination` | 220.548 | 138.679 | 1.59× | 839.876 | 515.490 | 1.63× |
| `lastPage` | 0.857 | 0.803 | 1.07× | 1.659 | 1.535 | 1.08× |
| `keywordFilterSwitch` | 5.020 | 5.033 | 1.00× | 9.019 | 8.916 | 1.01× |
| `dayRangeFilterSwitch` | 4.210 | 4.192 | 1.00× | 7.665 | 7.565 | 1.01× |
| `projectFilterSwitch` | 4.751 | 4.760 | 1.00× | 8.589 | 8.520 | 1.01× |
| `statusFilterSwitch` | 4.813 | 4.756 | 1.01× | 8.879 | 8.705 | 1.02× |
| `reviewViewLoad` | 2.395 | 2.368 | 1.01× | 4.439 | 4.345 | 1.02× |

按用户可见操作看：滚动到历史末尾快 2.05×（16,000）/ 1.92×（8,000），重写档案 1.63× /
1.59×；首屏、复核视图入口与四种筛选切换为 0.99–1.02×（没有可测量的退化）。服务级每页
成本快 1.07–1.13×。

整档复制消失的直接对照（同一场景、两侧同样的调用方代码，只是实现不同）：

每格为「先在同一轮里相减、再取两轮最小值」，与主表取最小值的口径一致。

| `fullPagination` − `serviceFullPagination` | 8,000 基线 | 8,000 本轮 | 16,000 基线 | 16,000 本轮 |
| --- | ---: | ---: | ---: | ---: |
| `chronological` | 74.0 | 6.3 | 283.4 | 12.6 |
| `edited` | 78.2 | 6.3 | 298.4 | 12.3 |

与诊断测量（保留页存储 539.2 vs 不保留 255.1，差 284.1）一致。

### 三个被否掉的方案（都有实测，不重复尝试）

1. **排序键改存 `Double`**（`Date.timeIntervalSinceReferenceDate`）。`Date` 的比较运算符是
   Foundation 跨模块调用，实测每次比较约 6 ns，而 `Double` 约 0.4 ns；但每行多一次
   `timeIntervalSinceReferenceDate` getter 调用把建键成本抬高（`serviceFilterOnly`
   0.287 → 约 0.46–0.51），净效果为负。
2. **把「是否已有序」的判断融合进建键循环**。实测严重恶化（`serviceFilterOnly`
   0.29 → 1.26–1.45、`serviceFirstPage` 1.02 → 1.32–1.50），机理未定位
   （推测是该循环内的可选 `Date` 与 `UUID` 局部量破坏寄存器分配）。
3. **独立一趟「已有序则跳过排序」**。跳过后 `serviceFullPagination` 244.2 vs 275.2、
   `serviceFirstPage` 0.782 vs 0.873，但同一构建里 `serviceProjects` 由 2.75–2.85 升到
   3.42（0.81×，两次运行一致），连带 `refreshFirstPage` 3.79 → 4.21、四种筛选切换约 0.90×。
   `projects()` 逐字未改，这是编译单元内代码布局/内联的副作用（与 §第三轮 记录的未定位
   4–5% 回退同类）。用更高频的首屏与筛选切换去换 11% 的滚动收益为负，因此删除。

### 残留下界（本轮结束时）

- **每页仍是 O(N) 建键 + O(N log N) 键排序**：16,000 行 0.88 ms/页，其中建键约 0.3、
  排序约 0.3（反向输入）、页物化约 0.1，其余是每页 512 KB 键数组的分配/释放与 actor 调用。
  没有引入跨页缓存（理由见 §实现与一致性边界）。
- **反向遍历让纯建键路径慢 4–7%**：`serviceFilterOnly`（`estimatedCount`，只建键不排序）
  16,000 chronological 0.290 → 0.302、edited 0.287 → 0.308。生产代码目前没有
  `estimatedCount` 的调用者，因此不影响用户路径；若将来接入，需要重新权衡这个方向。
- **`refreshFirstPage` 现在几乎完全是 `projects()`**：16,000 行 3.713 ms 中 2.812 ms（76%）
  是 `serviceProjects`，本轮按约定没有改动它。
- **`shuffled` 顺序本轮未重测**：它仍只是不可达的乱序代理。
- **每页一次 512 KB 键数组分配未优化**：跨调用复用工作缓冲可以省掉它，但那要求 actor
  保证「计算期间不 await」，收益未测量，本轮未做。

### 残留风险

- **真实 GUI 未验证**。上表与诊断里的「读者持有存储」都是值语义模型：真实 SwiftUI 列表
  是否同样长期持有这些行没有测过，因此「每页约 0.87 ms 的保留成本在真实 GUI 中同样存在」
  是模型假设，不是 GUI 测量。`List` 内嵌套 `ForEach` 的分组/行身份、`onAppear` 分页触发位置、
  复核视图的 `List(selection:)` + `.tag()` 都只有编译期与单元测试覆盖。尤其：只有重复行的页
  没有新尾行，旧末行不会重新 `onAppear`（旧实现同样如此）；修序折叠会改变部分行的外层
  页身份。真实滚动帧率、RSS、整机能耗同样未测，因此「每页 ~0.82 ms 的复制在真实 GUI
  中同样存在」是诊断模型的结论，不是 GUI 测量。
- 未测真实档案中重写行的占比（`edited` 的 2% 仍是代表性假设）。
- 无 `release-install`/`release-acceptance`：本轮不涉及签名、安装、Widget 数据或
  Git 刷新路径，且安装会写入外部状态。

### 验证范围与独立复核（本轮）

选择 **Module/contract**：改动跨 Core 查询服务与 App 控制器/视图。Core 公开 API 与
`FocusSessionQuerying` 协议签名未变，但 App 内部表示（`allSessions` 由存储属性变为计算属性、
新增 `sessionPages`/`loadedSessionCount`/`lastLoadedSessionID`）、`loadState` 载荷语义与
视图结构（嵌套 `ForEach`）改变。

```sh
./script/swiftpm.sh build
./script/swiftpm.sh test --filter 'FocusSessionQueryTests'
./script/swiftpm.sh test --filter 'HistoryQueryControllerTests'
./script/swiftpm.sh test            # 全量
git diff --check
```

全量（在最终修订上执行）：`TinyBuddyCoreTests` 1,055 项（1 项默认跳过的 opt-in 性能
测试）、`TinyBuddyAppTests` 733 项（2 项默认跳过），均 0 失败，退出码 0；
`git diff --check` 通过。

新增/改写的覆盖与变异验证：

- `FocusSessionQueryTests.testAppendAndDisplayOrderProviderInputProduceIdenticalPages`（新增）：
  同一批行分别以 append 顺序与展示顺序交给服务，比较 **`FocusSessionQueryPage` 对象本身**
  （行内容、顺序、`hasMore`、`nextCursor`、总数），并额外断言页大小 `[5, 5, 2]`、
  `hasMore == [true, true, false]`、末页无游标；两种 fixture（tie 组已按 id 排序 / 逆序）。
  变异验证：去掉排序后该测试失败。
- `FocusSessionQueryTests.testDuplicateSortKeysKeepProviderOrder`（新增）+ 既有
  `testDuplicateSortKeysFollowTheStrictlyAfterCursorRule` 增加一条首行断言：
  固定「两个排序分量都相同的行按 provider 顺序返回」。变异验证：删掉 `index` 这级
  tie-break 后两个测试都失败（复现了复核指出的那处可观察差异）。
- `HistoryQueryControllerTests` 新增四项：`testRenderedPageStorageIsUnaffectedByLaterAppends`、
  `testChunkLayoutAcrossStablePagesAndDuplicateOnlyPage`、
  `testMalformedFirstPageNormalizationCollapsesTheAccumulation`、
  `testOrderJumpRepairCollapsesTheAccumulation`，共用 `assertAccumulationMatchesChunks`
  （对**独立期望数组**断言 chunk 拼接、行数、尾行 ID，并断言不存在空 chunk）。
  变异验证：删掉 `guard !additions.isEmpty else { return }` 后重复页测试失败。
- 两处旧断言由「`page.sessions` 即整档累积」改为分页载荷断言（见 §改动一）。
- 性能测试新增 `renderedListPagination`：把页存储跨 append 保留（并 `withExtendedLifetime`
  固定生命周期），断言保留的值没有被后续 append 改动。它是**读者持有存储的压力模型**，
  不是 SwiftUI 行生命周期的测量；基线侧没有这个场景，因此基线对比一律用
  `fullPagination`（两侧调用方代码对等）。

跨模型独立只读复核（Codex `gpt-6.1-sol`，`delegate_task`，两轮）。第 1 轮判定「同排序键行的
顺序」是可观察差异（上面那条 BLOCKING，已按上述方式修正并加测试），并要求补强新测试的断言、
修正注释里超出证据的表述。第 2 轮确认该阻塞项已解决（tie-break 方向正确、三级比较仍是严格
弱序、游标谓词保持单调），另指出两处需要修正的表述：复制成本被重复扣除了一次控制器开销
（现改为「保留存储的增量成本 0.871 ms/页」，不再声称单独测得纯复制耗时），以及新核心测试
尚未比较页面元数据（现已整体比较 `FocusSessionQueryPage`）。两处均已修正并重测。

复测命令与两侧原始输出见 `.build/history-perf-r4/`（`final-chronological-*` 与
`edited2-*`，未提交到仓库）。
## 第五轮：每页有界选择（删除每页整档键数组与全量排序）

本轮基线为 `471a7faf7f7a0c791533233a72b578a731adc754`（工作树无未提交改动），即第四轮结束
状态。数据集、页面大小（50）、三种 provider 顺序、预热与中位数方法与 §可重复工作负载 相同；
`TINYBUDDY_HISTORY_BENCHMARK_SIZES=2000,8000,16000`、`SAMPLES=5`、Release。

两侧在同一会话内**成对交替**测量并各测两遍（A/B/A/B，A=本轮，B=基线），只把
`Sources/TinyBuddyCore/FocusSessionQueryService.swift` 换成 HEAD 版本，测试文件与数据完全相同。
每格取两轮最小值，单位毫秒：

```sh
cp Sources/TinyBuddyCore/FocusSessionQueryService.swift /tmp/cand.swift
run () { for order in chronological edited shuffled; do
  TINYBUDDY_HISTORY_BENCHMARK=1 TINYBUDDY_HISTORY_BENCHMARK_SIZES=2000,8000,16000 \
  TINYBUDDY_HISTORY_BENCHMARK_SAMPLES=5 TINYBUDDY_HISTORY_BENCHMARK_ORDER=$order \
    ./script/swiftpm.sh test -c release --filter HistoryQueryPerformanceTests/testHistoryQueryScenarioBaseline
done }
run; git checkout HEAD -- Sources/TinyBuddyCore/FocusSessionQueryService.swift; run
cp /tmp/cand.swift Sources/TinyBuddyCore/FocusSessionQueryService.swift; run
git checkout HEAD -- Sources/TinyBuddyCore/FocusSessionQueryService.swift; run
```

原始输出（每行一条场景中位数）在 `.build/history-query-perf/r5c-{cand1,base1,cand2,base2}-<order>.txt`，
未提交到仓库。仍是合成 fixture + 真实注册表解析器 + 真实控制器接线，不是真实用户档案的测量。

### `chronological`（从未重写过，生产可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 2.088 | 1.819 | 1.15× | 3.663 | 3.193 | 1.15× |
| `serviceProjects` | 1.560 | 1.608 | 0.97× | 2.830 | 2.790 | 1.01× |
| `serviceFilterOnly` | 0.171 | 0.159 | 1.08× | 0.316 | 0.300 | 1.05× |
| `serviceFirstPage` | 0.473 | 0.210 | 2.25× | 0.919 | 0.376 | 2.44× |
| `serviceFullPagination` | 77.676 | 44.950 | 1.73× | 287.283 | 151.867 | 1.89× |
| `fullPagination` | 85.995 | 52.703 | 1.63× | 303.011 | 168.046 | 1.80× |
| `renderedListPagination` | 86.363 | 52.310 | 1.65× | 303.020 | 166.553 | 1.82× |
| `lastPage` | 0.463 | 0.251 | 1.84× | 0.864 | 0.442 | 1.95× |
| `keywordFilterSwitch` | 4.633 | 4.348 | 1.07× | 8.239 | 7.712 | 1.07× |
| `dayRangeFilterSwitch` | 3.843 | 3.674 | 1.05× | 7.005 | 6.548 | 1.07× |
| `projectFilterSwitch` | 4.462 | 4.138 | 1.08× | 8.073 | 7.533 | 1.07× |
| `statusFilterSwitch` | 4.124 | 3.639 | 1.13× | 7.582 | 6.370 | 1.19× |
| `reviewViewLoad` | 2.060 | 1.817 | 1.13× | 3.687 | 3.277 | 1.13× |
### `edited`（被重写过的档案，生产可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 2.439 | 1.937 | 1.26× | 4.462 | 3.399 | 1.31× |
| `serviceProjects` | 1.605 | 1.581 | 1.02× | 2.812 | 2.980 | 0.94× |
| `serviceFilterOnly` | 0.167 | 0.159 | 1.05× | 0.316 | 0.300 | 1.05× |
| `serviceFirstPage` | 0.827 | 0.306 | 2.70× | 1.628 | 0.480 | 3.39× |
| `serviceFullPagination` | 134.549 | 59.142 | 2.28× | 513.562 | 180.502 | 2.85× |
| `fullPagination` | 142.556 | 65.489 | 2.18× | 529.872 | 197.150 | 2.69× |
| `renderedListPagination` | 142.952 | 66.033 | 2.16× | 529.690 | 197.104 | 2.69× |
| `lastPage` | 0.815 | 0.254 | 3.21× | 1.561 | 0.462 | 3.38× |
| `keywordFilterSwitch` | 5.074 | 4.585 | 1.11× | 9.148 | 8.004 | 1.14× |
| `dayRangeFilterSwitch` | 4.209 | 3.822 | 1.10× | 7.715 | 6.735 | 1.15× |
| `projectFilterSwitch` | 4.832 | 4.437 | 1.09× | 8.635 | 7.736 | 1.12× |
| `statusFilterSwitch` | 4.813 | 3.968 | 1.21× | 8.846 | 6.737 | 1.31× |
| `reviewViewLoad` | 2.400 | 1.991 | 1.21× | 4.424 | 3.369 | 1.31× |
### `shuffled`（固定种子乱序代理，不可达）

| 场景 | 8,000 基线 | 8,000 本轮 | 加速 | 16,000 基线 | 16,000 本轮 | 加速 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `refreshFirstPage` | 11.228 | 1.705 | 6.59× | 22.947 | 2.746 | 8.36× |
| `serviceProjects` | 1.333 | 1.366 | 0.98× | 2.265 | 2.242 | 1.01× |
| `serviceFilterOnly` | 0.168 | 0.159 | 1.06× | 0.311 | 0.299 | 1.04× |
| `serviceFirstPage` | 9.937 | 0.319 | 31.15× | 20.674 | 0.496 | 41.68× |
| `serviceFullPagination` | 1,586.892 | 63.312 | 25.06× | 6,594.847 | 197.554 | 33.38× |
| `fullPagination` | 1,593.628 | 70.052 | 22.75× | 6,614.686 | 213.075 | 31.04× |
| `renderedListPagination` | 1,596.317 | 70.338 | 22.69× | 6,609.058 | 213.743 | 30.92× |
| `lastPage` | 9.834 | 0.295 | 33.34× | 20.656 | 0.484 | 42.68× |
| `keywordFilterSwitch` | 14.935 | 4.079 | 3.66× | 29.093 | 6.838 | 4.25× |
| `dayRangeFilterSwitch` | 12.894 | 3.281 | 3.93× | 25.718 | 5.556 | 4.63× |
| `projectFilterSwitch` | 13.571 | 3.901 | 3.48× | 26.381 | 6.566 | 4.02× |
| `statusFilterSwitch` | 22.515 | 3.350 | 6.72× | 45.369 | 5.505 | 8.24× |
| `reviewViewLoad` | 11.240 | 1.673 | 6.72× | 22.811 | 2.763 | 8.26× |
### 小历史（2,000 条，默认规模）

| 场景 | chronological 加速 | edited 加速 | shuffled 加速 |
| --- | ---: | ---: | ---: |
| `refreshFirstPage` | 1.07× | 1.10× | 0.98× |
| `serviceFirstPage` | 1.54× | 1.49× | 0.95× |
| `serviceFullPagination` | 1.34× | 1.71× | 2.08× |
| `fullPagination` | 1.29× | 1.65× | 2.04× |
| `lastPage` | 1.43× | 2.56× | 16.42× |
| 四种筛选切换 | 1.04–1.07× | 1.00–1.12× | 0.94–1.03× |
### 收益来源与量级

按用户可见操作看：16,000 条时打开历史与复核视图入口快 1.15×（chronological）/
1.31×（edited），四种筛选切换 1.07–1.19× / 1.12–1.31×，
滚动到历史末尾 1.80× / 2.69×；首屏查询本体
2.44× / 3.39×。2,000 条时幅度更小
（1.00–2.56×）：小档案里 `projects()` 与控制器开销占主要部分。

chronological 与 edited 两个可达顺序、三种规模下，除下面单独讨论的 `serviceProjects` 外没有任何
场景慢于基线：最小一项是 edited 2,000 的 `keywordFilterSwitch` 1.00×（噪声内），最大
3.39×。`serviceProjects` 的实现本轮**逐字未改**，取值在 0.94–1.03× 之间双向摆动，
可见该列只是构建间漂移，不能当作收益或回退。

`shuffled` 在 16,000 / 8,000 条上仍在快路径，但 **2,000 条的 `shuffled` 会触发回退**：该布局整档
约需 9,200 次替换比较而预算是 `4 × 2,000 = 8,000`，于是每页先付一趟被放弃的扫描再走键数组路径，
实测 0.98× / 0.95× / 四种筛选
0.94–1.03×
（`lastPage` 仍 16.42×）。`shuffled` 是不可达的乱序代理，这是有意的上界保护。

`serviceProjects` 现在是 `refreshFirstPage` 的主导项：16,000 chronological 下
2.790 / 3.193 = 87%，
edited 下 88%（两个实测值之比，不是独立测量）。

### 为什么不是「有界最大堆」：被本轮否掉的第一个实现

第一次实现把候选键放进有界最大堆（根为最差键），每页仍只保留 `limit` 个键。它在功能上正确
（当时 1,060 / 733 项测试全绿），但 A/B 基准显示**首屏变慢**：16,000 chronological
`serviceFirstPage` 0.902 → 1.008 ms（0.90×）、`refreshFirstPage` 3.691 → 3.849 ms，
只有 `edited` 分页（501 → 283 ms）与 `lastPage`（0.855 → 0.525）变快，因此按「不为低频场景
牺牲首屏」的约定重新设计。回退到堆同样不行：微基准里它在最坏序列上比数组更差（见下表）。

机制用独立 Release 微基准（16,000 行、9 次取最优、同机、单个 `.swift` 直接 `swiftc -O`，
不提交，只是方向性证据）定位到「每行一次比较」的常数：

| 每页做法 | chronological | shuffled | newest-first（病态） |
| --- | ---: | ---: | ---: |
| 建全部键 + 全量排序（基线） | 0.56–0.76 ms | 19.3–24.3 ms | 0.69–0.93 ms |
| 有界最大堆（快速拒绝在前） | 0.10 ms | 0.21 ms | 6.9–9.3 ms |
| 有界数组，拒绝路径先调 `DisplayOrderKey.precedes` | 0.41–0.43 ms | — | — |
| **有界数组，拒绝路径先比较原始 `Double`**（本轮采用） | **0.043–0.049 ms** | **0.16–0.21 ms** | 4.7–6.1 ms（由回退阀兜住） |

原因：`Date` 的 `<`/`!=` 是 Foundation 跨模块调用（本轮微基准约 6 ns/次），`precedes` 一次约
23 ns/行，而「已经有序的扫描」里绝大多数行只需要被拒绝一次。改用键里已有的
`startedAt.timeIntervalSinceReferenceDate` 与最差键的同一值比较（约 2.7 ns/行）后，整趟扫描的
常数降到基线的约 1/12；堆带来的「替换更便宜」不再重要，于是删除堆，改为「有界数组 + 记住最差键」。

### 实现与一致性边界（第五轮）

1. **每页一趟 O(N) 扫描，不再为整档建键、不再全量排序。** `selectPage` 在同一次反向遍历里完成：
   行本地谓词（day 区间、status）→ 需要时解析并匹配项目谓词 → 游标判定 → 有界选择。只保留
   `limit` 个键（32 字节 × 50，替代原来按 provider 行数预留的键数组，16,000 行约 512 KB），
   最后只对这 ≤ `limit` 个键排序并物化返回行。`limit >= sessions.count / 2` 的调用仍走原
   「整档建键 + 排序」路径，`estimatedCount(query:)` 也仍然如此——因此「512 KB 键数组消失」
   只对每页选择路径成立，不是全服务的普遍结论。
2. **快速拒绝。** 页未满时无比较；页满后先比较原始 `Double`（`timeIntervalSinceReferenceDate`）：
   严格更旧的候选立即跳过，不构造键、不调 `precedes`。判据的等价性前提是**有限时间戳**：
   此时 `a < b` ⟹ `Date(a) != Date(b)` 且 `Date(a) > Date(b)` 为假，即该行确实排在当前最差键
   之后。不成立时一律回落到完整 `precedes`，所以时间相等、`UUID` 相等、行下标 tie-break 都与
   改动前一致。该前提依赖 `Date` 以单个 `Double` 存储时刻并按其比较（当前 Foundation 实现，
   不是文档化保证）；表示若改变而排序关系不变则只影响速度，若排序关系改变才可能影响正确性——
   这正是把非有限输入排除在外、而不是对它推理的原因。
3. **非有限时间戳与游标走回退。** `NaN` 使比较器失去严格全序（旧实现的结果本身就不确定），
   `±infinity` 虽可推理，但为把前提写成「只对有限值成立」，扫描在**行匹配之后、游标判定之前**
   遇到 `!interval.isFinite` 立即回退；非有限游标在扫描前回退。守卫必须早于游标判定：`NaN` 行的
   游标比较全为假，若先做游标测试，这类行会被当作「游标之前」直接跳过而不触发回退（第二轮复核
   给出的 `[NaN, 1, 2, 3, 4, 5]` + 游标时间 1 的反例：旧实现返回页面，错误顺序下返回 `nil`）。
   旧实现在 `NaN` 游标下按首页处理，回退路径逐字复现该行为，
   不会变成 `nil`。
4. **回退阀（工作量预算）。** 一次替换要付 O(limit) 的最差键重扫，所以预算按**比较次数**而不是
   替换次数计：`replacementWork += kept.count`，超过 `4 × 快照行数`（有溢出保护）即回退。
   于是选择阶段的总工作量上界是 `O(行数)` 而不是 `O(行数 × limit)`——后者在
   `行数 = 3 × limit` 这类参数下可达 Θ(limit²)，本轮 review 的第一版预算（`16 × limit` 次替换）
   正是漏了这一点。回退复用同一个已热的 `ProjectResolutionMemo`，因此不产生额外 resolver 调用，
   页面、计数、游标与不回退时完全相同；`.fallbackToKeyArray` 与「游标之后没有行」
   （`.cursorMiss` → `nil`，让上层从首页重启）是两种不同类型的结果，不会混用。
5. **保持不变的语义**：版本过期先返回 `nil`；`limit <= 0` 返回 `.empty`；无游标且无匹配返回
   `.empty`（总数为 `nil`）；带游标且游标之后没有匹配行返回 `nil`；游标谓词仍只用
   `(startedAt, id)` 两个分量，因此共享同一 `(startedAt, id)` 的行依旧无法通过自己的游标续取；
   `hasMore` = 「游标之后的匹配行数 > 本页行数」；`totalEstimatedCount` = 全匹配行数；
   `nextCursor` 取本页最后一行；排序键与 tie-break 逐字未变。
6. **项目解析调用契约不变**：带 `projectKey`/关键词时，对通过行本地谓词的每个精确输入 context
   在该趟内解析一次，顺序与原来相同（反向遍历），游标之前的匹配行同样解析（回退时首遍的解析
   已被 memo 记住，不重复调用）；无项目谓词的查询不为任何非返回行解析；返回页行走同一个 memo。
   行本地谓词与页面行物化（`rowMatches`、`appendResolved`）由两条路径共用，避免两套实现漂移。
7. **内存**：只测耗时。结构上每页选择路径不再分配按行数预留的键数组（16,000 行约 512 KB），
   只保留 ≤ `limit` 个键与返回页的行；没有测分配量或 RSS，因此不声称整体内存占用下降。

### 残留下界（本轮结束时）

- **`serviceProjects` 是 `refreshFirstPage` 的主导项**（16,000 行占 85–88%，见 §收益来源与量级），
  本轮按范围约定没有改它。
- **每页仍是 O(N) 谓词扫描**：16,000 行 0.376 ms/页 chronological，其中选择与比较约 0.05 ms，
  其余是一次 177 字节/行的快照遍历、谓词判断与 actor/物化开销。形状已从
  `O(N log N) + 512 KB 分配` 变成 `O(N)`（外加 ≤ `4 × 行数` 次替换比较的上界）。
- **没有引入跨页缓存**：理由与第二轮相同——生产没有覆盖所有会话变化的缓存失效版本，缓存会让
  翻页读到陈旧行。每页仍重读 provider，`execute` 仍只调用一次 provider。
- **`estimatedCount(query:)` 仍走完整键数组路径**（本轮未改；生产无调用者）。
- **回退侧成本未单独实测**：触发时是「一趟被放弃的扫描 + 一趟完整键数组路径」，按微基准推算
  约为基线单页的 1.1–2×，无界性已消除、结果不变。2,000 行 `shuffled` 是唯一在基准里观察到该
  代价的场景（见 §收益来源与量级）。
- **`shuffled` 仍只是不可达的乱序代理**，其 30–42×（8k/16k）不代表任何真实档案。
- **非有限时间戳仍可写入存储**：本轮只保证查询路径不误判，没有加写入侧校验（不在本轮范围）。

### 测试覆盖（本轮）

`FocusSessionQueryTests` 52 项（第四轮 47 项）。新增/改写：

- `assertPaginationMatchesReference`：把「逐页与朴素逐行参考实现比较」抽成共享 walk（页对象
  逐字段比较、`estimatedCount` 交叉校验、每条匹配行恰好访问一次、遍历自行终止）。
- `testSelectionPathMatchesPerRowReferenceImplementation`：480 行、limit 25（`25 < 480/2`，
  确实走选择路径），13 种查询形状各走完整分页；同一批查询在 40 行 fixture 上走键数组路径。
- `testBoundedSelectionAgreesWithKeyArrayPath`：400 行上「limit 50 连续翻页」与「一次取 400 行」
  的行、顺序、总数、解析后身份相同——两条内部路径互为对照。
- `testSelectionPathCursorBoundaries`、`testSelectionPathDuplicateSortKeysAreUnreachableThroughTheCursor`：
  末页/越界游标、以及 10 行重复 `(startedAt, id)` 组跨页时续取返回 `nil`（固定既有怪癖）。
- `testSelectionPathFallsBackToTheKeyArrayPathOnAdversarialOrder`：600 行 newest-first、limit 25/25/50，
  三种查询各走完整分页并与逐行参考比较；自检断言改成工作量口径
  （`(matching - limit) × limit > 4 × 行数`），确保 fixture 真的超过预算而不是恒真。
- `testNonFiniteRowBeforeFiniteCursorFallsBack`：第二轮复核给出的反例本身（provider 顺序
  `[NaN, 1, 2, 3, 4, 5]`、limit 1、游标为时间 1 的行）：断言结果**不是** `nil`、总匹配数 6、
  且 `limit = 6` 时不重复地取回全部 6 行。刻意不断言胜出行与 `hasMore`——`NaN` 下比较器没有
  严格全序，旧实现的胜出者本身也不确定；这里固定的是「是页面而不是游标丢失」。
- `testNonFiniteTimestampsFallBackToTheKeyArrayPath`：快照含 `+infinity` / `-infinity` / `NaN`
  时间戳；断言返回页是期望行的排列、计数正确、`limit = 行数` 时每行恰好取回一次、且 `NaN`
  游标返回与无游标相同的页（复现旧二分行为）。不检查 `NaN` 行的相对顺序——那时比较器没有
  全序，旧实现同样不确定。
- `testSelectionFallbackKeepsResolverCallsPerContext`：回退路径下 resolver 仍按精确输入 context
  记忆化（每个 context 至多一次）。
- `testSelectionPathSentinelAndFastRejectKeepKeyArrayResults`：空 provider、匹配集为空、快照小于
  页大小、`limit == 1`、同一 `startedAt` 的 `UUID` tie-break。

变异验证：把快速拒绝从 `interval < worstInterval` 改成 `<=`，focused 套件两轮各出现 25 / 27 处
失败（选择路径差分、既有差分、哨兵、append/展示顺序等价、跨页同时间戳、UUID 序），随后立即
还原并校验 `shasum` 与原文件一致。临时探针（已删除、校验字节相同）确认：对抗顺序用例命中
`.fallbackToKeyArray` 39 次（全部由工作量预算触发）、非有限用例命中 5 次（扫描 4 + 游标 1）
另加 1 次预算回退、resolver 用例命中 1 次。

### 验证范围与独立复核（本轮）

选择 **Module/contract**：改动集中在 `TinyBuddyCore` 的查询服务，公开 API 与协议签名未变，
唯一生产消费者仍是 `HistoryQueryController`。

```sh
./script/swiftpm.sh build
./script/swiftpm.sh test --filter FocusSessionQueryTests      # 52 项
./script/swiftpm.sh test                                      # 全量
git diff --check
```

全量（最终修订上执行，退出码 0）：`TinyBuddyCoreTests` 1,064 项（1 项默认跳过的 opt-in
性能测试）、`TinyBuddyAppTests` 733 项（2 项默认跳过），均 0 失败。

表格中的数值来自定稿前的同一次三规模 A/B（`r5c`）。此后为修掉「有限游标 + `NaN` 行」的反例，
把 `isFinite` 守卫移到了游标判定之前，并另跑一次 16,000 条的 A/B 复核（`r5d`，两轮最小值）：
`serviceFirstPage` 2.42× / 3.36×、`serviceFullPagination` 1.73× / 2.64×、`fullPagination`
1.66× / 2.51×、`refreshFirstPage` 1.23× / 1.43×（chronological / edited），方向与量级一致；
该次候选侧两轮自身相差 5–10%，因此它只作为「守卫顺序调整没有引入回退」的复核，不替换上表。

独立只读复核（跨模型）两轮：第 1 轮否掉了首版有界最大堆（首屏 0.90×，见 §为什么不是「有界最大堆」）
并指出两项阻塞——`NaN` 游标下新旧实现返回不同结果、工作量预算按 `limit` 而非行数计仍可到
`O(行数 × limit)`；两项均已修正（§实现与一致性边界 第 3、4 条）并补充了对应测试。第 2 轮针对
修正后的定稿复核。

没有运行 GUI 回归、`script/regression_gate.sh`、`benchmark_git_refresh.sh` 或 `release-install`：
本轮不涉及 Git 刷新、签名、安装、Widget 数据或发布行为，且这些命令会操作外部状态。因此证据
覆盖查询服务的 CPU 工作量与历史列表分页的功能行为，不代表真实 GUI 进程的滚动帧率、RSS 或整机
能耗，也不代表真实档案中重写行的实际占比（`edited` 的 2% 仍是代表性假设）。微基准是单文件、
未提交的方向性证据；正式证据是上面三张基准表，两者口径不同，不可混用。
