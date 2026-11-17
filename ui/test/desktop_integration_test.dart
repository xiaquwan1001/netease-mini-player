import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/desktop_integration.dart';

/// AppImage 首启「集成到应用菜单」(§11.A-2) 的判据与落盘契约。
///
/// 这些用例只碰临时目录(HOME 注入), 不写真实 `~/.local`, 也不依赖桌面会话。
void main() {
  group('该不该问(纯函数)', () {
    test('只有 AppImage 且没装过、没拒绝过才问', () {
      expect(
        shouldOfferDesktopIntegration(
          appImagePath: '/home/u/Apps/MiniNCM.AppImage',
          desktopEntryExists: false,
          askedBefore: false,
        ),
        isTrue,
      );
    });

    test('非 AppImage(源码运行 / deb 安装)不问', () {
      expect(
        shouldOfferDesktopIntegration(
          appImagePath: null,
          desktopEntryExists: false,
          askedBefore: false,
        ),
        isFalse,
      );
      expect(
        shouldOfferDesktopIntegration(
          appImagePath: '',
          desktopEntryExists: false,
          askedBefore: false,
        ),
        isFalse,
      );
    });

    test('已集成 / 已拒绝都不再问', () {
      expect(
        shouldOfferDesktopIntegration(
          appImagePath: '/x.AppImage',
          desktopEntryExists: true,
          askedBefore: false,
        ),
        isFalse,
      );
      expect(
        shouldOfferDesktopIntegration(
          appImagePath: '/x.AppImage',
          desktopEntryExists: false,
          askedBefore: true,
        ),
        isFalse,
      );
    });
  });

  group('desktop entry 文本', () {
    test('Exec 用 AppImage 绝对路径, 不写 minincm(PATH 上并没有它)', () {
      final text = buildIntegratedDesktopEntry(
        execPath: '/home/u/Apps/MiniNCM-0.20.0.AppImage',
        version: '0.20.0',
      );
      expect(text, contains('Exec=/home/u/Apps/MiniNCM-0.20.0.AppImage %U'));
      expect(text, isNot(contains('Exec=minincm')));
      expect(text, contains('Icon=$kDesktopIconName'));
      expect(text, contains('StartupWMClass=$kDesktopAppId'));
      expect(text, contains('X-AppImage-Version=0.20.0'));
      expect(text.startsWith('[Desktop Entry]'), isTrue);
    });

    test('路径含空格/引号时整体加引号并转义', () {
      expect(quoteDesktopExec('/plain/path'), '/plain/path');
      expect(
        quoteDesktopExec('/with space/x.AppImage'),
        '"/with space/x.AppImage"',
      );
      expect(quoteDesktopExec(r'/a"b/x'), r'"/a\"b/x"');
      final text = buildIntegratedDesktopEntry(
        execPath: '/mnt/my apps/x.AppImage',
      );
      expect(text, contains('Exec="/mnt/my apps/x.AppImage" %U'));
    });
  });

  group('安装落盘(临时 HOME)', () {
    late Directory tmp;
    late String home;
    late String installedExe;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ncm-integration-');
      home = '${tmp.path}/home';
      // 模拟 AppDir 布局: <appdir>/usr/bin/minincm + <appdir>/usr/share/icons/...
      installedExe = '${tmp.path}/AppDir/usr/bin/minincm';
      final icon = File(bundledIconPath(installedExe));
      await icon.parent.create(recursive: true);
      await icon.writeAsBytes(const [0x89, 0x50, 0x4E, 0x47]); // PNG 头就够
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('写 desktop + 图标, 幂等且不需要 root', () async {
      final r1 = await installDesktopIntegration(
        appImagePath: '/home/u/Apps/MiniNCM.AppImage',
        home: home,
        executablePath: installedExe,
        refreshDatabase: false, // 测试环境不跑 update-desktop-database
      );
      expect(r1.ok, isTrue, reason: r1.error);
      expect(r1.iconInstalled, isTrue);
      expect(r1.desktopPath, userDesktopEntryPath(home));
      final desktop = File(userDesktopEntryPath(home));
      expect(await desktop.exists(), isTrue);
      expect(
        await desktop.readAsString(),
        contains('/home/u/Apps/MiniNCM.AppImage'),
      );
      expect(await File(userIconPath(home)).exists(), isTrue);

      // 再装一次结果相同(覆盖写, 不报错)
      final r2 = await installDesktopIntegration(
        appImagePath: '/home/u/Apps/MiniNCM.AppImage',
        home: home,
        executablePath: installedExe,
        refreshDatabase: false,
      );
      expect(r2.ok, isTrue);
    });

    test('AppDir 里没有图标也能装菜单入口(只是没图标)', () async {
      await File(bundledIconPath(installedExe)).delete();
      final r = await installDesktopIntegration(
        appImagePath: '/home/u/x.AppImage',
        home: home,
        executablePath: installedExe,
        refreshDatabase: false,
      );
      expect(r.ok, isTrue);
      expect(r.iconInstalled, isFalse);
      expect(await File(userDesktopEntryPath(home)).exists(), isTrue);
    });
  });

  group('探测 + 标记', () {
    late Directory tmp;
    late String home;
    late String dataDir;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ncm-probe-');
      home = '${tmp.path}/home';
      dataDir = '${tmp.path}/data';
      await Directory(home).create(recursive: true);
      await Directory(dataDir).create(recursive: true);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('AppImage 环境 + 没装过 => 需要提示', () async {
      final pending = await desktopIntegrationPending(
        dataDir: dataDir,
        env: {'APPIMAGE': '/home/u/x.AppImage', 'HOME': home},
        home: home,
      );
      // 本机是 Linux 才会有结果; 非 Linux 平台直接跳过(CI 是 Linux)
      if (!Platform.isLinux) return;
      expect(pending, isNotNull);
      expect(pending!.appImagePath, '/home/u/x.AppImage');
    });

    test('拒绝后落标记, 下次不再提示', () async {
      await markDesktopIntegrationAsked(dataDir);
      expect(
        await File(desktopIntegrationMarkerPath(dataDir)).exists(),
        isTrue,
      );
      final pending = await desktopIntegrationPending(
        dataDir: dataDir,
        env: {'APPIMAGE': '/home/u/x.AppImage', 'HOME': home},
        home: home,
      );
      expect(pending, isNull);
    });

    test('已存在用户级 desktop 文件时不再提示', () async {
      final f = File(userDesktopEntryPath(home));
      await f.parent.create(recursive: true);
      await f.writeAsString('[Desktop Entry]\n');
      final pending = await desktopIntegrationPending(
        dataDir: dataDir,
        env: {'APPIMAGE': '/home/u/x.AppImage', 'HOME': home},
        home: home,
      );
      expect(pending, isNull);
    });
  });
}
