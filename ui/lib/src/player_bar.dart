/// 常驻播放条(排版 + 与宿主的契约)。
///
/// **桌面右键契约(接线方 = HomePage / 车道 D)**: [PlayerBarActions.onMenu] 是
/// **可选**回调, 语义 = 「对当前曲目打开**现有的**歌曲操作 sheet」—— 与
/// `song_tile.dart` 列表行的长按/右键同一个入口(`showSongActionsSheet`),
/// 播放条不新写一份菜单, 只把**封面**与**信息区**的 `onSecondaryTap` 转给它。
/// 接线方负责: `onMenu: () { final song = <当前曲目>; if (song != null) showSongActionsSheet(...); }`。
/// 不传 = 右键没有任何反应(既有行为); 因此它是可选字段, 既有构造点不用改。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'cover_art.dart';
import 'format.dart' show formatDurationClock;
import 'layout.dart'
    show
        LayoutTier,
        kPagePadding,
        kPlayerBarAlbumMinWidth,
        kPlayerBarEdgeInset,
        kPlayerBarRoomyWidth,
        kRowTitleGap,
        layoutTierFor;
import 'platform_is.dart' show isAndroidPlatform;
import 'playback.dart';
import 'player_volume_button.dart';
import 'queue.dart' show PlayMode;
import 'rust/api_all.dart' as rust;
import 'stream_note.dart' show currentStreamNote, StreamNote;

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
    this.fmActive = false,
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

  /// 播放顺序(只有 4 档; 引导态不在里面)
  final PlayMode mode;

  /// 心动模式引导态(火焰图标; 播放顺序按钮此时 = 退出引导回到列表循环)
  final bool heartActive;

  /// 私人FM 引导态(广播图标; 同上)
  final bool fmActive;

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
        other.fmActive == fmActive &&
        other.player.seekable == player.seekable &&
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
    fmActive,
    player.trackId,
    player.playing,
    player.positionMs,
    player.durationMs,
    player.volume,
    player.seekable,
    identityHashCode(current),
  );

  static bool _playerEquals(PlayerView a, PlayerView b) =>
      a.trackId == b.trackId &&
      a.playing == b.playing &&
      a.positionMs == b.positionMs &&
      a.durationMs == b.durationMs &&
      a.volume == b.volume &&
      a.seekable == b.seekable &&
      a.pendingSeekMs == b.pendingSeekMs;

  /// 进度条能不能拖: 有量程就可拖。
  ///
  /// 桌面「边下边播」期 [PlayerView.seekable] 为 false, 但 P-10 方案 B 之后 Rust 侧不再直接
  /// 拒绝 —— 它会把这次跳转**登记成待跳**(`pending_seek_ms`), 缓存完成后换源重建解码器再跳。
  /// 所以 UI 不能再用 seekable 提前把进度条钉死(那会变成「明明能排队却不让拖」);
  /// 真正不可跳(下载失败)只在 seek 结果里回传 `seek_error`, 由页面 toast 如实告知。
  bool get canSeek => player.durationMs > BigInt.zero;

  /// 已登记的待跳位置(null = 没有挂起的跳转)。播放条据此把拇指停在待跳点并在信息行
  /// 显示「已排队→mm:ss」, 而不是停在一个之后会被换源改掉的位置上。
  BigInt? get pendingSeekMs => player.pendingSeekMs;
}

/// 常驻播放条的回调集合: 不可变, 同一实例跨帧复用(HomePage 建一次后不再变)。
class PlayerBarActions {
  const PlayerBarActions({
    required this.onSeekStart,
    required this.onSeekChanging,
    required this.onSeekEnd,
    required this.onToggleLyrics,
    required this.onOpenDetail,
    required this.onToggleLike,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
    required this.onCycleMode,
    required this.onOpenQueue,
    this.onMenu,
  });

  final void Function(double ms) onSeekStart;
  final void Function(double ms) onSeekChanging;
  final void Function(double ms) onSeekEnd;
  final VoidCallback onToggleLyrics;

  /// 点封面 = 进入播放详情(歌词页). 之前是打开专辑预览, 用户要求改为详情页;
  /// 专辑仍然可以从歌曲"..."菜单里的「专辑信息」进.
  final VoidCallback onOpenDetail;
  final VoidCallback onToggleLike;
  final VoidCallback onToggle;

  /// 上一首(播放条左侧控制组的一员)
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// 播放顺序轮转: 列表循环 → 单曲 → 顺序 → 随机 → 列表循环(**只有 4 档**,
  /// 见 `home/queue_sheet_controller.dart` 的 `cycleMode`)。
  /// 心动/私人FM 不在轮转里(它们有自己的入口与续播逻辑); 处于引导态时这个按钮
  /// 的语义 = 「退出引导回到列表循环」, 图标由 [PlayerBarData.heartActive] /
  /// [PlayerBarData.fmActive] 换成火焰/广播。
  final VoidCallback onCycleMode;

  /// 打开播放队列面板(播放条右侧)
  final VoidCallback onOpenQueue;

  /// 桌面右键(封面 / 信息区)= 打开**现有的**歌曲操作 sheet(见文件头契约)。
  ///
  /// null(默认)= 右键无动作。语义与 `song_tile.dart` 列表行的右键完全同一入口,
  /// 播放条只负责把命中区上的 `onSecondaryTap` 转出来, 接线在 HomePage。
  final VoidCallback? onMenu;
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

/// 宽档播放条是否追加「专辑名」—— 文案分档里「空间还有」的唯一判据。
///
/// 两条同时成立才加:
///   · 档位是宽档(>= [kWideMinWidth]): 中/窄档按用户口径根本不放专辑名;
///   · 信息块(封面与右侧控件之间那一段)实测可用宽 >= [kPlayerBarAlbumMinWidth]。
///
/// 可用宽由播放条的 LayoutBuilder 给出, 不是窗口宽: 窗口再宽, 若壳层把播放条
/// 塞进窄容器, 也不该硬塞专辑名(那时专辑名只会变成一串省略号)。
bool playerBarShowsAlbum({
  required LayoutTier tier,
  required double infoWidth,
}) {
  if (tier != LayoutTier.wide) return false;
  if (infoWidth.isNaN) return false;
  if (!infoWidth.isFinite) return true;
  return infoWidth >= kPlayerBarAlbumMinWidth;
}

/// 测试注入: 在桌面宿主上强制按「非桌面」(手机)判定。
///
/// 与 `platform_is.dart` 的 `debugForceAndroid` 同形: widget 测试跑在 Linux 宿主机上,
/// `Platform.isLinux` 恒为 true, 想验「手机全屏页仍让导航让位」就只能靠它。用完复位。
@visibleForTesting
bool debugForceNonDesktopPlatform = false;

/// 当前进程是不是「桌面版」(Linux / Windows)。
///
/// 用户口径(2026-11-18): **桌面版**底部播放栏不要显示当前曲在队列的排位(2/35);
/// 手机端(Android)保留。判据只看平台, 不看窗口宽度 —— 桌面窗口拖窄了仍然是桌面版。
bool get isDesktopPlatform =>
    !debugForceNonDesktopPlatform &&
    !kIsWeb &&
    (Platform.isLinux || Platform.isWindows);

/// 播放条是否显示队列排位 `N/M`。
///
/// 抽成纯函数: 只吃平台布尔, 与宽度/档位无关, 便于单测(见 player_bar_tiers_test)。
/// 桌面隐藏的理由: 排位在桌面窗口里多是 "5/12" 这种噪音 —— 队列顺序在队列面板里
/// 看更准, 播放条第二行的位置/时长与「已排队→mm:ss」才是当下要的信息。
bool playerBarShowsQueueIndex({required bool isDesktop}) => !isDesktop;

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
    this.desktopPlatformOverride,
  });

  final PlayerBarData data;
  final PlayerBarActions actions;

  /// 桌面平台判定的注入口(null = 按当前进程平台, 见 [isDesktopPlatform])。
  ///
  /// 只在测试里用: widget 测试跑在 Linux 宿主机上, 若要验「手机端仍显示队列排位」
  /// 就必须能把平台钉成非桌面, 否则同一份断言只能取一头。
  final bool? desktopPlatformOverride;

  /// 没有底部导航时自己吃掉系统手势区(有导航时由 NavigationBar 的 SafeArea 负责)
  final bool absorbBottomInset;

  /// 播放条上的紧凑图标按钮: 宽 [size](播放键 38, 其余 34) × **高 48** + 无内边距。
  ///
  /// 宽度为什么还是手机预算(没跟着提到 48): 一排 6 个按钮, 按 48 宽在 300dp 窄屏上
  /// 直接溢出(封面 52 + 6×48 = 340 > 300, 信息行会归零); 横向的可点性由
  /// 「高度 48 + 按钮紧挨着排」兜住, 窄屏上相邻按钮的命中区本来就是相邻的。
  ///
  /// 高度 48 才是本次要修的(2026-11-26 安卓交互审计 P2#4: 34/38dp 的方形命中区
  /// 单手/走路时极容易点空)。注意不能只改 `constraints`: visualDensity.compact
  /// 会把最小尺寸再减 8、`tapTargetSize.padded` 会把命中区撑成 48×48(宽度一起变),
  /// 所以这里显式关掉这两条, 让尺寸**只**由 `size` 与 48 决定。
  Widget _barIcon({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
    double size = 34,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: icon,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      constraints: BoxConstraints(minWidth: size, minHeight: 48),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 宽度用**实测可用宽**, 不是窗口宽: 宽档 Rail 在场时播放条挂在右列,
    // 实际宽 = 窗口宽 - kRailWidth —— 用窗口宽会在 900~980 之间错判档位
    // (窗口 950: 窗口宽算宽档, 播放条实际只有 870 = 中档)。
    // 取不到有限宽(被塞进横滑容器)时才回落到窗口宽。
    return LayoutBuilder(
      builder: (context, constraints) => _buildBar(
        context,
        constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width,
      ),
    );
  }

  Widget _buildBar(BuildContext context, double width) {
    final player = data.player;
    final current = data.current;
    final liked = data.liked;
    final dur = player.durationMs.toDouble();
    // 拖动中冻结量程: 自动续播会让 duration 突跳
    final maxMs = data.dragMax ?? (dur <= 0 ? 1.0 : dur);
    // 拇指位置优先级: 正在拖 → 已登记的待跳点(P-10 方案 B: 缓存完成后会跳到这里) → 当前进度。
    // 少了中间这档, 渐进期排队后拇指会继续跟着旧解码器往前走, 看起来像「没接受这次跳转」。
    final pos =
        (data.dragMs ??
                data.pendingSeekMs?.toDouble() ??
                player.positionMs.toDouble())
            .clamp(0.0, maxMs);
    // 待跳位置(信息行「已排队→mm:ss」用; null = 没有挂起的跳转)
    final queued = data.pendingSeekMs;
    // 留白/控件间隔按宽度分两档(口径与理由见 layout.dart「常驻播放条的横向口径」):
    // 窄屏沿用手机预算(留白 [kPlayerBarEdgeInset]、控件零间隔, 否则 300dp 上
    // 信息行被挤到 0); 宽屏(桌面窗口/平板)用 [kPagePadding] + [kRowTitleGap],
    // 否则六个控件会转成一坨贴在窗口右下角(2026-11-18 用户反馈)。
    // 文案与留白共用同一套档位口径(layout.dart: 窄 < 600 <= 中 < 900 <= 宽),
    // 不再自造阈值。
    final tier = layoutTierFor(width);
    final compact = tier == LayoutTier.compact;
    // roomy 与 compact 同界(kPlayerBarRoomyWidth == kCompactMaxWidth), 但语义不同:
    // roomy 只管留白/控件间隔, 档位管文案。两者都从 width 算, 不会再分叉。
    final roomy = width >= kPlayerBarRoomyWidth;
    final edge = roomy ? kPagePadding : kPlayerBarEdgeInset;
    // 0 = 不加占位(SizedBox 宽度 0 会留一个无意义的 RenderBox)
    final gap = roomy ? kRowTitleGap : 0.0;
    // 队列排位只给手机端(判据与理由见 [playerBarShowsQueueIndex])。
    final showQueueIndex = playerBarShowsQueueIndex(
      isDesktop: desktopPlatformOverride ?? isDesktopPlatform,
    );
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
          padding: EdgeInsets.symmetric(horizontal: edge),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条: 用户反馈"占的高度远大于视觉高度"。收掉 Material 默认的
              // 48dp 触摸留白/大圆点, 视觉只留 2dp 轨道 + 10dp 拇指。
              // 命中带则由 [_ProgressSlider] 自己撑到 48dp(见那里的注释)。
              SizedBox(
                height: kProgressHitHeight,
                child: _ProgressSlider(
                  value: pos,
                  max: maxMs,
                  label: formatDurationClock(BigInt.from(pos.round())),
                  onChangeStart: data.canSeek ? actions.onSeekStart : null,
                  onChanged: data.canSeek ? actions.onSeekChanging : null,
                  onChangeEnd: data.canSeek ? actions.onSeekEnd : null,
                ),
              ),
              // 歌曲信息与播放控制同排(用户明确要求合并); 文本块 Expanded + ellipsis,
              // 窄屏/大字号下只会变短不会溢出.
              Row(
                children: [
                  // 封面: 点开播放详情(歌词页)。专辑入口在歌曲"..."菜单里
                  // MouseRegion: 桌面悬停给手型(2026-11-26 审计 #4 —— 同一排里
                  // 图标按钮有手型+高亮, 封面却是箭头, 用户只能靠试)
                  // 右键(桌面) = 现有「歌曲操作」sheet(见文件头契约, 回调由 HomePage 接)
                  // 命中高度 48: 封面图形仍 40dp, 上下各多 4dp 纯命中带
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: actions.onOpenDetail,
                      onSecondaryTap: actions.onMenu,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                        child: CoverArt(
                          url: current?.coverUrl,
                          size: 40,
                          radius: 6,
                        ),
                      ),
                    ),
                  ),
                  // 播放条文案按档位分三种(2026-11-18 用户口径「竖屏只留封面 icon;
                  // 横屏(平板/电脑)显示歌名 + 艺人 + 空间够时的专辑名」):
                  //   · 窄(< kCompactMaxWidth): 只留封面图形 icon —— 无封面/加载失败时
                  //     CoverArt 自带中性占位图标(music_note), 不会是一片空白;
                  //   · 中(kCompactMaxWidth ~ kWideMinWidth): 歌名 + 艺人;
                  //   · 宽(>= kWideMinWidth): 歌名 + 艺人 + 空间够时专辑名。
                  // 时间/队列序号是既有信息(进度与 P-10 方案 B 的「已排队」状态靠它),
                  // 中/宽档放第二行; 窄档整块不渲染 —— 300dp 上那几个字本来就会被挤成
                  // 省略号, 不如把宽度还给封面与控件。
                  if (compact)
                    // 窄档没有文字块: 用 Spacer 把右侧控件推到与中/宽档相同的位置
                    const Spacer()
                  else
                    Expanded(
                      child: InkWell(
                        // 点信息区仍是「展开歌词」(既有行为, 不顺手改成详情页);
                        // 点封面 = 播放详情, 两个入口都保留。
                        onTap: actions.onToggleLyrics,
                        // 桌面右键 = 现有「歌曲操作」sheet(与列表行同一入口)
                        onSecondaryTap: actions.onMenu,
                        child: LayoutBuilder(
                          builder: (context, info) {
                            // 「空间还有」的口径见 layout.dart 的 kPlayerBarAlbumMinWidth
                            final showAlbum =
                                playerBarShowsAlbum(
                                  tier: tier,
                                  infoWidth: info.maxWidth,
                                ) &&
                                (current?.album.isNotEmpty ?? false);
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 6, 2),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 第一行: 歌名。VIP/付费做成行首彩色前缀 —— 独立徽标
                                  // (≈54dp)在窄信息区会直接溢出, 单行 ellipsis 天然
                                  // 不越界, 且前缀永远先显示(用户反馈过"没有 VIP 标记")。
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        if (current?.vip == true)
                                          TextSpan(
                                            text: 'VIP  ',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        if (current?.paid == true &&
                                            current?.vip != true)
                                          TextSpan(
                                            text: '付费  ',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .tertiary,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        TextSpan(
                                          text:
                                              (current?.name.isNotEmpty ??
                                                  false)
                                              ? current!.name
                                              : '未在播放',
                                        ),
                                      ],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall,
                                  ),
                                  // 第二行: 取链提示 + 艺人(· 专辑) + 位置/时长 (+ 队列序号, 仅手机端)
                                  //
                                  // 行首的「试听 00:45 / 已降级 极高」是方案 A 的信息无损展示:
                                  // 上游 freeTrialInfo 与 level 以前整块丢掉, 45s 试听片段被当
                                  // 整曲播。单行 ellipsis 天然不越界; 窄档(< kCompactMaxWidth)
                                  // 本来就没有文字块, 这条提示也就不显示(要更细的提示见详情页)。
                                  ValueListenableBuilder<
                                    ({BigInt trackId, StreamNote note})?
                                  >(
                                    valueListenable: currentStreamNote,
                                    builder: (context, slot, _) {
                                      final noteLabel =
                                          slot != null &&
                                              current != null &&
                                              slot.trackId == current.id
                                          ? slot.note.label
                                          : null;
                                      return Text.rich(
                                        TextSpan(
                                          children: [
                                            if (noteLabel != null)
                                              TextSpan(
                                                text: noteLabel,
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            // 渐进期已登记待跳(P-10 方案 B): 必须说出来,
                                            // 否则用户拖完等了几十秒不知道到底跳了没有。
                                            if (queued != null)
                                              TextSpan(
                                                text:
                                                    '已排队→${formatDurationClock(queued)}  ',
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            if (current?.artist.isNotEmpty ??
                                                false)
                                              TextSpan(text: current!.artist),
                                            if (showAlbum)
                                              TextSpan(
                                                text: ' · ${current!.album}',
                                              ),
                                            // 位置/时长是既有信息, 任何平台都留;
                                            // 队列排位只在手机端追加(桌面版用户口径)
                                            TextSpan(
                                              text:
                                                  '  ${formatDurationClock(player.positionMs)} / ${formatDurationClock(player.durationMs)}'
                                                  '${showQueueIndex ? '  ${data.queueIndex}/${data.queueLength}' : ''}',
                                            ),
                                          ],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  // 红心 + 播放顺序 + 上一首/播放/下一首 + 队列: 与信息行同一排.
                  // 紧凑点击区 34dp(见 _barIcon 注释), 保证 6 个按钮 + 封面在 300dp 内.
                  if (gap > 0) SizedBox(width: gap),
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
                  // 播放顺序: 取代原来的"上一首"位置(用户要求)。
                  //
                  // 引导态(私人FM/心动模式)下这个按钮显示对应的专属图标, 语义变成
                  // "退出引导回到列表循环"(2026-11-19 用户反馈 5/6: 以前 FM 和心动
                  // 都挤在播放顺序轮转里, 图标也不说明当前在哪个引导态)。
                  if (gap > 0) SizedBox(width: gap),
                  _barIcon(
                    tooltip: data.fmActive
                        ? '私人FM(点击返回列表循环)'
                        : data.heartActive
                        ? '心动模式(点击返回列表循环)'
                        : '播放顺序: ${playModeLabels[data.mode] ?? ''}',
                    icon: Icon(
                      // 全 App 统一: 心动 = local_fire_department(与推荐页入口同图),
                      // 私人FM = radio(与推荐页「私人FM」卡片同图)。
                      // auto_awesome 归「每日推荐」独占, 不再两种语义共用一个图标。
                      data.fmActive
                          ? Icons.radio
                          : data.heartActive
                          ? Icons.local_fire_department
                          : (playModeIcons[data.mode] ?? Icons.repeat),
                      size: 22,
                    ),
                    onPressed: actions.onCycleMode,
                  ),
                  if (gap > 0) SizedBox(width: gap),
                  _barIcon(
                    tooltip: '上一首',
                    icon: const Icon(Icons.skip_previous, size: 26),
                    onPressed: actions.onPrevious,
                  ),
                  if (gap > 0) SizedBox(width: gap),
                  _barIcon(
                    tooltip: player.playing ? '暂停' : '播放',
                    icon: Icon(
                      player.playing ? Icons.pause_circle : Icons.play_circle,
                      size: 38,
                    ),
                    // 播放/暂停是全条最高频的触摸动作: 按下时给一次轻触感
                    // (仅 Android; 桌面不震动, 也不该假装有 —— 见 isAndroidPlatform)
                    onPressed: () {
                      if (isAndroidPlatform) HapticFeedback.selectionClick();
                      actions.onToggle();
                    },
                    size: 38,
                  ),
                  if (gap > 0) SizedBox(width: gap),
                  _barIcon(
                    tooltip: '下一首',
                    icon: const Icon(Icons.skip_next, size: 26),
                    onPressed: actions.onNext,
                  ),
                  // 队列入口与歌曲信息同一行右侧(用户要求)
                  if (gap > 0) SizedBox(width: gap),
                  _barIcon(
                    tooltip: '播放队列',
                    icon: const Icon(Icons.queue_music, size: 22),
                    onPressed: actions.onOpenQueue,
                  ),
                  // 音量入口(2026-11-26 用户口径: 桌面/平板等宽屏设备要能直接在
                  // 播放条上调「精细音量」)。它与设置页是同一个值(AppSettings.volumeGainDb),
                  // 控件自己订阅 playback 域, 这里只负责放进行内。
                  //
                  // **只在宽档渲染**: 窄/中档(手机竖屏/小横屏)没有位置 —— 那一排
                  // 6 个控件在 300dp 上已经是紧预算(见 [_barIcon] 注释)。
                  //
                  // 宽度预算(最紧的宽档 900dp):
                  //   左右留白 2×kPagePadding = 24
                  //   封面命中盒 8+40+4 = 52
                  //   右侧控件 7 个 = 34×6 + 38 = 242
                  //   控件间隔 7×kRowTitleGap = 56
                  //   ⇒ 信息块还剩 900 - 24 - 52 - 242 - 56 = 526dp,
                  //   远大于 kPlayerBarAlbumMinWidth(120), 加这一个不会把宽档的
                  //   专辑名挤出局, 也不影响窄/中档的任何数字。
                  if (gap > 0) SizedBox(width: gap),
                  if (tier == LayoutTier.wide) const PlayerVolumeButton(),
                ],
              ),
              // 播放条与底部导航之间只留 2dp: 之前 8dp 加上导航栏自带内边距,
              // 视觉上是一条明显的空缝(用户要求把播放条/进度条往下挪、收掉缝隙).
              const SizedBox(height: 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// seek **真的**被拒时给用户的统一提示文案(播放条与测试共用一份口径)。
///
/// 什么时候会看到它: 桌面渐进播放期 seek 是**排队**不是拒绝(P-10 方案 B), 排队成功不进这里;
/// 只有下载失败(`GrowingFailed`)等硬不可跳的源, Rust 才会把原因写进 `PlayerState::seek_error`,
/// 页面据此 toast。旧的「缓存中, 暂不可跳转」闸门已随方案 B 撤掉。
const String seekFailedHint = '跳转没生效：当前音源暂不可跳转';

/// 进度条的**命中高度**。视觉仍是 2dp 轨道 + 10dp 拇指(见 [_ProgressSlider])。
///
/// 20dp 高的横条单手/走路时极难点中(2026-11-26 安卓交互审计 P2#4), 48 是 Material
/// 的最小触控尺寸。轨道画在这个盒的垂直中心, 上下多出来的都是**真**命中带
/// (点上去真的 seek, 不是空白)。
const double kProgressHitHeight = 48;

/// 常驻播放条的进度条: 视觉瘦、命中厚、能看见目标时间。
///
/// 三件事(对应两份审计的 P2#4/#8):
/// 1. **命中带 48dp**: 外层盒就是 [kProgressHitHeight], Slider **不加**垂直
///    `padding` —— 手势挂在轨道那一层 render object 上, 用 `Slider.padding` 把
///    盒子撑高、再把轨道挤回顶部, 撑出来的空白是**点不到**的(实测
///    `bottom: 32` 时点在那 32dp 里 `onChanged` 一次都不触发)。所以这里让
///    轨道落在 48dp 盒的垂直中心: 拇指/轨道仍是 2dp+10dp, 上下各 19dp 是真的
///    命中带(点在那个高度也算点进度条)。代价是播放条总高 62 → 98dp。
/// 2. **拖动时显示目标时间**: 原来全程"盲拖"(值指示器被关掉), 现在拖动中弹气泡、
///    松手即收 —— 常显会遮住上方内容。文案由父层算好传进来([label] 就是当前
///    目标时间), 不在这里再读一次播放状态。
/// 3. **悬停拇指放大** 5 → 8: 桌面鼠标悬停时给一个"这条能拖"的可点提示。
///
/// 悬停时的**时间气泡**没做: Slider 不对外暴露 trackRect, 要在外面按 padding +
/// 拇指尺寸重算一遍落点, 近似值会让气泡时间与真实落点差几秒(200s 的曲子上就是
/// 好几秒), 比没有更误导; 拖动气泡给的才是精确值。
class _ProgressSlider extends StatefulWidget {
  const _ProgressSlider({
    required this.value,
    required this.max,
    required this.label,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double max;

  /// 拖动气泡里的文案(目标时间 mm:ss)。
  final String label;

  final void Function(double ms)? onChangeStart;
  final void Function(double ms)? onChanged;
  final void Function(double ms)? onChangeEnd;

  @override
  State<_ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<_ProgressSlider> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: _hovering ? 8 : 5,
          ),
          overlayShape: SliderComponentShape.noOverlay,
          // 只在拖动中弹目标时间; 平时一点都不占视觉
          showValueIndicator: ShowValueIndicator.onDrag,
        ),
        // 不可 seek 期(桌面边下边播)不再换成「只提示不跳转」的轨道:
        // P-10 方案 B 落地后 Rust 会把这次跳转**排队**, 所以拖动照常回调;
        // 排队状态由拇指位置与信息行的「已排队→mm:ss」体现。
        // 真正不可跳(下载失败)时 seek 会回传 seek_error, 由页面 toast 如实告知。
        child: Slider(
          // 只留左右贴边留白; **不要**加垂直 padding(那条命中带点不到, 见类注释)
          padding: const EdgeInsets.only(left: 8, right: 8),
          value: widget.value,
          max: widget.max,
          label: widget.label,
          onChangeStart: widget.onChangeStart,
          onChanged: widget.onChanged,
          onChangeEnd: widget.onChangeEnd,
        ),
      ),
    );
  }
}
