import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 动作回调集合(由 main.dart 组装, 行组件通过 AppActions 取)
class SongActionHost {
  const SongActionHost({
    required this.loggedIn,
    required this.isLiked,
    required this.toggleLike,
    required this.playNext,
    required this.addToPlaylist,
    required this.share,
    required this.comments,
    required this.openArtist,
    required this.openAlbum,
    required this.download,
    this.similarSongs,
    this.dislike,
    this.songWiki,
  });

  /// 是否已登录(收藏/喜欢仍会回调, 未登录由调用方提示)
  final bool loggedIn;

  /// 该歌曲当前是否已喜欢
  final bool Function(BigInt? trackId) isLiked;

  /// 喜欢/取消喜欢
  final Future<void> Function(rust.SongDto song) toggleLike;

  /// 下一首播放
  final Future<void> Function(rust.SongDto song) playNext;

  /// 收藏到歌单
  final Future<void> Function(rust.SongDto song) addToPlaylist;

  /// 分享
  final Future<void> Function(rust.SongDto song) share;

  /// 查看评论
  final Future<void> Function(rust.SongDto song) comments;

  /// 歌手信息
  final Future<void> Function(rust.SongDto song) openArtist;

  /// 专辑信息
  final Future<void> Function(rust.SongDto song) openAlbum;

  /// 下载
  final Future<void> Function(rust.SongDto song) download;

  /// 相似歌曲(不传就不显示这一项)
  final Future<void> Function(rust.SongDto song)? similarSongs;

  /// 不感兴趣(每日推荐/FM; 不传就不显示这一项)
  final Future<void> Function(rust.SongDto song)? dislike;

  /// 歌曲百科(曲风/语种/BPM/获奖; 不传就不显示这一项)
  final Future<void> Function(rust.SongDto song)? songWiki;
}

/// InheritedWidget: 任一子树里的 SongOverflowButton 自动拿到 host
class AppActions extends InheritedWidget {
  const AppActions({super.key, required this.host, required super.child});

  final SongActionHost host;

  /// 从子树取 host, 不存在时返回 null
  static SongActionHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppActions>()?.host;

  @override
  bool updateShouldNotify(AppActions oldWidget) => host != oldWidget.host;
}

/// 行尾 "..." 按钮; host 为空(只从参数/Inherited 取)时渲染 SizedBox.shrink()
class SongOverflowButton extends StatelessWidget {
  const SongOverflowButton({
    super.key,
    required this.song,
    this.host,
    this.size = 20,
  });

  final rust.SongDto song;

  /// 显式传入时优先于 InheritedWidget
  final SongActionHost? host;
  final double size;

  @override
  Widget build(BuildContext context) {
    // 没有任何 host(参数与 Inherited 都没有)时干脆不占位
    final SongActionHost? h = host ?? AppActions.maybeOf(context);
    if (h == null) return const SizedBox.shrink();
    return IconButton(
      icon: Icon(Icons.more_vert, size: size),
      tooltip: '更多操作',
      onPressed: () => showSongActionsSheet(context, song, h),
    );
  }
}

/// 底部动作面板
Future<void> showSongActionsSheet(
  BuildContext context,
  rust.SongDto song,
  SongActionHost host,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      // 8 个动作 + 头部在矮屏会超过半屏, 用可滚动面板兜住
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _menu(sheetContext, song, host),
          ),
        ),
      ),
    ),
  );
}

/// 面板菜单项列表
List<Widget> _menu(
  BuildContext context,
  rust.SongDto song,
  SongActionHost host,
) {
  final colorScheme = Theme.of(context).colorScheme;
  final liked = host.isLiked(song.id);

  // 点击统一流程: 先关面板, 再执行回调; 失败时用 ScaffoldMessenger 提示
  // 先取 messenger 再关面板: 面板 pop 后 context 可能已失效
  final messenger = ScaffoldMessenger.maybeOf(context);
  Future<void> run(Future<void> Function() action) async {
    Navigator.pop(context);
    try {
      await action();
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('操作失败: ${friendlyError(e)}')));
    }
  }

  // artistId/albumId 为 0 表示未知, 对应入口禁用(文案灰色)
  final artistEnabled = song.artistId != BigInt.zero;
  final albumEnabled = song.albumId != BigInt.zero;

  return [
    // 顶部: 封面 + 歌名 + 歌手
    ListTile(
      leading: CoverArt(url: song.coverUrl, size: 40, radius: 4),
      title: Text(song.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    ListTile(
      leading: const Icon(Icons.queue_play_next),
      title: const Text('下一首播放'),
      onTap: () => run(() => host.playNext(song)),
    ),
    ListTile(
      leading: Icon(liked ? Icons.favorite : Icons.favorite_border),
      title: Text(liked ? '取消喜欢' : '喜欢'),
      // 未登录也显示, 由 host 回调方提示登录
      onTap: () => run(() => host.toggleLike(song)),
    ),
    ListTile(
      leading: const Icon(Icons.playlist_add),
      title: const Text('收藏到歌单'),
      onTap: () => run(() => host.addToPlaylist(song)),
    ),
    ListTile(
      leading: const Icon(Icons.share_outlined),
      title: const Text('分享'),
      onTap: () => run(() => host.share(song)),
    ),
    ListTile(
      leading: const Icon(Icons.comment_outlined),
      title: const Text('查看评论'),
      onTap: () => run(() => host.comments(song)),
    ),
    ListTile(
      leading: const Icon(Icons.person_outline),
      title: Text(
        '歌手信息',
        style: artistEnabled ? null : TextStyle(color: colorScheme.outline),
      ),
      onTap: artistEnabled ? () => run(() => host.openArtist(song)) : null,
    ),
    if (host.dislike != null)
      ListTile(
        leading: const Icon(Icons.do_not_disturb_on_outlined),
        title: const Text('不感兴趣'),
        subtitle: const Text('少推这类歌(日推/FM)'),
        onTap: () => run(() => host.dislike!(song)),
      ),
    if (host.similarSongs != null)
      ListTile(
        leading: const Icon(Icons.auto_awesome_motion_outlined),
        title: const Text('相似歌曲'),
        onTap: () => run(() => host.similarSongs!(song)),
      ),
    if (host.songWiki != null)
      ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('歌曲百科'),
        subtitle: const Text('曲风/语种/BPM/获奖成就'),
        onTap: () => run(() => host.songWiki!(song)),
      ),
    ListTile(
      leading: const Icon(Icons.album_outlined),
      title: Text(
        '专辑信息',
        style: albumEnabled ? null : TextStyle(color: colorScheme.outline),
      ),
      onTap: albumEnabled ? () => run(() => host.openAlbum(song)) : null,
    ),
    ListTile(
      leading: const Icon(Icons.download_outlined),
      title: const Text('下载'),
      onTap: () => run(() => host.download(song)),
    ),
  ];
}
