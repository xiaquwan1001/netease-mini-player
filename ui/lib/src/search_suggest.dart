import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'rust/api.dart' as rust;

IconData suggestIcon(String kind) {
  switch (kind) {
    case 'song':
      return Icons.music_note;
    case 'artist':
      return Icons.person_outline;
    case 'album':
      return Icons.album_outlined;
    case 'playlist':
      return Icons.queue_music;
    default:
      return Icons.search;
  }
}

String suggestKindLabel(String kind) {
  switch (kind) {
    case 'song':
      return '单曲';
    case 'artist':
      return '歌手';
    case 'album':
      return '专辑';
    case 'playlist':
      return '歌单';
    default:
      return '';
  }
}

/// 输入联想面板: 点条目 → 用它做一次搜索(与原版一致: 先给建议, 再出结果).
class SuggestionPanel extends StatelessWidget {
  const SuggestionPanel({
    super.key,
    required this.items,
    required this.onSelected,
  });

  final List<rust.SuggestItemDto> items;
  final void Function(rust.SuggestItemDto) onSelected;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            ListTile(
              dense: true,
              leading: item.coverUrl == null
                  ? Icon(suggestIcon(item.kind), size: 20)
                  : CoverArt(url: item.coverUrl, size: 32, radius: 4),
              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: item.subtitle.isEmpty
                  ? null
                  : Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Text(
                suggestKindLabel(item.kind),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              onTap: () => onSelected(item),
            ),
        ],
      ),
    );
  }
}

/// 搜索历史(没输入内容时展示): 点一下直接搜, 右侧可清空.
class SearchHistoryBar extends StatelessWidget {
  const SearchHistoryBar({
    super.key,
    required this.history,
    required this.onSelected,
    required this.onClear,
  });

  final List<String> history;
  final void Function(String keyword) onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('搜索历史', style: Theme.of(context).textTheme.labelMedium),
              const Spacer(),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('清空'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final keyword in history)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    keyword,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  onPressed: () => onSelected(keyword),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
