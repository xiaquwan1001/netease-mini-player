import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'state_views.dart';

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

/// 小型等级徽标, 给资料卡一行里用: 高度 <= 32dp。
///
/// 组成: "Lv.N" + 可选等级名; isVip 用主色描边/底色; target>0 时文字下方
/// 一条 3dp 细进度条。高度定死 32dp, 300dp 窄屏 + 1.25 字号下文本按可用宽度
/// 省略, 不会撑破资料卡行高。
class LevelBadge extends StatelessWidget {
  const LevelBadge({super.key, required this.view, this.onTap});

  final UserLevelView view;
  final VoidCallback? onTap;

  /// 徽标高度上限(dp) —— 资料卡行高敏感, 别改大。
  static const double maxHeight = 32;

  /// 细进度条宽度(dp): FittedBox 内宽度无界, 必须给确定值。
  static const double _progressWidth = 52;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vip = view.isVip;

    final background = vip
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final border = vip ? scheme.primary : scheme.outlineVariant;
    final foreground = vip
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    final label = Flexible(
      child: Text(
        'Lv.${view.level}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
    final name = Flexible(
      child: Text(
        view.levelName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: vip ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          height: 1.1,
        ),
      ),
    );

    final Widget textRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        label,
        if (view.levelName.isNotEmpty) ...[const SizedBox(width: 4), name],
      ],
    );

    final Widget content = view.hasProgress
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              textRow,
              const SizedBox(height: 3),
              // FittedBox 下宽度无界, 进度条必须定宽; 52dp 约等于
              // "Lv.28" + 短等级名 的文本宽度, 视觉上正好占满徽标内宽。
              SizedBox(
                width: _progressWidth,
                height: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: view.fraction,
                    minHeight: 3,
                    backgroundColor: vip
                        ? scheme.primary.withValues(alpha: 0.24)
                        : scheme.outlineVariant,
                    valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                  ),
                ),
              ),
            ],
          )
        : textRow;

    final badge = Container(
      height: maxHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: vip ? 1.2 : 1),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: content,
        ),
      ),
    );

    if (onTap == null) return badge;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: badge,
    );
  }
}

/// 整页勋章墙: 顶部等级卡 + 每行 3 个的勋章网格, 支持下拉刷新。
///
/// 状态机与其它页一致: 加载中转圈 / 错误态 friendlyError + 重试 / 空态 /
/// 正常态。未获得的勋章灰显但仍占位显示(不隐藏)。

// ---------------------------------------------------------------------------
// Rust 接入层(上面是纯视图; 这里负责 DTO -> View 与页面打开)
// ---------------------------------------------------------------------------

/// 打开勋章墙. 默认走真实 Rust 数据; 测试可传 load 覆盖.
Future<void> showMedalWall(
  BuildContext context, {
  Future<MedalWallData> Function()? load,
  bool isVip = false,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MedalWallPage(
        load: load ?? () => loadMedalWallData(isVip: isVip),
        onBack: () => Navigator.of(context).maybePop(),
      ),
    ),
  );
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

class MedalWallPage extends StatefulWidget {
  const MedalWallPage({super.key, required this.load, this.onBack});

  /// 数据加载(注入式; Rust 接入时由外层包 rust.userLevel / rust.userMedals)。
  final Future<MedalWallData> Function() load;

  /// 自定义返回; 为 null 时用 AppBar 默认返回(Navigator.pop)。
  final VoidCallback? onBack;

  @override
  State<MedalWallPage> createState() => _MedalWallPageState();
}

class _MedalWallPageState extends State<MedalWallPage> {
  MedalWallData? _data;
  String? _error;
  bool _loading = false;

  /// 勋章图标边长(dp)
  static const double _medalSize = 56;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.load();
      if (!mounted) return;
      setState(() => _data = data);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 下拉刷新: 走同一条 loader。
  Future<void> _refresh() async {
    try {
      final data = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  void _back() {
    final onBack = widget.onBack;
    if (onBack != null) {
      onBack();
      return;
    }
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的勋章'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: _back,
        ),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_data == null && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_data == null) {
      return const LoadingView();
    }

    final data = _data!;
    final level = data.level;
    final medals = data.medals;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        // 空态也要能下拉刷新, 所以始终用可滚动容器
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          if (level != null) _LevelCard(view: level),
          if (level != null) const SizedBox(height: 16),
          if (medals.isEmpty)
            const EmptyView(
              padding: EdgeInsets.symmetric(vertical: 40, horizontal: 24),
              icon: Icons.military_tech_outlined,
              title: '还没有勋章',
              hint: '多听多分享, 徽章会陆续点亮',
            )
          else
            _MedalGrid(medals: medals, medalSize: _medalSize),
          if (_loading) ...[
            const SizedBox(height: 12),
            const LoadingView(size: 18),
          ],
        ],
      ),
    );
  }
}

/// 顶部等级卡(LevelBadge 放大版 + 等级名 + "x/y" 进度文字)。
class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.view});

  final UserLevelView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vip = view.isVip;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // LevelBadge 定高 32dp, 放大版靠 Transform.scale 而不是放开高度约束,
            // 这样窄屏 + 大字号也不会撑破卡片。
            // SizedBox 收住放大后的宽度: 否则 Transform.scale 会按放大量撑宽,
            // 300dp 窄屏时挤压右侧标题导致 Row 溢出。
            final badge = SizedBox(
              width: (LevelBadge.maxHeight * 2.6 * 1.25).clamp(72.0, 150.0),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Transform.scale(
                  scale: 1.25,
                  alignment: Alignment.centerLeft,
                  child: LevelBadge(view: view),
                ),
              ),
            );
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  view.levelName.isNotEmpty
                      ? view.levelName
                      : 'Lv.${view.level}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  view.hasProgress
                      ? '${view.progress}/${view.target}'
                      : '已达当前最高等级',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            );

            if (constraints.maxWidth < 240) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [badge, const SizedBox(height: 6), title],
              );
            }
            return Row(
              children: [
                badge,
                const SizedBox(width: 10),
                Expanded(child: title),
                if (vip) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.workspace_premium,
                    color: scheme.primary,
                    size: 20,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 每行 3 个的勋章网格。
class _MedalGrid extends StatelessWidget {
  const _MedalGrid({required this.medals, required this.medalSize});

  final List<MedalView> medals;
  final double medalSize;

  static const int _columns = 3;

  @override
  Widget build(BuildContext context) {
    // 用手工分行而不是 GridView: 整页外层已是 ListView, 内嵌可滚动网格需要
    // shrinkWrap + 固定宽高比, 窄屏/大字号下容易溢出。
    final rows = <Widget>[];
    for (var i = 0; i < medals.length; i += _columns) {
      final end = (i + _columns) > medals.length
          ? medals.length
          : (i + _columns);
      final slice = medals.sublist(i, end);
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < _columns; c++)
              Expanded(
                child: c < slice.length
                    ? _MedalTile(medal: slice[c], size: medalSize)
                    // 末行补空位, 保证每格等宽
                    : const SizedBox.shrink(),
              ),
          ],
        ),
      );
      if (end < medals.length) rows.add(const SizedBox(height: 14));
    }
    return Column(children: rows);
  }
}

/// 单个勋章: 图标 + 单行省略名称; 未获得的降低不透明度 + 灰底。
class _MedalTile extends StatelessWidget {
  const _MedalTile({required this.medal, required this.size});

  final MedalView medal;
  final double size;

  /// 未获得时的整体不透明度
  static const double unearnedOpacity = 0.45;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final obtained = medal.obtained;

    final iconWidget = SizedBox(
      width: size,
      height: size,
      child: medal.imageUrl == null
          ? Container(
              decoration: BoxDecoration(
                color: obtained
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(
                  color: obtained ? scheme.primary : scheme.outlineVariant,
                  width: obtained ? 1.4 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                obtained ? Icons.military_tech : Icons.lock_outline,
                size: size * 0.5,
                color: obtained ? scheme.primary : scheme.outline,
              ),
            )
          : ClipOval(
              child: NetImage(
                url: medal.imageUrl,
                width: size,
                height: size,
                icon: Icons.military_tech,
              ),
            ),
    );

    final tile = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconWidget,
        const SizedBox(height: 6),
        Text(
          medal.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: obtained ? scheme.onSurface : scheme.onSurfaceVariant,
            fontWeight: obtained ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );

    final decorated = Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: obtained
            ? Colors.transparent
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: tile,
    );

    final withTooltip = Tooltip(
      message: medal.description.isEmpty ? medal.name : medal.description,
      child: decorated,
    );

    if (obtained) return withTooltip;
    // 未获得: 灰显但仍显示(不隐藏), 用 Opacity 便于测试断言差异。
    return Opacity(opacity: unearnedOpacity, child: withTooltip);
  }
}
