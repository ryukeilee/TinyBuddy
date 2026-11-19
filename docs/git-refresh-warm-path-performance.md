# Git 活动刷新热路径性能

## 可重复工作负载

基线为执行时 main 的 c564fe333f；两侧只回退 script/update_git_completion_count.sh，
使用同一份夹具、同一台机器（arm64 macOS 27.2、Apple M2 16 GB、/bin/bash 3.2.57）。
计时不含 App 进程：直接以生产环境变量运行脚本，缓存目录与偏好文件都在临时目录。

两种夹具，均为「已完成仓库 + .git/logs/HEAD 文本 reflog」的现有 benchmark 形态：

| 夹具 | 仓库数 | 每仓当天事件 | 说明 |
| --- | ---: | ---: | --- |
| 稠密 | 24 | 100 | script/benchmark_git_refresh.sh 默认负载（2,400 个当天事件） |
| 真实规模 | 11 | 20 | 本机真实扫描根的仓库数量量级，事件密度取偏保守的 20 |

命令（同机、同夹具、交替执行；warm 为已有仓库列表与 reflog 缓存的第二次运行）：

~~~sh
env TINYBUDDY_USER_HOME=... TINYBUDDY_APP_GROUP_PREFERENCES_DIR=... \
  TINYBUDDY_GIT_REPOSITORY_CACHE_DIR=... TINYBUDDY_GIT_SCAN_ROOTS=... \
  TINYBUDDY_TODAY=$(date +%F) TINYBUDDY_REFRESH_EPOCH=... \
  /bin/bash script/update_git_completion_count.sh
~~~

## 测量结果

直接计时（秒，两次 warm 运行一致）：

| 夹具 | 阶段 | 基线 | 本轮 | 加速 |
| --- | --- | ---: | ---: | ---: |
| 稠密 | 冷启动（无缓存） | 50.18 | 29.20 | 1.72× |
| 稠密 | warm（缓存命中） | 15.44 | 6.60 | 2.34× |
| 真实规模 | warm（缓存命中） | 4.06 | 1.56 | 2.60× |

官方门禁 script/benchmark_git_refresh.sh（默认 24 仓 / 100 事件 / 30,000 目录；
该脚本每 20 ms 采样一次进程资源，绝对值含采样开销，用于同门禁前后对比）：

| phase | 基线 wall_ms | 本轮 wall_ms |
| --- | ---: | ---: |
| first | 51,575 | 30,571 |
| incremental | 16,542 | 7,022 |
| padded | 17,549 | 8,753 |

准确性与范围断言通过：2,400 个预期事件、仓库变更只重扫受影响仓库、
scan-root 失效仍重扫整根且两者发布相同活动、取消在 2 s 内完成（最终设计两次实测
413 ms 与 1,047 ms，门禁上限 2 s；这是脚本取消收敛时间，不是稳态刷新成本）。为让取消在
缓存命中的 reflog 阶段也能立即收敛，read_reflog_signature 的 stat/cksum 改为
写入临时文件而不是命令替换，主 shell 因此停留在可被 SIGTERM 打断的前台命令上。

## 根因与改动

1. **每个活动事件启动一次 awk 查询最近项目指纹**：
   process_repository_list 的事件循环里，每次「最新事件」胜出都执行
   awk -F '\t' -v identity=... '$2 == identity { print $1; exit }' project_discovery_records_file。
   该值只在循环结束后被读取一次。稠密夹具 2,400 个事件对应 2,400 次 awk；同一次
   带时间戳的 trace 里该模式累计 4.47 s（约 1.9 ms/次，启动加一行匹配），是 warm
   运行中最大的单项。另有 120 次按仓库的缓存校验 awk（1.2 MB/2,400 行 stats 文件，
   约 17–25 ms/次，累计约 2.1 s），量级不同，不应混为一谈。
   现在循环退出后按最终胜者查询一次；中间胜者的指纹从未被使用，语义等价。
2. **超时包装器每个外部命令轮询 sleep 0.01 秒**：
   run_command_with_timeout 原先每次轮询都启动一个 sleep 进程；macOS 上每次
   sleep 进程创建约 15 ms，一次快速的 stat/cksum/test 因此要付 15–20 ms。
   现在改为一次性 watchdog：脚本启动时打开一个只用于计时的 FIFO 读/写描述符，
   watchdog 用内建 read -t 等待整个超时时间，没有 timer 子进程。Bash 3.2 会把
   trapped 信号推迟到 read 返回，因此父进程用 SIGKILL 回收空闲 watchdog（它不持有
   任何资源），而不是 TERM；这样快速失败的外部命令既不会留下 timer，也不会让
   watchdog 等到超时才退出。超时路径仍对命令先 SIGTERM、再等待 0.1 秒、再 SIGKILL，
   并保留返回值 124 与 active_command_pid 的终止处理；超时处理中的 watchdog 由
   父进程等待其完成（因此宽限期的 sleep 不会被留下），空闲 watchdog 才用 SIGKILL
   回收；取消路径若发现超时标记也改为等待其完成，否则对当前命令同样执行有界的
   SIGTERM → 0.1 秒 → SIGKILL（忽略 SIGTERM 的命令也能在 5 秒内收敛并回收）。
   Bash 3.2 在计时 read 之后对
   小数 read -t 不可靠，所以 0.1 秒宽限仍用真实 sleep，由等待关系保证回收。
   48 次 stat+cksum 从 939 ms
   降到约 147 ms（同机微基准，直接执行约 125 ms）；连续 100 次快速失败总耗时约
   294 ms；超时 1 s 连续 4 次均返回 124，且每次立即检查进程表都没有
   sleep 0.1/sleep 30/watchdog 残留；取消路径同样无残留。新增
   testScriptPreservesTimeoutGraceForCommandCleanup：收到 SIGTERM 后需要 50 ms
   清理的探测命令必须完成清理（在 mutant 上该测试会失败）；
   testCancellationEscalatesWhenACommandIgnoresSIGTERM：确认探针已进入 reflog
   stat 后发送取消信号，忽略 SIGTERM 的探针必须被 SIGKILL 且脚本在 5 秒内退出
   （在缺少升级的 mutant 上该测试失败），以及
   GitActivityRefreshScriptTests.testScriptDoesNotWaitForScanTimeoutWhenAnExternalCommandFailsFast
   固定这个行为。
3. **每个 reflog 事件多算两个未使用的本地时间**：
   append_reflog_events_for_today 对每个事件执行 date -r epoch +%H 与 +%M，
   再算一个从未被读取的 block_minute；实际只使用 date +%Y-%m-%d 做当天过滤和
   epoch/1800 作为专注块。删除两个死调用（稠密冷启动 40.4 → 29.3 秒，
   与第 2 项共同作用）。

缓存格式（v3 行、字段、校验和）、reflog 事件语义、当天边界、专注块、
指纹与自动身份过滤均未改变。

## 验证范围

选择 **Module/contract**：改动限于刷新脚本的内部执行机制与一个死代码删除，
不改变 App/Widget 契约、缓存 schema、共享 plist 字段或签名边界；依赖清单新增
标准 macOS 命令 mkfifo（只用于计时 FIFO）。执行：

~~~sh
/bin/bash -n script/update_git_completion_count.sh
./script/swiftpm.sh test --filter GitActivityRefreshScriptTests   # 79 项通过
./script/benchmark_git_refresh.sh                                 # 通过
git diff --check
~~~

## 残留下界

- **warm 路径每仓库仍有约 5 次 awk 进程**（cache entry 是否存在、两次事件匹配、
  缓存行回放、指纹查询）。稠密夹具下每次约 20 ms，真实规模下约 5–10 ms。
  合并为一次校验+回放可以把 warm 再降一档，但需要重写缓存内容校验的 awk 程序，
  风险与验证成本高于本轮已获得的收益，未实施。
- **冷启动仍按事件执行 cksum 与 date**：每个当天事件一次 cksum（消息指纹）与
  一次 date（当天过滤）。稠密冷启动 29 s 中大部分来自这两类进程；把当天过滤改成
  一次计算的本地日区间、把指纹改成批量算法需要处理 DST 与缓存指纹兼容，
  本轮没有改。
- **首次发现仍随扫描根大小线性增长**（30,000 目录夹具约 1–3 秒），这是 find 本身
  的成本，与本次改动无关。
- 以上数据来自脚本级计时，不是 App 进程的 CPU/RSS/wakeups；App 侧刷新协调器、
  5–60 分钟的刷新节奏与低电量策略未改。
