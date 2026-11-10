// 隐私回归: 未登录时账号页不能把"上一次登录留下的昵称/会员标"当成当前账号展示.
//
// 2026-11-10 用户报: 装好的 deb、没登录的情况下, 空账号的占位显示成上次登录的
// 昵称 + VIP 标. 根因是账号簿(accounts.json)里的缓存被无脑渲染, 且会员标只看
// active 不看登录态. 这组用例锁死两个不变量:
//   1) 未登录: 头部一定是「未登录」, 且**没有任何 VIP 标**;
//   2) 账号簿仍可展示昵称(它就是一本地址簿), 但要标明「当前未登录」.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/settings_account_page.dart';

rust.InitInfo info({required bool loggedIn}) => rust.InitInfo(
      dataDir: '/tmp/minincm',
      deviceId: 'dev-1',
      loggedIn: loggedIn,
      vip: false,
      providers: const [],
    );

rust.AccountDto account(
  int id,
  String nickname, {
  bool active = false,
  bool vip = true,
}) =>
    rust.AccountDto(
      userId: BigInt.from(id),
      nickname: nickname,
      active: active,
      vip: vip,
    );

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('未登录: 账号簿里的昵称/会员标不得冒充当前账号', (tester) async {
    await tester.pumpWidget(host(AccountPage(
      info: info(loggedIn: false),
      isAndroid: false,
      onLogin: () {},
      onLogout: () async {},
      loadAccounts: () async => [account(1822714196, '下去玩', active: true)],
    )));
    await tester.pumpAndSettle();

    // 头部: 未登录
    expect(find.text('未登录'), findsOneWidget);
    // 账号簿里仍能看到那个账号(它就是一本地址簿), 但标成"上次登录"
    expect(find.text('下去玩'), findsOneWidget);
    expect(find.text('上次登录的账号(当前未登录)'), findsOneWidget);
    // 关键断言: 一个 VIP 标都不许有
    expect(find.text('VIP'), findsNothing);
    // 未登录必须给出登录入口(桌面端以前这里是空的, 只能去命令行导 cookie)
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
  });

  testWidgets('已登录: 当前账号才显示 VIP 标', (tester) async {
    await tester.pumpWidget(host(AccountPage(
      info: info(loggedIn: true),
      isAndroid: false,
      onLogin: () {},
      onLogout: () async {},
      loadAccounts: () async => [account(1, '小明', active: true)],
    )));
    await tester.pumpAndSettle();

    // 头部与账号簿行都会显示昵称
    expect(find.text('小明'), findsNWidgets(2));
    // 头部 + 账号簿行: 2 个 VIP 标
    expect(find.text('VIP'), findsNWidgets(2));
  });

  testWidgets('账号簿为空时没有"清除本机凭据"入口', (tester) async {
    await tester.pumpWidget(host(AccountPage(
      info: info(loggedIn: false),
      isAndroid: false,
      onLogin: () {},
      onLogout: () async {},
      loadAccounts: () async => const [],
    )));
    await tester.pumpAndSettle();
    expect(find.text('清除本机登录凭据'), findsNothing);
  });

  testWidgets('清除本机凭据: 二次确认后才调用回调', (tester) async {
    var purged = 0;
    await tester.pumpWidget(host(AccountPage(
      info: info(loggedIn: true),
      isAndroid: false,
      onLogin: () {},
      onLogout: () async {},
      loadAccounts: () async => [account(1, '小明', active: true)],
      onPurgeLocal: () async => purged++,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('清除本机登录凭据'));
    await tester.pumpAndSettle();
    expect(find.text('清除本机登录凭据?'), findsOneWidget);

    // 取消: 不执行
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(purged, 0);

    await tester.tap(find.text('清除本机登录凭据'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清除'));
    await tester.pumpAndSettle();
    expect(purged, 1);
  });
}
