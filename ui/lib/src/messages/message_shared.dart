/// 消息中心各页签共用的小件: 相对时间文案.
///
/// 页签的错误行原先在这里另写了一份 `MessageErrorRow`, 与 `error_views.InlineError`
/// 同构; 四态收口到 AsyncView 后统一用 `InlineError` 表达, 那份实现已删除。
library;

/// 相对时间: 刚刚/n 分钟前/n 小时前/n 天前/日期
String relativeTime(BigInt timeMs) {
  if (timeMs <= BigInt.zero) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(timeMs.toInt());
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}
