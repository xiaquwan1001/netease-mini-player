import 'package:flutter/material.dart';

import 'rust/api.dart' as rust;
import 'user_page.dart';

/// 头像点击 -> 用户主页。
///
/// 动态/评论区散布在多个页面(列表卡、动态详情、歌曲详情、播客详情),
/// 逐层透传 onOpenUser 回调会污染一堆构造函数; 这里用与 AppActions 同款的
/// 全局注入: main 启动时把"点歌播放"回调塞进来, 各处直接用 [UserAvatarTap]。
class UserNav {
  UserNav._();

  /// 用户主页里点歌单/歌曲时的播放回调(由 main 注入; 未注入时页面仍可浏览)
  static void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  static bool canOpen(BigInt userId) => userId > BigInt.zero;

  /// 实际打开动作(测试可替换成假实现; 生产默认 showUserPage)
  static Future<void> Function(
    BuildContext context,
    BigInt userId, {
    String? nickname,
  })?
  opener;

  static Future<void> open(
    BuildContext context,
    BigInt userId, {
    String? nickname,
  }) {
    if (!canOpen(userId)) return Future<void>.value();
    final custom = opener;
    if (custom != null) {
      return custom(context, userId, nickname: nickname);
    }
    return showUserPage(
      context,
      userId: userId,
      fallbackNickname: nickname,
      onPlaySongs: onPlaySongs,
    );
  }
}

/// 包住头像(或昵称), 点击进入用户主页; uid 未知(0)时不拦截点击。
class UserAvatarTap extends StatelessWidget {
  const UserAvatarTap({
    super.key,
    required this.userId,
    required this.child,
    this.nickname,
  });

  final BigInt userId;
  final Widget child;
  final String? nickname;

  @override
  Widget build(BuildContext context) {
    if (!UserNav.canOpen(userId)) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => UserNav.open(context, userId, nickname: nickname),
      child: child,
    );
  }
}
