import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/vip_page.dart';

/// 7 天签到样本(对齐 vip_sign_info: [{timeStr, today, score}], 升序, score>0 即已签)
List<VipSignDayView> sampleDays({required bool signedToday}) {
  const dates = [
    '2026-11-01', // 周日
    '2026-11-02',
    '2026-11-03',
    '2026-11-04',
    '2026-11-05',
    '2026-11-06',
    '2026-11-07', // 今天
  ];
  const labels = ['日', '一', '二', '三', '四', '五', '六'];
  return [
    for (var i = 0; i < dates.length; i++)
      VipSignDayView(
        date: dates[i],
        label: labels[i],
        // 前 3 天已签; 今天由 signedToday 决定
        signed: i < 3 || (i == 6 && signedToday),
        today: i == 6,
      ),
  ];
}

VipPageData fakeData({
  bool loggedIn = true,
  bool signedToday = true,
  bool isVip = true,
  String? avatarUrl,
  List<VipTaskView>? tasks,
}) => VipPageData(
  isLoggedIn: loggedIn,
  profile: loggedIn
      ? VipProfileView(
          nickname: '测试用户',
          avatarUrl: avatarUrl,
          level: 3,
          levelName: '黑胶·叁',
          isVip: isVip,
          expireDate: '2026-11-10',
          growthValue: 2195,
          todayGrowthValue: 6,
        )
      : null,
  sign: loggedIn
      ? VipSignView(
          days: sampleDays(signedToday: signedToday),
          signedToday: signedToday,
        )
      : null,
  tasks:
      tasks ??
      const [
        VipTaskView(
          title: '浏览黑胶时光机',
          rewardText: '成长值+3',
          progress: 0,
          total: 0,
          showProgress: true,
        ),
        VipTaskView(
          title: '每日听歌 30 分钟',
          rewardText: '成长值+2',
          progress: 30,
          total: 60,
        ),
        VipTaskView(
          title: '已完成任务',
          rewardText: '云贝+10',
          progress: 3,
          total: 3,
          done: true,
        ),
      ],
);

/// 签到卡片里的圆点(28x28), 用来数渲染了几格
Finder signDots() => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.constraints?.maxWidth == 28 &&
      w.constraints?.maxHeight == 28,
);

/// 不发起任何真实请求的 HttpClient 桩
class _NoopHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _NoopHttpClient();
}

/// 返回空的 1x1 PNG, 让图片解码安静失败/成功, 不抛异常
class _NoopHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout = Duration.zero;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _NoopRequest();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _NoopHeaders();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  Future<HttpClientResponse> close() async => _NoopResponse();
}

/// 1x1 透明 PNG
final List<int> _tinyPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class _NoopResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => _tinyPng.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  HttpHeaders get headers => _NoopHeaders();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_tinyPng).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget host(VipPage page, {Size? size, double textScale = 1.0}) {
  Widget w = MaterialApp(home: page);
  if (size != null || textScale != 1.0) {
    w = MediaQuery(
      data: MediaQueryData(
        size: size ?? const Size(800, 600),
        textScaler: TextScaler.linear(textScale),
      ),
      child: w,
    );
  }
  return w;
}

void main() {
  testWidgets('正常态: 会员卡/签到/任务全部渲染', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        VipPage(
          load: () async {
            calls++;
            return fakeData();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
    // 会员卡
    expect(find.text('测试用户'), findsOneWidget);
    expect(find.text('黑胶VIP'), findsOneWidget);
    expect(find.textContaining('到期 2026-11-10'), findsOneWidget);
    expect(find.textContaining('成长值 2195'), findsOneWidget);
    expect(find.textContaining('今日 +6'), findsOneWidget);
    // 签到: 本周维度, 不再有本月/累计文案
    expect(find.textContaining('本月已签'), findsNothing);
    expect(find.textContaining('累计'), findsNothing);
    // 任务条
    expect(find.text('浏览黑胶时光机'), findsOneWidget); // name 空 -> 退 action
    expect(find.text('每日听歌 30 分钟'), findsOneWidget);
    expect(find.text('已完成任务'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('30/60'), findsOneWidget);
  });

  testWidgets('签到文案: 今天已签 / 今天未签两种', (tester) async {
    await tester.pumpWidget(
      host(VipPage(load: () async => fakeData(signedToday: true))),
    );
    await tester.pumpAndSettle();

    // 前 3 天 + 今天 = 4 天已签
    expect(find.textContaining('本周已签 4/7 天'), findsOneWidget);
    expect(find.textContaining('今日已签'), findsOneWidget);
    expect(find.textContaining('今日未签'), findsNothing);
    // 7 格全部渲染: 只在签到卡片内数图标(任务条也用 radio_button_unchecked)
    expect(find.byIcon(Icons.check), findsNWidgets(4));
    expect(signDots(), findsNWidgets(7));

    // 换 key 强制重建 State, 否则 initState 不会重跑(loader 不换)
    await tester.pumpWidget(
      host(
        VipPage(
          key: const ValueKey('un-signed'),
          load: () async => fakeData(signedToday: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('本周已签 3/7 天'), findsOneWidget);
    expect(find.textContaining('今日未签'), findsOneWidget);
    expect(find.textContaining('今日已签'), findsNothing);
    expect(find.byIcon(Icons.check), findsNWidgets(3));
    expect(signDots(), findsNWidgets(7));
  });

  testWidgets('未登录空态: 文案 + 登录按钮回调', (tester) async {
    var loginCalls = 0;
    await tester.pumpWidget(
      host(
        VipPage(
          load: () async => fakeData(loggedIn: false),
          onLogin: () => loginCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录后可查看会员信息'), findsOneWidget);
    expect(find.text('测试用户'), findsNothing);

    await tester.tap(find.text('登录'));
    expect(loginCalls, 1);
  });

  testWidgets('错误态: friendlyError 文案 + 点重试再次调用 loader', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        VipPage(
          load: () async {
            calls++;
            if (calls == 1) throw Exception('network boom');
            return fakeData();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.textContaining('network boom'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('测试用户'), findsOneWidget);
  });

  testWidgets('任务条: total 为 0 / showProgress 为 false 时不渲染进度条', (tester) async {
    await tester.pumpWidget(
      host(
        VipPage(
          load: () async => fakeData(
            tasks: const [
              // targets == null -> total 0: 无进度条
              VipTaskView(title: '浏览黑胶时光机', rewardText: '成长值+3'),
              // showProgress == false: 无进度条
              VipTaskView(
                title: '看好礼',
                rewardText: '成长值+1',
                progress: 1,
                total: 5,
                showProgress: false,
              ),
              // 有 total: 有进度条
              VipTaskView(
                title: '每日听歌',
                rewardText: '成长值+2',
                progress: 30,
                total: 60,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('浏览黑胶时光机'), findsOneWidget);
    expect(find.text('看好礼'), findsOneWidget);
    expect(find.text('每日听歌'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('30/60'), findsOneWidget);
    expect(find.text('未完成'), findsNWidgets(2));
  });

  testWidgets('头像走 CircleAvatar + NetworkImage(不带 headers)', (tester) async {
    // 测试环境下 HTTP 一律 400: 换掉默认 HttpClient, 避免真实网络与异常
    final saved = HttpOverrides.current;
    HttpOverrides.global = _NoopHttpOverrides();
    addTearDown(() => HttpOverrides.global = saved);
    await tester.pumpWidget(
      host(
        VipPage(
          load: () async =>
              fakeData(avatarUrl: 'https://p1.music.126.net/a.jpg'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar).first);
    expect(avatar.backgroundImage, isA<NetworkImage>());
    expect(
      (avatar.backgroundImage! as NetworkImage).url,
      'https://p1.music.126.net/a.jpg',
    );
    expect((avatar.backgroundImage! as NetworkImage).headers, isNull);
  });

  testWidgets('300dp 窄屏 + 1.25 倍字号不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(300, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      host(
        VipPage(load: () async => fakeData()),
        size: const Size(300, 600),
        textScale: 1.25,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
