part of 'comment_thread.dart';

typedef CommentPageLoader = Future<rust.CommentPage> Function(
  int limit,
  int offset,
);
typedef CommentLikeHook = Future<bool> Function(BigInt commentId, bool liked);
typedef CommentRepliesLoader = Future<rust.CommentPage> Function(
  BigInt parentId,
  int limit,
);
typedef CommentReplyHook = Future<bool> Function(
  BigInt commentId,
  String content,
);
typedef CommentDeleteHook = Future<bool> Function(BigInt commentId);

/// 发表顶层评论: 完全复用 [CommentReplyHook] 的形态 —— commentId 传
/// [BigInt.zero] 表示"评论整个资源"(网易云 comment_reply 接口 commentId=0 即顶层评论),
/// 所以这条链路不需要新增任何 FFI。
typedef CommentSendHook = CommentReplyHook;
