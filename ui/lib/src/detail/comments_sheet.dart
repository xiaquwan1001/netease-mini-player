import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_sheet.dart';
import '../comment_thread.dart';
import '../sheet_header.dart';

/// 评论底部面板(歌曲/歌单/专辑/播客通用): "..." 菜单里的"查看评论"走这里
///
/// [shareSourceTitle] / [shareSourceKind]: 评论被长按分享成图片时的语境
/// (用户反馈 10: 卡片只有用户+评论内容, 看不出这条评论来自哪首歌/专辑/播客/歌单)。
/// 不传时按 [kind] 给一个类型词, 标题留空(卡片只写「来自歌曲」)。
Future<void> showCommentsSheet(
  BuildContext context, {
  required String kind,
  required BigInt resourceId,
  String title = '评论',
  int totalHint = 0,
  String shareSourceTitle = '',
  String? shareSourceKind,

  // 测试注入(不传走 rust), 与 CommentThread 的可选 hook 一一对应
  CommentPageLoader? loadPage,
  CommentLikeHook? like,
  CommentRepliesLoader? loadReplies,
  CommentSendHook? send,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      // 键盘避让: 根节点按 viewInsets.bottom 抬升, 同时把面板高度压掉同样的量,
      // 保证输入框可见、列表可滚、收起键盘后高度回弹(不留白)。
      final insets = MediaQuery.of(sheetContext).viewInsets.bottom;
      final height = math.max(
        200.0,
        MediaQuery.of(sheetContext).size.height * 0.75 - insets,
      );
      return Padding(
        key: const ValueKey('b2-sheet-root'),
        padding: EdgeInsets.only(bottom: insets),
        child: SafeArea(
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                SheetHeader(
                  title: title,
                  onClose: () => Navigator.pop(sheetContext),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: CommentThread(
                      kind: kind,
                      resourceId: resourceId,
                      totalHint: totalHint,
                      loadPage: loadPage,
                      like: like,
                      loadReplies: loadReplies,
                      send: send,
                      shareSourceTitle: shareSourceTitle,
                      shareSourceKind:
                          shareSourceKind ?? commentSourceKindLabel(kind),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

// ---------------- 歌单详情 ----------------
