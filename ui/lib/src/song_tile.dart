import 'package:flutter/material.dart';

import 'adaptive_text_row.dart';
import 'cover_art.dart';
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
      padding: EdgeInsets.symmetric(horizontal: small ? 4 : 6, vertical: small ? 1 : 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.5), width: 0.8),
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
String formatSongDuration(BigInt durationMs) {
  final total =
      durationMs.isNegative ? 0 : (durationMs ~/ BigInt.from(1000)).toInt();
  String two(int v) => v.toString().padLeft(2, '0');
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  // 超过 1 小时才带小时位(小时不补零, 与歌单详情 h:mm:ss 一致)
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '${two(minutes)}:${two(seconds)}';
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
    final onLike = onToggleLike ??
        (host == null ? null : () => host.toggleLike(song));
    return ListTile(
      dense: true,
      selected: active,
      // 每首歌展示封面(搜索结果/歌单/最近听过统一)
      leading: CoverArt(url: song.coverUrl, size: 40, radius: 4),
      // 窄宽降级已收敛到共享组件 AdaptiveTextRow(Expanded + 单行 marquee;
      // 标题区 <120px 时整组隐藏装饰性徽标, 绝不把歌名压到 0 宽).
      title: AdaptiveTextRow(
        title: song.name,
        style: playable ? null : grey,
        badges: [
          // 没有可点路径时才在这里画只读红心(不要做 leading, 否则歌名缩进不齐);
          // 可点红心统一放行尾, 与歌单详情页的位置/行为一致
          if (onLike == null && liked)
            Icon(Icons.favorite, size: 13, color: scheme.primary),
          if (playable && song.vip) const VipBadge(small: true),
          if (playable && !song.vip && song.paid) const PaidBadge(),
          if (!playable) const UnplayableBadge(),
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
          Text(
            formatSongDuration(song.durationMs),
            style: playable ? null : grey,
          ),
          // 命中区 ≥48dp: compact 密度 + iconSize 20 只有 40dp, 换成显式 constraints
          if (onLike != null)
            IconButton(
              tooltip: liked ? '取消喜欢' : '喜欢',
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.more_vert),
              onPressed: onMenu,
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}
