import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';
import 'format.dart' show formatDurationMs;
import 'layout.dart' show kSongRowPadding;
import 'rust/api.dart' as rust;
import 'song_actions.dart';

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

/// 列表里的一行曲目: 红心 / VIP / 付费 / 无版权 的形态都收在这里
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.active,
    required this.liked,
    required this.onTap,
    this.onMenu,
    this.onToggleLike,
  });

  final rust.SongDto song;
  final bool active;
  final bool liked;
  final VoidCallback onTap;

  /// 行尾的"..."更多操作(下一首/喜欢/收藏到歌单/分享/评论/歌手/专辑/下载)
  final VoidCallback? onMenu;

  /// 点红心 = 喜欢/取消喜欢(与歌单详情页 _SongRow 同款行为).
  /// 不传时退到 [AppActions] 的 toggleLike(全局动作宿主);
  /// 两者都没有时红心退回"只读指示器", 不再假装可点.
  final VoidCallback? onToggleLike;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playable = song.playable;
    final grey = TextStyle(color: scheme.outline);
    // 红心可点: 显式回调 > 全局动作宿主 > 无(退回只读指示器)
    final host = onToggleLike == null ? AppActions.maybeOf(context) : null;
    final onLike =
        onToggleLike ?? (host == null ? null : () => host.toggleLike(song));
    // 极窄屏(用户的 vivo 逻辑宽仅 300dp): 行尾「时长 + 红心 + ...」会把标题区
    // 压到 ~49dp, 连一个 VIP 徽标都放不下。此时先牺牲时长(菜单/详情页仍有),
    // 把横向空间让给歌名与徽标 —— 徽标优先于时长。
    final narrow = MediaQuery.sizeOf(context).width < 340;
    return ListTile(
      dense: true,
      selected: active,
      // 行左右留白统一走 layout.dart(默认 16+16 会白白吃掉 32dp)
      contentPadding: kSongRowPadding,
      // 每首歌展示封面(搜索结果/歌单/最近听过统一)
      leading: CoverArt(url: song.coverUrl, size: 40, radius: 4),
      // 徽标位置统一到歌名之后(与推荐/歌单/队列里的 SongTitleWithBadges 一致):
      // 用户反馈"搜索结果里 VIP 标在歌手前面, 和推荐页不一致"。
      // 徽标是固定宽度, 只有歌名 Expanded 会被压缩, 再窄也不会把徽标挤掉。
      title: SongTitleWithBadges(
        song: song,
        style: playable ? null : grey,
        marquee: true,
        extraBadges: [
          // 没有可点路径时才在这里画只读红心(不要做 leading, 否则歌名缩进不齐);
          // 可点红心统一放行尾, 与歌单详情页的位置/行为一致
          if (onLike == null && liked) ...[
            const SizedBox(width: 4),
            Icon(Icons.favorite, size: 13, color: scheme.primary),
          ],
        ],
      ),
      subtitle: Text(
        '${song.artist} · ${song.album}',
        // 不给 maxLines 会在窄宽度下逐字换行 => 竖排 + 高度暴涨(实测 378px)
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: playable ? null : grey,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!narrow)
            Text(
              formatSongDuration(song.durationMs),
              style: playable ? null : grey,
            ),
          // 命中区: 高度保持 48dp, 宽度收到 40dp(两枚按钮省下 16dp 给歌名)。
          // visualDensity.compact 同时压掉 IconButton 的默认内边距。
          if (onLike != null)
            IconButton(
              tooltip: liked ? '取消喜欢' : '喜欢',
              iconSize: 20,
              padding: EdgeInsets.zero,
              // tapTargetSize 默认 padded 会强行把命中区撑到 48x48(压掉 constraints),
              // 这正是"改了 minWidth 却仍占 48dp"的原因。shrinkWrap 后宽度才真的是 40。
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
              icon: Icon(
                liked ? Icons.favorite : Icons.favorite_border,
                size: 20,
                color: liked ? scheme.primary : null,
              ),
              onPressed: onLike,
            ),
          if (onMenu != null)
            IconButton(
              tooltip: '更多操作',
              iconSize: 20,
              padding: EdgeInsets.zero,
              // tapTargetSize 默认 padded 会强行把命中区撑到 48x48(压掉 constraints),
              // 这正是"改了 minWidth 却仍占 48dp"的原因。shrinkWrap 后宽度才真的是 40。
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
              icon: const Icon(Icons.more_vert),
              onPressed: onMenu,
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}
