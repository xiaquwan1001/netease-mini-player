import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'rust/api.dart' as rust;

/// 个人主页头部卡片: 背景图 + 头像/昵称/VIP/签名 + 关注/粉丝/等级一行。
/// 未登录时显示默认灰背景卡片, 点击触发 onTap(登录)。
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    this.detail,
    this.fallbackNickname,
    required this.loggedIn,
    this.onTap,
    this.onTapFollows,
    this.onTapFolloweds,
  });

  final rust.ProfileDetailDto? detail;
  final String? fallbackNickname;
  final bool loggedIn;
  final VoidCallback? onTap;

  /// 点"关注 N" / "粉丝 N"
  final VoidCallback? onTapFollows;
  final VoidCallback? onTapFolloweds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = detail;
    final nickname = loggedIn
        ? (d?.nickname.isNotEmpty == true
              ? d!.nickname
              : (fallbackNickname ?? '未命名用户'))
        : '未登录';
    final signature = loggedIn ? (d?.signature ?? '') : '';

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(12),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 130,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 背景: 登录且有背景图时用图片, 否则灰底
                  if (loggedIn && d?.backgroundUrl != null)
                    NetImage(
                      url: d!.backgroundUrl,
                      width: double.infinity,
                      height: 130,
                      fit: BoxFit.cover,
                    )
                  else
                    ColoredBox(color: scheme.surfaceContainerHighest),
                  // 顶部/底部黑色渐变保证白字可读
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black38,
                          Colors.transparent,
                          Colors.black54,
                        ],
                        stops: [0, 0.4, 1],
                      ),
                    ),
                  ),
                  // 右上角"账号管理"小按钮
                  if (onTap != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: onTap,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.manage_accounts_outlined,
                                  size: 14,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  '账号管理',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 底部覆盖: 头像 + 昵称/VIP/签名
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 12,
                    child: Row(
                      children: [
                        // 白边圆形头像
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: CircleCover(
                            url: loggedIn ? d?.avatarUrl : null,
                            size: 64,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      nickname,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                  if (loggedIn && (d?.vip ?? false)) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE0342C),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'VIP',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              if (signature.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    signature,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 底部统计行: 关注 X · 粉丝 Y · Lv.Z(缺失显示 0)
            // 关注/粉丝可点, 进去看列表
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: loggedIn
                  ? Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _StatEntry(
                          label: '关注 ${d?.follows ?? BigInt.zero}',
                          onTap: onTapFollows,
                        ),
                        Text(
                          ' · ',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        _StatEntry(
                          label: '粉丝 ${d?.followeds ?? BigInt.zero}',
                          onTap: onTapFolloweds,
                        ),
                        Text(
                          ' · Lv.${d?.level ?? BigInt.zero}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    )
                  : Text(
                      '点击登录后同步账号资料',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 可点的统计数字(关注/粉丝)
class _StatEntry extends StatelessWidget {
  const _StatEntry({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: onTap == null
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.primary,
        );
    if (onTap == null) return Text(label, style: style);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Text(label, style: style),
      ),
    );
  }
}
