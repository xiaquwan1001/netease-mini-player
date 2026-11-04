import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart';

void main() {
  group('httpsImageUrl', () {
    test('明文 http 升级为 https', () {
      expect(
        httpsImageUrl('http://p3.music.126.net/a/b.jpg'),
        'https://p3.music.126.net/a/b.jpg',
      );
    });

    test('https 与非 http 原样返回', () {
      const https = 'https://p3.music.126.net/a/b.jpg';
      expect(httpsImageUrl(https), https);
      expect(httpsImageUrl('file:///tmp/a.jpg'), 'file:///tmp/a.jpg');
    });

    test('空值返回空串', () {
      expect(httpsImageUrl(null), '');
      expect(httpsImageUrl(''), '');
    });

    test('不可解析的串原样返回', () {
      expect(httpsImageUrl('not a url'), 'not a url');
      expect(httpsImageUrl('http://'), 'http://');
    });
  });
}
