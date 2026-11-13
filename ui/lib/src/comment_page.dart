import 'package:flutter/material.dart';

import 'comment_thread.dart';

/// 独立评论区页: 从消息中心(评论 / @我)直接跳到对应线程。
///
/// 消息中心以前只读且不可点开; InboxItem 补出 threadId 之后, 这里给一个
/// 最小壳(`CommentThread` 自带回复框), 点消息即可浏览并直接回复。
Future<void> showCommentThreadPage(
  BuildContext context, {
  required String threadId,
  String title = '评论',
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _CommentThreadPage(threadId: threadId, title: title),
    ),
  );
}

class _CommentThreadPage extends StatelessWidget {
  const _CommentThreadPage({required this.threadId, required this.title});

  final String threadId;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      // CommentThread 是 Column(不自带滚动), 外面必须包一个滚动容器
      body: SafeArea(
        child: SingleChildScrollView(
          child: CommentThread(
            threadId: threadId,
            title: title,
            inset: const EdgeInsets.fromLTRB(12, 16, 12, 16),
          ),
        ),
      ),
    );
  }
}
