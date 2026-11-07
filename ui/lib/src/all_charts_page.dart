import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

typedef ToplistCatalogLoader = Future<List<rust.ToplistCatalogGroupDto>> Function();

/// toplist_catalog 的 categoryCode → 中文小标题.
/// 实测 7 组(顺序按服务端返回): TOPPING(置顶推广) / OFFICIAL(官方榜) /
/// FEATURE(特色榜) / MUSIC_STYLE(曲风榜) / GLOBAL(全球榜) / LANGUAGE(语种榜) /
/// MORE(更多). 未知 code 原样展示, 不吞组.
String toplistGroupTitle(String code) => switch (code) {
      'TOPPING' => '置顶',
      'OFFICIAL' => '官方榜',
      'FEATURE' => '特色榜',
      'MUSIC_STYLE' => '曲风榜',
      'GLOBAL' => '全球榜',
      'LANGUAGE' => '语种榜',
      'MORE' => '更多',
      _ => code,
    };

/// 打开"全部榜单"页(榜单即歌单, 点可播条目走上层歌单详情回调).
Future<void> showAllChartsPage(
  BuildContext context, {
  required void Function(rust.PlaylistDto playlist) onOpenPlaylist,
  ToplistCatalogLoader? loadCatalog,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AllChartsPage(
        onOpenPlaylist: onOpenPlaylist,
        loadCatalog: loadCatalog,
      ),
    ),
  );
}

class AllChartsPage extends StatefulWidget {
  const AllChartsPage({super.key, required this.onOpenPlaylist, this.loadCatalog});

  final void Function(rust.PlaylistDto playlist) onOpenPlaylist;

  /// 可注入(测试用); 默认走 FFI toplist_catalog.
  final ToplistCatalogLoader? loadCatalog;

  @override
  State<AllChartsPage> createState() => _AllChartsPageState();
}

class _AllChartsPageState extends State<AllChartsPage> {
  List<rust.ToplistCatalogGroupDto>? _groups;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _groups = null;
    });
    try {
      final groups =
          await retryNetwork(widget.loadCatalog ?? rust.toplistCatalog);
      if (!mounted) return;
      setState(() => _groups = groups);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(title: const Text('全部榜单')),
      body: _AsyncBody(
        error: _error,
        onRetry: _load,
        isEmpty: groups != null && groups.isEmpty,
        emptyText: '暂时没有榜单',
        child: groups == null
            ? null
            : ListView.builder(
                itemCount: groups.length,
                itemBuilder: (context, i) => _GroupSection(
                  group: groups[i],
                  onOpenPlaylist: widget.onOpenPlaylist,
                ),
              ),
      ),
    );
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.group, required this.onOpenPlaylist});

  final rust.ToplistCatalogGroupDto group;
  final void Function(rust.PlaylistDto playlist) onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    if (group.items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            toplistGroupTitle(group.code),
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        for (final item in group.items)
          ListTile(
            dense: true,
            leading: CoverArt(url: item.coverUrl, size: 48, radius: 6),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: item.canPlay
                  ? null
                  : TextStyle(color: Theme.of(context).disabledColor),
            ),
            subtitle: Text(
              item.updateFrequency,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // canPlay=false 的条目灰显不可点(榜单即歌单, 传 id 走歌单详情)
            onTap: item.canPlay
                ? () => onOpenPlaylist(rust.PlaylistDto(
                      id: item.id,
                      name: item.name,
                      coverUrl: item.coverUrl,
                      trackCount: BigInt.zero,
                      special: false,
                    ))
                : null,
            enabled: item.canPlay,
          ),
      ],
    );
  }
}

/// 与 new_release_page.dart 的 _AsyncBody 同口径: 加载中 / 错误+重试 / 空态
class _AsyncBody extends StatelessWidget {
  const _AsyncBody({
    required this.error,
    required this.onRetry,
    required this.isEmpty,
    required this.emptyText,
    required this.child,
  });

  final String? error;
  final VoidCallback onRetry;
  final bool isEmpty;
  final String emptyText;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      );
    }
    if (child == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (isEmpty) {
      return Center(child: Text(emptyText));
    }
    return child!;
  }
}
