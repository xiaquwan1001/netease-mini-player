import 'package:flutter/material.dart';

import 'all_charts_page.dart';
import 'app_settings.dart';
import 'async_view.dart';
import 'cover_row.dart';
import 'rust/api.dart' as rust;

/// 榜单列表加载器(可注入, 测试用)。缺省走 FFI chartList。
typedef ChartListLoader = Future<List<rust.ChartSummary>> Function();

/// 排行榜区块: 标题 + 「全部」+ 一排(或两排)榜单封面。
///
/// 2026-11 用户要求: 排行榜从「推荐」移到「搜索」页的落地内容。
/// 这里把原来 recommend_view 里的私有实现抽出来, 推荐页不再渲染;
/// 搜索落地页(SearchLanding)直接复用, 不要再复制第三份。
class ChartSection extends StatelessWidget {
  const ChartSection({super.key, required this.onOpen, this.load});

  /// 点某个榜单: 榜单本身就是歌单, 交给上层打开歌单详情。
  final void Function(rust.Playlist playlist) onOpen;

  /// 可注入(测试用); 缺省 rust.chartList。
  final ChartListLoader? load;

  @override
  Widget build(BuildContext context) {
    // 一排/两排是用户设置, 改了立刻反映(搜索页没有外层 AnimatedBuilder)。
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            title: '排行榜',
            trailing: TextButton(
              onPressed: () =>
                  showAllChartsPage(context, onOpenPlaylist: onOpen),
              child: const Text('全部'),
            ),
          ),
          AsyncView<List<rust.ChartSummary>>(
            // 收敛: 原来这里手写 FutureBuilder 四态, 现统一到 async_view.dart。
            // 注入的 loader 换了(测试/账号切换)才重新取数: 用 key 换代重挂载;
            // 普通重建复用同一个 future, 避免一离开视野就重新转圈。
            key: ValueKey(load),
            load: load ?? rust.chartList,
            emptyText: '暂时没有榜单',
            builder: (context, charts, reload) => CoverRow(
              height: kCoverCardHeight,
              rows: AppSettings.instance.coverRows,
              children: [
                for (final chart in charts)
                  CoverCard(
                    coverUrl: chart.coverUrl,
                    title: chart.name,
                    subtitle: chart.updateFrequency.isEmpty
                        ? '${chart.trackCount} 首'
                        : chart.updateFrequency,
                    onTap: () => onOpen(
                      rust.Playlist(
                        id: chart.id,
                        name: chart.name,
                        coverUrl: chart.coverUrl,
                        trackCount: chart.trackCount,
                        special: false,
                        subscribed: false,
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
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
