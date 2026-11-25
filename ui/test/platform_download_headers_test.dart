// 桌面下载的请求头口径(2026-11-25 审计 D12) + 「是 Android」唯一入口(D14)。
//
// D12: 同一个"下载直链"动作有三条路(Rust 边下边播 / Android DownloadManager /
// 桌面 curl)。前两条都带 `Referer: https://music.163.com/`, 桌面 curl 以前只发
// `-L --fail` 且不传 UA ⇒ CDN 403, "能播不能下载"。这里锁住桌面侧的参数拼装。
//
// D14: 8 个文件各写一份 `Platform.isAndroid`; 统一入口在 `platform_is.dart`
// (本机 flutter test 跑在 Linux, 正好能验"非 Android + 可强制")。
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/platform.dart'
    show desktopCurlDownloadArgs, kMusic163Referer;
import 'package:minincm/src/platform_is.dart'
    show debugForceAndroid, isAndroidPlatform;

void main() {
  group('desktopCurlDownloadArgs: 与安卓/Rust 侧同请求头', () {
    test('必带 Referer(常量与 Rust 的 DOWNLOAD_REFERER 同值)', () {
      expect(kMusic163Referer, 'https://music.163.com/');
      final args = desktopCurlDownloadArgs(
        url: 'https://m701.music.126.net/x.mp3',
        path: '/home/u/Downloads/a.mp3',
      );
      expect(args, containsAllInOrder(['-H', 'Referer: $kMusic163Referer']));
      expect(args.last, 'https://m701.music.126.net/x.mp3');
      expect(args, containsAllInOrder(['-o', '/home/u/Downloads/a.mp3']));
      expect(args, contains('-L'));
      expect(args, contains('--fail'));
    });

    test('UA 有则透传(-A), 没有就不发', () {
      final withUa = desktopCurlDownloadArgs(
        url: 'https://cdn/x.flac',
        path: '/tmp/x.flac',
        userAgent: 'Mozilla/5.0 (test)',
      );
      expect(withUa, containsAllInOrder(['-A', 'Mozilla/5.0 (test)']));

      final noUa = desktopCurlDownloadArgs(
        url: 'https://cdn/x.flac',
        path: '/tmp/x.flac',
      );
      expect(noUa, isNot(contains('-A')));
    });
  });

  group('isAndroidPlatform: 单一入口 + 测试强制开关', () {
    test('本机(flutter test 跑在 Linux)不是 Android', () {
      expect(isAndroidPlatform, isFalse);
    });

    test('debugForceAndroid 置 true 后走 Android 分支, 复位后回到平台判定', () {
      expect(debugForceAndroid, isFalse, reason: '默认必须是关的');
      debugForceAndroid = true;
      expect(isAndroidPlatform, isTrue);
      debugForceAndroid = false;
      expect(isAndroidPlatform, isFalse);
    });
  });
}
