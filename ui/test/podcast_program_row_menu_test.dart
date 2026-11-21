// PodcastProgramRow 的长按 / 右键: 与行尾「...」同一个歌曲菜单(来源 radio)。
//
// 口径见 lib/src/detail/podcast_program_row.dart: 节目播放的就是它对应的曲目
// (program.song), 所以长按/右键唤出的是这首歌的统一动作面板; 没有音频本体的
// 节目(song == null)不响应。
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail/podcast_program_row.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/song_actions.dart';

import 'support/fakes.dart';

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

rust.PodcastProgramDto _program({rust.SongDto? song}) => rust.PodcastProgramDto(
  id: BigInt.from(901),
  name: '第 1 期 · 独立音乐现场',
  coverUrl: null,
  durationMs: BigInt.from(1800000),
  djName: '主播小林',
  radioId: BigInt.from(42666),
  radioName: '硬地电台',
  description: '本期聊独立音乐。',
  song: song,
);

Future<void> _pumpRow(WidgetTester tester, rust.PodcastProgramDto program) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AppActions(
        host: _FakeHost().host,
        child: Scaffold(
          body: PodcastProgramRow(program: program, onTap: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('长按节目行打开该集歌曲的菜单', (tester) async {
    await _pumpRow(tester, _program(song: fakeSong(id: 701, name: '第一期')));
    await tester.longPress(find.byType(PodcastProgramRow));
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('鼠标右键打开同一菜单', (tester) async {
    await _pumpRow(tester, _program(song: fakeSong(id: 701, name: '第一期')));
    await tester.tap(find.byType(PodcastProgramRow), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('没有音频本体的节目(song == null)长按不弹菜单', (tester) async {
    await _pumpRow(tester, _program());
    await tester.longPress(find.byType(PodcastProgramRow));
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });
}
