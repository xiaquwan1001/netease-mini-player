import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/profile_header.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.ProfileDetail detail({
  int follows = 10,
  int fans = 20,
  String nickname = '小明',
  String signature = '签名',
}) =>
    rust.ProfileDetail(
      userId: BigInt.one,
      nickname: nickname,
      avatarUrl: null,
      backgroundUrl: null,
      signature: signature,
      vip: false,
      follows: BigInt.from(follows),
      followeds: BigInt.from(fans),
      level: BigInt.from(8),
    );

Widget host({
  rust.ProfileDetail? detail,
  bool loggedIn = true,
  Future<rust.ProfileDetail?> Function()? loadDetail,
  Key? headerKey,
}) =>
    MaterialApp(
      home: Scaffold(
        body: ProfileHeader(
          key: headerKey,
          detail: detail,
          fallbackNickname: '我的账号',
          loggedIn: loggedIn,
          loadDetail: loadDetail,
        ),
      ),
    );

void main() {
  testWidgets('refreshCounts: mock loader 返回新数据, 关注/粉丝数字即时更新', (
    tester,
  ) async {
    final key = GlobalKey<ProfileHeaderState>();
    await tester.pumpWidget(host(
      headerKey: key,
      detail: detail(follows: 10, fans: 20),
      loadDetail: () async => detail(follows: 11, fans: 21),
    ));
    expect(find.text('关注 10'), findsOneWidget);
    expect(find.text('粉丝 20'), findsOneWidget);

    final ok = await key.currentState!.refreshCounts();
    await tester.pump();

    expect(ok, isTrue);
    expect(find.text('关注 11'), findsOneWidget);
    expect(find.text('粉丝 21'), findsOneWidget);
    expect(find.text('关注 10'), findsNothing);
  });

  testWidgets('refreshCounts: loader 抛错返回 false, 保留旧数字不崩', (tester) async {
    final key = GlobalKey<ProfileHeaderState>();
    await tester.pumpWidget(host(
      headerKey: key,
      detail: detail(follows: 10, fans: 20),
      loadDetail: () async => throw Exception('网络挂了'),
    ));

    final ok = await key.currentState!.refreshCounts();
    await tester.pump();

    expect(ok, isFalse);
    expect(find.text('关注 10'), findsOneWidget);
    expect(find.text('粉丝 20'), findsOneWidget);
  });

  testWidgets('未登录时 refreshCounts 不触发 loader', (tester) async {
    final key = GlobalKey<ProfileHeaderState>();
    var calls = 0;
    await tester.pumpWidget(host(
      headerKey: key,
      loggedIn: false,
      loadDetail: () async {
        calls++;
        return detail();
      },
    ));

    final ok = await key.currentState!.refreshCounts();

    expect(ok, isFalse);
    expect(calls, 0);
  });

  testWidgets('父层传入新 detail 时以父层为准(didUpdateWidget)', (tester) async {
    final key = GlobalKey<ProfileHeaderState>();
    await tester.pumpWidget(host(headerKey: key, detail: detail(follows: 10)));
    await tester.pumpWidget(host(headerKey: key, detail: detail(follows: 30)));

    expect(find.text('关注 30'), findsOneWidget);
  });

  testWidgets('300dp 窄屏 + 1.25 字号 + 长昵称长签名不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: Scaffold(
        body: ProfileHeader(
          detail: detail(
            nickname: '这是一个特别特别特别长的昵称用来挤窄屏空间',
            signature: '这是一段同样特别特别特别长的个性签名, 验证窄屏大字号下省略号正常不溢出',
          ),
          fallbackNickname: '我的账号',
          loggedIn: true,
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('特别特别特别长的昵称'), findsOneWidget);
  });
}
