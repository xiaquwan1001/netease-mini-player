/// 评论线程的公开入口(实现拆在 src/comment/ 下).
///
/// 对外符号不变: [CommentThread] / [CommentThreadState] /
/// [commentSourceKindLabel] 与 loader/hook typedef,
/// 现有 `import 'comment_thread.dart'` 零改动。
library;

export 'comment/comment_thread.dart';
