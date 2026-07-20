# TinyBuddy

TinyBuddy 是一个 macOS 14 桌面伴侣 HUD 应用，用 SwiftUI + SwiftPM + WidgetKit 构建。

## 项目结构

```
Sources/
  TinyBuddyCore/                    # 共享核心逻辑（无 UI 依赖）
    DailyStats.swift                # 每日统计数据模型
    DailyStatsStore.swift           # 每日统计持久化
    FocusSession*.swift             # 专注会话引擎、时钟、配置、协调器、存储
    GitActivityExperienceState.swift
    GitActivityRefreshStatusStore.swift
    GitCommandExecutor.swift        # Git 命令执行封装
    GitTodayActivity*.swift         # 今日 Git 活动刷新策略、快照、可信存储
    GitTodayCommitCountStore.swift
    GitTodayFocusBlockCountStore.swift
    GitTodayRecentProjectStore.swift
    PetSession.swift / PetStatus.swift
    TinyBuddyAppConfig.swift
    TinyBuddyAppGroupPreferencesStore.swift
    TinyBuddyArcReactorCore.swift
    TinyBuddyCombinedSnapshotStore.swift   # 核心：统一快照架构
    TinyBuddyConfigStore.swift
    TinyBuddyDebugLogManager.swift
    TinyBuddyDiagnosticReport.swift
    TinyBuddyDisplayPresentation.swift
    TinyBuddyHUDTheme.swift
    TinyBuddyHistoryStore.swift
    TinyBuddyPrivacyRedactor.swift
    TinyBuddyReleaseSnapshotVerifier.swift
    TinyBuddySharedData.swift
    TinyBuddySharedSnapshotObservation.swift
    TinyBuddyStorageCleanupService.swift
    TinyBuddyTimeEnvironment.swift
    TinyBuddyWidgetPresentation.swift       # Widget 展示数据

  TinyBuddy/                       # macOS HUD App
    TinyBuddyApp.swift             # @main 入口
    PetView.swift / PetViewModel.swift     # 宠物 UI
    HUDWindowPositionController.swift      # 悬浮窗位置管理
    FocusSessionAppBridge.swift
    GitActivityExperiencePresentation.swift
    GitActivityRefreshCoordinator.swift    # 刷新协调
    GitRepositoryChangeMonitor.swift
    GitScanRootAuthorizationStore.swift    # 安全域书签存储
    GitScanRootSettingsView.swift
    RefreshEnvironmentMonitor.swift
    TimeEnvironmentChangeMonitor.swift
    TinyBuddyConfigCoordinator.swift
    TinyBuddyInstanceCoordinator.swift     # 实例协调
    TinyBuddyLoginItemManager.swift
    TinyBuddyOnboardingStore.swift
    TinyBuddyResetExecutionCoordinator.swift
    TinyBuddyResetService.swift
    TinyBuddySharedSnapshotDiagnostics.swift

  TinyBuddyReleaseInstaller/       # 命令行安装器
    main.swift
  TinyBuddyReleaseVerifier/        # 命令行验证器
    main.swift

Widget/
  TinyBuddyWidget/                 # WidgetKit 桌面 Widget

Tests/
  TinyBuddyCoreTests/              # 核心模块测试
  TinyBuddyAppTests/               # App 层测试（含真实 Git fixture）

script/
  build_and_run.sh                 # 主构建/运行/安装/验证入口（~103KB）
  regression_gate.sh               # 回归测试门禁
  update_git_completion_count.sh   # 启动时 Git 刷新脚本（~78KB）
  benchmark_git_refresh.sh         # Git 刷新性能基准
  verify_resource_stability.sh     # 资源稳定性验证
  swiftpm.sh                       # SwiftPM 封装
  local_build_env.sh               # 本地构建环境
  process_resource_probe.swift     # 资源探测工具

Resources/
  TinyBuddyApp/                    # App Info.plist, 权限, Assets
  TinyBuddyWidget/                 # Widget Info.plist, 权限

docs/
  superpowers/                     # 超能力文档
```

## 核心架构原则

### 1. 快照驱动架构

App 和 Widget 不从独立 Key-Value 存储读取数据，而是通过 **TinyBuddyCombinedSnapshotStore** 产生统一的提交快照。Widget 读取已提交的快照作为展示输入。

- `TinyBuddyCombinedSnapshotStore` 负责：收集各维度数据 → 写入原子快照（schema + revision + day）
- `TinyBuddyWidgetPresentation` 是 Widget 的只读展示模型
- `TinyBuddySharedSnapshotObservation` 连接快照变更与 Widget 刷新
- 所有消费者必须使用同一 schema/revision/day 的快照

### 2. 核心层分离

| 层 | 职责 | 依赖 |
|---|---|---|
| `TinyBuddyCore` | 领域逻辑、持久化、Git 操作、Widget 数据 | 无 UI 框架 |
| `TinyBuddy` | SwiftUI HUD、授权流、刷新协调、生命周期 | Core |
| `TinyBuddyWidgetExtension` | WidgetKit 展示 | Core |
| Release CLI 工具 | 安装/验证 | Core（Verifier） |

### 3. Git 活动追踪

- 通过 reflog 解析（非 git log）获取今日提交、专注块数、最近项目
- 使用安全域书签（Security-scoped bookmark）访问用户仓库
- 去重逻辑：规范化的通用 Git 目录作为仓库标识
- 错误隔离：单个仓库失败不影响其他仓库的有效数据
- 指纹缓存：内容校验的 reflog 指纹，无变更时跳过

### 4. 发布管道

`release-acceptance` 是终端发布门禁：
1. `swift test` 全量测试
2. 构建 Release 候选包
3. 本地签名（Widget → App）
4. 原子安装 + 同版本重装
5. 运行时验证（进程路径 + 哈希 + Widget 注册）

每个阶段有独立日志和原子状态记录，内核锁保护安装目录。

## 构建与测试命令

```bash
# 基础
swift build                           # SPM 构建
swift test                            # 全量测试

# 脚本入口
./script/build_and_run.sh             # Debug 构建 + 启动
./script/build_and_run.sh --verify    # 构建 + 启动 + 验证
./script/build_and_run.sh --logs      # 启动并流式日志
./script/build_and_run.sh release-acceptance  # 完整发布门禁
./script/build_and_run.sh release-verify      # 验证已安装的签名包
./script/build_and_run.sh release-install     # 仅安装步骤

# Xcode
xcodegen generate                     # 从 project.yml 重生成 .xcodeproj
```

### 快速验证路径

| 变更范围 | 最小验证命令 |
|---|---|
| 核心逻辑 | `swift test --filter TinyBuddyCoreTests` |
| 刷新协调 | `swift test --filter GitActivityRefreshCoordinatorTests` |
| Git 脚本/真实仓库 | `swift test --filter 'GitActivity(RefreshScript\|RealRepositoryFixture)Tests'` |
| 构建/签名 | `./script/build_and_run.sh release-verify` |
| Git 刷新性能 | `./script/benchmark_git_refresh.sh` |
| Shell 脚本语法 | `bash -n script/update_git_completion_count.sh` |

## 约定

- **Swift 版本**: 语言模式 Swift 6，工具链 Swift 5.9，macOS 14
- **代码风格**: 4 空格、UpperCamelCase 类型、lowerCamelCase 方法/属性
- **测试**: XCTest，`Tests.swift` 后缀，`test` 前缀方法，确定性依赖
- **Xcode 项目**: `project.yml` 是唯一权威来源，变更后运行 `xcodegen generate`
- **Bundle ID**: `com.ryukeili.TinyBuddy`（App）、`com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension`（Widget）
- **App Group**: `group.com.ryukeili.TinyBuddy`
- **Team ID**: `JYL9G28DP3`
- **沙箱**: 启用 App Sandbox，安全域书签，用户选择文件只读

## 安全与配置

- 不要提交 `.env`、密钥、证书、provisioning profile、仓库路径
- 不要泄露未脱敏的诊断信息
- 发布脚本依赖系统工具链（Bash 3.2+、codesign、security、pluginkit 等）
- 签名变更必须同步 `project.yml`、Info.plist、entitlements、验证脚本

## 修改准则

1. **触及哪个层就在哪个层改**：业务逻辑在 Core、UI 在 App、Widget 数据在 Widget，不要跨层重复
2. **快照完整性优先**：修改 Git 活动逻辑时必须确保 `partial` 行为、缓存失效、去重正确
3. **回归门禁**：影响 Git/快照/签名/Widget 的行为，必须跑对应的 verification 模式
4. **最小 diff**：不引入无关重构、格式化扫荡、依赖升级

更多详细指南见 `AGENTS.md`。
