import 'package:flutter/material.dart';

import 'rust/api.dart' as rust;

/// 搜索页的"落地内容": 历史 + 猜你想搜 + 热门榜.
/// 没有输入时展示, 和搜索结果共用一个滚动区, 避免列表套列表.
class SearchLanding extends StatelessWidget {
  const SearchLanding({
    super.key,
    required this.history,
    required this.hot,
    required this.recommended,
    required this.onSelected,
    required this.onClearHistory,
    this.recommendedReason,
    this.hotLoading = false,
    this.hotError,
    this.onRetryHot,
  });

  final List<String> history;
  final List<rust.HotSearchTermDto> hot;
  /// "猜你想搜"的关键词(真正要搜的词)
  final String? recommended;

  /// 官方给的推荐理由文案(形如 "🔥Mili 你的十月榜首"), 只用于展示
  final String? recommendedReason;

  final void Function(String keyword) onSelected;
  final VoidCallback onClearHistory;
  final bool hotLoading;
  final String? hotError;
  final VoidCallback? onRetryHot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      children: [
        if (history.isNotEmpty) ...[
          _SectionTitle(
            title: '搜索历史',
            trailing: TextButton(
              onPressed: onClearHistory,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('清空'),
            ),
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
          const SizedBox(height: 12),
        ],
        if (recommended != null && recommended!.isNotEmpty) ...[
          const _SectionTitle(title: '猜你想搜'),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.auto_awesome, color: scheme.primary),
              // 关键词和推荐理由必须分开: 点一下只搜关键词, 理由只是说明
              title: Text(recommended!),
              subtitle: (recommendedReason == null ||
                      recommendedReason!.isEmpty ||
                      recommendedReason == recommended)
                  ? null
                  : Text(
                      recommendedReason!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: const Icon(Icons.north_west, size: 16),
              onTap: () => onSelected(recommended!),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _SectionTitle(
          title: '热门搜索',
          trailing: hotLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        if (hotError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '热词获取失败: $hotError',
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ),
                if (onRetryHot != null)
                  TextButton(onPressed: onRetryHot, child: const Text('重试')),
              ],
            ),
          )
        else if (!hotLoading && hot.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '暂无热词',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final term in hot)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: _RankBadge(rank: term.rank),
                    title: Text(
                      term.keyword,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => onSelected(term.keyword),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = rank <= 3;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: top ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$rank',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: top ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
