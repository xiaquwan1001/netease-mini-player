/// 消息中心各页签共用的小件: 相对时间文案.
///
/// 页签的错误行原先在这里另写了一份 `MessageErrorRow`, 与 `error_views.InlineError`
/// 同构; 四态收口到 AsyncView 后统一用 `InlineError` 表达, 那份实现已删除。
///
/// 相对时间本身也只有一份实现(在 `format.dart`), 这里只是消息页的入口名 ——
/// 页签原先 import 的是本文件, 保留 re-export 免得它们为了改名而改 import。
library;

export '../format.dart' show relativeTime;
