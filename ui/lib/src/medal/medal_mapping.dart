import '../rust/api.dart' as rust;

/// 等级 / 勋章墙 · 纯 Dart 视图模型(不依赖 Rust 绑定)。
///
/// 数据由注入的 loader 提供, 之后由编排者接 Rust 的 user_level / user_medal
/// 并把 DTO 转成这里的 View 类型; 本文件不做任何网络请求。

/// 一枚勋章(已获得 / 未获得都会出现在墙上, 未获得的灰显而不是隐藏)。
class MedalView {
  const MedalView({
    required this.id,
    required this.name,
    this.imageUrl,
    this.description = '',
    this.obtained = true,
  });

  final int id;
  final String name;

  /// 勋章图标直链; null 时用本地 Icon 占位(测试一律传 null, 不发网络请求)。
  final String? imageUrl;
  final String description;

  /// 是否已获得。false 时整块降低不透明度 + 灰底。
  final bool obtained;

  @override
  String toString() => 'MedalView(#$id $name obtained=$obtained)';
}

/// 等级(徽标 / 顶部等级卡共用)。
class UserLevelView {
  const UserLevelView({
    required this.level,
    this.levelName = '',
    this.progress = 0,
    this.target = 0,
    this.isVip = false,
  });

  final int level;

  /// 等级名, 如 "音乐达人"; 空则不显示。
  final String levelName;

  /// 当前成长值 / 距下一级所需成长值(语义同 user_level.progress / target)。
  final int progress;
  final int target;

  /// 黑胶(或会员)等级: 用主色描边/底色区分。
  final bool isVip;

  /// 进度占比, target<=0(已到顶/无成长值体系)时按 0 处理, 且不出进度条。
  double get fraction {
    if (target <= 0) return 0;
    return (progress / target).clamp(0.0, 1.0);
  }

  /// 有进度可画(只在 target>0 时出进度条)。
  bool get hasProgress => target > 0;

  @override
  String toString() =>
      'UserLevelView(Lv.$level $levelName $progress/$target vip=$isVip)';
}

/// 勋章墙一页的数据。
class MedalWallData {
  const MedalWallData({this.level, this.medals = const <MedalView>[]});

  /// 未登录 / 接口没有等级信息时为 null, 等级卡整块不显示。
  final UserLevelView? level;
  final List<MedalView> medals;

  @override
  String toString() => 'MedalWallData(level=$level medals=${medals.length})';
}

/// user_level + user_medal. 等级失败只影响顶部等级卡(徽章墙照常显示);
/// 勋章接口本身有服务端限流, provider 侧已做有界重试.
Future<MedalWallData> loadMedalWallData({bool isVip = false}) async {
  final levelFuture = _tryUserLevel();
  final medals = await rust.userMedals();
  final level = await levelFuture;
  return mapMedalWall(level, medals, isVip: isVip);
}

Future<rust.UserLevel?> _tryUserLevel() async {
  try {
    return await rust.userLevel();
  } catch (_) {
    return null;
  }
}

/// DTO -> 视图(纯函数, 便于单测).
/// 注意: user_level 的 progress 按**听歌数**算(nowPlayCount/nextPlayCount),
/// 不是成长值; 这里直接把两个计数当 progress/target 传给进度条.
MedalWallData mapMedalWall(
  rust.UserLevel? level,
  List<rust.UserMedal> medals, {
  bool isVip = false,
}) {
  return MedalWallData(
    level: level == null
        ? null
        : UserLevelView(
            level: level.level,
            progress: level.nowPlayCount.toInt(),
            target: level.nextPlayCount.toInt(),
            isVip: isVip,
          ),
    medals: [
      for (var i = 0; i < medals.length; i++)
        MedalView(
          id: i,
          name: medals[i].name,
          imageUrl: medals[i].picUrl,
          description: medals[i].condition,
          obtained: medals[i].obtained,
        ),
    ],
  );
}
