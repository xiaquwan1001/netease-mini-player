import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/feed_share.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:qr_flutter/qr_flutter.dart';

/// 动态/评论分享面板回归: 预览卡片、水印开关、长按转发、评论长按分享.

rust.FeedEventDto event({
  int id = 1,
  int userId = 10,
  String userName = '艺人甲',
  String text = '今天发了一首新歌',
  String title = '',
  bool liked = false,
  int likedCount = 0,
  int commentCount = 0,
  int shareCount = 0,
}) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_$userId',
  userId: BigInt.from(userId),
  kind: 'text',
  userName: userName,
  text: text,
  title: title,
  images: const [],
  timeMs: BigInt.from(1700000000000),
  liked: liked,
  likedCount: BigInt.from(likedCount),
  shareCount: BigInt.from(shareCount),
  commentCount: BigInt.from(commentCount),
);

rust.Comment comment({
  int id = 1,
  String userName = '用户甲',
  String content = '这条动态真好听',
}) => rust.Comment(
  id: BigInt.from(id),
  userId: BigInt.from(100 + id),
  userName: userName,
  avatarUrl: null,
  content: content,
  timeMs: BigInt.from(1700000000000),
  likedCount: BigInt.zero,
  liked: false,
  replyCount: BigInt.zero,
  ipLocation: '',
  hot: false,
  parentId: BigInt.zero,
);

/// 转发 FFI 替身: 记录调用(不触网)
class _ForwardHooks {
  final calls = <Map<String, Object>>[];

  Future<bool> forward({
    required BigInt eventId,
    required BigInt userId,
    required String msg,
  }) async {
    calls.add({'eventId': eventId, 'userId': userId, 'msg': msg});
    return true;
  }
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 记录 Clipboard.setData 的文本(平台通道走 mock, 不碰真 IO)
String? trackClipboard(WidgetTester tester) {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
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
  // 返回 getter 语义: 用闭包包装, 每次读到最新的值
  _clipboardGetter = () => copied;
  return copied;
}

String? Function() _clipboardGetter = () => null;

void main() {
  test('二维码内容指向官方动态页', () {
    expect(
      feedShareUrl(BigInt.from(42)),
      'https://music.163.com/#/event?id=42',
    );
  });

  test('复制评论文本: 作者 + 正文 + 原动态标题', () {
    expect(commentShareText(author: '用户甲', content: '真好听'), '用户甲：真好听');
    expect(
      commentShareText(author: '用户甲', content: '真好听', sourceTitle: '新歌上线'),
      '用户甲：真好听\n—— 来自动态《新歌上线》',
    );
  });

  test('分享文件名: 非法字符替换为下划线', () {
    expect(sharePngFilename('动态/艺人:甲'), '动态_艺人_甲.png');
    expect(sharePngFilename('  '), 'share.png');
  });

  testWidgets('分享面板: 预览卡片 + 水印默认关 + 开关画进卡片', (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showFeedShareSheet(context, event: event()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('分享动态'), findsOneWidget);
    expect(find.byType(FeedShareCard), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('艺人甲'), findsOneWidget);
    expect(find.text('今天发了一首新歌'), findsOneWidget);
    // 水印默认关
    expect(find.text(kShareWatermarkText), findsNothing);

    await tester.tap(find.text('添加应用水印'));
    await tester.pumpAndSettle();
    // 水印必须画在卡片(截图边界)内部, 才能进导出的 PNG
    expect(
      find.descendant(
        of: find.byType(FeedShareCard),
        matching: find.text(kShareWatermarkText),
      ),
      findsOneWidget,
    );

    // 关掉二维码: 卡片里不再有 QR
    await tester.tap(find.text('包含二维码'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    // 水印仍在
    expect(find.text(kShareWatermarkText), findsOneWidget);
  });

  testWidgets('分享面板: 复制链接写入剪贴板', (tester) async {
    trackClipboard(tester);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  showFeedShareSheet(context, event: event(id: 42)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制链接'));
    await tester.pumpAndSettle();
    expect(_clipboardGetter(), 'https://music.163.com/#/event?id=42');
  });

  testWidgets('分享面板: 选「转发动态」进入转发面板', (tester) async {
    final hooks = _ForwardHooks();
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showFeedShareSheet(
                context,
                event: event(),
                forwardEvent: hooks.forward,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转发动态'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedForwardSheet), findsOneWidget);
    expect(find.text('说点什么(可留空)'), findsOneWidget);
  });

  testWidgets('长按动态直接打开转发面板, 转发语可空并走 forwardEvent', (tester) async {
    final hooks = _ForwardHooks();
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [event(id: 7, userId: 70)],
          loadSubscribedArtists: () async => const [],
          forwardEvent: hooks.forward,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('今天发了一首新歌'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedForwardSheet), findsOneWidget);
    // 原动态预览(卡片里也有昵称/正文) + 转发语输入框
    expect(find.byType(FeedShareCard), findsOneWidget);
    expect(find.text('说点什么(可留空)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '好听');
    await tester.tap(find.widgetWithText(FilledButton, '转发'));
    await tester.pumpAndSettle();

    expect(hooks.calls.length, 1);
    expect(hooks.calls.first['msg'], '好听');
    expect(hooks.calls.first['eventId'], BigInt.from(7));
    expect(hooks.calls.first['userId'], BigInt.from(70));
  });

  testWidgets('长按评论打开评论分享面板, 复制评论带原动态出处', (tester) async {
    trackClipboard(tester);
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          shareSourceTitle: '新歌上线',
          loadPage: (limit, offset) async => rust.CommentPage(
            threadId: 'R_SO_4_1',
            comments: [comment()],
            total: BigInt.one,
            hasMore: false,
          ),
          like: (_, _) async => true,
          loadReplies: (_, _) async => rust.CommentPage(
            threadId: 'R_SO_4_1',
            comments: const [],
            total: BigInt.zero,
            hasMore: false,
          ),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('这条动态真好听'));
    await tester.pumpAndSettle();

    expect(find.byType(CommentShareSheet), findsOneWidget);
    expect(find.text('分享评论'), findsOneWidget);
    expect(find.byType(CommentShareCard), findsOneWidget);
    expect(find.text('来自动态《新歌上线》'), findsOneWidget);

    await tester.tap(find.text('复制评论'));
    await tester.pumpAndSettle();
    expect(_clipboardGetter(), '用户甲：这条动态真好听\n—— 来自动态《新歌上线》');
  });

  testWidgets('300dp + 1.25 字号: 分享面板与水印不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: host(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showFeedShareSheet(context, event: event()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(FeedShareCard), findsOneWidget);

    // 水印打开后再看一遍(多一行文字也不能溢出)
    await tester.tap(find.text('添加应用水印'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(kShareWatermarkText), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号: 评论分享卡片不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: host(
          Center(
            child: CommentShareCard(
              comment: comment(content: '这条动态真好听, 循环了一整天'),
              sourceTitle: '新歌上线后的第一条动态',
              width: 276,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('来自动态《新歌上线后的第一条动态》'), findsOneWidget);
  });
}
