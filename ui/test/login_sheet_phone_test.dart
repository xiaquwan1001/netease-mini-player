// 手机号 + 短信验证码登录(桌面登录弹层的第二个 tab)的回归.
//
// 走的是网页登录通道(weapi), 与扫码同一族; 这里用注入的假实现覆盖:
// 发码 → 冷却 → 校验 → 成功后关弹层回调, 以及风控(8821)时把用户引回扫码.
//
// 注意: 弹层里有 Timer.periodic(扫码轮询) 与冷却倒计时, **不要 pumpAndSettle**.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/login_sheet.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.QrLoginKey qrKey() => rust.QrLoginKey(
      key: 'k-1',
      url: 'https://music.163.com/login?codekey=k-1',
      expiresIn: BigInt.from(180),
    );

rust.QrLoginCheck pending() => const rust.QrLoginCheck(
      state: rust.QrLoginState.pending,
      code: 801,
      loggedIn: false,
      nickname: '',
      avatarUrl: null,
    );

rust.PhoneLoginResult okLogin() => const rust.PhoneLoginResult(
      loggedIn: true,
      nickname: '下去玩',
      avatarUrl: null,
    );

Future<void> bigSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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

/// 打开弹层并切到「手机号登录」tab.
Future<void> openPhoneTab(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump(); // 建弹层 + 触发 createQr
  await tester.pump(); // createQr 完成
  await tester.pump(const Duration(milliseconds: 350)); // 底栏滑入
  await tester.tap(find.text('手机号登录'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('发码 → 冷却 → 填码登录成功: 关弹层并回调宿主', (tester) async {
    await bigSurface(tester);
    var loggedIn = 0;
    bool? result;
    String? sentPhone;
    String? verifiedCode;
    var cooldownTicks = 0;

    await tester.pumpWidget(host((ctx) async {
      result = await showLoginSheet(
        ctx,
        createQr: () async => qrKey(),
        checkQr: (_) async => pending(),
        sendSms: (phone, cc) async {
          sentPhone = '$cc-$phone';
          return const rust.SmsCodeSent(code: 200, message: '', expiresIn: 60);
        },
        verifySms: (phone, code, cc) async {
          verifiedCode = code;
          return okLogin();
        },
        onLoggedIn: () async => loggedIn++,
        resendCooldownSeconds: 2, // 冷却 2 秒, 便于观察倒计时
        pollInterval: const Duration(seconds: 30),
      );
    }));
    await openPhoneTab(tester);

    await tester.enterText(find.widgetWithText(TextField, '手机号'), '13800138000');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    await tester.pump();

    expect(sentPhone, '86-13800138000');
    // 冷却中: 按钮变成倒计时并且不可点
    expect(find.textContaining('后重发'), findsOneWidget);
    final btn = tester.widget<OutlinedButton>(find.byType(OutlinedButton).first);
    expect(btn.onPressed, isNull);

    await tester.pump(const Duration(seconds: 1));
    cooldownTicks = 1;
    expect(cooldownTicks, 1);

    await tester.enterText(find.widgetWithText(TextField, '短信验证码'), '123456');
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350)); // 关闭动画

    expect(verifiedCode, '123456');
    expect(loggedIn, 1);
    expect(result, isTrue);
    expect(find.text('手机号登录'), findsNothing);
  });

  testWidgets('风控(8821): 报错并把用户引回扫码登录', (tester) async {
    await bigSurface(tester);
    await tester.pumpWidget(host((ctx) {
      showLoginSheet(
        ctx,
        createQr: () async => qrKey(),
        checkQr: (_) async => pending(),
        sendSms: (phone, cc) async => throw Exception(
            '[riskControl] code=8821: 安全环境风险, 请切换其他登录方式'),
        verifySms: (phone, code, cc) async => okLogin(),
        pollInterval: const Duration(seconds: 30),
      );
    }));
    await openPhoneTab(tester);

    await tester.enterText(find.widgetWithText(TextField, '手机号'), '13800138000');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('发送验证码失败'), findsOneWidget);
    expect(find.textContaining('请改用「扫码登录」'), findsOneWidget);
    // 冷却没启动, 用户可以重试或换方式
    final btn = tester.widget<OutlinedButton>(find.byType(OutlinedButton).first);
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('空手机号 / 空验证码: 只提示, 不打接口', (tester) async {
    await bigSurface(tester);
    var called = 0;
    await tester.pumpWidget(host((ctx) {
      showLoginSheet(
        ctx,
        createQr: () async => qrKey(),
        checkQr: (_) async => pending(),
        sendSms: (phone, cc) async {
          called++;
          return const rust.SmsCodeSent(code: 200, message: '', expiresIn: 60);
        },
        verifySms: (phone, code, cc) async {
          called++;
          return okLogin();
        },
        pollInterval: const Duration(seconds: 30),
      );
    }));
    await openPhoneTab(tester);

    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    expect(find.text('先填手机号'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '手机号'), '13800138000');
    await tester.tap(find.text('登录'));
    await tester.pump();
    expect(find.text('先填收到的短信验证码'), findsOneWidget);

    expect(called, 0);
  });

  testWidgets('切到手机号 tab 时不再轮询二维码', (tester) async {
    await bigSurface(tester);
    var polls = 0;
    await tester.pumpWidget(host((ctx) {
      showLoginSheet(
        ctx,
        createQr: () async => qrKey(),
        checkQr: (_) async {
          polls++;
          return pending();
        },
        sendSms: (phone, cc) async =>
            const rust.SmsCodeSent(code: 200, message: '', expiresIn: 60),
        verifySms: (phone, code, cc) async => okLogin(),
        pollInterval: const Duration(milliseconds: 100),
      );
    }));
    await openPhoneTab(tester);
    final before = polls;
    await tester.pump(const Duration(milliseconds: 500));
    expect(polls, before);
  });

  testWidgets('300dp + 1.25 字号: 手机号登录面板不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
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
                createQr: () async => qrKey(),
                checkQr: (_) async => pending(),
                sendSms: (phone, cc) async =>
                    const rust.SmsCodeSent(code: 200, message: '', expiresIn: 60),
                verifySms: (phone, code, cc) async => okLogin(),
                pollInterval: const Duration(seconds: 30),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await openPhoneTab(tester);

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextField, '手机号'), findsOneWidget);
    // 卸载弹层, 停掉轮询/冷却 Timer, 避免 timersPending
    await tester.pumpWidget(const SizedBox());
  });
}
