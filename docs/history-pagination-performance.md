# 专注历史连续分页性能

## 可重复工作负载

基线为执行时最新 `origin/main`：`ed0e575999a2eadb4417bfed7edd7ddee7549d76`。
测试环境为 arm64 macOS、Apple Swift 6.4，使用 Release 编译。

`HistoryQueryControllerTests.testContinuousPaginationPerformance` 生成确定性的
2,000、8,000、16,000 条会话，维持生产页面大小 50，各执行三次完整分页。
预生成页面、首次 `refresh()` 和最终结果断言不计入追加耗时；每次
`loadMore()` 的 actor 调用、状态发布、去重、顺序处理和数组追加均计入。
测试输出 `HISTORY_PAGINATION` 行，包含完整追加时间与四个连续阶段时间。

使用预生成页面是为了隔离控制器处理成本；查询服务本身每次读取、筛选、排序
数据的成本和 SwiftUI 绘制成本不在测量范围内。真实服务的分页、数据变化、
相同时间戳、筛选切换及失效恢复由功能测试覆盖。

```sh
rtk proxy ./script/swiftpm.sh test -c release --filter HistoryQueryControllerTests/testContinuousPaginationPerformance
```

复测基线时，在独立的 `origin/main` 工作树中使用本次的测试文件，将原控制器的
属性与初始化参数 `FocusSessionQueryService` 改成 `any FocusSessionQuerying`，
以便注入相同固定页面；保留原来的追加算法。此注入接口是已有协议，不改变
查询行为。原算法会触发新增的增长比例断言失败，输出时间仍可用于比较。
本次基线测量在增加该断言之前进行，命令成功退出。

## 测量结果

下表为同机三次样本的中位数，单位为毫秒；阶段比为末阶段中位数除以首阶段中位数。

| 历史条数 | main 完整追加 | 优化完整追加 | 加速比 | main 末/首阶段 | 优化末/首阶段 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2,000 | 10.885 | 1.878 | 5.8× | 5.06× | 1.13× |
| 8,000 | 164.372 | 7.249 | 22.7× | 6.45× | 1.03× |
| 16,000 | 643.828 | 15.002 | 42.9× | 6.61× | 1.07× |

历史从 8,000 加倍到 16,000 时，main 耗时增至 3.92 倍，优化后为 2.07 倍。
性能回归断言要求 16,000 条下末阶段中位数小于首阶段中位数的三倍；不使用
绝对耗时阈值，并以三次中位数降低偶发调度抖动影响。

## 实现与一致性边界

控制器保存已加载 UUID 集合。稳定页面只处理新增会话，检查页边界及新增行的
相邻顺序，并保留首现 UUID 的值。异常顺序触发全量排序；首页异常则在第一次
追加时沿用原去重与排序行为。`refresh()` 重建索引，陈旧返回在修改索引前丢弃。
游标、加载内容、页面大小以及首页总数（包括 `nil`）保持原语义。

追加前只提取游标与总数，释放控制器旧 `.loaded` 页对数组的共享引用，避免
每次写时复制已加载数组。数组与集合扩容仍有偶发线性成本，稳定追加为摊销的
新增页成本。外部消费者若长时间保存旧数组快照，仍可能触发 Swift 写时复制；
此次没有改变公开快照的值语义。

## 验证范围

选择 Focused 验证：变更局限于 App 控制器及测试注入已有协议，不涉及持久化、
Core 查询算法、共享快照、跨进程协议或发布安装。

```sh
rtk proxy ./script/swiftpm.sh test -c release --filter 'HistoryQueryControllerTests|FocusSessionQueryTests|FocusSessionQueryPerformanceTests|FocusHistoryPresentationConsistencyTests'
rtk proxy ./script/swiftpm.sh test -c release --filter HistoryQueryControllerTests
rtk git diff --check
```

首个组合命令通过 63 项测试；补充重复整页、总数 `nil` 和后续页边界异常覆盖后，
最后一个控制器测试命令通过全部 24 项，验证最终测试输入。SwiftPM 同时编译了 App 与 Core
直接消费者。没有运行全量测试。

## 本机签名安装运行

按用户授权，在 macOS 27.0.1 上执行：

```sh
rtk proxy env TINYBUDDY_SIGNING_MODE=signed ./script/build_and_run.sh release-install
```

命令成功：Release 构建、签名和权限验证、环境预检、事务安装均通过。
新 App 已安装并运行于 `/Applications/TinyBuddy.app`；运行中的 App 与 Widget
可执行文件路径及哈希均匹配安装包，HUD 与 Widget 消费同一 schema、revision
和 local day 的共享快照，保存的目录授权得到保留。使用本机开发签名与配置
描述文件，符合 macOS 15 及以后 App Group 权限要求。

此结果是本机安装运行证据，不是 `release-acceptance` 全量验收。

