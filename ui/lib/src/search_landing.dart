import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'app_sheet.dart';
import 'chart_section.dart';
import 'layout.dart';
import 'rust/api_all.dart' as rust;
import 'section_header.dart';
import 'state_views.dart';

/// "猜你想搜"的一个候选词.
///
/// [keyword] 是真正要搜的词(点一下只搜它), [reason] 是官方给的推荐理由
/// (形如 "🔥Mili 你的十月榜首"), 只做 Tooltip/小字说明, 不占整行.
class RecommendedKeyword {
  const RecommendedKeyword({required this.keyword, this.reason});

  final String keyword;
  final String? reason;

  @override
  int get hashCode => keyword.hashCode ^ reason.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecommendedKeyword &&
          runtimeType == other.runtimeType &&
          keyword == other.keyword &&
          reason == other.reason;

  @override
  String toString() => 'RecommendedKeyword($keyword)';
}

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
    this.hotLoading = false,
    this.hotError,
    this.onRetryHot,
    this.loadCharts,
    this.onOpenChartPlaylist,
  });

  final List<String> history;
  final List<rust.HotSearchTerm> hot;

  /// "猜你想搜"的候选词(按优先级排好序, 最多 [_recommendedMaxCount] 个).
  /// 空列表 = 没有任何可信候选, 整块(含标题)不渲染.
  final List<RecommendedKeyword> recommended;

  /// 候选格子最多显示几个(多来源合并去重后截断; 不足就少显示).
  static const int _recommendedMaxCount = 4;

  final void Function(String keyword) onSelected;
  final VoidCallback onClearHistory;
  final bool hotLoading;
  final String? hotError;
  final VoidCallback? onRetryHot;

  /// 排行榜(2026-11 从「推荐」页搬到这里)。
  /// [onOpenChartPlaylist] 为 null 时不渲染该区块(纯搜索落地页测试/嵌入场景)。
  final ChartListLoader? loadCharts;
  final void Function(rust.Playlist playlist)? onOpenChartPlaylist;

  /// 一个候选格子。样式与「搜索历史」chip 完全一致(字号 12 / padded 命中区),
  /// 推荐理由只放在 Tooltip 里, 不再占一整行。
  Widget _recommendedChip(ColorScheme scheme, RecommendedKeyword item) {
    final reason = item.reason;
    final hasReason =
        reason != null && reason.isNotEmpty && reason != item.keyword;
    final chip = ActionChip(
      materialTapTargetSize: MaterialTapTargetSize.padded,
      avatar: hasReason
          ? Icon(Icons.auto_awesome, size: 16, color: scheme.primary)
          : null,
      label: Text(
        item.keyword,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      onPressed: () => onSelected(item.keyword),
    );
    if (!hasReason) return chip;
    return Tooltip(message: reason, child: chip);
  }

  /// 清空历史前的二次确认(C2): 一次误触就不可恢复, 且这是页面上唯一的破坏性操作.
  /// 先把回调取出来再 await, 避免 "use_build_context_synchronously".
  Future<void> _confirmClear(BuildContext context) async {
    final clear = onClearHistory;
    final count = history.length;
    final ok = await showAppDialog<bool>(
      context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空搜索历史'),
        content: Text(count == 1 ? '将删除这 1 条搜索历史。' : '将删除全部 $count 条搜索历史。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 上限 4 个: 再多就把「搜索历史」挤下一屏, 且猜你想搜只要"提示感"
    final candidates = recommended.take(_recommendedMaxCount).toList();
    // 字段是 public 的, 先提成本地变量才能做 null 提升
    final chartOpen = onOpenChartPlaylist;
    return ListView(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 0, kPagePadding, 16),
      children: [
        if (history.isNotEmpty) ...[
          SectionTitle(
            '搜索历史',
            // 列表顶部没有额外留白, 这里保留 4dp 上呼吸; 下方统一 kSectionTitleGap。
            padding: const EdgeInsets.only(top: 4, bottom: kSectionTitleGap),
            // 命中区 ≥48dp(审查 P1-7.12): 原来 minimumSize 高 32, 是大字号下最难点的控件
            trailing: TextButton(
              onPressed: () => _confirmClear(context),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              child: const Text('清空'),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final keyword in history)
                // 不要 compact: 它把 chip 压到 32dp, 低于 48dp 最小触控(审查 P1-7.12)
                ActionChip(
                  materialTapTargetSize: MaterialTapTargetSize.padded,
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
          const SizedBox(height: 12),
        ],
        if (candidates.isNotEmpty) ...[
          // 与「搜索历史」同一套格子(Wrap + ActionChip), 两块视觉一致;
          // 2026-11 起候选是"多个 + 会更新", 不再是一张长期不变的卡片。
          const SectionTitle('猜你想搜'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final item in candidates) _recommendedChip(scheme, item),
            ],
          ),
          const SizedBox(height: 12),
        ],
        // 热门搜索: 栏目常驻(不再整块被设置项隐藏), 展开/收起 + 开关都在这一行,
        // 用户不必再跳设置页(2026-11 需求 7)。
        _HotSection(
          hot: hot,
          loading: hotLoading,
          error: hotError,
          onRetry: onRetryHot,
          onSelected: onSelected,
        ),
        // 排行榜: 2026-11 用户要求从「推荐」搬来。放最后, 不抢搜索历史/热词的首屏位置。
        if (chartOpen != null) ...[
          const SizedBox(height: 12),
          ChartSection(load: loadCharts, onOpen: chartOpen),
        ],
      ],
    );
  }
}

/// 热门搜索: 栏目本身常驻, 内容由右侧**一个**按钮控制(关闭 / 开启)。
///
/// 2026-11 需求: 原来「显示热搜建议」开关在设置页, 搜索页被关掉后只剩一句
/// 「去设置里开启」; 现在开关搬到这里, 且栏目标题永远显示, 不再整块消失。
/// 另: 之前「收起」+ 右侧的 ❌ 是两个做同一件事的控件(用户报"功能重复"),
/// 现在只留一个: 关闭 = 收起并记住(落盘), 再点开启恢复。
class _HotSection extends StatefulWidget {
  const _HotSection({
    required this.hot,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onSelected,
  });

  final List<rust.HotSearchTerm> hot;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final void Function(String keyword) onSelected;

  @override
  State<_HotSection> createState() => _HotSectionState();
}

class _HotSectionState extends State<_HotSection> {
  /// 唯一的状态: 设置里的持久开关(关 = 收起且下次进来仍然是关)。
  void _toggle() {
    setState(() {
      AppSettings.instance.update(
        showHotSearch: !AppSettings.instance.showHotSearch,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = AppSettings.instance.showHotSearch;
    final expanded = enabled;
    final hot = widget.hot;
    final retry = widget.onRetry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          '热门搜索',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (expanded && widget.loading)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              // 一个按钮即可: 关闭时同时收起内容并记住, 再点开启恢复。
              // (原来这里还有一枚 ❌, 与「关闭」完全重合, 2026-11 用户要求删掉。)
              TextButton(
                onPressed: _toggle,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(enabled ? '关闭' : '开启'),
              ),
            ],
          ),
        ),
        if (!enabled)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '热门搜索已关闭, 点「开启」恢复',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else if (!expanded)
          const SizedBox.shrink()
        else if (widget.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '热词获取失败: ${widget.error}',
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ),
                if (retry != null)
                  TextButton(
                    onPressed: retry,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    child: const Text('重试'),
                  ),
              ],
            ),
          )
        else if (widget.loading && hot.isEmpty)
          const EmptyView(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            title: '正在加载热词…',
          )
        else if (hot.isEmpty)
          const EmptyView(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            title: '暂无热词',
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
                    onTap: () => widget.onSelected(term.keyword),
                  ),
              ],
            ),
          ),
      ],
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
