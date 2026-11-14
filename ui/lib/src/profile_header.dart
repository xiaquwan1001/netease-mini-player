import 'package:flutter/material.dart';

import 'layout.dart';
import 'profile_banner.dart';
import 'profile_scaffold.dart';
import 'rust/api.dart' as rust;

/// 个人主页头部卡片: 背景图 + 头像/昵称/VIP/签名 + 关注/粉丝/等级一行。
/// 未登录时显示默认灰背景卡片, 点击触发 onTap(登录)。
///
/// 关注/取关动作不在本组件内(发生在关注/粉丝列表页), 成功后由持有
/// [GlobalKey<ProfileHeaderState>] 的一方调用 [ProfileHeaderState.refreshCounts]
/// 重拉 [loadDetail](默认可接 rust.profileDetail / rust.followCounts)刷新
/// 「关注 N / 粉丝 M」, 不必等重进页面。
class ProfileHeader extends StatefulWidget {
  const ProfileHeader({
    super.key,
    this.detail,
    this.fallbackNickname,
    required this.loggedIn,
    this.onTap,
    this.onTapFollows,
    this.onTapFolloweds,
    this.loadDetail,
    this.onEditSignature,
  });

  final rust.ProfileDetail? detail;
  final String? fallbackNickname;
  final bool loggedIn;
  final VoidCallback? onTap;

  /// 点"关注 N" / "粉丝 N"
  final VoidCallback? onTapFollows;
  final VoidCallback? onTapFolloweds;

  /// 注入式详情 loader(refreshCounts 用, 测试可注入 mock);
  /// 未注入或未登录时 refreshCounts 是 no-op。
  final Future<rust.ProfileDetail?> Function()? loadDetail;

  /// 「编辑简介」行内入口(「我的」页注入): 与简介同一行的小按钮,
  /// 不再单独占一个「简介」区块(用户反馈 6)。
  final VoidCallback? onEditSignature;

  @override
  ProfileHeaderState createState() => ProfileHeaderState();
}

class ProfileHeaderState extends State<ProfileHeader> {
  rust.ProfileDetail? _detail;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
  }

  @override
  void didUpdateWidget(ProfileHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父层带来新数据则以父层为准; 登出时清空。
    // 父层传 null 但仍登录时保留本地已刷新的数据(避免重 build 抹掉)。
    if (widget.detail != null) {
      _detail = widget.detail;
    } else if (!widget.loggedIn) {
      _detail = null;
    }
  }

  /// 关注/取关成功后调用: 重拉 [ProfileHeader.loadDetail] 更新「关注 N / 粉丝 M」。
  /// 返回是否刷新成功; 未注入 loader/未登录/已在刷新中/加载失败时返回 false,
  /// 失败时保留旧数字不崩。
  Future<bool> refreshCounts() async {
    final load = widget.loadDetail;
    if (load == null || !widget.loggedIn || _refreshing) return false;
    _refreshing = true;
    try {
      final detail = await load();
      if (!mounted) return false;
      if (detail != null) {
        setState(() => _detail = detail);
      }
      return detail != null;
    } catch (_) {
      return false; // 失败保留旧数字
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = _detail;
    final nickname = widget.loggedIn
        ? (d?.nickname.isNotEmpty == true
              ? d!.nickname
              : (widget.fallbackNickname ?? '未命名用户'))
        : '未登录';
    final signature = widget.loggedIn ? (d?.signature ?? '') : '';
    // 空简介时给一句可点的占位(「编辑简介」入口在右侧), 不再靠独立区块提示
    final subtitle = !widget.loggedIn
        ? null
        : (signature.trim().isEmpty ? '还没有填写简介' : signature.trim());
    final editAction = widget.onEditSignature == null
        ? null
        : TextButton(
            onPressed: widget.onEditSignature,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
            ),
            child: const Text('编辑简介'),
          );

    return Card(
      clipBehavior: Clip.antiAlias,
      // 页面本身已有 12dp 留白, 卡片再加 12 会变成距屏 24(用户反馈"个人背景左右有缝")。
      margin: kCardMargin,
      child: InkWell(
        onTap: widget.onTap,
        // 背景横幅 + 身份卡统一走 ProfileBanner: 取图按真实像素矩形 x 清晰度档位,
        // 点图看全屏原图; 名字/签名/统计落到图片**下方**的 surface 卡片(不再压图).
        // 「我的」页(mine_view)也走这里, 一处修复两处受益.
        child: ProfileBanner(
          imageUrl: widget.loggedIn ? d?.backgroundUrl : null,
          avatarUrl: widget.loggedIn ? d?.avatarUrl : null,
          title: nickname,
          subtitle: subtitle,
          subtitleAction: editAction,
          subtitleMaxLines: 3,
          vip: widget.loggedIn && (d?.vip ?? false),
          // 统计行与艺人页/他人主页同一套 chip: 之前这里是自己一份
          // Wrap + Text(' · ') + _StatEntry, 「我的」页与别人主页的点缀/字号都不同
          footer: widget.loggedIn
              ? ProfileStatRow(
                  chips: [
                    ProfileStatChip(
                      icon: Icons.people_outline,
                      label: '关注 ${d?.follows ?? BigInt.zero}',
                      onTap: widget.onTapFollows,
                    ),
                    ProfileStatChip(
                      icon: Icons.person_outline,
                      label: '粉丝 ${d?.followeds ?? BigInt.zero}',
                      onTap: widget.onTapFolloweds,
                    ),
                    ProfileStatChip(
                      icon: Icons.military_tech_outlined,
                      label: 'Lv.${d?.level ?? BigInt.zero}',
                    ),
                  ],
                )
              : Text(
                  '点击登录后同步账号资料',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
    );
  }
}
