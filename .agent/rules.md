# TinyBuddy Agent Rules

这些规则约束所有执行 Maintenance Loop 的智能体。它们与根目录 `AGENTS.md`、`CLAUDE.md` 和用户当前请求一起生效；如有冲突，以用户明确要求和更高优先级的仓库规则为准。

## 必须

- 用户可见输出使用简体中文。
- 代码、命令、路径、标识符和错误原文保持原样，不翻译、不臆造。
- 遵循最小修改原则：只改为验证当前目标所必需的文件和行。
- 尊重现有架构、测试、工具链和项目约定；共享逻辑仍放在 `Sources/TinyBuddyCore/`，App/Widget 保持既有职责边界。
- 先观察后决策，依据真实证据选择一个最高价值、可验证的问题；每次 Loop 只处理一个问题。
- 同一模块可以继续优化，但必须基于新的证据（新失败、新复现、新指标或新用户反馈）；不得重复处理 `.agent/history.md` 与 `.agent/history-archive.md` 中已完成的问题。
- 若没有真实且可验证的高价值问题，允许以无修改轮次结束 Loop；不为了产生修改而修改。
- 不覆盖、回滚或丢弃用户已有修改；遇到重叠改动先保留并重新界定范围。
- 修改后运行适用的测试、构建或静态检查，并在 `.agent/history.md` 记录实际验证结果。
- 维护历史记录时保留最近约 10 条，旧条目原样归档到 `.agent/history-archive.md`；不得删除、改写或截断归档条目。
- 保留错误的可见性和可诊断性；诊断内容遵守仓库现有脱敏要求。
- 需要外部状态变更时先确认授权；默认只在当前仓库范围内读写。

## 禁止

- 隐藏错误、吞掉失败、伪造结果或用未经验证的推断代替证据。
- 修改、削弱或删除测试断言，只为了让测试通过；不得跳过失败测试来报告成功。
- 在没有验证的情况下完成任务或宣称修复。
- 无关重构、批量格式化、扩大任务范围或改变架构方向。
- 新增功能、升级依赖或删除已有行为，除非用户另行明确授权且 Loop 的单一问题确实需要。
- 覆盖用户修改、执行破坏性命令，或读取凭证、私密数据和无关项目。
- 执行 `commit`、`push`、创建 PR、发布或部署；也不得替用户替换已安装 App 或改变外部服务状态。

## 项目验证边界

- Swift 逻辑和测试：优先使用受影响的 `swift test --filter <TestName>`，稳定后按 `AGENTS.md` 要求运行 `swift test`；构建使用 `swift build` 或 `./script/swiftpm.sh build`。
- Xcode 目标、资源、签名或新源文件：以 `project.yml` 为事实来源，必要时运行 `xcodegen generate`；按需使用最小的 `./script/build_and_run.sh` 验证模式。
- Git 刷新脚本：运行 `/bin/bash -n script/update_git_completion_count.sh`，并在行为或性能变化时运行仓库规定的测试/benchmark。
- 仓库没有独立 lint；对所有改动运行 `git diff --check`，并检查 `git status --short` 与最终 diff。
- `release-install`、`release-acceptance`、发布和部署会改变外部状态，除非用户明确授权，否则不执行。
