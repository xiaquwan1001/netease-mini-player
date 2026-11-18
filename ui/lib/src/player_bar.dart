import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'layout.dart'
    show
        LayoutTier,
        kPagePadding,
        kPlayerBarAlbumMinWidth,
        kPlayerBarEdgeInset,
        kPlayerBarRoomyWidth,
        kRowTitleGap,
        layoutTierFor;
import 'playback.dart';
import 'queue.dart' show PlayMode;
import 'rust/api.dart' as rust;

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

/// 当前进程是不是「桌面版」(Linux / Windows)。
///
/// 用户口径(2026-11-18): **桌面版**底部播放栏不要显示当前曲在队列的排位(2/35);
/// 手机端(Android)保留。判据只看平台, 不看窗口宽度 —— 桌面窗口拖窄了仍然是桌面版。
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows);

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

  /// 播放条上的紧凑图标按钮: 34dp 点击区(播放键 38) + 无内边距.
  ///
  /// 加入「上一首」后一排有 6 个按钮: 封面 48 + 5×34 + 38 = 256dp,
  /// 300dp 窄屏上信息行仍有 ~44dp; 按 40dp 排会只剩 8dp, 等于没有文字.
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
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(minWidth: size, minHeight: size),
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
    // 播放条恒等于窗口宽度(根布局 Column 的直接子项), 直接读 MediaQuery 宽度即可。
    final width = MediaQuery.sizeOf(context).width;
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
                  // 不可 seek 期(桌面边下边播)不再换成「只提示不跳转」的轨道:
                  // P-10 方案 B 落地后 Rust 会把这次跳转**排队**, 所以拖动照常回调;
                  // 排队状态由拇指位置(见上面 pos)与信息行的「已排队→mm:ss」体现。
                  // 真正不可跳(下载失败)时 seek 会回传 seek_error, 由页面 toast 如实告知。
                  child: Slider(
                    padding: const EdgeInsets.only(left: 8, right: 8),
                    value: pos,
                    max: maxMs,
                    onChangeStart: data.canSeek ? actions.onSeekStart : null,
                    onChanged: data.canSeek ? actions.onSeekChanging : null,
                    onChangeEnd: data.canSeek ? actions.onSeekEnd : null,
                  ),
                ),
              ),
              // 歌曲信息与播放控制同排(用户明确要求合并); 文本块 Expanded + ellipsis,
              // 窄屏/大字号下只会变短不会溢出.
              Row(
                children: [
                  // 封面: 点开播放详情(歌词页)。专辑入口在歌曲"..."菜单里
                  GestureDetector(
                    onTap: actions.onOpenDetail,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 4),
                      child: CoverArt(
                        url: current?.coverUrl,
                        size: 40,
                        radius: 6,
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
                                  // 第二行: 艺人(· 专辑) + 位置/时长 (+ 队列序号, 仅手机端)
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        // 渐进期已登记待跳(P-10 方案 B): 必须说出来,
                                        // 否则用户拖完等了几十秒不知道到底跳了没有。
                                        if (queued != null)
                                          TextSpan(
                                            text: '已排队→${_fmt(queued)}  ',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        if (current?.artist.isNotEmpty ?? false)
                                          TextSpan(text: current!.artist),
                                        if (showAlbum)
                                          TextSpan(
                                            text: ' · ${current!.album}',
                                          ),
                                        // 位置/时长是既有信息, 任何平台都留;
                                        // 队列排位只在手机端追加(桌面版用户口径)
                                        TextSpan(
                                          text:
                                              '  ${_fmt(player.positionMs)} / ${_fmt(player.durationMs)}'
                                              '${showQueueIndex ? '  ${data.queueIndex}/${data.queueLength}' : ''}',
                                        ),
                                      ],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
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
                  // 播放顺序: 取代原来的"上一首"位置(用户要求); 心动模式也在这里轮转.
                  if (gap > 0) SizedBox(width: gap),
                  _barIcon(
                    tooltip: data.heartActive
                        ? '心动模式(点击返回列表循环)'
                        : '播放顺序: ${playModeLabels[data.mode] ?? ''}',
                    icon: Icon(
                      data.heartActive
                          // 全 App 统一: 心动 = local_fire_department(与推荐页入口同图)。
                          // auto_awesome 归「每日推荐」独占, 不再两种语义共用一个图标。
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
                    onPressed: actions.onToggle,
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
