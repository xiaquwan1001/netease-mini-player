import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/error_views.dart';
import 'package:minincm/src/net_retry.dart';
import 'package:minincm/src/state_views.dart';

/// 错误态视图(error_views.dart)与 friendlyError 文案口径的直接单测.

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('friendlyError kind 前缀映射', () {
    test('network: 换成说人话的文案, 不露 os error / 前缀', () {
      final text = friendlyError(
        Exception(
          '[network] error sending request <- Connection reset by peer (os error 104)',
        ),
      );
      expect(text, contains('网络不稳定'));
      expect(text, isNot(contains('[network]')));
      expect(text, isNot(contains('os error')));
    });

    test('forbidden: 去掉内部前缀, 直接用 detail 当文案', () {
      expect(
        friendlyError(Exception('[forbidden] 该用户已设置关注列表不可见')),
        '该用户已设置关注列表不可见',
      );
    });

    test('forbidden: 无 detail 时给兜底文案', () {
      expect(friendlyError(Exception('[forbidden]')), '没有权限查看');
      expect(friendlyError(Exception('[forbidden]   ')), '没有权限查看');
    });

    test('auth: 原样保留(带前缀方便定位)', () {
      expect(friendlyError(Exception('[auth] 登录已过期')), contains('[auth]'));
      expect(friendlyError(Exception('[auth] 登录已过期')), contains('登录已过期'));
    });

    test('internal: 原样保留(带前缀方便定位)', () {
      const raw = '[internal] code=500';
      expect(friendlyError(Exception(raw)), contains('[internal]'));
      expect(friendlyError(Exception(raw)), contains('code=500'));
    });

    test('无前缀: 原样返回', () {
      expect(friendlyError(Exception('磁盘写入失败')), contains('磁盘写入失败'));
      expect(friendlyError('纯字符串错误'), '纯字符串错误');
    });

    test('风控/无版权等其它 kind 不误判成网络错误', () {
      expect(isNetworkError(Exception('[riskControl] code=8821')), isFalse);
      expect(friendlyError(Exception('[notFound] code=404')), contains('404'));
    });
  });

  group('InlineError', () {
    testWidgets('渲染文案 + 「重试」, 点击回调一次', (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        host(
          Column(
            children: [
              InlineError(
                message: '网络不稳定, 已自动重试仍失败, 请稍后重试',
                onRetry: () => retries += 1,
              ),
            ],
          ),
        ),
      );
      expect(find.text('网络不稳定, 已自动重试仍失败, 请稍后重试'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('是行内形态: 不居中, 文案与按钮在同一行', (tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 320,
            child: InlineError(message: '加载失败', onRetry: () {}),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(InlineError),
          matching: find.byType(Center),
        ),
        findsNothing,
      );
      final message = tester.getCenter(find.text('加载失败'));
      final button = tester.getCenter(find.text('重试'));
      expect(button.dx, greaterThan(message.dx), reason: '重试按钮在文案右侧');
    });

    testWidgets('超长文案不溢出(文案列被 Expanded 收住)', (tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 240,
            child: InlineError(
              message:
                  '[internal] code=500 ${List.filled(20, '很长的错误详情').join()}',
              onRetry: () {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('FullError', () {
    testWidgets('渲染居中文案 + 「重试」主按钮, 点击回调一次', (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        host(FullError(message: '专辑加载失败: 网络不稳定', onRetry: () => retries += 1)),
      );
      expect(find.text('专辑加载失败: 网络不稳定'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('文案居中且留 24 内边距', (tester) async {
      await tester.pumpWidget(
        host(const FullError(message: '加载失败', onRetry: _noop)),
      );
      final text = tester.widget<Text>(find.text('加载失败'));
      expect(text.textAlign, TextAlign.center);
      final padding = tester.widget<Padding>(
        find
            .descendant(
              of: find.byType(FullError),
              matching: find.byType(Padding),
            )
            .first,
      );
      expect(padding.padding, const EdgeInsets.all(24));
    });

    testWidgets('文案可直接来自 friendlyError(隐私类不露前缀)', (tester) async {
      await tester.pumpWidget(
        host(
          FullError(
            message: friendlyError(Exception('[forbidden] 该用户已设置歌单不可见')),
            onRetry: _noop,
          ),
        ),
      );
      expect(find.text('该用户已设置歌单不可见'), findsOneWidget);
      expect(find.textContaining('[forbidden]'), findsNothing);
    });
  });

  group('EmptyView', () {
    testWidgets('标题 / 提示 / 操作按钮都渲染, 按钮可点一次', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          EmptyView(
            icon: Icons.inbox_outlined,
            title: '还没有收藏的歌单',
            hint: '收藏后就会出现在这里',
            action: TextButton(
              onPressed: () => taps += 1,
              child: const Text('去发现'),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.text('还没有收藏的歌单'), findsOneWidget);
      expect(find.text('收藏后就会出现在这里'), findsOneWidget);

      await tester.tap(find.text('去发现'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('没有 hint / action 时不占位(极简空态)', (tester) async {
      await tester.pumpWidget(host(const EmptyView(title: '暂无内容')));
      expect(find.text('暂无内容'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });
  });
}

void _noop() {}
