import 'dart:convert';
import 'dart:io';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/desktop_shell.dart';

/// Linux「关闭主窗口 = 退出 / 隐藏到托盘」的离线单测(lane/tray-close)。
///
/// 覆盖三块纯逻辑与契约, 都不碰真实桌面会话:
///   1. 设置项默认值 / 落盘 / 读回(含未知值回落"直接退出");
///   2. 通知文案不撒谎(非 Linux / 有托盘 / 缺库 / 缺 StatusNotifier 宿主);
///   3. 通道契约: 推设置、读能力、hideToTray 的降级返回值, 以及
///      didRequestAppExit 的 exit / cancel 分流(托盘模式必须 cancel, 否则进程会退出)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final settings = AppSettings.instance;

  group('设置项(默认值 + 落盘)', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ncm_close_behavior');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Map<String, dynamic> readSettings() =>
        jsonDecode(File('${dir.path}/settings.json').readAsStringSync())
            as Map<String, dynamic>;

    test('默认是"直接退出"(不改变旧用户预期)', () async {
      await settings.load(dir.path);
      expect(settings.closeBehavior, CloseBehavior.quit);
    });

    test('旧配置没有 closeBehavior 字段 ⇒ 按直接退出读', () async {
      File('${dir.path}/settings.json')
          .writeAsStringSync(jsonEncode({'themeMode': 'dark'}));
      await settings.load(dir.path);
      expect(settings.closeBehavior, CloseBehavior.quit);
    });

    test('未知/坏值回落"直接退出", 不报错', () async {
      File('${dir.path}/settings.json')
          .writeAsStringSync(jsonEncode({'closeBehavior': 'teleport'}));
      await settings.load(dir.path);
      expect(settings.closeBehavior, CloseBehavior.quit);
      expect(CloseBehaviorX.fromId(null), CloseBehavior.quit);
      expect(CloseBehaviorX.fromId(42), CloseBehavior.quit);
    });

    test('选托盘后落盘为 "tray", 重新 load 能读回', () async {
      await settings.load(dir.path);
      await settings.update(closeBehavior: CloseBehavior.minimizeToTray);
      expect(readSettings()['closeBehavior'], 'tray');
      // 换一个实例读同一份文件: load 幂等、值不丢
      await settings.load(dir.path);
      expect(settings.closeBehavior, CloseBehavior.minimizeToTray);
      // 再切回退出也落盘('tray' 不是单向的)
      await settings.update(closeBehavior: CloseBehavior.quit);
      expect(readSettings()['closeBehavior'], 'quit');
    });
  });

  group('设置项文案(不撒谎)', () {
    const unknown = TrayStatus.unknown();
    const available = TrayStatus(
      trayAvailable: true,
      libAppIndicator: true,
      closeToTray: true,
      reason: 'ok',
    );
    const noLib = TrayStatus(
      trayAvailable: false,
      libAppIndicator: false,
      closeToTray: true,
      reason: 'no-libappindicator',
    );
    const noHost = TrayStatus(
      trayAvailable: false,
      libAppIndicator: true,
      closeToTray: true,
      reason: 'no-status-notifier-host',
    );

    test('非 Linux 明说"仅 Linux 生效"(Windows 端本轮未实现)', () {
      final text = closeBehaviorSubtitle(
        behavior: CloseBehavior.minimizeToTray,
        status: available,
        linux: false,
      );
      expect(text, contains('仅 Linux'));
      expect(text, contains('仍然是直接退出'));
    });

    test('直接退出: 说清与旧版一致且停播放', () {
      final text = closeBehaviorSubtitle(
        behavior: CloseBehavior.quit,
        status: available,
        linux: true,
      );
      expect(text, contains('直接退出'));
      expect(text, contains('停止播放'));
    });

    test('托盘可用: 说清"后台继续播放 + 托盘恢复/退出"', () {
      final text = closeBehaviorSubtitle(
        behavior: CloseBehavior.minimizeToTray,
        status: available,
        linux: true,
      );
      expect(text, contains('继续播放'));
      expect(text, contains('托盘'));
      expect(text, isNot(contains('降级')));
    });

    test('缺库 / 缺宿主都如实写"降级为最小化到任务栏"', () {
      for (final status in [noLib, noHost, unknown]) {
        final text = closeBehaviorSubtitle(
          behavior: CloseBehavior.minimizeToTray,
          status: status,
          linux: true,
        );
        expect(text, contains('降级'), reason: status.reason);
        expect(text, contains('任务栏'), reason: status.reason);
      }
      expect(
        closeBehaviorSubtitle(
          behavior: CloseBehavior.minimizeToTray,
          status: noLib,
          linux: true,
        ),
        contains('libayatana-appindicator3'),
      );
    });
  });

  group('TrayStatus 解析(宽容, 不抛)', () {
    test('完整 map', () {
      final s = TrayStatus.fromChannel({
        'trayAvailable': true,
        'libAppIndicator': true,
        'closeToTray': true,
        'reason': 'ok',
      });
      expect(s.trayAvailable, isTrue);
      expect(s.libAppIndicator, isTrue);
      expect(s.closeToTray, isTrue);
      expect(s.reason, 'ok');
    });

    test('null / 类型不对 / 缺字段 ⇒ 按不可用处理', () {
      expect(TrayStatus.fromChannel(null).reason, 'unknown');
      expect(TrayStatus.fromChannel('nope').trayAvailable, isFalse);
      expect(TrayStatus.fromChannel(<Object?, Object?>{}).reason, 'unknown');
      final s = TrayStatus.fromChannel({
        'trayAvailable': 'true', // 字符串不是 bool
        'reason': 7,
      });
      expect(s.trayAvailable, isFalse);
      expect(s.reason, 'unknown');
      expect(s.degraded, isTrue);
    });
  });

  group('ncm/desktop_shell 通道契约', () {
    const channel = MethodChannel('ncm/desktop_shell.test');
    final calls = <MethodCall>[];
    late DesktopShell shell;

    setUp(() {
      calls.clear();
      shell = DesktopShell(channel: channel);
    });

    tearDown(() {
      // 卸掉 mock, 免得影响其它用例
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    void mock(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return handler(call);
          });
    }

    test('getStatus 读回能力快照', () async {
      mock(
        (_) async => {
          'trayAvailable': true,
          'libAppIndicator': true,
          'closeToTray': true,
          'reason': 'ok',
        },
      );
      if (!DesktopShell.isSupportedPlatform) return;
      final status = await shell.refresh();
      expect(status.trayAvailable, isTrue);
      expect(shell.status.value.trayAvailable, isTrue);
      expect(calls.single.method, 'getStatus');
    });

    test('setCloseBehavior 推的是稳定 id(tray/quit)', () async {
      mock((_) async => true);
      if (!DesktopShell.isSupportedPlatform) return;
      expect(
        await shell.setCloseBehavior(CloseBehavior.minimizeToTray),
        isTrue,
      );
      expect(calls.single.method, 'setCloseBehavior');
      expect(calls.single.arguments, 'tray');
      await shell.setCloseBehavior(CloseBehavior.quit);
      expect(calls.last.arguments, 'quit');
    });

    test('hideToTray 返回 false(降级)时不假装成功', () async {
      mock((_) async => false);
      if (!DesktopShell.isSupportedPlatform) return;
      expect(await shell.hideToTray(), isFalse);
      expect(calls.single.method, 'hideToTray');
    });

    test('通道不存在(MissingPluginException)时静默降级', () async {
      mock((_) async => throw MissingPluginException('no host'));
      if (!DesktopShell.isSupportedPlatform) return;
      expect(
        await shell.setCloseBehavior(CloseBehavior.minimizeToTray),
        isFalse,
      );
      expect(await shell.hideToTray(), isFalse);
      expect((await shell.refresh()).reason, 'unknown');
    });

    test('bindSettings 启动推一次 + 改设置再推', () async {
      mock(
        (call) async => call.method == 'getStatus'
            ? <Object?, Object?>{
                'trayAvailable': false,
                'reason': 'no-status-notifier-host',
              }
            : true,
      );
      if (!DesktopShell.isSupportedPlatform) return;
      await settings.load(Directory.systemTemp.createTempSync('ncm_bind').path);
      shell.unbindSettings();
      await shell.bindSettings(settings);
      expect(calls.first.method, 'getStatus');
      expect(
        calls.where((c) => c.method == 'setCloseBehavior').single.arguments,
        settings.closeBehavior.id,
      );

      calls.clear();
      await settings.update(closeBehavior: CloseBehavior.minimizeToTray);
      // 通知是同步 addListener → 异步 _push; 让事件循环跑完
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((c) => c.method == 'setCloseBehavior').last.arguments,
        'tray',
      );
      shell.unbindSettings();
    });
  });

  group('didRequestAppExit 分流(核心: 托盘模式必须 cancel)', () {
    const channel = MethodChannel('ncm/desktop_shell.exit');
    final calls = <MethodCall>[];
    late DesktopShell shell;
    late AppSettings localSettings;
    late Directory dir;

    setUp(() async {
      calls.clear();
      shell = DesktopShell(channel: channel);
      dir = Directory.systemTemp.createTempSync('ncm_exit');
      localSettings = AppSettings.instance;
      await localSettings.load(dir.path);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    void mock(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return handler(call);
          });
    }

    test('直接退出: 返回 exit, 完全不碰原生通道', () async {
      mock((_) async => true);
      await localSettings.update(closeBehavior: CloseBehavior.quit);
      final observer = DesktopCloseObserver(
        shell: shell,
        settings: localSettings,
      );
      final r = await observer.didRequestAppExit();
      if (!DesktopShell.isSupportedPlatform) {
        expect(r, AppExitResponse.exit);
        return;
      }
      expect(r, AppExitResponse.exit);
      expect(calls, isEmpty);
    });

    test('托盘模式: 返回 cancel 并请求原生隐藏(进程与播放保留)', () async {
      mock((_) async => true);
      await localSettings.update(closeBehavior: CloseBehavior.minimizeToTray);
      final observer = DesktopCloseObserver(
        shell: shell,
        settings: localSettings,
      );
      final r = await observer.didRequestAppExit();
      if (!DesktopShell.isSupportedPlatform) {
        expect(r, AppExitResponse.exit);
        return;
      }
      expect(r, AppExitResponse.cancel);
      expect(calls.single.method, 'hideToTray');
    });

    test('托盘模式 + 无托盘宿主: 仍然 cancel(不能退出), 降级提示只弹一次', () async {
      mock((_) async => false); // 原生 hideToTray 返回 false = 降级为最小化
      await localSettings.update(closeBehavior: CloseBehavior.minimizeToTray);
      final observer = DesktopCloseObserver(
        shell: shell,
        settings: localSettings,
      );
      var notified = 0;
      observer.onFallbackToTaskbar = () => notified++;
      final r1 = await observer.didRequestAppExit();
      final r2 = await observer.didRequestAppExit();
      if (!DesktopShell.isSupportedPlatform) {
        expect(r1, AppExitResponse.exit);
        return;
      }
      expect(r1, AppExitResponse.cancel);
      expect(r2, AppExitResponse.cancel);
      expect(notified, 1);
    });
  });
}
