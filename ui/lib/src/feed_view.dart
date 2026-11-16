/// 关注动态流的公开入口(实现拆在 src/feed/ 下).
///
/// 对外符号不变: [FeedView] / [FeedPageLoader] / [mergeFeedEvents],
/// 现有 `import 'feed_view.dart'` 零改动。
library;

export 'feed/feed_view_body.dart';
