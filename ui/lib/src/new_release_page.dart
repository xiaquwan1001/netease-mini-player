import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;

typedef AreaSongLoader = Future<List<rust.SongDto>> Function(String area);
typedef AreaAlbumLoader = Future<List<rust.AlbumItemDto>> Function(String area);
typedef HotArtistLoader = Future<List<rust.HotArtistDto>> Function();
typedef NewestAlbumLoader = Future<List<rust.AlbumItemDto>> Function();

/// 地区选项: key 传给 Rust(area 简写), label 给 UI
const List<({String key, String label})> releaseAreas = [
  (key: 'all', label: '全部'),
  (key: 'zh', label: '华语'),
  (key: 'ea', label: '欧美'),
  (key: 'jp', label: '日本'),
  (key: 'kr', label: '韩国'),
];

/// 新歌 / 新碟 / 热门歌手 三个页签的"更多"页.
/// 新歌=top_song(按地区 areaId), 新碟=top_album(weekData+monthData 合并), 歌手=top_artists.
Future<void> showNewReleasePage(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  required void Function(rust.AlbumItemDto album) onOpenAlbum,
  required void Function(rust.HotArtistDto artist) onOpenArtist,
  AreaSongLoader? loadSongs,
  AreaAlbumLoader? loadAlbums,
  HotArtistLoader? loadArtists,
  NewestAlbumLoader? loadNewestAlbums,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NewReleasePage(
        onPlaySongs: onPlaySongs,
        onOpenAlbum: onOpenAlbum,
        onOpenArtist: onOpenArtist,
        loadSongs: loadSongs,
        loadAlbums: loadAlbums,
        loadArtists: loadArtists,
        loadNewestAlbums: loadNewestAlbums,
      ),
    ),
  );
}

class NewReleasePage extends StatelessWidget {
  const NewReleasePage({
    super.key,
    required this.onPlaySongs,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    this.loadSongs,
    this.loadAlbums,
    this.loadArtists,
    this.loadNewestAlbums,
  });

  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.AlbumItemDto album) onOpenAlbum;
  final void Function(rust.HotArtistDto artist) onOpenArtist;
  final AreaSongLoader? loadSongs;
  final AreaAlbumLoader? loadAlbums;
  final HotArtistLoader? loadArtists;

  /// "精选新碟"页签(album_newest, 固定 12 张, 无地区/分页); 可注入(测试用)
  final NewestAlbumLoader? loadNewestAlbums;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('新歌 · 新碟 · 歌手'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '新歌'),
              Tab(text: '新碟'),
              Tab(text: '歌手'),
              Tab(text: '精选新碟'),
            ],
          ),
        ),
        // P1-7.15: 底部让出手势导航条
        body: SafeArea(
          top: false,
          child: TabBarView(
            children: [
            _NewSongsTab(
              load: loadSongs ??
                  (area) => rust.newSongsByArea(area: area, limit: 50),
              onPlay: onPlaySongs,
            ),
            _NewAlbumsTab(
              load: loadAlbums ??
                  (area) => rust.newAlbumsByArea(area: area, limit: 30),
              onOpen: onOpenAlbum,
            ),
            _HotArtistsTab(
              load: loadArtists ?? () => rust.hotArtists(limit: 50, offset: 0),
              onOpen: onOpenArtist,
            ),
            _NewestAlbumsTab(
              load: loadNewestAlbums ?? () => rust.newestAlbums(limit: 12),
              onOpen: onOpenAlbum,
            ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 地区筛选条
class _AreaChips extends StatelessWidget {
  const _AreaChips({required this.value, required this.onChange});

  final String value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          for (final a in releaseAreas)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(a.label),
                selected: value == a.key,
                onSelected: (_) => onChange(a.key),
              ),
            ),
        ],
      ),
    );
  }
}

class _NewSongsTab extends StatefulWidget {
  const _NewSongsTab({required this.load, required this.onPlay});

  final AreaSongLoader load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  State<_NewSongsTab> createState() => _NewSongsTabState();
}

class _NewSongsTabState extends State<_NewSongsTab> {
  String _area = 'all';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _AreaChips(
          value: _area,
          onChange: (area) {
            if (area == _area) return;
            setState(() => _area = area);
          },
        ),
        Expanded(
          // PagedListView 非分页模式: loader 恒 hasMore:false, 三态壳交给组件
          child: PagedListView<rust.SongDto>(
            key: ValueKey(_area),
            refreshable: false,
            emptyText: '这个地区暂时没有新歌',
            loader: (cursor) async => PagedPage(
              await retryNetwork(() => widget.load(_area)),
              hasMore: false,
            ),
            itemBuilder: (context, s, i, songs) => ListTile(
              dense: true,
              leading: CoverArt(url: s.coverUrl, size: 44, radius: 4),
              title: Text(
                s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                s.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                _duration(s.durationMs),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              onTap: s.playable ? () => widget.onPlay(songs, i) : null,
            ),
          ),
        ),
      ],
    );
  }

  String _duration(BigInt ms) {
    if (ms <= BigInt.zero) return '';
    final total = ms.toInt() ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

class _NewAlbumsTab extends StatefulWidget {
  const _NewAlbumsTab({required this.load, required this.onOpen});

  final AreaAlbumLoader load;
  final void Function(rust.AlbumItemDto album) onOpen;

  @override
  State<_NewAlbumsTab> createState() => _NewAlbumsTabState();
}

class _NewAlbumsTabState extends State<_NewAlbumsTab> {
  String _area = 'all';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _AreaChips(
          value: _area,
          onChange: (area) {
            if (area == _area) return;
            setState(() => _area = area);
          },
        ),
        Expanded(
          child: PagedListView<rust.AlbumItemDto>(
            key: ValueKey(_area),
            refreshable: false,
            emptyText: '这个地区暂时没有新碟',
            loader: (cursor) async => PagedPage(
              await retryNetwork(() => widget.load(_area)),
              hasMore: false,
            ),
            itemBuilder: (context, a, i, albums) => ListTile(
              leading: CoverArt(url: a.coverUrl, size: 52, radius: 6),
              title: Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (a.artist.isNotEmpty) a.artist,
                  if (a.trackCount > BigInt.zero) '${a.trackCount} 首',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => widget.onOpen(a),
            ),
          ),
        ),
      ],
    );
  }
}

class _HotArtistsTab extends StatelessWidget {
  const _HotArtistsTab({required this.load, required this.onOpen});

  final HotArtistLoader load;
  final void Function(rust.HotArtistDto artist) onOpen;

  @override
  Widget build(BuildContext context) {
    return PagedListView<rust.HotArtistDto>(
      refreshable: false,
      emptyText: '暂时没有歌手榜',
      loader: (cursor) async =>
          PagedPage(await retryNetwork(load), hasMore: false),
      itemBuilder: (context, a, i, artists) => ListTile(
        leading: CircleCover(
          url: a.avatarUrl,
          size: 44,
          icon: Icons.person_outline,
        ),
        title: Text(
          a.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(formatFans(a.fans)),
        onTap: () => onOpen(a),
      ),
    );
  }
}

/// 粉丝数: 16908300 → "1690.8万"
String formatFans(BigInt fans) {
  if (fans <= BigInt.zero) return '';
  if (fans < BigInt.from(10000)) return '$fans 粉丝';
  final wan = fans.toDouble() / 10000;
  final text = wan >= 100 ? wan.toStringAsFixed(0) : wan.toStringAsFixed(1);
  return '$text 万粉丝';
}

/// "精选新碟"页签: album_newest 固定 12 张编辑精选新碟, 封面网格(无地区筛选).
class _NewestAlbumsTab extends StatefulWidget {
  const _NewestAlbumsTab({required this.load, required this.onOpen});

  final NewestAlbumLoader load;
  final void Function(rust.AlbumItemDto album) onOpen;

  @override
  State<_NewestAlbumsTab> createState() => _NewestAlbumsTabState();
}

class _NewestAlbumsTabState extends State<_NewestAlbumsTab> {
  @override
  Widget build(BuildContext context) {
    return PagedListView<rust.AlbumItemDto>(
      refreshable: false,
      emptyText: '暂时没有精选新碟',
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.72,
      ),
      loader: (cursor) async =>
          PagedPage(await retryNetwork(widget.load), hasMore: false),
      itemBuilder: (context, a, i, albums) => InkWell(
        onTap: () => widget.onOpen(a),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面随格子宽度伸缩(AspectRatio), 避免固定 size 溢出
            AspectRatio(
              aspectRatio: 1,
              child: CoverArt(url: a.coverUrl, size: 100, radius: 8),
            ),
            const SizedBox(height: 4),
            Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              a.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
