import 'package:flutter/material.dart';

import 'adaptive_text_row.dart';
import 'cover_art.dart';
import 'playback.dart';
import 'queue.dart' show PlayMode;
import 'rust/api.dart' as rust;
import 'song_tile.dart';

/// 常驻播放条的不可变数据快照。
///
/// HomePage 每次 build 生成一份; 与上一份相等时 ValueNotifier 不通知,
/// 播放条因此只在"数据真的变了"时才重建(回调集合另行经 [PlayerBarActions] 投递)。
class PlayerBarData {
  const PlayerBarData({
    required this.player,
    required this.current,
    required this.liked,
    required this.queueIndex,
    required this.queueLength,
    required this.dragMax,
    required this.dragMs,
    this.mode = PlayMode.repeatAll,
    this.heartActive = false,
  });

  final PlayerView player;
  final rust.SongDto? current;
  final bool liked;

  /// 当前曲在队列里的序号(1 起)与队列长度
  final int queueIndex;
  final int queueLength;

  /// 拖动中冻结的量程与位置(null = 跟随播放状态)
  final double? dragMax;
  final double? dragMs;

  /// 播放顺序(含"心动模式"这一虚拟档, 用 [heartActive] 表示)
  final PlayMode mode;
  final bool heartActive;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PlayerBarData &&
        other.liked == liked &&
        other.queueIndex == queueIndex &&
        other.queueLength == queueLength &&
        other.dragMax == dragMax &&
        other.dragMs == dragMs &&
        other.mode == mode &&
        other.heartActive == heartActive &&
        _playerEquals(other.player, player) &&
        identical(other.current, current);
  }

  @override
  int get hashCode => Object.hash(
    liked,
    queueIndex,
    queueLength,
    dragMax,
    dragMs,
    mode,
    heartActive,
    player.trackId,
    player.playing,
    player.positionMs,
    player.durationMs,
    player.volume,
    identityHashCode(current),
  );

  static bool _playerEquals(PlayerView a, PlayerView b) =>
      a.trackId == b.trackId &&
      a.playing == b.playing &&
      a.positionMs == b.positionMs &&
      a.durationMs == b.durationMs &&
      a.volume == b.volume;
}

/// 常驻播放条的回调集合: 不可变, 同一实例跨帧复用(HomePage 建一次后不再变)。
class PlayerBarActions {
  const PlayerBarActions({
    required this.onSeekStart,
    required this.onSeekChanging,
    required this.onSeekEnd,
    required this.onToggleLyrics,
    required this.onOpenAlbum,
    required this.onToggleLike,
    required this.onToggle,
    required this.onNext,
    required this.onCycleMode,
    required this.onOpenQueue,
  });

  final void Function(double ms) onSeekStart;
  final void Function(double ms) onSeekChanging;
  final void Function(double ms) onSeekEnd;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenAlbum;
  final VoidCallback onToggleLike;
  final VoidCallback onToggle;
  final VoidCallback onNext;

  /// 播放顺序轮转(列表循环→单曲→顺序→随机→心动, 心动不可用时跳过)
  final VoidCallback onCycleMode;

  /// 打开播放队列面板(播放条最右侧)
  final VoidCallback onOpenQueue;
}

/// 毫秒时长 → `mm:ss`(分钟补零; 超 60 分钟继续累计, 与原 main.dart `_fmt` 同口径,
/// 不用 format.dart 的 `formatDurationMs` —— 那个在满一小时会变 `h:mm:ss`).
String _fmt(BigInt ms) {
  final total = (ms ~/ BigInt.from(1000)).toInt();
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 播放顺序图标/文案: 通知栏、播放条、详情页共用一份口径。
const Map<PlayMode, IconData> playModeIcons = {
  PlayMode.repeatAll: Icons.repeat,
  PlayMode.repeatOne: Icons.repeat_one,
  PlayMode.sequence: Icons.playlist_play,
  PlayMode.shuffle: Icons.shuffle,
};

const Map<PlayMode, String> playModeLabels = {
  PlayMode.repeatAll: '列表循环',
  PlayMode.repeatOne: '单曲循环',
  PlayMode.sequence: '顺序播放',
  PlayMode.shuffle: '随机播放',
};

/// 常驻播放条: 从 HomePage.bottomNavigationBar 上移到根布局(见 [PlayerBarHost])。
///
/// 数据([PlayerBarData])与回调([PlayerBarActions])全部由 _HomePageState 注入
/// (播放状态与队列只有一份, 在那边), 这里只负责排版,
/// 方便被根布局在任意路由之上渲染。
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({
    super.key,
    required this.data,
    required this.actions,
    required this.absorbBottomInset,
  });

  final PlayerBarData data;
  final PlayerBarActions actions;

  /// 没有底部导航时自己吃掉系统手势区(有导航时由 NavigationBar 的 SafeArea 负责)
  final bool absorbBottomInset;

  /// 播放条上的紧凑图标按钮: 40dp 点击区 + 无内边距.
  ///
  /// 合并成一行后总宽 = 封面 52 + 4×40 = 212dp, 300dp 窄屏上文本仍有 ~90dp,
  /// 配合 Expanded + ellipsis 不会溢出.
  Widget _barIcon({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: icon,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = data.player;
    final current = data.current;
    final liked = data.liked;
    final dur = player.durationMs.toDouble();
    // 拖动中冻结量程: 自动续播会让 duration 突跳
    final maxMs = data.dragMax ?? (dur <= 0 ? 1.0 : dur);
    final pos = (data.dragMs ?? player.positionMs.toDouble()).clamp(0.0, maxMs);
    return Material(
      elevation: 8,
      // 有底部导航时, 底部的系统安全区由 NavigationBar 自己的 SafeArea 负责,
      // 这里再吃一次 bottom inset 会在播放条与底栏之间留出一条空白(R4);
      // 二级页上没有导航栏, 就得自己吃掉这块(否则被系统手势条压住一条)。
      child: SafeArea(
        // top: false —— 这一条是回归根因: 播放条现在挂根布局上(Navigator 之外),
        // 根 MediaQuery.padding.top 还是状态栏高度; 若 SafeArea 默认 top: true,
        // 播放条顶部会多出一条等于状态栏高度的空白带(bar 变高 ⇒ 挤压内容区)。
        // 状态栏安全区由页面自己的 AppBar/body Padding 负责。
        top: false,
        bottom: absorbBottomInset,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条: 用户反馈"占的高度远大于视觉高度"。收掉 Material 默认的
              // 48dp 触摸留白/大圆点, 只留 2dp 轨道 + 10dp 拇指, 并整体左移贴边。
              SizedBox(
                height: 20,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                    showValueIndicator: ShowValueIndicator.never,
                  ),
                  child: Slider(
                    padding: const EdgeInsets.only(left: 8, right: 8),
                    value: pos,
                    max: maxMs,
                    onChangeStart: dur <= 0 ? null : actions.onSeekStart,
                    onChanged: dur <= 0 ? null : actions.onSeekChanging,
                    onChangeEnd: dur <= 0 ? null : actions.onSeekEnd,
                  ),
                ),
              ),
              // 歌曲信息与播放控制同排(用户明确要求合并); 文本块 Expanded + ellipsis,
              // 窄屏/大字号下只会变短不会溢出.
              Row(
                children: [
                  // 封面: 点开看专辑大图 + 曲目
                  GestureDetector(
                    onTap: actions.onOpenAlbum,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 4),
                      child: CoverArt(
                        url: current?.coverUrl,
                        size: 40,
                        radius: 6,
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: actions.onToggleLyrics,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 播放条曲名行: 共享的窄宽降级组件(Expanded + 单行
                            // marquee; 300dp/1.25 下徽标整组收起, 不挤标题).
                            AdaptiveTextRow(
                              title: current?.name ?? '未在播放',
                              style: Theme.of(context).textTheme.titleSmall,
                              badges: [
                                if (current?.vip == true)
                                  const VipBadge(small: true),
                                if (current?.paid == true &&
                                    current?.vip != true)
                                  const PaidBadge(),
                              ],
                            ),
                            Text(
                              '${_fmt(player.positionMs)} / ${_fmt(player.durationMs)}'
                              '  ${current?.artist ?? ''}'
                              '  ${data.queueIndex}/${data.queueLength}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 红心 + 上一首/播放/下一首: 与歌曲信息挤在同一行(用户要求把两排合并),
                  // 紧凑点击区 40dp; 播放模式/心动/队列挪到详情页底部, 低频动作不占播放条.
                  _barIcon(
                    tooltip: liked ? '取消喜欢' : '喜欢',
                    icon: Icon(
                      liked ? Icons.favorite : Icons.favorite_border,
                      size: 22,
                      color: liked
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onPressed: actions.onToggleLike,
                  ),
                  // 播放顺序: 取代原来的"上一首"位置(用户要求); 心动模式也在这里轮转.
                  _barIcon(
                    tooltip: data.heartActive
                        ? '心动模式(点击返回列表循环)'
                        : '播放顺序: ${playModeLabels[data.mode] ?? ''}',
                    icon: Icon(
                      data.heartActive
                          ? Icons.auto_awesome
                          : (playModeIcons[data.mode] ?? Icons.repeat),
                      size: 22,
                    ),
                    onPressed: actions.onCycleMode,
                  ),
                  _barIcon(
                    tooltip: player.playing ? '暂停' : '播放',
                    icon: Icon(
                      player.playing ? Icons.pause_circle : Icons.play_circle,
                      size: 38,
                    ),
                    onPressed: actions.onToggle,
                  ),
                  _barIcon(
                    tooltip: '下一首',
                    icon: const Icon(Icons.skip_next, size: 26),
                    onPressed: actions.onNext,
                  ),
                  // 队列入口与歌曲信息同一行右侧(用户要求)
                  _barIcon(
                    tooltip: '播放队列',
                    icon: const Icon(Icons.queue_music, size: 22),
                    onPressed: actions.onOpenQueue,
                  ),
                ],
              ),
              // 手势导航条会吞掉最底部约 20dp 的点击, 留一点安全边距
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
