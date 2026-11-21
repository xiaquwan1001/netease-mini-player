// SongRow 的「行尾三点 / 长按 / 右键」统一口径(2026-11-22 用户反馈第 1 条)。
//
// 口径见 lib/src/song_tile.dart 的 SongRow:
//   · menuSource 默认 SongActionSource.other ⇒ 所有歌曲列表行默认带行尾「...」;
//     显式传 null 才关闭(无版权曲目的调用点用它);
//   · onLongPress == null 时长按与鼠标右键走同一份菜单: onMenu 优先, 否则
//     showSongActionsSheet(..., menuSource); 显式 onLongPress(多选语义)不被覆盖;
//   · onMenu 与 menuSource 二选一, 不会画出两个「...」。
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/song_actions.dart';
import 'package:minincm/src/song_tile.dart';

import 'support/fakes.dart';

/// 最小动作宿主: 只关心"菜单打开没有", 各回调都记账不联网。
class _FakeHost {
  int playNextCalls = 0;

  late final SongActionHost host = SongActionHost(
    loggedIn: true,
    isLiked: (_) => false,
    toggleLike: (_) async {},
    playNext: (_) async => playNextCalls++,
    addToPlaylist: (_) async {},
    share: (_) async {},
    comments: (_) async {},
    openArtist: (_) async {},
    openAlbum: (_) async {},
    download: (_) async {},
  );
}

rust.SongDto _song() => fakeSong(id: 42, name: '测试歌曲', durationMs: 200000);

Future<void> _pumpRow(WidgetTester tester, Widget row) async {
  tester.view.physicalSize = const Size(420, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: AppActions(
        host: _FakeHost().host,
        child: Scaffold(body: row),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('工厂行默认渲染行尾三点, 点开出现「下一首播放」', (tester) async {
    await _pumpRow(
      tester,
      SongRow.pageIndexed(
        song: _song(),
        indexText: '1',
        onTap: () {},
      ),
    );

    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('自绘臂长按打开菜单(未传 onLongPress)', (tester) async {
    await _pumpRow(tester, SongRow(song: _song(), onTap: () {}));
    await tester.longPress(find.byType(SongRow));
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('ListTile 臂长按打开菜单(未传 onLongPress)', (tester) async {
    await _pumpRow(
      tester,
      SongRow(song: _song(), layout: SongRowLayout.tile, onTap: () {}),
    );
    await tester.longPress(find.byType(SongRow));
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('自绘臂鼠标右键(secondary tap)打开同一菜单', (tester) async {
    await _pumpRow(tester, SongRow(song: _song(), onTap: () {}));
    await tester.tap(find.byType(SongRow), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('ListTile 臂鼠标右键(secondary tap)打开同一菜单', (tester) async {
    await _pumpRow(
      tester,
      SongRow(song: _song(), layout: SongRowLayout.tile, onTap: () {}),
    );
    await tester.tap(find.byType(SongRow), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('显式 onLongPress(多选语义)不被菜单覆盖', (tester) async {
    var longPresses = 0;
    await _pumpRow(
      tester,
      SongRow(
        song: _song(),
        onTap: () {},
        onLongPress: () => longPresses++,
      ),
    );
    await tester.longPress(find.byType(SongRow));
    await tester.pumpAndSettle();
    expect(longPresses, 1);
    expect(find.text('下一首播放'), findsNothing);
  });

  testWidgets('显式 menuSource: null 时不渲染三点, 长按也不弹菜单', (tester) async {
    await _pumpRow(
      tester,
      SongRow(
        song: _song(),
        menuSource: null,
        onTap: () {},
      ),
    );
    expect(find.byIcon(Icons.more_vert), findsNothing);
    await tester.longPress(find.byType(SongRow));
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('onMenu 与默认 menuSource 并存时只有一个「...」', (tester) async {
    var menuCalls = 0;
    await _pumpRow(
      tester,
      SongRow(
        song: _song(),
        onMenu: () => menuCalls++,
        onTap: () {},
      ),
    );
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    expect(menuCalls, 1);
  });
}
