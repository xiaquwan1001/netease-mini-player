import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_list_page.dart';

rust.UserItemDto user(int id, String name, {bool followed = false}) =>
    rust.UserItemDto(
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
    await tester.pumpWidget(host(UserListView(
      uid: BigInt.zero,
      loadFollows: (uid, limit, offset) async => [user(1, '关注A', followed: true)],
      loadFolloweds: (uid, limit, offset) async => [user(2, '粉丝B')],
      setFollow: (uid, follow) async {
        calls.add('$uid:$follow');
        return true;
      },
    )));
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
    await tester.pumpWidget(host(UserListView(
      uid: BigInt.zero,
      loadFollows: (uid, limit, offset) async => const [],
      loadFolloweds: (uid, limit, offset) async => const [],
      setFollow: (uid, follow) async => true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('还没有关注任何人'), findsOneWidget);
  });
}
