import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/desktop_shell.dart';

/// Linux 系统托盘菜单的播放控制(N3)离线单测。
///
/// 覆盖三块, 都不碰真实桌面会话:
///   1. 动作名与原生 `my_application.cc` 的 kTrayAction* 逐字一致(表只有一份);
///   2. 动作 → **已有**播放控制回调的分发: 注册了就调, 没注册就安全 no-op;
///   3. 通道契约: Dart→原生推按钮态(幂等)、原生→Dart 发动作(含未注册时 no-op)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('动作名(与原生同一份表)', () {
    test('四个常量就是通道里跑的字符串', () {
      expect(TrayActionNames.togglePlay, 'togglePlay');
      expect(TrayActionNames.previous, 'previous');
      expect(TrayActionNames.next, 'next');
      expect(TrayActionNames.toggleLike, 'toggleLike');
      // 枚举的 id 与常量表一致(抄错一处这里会红)
      for (final action in TrayAction.values) {
        expect(action.id, isNotEmpty);
        expect(TrayAction.tryParse(action.id), action);
      }
      expect(TrayAction.values.length, 4);
    });

    test('认不出的动作解析成 null(不猜、不抛)', () {
      expect(TrayAction.tryParse('playPause'), isNull);
      expect(TrayAction.tryParse(''), isNull);
      expect(TrayAction.tryParse(null), isNull);
      expect(TrayAction.tryParse(7), isNull);
      expect(TrayAction.tryParse(MethodCall('trayAction')), isNull);
    });
  });

  group('TrayActionHandlers 分发', () {
    test('每个动作落到自己的回调, 且返回 true', () {
      final hits = <String>[];
      final handlers = TrayActionHandlers(
        onTogglePlay: () => hits.add('togglePlay'),
        onPrevious: () => hits.add('previous'),
        onNext: () => hits.add('next'),
        onToggleLike: () => hits.add('toggleLike'),
      );
      for (final action in TrayAction.values) {
        expect(handlers.handles(action), isTrue);
        expect(handlers.dispatch(action), isTrue);
      }
      expect(hits, ['togglePlay', 'previous', 'next', 'toggleLike']);
    });

    test('只有一部分注册: 注册的照跑, 没注册的安全 no-op', () {
      final hits = <String>[];
      final handlers = TrayActionHandlers(onNext: () => hits.add('next'));
      expect(handlers.dispatch(TrayAction.togglePlay), isFalse);
      expect(handlers.dispatch(TrayAction.toggleLike), isFalse);
      expect(handlers.handles(TrayAction.togglePlay), isFalse);
      expect(handlers.dispatch(TrayAction.next), isTrue);
      expect(hits, ['next']);
    });

    test('全空(无页面/未登录)也不抛', () {
      const handlers = TrayActionHandlers();
      for (final action in TrayAction.values) {
        expect(handlers.handles(action), isFalse);
        expect(handlers.dispatch(action), isFalse);
      }
    });
  });

  group('ncm/desktop_shell 通道契约(托盘部分)', () {
    const channel = MethodChannel('ncm/desktop_shell.tray_test');
    const codec = StandardMethodCodec();
    final calls = <MethodCall>[];
    late DesktopShell shell;

    setUp(() {
      calls.clear();
      shell = DesktopShell(channel: channel)
        ..setTrayActionHandlers(null)
        ..debugResetPlaybackStateCache();
    });

    tearDown(() {
      shell.setTrayActionHandlers(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    void mockHost(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return handler(call);
          });
    }

    /// 模拟原生 → Dart 的一次 invokeMethod。
    Future<void> nativeCall(String method, Object? arguments) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(MethodCall(method, arguments)),
            (_) {},
          );
    }

    test('setPlaybackState 推的是稳定字面键, 且值未变时不重复跨通道', () async {
      mockHost((_) async => true);
      if (!DesktopShell.isSupportedPlatform) return;

      expect(
        await shell.setPlaybackState(
          playing: true,
          liked: false,
          hasTrack: true,
        ),
        isTrue,
      );
      expect(calls.single.method, 'setTrayPlaybackState');
      expect(calls.single.arguments, {
        'playing': true,
        'liked': false,
        'hasTrack': true,
      });

      // 同一份状态再推一次: 幂等短路, 不再跨通道(整页重建会频繁调)
      await shell.setPlaybackState(playing: true, liked: false, hasTrack: true);
      expect(calls.length, 1);

      // 播放态变化 ⇒ 真的推一次(原生据此把「播放」改成「暂停」)
      await shell.setPlaybackState(playing: false, liked: true, hasTrack: true);
      expect(calls.length, 2);
      expect(calls.last.arguments, {
        'playing': false,
        'liked': true,
        'hasTrack': true,
      });
    });

    test('原生说托盘菜单没建好 ⇒ 返回 false(不假装成功)', () async {
      mockHost((_) async => false);
      if (!DesktopShell.isSupportedPlatform) return;
      expect(
        await shell.setPlaybackState(
          playing: false,
          liked: false,
          hasTrack: false,
        ),
        isFalse,
      );
    });

    test('通道缺失时静默降级(托盘不可用也不崩)', () async {
      mockHost((_) async => throw MissingPluginException('no host'));
      if (!DesktopShell.isSupportedPlatform) return;
      expect(
        await shell.setPlaybackState(
          playing: true,
          liked: true,
          hasTrack: true,
        ),
        isFalse,
      );
    });

    test('原生 → Dart: trayAction 落到已注册的回调', () async {
      final hits = <String>[];
      shell.setTrayActionHandlers(
        TrayActionHandlers(
          onTogglePlay: () => hits.add('togglePlay'),
          onPrevious: () => hits.add('previous'),
          onNext: () => hits.add('next'),
          onToggleLike: () => hits.add('toggleLike'),
        ),
      );
      for (final name in [
        TrayActionNames.togglePlay,
        TrayActionNames.previous,
        TrayActionNames.next,
        TrayActionNames.toggleLike,
      ]) {
        await nativeCall('trayAction', name);
      }
      expect(hits, ['togglePlay', 'previous', 'next', 'toggleLike']);
    });

    test('未注册回调 / 未知动作 / 别的方法名: 都不崩也不回调', () async {
      final hits = <String>[];
      // 没注册就收到动作: 安全 no-op
      await nativeCall('trayAction', TrayActionNames.next);
      expect(hits, isEmpty);

      shell.setTrayActionHandlers(
        TrayActionHandlers(onNext: () => hits.add('next')),
      );
      // 未知动作: 解析不出枚举 ⇒ 丢弃(两端口径漂了只留日志)
      await nativeCall('trayAction', 'teleport');
      await nativeCall('trayAction', null);
      // 不是本桥认的方法
      await nativeCall('somethingElse', TrayActionNames.next);
      expect(hits, isEmpty);

      await nativeCall('trayAction', TrayActionNames.next);
      expect(hits, ['next']);
    });
  });
}
