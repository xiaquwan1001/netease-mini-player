// 桌面端登录弹层(官方扫码通道)的回归.
//
// 之前桌面端只能 `ncm login-cookie`, 点「登录」直接抛 UnsupportedError.
// 现在走官方网页登录的扫码通道: 申请 key → 轮询 → 803 时凭据已在 Rust 侧落盘.
// 这里用注入的假实现覆盖状态机, 不联网、不碰 FFI.
//
// 注意: 弹层里有 Timer.periodic, **不要用 pumpAndSettle**(它会被周期定时器拖住),
// 一律用显式 pump(时长) 推进.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/login_sheet.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.QrLoginKey key() => rust.QrLoginKey(
      key: 'k-1',
      url: 'https://music.163.com/login?codekey=k-1',
      expiresIn: BigInt.from(180),
    );

rust.QrLoginCheck check(rust.QrLoginState state, {int code = 801}) =>
    rust.QrLoginCheck(
      state: state,
      code: code,
      cookie: null,
      nickname: '',
      avatarUrl: null,
    );

/// 弹层比默认 800x600 高(二维码 200 + 说明 + 按钮), 先放大画布.
Future<void> bigSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// 打开弹层.
///
/// [animate] 是"等底栏滑入动画"的时长: 需要点击控件时必须 >=300ms(否则控件还在屏幕外),
/// 但那段时长也会顺带推进轮询定时器 —— 要精确数轮询次数的用例传 Duration.zero.
Future<void> openSheet(
  WidgetTester tester, {
  Duration animate = const Duration(milliseconds: 350),
}) async {
  await tester.tap(find.text('open'));
  await tester.pump(); // 建弹层 + 触发 createQr
  await tester.pump(); // createQr future 完成
  if (animate != Duration.zero) await tester.pump(animate);
  await tester.pump();
}

Widget host(void Function(BuildContext ctx) onOpen) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => onOpen(ctx),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('扫码: 待扫 → 已扫 → 确认, 弹层关闭并回调宿主', (tester) async {
    await bigSurface(tester);
    var loggedIn = 0;
    final states = <rust.QrLoginCheck>[
      check(rust.QrLoginState.pending),
      check(rust.QrLoginState.scanned, code: 802),
      check(rust.QrLoginState.confirmed, code: 803),
    ];
    var calls = 0;
    bool? result;

    await tester.pumpWidget(host((ctx) async {
      result = await showLoginSheet(
        ctx,
        createQr: () async => key(),
        checkQr: (_) async {
          final i = calls < states.length - 1 ? calls : states.length - 1;
          calls++;
          return states[i];
        },
        onLoggedIn: () async => loggedIn++,
        pollInterval: const Duration(milliseconds: 100),
      );
    }));
    // 不推进动画(否则 300ms 里会连着跑掉好几次轮询)
    await openSheet(tester, animate: Duration.zero);
    expect(find.text('等待扫码…'), findsOneWidget);

    // 第一次轮询: pending
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('等待扫码…'), findsOneWidget);

    // 第二次轮询: 已扫码
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('已扫码, 请在手机上点「确认登录」'), findsOneWidget);

    // 第三次轮询: 确认 → 关闭 + 回调
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350)); // 关闭动画
    expect(loggedIn, 1);
    expect(result, isTrue);
    expect(find.text('等待扫码…'), findsNothing);
  });

  testWidgets('二维码过期: 停轮询并提示刷新', (tester) async {
    await bigSurface(tester);
    var calls = 0;
    await tester.pumpWidget(host((ctx) {
      showLoginSheet(
        ctx,
        createQr: () async => key(),
        checkQr: (_) async {
          calls++;
          return check(rust.QrLoginState.expired, code: 800);
        },
        pollInterval: const Duration(milliseconds: 100),
      );
    }));
    await openSheet(tester);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('二维码已过期, 点「刷新二维码」重来'), findsOneWidget);

    // 定时器已停: 再等也不会再打接口
    final afterExpire = calls;
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, afterExpire);

    // 刷新二维码: 重新申请并恢复轮询
    await tester.tap(find.text('刷新二维码'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(calls, greaterThan(afterExpire));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('导入 Cookie: 成功后关闭并回调', (tester) async {
    await bigSurface(tester);
    var committed = '';
    var loggedIn = 0;
    bool? result;
    await tester.pumpWidget(host((ctx) async {
      result = await showLoginSheet(
        ctx,
        createQr: () async => key(),
        checkQr: (_) async => check(rust.QrLoginState.pending),
        commitCookie: (cookie) async {
          committed = cookie;
          return true;
        },
        onLoggedIn: () async => loggedIn++,
        pollInterval: const Duration(milliseconds: 100),
      );
    }));
    await openSheet(tester);

    await tester.tap(find.text('导入 Cookie'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.enterText(find.byType(TextField), 'MUSIC_U=abc; __csrf=def');
    await tester.tap(find.text('导入并登录'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 350)); // 关闭动画

    expect(committed, 'MUSIC_U=abc; __csrf=def');
    expect(loggedIn, 1);
    expect(result, isTrue);
  });

  testWidgets('导入 Cookie: 没有 MUSIC_U 时报错且不关闭', (tester) async {
    await bigSurface(tester);
    await tester.pumpWidget(host((ctx) {
      showLoginSheet(
        ctx,
        createQr: () async => key(),
        checkQr: (_) async => check(rust.QrLoginState.pending),
        commitCookie: (_) async => false,
        pollInterval: const Duration(milliseconds: 100),
      );
    }));
    await openSheet(tester);

    await tester.tap(find.text('导入 Cookie'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.enterText(find.byType(TextField), 'foo=bar');
    await tester.tap(find.text('导入并登录'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('cookie 里没有 MUSIC_U, 登录未生效'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('导入 Cookie: 空输入直接提示', (tester) async {
    await bigSurface(tester);
    var called = 0;
    await tester.pumpWidget(host((ctx) {
      showLoginSheet(
        ctx,
        createQr: () async => key(),
        checkQr: (_) async => check(rust.QrLoginState.pending),
        commitCookie: (_) async {
          called++;
          return true;
        },
        pollInterval: const Duration(milliseconds: 100),
      );
    }));
    await openSheet(tester);
    await tester.tap(find.text('导入 Cookie'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('导入并登录'));
    await tester.pump();
    expect(called, 0);
    expect(find.text('先粘贴 cookie(MUSIC_U=...)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('申请二维码失败: 给出错误并能重试', (tester) async {
    await bigSurface(tester);
    var attempts = 0;
    await tester.pumpWidget(host((ctx) {
      showLoginSheet(
        ctx,
        createQr: () async {
          attempts++;
          if (attempts == 1) throw Exception('[network] boom');
          return key();
        },
        checkQr: (_) async => check(rust.QrLoginState.pending),
        pollInterval: const Duration(milliseconds: 100),
      );
    }));
    await openSheet(tester);
    expect(find.textContaining('申请二维码失败'), findsOneWidget);

    await tester.tap(find.text('刷新二维码'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox());
  });
}
