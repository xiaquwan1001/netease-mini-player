import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'layout.dart';
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
    case 'mv':
      return Icons.play_circle_outline;
    default:
      return Icons.search;
  }
}

String suggestKindLabel(String kind) {
  switch (kind) {
    case 'song':
      return '单曲';
    case 'artist':
      return '艺人';
    case 'album':
      return '专辑';
    case 'playlist':
      return '歌单';
    case 'mv':
      return 'MV';
    default:
      return '';
  }
}

/// 输入联想面板: 点条目 → 用它做一次搜索(与原版一致: 先给建议, 再出结果).
///
/// 2026-11 需求: 联想结果要**按分类纵向分组**(单曲 / 艺人 / 专辑 / 歌单 / 其他),
/// 之前是平铺列表 + 每行尾部一个小 tag, 看不出分类边界, 也无法按类筛选。
class SuggestionPanel extends StatelessWidget {
  const SuggestionPanel({
    super.key,
    required this.items,
    required this.onSelected,
  });

  final List<rust.SuggestItem> items;
  final void Function(rust.SuggestItem) onSelected;

  /// 固定优先顺序; 未知分类按返回顺序补在最后。
  static const List<String> _kindOrder = [
    'song',
    'artist',
    'album',
    'playlist',
    'mv',
  ];

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final groups = <String, List<rust.SuggestItem>>{};
    for (final item in items) {
      groups.putIfAbsent(item.kind, () => <rust.SuggestItem>[]).add(item);
    }
    final orderedKinds = <String>[
      for (final kind in _kindOrder)
        if (groups.containsKey(kind)) kind,
      for (final kind in groups.keys)
        if (!_kindOrder.contains(kind)) kind,
    ];
    // 面板**占满**父级给的剩余高度(需求 14): 以前调用方套了
    // ConstrainedBox(maxHeight: 280) + SingleChildScrollView, 联想一多就只能在
    // 一条 280dp 的小矩形里滚, 下面还露出半截结果页。现在内部自滚动,
    // 条目一直排到页面底部(末端留出安全区/播放条的 [kPagePadding])。
    // 底部让出系统手势/导航条安全区, 最后一条不会被系统条压住。
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return Card(
      margin: EdgeInsets.fromLTRB(
        kPagePadding,
        0,
        kPagePadding,
        kPagePadding + safeBottom,
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        padding: const EdgeInsets.only(bottom: kSectionTitleGap),
        children: [
          for (final kind in orderedKinds) ...[
            _SuggestGroupHeader(kind: kind, count: groups[kind]!.length),
            for (final item in groups[kind]!)
              ListTile(
                dense: true,
                leading: item.coverUrl == null
                    ? Icon(_iconOf(kind), size: 20)
                    : CoverArt(url: item.coverUrl, size: 32, radius: 4),
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: item.subtitle.isEmpty
                    ? null
                    : Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => onSelected(item),
              ),
          ],
        ],
      ),
    );
  }

  /// 联想条目自带的 kind 与结果页的分类名对齐(kind 可能为空/未知)。
  static String _labelOf(String kind) {
    final label = suggestKindLabel(kind);
    return label.isEmpty ? '其他' : label;
  }

  static IconData _iconOf(String kind) =>
      kind.isEmpty ? Icons.search : suggestIcon(kind);
}

/// 分组标题(单曲 / 艺人 / …  右侧组内条数), 与结果页的区块标题同一视觉语言。
class _SuggestGroupHeader extends StatelessWidget {
  const _SuggestGroupHeader({required this.kind, required this.count});

  final String kind;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = SuggestionPanel._labelOf(kind);
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      child: Row(
        children: [
          Icon(SuggestionPanel._iconOf(kind), size: 14, color: scheme.outline),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
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
      padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 4),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
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
