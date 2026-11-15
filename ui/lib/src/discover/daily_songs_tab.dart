import 'package:flutter/material.dart';

import '../error_views.dart' show FullError;
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../song_actions.dart';
import '../state_views.dart';
import 'discover_song_row.dart' show DiscoverSongRow;
import 'discover_types.dart';

/// 「推荐歌曲」页签: 一次全量返回, 点歌只换队列、不退出日推页.
class DailySongsTab extends StatefulWidget {
  const DailySongsTab({super.key, required this.load, required this.onPlay});

  final SongListLoader load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  State<DailySongsTab> createState() => DailySongsTabState();
}

class DailySongsTabState extends State<DailySongsTab>
    with AutomaticKeepAliveClientMixin {
  List<rust.SongDto>? _songs;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final songs = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _songs = songs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final songs = _songs;
    if (_error != null) {
      return FullError(message: _error!, onRetry: _load);
    }
    if (songs == null) {
      return const LoadingView();
    }
    if (songs.isEmpty) {
      return const EmptyView(
        icon: Icons.music_note_outlined,
        title: '今天没有推荐歌曲',
      );
    }
    // 非分页: 每日推荐歌曲一次全量返回, 接口无分页
    return ListView.builder(
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final s = songs[i];
        return DiscoverSongRow(
          song: s,
          index: i + 1,
          // 每日推荐 tab: "..."菜单同样允许"不感兴趣"
          // 行尾不再放"不感兴趣"按钮: 它占掉 ~48dp 横向空间, 而同一动作
          // 已经在行尾「...」菜单里(SongActionSource.dailyRecommend 决定显示)。
          source: SongActionSource.dailyRecommend,
          // 点歌只开始播放, **不退出日推页**: 之前 `Navigator.pop` 会直接
          // 把整页弹掉, 用户想接着挑下一首还得重新进来(用户反馈)。与歌单详情页
          // (detail_page)一致: 列表页点播 = 换队列, 页面留在原地。
          onTap: s.playable ? () => widget.onPlay(songs, i) : null,
        );
      },
    );
  }
}
