import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;

/// 「我的」页里的收藏歌单 / 收藏播客 / 收藏专辑的"查看全部"二级页。
///
/// 用户反馈(2026-11): 我的页只给横向预览, 收藏多了看不到全部,
/// 需要各自有可展开的整页列表。三个页面结构一致, 共用一份实现。

Future<void> showMyPlaylistsPage(
  BuildContext context, {
  required Future<List<rust.Playlist>> Function() load,
  required void Function(rust.Playlist playlist) onOpen,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _MyCollectionPage<rust.Playlist>(
        title: '收藏的歌单',
        emptyText: '还没有收藏歌单',
        load: load,
        leading: (pl) => CoverArt(url: pl.coverUrl, size: 48, radius: 6),
        titleOf: (pl) => pl.special ? '我喜欢的音乐' : pl.name,
        subtitleOf: (pl) => '${pl.trackCount} 首',
        onOpen: onOpen,
      ),
    ),
  );
}

Future<void> showMyPodcastsPage(
  BuildContext context, {
  required Future<List<rust.PodcastRadio>> Function() load,
  required void Function(rust.PodcastRadio radio) onOpen,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _MyCollectionPage<rust.PodcastRadio>(
        title: '收藏的播客',
        emptyText: '还没有收藏播客',
        load: load,
        leading: (r) => CoverArt(url: r.coverUrl, size: 48, radius: 6),
        titleOf: (r) => r.name,
        subtitleOf: (r) => [
          if (r.djName.isNotEmpty) r.djName,
          if (r.programCount > BigInt.zero) '${r.programCount} 集',
        ].join(' · '),
        onOpen: onOpen,
      ),
    ),
  );
}

Future<void> showMyAlbumsPage(
  BuildContext context, {
  required Future<List<rust.AlbumItem>> Function() load,
  required void Function(rust.AlbumItem album) onOpen,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _MyCollectionPage<rust.AlbumItem>(
        title: '收藏的专辑',
        emptyText: '还没有收藏专辑(在专辑页点收藏)',
        load: load,
        leading: (a) => CoverArt(url: a.coverUrl, size: 48, radius: 6),
        titleOf: (a) => a.name,
        subtitleOf: (a) => [
          if (a.artist.isNotEmpty) a.artist,
          if (a.trackCount > BigInt.zero) '${a.trackCount} 首',
        ].join(' · '),
        onOpen: onOpen,
      ),
    ),
  );
}

class _MyCollectionPage<T> extends StatelessWidget {
  const _MyCollectionPage({
    required this.title,
    required this.emptyText,
    required this.load,
    required this.leading,
    required this.titleOf,
    required this.subtitleOf,
    required this.onOpen,
  });

  final String title;
  final String emptyText;
  final Future<List<T>> Function() load;
  final Widget Function(T item) leading;
  final String Function(T item) titleOf;
  final String Function(T item) subtitleOf;
  final void Function(T item) onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      // 非分页模式: 一次取全部, hasMore 恒 false; 三态/重试/下拉刷新交给组件。
      body: PagedListView<T>(
        emptyText: emptyText,
        endText: null,
        loader: (cursor) async =>
            PagedPage(await retryNetwork(load), hasMore: false),
        itemBuilder: (context, item, i, items) => ListTile(
          leading: leading(item),
          title: AdaptiveText(titleOf(item)),
          subtitle: Text(
            subtitleOf(item),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onOpen(item),
        ),
      ),
    );
  }
}
