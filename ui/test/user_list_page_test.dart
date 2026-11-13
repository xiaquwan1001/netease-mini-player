import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_list_page.dart';

rust.UserItem user(int id, String name, {bool followed = false}) =>
    rust.UserItem(
      id: BigInt.from(id),
      name: name,
      avatarUrl: null,
      signature: '签名$id',
      followed: followed,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('关注列表可切到粉丝, 关注按钮回调', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      host(
        UserListView(
          uid: BigInt.zero,
          loadFollows: (uid, limit, offset) async => [
            user(1, '关注A', followed: true),
          ],
          loadFolloweds: (uid, limit, offset) async => [user(2, '粉丝B')],
          setFollow: (uid, follow) async {
            calls.add('$uid:$follow');
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关注A'), findsOneWidget);
    expect(find.text('已关注'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '已关注'));
    await tester.pumpAndSettle();
    expect(calls, ['1:false']);
    expect(find.widgetWithText(OutlinedButton, '关注'), findsOneWidget);

    // 切粉丝
    await tester.tap(find.text('粉丝'));
    await tester.pumpAndSettle();
    expect(find.text('粉丝B'), findsOneWidget);
    expect(find.text('关注A'), findsNothing);

    // 粉丝默认为未关注 → 点一下变已关注
    await tester.tap(find.widgetWithText(OutlinedButton, '关注'));
    await tester.pumpAndSettle();
    expect(calls.last, '2:true');
    expect(find.text('已关注'), findsOneWidget);
  });

  testWidgets('空列表占位', (tester) async {
    await tester.pumpWidget(
      host(
        UserListView(
          uid: BigInt.zero,
          loadFollows: (uid, limit, offset) async => const [],
          loadFolloweds: (uid, limit, offset) async => const [],
          setFollow: (uid, follow) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有关注任何人'), findsOneWidget);
    expect(find.textContaining('感兴趣的人'), findsOneWidget);
  });

  testWidgets('首屏失败显示 friendlyError + 重试后成功', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        UserListView(
          uid: BigInt.zero,
          loadFollows: (uid, limit, offset) async {
            attempts++;
            // retryNetwork 会自动重试网络错误 3 次, 第 4 次才放行
            if (attempts <= 3) throw Exception('[network] connection reset');
            return [user(1, '重试后的用户')];
          },
          loadFolloweds: (uid, limit, offset) async => const [],
          setFollow: (uid, follow) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试后的用户'), findsOneWidget);
    expect(attempts, 4);
  });

  testWidgets('300dp + 1.25 字号不溢出(有数据/空态)', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final mq = (
      data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: mq.data,
          child: Scaffold(
            body: UserListView(
              uid: BigInt.zero,
              loadFollows: (uid, limit, offset) async => [
                user(1, '很长很长的昵称用户测试中文溢出场景'),
              ],
              loadFolloweds: (uid, limit, offset) async => const [],
              setFollow: (uid, follow) async => true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 空态(粉丝 tab)
    await tester.tap(find.text('粉丝'));
    await tester.pumpAndSettle();
    expect(find.text('还没有粉丝'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
