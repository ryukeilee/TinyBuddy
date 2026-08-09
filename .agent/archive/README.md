# .agent/archive/ — 历史维护记录归档目录

本目录存放 Maintenance Loop 的归档历史记录，由 `.agent/loop.md` 的 Maintain 阶段维护。

## 用途

- 当 `.agent/history.md` 中的轮次记录超过约 10 条时，最旧的条目按原样移入本目录，防止历史文件无限膨胀，同时保证近期上下文在 `history.md` 中立即可读。
- 归档文件命名建议：`history-YYYY-MM-DD.md`（以归档发生的日期命名）；文件头部注明用途与归档时间。
- 归档条目不丢失、不改写、不截断，保持完整可审计。
- 日常 Loop 以 `history.md` 近期记录为准；Observe/Decide 阶段做去重核对时，再读取本目录。

## 目录内文件

- （暂无归档条目；首次归档由 Maintain 阶段按上述规则创建。）
