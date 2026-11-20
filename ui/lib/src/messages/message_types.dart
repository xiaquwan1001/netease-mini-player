import '../rust/api_all.dart' as rust;

/// 消息中心的加载/发送回调类型(页面与注入点共用, 见 main.dart 的接线).

typedef MessageCountsLoader = Future<rust.MessageCountsDto> Function();
typedef SessionsPageLoader = Future<List<rust.PrivateSession>> Function(
  int limit,
  int offset,
);
typedef ContactsLoader = Future<List<rust.RecentContact>> Function();
typedef ForwardsLoader = Future<List<rust.ForwardItem>> Function();
typedef HistoryPageLoader = Future<List<rust.PrivateMessage>> Function(
  BigInt userId,
  int limit,
  BigInt beforeMs,
);
typedef InboxLoader = Future<List<rust.InboxItem>> Function();
typedef PrivateSender = Future<bool> Function(BigInt userId, String content);
