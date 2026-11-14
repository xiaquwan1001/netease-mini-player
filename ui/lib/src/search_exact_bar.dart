import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'layout.dart';

// ---------------------------------------------------------------------------
// 视图模型 —— 纯 Dart, 语义对齐 Rust search_multimatch 的 DTO
// (docs/b4-search-notes.md). 这里刻意不 import rust: 组件与桥解耦,
// 之后由上层把 Rust DTO 转成这些 view 类型.
// ---------------------------------------------------------------------------

/// 命中的艺人实体.
class SearchExactArtist {
  const SearchExactArtist({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.subtitle,
  });

  final int id;
  final String name;
  final String? avatarUrl;

  /// 副标题(通常是 occupation, 如「艺人」).
  final String? subtitle;
}

/// 命中的歌单实体.
class SearchExactPlaylist {
  const SearchExactPlaylist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.creatorName,
    this.trackCount = 0,
    this.playCount = 0,
  });

  final int id;
  final String name;
  final String? coverUrl;
  final String? creatorName;
  final int trackCount;
  final int playCount;
}

/// 命中的电台/播客实体 (multimatch 的 `voice` 类型).
class SearchExactRadio {
  const SearchExactRadio({
    required this.id,
    required this.name,
    this.coverUrl,
    this.djName,
    this.programCount = 0,
  });

  final int id;
  final String name;
  final String? coverUrl;
  final String? djName;
  final int programCount;
}

/// 精确实体条视图模型.
///
/// [orders] 是命中类型的展示顺序, 取值 `artist` / `playlist` / `voice`;
/// 未知类型忽略. orders 为空而列表非空时按固定顺序兜底
/// (见 [kSearchExactFallbackOrder]).
class SearchExactView {
  const SearchExactView({
    this.orders = const <String>[],
    this.artists = const <SearchExactArtist>[],
    this.playlists = const <SearchExactPlaylist>[],
    this.podcasts = const <SearchExactRadio>[],
  });

  final List<String> orders;
  final List<SearchExactArtist> artists;
  final List<SearchExactPlaylist> playlists;
  final List<SearchExactRadio> podcasts;

  bool get isEmpty => artists.isEmpty && playlists.isEmpty && podcasts.isEmpty;
}

/// orders 缺失时的兜底展示顺序.
const List<String> kSearchExactFallbackOrder = <String>[
  'artist',
  'playlist',
  'voice',
];

/// 分区标题文案.
const String kSearchExactTitle = '精确匹配';

const Map<String, String> _sectionTitles = <String, String>{
  'artist': '艺人',
  'playlist': '歌单',
  // 官方 8.0 起把「电台」改名为「播客」；搜索侧 type=2000 官方文档叫
  // 「声音」，这里沿用用户可理解的产品名「播客」。
  'voice': '播客',
};

/// "12.3万" 这类紧凑数字.
String _compactCount(int n) {
  if (n < 0) return '0';
  if (n < 10000) return '$n';
  final v = n / 10000.0;
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}万';
}

/// 联想面板里的「精确实体」条: 直接进入艺人/歌单/播客.
///
/// 空命中([SearchExactView.isEmpty])整体 [SizedBox.shrink], 不占位 ——
/// multimatch 的 `orders: []` 是常态. 各分区横向滚动, 卡片固定 96dp 宽,
/// 文案单行省略, 300dp 窄屏 + 大字号也不溢出.
///
/// 图片一律走 [CircleCover] / [CoverArt]: 它们用自带浏览器的 UA 取图,
/// 这里**不要**用 `Image.network(headers:)` —— 本仓库踩过 UA 双拼被 CDN 403 的坑.

/// 纯关键词联想(mobile 版 search_suggest): 卡片与精确实体都没命中时的兜底候选.
class KeywordSuggestBar extends StatelessWidget {
  const KeywordSuggestBar({super.key, required this.keywords, this.onSelected});

  final List<String> keywords;
  final void Function(String keyword)? onSelected;

  @override
  Widget build(BuildContext context) {
    if (keywords.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 4, kPagePadding, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('猜你想搜', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final k in keywords)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    k,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  onPressed: onSelected == null ? null : () => onSelected!(k),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class SearchExactBar extends StatelessWidget {
  const SearchExactBar({
    super.key,
    required this.view,
    this.onPickArtist,
    this.onPickPlaylist,
    this.onPickRadio,
  });

  final SearchExactView view;
  final void Function(int id)? onPickArtist;
  final void Function(int id)? onPickPlaylist;
  final void Function(int id)? onPickRadio;

  /// 实际渲染顺序: orders 里认识的类型(去重, 保序) + 缺失的已知类型补齐
  /// (只要对应列表非空). orders 全为空即等价于固定兜底顺序.
  List<String> get _sections {
    final out = <String>[];
    bool has(String kind) => out.contains(kind);
    bool nonEmpty(String kind) {
      switch (kind) {
        case 'artist':
          return view.artists.isNotEmpty;
        case 'playlist':
          return view.playlists.isNotEmpty;
        case 'voice':
          return view.podcasts.isNotEmpty;
      }
      return false;
    }

    for (final kind in view.orders) {
      if (_sectionTitles.containsKey(kind) && !has(kind) && nonEmpty(kind)) {
        out.add(kind);
      }
    }
    for (final kind in kSearchExactFallbackOrder) {
      if (!has(kind) && nonEmpty(kind)) out.add(kind);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (view.isEmpty) return const SizedBox.shrink();
    final sections = _sections;
    if (sections.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              4,
              kPagePadding,
              2,
            ),
            child: Text(
              kSearchExactTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          for (final kind in sections) _buildSection(context, kind, theme),
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, String kind, ThemeData theme) {
    final Widget strip;
    switch (kind) {
      case 'artist':
        strip = _buildArtists(context, theme);
      case 'playlist':
        strip = _buildPlaylists(context, theme);
      case 'voice':
        strip = _buildPodcasts(context, theme);
      default:
        return const SizedBox.shrink();
    }
    final caption = _sectionTitles[kind] ?? kind;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 4, kPagePadding, 2),
          child: Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        strip,
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildArtists(BuildContext context, ThemeData theme) {
    return SizedBox(
      height: _kArtistStripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: kPagePadding,
          vertical: 2,
        ),
        itemCount: view.artists.length,
        separatorBuilder: (_, _) => const SizedBox(width: kSectionGap),
        itemBuilder: (context, i) {
          final a = view.artists[i];
          return _ExactCard(
            width: _kCardWidth,
            onTap: onPickArtist == null ? null : () => onPickArtist!(a.id),
            cover: CircleCover(url: a.avatarUrl, size: _kCoverSize),
            title: a.name,
            subtitle: a.subtitle,
            theme: theme,
          );
        },
      ),
    );
  }

  Widget _buildPlaylists(BuildContext context, ThemeData theme) {
    return SizedBox(
      height: _kCardStripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: kPagePadding,
          vertical: 2,
        ),
        itemCount: view.playlists.length,
        separatorBuilder: (_, _) => const SizedBox(width: kSectionGap),
        itemBuilder: (context, i) {
          final p = view.playlists[i];
          return _ExactCard(
            width: _kCardWidth,
            onTap: onPickPlaylist == null ? null : () => onPickPlaylist!(p.id),
            cover: CoverArt(url: p.coverUrl, size: _kCoverSize, radius: 8),
            title: p.name,
            subtitle: _playlistSubtitle(p),
            theme: theme,
          );
        },
      ),
    );
  }

  Widget _buildPodcasts(BuildContext context, ThemeData theme) {
    return SizedBox(
      height: _kCardStripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: kPagePadding,
          vertical: 2,
        ),
        itemCount: view.podcasts.length,
        separatorBuilder: (_, _) => const SizedBox(width: kSectionGap),
        itemBuilder: (context, i) {
          final r = view.podcasts[i];
          return _ExactCard(
            width: _kCardWidth,
            onTap: onPickRadio == null ? null : () => onPickRadio!(r.id),
            cover: CoverArt(url: r.coverUrl, size: _kCoverSize, radius: 8),
            title: r.name,
            subtitle: _radioSubtitle(r),
            theme: theme,
          );
        },
      ),
    );
  }

  static String? _playlistSubtitle(SearchExactPlaylist p) {
    final parts = <String>[
      if (p.creatorName != null && p.creatorName!.isNotEmpty) p.creatorName!,
      if (p.trackCount > 0) '${p.trackCount}首',
      if (p.playCount > 0) '${_compactCount(p.playCount)}播放',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String? _radioSubtitle(SearchExactRadio r) {
    final parts = <String>[
      if (r.djName != null && r.djName!.isNotEmpty) r.djName!,
      if (r.programCount > 0) '${r.programCount}期',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

const double _kCardWidth = 96;
const double _kCoverSize = 72;

// 卡片高度 = 封面 + 间距 + 两行文本(单行省略, 但字号放大时行高会涨).
// 这里给足余量并在卡片内部用 Flexible 吞掉溢出, 保证 1.25 字号下也不报错.
const double _kCardTextHeight = 56;
const double _kCardStripHeight = _kCoverSize + 8 + _kCardTextHeight + 6;
const double _kArtistStripHeight = _kCardStripHeight;

/// 单张实体卡片: 圆形/方形封面由调用方决定, 文本一律单行省略.
class _ExactCard extends StatelessWidget {
  const _ExactCard({
    required this.width,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.theme,
    this.onTap,
  });

  final double width;
  final Widget cover;
  final String title;
  final String? subtitle;
  final ThemeData theme;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            cover,
            const SizedBox(height: 4),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  if (sub != null && sub.isNotEmpty)
                    Flexible(
                      child: Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
