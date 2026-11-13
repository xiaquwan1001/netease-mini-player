import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// 动态流列表行交互回归: 点赞(乐观/回滚) + 评论直达 + 分享面板 + 窄屏溢出.

rust.FeedEventDto event({
  int id = 1,
  int userId = 10,
  String userName = '艺人',
  String text = '正文',
  String threadId = 'A_EV_2_1_10',
  bool liked = false,
  int likedCount = 0,
  int commentCount = 0,
  int shareCount = 0,
}) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: threadId,
  userId: BigInt.from(userId),
  kind: 'text',
  userName: userName,
  text: text,
  images: const [],
  title: '',
  timeMs: BigInt.from(1700000000000),
  liked: liked,
  likedCount: BigInt.from(likedCount),
  shareCount: BigInt.from(shareCount),
  commentCount: BigInt.from(commentCount),
);

/// FFI 替身: 记录调用, 可注入失败
class _Hooks {
  final likeCalls = <Map<String, Object>>[];
  final forwardCalls = <Map<String, Object>>[];
  Object? likeError;

  Future<bool> like({required String threadId, required bool liked}) async {
    likeCalls.add({'threadId': threadId, 'liked': liked});
    if (likeError != null) throw likeError!;
    return true;
  }

  Future<bool> forward({
    required BigInt eventId,
    required BigInt userId,
    required String msg,
  }) async {
    forwardCalls.add({'eventId': eventId, 'userId': userId, 'msg': msg});
    return true;
  }
}

Future<void> _pumpFeed(
  WidgetTester tester, {
  required List<rust.FeedEventDto> events,
  required _Hooks hooks,
  double textScale = 1.0,
}) async {
  Widget child = MaterialApp(
    home: Scaffold(
      body: FeedView(
        loggedIn: true,
        onLogin: () {},
        onPlaySongs: (_, _) {},
        onOpenUrl: (_) async {},
        loadFeed: () async => events,
        loadSubscribedArtists: () async => const [],
        likeEvent: hooks.like,
        forwardEvent: hooks.forward,
      ),
    ),
  );
  if (textScale != 1.0) {
    child = MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: child,
    );
  }
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列表行点赞: FFI 调一次(threadId+取反), 图标数字乐观翻转', (tester) async {
    final hooks = _Hooks();
    await _pumpFeed(tester, events: [event(likedCount: 5)], hooks: hooks);

    expect(find.byIcon(Icons.favorite), findsNothing);
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();

    expect(hooks.likeCalls, hasLength(1));
    expect(hooks.likeCalls.single['threadId'], 'A_EV_2_1_10');
    expect(hooks.likeCalls.single['liked'], isTrue);
    // 乐观更新: 图标实心 + 数字 +1
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('列表行点赞失败: 回滚图标与数字并提示', (tester) async {
    final hooks = _Hooks()..likeError = Exception('boom');
    await _pumpFeed(tester, events: [event(likedCount: 5)], hooks: hooks);

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();

    expect(hooks.likeCalls, hasLength(1));
    // 回滚: 回到空心 + 原数字, snackbar 提示
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(find.text('5'), findsOneWidget);
    expect(find.textContaining('点赞失败'), findsOneWidget);
  });

  testWidgets('列表行点赞: 无 threadId 的动态只提示不调 FFI', (tester) async {
    final hooks = _Hooks();
    await _pumpFeed(
      tester,
      events: [event(threadId: '')],
      hooks: hooks,
    );

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();

    expect(hooks.likeCalls, isEmpty);
    expect(find.text('这条动态不支持点赞'), findsOneWidget);
  });

  testWidgets('点评论: 进详情页并直接滚到评论区, 不弹写评论面板', (tester) async {
    final hooks = _Hooks();
    // 正文足够长, 让评论区初始时在首屏之下
    final longText = '一段很长的动态正文用于评论定位测试。' * 200;
    await _pumpFeed(
      tester,
      events: [event(text: longText, commentCount: 12)],
      hooks: hooks,
    );

    await tester.tap(find.byIcon(Icons.mode_comment_outlined));
    // 分步推进路由转场(评论区加载失败会有重试定时器, 不用 pumpAndSettle)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 100));

    // 详情页已打开(AppBar '动态' 唯一 —— 列表卡片在路由栈下但无 AppBar)
    expect(find.byType(CommentThread), findsOneWidget);
    // 只滚动定位, 不自动弹写评论面板
    expect(find.text('写评论'), findsNothing);
    // 评论区已滚进视口(锚点 ensureVisible 生效)
    // 评论区在内容末尾: "定位评论区" = 滚到评论区(顶部对齐;
    // 剩余不足一屏时 clamp 到底部)。测试环境评论加载失败只剩错误框,
    // 断言两层: 详情页确实滚动了(到内容末尾) + 评论区在视口内。
    final scroller = find.byType(SingleChildScrollView);
    expect(scroller, findsOneWidget);
    final scrollableState = tester.state<ScrollableState>(
      find.descendant(of: scroller, matching: find.byType(Scrollable)).first,
    );
    final position = scrollableState.position;
    expect(position.pixels, greaterThan(0), reason: '必须发生过滚动');
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 10),
      reason: '评论区即内容末尾, 应滚到底部(允许加载后布局微调)',
    );
    final rect = tester.getRect(find.byType(CommentThread));
    expect(rect.top, lessThan(600), reason: '评论区应可见, 实际 $rect');
    expect(rect.bottom, greaterThan(0), reason: '评论区应可见, 实际 $rect');
  });

  testWidgets('分享面板: 可打开, 复制链接写入剪贴板', (tester) async {
    final hooks = _Hooks();
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await _pumpFeed(tester, events: [event(shareCount: 7)], hooks: hooks);

    await tester.tap(find.byIcon(Icons.autorenew));
    await tester.pumpAndSettle();
    // 面板两项动作都在
    expect(find.text('转发动态'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);

    await tester.tap(find.text('复制链接'));
    await tester.pumpAndSettle();
    expect(clipboardText, 'https://music.163.com/#/event?id=1');
    expect(find.text('链接已复制'), findsOneWidget);
    // 走的不是转发 FFI
    expect(hooks.forwardCalls, isEmpty);
  });

  testWidgets('分享面板: 转发动态 → 弹转发语框 → forwardEvent 调一次', (tester) async {
    final hooks = _Hooks();
    await _pumpFeed(tester, events: [event()], hooks: hooks);

    await tester.tap(find.byIcon(Icons.autorenew));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转发动态'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '帮顶');
    await tester.tap(find.text('转发'));
    await tester.pumpAndSettle();

    expect(hooks.forwardCalls, hasLength(1));
    expect(hooks.forwardCalls.single['eventId'], BigInt.one);
    expect(hooks.forwardCalls.single['userId'], BigInt.from(10));
    expect(hooks.forwardCalls.single['msg'], '帮顶');
    expect(find.text('已转发'), findsOneWidget);
  });

  testWidgets('300dp+1.25: 操作行(点赞/评论/分享/查看详情)不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hooks = _Hooks();
    await _pumpFeed(
      tester,
      events: [
        event(
          userName: '一个名字特别特别长的艺人用户名用于小屏回归测试',
          text: '一条很长很长很长很长很长很长很长很长很长很长的动态正文用于小屏回归测试' * 3,
          likedCount: 1234,
          commentCount: 567,
          shareCount: 89,
        ),
      ],
      hooks: hooks,
      textScale: 1.25,
    );
    expect(tester.takeException(), isNull);

    // 点赞后也不溢出
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('1235'), findsOneWidget);

    // 分享面板在窄屏也不溢出
    await tester.tap(find.byIcon(Icons.autorenew));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('复制链接'), findsOneWidget);
  });
}
