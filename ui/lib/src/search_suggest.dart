import 'package:flutter/material.dart';

import 'category_bar.dart';
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
/// 2026-11-14 用户反馈(需求 3): 联想以前是"分类标题 + 条目"从上到下堆着排,
/// 想看后面的分类必须一直下滑, 而且和搜索结果页的分类 tab 完全两套交互。
/// 现在改成**和搜索结果一样的纵向分类 tab**: 顶部一条 [CategoryBar]
/// (单曲/艺人/专辑/歌单/MV, 带条数), 一次只渲染一个分类, 面板内部自滚动。
///
/// 默认打开的分类 = 后端个性化排序后的第一条所属分类(见 Rust 侧
/// `rank_suggest`: 与我关注艺人相关的类会被提前), 所以"搜 Chinese 却先看到
/// 冷门同名艺人"不会再把关注对象挤到后面。
class SuggestionPanel extends StatefulWidget {
  const SuggestionPanel({
    super.key,
    required this.items,
    required this.onSelected,
    this.keyword = '',
    this.onSearchAll,
  });

  final List<rust.SuggestItem> items;
  final void Function(rust.SuggestItem) onSelected;

  /// 当前输入词(底部「搜索全部结果」按钮用)
  final String keyword;

  /// 底部「看全部结果」回调; 不传就不渲染该入口
  final VoidCallback? onSearchAll;

  @override
  State<SuggestionPanel> createState() => _SuggestionPanelState();
}

class _SuggestionPanelState extends State<SuggestionPanel> {
  /// 当前分类(null = 跟随第一条所在的分类)
  String? _kind;

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
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final groups = <String, List<rust.SuggestItem>>{};
    for (final item in widget.items) {
      groups.putIfAbsent(item.kind, () => <rust.SuggestItem>[]).add(item);
    }
    final kinds = <String>[
      for (final kind in _kindOrder)
        if (groups.containsKey(kind)) kind,
      for (final kind in groups.keys)
        if (!_kindOrder.contains(kind)) kind,
    ];
    // 旧选择仍然有效就保留(用户还在打字时不要每次跳回第一类)
    final selectedKind = (_kind != null && groups.containsKey(_kind))
        ? _kind!
        : kinds.first;
    final items = groups[selectedKind]!;
    // 底部让出系统手势/导航条安全区, 最后一条不会被系统条压住。
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.fromLTRB(
        kPagePadding,
        0,
        kPagePadding,
        kPagePadding + safeBottom,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          CategoryBar(
            labels: [for (final kind in kinds) _labelOf(kind)],
            counts: [for (final kind in kinds) groups[kind]!.length],
            selected: kinds.indexOf(selectedKind),
            onSelected: (i) => setState(() => _kind = kinds[i]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: kSectionTitleGap),
              children: [
                for (final item in items)
                  ListTile(
                    dense: true,
                    leading: item.coverUrl == null
                        ? Icon(_iconOf(item.kind), size: 22)
                        : CoverArt(url: item.coverUrl, size: 36, radius: 4),
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
                    onTap: () => widget.onSelected(item),
                  ),
                if (widget.onSearchAll != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: widget.onSearchAll,
                        icon: const Icon(Icons.search, size: 18),
                        label: Text(
                          widget.keyword.isEmpty
                              ? '查看全部搜索结果'
                              : '在搜索结果里看全部「${widget.keyword}」',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.primary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
