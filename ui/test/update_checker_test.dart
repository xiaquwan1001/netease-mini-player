// 自动更新检查测试: compareVersions / 资产选择 / 错误路径 / 节流与跳过 / 关于项 UI。
// 网络全部走假 fetcher / 假 HttpClient, 绝不真联网(也不依赖网络插件)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_meta.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/update_checker.dart';

/// 构造 latest release 的 GitHub JSON(与真实 API 同构的最小子集)。
/// 默认 tag 故意取得比任何真实版本都高(v9.9.9): 这些用例断言的是"有更新",
/// 若跟着发版改成当前版本号, 每次 bump 版本后这条断言就会变成 "同一版本不算更新" 而挂。
String releaseJson({
  String tag = 'v9.9.9',
  String? name = 'MiniNCM 9.9.9',
  String? body = '修复若干问题',
  List<Map<String, String>> assets = const [
    {'name': 'MiniNCM-0.3.0-android-arm64.apk', 'browser_download_url': 'https://example.com/apk'},
    {'name': 'MiniNCM-0.3.0-linux-x64.tar.gz', 'browser_download_url': 'https://example.com/tgz'},
  ],
  String htmlUrl = 'https://github.com/xiaquwan1001/netease-mini-player/releases/tag/v9.9.9',
}) {
  return jsonEncode({
    'tag_name': tag,
    'name': name,
    'body': body,
    'html_url': htmlUrl,
    'assets': assets,
  });
}

UpdateFetcher fetcherOf(String body, {int statusCode = 200}) =>
    (_) async => (statusCode: statusCode, body: body);

/// 记录 openUrl 调用的假 host。
List<String> stubOpenUrl() {
  final calls = <String>[];
  UpdateCheckHost.openUrl = (url) async => calls.add(url);
  return calls;
}

/// 假 HttpClient(只实现 checkForUpdate 用到的成员, 其余走 noSuchMethod)。
class FakeHttpClient implements HttpClient {
  FakeHttpClient(this.body);
  final String body;
  Uri? lastUri;
  String? lastAccept;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    lastUri = url;
    return FakeHttpRequest(body, (accept) => lastAccept = accept);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class FakeHttpRequest implements HttpClientRequest {
  FakeHttpRequest(this.body, this.onHeader);
  final String body;
  final void Function(String accept) onHeader;

  @override
  HttpHeaders get headers => FakeHttpHeaders(onHeader);

  @override
  Future<HttpClientResponse> close() async => FakeHttpClientResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class FakeHttpHeaders implements HttpHeaders {
  FakeHttpHeaders(this.onSet);
  final void Function(String accept) onSet;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    if (name.toLowerCase() == 'accept') onSet(value.toString());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FakeHttpClientResponse(this.body);
  final String body;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> data)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(utf8.encode(body)).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  setUp(() {
    UpdateCheckHost.pendingUpdate.value = null;
  });

  group('compareVersions', () {
    test('0.2.1 < 0.2.10(逐段数字, 不是字符串比较)', () {
      expect(compareVersions('0.2.1', '0.2.10'), -1);
      expect(compareVersions('0.2.10', '0.2.1'), 1);
    });

    test('v 前缀等价处理: v0.3.0 > 0.2.9', () {
      expect(compareVersions('v0.3.0', '0.2.9'), 1);
      expect(compareVersions('V0.3.0', '0.2.9'), 1);
    });

    test('build 段 +N: 0.2.1+4 < 0.2.1+5', () {
      expect(compareVersions('0.2.1+4', '0.2.1+5'), -1);
      expect(compareVersions('0.2.1+5', '0.2.1+4'), 1);
    });

    test('semver 预发布: 1.0.0-rc1 < 1.0.0', () {
      expect(compareVersions('1.0.0-rc1', '1.0.0'), -1);
      expect(compareVersions('1.0.0', '1.0.0-rc1'), 1);
      // 预发布内部: 数字标识 < 字母标识
      expect(compareVersions('1.0.0-1', '1.0.0-alpha'), -1);
    });

    test('相等(含 v 前缀与相同 build)', () {
      expect(compareVersions('0.2.1', '0.2.1'), 0);
      expect(compareVersions('v0.2.1', '0.2.1'), 0);
      expect(compareVersions('0.2.1+7', '0.2.1+7'), 0);
    });

    test('非法输入: 不抛异常, 返回 0', () {
      expect(compareVersions('abc', '0.2.1'), 0);
      expect(compareVersions('0.2.1', 'not.a.version!'), 0);
      expect(compareVersions('', ''), 0);
    });
  });

  group('parseReleaseResponse / 资产选择', () {
    test('android 资产: 选中 -android-*.apk', () {
      final info = parseReleaseResponse(releaseJson(),
          currentVersion: '0.2.1', preferAndroid: true);
      expect(info, isNotNull);
      expect(info!.isNewer, isTrue);
      expect(info.downloadUrl, 'https://example.com/apk');
    });

    test('linux 资产: 选中 -linux-*.tar.gz', () {
      final info = parseReleaseResponse(releaseJson(),
          currentVersion: '0.2.1', preferAndroid: false);
      expect(info!.downloadUrl, 'https://example.com/tgz');
    });

    test('无匹配资产时 downloadUrl 回退 html_url', () {
      final info = parseReleaseResponse(
          releaseJson(assets: const [
            {
              'name': 'MiniNCM-0.3.0-win-x64.zip',
              'browser_download_url': 'https://example.com/zip',
            }
          ]),
          currentVersion: '0.2.1',
          preferAndroid: true);
      expect(
          info!.downloadUrl,
          'https://github.com/xiaquwan1001/netease-mini-player'
          '/releases/tag/v9.9.9');
    });

    test('旧版本/同版本 isNewer 为 false', () {
      expect(
          parseReleaseResponse(releaseJson(tag: 'v0.2.1'),
                  currentVersion: '0.2.1')!
              .isNewer,
          isFalse);
      expect(
          parseReleaseResponse(releaseJson(tag: 'v0.2.0'),
                  currentVersion: '0.2.1')!
              .isNewer,
          isFalse);
    });
  });

  group('checkForUpdate 错误路径(全部不抛异常返回 null)', () {
    test('404 => null', () async {
      final info = await checkForUpdate(
        currentVersion: kAppVersion,
        fetch: fetcherOf('Not Found', statusCode: 404),
      );
      expect(info, isNull);
    });

    test('超时(TimeoutException) => null', () async {
      Future<({int statusCode, String body})> slow(Uri _) async {
        throw TimeoutException('timed out');
      }
      final info =
          await checkForUpdate(currentVersion: kAppVersion, fetch: slow);
      expect(info, isNull);
    });

    test('坏 JSON => null', () async {
      final info = await checkForUpdate(
        currentVersion: kAppVersion,
        fetch: fetcherOf('{not json at all'),
      );
      expect(info, isNull);
    });

    test('无网络(SocketException) => null', () async {
      Future<({int statusCode, String body})> fail(Uri _) async {
        throw const SocketException('Network is unreachable');
      }
      final info =
          await checkForUpdate(currentVersion: kAppVersion, fetch: fail);
      expect(info, isNull);
    });

    test('tag_name 缺失(结构畸形) => null', () async {
      final info = await checkForUpdate(
        currentVersion: kAppVersion,
        fetch: fetcherOf(jsonEncode({'name': 'no tag'})),
      );
      expect(info, isNull);
    });
  });

  group('假 HttpClient 路径', () {
    test('注入假 HttpClient 解析 200 响应并携带协议头', () async {
      final client = FakeHttpClient(releaseJson());
      final info = await checkForUpdate(
        currentVersion: '0.2.1',
        client: client,
        apiBase: 'https://api.fake.local/latest',
        preferAndroid: true,
      );
      expect(info!.isNewer, isTrue);
      expect(client.lastUri.toString(), 'https://api.fake.local/latest');
      expect(client.lastAccept, 'application/vnd.github+json');
    });
  });

  group('启动静默检查: 节流与跳过(注入时钟)', () {
    test('24h 节流: 首次检查并记录, 24h 内不再请求', () async {
      var calls = 0;
      UpdateCheckHost.check = (v) async {
        calls++;
        return parseReleaseResponse(releaseJson(),
            currentVersion: v, preferAndroid: false);
      };
      final settings = AppSettings.instance;
      settings.updateCheckOnStartup = true;
      settings.lastUpdateCheckMs = null;
      settings.skippedUpdateVersion = null;
      var now = 1000000;
      await runStartupUpdateCheck(settings,
          startupDelay: Duration.zero, now: () => now);
      expect(calls, 1);
      expect(settings.lastUpdateCheckMs, 1000000);
      expect(UpdateCheckHost.pendingUpdate.value, isNotNull);

      UpdateCheckHost.pendingUpdate.value = null;
      now += const Duration(hours: 23).inMilliseconds;
      await runStartupUpdateCheck(settings,
          startupDelay: Duration.zero, now: () => now);
      expect(calls, 1, reason: '24h 内不重复请求');

      now += const Duration(hours: 2).inMilliseconds;
      await runStartupUpdateCheck(settings,
          startupDelay: Duration.zero, now: () => now);
      expect(calls, 2, reason: '超过 24h 后重新检查');
    });

    test('开关关闭时不检查; 跳过的版本不再点亮红点', () async {
      var calls = 0;
      UpdateCheckHost.check = (v) async {
        calls++;
        return parseReleaseResponse(releaseJson(),
            currentVersion: v, preferAndroid: false);
      };
      final settings = AppSettings.instance;
      settings.lastUpdateCheckMs = null;
      settings.updateCheckOnStartup = false;
      var now = 2000000;
      await runStartupUpdateCheck(settings,
          startupDelay: Duration.zero, now: () => now);
      expect(calls, 0, reason: '关闭开关就不后台检查');

      settings.updateCheckOnStartup = true;
      settings.skippedUpdateVersion = 'v9.9.9';
      await runStartupUpdateCheck(settings,
          startupDelay: Duration.zero, now: () => now);
      expect(calls, 1);
      expect(UpdateCheckHost.pendingUpdate.value, isNull,
          reason: '用户点「稍后」跳过的版本不再提示');

      // 换一个新版本则照常点亮(重置节流时间)
      settings.skippedUpdateVersion = null;
      settings.lastUpdateCheckMs = null;
      UpdateCheckHost.pendingUpdate.value = null;
      await runStartupUpdateCheck(settings,
          startupDelay: Duration.zero, now: () => now);
      expect(UpdateCheckHost.pendingUpdate.value, isNotNull);
    });

    test('shouldStartupCheck 纯函数边界: 恰好 24h', () {
      final s = AppSettings.instance..updateCheckOnStartup = true;
      s.lastUpdateCheckMs = 0;
      expect(
          shouldStartupCheck(
              settings: s, nowMs: const Duration(hours: 24).inMilliseconds),
          isTrue);
      expect(
          shouldStartupCheck(
              settings: s, nowMs: const Duration(hours: 24).inMilliseconds - 1),
          isFalse);
    });
  });

  group('设置页「检查更新」项 UI(假 host, 不联网)', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SettingsView(info: null)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('有新版本: 点击弹窗含版本号与下载按钮, 点下载走 openUrl',
        (tester) async {
      final opened = stubOpenUrl();
      UpdateCheckHost.check = (v) async => UpdateInfo(
            latest: 'v0.3.0',
            current: v,
            isNewer: true,
            notes: '新版本说明',
            downloadUrl: 'https://example.com/tgz',
          );
      await pumpSettings(tester);
      expect(find.text('检查更新'), findsOneWidget);
      // 初始无红点(先点亮 pendingUpdate 才有角标)
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      // tile 副标题(红点亮起)与弹窗标题各一处
      expect(find.text('发现新版本 v0.3.0'), findsNWidgets(2));
      expect(find.text('新版本说明'), findsOneWidget);
      expect(find.text('前往下载'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
      await tester.tap(find.text('前往下载'));
      await tester.pumpAndSettle();
      expect(opened, ['https://example.com/tgz']);
      // 弹窗后红点保持(直到用户装上新版本)
      expect(UpdateCheckHost.pendingUpdate.value, isNotNull);
    });

    testWidgets('无新版本: toast「已是最新版本」, 不弹窗', (tester) async {
      stubOpenUrl();
      UpdateCheckHost.check =
          (v) async => UpdateInfo(latest: v, current: v, isNewer: false);
      await pumpSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已是最新版本 v$kAppVersion'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('启动检查点亮红点: 关于项显示角标与新版本文案', (tester) async {
      stubOpenUrl();
      UpdateCheckHost.check = (v) async => null;
      UpdateCheckHost.pendingUpdate.value = UpdateInfo(
        latest: 'v0.3.0',
        current: kAppVersion,
        isNewer: true,
        downloadUrl: 'https://example.com/tgz',
      );
      await pumpSettings(tester);
      expect(find.text('发现新版本 v0.3.0'), findsOneWidget,
          reason: '红点项副标题展示新版本号');
    });

    testWidgets('检查失败: 错误 toast, 不弹窗', (tester) async {
      stubOpenUrl();
      UpdateCheckHost.check = (v) async => null;
      await pumpSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('检查更新失败, 请检查网络后重试'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('点「稍后」记录跳过版本', (tester) async {
      stubOpenUrl();
      final settings = AppSettings.instance..skippedUpdateVersion = null;
      UpdateCheckHost.check = (v) async => UpdateInfo(
            latest: 'v0.4.0',
            current: v,
            isNewer: true,
            notes: 'n',
            downloadUrl: 'https://example.com/tgz',
          );
      await pumpSettings(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(settings.skippedUpdateVersion, 'v0.4.0');
    });

    testWidgets('启动时检查更新开关存在且可切换', (tester) async {
      stubOpenUrl();
      final settings = AppSettings.instance..updateCheckOnStartup = true;
      await pumpSettings(tester);
      final tile = find.widgetWithText(SwitchListTile, '启动时检查更新');
      expect(tile, findsOneWidget);
      final sw = tester.widget<SwitchListTile>(tile);
      expect(sw.value, isTrue);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(settings.updateCheckOnStartup, isFalse);
      settings.updateCheckOnStartup = true;
    });
  });
}
