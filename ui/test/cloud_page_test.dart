import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cloud_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.CloudSong _song(
  int id, {
  String name = '云盘歌曲',
  String artist = '歌手A',
  int size = 4000000,
}) {
  return rust.CloudSong(
    id: BigInt.from(id),
    songId: BigInt.from(id + 1000),
    name: name,
    artist: artist,
    album: '专辑',
    coverUrl: 'http://p1.music.126.net/c.jpg',
    size: BigInt.from(size),
    bitrate: BigInt.from(320000),
    addTime: BigInt.from(1700000000000),
  );
}

rust.CloudPage _page(
  List<rust.CloudSong> songs, {
  bool more = false,
  int count = 1,
}) {
  return rust.CloudPage(
    songs: songs,
    count: BigInt.from(count),
    size: BigInt.from(7000000),
    maxSize: BigInt.from(64424509440),
    more: more,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required CloudPageLoader loadPage,
  CloudDeleter? deleteSongs,
  void Function(rust.CloudSong song)? onPlay,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CloudPage(
        loadPage: loadPage,
        deleteSongs: deleteSongs,
        onPlay: onPlay,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('formatBytes', () {
    test('按 1024 进制给一位小数, 0 字节给空串', () {
      expect(formatBytes(0), '');
      expect(formatBytes(-1), '');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(4000000), '3.8 MB');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });
  });

  testWidgets('列表: 显示歌名/歌手/大小, 有容量说明行', (tester) async {
    await _pump(
      tester,
      loadPage: (limit, offset) async =>
          _page(<rust.CloudSong>[_song(11, name: '云盘里的歌')]),
    );

    expect(find.text('音乐云盘'), findsOneWidget);
    expect(find.text('云盘里的歌'), findsOneWidget);
    expect(find.text('歌手A · 3.8 MB'), findsOneWidget);
    // 容量行: 1 首 · 已用 6.7 MB · 共 60.0 GB
    expect(find.textContaining('1 首'), findsOneWidget);
    expect(find.textContaining('已用'), findsOneWidget);
  });

  testWidgets('空态: 云盘没歌时给空态文案', (tester) async {
    await _pump(tester, loadPage: (limit, offset) async => _page(<rust.CloudSong>[]));
    expect(find.text('云盘还没有歌曲(上传请在官方客户端进行)'), findsOneWidget);
  });

  testWidgets('错误态: 首屏失败给错误文案+重试, 重试成功后出列表', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      loadPage: (limit, offset) async {
        calls += 1;
        // 用非 network 错误: network 会被 friendlyError 换成固定文案
        if (calls == 1) throw Exception('[internal] boom');
        return _page(<rust.CloudSong>[_song(11)]);
      },
    );
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('云盘歌曲'), findsOneWidget);
  });

  testWidgets('加载更多: more=true 时显示按钮, 点击追加下一页', (tester) async {
    final offsets = <int>[];
    await _pump(
      tester,
      loadPage: (limit, offset) async {
        offsets.add(offset);
        if (offset == 0) {
          return _page(<rust.CloudSong>[_song(1, name: '第一页')], more: true);
        }
        return _page(<rust.CloudSong>[_song(2, name: '第二页')]);
      },
    );

    expect(find.text('第一页'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    expect(offsets, <int>[0, 1], reason: '第二次请求的 offset 应该是已加载条数');
    expect(find.text('第一页'), findsOneWidget, reason: '追加而不是替换');
    expect(find.text('第二页'), findsOneWidget);
    expect(find.text('已全部加载'), findsOneWidget);
  });

  testWidgets('删除: 确认后调用删除回调并把行移除', (tester) async {
    final requested = <List<int>>[];
    await _pump(
      tester,
      loadPage: (limit, offset) async => _page(<rust.CloudSong>[
        _song(11, name: '要删的歌'),
        _song(12, name: '留着的歌'),
      ]),
      deleteSongs: (Uint64List ids) async {
        requested.add(ids.map((v) => v.toInt()).toList());
        return true;
      },
    );

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('要删的歌'), findsWidgets);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(requested, <List<int>>[
      <int>[11],
    ], reason: '删除用云盘条目 id');
    expect(find.text('要删的歌'), findsNothing);
    expect(find.text('留着的歌'), findsOneWidget);
    expect(find.text('已从云盘删除'), findsOneWidget);
  });

  testWidgets('删除: 取消时不调用回调', (tester) async {
    var called = 0;
    await _pump(
      tester,
      loadPage: (limit, offset) async =>
          _page(<rust.CloudSong>[_song(11, name: '要删的歌')]),
      deleteSongs: (Uint64List ids) async {
        called += 1;
        return true;
      },
    );

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(called, 0);
    expect(find.text('要删的歌'), findsOneWidget);
  });

  testWidgets('点击播放: 把该行条目交给注入的播放回调', (tester) async {
    final played = <String>[];
    await _pump(
      tester,
      loadPage: (limit, offset) async => _page(<rust.CloudSong>[
        _song(11, name: '点我播放'),
      ]),
      onPlay: (song) => played.add(song.name),
    );

    await tester.tap(find.text('点我播放'));
    await tester.pumpAndSettle();
    expect(played, <String>['点我播放']);
  });

  testWidgets('下拉刷新: 重新从 offset 0 拉一页', (tester) async {
    final offsets = <int>[];
    await _pump(
      tester,
      loadPage: (limit, offset) async {
        offsets.add(offset);
        return _page(<rust.CloudSong>[
          _song(11, name: offsets.length == 1 ? '旧歌' : '新歌'),
        ]);
      },
    );

    expect(find.text('旧歌'), findsOneWidget);
    await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
    await tester.pumpAndSettle();

    expect(offsets, <int>[0, 0]);
    expect(find.text('新歌'), findsOneWidget);
    expect(find.text('旧歌'), findsNothing);
  });
}
