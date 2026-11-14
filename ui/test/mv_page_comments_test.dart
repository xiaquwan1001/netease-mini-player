import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/mv_page.dart';
import 'package:minincm/src/mv_playback.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// MV 播放页评论区(需求 10): 看评论 / 点赞 / 发评论, 全部复用 CommentThread
/// (kind: 'mv' → provider 的 comment_mv)。测试全用注入 hook, 不触网络。

class _FakePlayback extends MvPlayback {
  @override
  bool get supportsInlinePlayback => true;
}

rust.MvDetailDto mvDetail() => rust.MvDetailDto(
  id: BigInt.from(5436712),
  name: '主角',
  artistName: '王菲',
  durationMs: BigInt.from(284000),
  playCount: BigInt.from(377308),
  publishTime: '2026-05-07',
  coverUrl: null,
  maxBr: 0,
  brs: Uint32List.fromList(const []),
  desc: null,
);

rust.Comment comment(int id, String content) => rust.Comment(
  id: BigInt.from(id),
  userId: BigInt.from(100 + id),
  userName: '用户$id',
  avatarUrl: null,
  content: content,
  timeMs: BigInt.from(1700000000000),
  likedCount: BigInt.from(2),
  liked: false,
  replyCount: BigInt.zero,
  ipLocation: '',
  hot: false,
  parentId: BigInt.zero,
);

rust.CommentPage page(List<rust.Comment> items) => rust.CommentPage(
  threadId: 'R_MV_5_5436712',
  comments: items,
  total: BigInt.from(items.length),
  hasMore: false,
);

Future<void> pumpMv(
  WidgetTester tester, {
  required Future<rust.CommentPage> Function(int limit, int offset)
  loadComments,
  Future<bool> Function(BigInt commentId, bool liked)? likeComment,
  Future<bool> Function(BigInt commentId, String content)? replyComment,
  bool desktop = false,
}) async {
  tester.view.physicalSize = const Size(420, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MvPage(
        mvId: BigInt.from(5436712),
        name: '主角',
        playback: _FakePlayback(),
        loadDetail: (_) async => mvDetail(),
        loadUrl: (_, _) async => rust.MvUrlDto(
          url: 'http://vod.example.com/a.mp4',
          r: 480,
          size: BigInt.from(1),
        ),
        loadComments: loadComments,
        likeComment: likeComment,
        replyComment: replyComment,
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 评论区在页面下半部: 滚到底把它带进树
  await tester.dragUntilVisible(
    find.byType(CommentThread),
    find.byType(ListView),
    const Offset(0, -200),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('MV 播放页渲染评论区(kind: mv + 第一页评论)', (tester) async {
    final kinds = <String>[];
    await pumpMv(
      tester,
      loadComments: (limit, offset) async {
        kinds.add('$limit/$offset');
        return page([comment(1, '好听'), comment(2, '画面很赞')]);
      },
    );
    expect(find.byType(CommentThread), findsOneWidget);
    final thread = tester.widget<CommentThread>(find.byType(CommentThread));
    expect(thread.kind, 'mv', reason: 'MV 评论走 provider 的 comment_mv 分支');
    expect(thread.resourceId, BigInt.from(5436712));
    expect(kinds, ['10/0']);
    expect(find.text('好听'), findsOneWidget);
    expect(find.text('画面很赞'), findsOneWidget);
    // 播放区仍在(评论区是追加, 不是替换)
    expect(find.textContaining('王菲'), findsOneWidget);
  });

  testWidgets('评论区点赞: 乐观翻转并回调 like hook', (tester) async {
    final liked = <String>[];
    await pumpMv(
      tester,
      loadComments: (_, _) async => page([comment(1, '好听')]),
      likeComment: (id, target) async {
        liked.add('$id:$target');
        return true;
      },
      replyComment: (_, _) async => true,
    );
    // 第一页评论默认 liked=false → 空心
    expect(find.byIcon(Icons.favorite_border), findsWidgets);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pumpAndSettle();
    expect(liked, ['1:true']);
    expect(find.byIcon(Icons.favorite), findsWidgets);
  });

  testWidgets('发表评论: 走 reply hook(顶层评论 commentId=0)并出现在列表', (tester) async {
    final sent = <String>[];
    var calls = 0;
    await pumpMv(
      tester,
      loadComments: (_, _) async {
        calls++;
        // 第二次(发表后静默重载)把新评论带回来
        return page([
          comment(1, '好听'),
          if (calls > 1) comment(9, '第一次看这个 MV'),
        ]);
      },
      likeComment: (_, _) async => true,
      replyComment: (id, content) async {
        sent.add('$id:$content');
        return true;
      },
    );
    await tester.tap(find.text('写评论…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '第一次看这个 MV');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();
    expect(sent, ['0:第一次看这个 MV']);
    expect(find.text('第一次看这个 MV'), findsWidgets);
  });
}
