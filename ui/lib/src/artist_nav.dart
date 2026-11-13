import 'package:flutter/material.dart';

import 'artist_page.dart';
import 'rust/api.dart' as rust;
import 'toast.dart';

/// 艺人头像点击 -> 艺人主页。
///
/// 与 [UserNav] 同形: 关注动态流的艺人 chip / 「全部艺人」面板 / 动态卡上的艺人
/// 头像散布在多个页面, 逐层透传回调会污染构造函数; 这里用全局注入,
/// main 启动时把「点歌播放」「打开专辑」塞进来, 各处直接用 [ArtistAvatarTap]。
///
/// 与 [UserNav] 分开而不是合并成一个"人物导航": 艺人主页与用户主页是两份数据源
/// (artistDetail vs userProfile), id 空间也不同, 合在一起只会让调用方分不清该传哪种 id。
class ArtistNav {
  ArtistNav._();

  /// 艺人主页里点歌 / 播放全部时的回调(由 main 注入; 未注入时页面仍可浏览)
  static void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  /// 艺人主页里点专辑的回调(由 main 注入; 未注入时专辑卡不可点)
  static void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum;

  static bool canOpen(BigInt artistId) => artistId > BigInt.zero;

  /// 实际打开动作(测试可替换成假实现; 生产默认 showArtistDetail)
  static Future<void> Function(
    BuildContext context,
    BigInt artistId, {
    String? name,
  })?
  opener;

  static Future<void> open(
    BuildContext context,
    BigInt artistId, {
    String? name,
  }) {
    if (!canOpen(artistId)) return Future<void>.value();
    final custom = opener;
    if (custom != null) {
      return custom(context, artistId, name: name);
    }
    // 播放回调没注入时给出明确提示, 而不是让用户点了歌没反应
    return showArtistDetail(
      context,
      artistId: artistId,
      name: name,
      onPlaySongs: onPlaySongs ?? (_, _) => showToast(context, '当前页面不支持播放'),
      onOpenAlbum: onOpenAlbum,
    );
  }
}

/// 包住头像(或名字), 点击进入艺人主页; id 未知(<=0)时不拦截点击。
///
/// 用在"整行/整块是筛选, 只有头像进主页"的场景: 只包住头像本身,
/// 命中区小且不与外层的筛选点击抢地方。
class ArtistAvatarTap extends StatelessWidget {
  const ArtistAvatarTap({
    super.key,
    required this.artistId,
    required this.child,
    this.name,
  });

  final BigInt artistId;
  final Widget child;
  final String? name;

  @override
  Widget build(BuildContext context) {
    if (!ArtistNav.canOpen(artistId)) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ArtistNav.open(context, artistId, name: name),
      child: child,
    );
  }
}
