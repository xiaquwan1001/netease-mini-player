/// 数字专辑(只读): 我的已购数字专辑 + 已购单曲, 详情用 BottomSheet 展开.
/// 只读, 不提供下单; 未登录不进入(入口在 mine_view 里已按 loggedIn 过滤).
import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 可注入的加载器(测试用 mock)
typedef LoadPurchasedAlbums = Future<rust.DigitalAlbumPurchasedDto?> Function();
typedef LoadPurchasedSongs = Future<rust.SongPurchasedDto?> Function();
typedef LoadAlbumSales = Future<List<rust.DigitalAlbumSalesDto>?> Function(String albumIds);
typedef LoadAlbumDetail = Future<rust.DigitalAlbumDetailDto?> Function(BigInt albumId);

class DigitalAlbumPage extends StatefulWidget {
  const DigitalAlbumPage({super.key, this.loadAlbums, this.loadSongs, this.loadSales, this.loadDetail});

  final LoadPurchasedAlbums? loadAlbums;
  final LoadPurchasedSongs? loadSongs;
  final LoadAlbumSales? loadSales;
  final LoadAlbumDetail? loadDetail;

  @override
  State<DigitalAlbumPage> createState() => _DigitalAlbumPageState();
}

class _DigitalAlbumPageState extends State<DigitalAlbumPage> {
  rust.DigitalAlbumPurchasedDto? _albums;
  rust.SongPurchasedDto? _songs;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final loadA = widget.loadAlbums ??
          () => retryNetwork(() => rust.digitalAlbumPurchased(limit: 30, offset: 0));
      final loadS = widget.loadSongs ??
          () => retryNetwork(() => rust.songPurchased(limit: 20, offset: 0));
      final results = await Future.wait<Object?>([loadA(), loadS()]);
      if (!mounted) return;
      setState(() {
        _albums = results[0] as rust.DigitalAlbumPurchasedDto?;
        _songs = results[1] as rust.SongPurchasedDto?;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _openDetail(rust.DigitalAlbumEntryDto album) async {
    final detailLoader = widget.loadDetail ?? (BigInt id) => rust.digitalAlbumDetail(albumId: id);
    final salesLoader = widget.loadSales ?? (ids) => rust.digitalAlbumSales(albumIds: ids);
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
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '加载失败: $_error',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          Center(child: FilledButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    final albums = _albums?.albums ?? const <rust.DigitalAlbumEntryDto>[];
    final songs = _songs?.songs ?? const <rust.PurchasedSongDto>[];
    if (albums.isEmpty && songs.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 96),
          Icon(Icons.album_outlined, size: 56),
          SizedBox(height: 12),
          Center(child: Text('还没有已购的数字专辑或单曲')),
          Center(child: Text('购买后会展现在这里(本页只读, 不支持下单)')),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (albums.isNotEmpty) ...[
          Text('已购数字专辑(${albums.length})', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          ...albums.map((a) => Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: CoverArt(url: a.coverUrl, size: 48, radius: 6),
                  title: Text(a.albumName, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${a.artistName} · x${a.boughtCount} · ${_fmtDate(a.paidTimeMs)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openDetail(a),
                ),
              )),
        ],
        if (songs.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('已购单曲(${songs.length})', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          ...songs.map((s) => ListTile(
                leading: CoverArt(url: s.coverUrl, size: 40, radius: 4),
                title: Text(s.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${s.artistName} · ${_fmtDate(s.paidTimeMs)}',
                  overflow: TextOverflow.ellipsis,
                ),
              )),
        ],
      ],
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

  final rust.DigitalAlbumEntryDto album;
  final LoadAlbumDetail loadDetail;
  final LoadAlbumSales loadSales;

  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  rust.DigitalAlbumDetailDto? _detail;
  List<rust.DigitalAlbumSalesDto>? _sales;
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
        _detail = results[0] as rust.DigitalAlbumDetailDto?;
        _sales = results[1] as List<rust.DigitalAlbumSalesDto>?;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final sales = _sales?.where((e) => e.albumId == album.albumId.toString()).toList();
    final salesNum = (sales == null || sales.isEmpty) ? null : sales.first.sales;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CoverArt(url: album.coverUrl, size: 88, radius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(album.albumName,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(album.artistName, overflow: TextOverflow.ellipsis),
                      if (_detail != null) ...[
                        const SizedBox(height: 4),
                        Text('价格: ¥${_detail!.price} · ${_fmtTags(_detail!.tags)}'),
                      ],
                      if (salesNum != null)
                        Text('销量: ${_fmtCompact(salesNum)}'),
                    ],
                  ),
                ),
              ],
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
