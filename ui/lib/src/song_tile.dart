import 'package:flutter/material.dart';

import 'adaptive_text_row.dart';
import 'cover_art.dart';
import 'format.dart' show formatDurationMs;
import 'layout.dart' show kSongRowPadding;
import 'now_playing.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';

/// 歌曲行的布局口径(两条既有排版臂, 二选一):
///
/// - [SongRowLayout.tile]: Material [ListTile] 口径(整页铺满的搜索/日推等列表)。
///   行高、水波纹、selected 文本色都由 ListTile 负责, 行留白默认 [kSongRowPadding]。
/// - [SongRowLayout.plain]: 自带 InkWell + Row 的自绘口径(带序号列、行高由页面
///   自己定, 或包在固定 itemExtent 里需要竖直居中的行)。
enum SongRowLayout { tile, plain }

/// 歌曲行副标题内容: 只显示歌手, 还是「歌手 · 专辑」。
enum SongRowSubtitle { artist, artistAlbum }

/// 会员标: 歌曲行 / 播放条 / 账号都用同一个, 避免各处自己画一套形态
class VipBadge extends StatelessWidget {
  const VipBadge({super.key, this.small = false});

  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: EdgeInsets.symmetric(
        horizontal: small ? 4 : 6,
        vertical: small ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.5),
          width: 0.8,
        ),
      ),
      child: Text(
        'VIP',
        style: TextStyle(
          fontSize: small ? 10 : 11,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// 需单独购买的数字专辑(fee=4)
class PaidBadge extends StatelessWidget {
  const PaidBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '付费',
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: scheme.tertiary,
        ),
      ),
    );
  }
}

/// 无版权(网易云 privilege.st < 0): 官方是灰显 + 点击才提示
class UnplayableBadge extends StatelessWidget {
  const UnplayableBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.outline.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '无版权',
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: scheme.outline,
        ),
      ),
    );
  }
}

/// 时长文案: `mm:ss`(满一小时用 `h:mm:ss`).
///
/// 纯函数(便于单测): 歌曲行以前显示原始秒数(如 `245s`), 与播放条/歌单详情的
/// `mm:ss` 不一致; 这里是全 App 歌曲行的唯一口径.
/// 实现统一走 format.dart 的 formatDurationMs(非负区间输出完全一致);
/// 口径差异只剩负值: 共享实现回绕(→59:55), 歌曲行钳 0(→00:00), 测试锁定.
String formatSongDuration(BigInt durationMs) {
  if (durationMs.isNegative) return formatDurationMs(BigInt.zero);
  return formatDurationMs(durationMs);
}

/// 行内「VIP / 付费 / 无版权」标记组(紧凑, 不参与窄宽收起).
///
/// 用于自带排版、不走 [SongTile] 的曲目行(专辑预览/播放队列/相似歌曲/推荐预览等):
/// 与歌名同一行, 歌名 Expanded + ellipsis, 标记固定宽度 ⇒ 标记永远可见。
class SongFeeBadges extends StatelessWidget {
  const SongFeeBadges({super.key, required this.song, this.small = true});

  final rust.SongDto song;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (song.playable && song.vip) VipBadge(small: small),
        if (song.playable && !song.vip && song.paid) const PaidBadge(),
        if (!song.playable) const UnplayableBadge(),
      ],
    );
  }
}

/// 「歌名 + VIP/付费/无版权标记」的整行标题(供 ListTile.title 等窄位使用).
///
/// 歌名部分走统一组件 [AdaptiveText](跑马灯形态, 放得下就不动); 徽标是语义信息
/// (VIP/付费/无版权, 用户反馈"歌曲没有是否为 VIP 的标记"), 因此**永不按宽度收起**,
/// 固定宽度排在歌名之后, 只有歌名 Expanded 会被压缩。
class SongTitleWithBadges extends StatelessWidget {
  const SongTitleWithBadges({
    super.key,
    required this.song,
    this.style,
    this.marquee = true,
    this.extraBadges = const [],
  });

  final rust.SongDto song;
  final TextStyle? style;
  final bool marquee;

  /// 歌名之后、VIP/付费标记之前的额外装饰徽标(如"只读红心")。
  final List<Widget> extraBadges;

  @override
  Widget build(BuildContext context) {
    final Widget title = AdaptiveText(
      song.name,
      mode: marquee ? AdaptiveTextMode.marquee : AdaptiveTextMode.ellipsis,
      style: style,
    );
    return Row(
      children: [
        Expanded(child: title),
        for (final badge in extraBadges) badge,
        SongFeeBadges(song: song),
      ],
    );
  }
}

/// 全 App **唯一**的歌曲行实现(前端审计 §2.2 建议 4).
///
/// 参数全部可空 —— 不传 / 传 null 就是这一行**不显示**这一块, 不存在"顺手统一"的
/// 隐式行为。各调用点保留自己原来的排版参数, 视觉与交互按原样:
///
/// | 能力 | 参数 |
/// |---|---|
/// | 序号列(正在播放时换成喇叭) | [indexText] / [indexWidth] / [indexAlign] / [indexColor] / [indexGap] |
/// | 正在播放高亮 | [active] / [unionWithNowPlaying] / [highlightNowPlaying] / [playingTint] |
/// | VIP / 付费 / 无版权徽标 | [badgesInSubtitle] (在歌名后 还是 副标题行) |
/// | 副标题(歌手 / 歌手·专辑) | [subtitle] / [subtitleStyle] |
/// | 封面 | [coverSize] / [coverGap] |
/// | 时长 | [showDuration] / [durationGap] / [capTrailing] |
/// | 红心 | [liked] / [onToggleLike] / [readOnlyHeart] |
/// | 行尾菜单 | [onMenu](页面自带回调) / [menuSource](走 SongOverflowButton) |
/// | 点击 / 长按选中 | [onTap] / [onLongPress] / [tapOnlyWhenPlayable] |
///
/// 布局只有两条臂(见 [SongRowLayout]): ListTile 口径与自绘口径。臂内差异继续由
/// 上面的参数表达, 不做跨臂合并 —— 换臂等于换 Material 度量, 一定有视觉变化。
class SongRow extends StatelessWidget {
  const SongRow({
    super.key,
    required this.song,
    this.layout = SongRowLayout.plain,
    this.visualDensity,
    this.indexText,
    this.indexWidth = 24,
    this.indexAlign = TextAlign.center,
    this.indexColor,
    this.indexGap = 10,
    this.coverSize,
    this.coverGap = 10,
    this.active,
    this.unionWithNowPlaying = false,
    this.highlightNowPlaying = true,
    this.playingTitleStyle = true,
    this.playingTint = false,
    this.titleMarquee = true,
    this.badgesInSubtitle = false,
    this.readOnlyHeart = false,
    this.subtitle = SongRowSubtitle.artistAlbum,
    this.subtitleStyle,
    this.showDuration = true,
    this.durationGap = 8,
    this.trailingExtra,
    this.capTrailing = false,
    this.liked = false,
    this.onToggleLike,
    this.onMenu,
    this.menuSource,
    this.onTap,
    this.onLongPress,
    this.padding = EdgeInsets.zero,
    this.tapOnlyWhenPlayable = false,
  });

  final rust.SongDto song;

  /// 排版口径(见 [SongRowLayout]); 默认自绘臂。
  final SongRowLayout layout;

  /// ListTile 臂的行密度(自绘臂无此概念); null = Material 默认。
  /// 卡片里的紧凑预览列表传 [VisualDensity.compact] 保持原来的行高。
  final VisualDensity? visualDensity;

  /// 序号列文案(如 `'1'` / `'01'`)。null = 没有序号列。
  /// 文案由调用方决定(歌单详情要两位右对齐, 艺人页/我喜欢 1 起居中)。
  final String? indexText;

  /// 序号列宽(`SizedBox`); 数字宽度, 不是间距 token。
  final double indexWidth;

  /// 序号文字对齐方式(歌单详情右对齐, 艺人页/我喜欢居中, 日推列表靠左)。
  final TextAlign indexAlign;

  /// 序号文字颜色; null = 自绘臂用 `scheme.outline`, ListTile 臂沿用 `bodySmall` 原色。
  final Color? indexColor;

  /// 序号列与封面(没有封面时与标题)之间的间距。
  final double indexGap;

  /// 封面直径; null = 不显示封面。
  final double? coverSize;

  /// 封面与标题列之间的间距。
  final double coverGap;

  /// 显式播放态。null = 读全局 [nowPlayingSongId](推荐);
  /// 传值时不看全局, 除非同时传 [unionWithNowPlaying]。
  final bool? active;

  /// [active] 与全局"正在播放"取并集(页内乐观态 + 别处换歌都要高亮)。
  final bool unionWithNowPlaying;

  /// 是否包 [NowPlayingHighlight] 读全局播放态。false = 本行永远不显示播放态
  /// (艺人推荐单曲/我喜欢预览历史上就没有这个语汇)。
  final bool highlightNowPlaying;

  /// 播放态是否把歌名换成主色加粗。ListTile 臂里由 ListTile.selected 负责时传 false。
  final bool playingTitleStyle;

  /// 播放态是否给整行铺主色底(歌单详情的口径)。
  final bool playingTint;

  /// 歌名放不下时是否跑马灯滚动(false = 单行省略)。
  final bool titleMarquee;

  /// 徽标(VIP/付费/无版权)放副标题行而不是歌名后(窄屏也更保险, 歌单详情口径)。
  final bool badgesInSubtitle;

  /// 没有可点红心时, 用歌名后的只读红心表示"已收藏"。
  final bool readOnlyHeart;

  /// 副标题内容。
  final SongRowSubtitle subtitle;

  /// 副标题样式; null = 自绘臂 `labelSmall` + 可播 `onSurfaceVariant` / 不可播 `outline`,
  /// ListTile 臂不设样式(沿用 Material 自己的行样式)。
  final TextStyle? subtitleStyle;

  /// 是否显示时长。
  final bool showDuration;

  /// 时长前的间距(自绘臂且未封顶时生效)。
  final double durationGap;

  /// 行尾在时长之前插入的附加内容(如"共 N 首"这类一次性说明);
  /// null = 这一行没有附加内容。
  final Widget? trailingExtra;

  /// 行尾(时长+红心+更多)是否封顶在可用宽的 45%(歌单详情口径):
  /// 触到上限时**先截断时长**, 歌名/徽标不被挤掉。
  final bool capTrailing;

  /// 是否已收藏(红心形态)。
  final bool liked;

  /// 点红心 = 喜欢/取消喜欢; null = 不显示可点红心。
  final VoidCallback? onToggleLike;

  /// 行尾"更多操作"; 与 [menuSource] 二选一(前者是页面自己的面板, 后者是统一菜单)。
  final VoidCallback? onMenu;

  /// 走统一 [SongOverflowButton] 时的菜单来源(决定菜单里是否显示"不感兴趣")。
  final SongActionSource? menuSource;

  /// 点整行。
  final VoidCallback? onTap;

  /// 长按整行(选中/多选等); null = 没有长按语义。
  final VoidCallback? onLongPress;

  /// 行内留白: 自绘臂默认零; ListTile 臂默认 [kSongRowPadding], 显式传值时按传入的走
  /// (嵌在卡片里的列表要跟卡片栅格, 传 layout.dart 的 `kCardRowPadding`)。
  final EdgeInsetsGeometry padding;

  /// 无版权曲目是否禁用点击(true = 点了没有任何反应, 官方同款灰行)。
  final bool tapOnlyWhenPlayable;

  @override
  Widget build(BuildContext context) {
    if (!highlightNowPlaying) return _build(context, active ?? false);
    final explicit = active;
    if (explicit == null) {
      return NowPlayingHighlight(
        songId: song.id,
        builder: (context, playing) => _build(context, playing),
      );
    }
    if (!unionWithNowPlaying) return _build(context, explicit);
    // 页面自己算出来的播放态(乐观态/进页时的当前曲目)与全局取并集
    return NowPlayingHighlight(
      songId: song.id,
      builder: (context, playing) => _build(context, explicit || playing),
    );
  }

  Widget _build(BuildContext context, bool playing) =>
      layout == SongRowLayout.tile
      ? _buildTile(context, playing)
      : _buildPlain(context, playing);

  String get _subtitleText => switch (subtitle) {
    SongRowSubtitle.artist => song.artist,
    SongRowSubtitle.artistAlbum => '${song.artist} · ${song.album}',
  };

  /// 序号列: 正在播放时换成喇叭(与歌单详情/搜索/日推同一套播放态语汇)
  Widget _indexOrPlaying(ThemeData theme, bool playing, TextStyle? style) {
    if (playing) {
      return Icon(Icons.volume_up, size: 16, color: theme.colorScheme.primary);
    }
    return Text(indexText!, textAlign: indexAlign, style: style);
  }

  /// 播放态歌名样式: 主色 + 半粗
  TextStyle? _playingTitleStyle(ThemeData theme) =>
      theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
      );

  /// 红心: 命中区 40x48dp(高仍 48 便于点按, 宽度让给歌名), 与各页原口径一致。
  Widget _likeButton(ColorScheme scheme) => IconButton(
    tooltip: liked ? '取消喜欢' : '喜欢',
    iconSize: 20,
    padding: EdgeInsets.zero,
    // tapTargetSize 默认 padded 会强行把命中区撑到 48x48(压掉 constraints),
    // 这正是"改了 minWidth 却仍占 48dp"的原因。shrinkWrap 后宽度才真的是 40。
    style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
    icon: Icon(
      liked ? Icons.favorite : Icons.favorite_border,
      size: 20,
      color: liked ? scheme.primary : null,
    ),
    onPressed: onToggleLike,
  );

  /// 行尾"..."(页面自带面板的形态; 统一菜单走 [SongOverflowButton])
  Widget _moreButton() => IconButton(
    tooltip: '更多操作',
    iconSize: 20,
    padding: EdgeInsets.zero,
    style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
    icon: const Icon(Icons.more_vert),
    onPressed: onMenu,
  );

  /// 歌名(含徽标 / 只读红心)
  Widget _title(BuildContext context, TextStyle? style) {
    if (badgesInSubtitle) {
      return AdaptiveTextRow(
        title: song.name,
        style: style,
        marquee: titleMarquee,
      );
    }
    return SongTitleWithBadges(
      song: song,
      style: style,
      marquee: titleMarquee,
      extraBadges: [
        // 没有可点路径时才在这里画只读红心(不要做 leading, 否则歌名缩进不齐)
        if (readOnlyHeart && onToggleLike == null && liked) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.favorite,
            size: 13,
            color: Theme.of(context).colorScheme.primary,
          ),
        ],
      ],
    );
  }

  Widget _buildPlain(BuildContext context, bool playing) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final playable = song.playable;
    final grey = TextStyle(color: scheme.outline);
    final titleStyle = playing && playingTitleStyle
        ? _playingTitleStyle(theme)
        : (playable ? theme.textTheme.bodyMedium : grey);
    final subStyle =
        subtitleStyle ??
        theme.textTheme.labelSmall?.copyWith(
          color: playable ? scheme.onSurfaceVariant : scheme.outline,
        );
    final durationStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.outline,
    );
    final subtitleText = Text(
      _subtitleText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: subStyle,
    );

    final column = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(context, titleStyle),
        const SizedBox(height: 2),
        // 徽标放副标题行时任何宽度都可见(不会被标题区的宽度收起)
        if (badgesInSubtitle)
          Row(
            children: [
              SongFeeBadges(song: song),
              Expanded(child: subtitleText),
            ],
          )
        else
          subtitleText,
      ],
    );

    Widget trailing({double? maxWidth}) {
      final children = <Widget>[
        ?trailingExtra,
        if (showDuration) ...[
          if (maxWidth != null)
            // 时长是弹性项: 行尾触到上限时先截断它, 歌名/徽标不被挤掉
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  formatSongDuration(song.durationMs),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: durationStyle,
                ),
              ),
            )
          else ...[
            if (durationGap > 0) SizedBox(width: durationGap),
            Text(formatSongDuration(song.durationMs), style: durationStyle),
          ],
        ],
        if (onToggleLike != null) _likeButton(scheme),
        if (onMenu != null) _moreButton(),
        if (menuSource != null)
          SongOverflowButton(song: song, size: 20, source: menuSource!),
      ];
      final row = Row(mainAxisSize: MainAxisSize.min, children: children);
      if (maxWidth == null) return row;
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: row,
      );
    }

    final leading = <Widget>[
      if (indexText != null) ...[
        SizedBox(
          width: indexWidth,
          child: _indexOrPlaying(
            theme,
            playing,
            theme.textTheme.bodySmall?.copyWith(
              color: indexColor ?? scheme.outline,
            ),
          ),
        ),
        if (indexGap > 0) SizedBox(width: indexGap),
      ],
      if (coverSize != null) ...[
        CoverArt(url: song.coverUrl, size: coverSize!, radius: 4),
        if (coverGap > 0) SizedBox(width: coverGap),
      ],
    ];

    final Widget body;
    if (capTrailing) {
      body = LayoutBuilder(
        builder: (context, constraints) {
          // 行尾三件(时长 + 红心 + 更多)是全仓最宽 trailing: 不封顶时 300dp 下
          // 标题区只剩 ~117dp。宽度拿不到上限时退化成不封顶(不套 Flexible)。
          final maxTrailingWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth * 0.45
              : null;
          return Row(
            children: [
              ...leading,
              Expanded(child: column),
              trailing(maxWidth: maxTrailingWidth),
            ],
          );
        },
      );
    } else {
      body = Row(
        children: [...leading, Expanded(child: column), trailing()],
      );
    }

    return InkWell(
      onTap: tapOnlyWhenPlayable && !playable ? null : onTap,
      onLongPress: onLongPress,
      child: Container(
        color: playingTint && playing
            ? scheme.primary.withValues(alpha: 0.10)
            : null,
        padding: padding,
        child: body,
      ),
    );
  }

  Widget _buildTile(BuildContext context, bool playing) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final playable = song.playable;
    final grey = TextStyle(color: scheme.outline);
    final titleStyle = playing && playingTitleStyle
        ? _playingTitleStyle(theme)
        : (playable ? null : grey);
    // 极窄屏(用户的 vivo 逻辑宽仅 300dp): 行尾「时长 + 红心 + ...」会把标题区
    // 压到 ~49dp, 连一个 VIP 徽标都放不下。此时先牺牲时长(菜单/详情页仍有)。
    final narrow = MediaQuery.sizeOf(context).width < 340;

    final Widget? leading = (indexText == null && coverSize == null)
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (indexText != null) ...[
                SizedBox(
                  width: indexWidth,
                  child: _indexOrPlaying(
                    theme,
                    playing,
                    indexColor == null
                        ? theme.textTheme.bodySmall
                        : theme.textTheme.bodySmall?.copyWith(color: indexColor),
                  ),
                ),
                if (indexGap > 0) SizedBox(width: indexGap),
              ],
              if (coverSize != null)
                CoverArt(url: song.coverUrl, size: coverSize!, radius: 4),
            ],
          );

    return ListTile(
      dense: true,
      visualDensity: visualDensity,
      selected: playing,
      // 行左右留白统一走 layout.dart(默认 16+16 会白白吃掉 32dp);
      // 嵌在卡片里的列表传 [padding](卡片边缘 4 + 容器 12 = 16 的同一栅格)
      contentPadding: padding == EdgeInsets.zero ? kSongRowPadding : padding,
      leading: leading,
      title: _title(context, titleStyle),
      subtitle: Text(
        _subtitleText,
        // 不给 maxLines 会在窄宽度下逐字换行 => 竖排 + 高度暴涨(实测 378px)
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: subtitleStyle,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?trailingExtra,
          if (showDuration && !narrow)
            Text(
              formatSongDuration(song.durationMs),
              style: playable ? null : grey,
            ),
          if (onToggleLike != null) _likeButton(scheme),
          if (onMenu != null) _moreButton(),
          if (menuSource != null)
            SongOverflowButton(song: song, size: 20, source: menuSource!),
        ],
      ),
      onTap: tapOnlyWhenPlayable && !playable ? null : onTap,
      onLongPress: onLongPress,
    );
  }
}

/// 列表里的一行曲目: 红心 / VIP / 付费 / 无版权 的形态都收在这里。
///
/// 实现已收敛到 [SongRow](ListTile 臂), 本类只保留原有公开参数/默认值, 让搜索页、
/// 库内歌单详情等既有调用点继续用; 新代码请直接用 [SongRow]。
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    this.active,
    required this.liked,
    required this.onTap,
    this.onMenu,
    this.onToggleLike,
  });

  final rust.SongDto song;

  /// 显式指定"是否是正在播放"; 不传(推荐)就读全局 [nowPlayingSongId],
  /// 这样任何列表(搜索/最近听过/队列)都不用各自接线就能高亮(用户反馈)。
  final bool? active;
  final bool liked;
  final VoidCallback onTap;

  /// 行尾的"..."更多操作(下一首/喜欢/收藏到歌单/分享/评论/艺人/专辑/下载)
  final VoidCallback? onMenu;

  /// 点红心 = 喜欢/取消喜欢(与歌单详情页的曲目行同款行为).
  /// 不传时退到 [AppActions] 的 toggleLike(全局动作宿主);
  /// 两者都没有时红心退回"只读指示器", 不再假装可点.
  final VoidCallback? onToggleLike;

  @override
  Widget build(BuildContext context) {
    // 红心可点: 显式回调 > 全局动作宿主 > 无(退回只读指示器)
    final host = onToggleLike == null ? AppActions.maybeOf(context) : null;
    final onLike =
        onToggleLike ?? (host == null ? null : () => host.toggleLike(song));
    final grey = TextStyle(color: Theme.of(context).colorScheme.outline);
    return SongRow(
      song: song,
      layout: SongRowLayout.tile,
      coverSize: 40,
      active: active,
      // ListTile.selected 自己负责播放态文本色(不再叠一层主色加粗)
      playingTitleStyle: false,
      readOnlyHeart: true,
      liked: liked,
      onToggleLike: onLike,
      subtitleStyle: song.playable ? null : grey,
      onMenu: onMenu,
      onTap: onTap,
    );
  }
}
