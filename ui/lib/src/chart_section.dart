import 'package:flutter/material.dart';

import 'all_charts_page.dart';
import 'app_settings.dart';
import 'cover_row.dart';
import 'error_views.dart' show InlineError;
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'state_views.dart';

/// 榜单列表加载器(可注入, 测试用)。缺省走 FFI chartList。
typedef ChartListLoader = Future<List<rust.ChartSummary>> Function();

/// 排行榜区块: 标题 + 「全部」+ 一排(或两排)榜单封面。
///
/// 2026-11 用户要求: 排行榜从「推荐」移到「搜索」页的落地内容。
/// 这里把原来 recommend_view 里的私有实现抽出来, 推荐页不再渲染;
/// 搜索落地页(SearchLanding)直接复用, 不要再复制第三份。
class ChartSection extends StatefulWidget {
  const ChartSection({super.key, required this.onOpen, this.load});

  /// 点某个榜单: 榜单本身就是歌单, 交给上层打开歌单详情。
  final void Function(rust.Playlist playlist) onOpen;

  /// 可注入(测试用); 缺省 rust.chartList。
  final ChartListLoader? load;

  @override
  State<ChartSection> createState() => _ChartSectionState();
}

class _ChartSectionState extends State<ChartSection> {
  late Future<List<rust.ChartSummary>> _future;

  ChartListLoader get _loader => widget.load ?? rust.chartList;

  @override
  void initState() {
    super.initState();
    _future = retryNetwork(_loader);
  }

  @override
  void didUpdateWidget(covariant ChartSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 注入的 loader 换了(测试/账号切换)才重拉, 普通重建复用同一个 future,
    // 避免像「我的」页那样一离开视野就重新转圈。
    if (oldWidget.load != widget.load) {
      _future = retryNetwork(_loader);
    }
  }

  void _reload() => setState(() => _future = retryNetwork(_loader));

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
                  showAllChartsPage(context, onOpenPlaylist: widget.onOpen),
              child: const Text('全部'),
            ),
          ),
          FutureBuilder<List<rust.ChartSummary>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const LoadingView(
                  size: 22,
                  padding: EdgeInsets.symmetric(vertical: 20),
                );
              }
              if (snap.hasError) {
                return InlineError(
                  message: friendlyError(snap.error!),
                  onRetry: _reload,
                );
              }
              final charts = snap.data ?? const <rust.ChartSummary>[];
              if (charts.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    '暂时没有榜单',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              }
              return CoverRow(
                height: 176,
                rows: AppSettings.instance.coverRows,
                children: [
                  for (final chart in charts)
                    CoverCard(
                      coverUrl: chart.coverUrl,
                      title: chart.name,
                      subtitle: chart.updateFrequency.isEmpty
                          ? '${chart.trackCount} 首'
                          : chart.updateFrequency,
                      onTap: () => widget.onOpen(
                        rust.Playlist(
                          id: chart.id,
                          name: chart.name,
                          coverUrl: chart.coverUrl,
                          trackCount: chart.trackCount,
                          special: false,
                        ),
                      ),
                    ),
                ],
              );
            },
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
