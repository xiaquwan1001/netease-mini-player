import 'package:flutter/material.dart';

import '../cover_art.dart';
import '../error_views.dart' show FullError;
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../state_views.dart';
import 'discover_types.dart';

/// 「推荐歌单」页签: 一次全量返回, 点歌单先关本页再交给上层打开.
class DailyPlaylistsTab extends StatefulWidget {
  const DailyPlaylistsTab({
    super.key,
    required this.load,
    required this.onOpen,
  });

  final PlaylistListLoader load;
  final void Function(rust.Playlist playlist) onOpen;

  @override
  State<DailyPlaylistsTab> createState() => DailyPlaylistsTabState();
}

class DailyPlaylistsTabState extends State<DailyPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  List<rust.Playlist>? _lists;
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
      final lists = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _lists = lists);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lists = _lists;
    if (_error != null) {
      return FullError(message: '推荐歌单需要登录后才能获取\n$_error', onRetry: _load);
    }
    if (lists == null) {
      return const LoadingView();
    }
    if (lists.isEmpty) {
      return const EmptyView(
        icon: Icons.queue_music_outlined,
        title: '今天没有推荐歌单',
      );
    }
    // 非分页: 推荐歌单随一次请求全量返回, 接口无分页
    return ListView.builder(
      itemCount: lists.length,
      itemBuilder: (context, i) {
        final pl = lists[i];
        return ListTile(
          leading: CoverArt(url: pl.coverUrl, size: 48, radius: 6),
          title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${pl.trackCount} 首'),
          onTap: () {
            Navigator.pop(context);
            widget.onOpen(pl);
          },
        );
      },
    );
  }
}
