import 'package:flutter/material.dart';

import 'rust/api.dart' as rust;

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

/// 列表里的一行曲目: 红心 / VIP / 付费 / 无版权 的形态都收在这里
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.active,
    required this.liked,
    required this.onTap,
  });

  final rust.SongDto song;
  final bool active;
  final bool liked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playable = song.playable;
    final grey = TextStyle(color: scheme.outline);
    return ListTile(
      dense: true,
      selected: active,
      leading: liked
          ? Icon(Icons.favorite, size: 16, color: scheme.primary)
          : null,
      title: Row(
        children: [
          Flexible(
            child: Text(
              song.name,
              overflow: TextOverflow.ellipsis,
              style: playable ? null : grey,
            ),
          ),
          if (playable && song.vip) const VipBadge(small: true),
          if (playable && !song.vip && song.paid) const PaidBadge(),
          if (!playable) const UnplayableBadge(),
        ],
      ),
      subtitle: Text(
        '${song.artist} · ${song.album}',
        style: playable ? null : grey,
      ),
      trailing: Text(
        '${song.durationMs ~/ BigInt.from(1000)}s',
        style: playable ? null : grey,
      ),
      onTap: onTap,
    );
  }
}
