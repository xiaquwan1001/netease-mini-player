/// 数字专辑(只读): 我的已购数字专辑 + 已购单曲, 详情用 BottomSheet 展开.
/// 只读, 不提供下单; 未登录不进入(入口在 mine_view 里已按 loggedIn 过滤).
library;

import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';

/// 可注入的加载器(测试用 mock)
typedef LoadPurchasedAlbums = Future<rust.DigitalAlbumPurchased?> Function();
typedef LoadPurchasedSongs = Future<rust.SongPurchasedPage?> Function();
typedef LoadAlbumSales = Future<List<rust.DigitalAlbumSalesEntry>?> Function(
  String albumIds,
);
typedef LoadAlbumDetail = Future<rust.DigitalAlbumDetail?> Function(
  BigInt albumId,
);

class DigitalAlbumPage extends StatefulWidget {
  const DigitalAlbumPage({
    super.key,
    this.loadAlbums,
    this.loadSongs,
    this.loadSales,
    this.loadDetail,
  });

  final LoadPurchasedAlbums? loadAlbums;
  final LoadPurchasedSongs? loadSongs;
  final LoadAlbumSales? loadSales;
  final LoadAlbumDetail? loadDetail;

  @override
  State<DigitalAlbumPage> createState() => _DigitalAlbumPageState();
}

/// 列表统一条目: 区块小标题 / 已购专辑行 / 已购单曲行.
sealed class _Entry {
  const _Entry();
}

class _SectionHead extends _Entry {
  const _SectionHead(this.title, {required this.gapAbove});
  final String title;

  /// 单曲区块标题上方多留一档间距(与旧版 SizedBox(height:12) 对齐)
  final bool gapAbove;
}

class _AlbumEntry extends _Entry {
  const _AlbumEntry(this.album);
  final rust.DigitalAlbumPurchasedEntry album;
}

class _SongEntry extends _Entry {
  const _SongEntry(this.song);
  final rust.PurchasedSongEntry song;
}

class _DigitalAlbumPageState extends State<DigitalAlbumPage> {
  // PagedListView 非分页模式: 专辑+单曲合并为一个列表, 恒 hasMore:false;
  // 任一加载失败 → 组件整页错误视图(friendlyError) + 重试, 与旧版一致。
  PagedLoader<_Entry> get _entryLoader {
    final loadA =
        widget.loadAlbums ??
        () => retryNetwork(
          () => rust.digitalAlbumPurchased(limit: 30, offset: 0),
        );
    final loadS =
        widget.loadSongs ??
        () => retryNetwork(() => rust.songPurchased(limit: 20, offset: 0));
    return (cursor) async {
      final results = await Future.wait<Object?>([loadA(), loadS()]);
      final albums =
          (results[0] as rust.DigitalAlbumPurchased?)?.albums ??
          const <rust.DigitalAlbumPurchasedEntry>[];
      final songs =
          (results[1] as rust.SongPurchasedPage?)?.songs ??
          const <rust.PurchasedSongEntry>[];
      return PagedPage<_Entry>([
        if (albums.isNotEmpty) ...[
          _SectionHead('已购数字专辑(${albums.length})', gapAbove: false),
          for (final a in albums) _AlbumEntry(a),
        ],
        if (songs.isNotEmpty) ...[
          _SectionHead('已购单曲(${songs.length})', gapAbove: true),
          for (final s in songs) _SongEntry(s),
        ],
      ], hasMore: false);
    };
  }

  Future<void> _openDetail(rust.DigitalAlbumPurchasedEntry album) async {
    final detailLoader =
        widget.loadDetail ??
        (BigInt id) => rust.digitalAlbumDetail(albumId: id);
    final salesLoader =
        widget.loadSales ?? (ids) => rust.digitalAlbumSales(albumIds: ids);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _DetailSheet(
        album: album,
        loadDetail: detailLoader,
        loadSales: salesLoader,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('数字专辑(只读)')),
      body: PagedListView<_Entry>(
        loader: _entryLoader,
        padding: EdgeInsets.fromLTRB(
          12,
          8,
          12,
          24 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        emptyBuilder: (context, items) => ListView(
          children: const [
            SizedBox(height: 96),
            Icon(Icons.album_outlined, size: 56),
            SizedBox(height: 12),
            Center(child: Text('还没有已购的数字专辑或单曲')),
            Center(child: Text('购买后会展现在这里(本页只读, 不支持下单)')),
          ],
        ),
        itemBuilder: (context, e, i, items) => switch (e) {
          _SectionHead() => Padding(
            padding: EdgeInsets.only(top: e.gapAbove ? 12 : 0, bottom: 4),
            child: Text(e.title, style: Theme.of(context).textTheme.titleSmall),
          ),
          _AlbumEntry() => Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: CoverArt(url: e.album.coverUrl, size: 48, radius: 6),
              // 只有 ellipsis 没有 maxLines 会先换行再省略: 长专辑名逐字竖排,
              // 行高翻倍(实测 378px, 见 song_tile.dart 同条注释)。
              title: Text(
                e.album.albumName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${e.album.artistName} · x${e.album.boughtCount} · ${_fmtDate(e.album.paidTimeMs)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openDetail(e.album),
            ),
          ),
          _SongEntry() => ListTile(
            leading: CoverArt(url: e.song.coverUrl, size: 40, radius: 4),
            title: Text(
              e.song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${e.song.artistName} · ${_fmtDate(e.song.paidTimeMs)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        },
      ),
    );
  }

  static String _fmtDate(BigInt ms) {
    if (ms == BigInt.zero) return '-';
    final s = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    return '${s.year}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}';
  }
}

class _DetailSheet extends StatefulWidget {
  const _DetailSheet({
    required this.album,
    required this.loadDetail,
    required this.loadSales,
  });

  final rust.DigitalAlbumPurchasedEntry album;
  final LoadAlbumDetail loadDetail;
  final LoadAlbumSales loadSales;

  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  rust.DigitalAlbumDetail? _detail;
  List<rust.DigitalAlbumSalesEntry>? _sales;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.album.albumId;
      final results = await Future.wait<Object?>([
        widget.loadDetail(id),
        widget.loadSales(id.toString()),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as rust.DigitalAlbumDetail?;
        _sales = results[1] as List<rust.DigitalAlbumSalesEntry>?;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final sales = _sales
        ?.where((e) => e.albumId == album.albumId.toString())
        .toList();
    final salesNum = (sales == null || sales.isEmpty)
        ? null
        : sales.first.sales;
    return SafeArea(
      child: Padding(
        // 双层留白 20+16 曾是全仓库最宽(36dp/侧); 外层收到 12, 正文保留 16
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SheetHeader(
              title: album.albumName,
              subtitle: album.artistName,
              leading: CoverArt(url: album.coverUrl, size: 40, radius: 6),
            ),
            if (_detail != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(
                  '价格: ¥${_detail!.price} · ${_fmtTags(_detail!.tags)}',
                ),
              ),
            if (salesNum != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text('销量: ${_fmtCompact(salesNum)}'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text('详情加载失败: $_error'),
            ],
            if (_detail != null && _detail!.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    _detail!.description,
                    maxLines: 12,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _fmtTags(List<String> tags) =>
      tags.isEmpty ? '-' : tags.join(' / ');

  static String _fmtCompact(BigInt n) {
    final v = n.toInt();
    if (v < 1000) return '$v';
    if (v < 10000) return '${(v / 1000).toStringAsFixed(1)}千';
    return '${(v / 10000).toStringAsFixed(1)}万';
  }
}
