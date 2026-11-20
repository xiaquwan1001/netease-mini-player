import 'package:minincm/src/playback_bridge.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/song_actions.dart' show SongActionSource;

/// 播放探针: 用 [PlaybackBridge.debugOverride] 截获页面内的点播。
///
/// "onPlaySongs 收成 PlaybackBridge 单入口"(2026-11)之后, 页面不再接收播放回调,
/// 测试也就不能再用构造参数注入假实现 —— 统一改用这里:
///
/// ```dart
/// List<rust.SongDto>? played;
/// int? playedIndex;
/// installPlaybackSpy((songs, index) {
///   played = songs;
///   playedIndex = index;
/// }, onNext: ...);
/// addTearDown(resetPlaybackSpy);
/// ```
void installPlaybackSpy(
  void Function(List<rust.SongDto> songs, int index) onPlaySongs, {

  /// 需要断言 playlistId / source 时用这个重载(心动模式、不感兴趣路由)
  void Function(List<rust.SongDto> songs, int index, BigInt? playlistId)?
  onPlaySongsWithPlaylist,

  /// 歌单内搜索"只添加当前歌"的断言(PlaybackBridge.appendNext)
  void Function(rust.SongDto song)? onAppendNext,
}) {
  PlaybackBridge.instance.debugOverride(
    playSongs:
        (songs, index, {playlistId, source = SongActionSource.other}) async {
          onPlaySongsWithPlaylist?.call(songs, index, playlistId);
          onPlaySongs(songs, index);
        },
    appendNext: onAppendNext == null
        ? null
        : (song) async => onAppendNext(song),
  );
}

/// 清掉 [installPlaybackSpy] 注入的假实现(测试收尾; 全局单例不能跨用例串味)。
void resetPlaybackSpy() => PlaybackBridge.instance.resetDebugOverride();
