import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_share.dart';
import 'package:qr_flutter/qr_flutter.dart';

rust.SongDto _song() => rust.SongDto(
  id: BigInt.from(186016),
  name: '晴天',
  artist: '周杰伦',
  artistId: BigInt.one,
  album: '叶惠美',
  albumId: BigInt.one,
  coverUrl: null,
  durationMs: BigInt.from(269000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

void main() {
  test('二维码内容指向官方网页', () {
    expect(
      songShareUrl(BigInt.from(186016)),
      'https://music.163.com/song?id=186016',
    );
  });

  test('分享歌词: 过滤空行/♪ 并截断到上限', () {
    expect(shareableLyricLines(['  ', '♪', ' 第一句 ', '']), ['第一句']);
    expect(shareableLyricLines(List.generate(10, (i) => 'l$i')), [
      'l0',
      'l1',
      'l2',
      'l3',
      'l4',
      'l5',
    ]);
  });

  group('SongShareCard', () {
    testWidgets('渲染曲名/歌手/歌词/二维码', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongShareCard(song: _song(), lyricLines: const ['故事的小黄花']),
          ),
        ),
      );
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.text('故事的小黄花'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('300dp 窄屏不溢出', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(300, 640);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SongShareCard(
                song: _song(),
                lyricLines: const ['故事的小黄花', '从出生那年就飘着'],
                width: 300,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('RepaintBoundary 能导出 PNG 字节', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: SongShareCard(
                  song: _song(),
                  lyricLines: const ['故事的小黄花'],
                ),
              ),
            ),
          ),
        ),
      );
      Uint8List? png;
      await tester.runAsync(() async {
        png = await capturePng(key, pixelRatio: 1);
      });
      expect(png, isNotNull);
      // PNG 魔数
      expect(png!.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    });
  });

  testWidgets('分享面板: 预览 + 分享/保存/复制链接', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showSongShareSheet(
                  context,
                  song: _song(),
                  lyricLines: const ['故事的小黄花'],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('分享歌曲'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);

    await tester.tap(find.text('复制链接'));
    await tester.pumpAndSettle();
    expect(copied, 'https://music.163.com/song?id=186016');
  });
}
