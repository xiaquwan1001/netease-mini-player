import 'package:flutter/material.dart';

import 'all_charts_page.dart';
import 'app_settings.dart';
import 'cover_art.dart';
import 'error_views.dart' show InlineError;
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 榜单列表加载器(可注入, 测试用)。缺省走 FFI chartList。
typedef ChartListLoader = Future<List<rust.ChartSummary>> Function();

/// 排行榜区块: 标题 + 「全部」+ 一排(或两排)榜单封面。
///
/// 2026-11 用户要求: 排行榜从「推荐」移到「搜索」页的落地内容。
/// 这里把原来 recommend_view 里的私有实现抽出来, 推荐页不再渲染;
/// 搜索落地页(SearchLanding)直接复用, 不要再复制第三份。
class ChartSection extends StatefulWidget {
  const ChartSection({
    super.key,
    required this.onOpen,
    this.load,
  });

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
              onPressed: () => showAllChartsPage(
                context,
                onOpenPlaylist: widget.onOpen,
              ),
              child: const Text('全部'),
            ),
          ),
          FutureBuilder<List<rust.ChartSummary>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
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
              return _CoverRow(
                height: 176,
                rows: AppSettings.instance.coverRows,
                children: [
                  for (final chart in charts)
                    _CoverCard(
                      coverUrl: chart.coverUrl,
                      title: chart.name,
                      subtitle: chart.updateFrequency.isEmpty
                          ? '${chart.trackCount} 首'
                          : chart.updateFrequency,
                      onTap: () => widget.onOpen(rust.Playlist(
                        id: chart.id,
                        name: chart.name,
                        coverUrl: chart.coverUrl,
                        trackCount: chart.trackCount,
                        special: false,
                      )),
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
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _CoverRow extends StatelessWidget {
  const _CoverRow({required this.children, required this.height, this.rows = 1});

  final List<Widget> children;
  final double height;
  final int rows;

  /// 定高 height(=176)按 scale=1.0 设计: 封面 118 + 4 + 两行文字约 54.
  /// 大字体(1.3/1.625)下文字行高变大, 固定 176 会纵向溢出;
  /// 只放大"两行文字"的部分, scale=1.0 时不变。
  double _effectiveHeight(BuildContext context) {
    final textLines = MediaQuery.textScalerOf(context).scale(27) * 2;
    return height + (textLines - 54);
  }

  @override
  Widget build(BuildContext context) {
    final h = _effectiveHeight(context);
    if (rows <= 1 || children.length < 2) return _row(children, h);
    final half = (children.length + 1) ~/ 2;
    // 两排时内容高 = 2*height + 行间距(4), 外层必须把间距算进去(R1 溢出回归)。
    return SizedBox(
      height: h * 2 + 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(children.take(half).toList(), h),
          const SizedBox(height: 4),
          _row(children.skip(half).toList(), h),
        ],
      ),
    );
  }

  Widget _row(List<Widget> items, double h) {
    if (items.isEmpty) return SizedBox(height: h);
    return SizedBox(
      height: h,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => SizedBox(width: 118, child: items[i]),
      ),
    );
  }
}

class _CoverCard extends StatelessWidget {
  const _CoverCard({
    required this.coverUrl,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String? coverUrl;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverArt(url: coverUrl, size: 118, radius: 8),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
