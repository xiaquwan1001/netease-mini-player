import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';

/// 歌手详情页: 横幅 + 简介(可展开) + 热门歌曲 + 专辑。
/// 打开方式: [showArtistDetail], 全屏 MaterialPageRoute。
Future<void> showArtistDetail(
  BuildContext context, {
  required BigInt artistId,
  String? name,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum,
  Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist, // 测试注入
  Future<List<rust.ArtistDto>> Function(BigInt)? loadSimilar, // 测试注入
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _ArtistDetailPage(
        artistId: artistId,
        name: name,
        onPlaySongs: onPlaySongs,
        onOpenAlbum: onOpenAlbum,
        loadArtist: loadArtist,
        loadSimilar: loadSimilar,
      ),
    ),
  );
}

class _ArtistDetailPage extends StatefulWidget {
  const _ArtistDetailPage({
    required this.artistId,
    required this.onPlaySongs,
    this.name,
    this.onOpenAlbum,
    this.loadArtist,
    this.loadSimilar,
  });

  final BigInt artistId;
  final String? name;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum;
  final Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist;
  final Future<List<rust.ArtistDto>> Function(BigInt)? loadSimilar;

  @override
  State<_ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<_ArtistDetailPage> {
  rust.ArtistDetailDto? _detail;
  String? _error;

  /// 相似歌手(需要登录; 拿不到就整块不显示, 不打扰其它内容)
  List<rust.ArtistDto> _similar = const [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadSimilar();
  }

  Future<void> _loadSimilar() async {
    try {
      final list = await (widget.loadSimilar != null
          ? widget.loadSimilar!(widget.artistId)
          : retryNetwork(() => rust.similarArtists(artistId: widget.artistId)));
      if (!mounted) return;
      setState(() => _similar = list);
    } catch (_) {
      // 未登录/接口不支持: 静默隐藏
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
    });
    try {
      final detail = widget.loadArtist != null
          ? await widget.loadArtist!(widget.artistId)
          : await retryNetwork(
              () => rust.artistDetail(artistId: widget.artistId),
            );
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.name ?? _detail?.name ?? '歌手详情')),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_detail == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final detail = _detail!;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _buildBanner(theme, detail),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${detail.albumCount} 个专辑 · ${detail.musicCount} 首歌曲',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (detail.briefDesc.trim().isNotEmpty)
                _ExpandableText(text: detail.briefDesc),
              if (detail.songs.isNotEmpty) _SectionTitle('热门歌曲'),
              ..._buildSongs(theme, detail.songs),
              if (detail.albums.isNotEmpty) _SectionTitle('专辑'),
              _buildAlbums(detail.albums),
              if (_similar.isNotEmpty) ...[
                _SectionTitle('相似歌手'),
                _buildSimilarArtists(theme),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 横幅: 封面 + 底部渐变, 叠加头像/名字/别名
  Widget _buildBanner(ThemeData theme, rust.ArtistDetailDto detail) {
    const bannerHeight = 170.0;
    return SizedBox(
      height: bannerHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          NetImage(
            url: detail.coverUrl,
            height: bannerHeight,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
          // 底部渐变保证白字可读
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54],
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 12,
            right: 16,
            child: Row(
              children: [
                CircleCover(url: detail.avatarUrl, size: 76),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        detail.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (detail.alias.isNotEmpty)
                        Text(
                          detail.alias.join(' / '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSongs(ThemeData theme, List<rust.SongDto> songs) {
    return [
      for (var i = 0; i < songs.length; i++)
        _ArtistSongRow(
          song: songs[i],
          index: i,
          onTap: () => widget.onPlaySongs(songs, i),
        ),
    ];
  }

  /// 相似歌手: 头像 + 名字的小胶囊, 点开进入对应歌手页
  Widget _buildSimilarArtists(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final a in _similar)
            ActionChip(
              avatar: CircleCover(url: a.avatarUrl, size: 24),
              label: Text(a.name),
              onPressed: () => showArtistDetail(
                context,
                artistId: a.id,
                name: a.name,
                onPlaySongs: widget.onPlaySongs,
                onOpenAlbum: widget.onOpenAlbum,
              ),
            ),
        ],
      ),
    );
  }

  /// 专辑: 横向滚动的封面卡片(118 宽, 行高 176)
  Widget _buildAlbums(List<rust.AlbumBriefDto> albums) {
    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final album = albums[i];
          final year = album.publishTime > BigInt.zero
              ? DateTime.fromMillisecondsSinceEpoch(album.publishTime.toInt())
                    .year
              : null;
          return SizedBox(
            width: 118,
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: widget.onOpenAlbum == null
                  ? null
                  : () => widget.onOpenAlbum!(
                      album.id,
                      album.name,
                      album.coverUrl,
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CoverArt(url: album.coverUrl, size: 118, radius: 6),
                  const SizedBox(height: 4),
                  Text(
                    album.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  if (year != null)
                    Text(
                      '$year',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 区块标题(热门歌曲 / 专辑)
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 热门歌曲行: 序号 + 歌名/歌手 + 时长 + SongOverflowButton。无版权灰显。
class _ArtistSongRow extends StatelessWidget {
  const _ArtistSongRow({
    required this.song,
    required this.index,
    required this.onTap,
  });

  final rust.SongDto song;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grey = TextStyle(color: scheme.outline);
    return InkWell(
      onTap: song.playable ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: song.playable ? theme.textTheme.bodyMedium : grey,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: song.playable
                          ? scheme.onSurfaceVariant
                          : scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _fmtDuration(song.durationMs),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
            SongOverflowButton(song: song, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 简介: 默认 3 行 + 展开/收起(与 detail_page 的 _ExpandableText 同思路)
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            widget.text.trim(),
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                _expanded ? '收起' : '展开',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 时长: mm:ss(超过 1 小时用 h:mm:ss), 与 detail_page 同一套格式
String _fmtDuration(BigInt ms) {
  final total = (ms ~/ BigInt.from(1000)).toInt();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
