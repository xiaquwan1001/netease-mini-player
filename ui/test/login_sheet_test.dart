// 桌面端登录弹层(官方扫码通道)的回归.
//
// 之前桌面端只能 `ncm login-cookie`, 点「登录」直接抛 UnsupportedError.
// 现在走官方网页登录的扫码通道: 申请 key → 轮询 → 803 时凭据已在 Rust 侧落盘.
// 这里用注入的假实现覆盖状态机, 不联网、不碰 FFI.
//
// 注意: 弹层里有 Timer.periodic, **不要用 pumpAndSettle**(它会被周期定时器拖住),
// 一律用显式 pump(时长) 推进.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/login_sheet.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

import 'support/nav_chrome.dart';

rust.QrLoginKey key() => rust.QrLoginKey(
  key: 'k-1',
  url: 'https://music.163.com/login?codekey=k-1',
  expiresIn: BigInt.from(180),
);

rust.QrLoginCheck check(rust.QrLoginState state, {int code = 801}) =>
    rust.QrLoginCheck(
      state: state,
      code: code,
      // Confirmed 的登录凭据由 Rust 侧落盘, Dart 只拿到 loggedIn
      loggedIn: state == rust.QrLoginState.confirmed,
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
      builder: (ctx) =>
          TextButton(onPressed: () => onOpen(ctx), child: const Text('open')),
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

    await tester.pumpWidget(
      host((ctx) async {
        result = await showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, _) async {
            final i = calls < states.length - 1 ? calls : states.length - 1;
            calls++;
            return states[i];
          },
          onLoggedIn: () async => loggedIn++,
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
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
    await tester.pumpWidget(
      host((ctx) {
        showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, _) async {
            calls++;
            return check(rust.QrLoginState.expired, code: 800);
          },
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
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

  testWidgets('扫码 8821(需易盾验证): 提示安全验证并继续轮询', (tester) async {
    await bigSurface(tester);
    var calls = 0;
    await tester.pumpWidget(
      host((ctx) {
        showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, _) async {
            calls++;
            // 8821: 官方 PC 端此时弹易盾窗口; 本仓只做文案 + secureCaptcha 透传,
            // 扫码会话不结束, 轮询必须继续。
            return rust.QrLoginCheck(
              state: rust.QrLoginState.captcha,
              code: 8821,
              loggedIn: false,
              nickname: '',
              avatarUrl: null,
              secureCaptcha: 'tok-1',
            );
          },
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
    await openSheet(tester);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('需要在手机上完成安全验证, 完成后会自动继续'), findsOneWidget);

    // 与 expired/failed 不同: 定时器**不停**, 继续轮询等用户完成验证
    final before = calls;
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    expect(calls, greaterThan(before));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('扫码 8821: secureCaptcha 记住后下一轮原样回传', (tester) async {
    await bigSurface(tester);
    final seen = <String?>[];
    var calls = 0;
    await tester.pumpWidget(
      host((ctx) {
        showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, captcha) async {
            seen.add(captcha);
            calls++;
            // 第一轮 8821 带句柄, 之后句柄一路带着走(官方 PC 客户端同理)
            return rust.QrLoginCheck(
              state: rust.QrLoginState.captcha,
              code: 8821,
              loggedIn: false,
              nickname: '',
              avatarUrl: null,
              secureCaptcha: 'tok-9',
            );
          },
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
    await openSheet(tester);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(calls, greaterThanOrEqualTo(2));
    // 首轮没有句柄(null), 拿到后下一轮原样回传, 不做解析/改写
    expect(seen.first, isNull);
    expect(seen.skip(1).every((c) => c == 'tok-9'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('扫码未知 code(Unknown): 提示异常码并停轮询', (tester) async {
    await bigSurface(tester);
    var calls = 0;
    await tester.pumpWidget(
      host((ctx) {
        showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, _) async {
            calls++;
            return check(rust.QrLoginState.unknown, code: 9999);
          },
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
    await openSheet(tester);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    // 文案层提示异常码(状态行给「刷新二维码」建议, 详情行给 code)
    expect(find.text('扫码状态异常, 请点「刷新二维码」重试'), findsOneWidget);

    // Unknown 不是可继续状态: 定时器必须停(与 8821 相反)
    final afterUnknown = calls;
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, afterUnknown);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('导入 Cookie: 成功后关闭并回调', (tester) async {
    await bigSurface(tester);
    var committed = '';
    var loggedIn = 0;
    bool? result;
    await tester.pumpWidget(
      host((ctx) async {
        result = await showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, _) async => check(rust.QrLoginState.pending),
          commitCookie: (cookie) async {
            committed = cookie;
            return true;
          },
          onLoggedIn: () async => loggedIn++,
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
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
    await tester.pumpWidget(
      host((ctx) {
        showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, _) async => check(rust.QrLoginState.pending),
          commitCookie: (_) async => false,
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
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
    await tester.pumpWidget(
      host((ctx) {
        showLoginSheet(
          ctx,
          createQr: () async => key(),
          checkQr: (_, _) async => check(rust.QrLoginState.pending),
          commitCookie: (_) async {
            called++;
            return true;
          },
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
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
    await tester.pumpWidget(
      host((ctx) {
        showLoginSheet(
          ctx,
          createQr: () async {
            attempts++;
            if (attempts == 1) throw Exception('[network] boom');
            return key();
          },
          checkQr: (_, _) async => check(rust.QrLoginState.pending),
          pollInterval: const Duration(milliseconds: 100),
        );
      }),
    );
    await openSheet(tester);
    expect(find.textContaining('申请二维码失败'), findsOneWidget);

    await tester.tap(find.text('刷新二维码'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('300dp + 1.25 字号: 扫码面板不溢出', (tester) async {
    // 面板比 300x800 视口矮不了多少, 沿用本文件的 setSurfaceSize 放大画布
    await tester.binding.setSurfaceSize(const Size(300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () {
                showLoginSheet(
                  ctx,
                  createQr: () async => key(),
                  checkQr: (_, _) async => check(rust.QrLoginState.pending),
                  pollInterval: const Duration(milliseconds: 100),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await openSheet(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('等待扫码…'), findsOneWidget);
    // 卸载弹层, 停掉轮询 Timer, 避免 timersPending
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('切底部 tab 自动收起登录弹层(只关自己, 不误关其它弹层)', (tester) async {
    // 弹层是 modal sheet, 切 tab 不会自然消失, 一直挂在旧页面上(用户反馈).
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => playerBarSlot.value = null);
    // 底部导航由根布局的 PlayerBarHost 渲染(同 top_bar_no_duplicate_test);
    // 观察者与生产一致(MiniNcmApp 挂了 NcmRouteObserver): 切 tab 收起浮层走的是
    // 它的浮层登记表(见 app_shell.dart 的 dismissAllPopups), 不挂就收不到。
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [NcmRouteObserver()],
        builder: (context, child) =>
            PlayerBarHost(content: child ?? const SizedBox.shrink()),
        home: const HomePage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 从首页 context 走生产入口打开登录弹层(注入假实现, 不联网)
    unawaited(
      showLoginSheet(
        tester.element(find.byType(HomePage)),
        createQr: () async => key(),
        checkQr: (_, _) async => check(rust.QrLoginState.pending),
        pollInterval: const Duration(milliseconds: 100),
      ),
    );
    await tester.pump(); // push 路由
    await tester.pump(const Duration(milliseconds: 350)); // 滑入动画
    expect(find.byType(LoginSheet), findsOneWidget);
    expect(loginSheetOpen, isTrue);

    // 切到「我的」
    // 导航本体按宽度可能是底部 NavigationBar 或左侧 NavigationRail
    await tester.tap(
      find.descendant(of: navChromeFinder, matching: find.text('我的')),
    );
    await tester.pump(); // _onTabSelected → dismissAllPopups
    await tester.pump(const Duration(milliseconds: 400)); // 收起动画
    expect(find.byType(LoginSheet), findsNothing);
    expect(loginSheetOpen, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dismissLoginSheet 不碰其它弹层', (tester) async {
    await tester.pumpWidget(
      host((ctx) {
        unawaited(
          showModalBottomSheet<void>(
            context: ctx,
            builder: (_) => const Text('other-sheet'),
          ),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('other-sheet'), findsOneWidget);

    dismissLoginSheet(); // 登录弹层没开 → 什么都不做
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('other-sheet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
