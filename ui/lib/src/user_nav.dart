import 'package:flutter/material.dart';

import 'artist_nav.dart';
import 'rust/api.dart' as rust;
import 'user_page.dart';

/// 头像点击 -> 这个人该去的主页。
///
/// 动态/评论区散布在多个页面(列表卡、动态详情、歌曲详情、播客详情),
/// 逐层透传 onOpenUser 回调会污染一堆构造函数; 这里用与 AppActions 同款的
/// 全局注入: main 启动时把"点歌播放"回调塞进来, 各处直接用 [UserAvatarTap]。
///
/// **统一口径(2026-11-14)**: 头像点击不直接假定"这是用户主页"。
/// 网易云的 user id 与 artist id 是两个 id 空间 —— 音乐人账号的 user id 在动态里
/// 只以一个 user id 出现(动态 JSON 的 user 对象没有 artistId, 只有 userType),
/// 真正的映射在 user_detail 的 `profile.artistId`。所以这里先解析艺人身份:
///   - 有 artistId -> 进艺人主页([ArtistNav]), 与「搜索 -> 艺人」完全同一个页面;
///   - 没有       -> 进用户主页([showUserPage]); 用户页里若有歌手身份另有入口。
/// 解析失败/网络异常一律退回用户主页(不挡用户的路)。
class UserNav {
  UserNav._();

  /// 用户主页里点歌单/歌曲时的播放回调(由 main 注入; 未注入时页面仍可浏览)
  static void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  static bool canOpen(BigInt userId) => userId > BigInt.zero;

  /// 整体接管打开动作(测试用: 不再解析艺人身份)
  static Future<void> Function(
    BuildContext context,
    BigInt userId, {
    String? nickname,
  })?
  opener;

  /// 只接管"进用户主页"这一步(测试用: 不联网也能断言落到了用户主页)
  static Future<void> Function(
    BuildContext context,
    BigInt userId, {
    String? nickname,
  })?
  userOpener;

  /// user id -> artist id 的解析(测试注入; 默认查 [rust.userProfile] 的 artistId)
  static Future<BigInt> Function(BigInt userId)? artistIdResolver;

  /// 解析结果缓存(同一次会话里反复点头像不必重复请求)。
  /// 注入 [artistIdResolver] 时不走缓存, 免得测试之间串味。
  static final Map<String, BigInt> _artistIdCache = <String, BigInt>{};

  static void clearCache() => _artistIdCache.clear();

  static Future<BigInt> _loadArtistId(BigInt userId) async {
    final detail = await rust.userProfile(userId: userId);
    return detail.artistId ?? BigInt.zero;
  }

  /// 这个 user id 有没有艺人身份? 返回 artist id(0 = 普通用户)。
  ///
  /// 解析失败一律当"普通用户"(不抛): 头像点击不能因为一次查询挂掉而没有反应。
  static Future<BigInt> resolveArtistId(BigInt userId) async {
    if (!canOpen(userId)) return BigInt.zero;
    final injected = artistIdResolver;
    if (injected != null) {
      try {
        return _sanitize(await injected(userId));
      } catch (_) {
        return BigInt.zero;
      }
    }
    final key = userId.toString();
    final cached = _artistIdCache[key];
    if (cached != null) return cached;
    BigInt id;
    try {
      id = _sanitize(await _loadArtistId(userId));
    } catch (_) {
      id = BigInt.zero;
    }
    _artistIdCache[key] = id;
    return id;
  }

  static BigInt _sanitize(BigInt id) => id.isNegative ? BigInt.zero : id;

  static Future<void> open(
    BuildContext context,
    BigInt userId, {
    String? nickname,
  }) async {
    if (!canOpen(userId)) return;
    final custom = opener;
    if (custom != null) {
      return custom(context, userId, nickname: nickname);
    }
    final artistId = await resolveArtistId(userId);
    if (!context.mounted) return;
    if (ArtistNav.canOpen(artistId)) {
      // 音乐人: 与「搜索 -> 艺人」同一个页面(ArtistAvatarTap 的同一入口)
      return ArtistNav.open(context, artistId, name: nickname);
    }
    return _openUserPage(context, userId, nickname: nickname);
  }

  static Future<void> _openUserPage(
    BuildContext context,
    BigInt userId, {
    String? nickname,
  }) {
    final custom = userOpener;
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

/// 包住头像(或昵称), 点击进入这个人的主页(艺人主页 / 用户主页, 见 [UserNav]);
/// uid 未知(0)时不拦截点击。
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
