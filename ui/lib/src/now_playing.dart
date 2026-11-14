import 'package:flutter/widgets.dart';

/// 当前正在播放的曲目 id(全局唯一样本).
///
/// 用户反馈(2026-11-14): 「完整日推歌单里, 正在播放的那首没有被高亮标记」——
/// 根因是每个列表页各自持有"正在播放"的来源(有的从页面参数传 currentTrackId,
/// 有的干脆没传), 少接一处就不高亮。现在改成**一处投递、所有行读同一个值**:
///
/// - [HomePage] 每次构建把当前曲目 id 帧后写进 [nowPlayingSongId](见 _publishPlayerBar);
/// - 行组件用 [NowPlayingHighlight] 包一层, 命中就按"正在播放"样式渲染。
///
/// 只放 id 不放整个 SongDto: 行里已经有自己的数据, 需要的只是"是不是这首"。
final ValueNotifier<BigInt?> nowPlayingSongId = ValueNotifier<BigInt?>(null);

/// 行级高亮: 监听全局"正在播放", 命中 [songId] 时让调用方按播放态渲染。
///
/// 用法(行组件内部): `return NowPlayingHighlight(songId: song.id, builder: (context, playing) => ...);`
/// 播客节目行同理: 节目拿到它对应的曲目 id(通常 mainSong.id) 后判断.
class NowPlayingHighlight extends StatelessWidget {
  const NowPlayingHighlight({
    super.key,
    required this.songId,
    required this.builder,
  });

  /// 这一行对应的曲目 id; null/0 视为不可播放, 永远不高亮
  final BigInt? songId;
  final Widget Function(BuildContext context, bool playing) builder;

  @override
  Widget build(BuildContext context) {
    final target = songId;
    if (target == null || target == BigInt.zero) {
      return builder(context, false);
    }
    return ValueListenableBuilder<BigInt?>(
      valueListenable: nowPlayingSongId,
      builder: (context, current, _) =>
          builder(context, current != null && current == target),
    );
  }
}
