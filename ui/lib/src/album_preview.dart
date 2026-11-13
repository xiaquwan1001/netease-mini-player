import 'package:flutter/material.dart';

import 'artist_page.dart';
import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'state_views.dart';
import 'toast.dart' show showToast;

typedef AlbumLoader = Future<rust.AlbumDetailDto> Function(BigInt albumId);

/// 专辑详情: 大图 + 专辑信息 + 曲目列表.
/// 点曲目 → 关闭本页, 用整张专辑重置播放队列并从这首开始.
/// loadAlbum 可注入(测试用), 默认走 Rust 接口.
///
/// 审查 P1-7.5: 原本是 [showDialog] 弹层(无 AppBar/无返回键, insetPadding 上下 32,
/// 小屏大字号把内容挤在圈里), 与同重量的歌单详情(全页 Scaffold)不一致;
/// 现改为全页 [Scaffold], 语义/注入点/回调整批曲目的行为完全保留。
Future<void> showAlbumPreview(
  BuildContext context, {
  required BigInt albumId,
  String? albumName,
  String? coverUrl,
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  AlbumLoader? loadAlbum,

  /// 从"收藏的专辑"进来时已知已收藏, 直接显示"已收藏"
  bool initiallySubscribed = false,

  /// 测试注入: 收藏/取消收藏
  Future<bool> Function(BigInt albumId, bool subscribed)? setSubscribed,

  /// 测试注入: 按艺人名解析 id(默认走 searchExact)
  Future<BigInt> Function(String name)? resolveArtistId,

  /// 测试注入: 打开艺人主页(默认 showArtistDetail)
  void Function(BigInt artistId, String name)? onOpenArtist,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AlbumPreviewPage(
        albumId: albumId,
        albumName: albumName,
        coverUrl: coverUrl,
        onPlay: onPlay,
        load: loadAlbum ?? (id) => rust.albumDetail(albumId: id),
        initiallySubscribed: initiallySubscribed,
        setSubscribed:
            setSubscribed ??
            (id, subscribed) =>
                rust.setAlbumSubscribed(albumId: id, subscribed: subscribed),
        resolveArtistId: resolveArtistId,
        onOpenArtist: onOpenArtist,
      ),
    ),
  );
}

/// 专辑详情全页(原 _AlbumPreviewDialog).
class AlbumPreviewPage extends StatefulWidget {
  const AlbumPreviewPage({
    super.key,
    required this.albumId,
    required this.albumName,
    required this.coverUrl,
    required this.onPlay,
    required this.load,
    required this.initiallySubscribed,
    required this.setSubscribed,
    this.resolveArtistId,
    this.onOpenArtist,
  });

  final BigInt albumId;
  final String? albumName;
  final String? coverUrl;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final AlbumLoader load;
  final bool initiallySubscribed;
  final Future<bool> Function(BigInt albumId, bool subscribed) setSubscribed;

  /// 按艺人名解析 id(测试注入; 默认 searchExact)
  final Future<BigInt> Function(String name)? resolveArtistId;

  /// 打开艺人主页(测试注入; 默认 showArtistDetail)
  final void Function(BigInt artistId, String name)? onOpenArtist;

  @override
  State<AlbumPreviewPage> createState() => _AlbumPreviewPageState();
}

class _AlbumPreviewPageState extends State<AlbumPreviewPage> {
  rust.AlbumDetailDto? _album;
  String? _error;
  bool _loading = false;

  /// 收藏状态: 由入参决定初值, 点按钮后本地翻转(没有可靠的"是否已收藏"查询接口)
  late bool _subscribed = widget.initiallySubscribed;
  bool _subBusy = false;
  String? _subError;

  @override
  void initState() {
    super.initState();
    if (widget.albumId > BigInt.zero) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final album = await retryNetwork(() => widget.load(widget.albumId));
      if (!mounted) return;
      setState(() => _album = album);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleSubscribe() async {
    final target = !_subscribed;
    setState(() {
      _subBusy = true;
      _subError = null;
    });
    try {
      final ok = await widget.setSubscribed(widget.albumId, target);
      if (!mounted) return;
      setState(() => _subscribed = ok ? target : _subscribed);
    } catch (e) {
      if (!mounted) return;
      setState(() => _subError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  /// 多艺人分隔符: "A / B"、"A、B"、"A & B" 都拆开
  List<String> _artistNames(rust.AlbumDetailDto album) => album.artist
      .split(RegExp(r'\s*(?:/|、|,|，|&|＆)\s*'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _openArtist(
    BuildContext context,
    rust.AlbumDetailDto album,
  ) async {
    final names = _artistNames(album);
    if (names.isEmpty) return;
    var name = names.first;
    if (names.length > 1) {
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择艺人'),
          children: [
            for (final n in names)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, n),
                child: Text(n),
              ),
          ],
        ),
      );
      if (picked == null || !context.mounted) return;
      name = picked;
    }
    // 单艺人且曲目里有 artistId: 不用联网解析
    var id = BigInt.zero;
    if (names.length == 1) {
      for (final s in album.songs) {
        if (s.artistId > BigInt.zero &&
            (s.artist == name || s.artist.contains(name))) {
          id = s.artistId;
          break;
        }
      }
    }
    if (id == BigInt.zero) {
      final resolve = widget.resolveArtistId;
      try {
        id = resolve != null
            ? await resolve(name)
            : await _searchArtistId(name);
      } catch (_) {
        id = BigInt.zero;
      }
    }
    if (!context.mounted) return;
    if (id == BigInt.zero) {
      showToast(context, '没有找到艺人「$name」');
      return;
    }
    final open = widget.onOpenArtist;
    if (open != null) {
      open(id, name);
      return;
    }
    await showArtistDetail(
      context,
      artistId: id,
      name: name,
      onPlaySongs: widget.onPlay,
    );
  }

  /// 按名字解析艺人 id(默认走精确搜索; 取同名或第一个命中)
  Future<BigInt> _searchArtistId(String name) async {
    final exact = await rust.searchExact(keywords: name);
    for (final a in exact.artists) {
      if (a.name == name) return a.id;
    }
    return exact.artists.isEmpty ? BigInt.zero : exact.artists.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    final name = album?.name ?? widget.albumName ?? '专辑';
    final cover = album?.coverUrl ?? widget.coverUrl;
    final songs = album?.songs ?? const <rust.SongDto>[];
    return Scaffold(
      // 全页骨架对齐歌单详情: AppBar 自带返回键, 破坏性/长内容不再挤在 Dialog 圈里
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CoverArt(url: cover, size: 120, radius: 10),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 专辑名只在 AppBar 出现一次(全页后正文不再重复标题)
                      // 艺人可点: 单艺人直接进主页, 多艺人先弹窗选择(用户要求)
                      InkWell(
                        onTap: album == null
                            ? null
                            : () => _openArtist(context, album),
                        borderRadius: BorderRadius.circular(4),
                        child: Text(
                          album?.artist ?? '未知艺人',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: album == null
                                    ? null
                                    : Theme.of(context).colorScheme.primary,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (songs.isNotEmpty)
                        Text(
                          '共 ${songs.length} 首',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (album != null && album.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          album.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (widget.albumId > BigInt.zero)
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: _subBusy ? null : _toggleSubscribe,
                              icon: Icon(
                                _subscribed
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 18,
                                color: _subscribed
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              label: Text(_subscribed ? '已收藏' : '收藏专辑'),
                            ),
                            if (_subBusy) const LoadingView.inline(size: 14),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_subError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                _subError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const Divider(height: 16),
          Expanded(child: _buildSongs(context, songs)),
        ],
      ),
    );
  }

  Widget _buildSongs(BuildContext context, List<rust.SongDto> songs) {
    if (_loading) {
      return const LoadingView();
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '专辑加载失败: $_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (songs.isEmpty) {
      return const EmptyView(
        icon: Icons.music_note_outlined,
        title: '这张专辑暂无曲目, 先去听听别的吧',
      );
    }
    // 非分页: 专辑曲目随专辑详情一次全量返回
    return ListView.builder(
      // 手势条留白(审查 P1-7.15: 全页列表要算底部 inset)
      padding: EdgeInsets.only(
        bottom: 12 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final s = songs[i];
        return ListTile(
          dense: true,
          leading: Text('${i + 1}'),
          title: SongTitleWithBadges(
            song: s,
            style: s.playable
                ? null
                : TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          subtitle: Text(
            s.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          enabled: s.playable,
          trailing: SongOverflowButton(
            song: s,
            size: 20,
            source: SongActionSource.album,
          ),
          onTap: s.playable
              ? () {
                  Navigator.pop(context);
                  widget.onPlay(songs, i);
                }
              : null,
        );
      },
    );
  }
}
