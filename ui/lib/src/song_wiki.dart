import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';

typedef WikiLoader = Future<List<rust.WikiFact>> Function(BigInt songId);

/// 歌曲百科: 曲风/语种/BPM/获奖成就等标签(网易云"音乐百科"那块).
///
/// 接口 song_wiki_summary 返回的是装修块 + 富文本, Rust 侧已压成 label/value 对,
/// 这里只做两列渲染. 没有百科的歌返回空列表, 给一句提示就够.
Future<void> showSongWiki(
  BuildContext context, {
  required rust.SongDto song,
  WikiLoader? load,
}) {
  final loader = load ?? (id) => rust.songWiki(songId: id);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              title: '歌曲百科',
              onClose: () => Navigator.pop(sheetContext),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  CoverArt(url: song.coverUrl, size: 40, radius: 4),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Flexible(child: _WikiBody(load: () => loader(song.id))),
          ],
        ),
      ),
    ),
  );
}

typedef WikiFactsLoader = Future<List<rust.WikiFact>> Function();

class _WikiBody extends StatefulWidget {
  const _WikiBody({required this.load});

  final WikiFactsLoader load;

  @override
  State<_WikiBody> createState() => _WikiBodyState();
}

class _WikiBodyState extends State<_WikiBody> {
  List<rust.WikiFact>? _facts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final facts = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _facts = facts);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final facts = _facts;
    if (facts == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (facts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('这首歌还没有百科信息', style: theme.textTheme.bodySmall),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: facts.length,
      separatorBuilder: (_, _) => const Divider(height: 16),
      itemBuilder: (context, i) {
        final f = facts[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(
                f.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(f.value, style: theme.textTheme.bodyMedium)),
          ],
        );
      },
    );
  }
}
