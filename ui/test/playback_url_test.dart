import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playback.dart';

void main() {
  group('preferHttpsStreamUrl', () {
    test('明文 http 直链升级为 https, 保留 path 与 query', () {
      const url = 'http://m701.music.126.net/2026/x/a.mp3?vuutv=abc+def/ghi=';
      expect(
        preferHttpsStreamUrl(url),
        'https://m701.music.126.net/2026/x/a.mp3?vuutv=abc+def/ghi=',
      );
    });

    test('已经是 https 不动', () {
      const url = 'https://m801.music.126.net/1/a.flac?x=1';
      expect(preferHttpsStreamUrl(url), url);
    });

    test('非 http(s) 与不可解析串原样返回', () {
      expect(preferHttpsStreamUrl('file:///tmp/a.mp3'), 'file:///tmp/a.mp3');
      expect(preferHttpsStreamUrl('not a url'), 'not a url');
      expect(preferHttpsStreamUrl('http://'), 'http://');
    });

    // T2(2026-11-18): 只升网易域名族。第三方音源可能只有明文, 强行改 scheme
    // 等于把能播的源改坏 —— 这条锁住"非 163/126 域不动"。
    test('非网易域名不强行改(第三方源可能只有明文)', () {
      const third = 'http://cdn.example.com/a.mp3?x=1';
      expect(preferHttpsStreamUrl(third), third);
      // 只是后缀像也是别人的域, 不能被误判成网易
      const lookalike = 'http://notmusic.126.net.evil.com/a.mp3';
      expect(preferHttpsStreamUrl(lookalike), lookalike);
      expect(isNeteaseStreamHost('notmusic.126.net.evil.com'), isFalse);
      expect(isNeteaseStreamHost('m701.music.126.net'), isTrue);
      expect(isNeteaseStreamHost('interface3.music.163.com'), isTrue);
    });

    test('显式 :80 端口去掉, 其它显式端口保留', () {
      expect(
        preferHttpsStreamUrl('http://m7.music.126.net:80/a.mp3'),
        'https://m7.music.126.net/a.mp3',
      );
    });

    // 判定可注入: 将来接入新域名族只需换判定函数, 不用复制整个升级逻辑
    test('域名判定可注入', () {
      bool onlyExample(String host) => host.endsWith('example.com');
      expect(
        preferHttpsStreamUrl(
          'http://cdn.example.com/a.mp3',
          shouldUpgrade: onlyExample,
        ),
        'https://cdn.example.com/a.mp3',
      );
      expect(
        preferHttpsStreamUrl(
          'http://m7.music.126.net/a.mp3',
          shouldUpgrade: onlyExample,
        ),
        'http://m7.music.126.net/a.mp3',
      );
    });
  });
}
