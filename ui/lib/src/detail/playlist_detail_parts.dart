import 'package:flutter/material.dart';

import '../cover_art.dart';
import '../cover_backdrop.dart';
import '../cover_palette.dart';
import '../expandable_text.dart';
import '../layout.dart' show kPagePadding;
import '../marquee_text.dart';
import '../rust/api_all.dart' as rust;

/// 歌单详情的纯视图零件(头部卡片 / 筛选条 / 无版权提示): 只吃入参, 不碰网络.

/// 头部卡片: 封面取色渐变背景 + 标题跑马灯 + 创建者/曲目数/标签 + 简介/重试链接.
class PlaylistHeaderCard extends StatelessWidget {
  const PlaylistHeaderCard({
    super.key,
    required this.detail,
    required this.name,
    required this.fallbackCoverUrl,
    required this.palette,
    required this.detailError,
    required this.onRetry,
    this.onOpenCreator,
  });

  /// 歌单详情(拉取失败时为 null: 标题/封面用入参兜底)
  final rust.PlaylistDetail? detail;
  final String name;
  final String? fallbackCoverUrl;
  final CoverPalette? palette;

  /// 详情错误文案(非空时卡片右下角给"点击重试")
  final String? detailError;
  final VoidCallback onRetry;

  /// 「创建者」的点击(进他人主页); null = 不可点(官方/系统歌单 uid 为 0)
  final VoidCallback? onOpenCreator;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final theme = Theme.of(context);
    // 头部卡片用封面取色渐变做背景; 卡片本体半透明, 让主色调透出来
    return CoverBackdrop(
      palette: palette,
      child: Card(
        color: theme.colorScheme.surface.withValues(alpha: 0.82),
        margin: const EdgeInsets.fromLTRB(0, 12, 0, 0),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 标题用 headlineSmall 级别(之前 titleMedium 显得特别小);
                        // 长标题单行横向滚动播放, 不再截断/竖排
                        MarqueeText(
                          d?.name ?? name,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (d != null && d.creatorName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _CreatorLine(
                              creatorName: d.creatorName,
                              onTap: onOpenCreator,
                            ),
                          ),
                        if (d != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${d.trackCount} 首 · 播放 ${d.playCount} 次',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        if (d != null && d.tags.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final t in d.tags)
                                  _PlaylistTagChip(tag: t),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  CoverArt(
                    url: d?.coverUrl ?? fallbackCoverUrl,
                    size: 120,
                    radius: 8,
                  ),
                ],
              ),
              if (detailError != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onRetry,
                    child: Text(
                      '详情加载失败, 点击重试',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                )
              else if (d != null && d.description.trim().isNotEmpty)
                ExpandableText(text: d.description),
            ],
          ),
        ),
      ),
    );
  }
}

/// 页面级筛选条: 本地过滤 + "定位正在播放"
class PlaylistFilterBar extends StatelessWidget {
  const PlaylistFilterBar({
    super.key,
    required this.controller,
    this.focusNode,
    required this.filter,
    required this.onChanged,
    required this.onClear,
    required this.canLocate,
    required this.onLocate,
  });

  final TextEditingController controller;

  /// 筛选框焦点(AppBar 常驻搜索按钮滚到筛选条后 requestFocus)
  final FocusNode? focusNode;
  final String filter;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  /// 当前队列正是这个歌单(或本页刚点播过)时才显示"定位正在播放"
  final bool canLocate;
  final VoidCallback onLocate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              decoration: InputDecoration(
                isDense: true,
                hintText: '筛选本页曲目',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: onClear,
                      ),
              ),
            ),
          ),
          if (canLocate) ...[
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: onLocate,
              icon: const Icon(Icons.my_location, size: 18),
              label: const Text('定位正在播放'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 无版权曲目隐藏提示(顶部一行)
class PlaylistHiddenNote extends StatelessWidget {
  const PlaylistHiddenNote({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 与页面级水平留白一致(原来这里 16, 和上下列表/卡片 12 对不齐)
      padding: const EdgeInsets.fromLTRB(kPagePadding, 4, kPagePadding, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '已隐藏 $count 首无版权曲目',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// 「创建者: xxx」一行: 有 uid 时是链接(主色 + 下划线, 点进他人主页),
/// 没有 uid(官方/系统歌单)时就是普通文字。
class _CreatorLine extends StatelessWidget {
  const _CreatorLine({required this.creatorName, this.onTap});

  final String creatorName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final label = Text(
      '创建者: $creatorName',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: onTap == null
          ? style
          : style?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: theme.colorScheme.primary,
            ),
    );
    if (onTap == null) return label;
    return InkWell(onTap: onTap, child: label);
  }
}

/// 标签胶囊(流派/场景)
class _PlaylistTagChip extends StatelessWidget {
  const _PlaylistTagChip({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(tag, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// 编辑模式的顶部横幅: 提示"点击曲目即可移出" + 完成按钮
class PlaylistEditingBanner extends StatelessWidget {
  const PlaylistEditingBanner({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.remove_circle_outline, size: 16),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('移出曲目模式: 点击曲目即可移出歌单', style: TextStyle(fontSize: 12)),
            ),
            TextButton(onPressed: onDone, child: const Text('完成')),
          ],
        ),
      ),
    );
  }
}
