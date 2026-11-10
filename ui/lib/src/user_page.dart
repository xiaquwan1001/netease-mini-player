import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'detail_page.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'toast.dart';

/// 他人主页(只读): 资料卡 + 公开歌单.
///
/// 为什么需要它: 听众列表(radio_subscribers_page)与关注/粉丝列表(user_list_page)
/// 早就能列出用户, 但点不动 —— 没有"用户主页"这个目的地. 数据面用
/// `user_profile`(user/detail, 匿名可用) + `user_playlists_of`(user/playlist).
///
/// 只读边界: 不做关注/取关、不发私信、不进对方"我喜欢的音乐"(私密歌单, 服务端也不会回).
class UserPage extends StatefulWidget {
  const UserPage({
    super.key,
    required this.userId,
    this.fallbackNickname,
    this.onPlaySongs,
    this.loadProfile,
    this.loadPlaylists,
  });

  final BigInt userId;
  final String? fallbackNickname;

  /// 点歌单后播放回调(宿主注入); 为空时歌单只展示不可播(测试/无播放器场景)
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  /// 测试注入
  final Future<rust.ProfileDetail> Function(BigInt uid)? loadProfile;
  final Future<List<rust.Playlist>> Function(BigInt uid)? loadPlaylists;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  rust.ProfileDetail? _detail;
  List<rust.Playlist>? _playlists;
  String? _error;
  bool _loading = true;

  Future<rust.ProfileDetail> Function(BigInt uid) get _loadProfile =>
      widget.loadProfile ?? (uid) => rust.userProfile(userId: uid);

  Future<List<rust.Playlist>> Function(BigInt uid) get _loadPlaylists =>
      widget.loadPlaylists ??
      (uid) => rust.userPlaylistsOf(userId: uid, limit: 50);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 资料与歌单互不阻塞: 任一失败不该让另一块空白
      final results = await Future.wait<Object?>([
        retryNetwork(() => _loadProfile(widget.userId)),
        retryNetwork(() => _loadPlaylists(widget.userId)),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as rust.ProfileDetail?;
        _playlists = results[1] as List<rust.Playlist>?;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _openPlaylist(rust.Playlist playlist) async {
    final play = widget.onPlaySongs;
    if (play == null) {
      showToast(context, '当前页面不支持播放');
      return;
    }
    await showPlaylistDetail(
      context,
      playlistId: playlist.id,
      name: playlist.name,
      coverUrl: playlist.coverUrl,
      special: playlist.special,
      onPlaySongs: play,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nickname = _detail?.nickname.isNotEmpty == true
        ? _detail!.nickname
        : (widget.fallbackNickname ?? '用户');
    return Scaffold(
      appBar: AppBar(title: Text(nickname)),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            12,
            8,
            12,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            _header(context, nickname),
            const SizedBox(height: 16),
            Text(
              'TA 的歌单',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            ..._playlistSection(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String nickname) {
    final theme = Theme.of(context);
    final d = _detail;
    final signature = d?.signature.trim() ?? '';
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 120,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (d?.backgroundUrl != null)
                  NetImage(
                    url: d!.backgroundUrl,
                    width: double.infinity,
                    height: 120,
                    fit: BoxFit.cover,
                  )
                else
                  ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black26, Colors.transparent, Colors.black54],
                      stops: [0, 0.4, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  bottom: 10,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: CircleCover(url: d?.avatarUrl, size: 52),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (signature.isNotEmpty)
                            SizedBox(
                              width: 200,
                              child: Text(
                                signature,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: Colors.white70),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              _loading && d == null
                  ? '加载中…'
                  : '关注 ${d?.follows ?? BigInt.zero} · 粉丝 ${d?.followeds ?? BigInt.zero}'
                      ' · Lv.${d?.level ?? BigInt.zero}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _playlistSection(BuildContext context) {
    if (_error != null && _playlists == null) {
      return [
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('加载失败'),
            subtitle: Text(_error!),
            trailing: TextButton(onPressed: _reload, child: const Text('重试')),
          ),
        ),
      ];
    }
    final lists = _playlists;
    if (lists == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (lists.isEmpty) {
      return const [
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(Icons.queue_music),
            title: Text('没有公开歌单'),
            subtitle: Text('对方可能没建过歌单, 或歌单都设为私密'),
          ),
        ),
      ];
    }
    return [
      Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            for (final p in lists.take(30))
              ListTile(
                leading: CoverArt(url: p.coverUrl, size: 44, radius: 6),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${p.trackCount} 首'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openPlaylist(p),
              ),
          ],
        ),
      ),
    ];
  }
}

/// 打开他人主页.
Future<void> showUserPage(
  BuildContext context, {
  required BigInt userId,
  String? fallbackNickname,
  void Function(List<rust.SongDto> songs, int index)? onPlaySongs,
  Future<rust.ProfileDetail> Function(BigInt uid)? loadProfile,
  Future<List<rust.Playlist>> Function(BigInt uid)? loadPlaylists,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UserPage(
        userId: userId,
        fallbackNickname: fallbackNickname,
        onPlaySongs: onPlaySongs,
        loadProfile: loadProfile,
        loadPlaylists: loadPlaylists,
      ),
    ),
  );
}
