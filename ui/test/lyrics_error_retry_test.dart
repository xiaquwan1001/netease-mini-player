// 歌词取数失败后的出口(2026-11 审计 V2)。
//
// 现象: 某首歌歌词请求失败后, 歌词页只有一行错误文本, 没有重试入口; 退出重进也不会
// 再发一次请求(只能切歌才可能恢复)。根因两条: `LyricController.load()` 在**发请求前**
// 就用 `_lyricTrackId` 占位 ⇒ 失败后同一首永远短路; 页面把错误当纯文本渲染。
//
// 这里断言页面侧的判据: 错误态必须给「重试」, 点它会真的再发一次取数
// (走 LyricController.retryLoad, 不另造四态组件)。测试环境没有 FFI, 取歌词必然
// 失败 —— 正好是"请求失败"的现场。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/auth.dart';
import 'package:minincm/src/detail_faces.dart' show DetailFace;
import 'package:minincm/src/home/account_actions.dart';
import 'package:minincm/src/home/lyric_controller.dart';
import 'package:minincm/src/home/lyrics_page.dart';
import 'package:minincm/src/playback.dart';

void main() {
  /// 歌词页正文只读歌单浏览态那几项, 其余回调全给 no-op。
  AccountActions accountActions(BuildContext Function() contextOf) =>
      AccountActions(
        contextOf: contextOf,
        isMounted: () => true,
        auth: Auth(),
        infoOf: () => null,
        setInfo: (_) {},
        dataDirOf: () async => null,
        toast: (_) {},
        toastError: (_) {},
        likedOf: () => <BigInt>{},
        markLiked: (_, _) {},
        setLiked: (_) {},
        clearLiked: () {},
        rebuildActionsHost: () {},
        setSearchBusy: (_) {},
        currentTrackIdOf: () => null,
        touchInteraction: (_, _) {},
      );

  testWidgets('歌词取数失败: 错误态带「重试」, 点了重新发一次请求', (tester) async {
    final lyric = LyricController(
      player: () => PlayerView(
        trackId: BigInt.from(42),
        playing: false,
        positionMs: BigInt.zero,
        durationMs: BigInt.zero,
        volume: 1,
      ),
      pollPlayer: () async {},
      itemExtentOf: () => 56,
      toast: (_) {},
    );
    addTearDown(lyric.dispose);
    await lyric.load(BigInt.from(42));
    expect(lyric.error, isNotNull, reason: '前置: 这次取歌词失败了');

    final face = ValueNotifier<DetailFace>(DetailFace.lyrics);
    addTearDown(face.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final page = HomeLyricsPage(
                lyric: lyric,
                account: accountActions(() => context),
                auth: Auth(),
                infoOf: () => null,
                currentOf: () => null,
                detailFace: face,
                storedDetailFace: () => DetailFace.lyrics,
                onDetailFaceChanged: (_) {},
                shareSong: ({List<String>? lyrics}) async {},
                shareSelectedLyrics: () async {},
                openComments: () {},
              );
              return page.buildBody(context);
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('重试'), findsOneWidget);

    final before = lyric.debugLoadCount;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(lyric.debugLoadCount, before + 1, reason: '重试必须真的再取一次');
  });
}
