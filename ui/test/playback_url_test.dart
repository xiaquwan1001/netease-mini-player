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
  });
}
