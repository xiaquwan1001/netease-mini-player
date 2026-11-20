import 'dart:async';

import 'package:flutter/material.dart';

import '../app_sheet.dart' show showAppDialog;
import '../app_settings.dart' show AppSettings;
import '../notification_mode.dart' show nextNotificationMode;
import '../play_queue_sheet.dart';
import '../player_bar.dart' show playModeLabels;
import '../popup_routes.dart' show buildAppSheetRoute, dismissPopupRoute;
import '../queue.dart';
import '../rust/api_all.dart' as rust;

/// 播放队列面板 + 播放模式轮转(从 main.dart 的 `_HomePageState` 搬出,
/// 2026-11 拆壳 S6, 对应审计 G10 + `_queueSheetOpen`)。
///
/// 搬的是什么(逐行等价搬运, 不改时序/不改阈值/不改面板尺寸):
/// - **面板开关状态** [isOpen](原 `_queueSheetOpen`)与 [open](原 `_openQueueSheet`:
///   已展开时再点 = 收起, 空队列给提示, `isScrollControlled` + `showDragHandle`)。
/// - **面板内的三项交互**: 拖拽重排 [move](原 `_moveInQueue`)、滑删
///   [remove](原 `_removeFromQueue`: 删当前项时换到顶上来的下一首, 删空则停播)、
///   清空 [clear](原 `_clearQueue`: 二次确认在面板里, 这里只清队列 + [stopAfterEmpty])、
///   点项跳播 [jumpTo](原 `_jumpToQueueSong`: 重新查下标再 `playSong(explicit)`)。
/// - **播放模式轮转** [cycleMode](原 `_cycleMode`): 只剩 4 档
///   (列表循环 → 单曲 → 顺序 → 随机 → 列表循环)与顶部短浮层 [toastTop](原 `_toastTop`)。
/// - **引导态 [guide]**: 心动模式/私人FM 从播放顺序里**独立**出来(2026-11-19 用户反馈
///   4/5/6)。进入时记下进入前的 [PlayMode], 退出时恢复(或按播放顺序按钮的语义回列表
///   循环, 见 [exitGuide]); 引导态期间下一首由 provider 续播, 不看 PlayMode。
/// - **退出心动模式** [leaveHeartMode]: 2026-11-18 修 —— 以前只把 mode 改回列表循环,
///   歌单浏览态标题仍是「心动模式」⇒ `heartActive` 永远为真, 图标变不回来、
///   再点只反复弹「列表循环」(用户反馈)。现在标题跟着引导态一起改。
/// - **重要变更(2026-11-18 用户反馈)**: 「存为歌单」整条链路已删除(选歌单/新建/批量加曲
///   连同 `ui/test/queue_sheet_save_test.dart` 一并移除)。
/// - **引导态口径** [heartActive] / [fmActive](原 `_heartActive`): 心动模式与私人FM
///   不是 `PlayMode`, 由 [guide] 表达; 歌单浏览态标题只是展示面, 由页面经
///   [leaveHeartMode] 跟着改。
///
/// 所有权边界(为什么这些仍留在页面):
/// - **队列 `PlayQueue` 由页面持有并注入引用**, 这里不复制(与
///   [PlaybackCoordinator] 同一口径): 拖拽/删除/清空/跳播改的就是页面那一份,
///   `_sourceSongs`、播放条快照读到的立刻是同一状态。
/// - **歌单浏览态标题**(`_libraryTitle`/`_libraryPlaylistId`/`_queuePlaylistId`)
///   归页面: 起播/恢复/搜索都会改, 不是队列面板的语义, 这里只在退出引导时
///   请求一次标题回落([leaveHeartMode])。
/// - **心动模式/私人FM 取数**(页面 `_heartMode` 与引导态续播)与**通知栏状态回传**
///   (`_syncActionState`)仍在页面/协调器, 这里只在退出引导时用 [syncActionState] 收尾。
/// - **播放动作**落到注入的 [playSong] / [stopPlayback] / [clearSavedState]
///   (播放协调器), 这里不碰播放器/歌词/搜索。
/// - **需要 BuildContext 的东西**一律不进来: 面板/对话框/toast 都经 [contextOf]
///   在调用瞬间取, 本类不持有 BuildContext(与 [SongActionWiring] 同款)。
///
/// 状态变化一律 [notifyListeners]; 页面用 `addListener(→setState)` 订阅,
/// 与拆分前"每处队列变更各自 setState"的重建语义一一对应。
class QueueSheetController extends ChangeNotifier {
  QueueSheetController({
    required this.contextOf,
    required this.isMounted,
    required this.queue,
    required this.toast,
    required this.playSong,
    required this.stopPlayback,
    required this.clearSavedState,
    required this.setUserStopped,
    required this.leaveHeartMode,
    required this.syncActionState,
  });

  /// 当前页面的 BuildContext(面板/对话框用; 调用瞬间取, 不缓存)。
  final BuildContext Function() contextOf;

  /// 页面是否还挂在树上(原 `mounted` 判定)。
  final bool Function() isMounted;

  /// 播放队列(真相在页面, 这里只持有引用)。
  final PlayQueue<rust.SongDto> queue;

  /// 普通提示(页面实现: mounted 判断 + `showToast`)。
  final void Function(String message) toast;

  /// 播放某一首(原 `_coordinator.playSong`)。
  final Future<void> Function(rust.SongDto song, {bool explicit}) playSong;

  /// 停止播放(原 `_coordinator.stopPlayback`)。
  final Future<void> Function() stopPlayback;

  /// 清掉落盘的播放现场(原 `_coordinator.clearSavedState`)。
  final Future<void> Function() clearSavedState;

  /// 标记"用户主动停止, 不再自动续播"(原 `_coordinator.userStopped = ...`)。
  final void Function(bool stopped) setUserStopped;

  /// 退出心动模式的列表态(页面实现: 标题从「心动模式」改回「正在播放」)。
  ///
  /// 必须与 `queue.mode` 一起改: [heartActive] 读的是浏览态标题, 只改 mode
  /// 会出现「图标还是心动 / 再点只弹列表循环 / 歌单不重排」三连(2026-11-18 用户反馈)。
  final void Function() leaveHeartMode;

  /// 把红心/播放模式回传原生通知栏(原 `_syncActionState`)。
  final Future<void> Function() syncActionState;

  // ---------------- 面板开关 ----------------

  /// 队列面板是否已展开.
  ///
  /// 播放条挂在根 Overlay(Navigator 之外), 队列面板打开后播放条仍然可点 ——
  /// 之前每点一次队列按钮就再压一层面板, 能无限叠加(用户反馈)。
  /// 现在已展开时再点 = 收起。
  bool _open = false;

  bool get isOpen => _open;

  // ---------------- 引导态(心动模式 / 私人FM) ----------------
  //
  // 这两个模式**不是** PlayMode(见 [QueueGuide] 的注释): 它们自己管续播, 不许
  // 随机/单曲循环接管; 播放顺序按钮在引导态下只剩"退出引导"一个语义。

  QueueGuide _guide = QueueGuide.none;

  /// 进入引导态之前的 [PlayMode](退出时恢复; 见 [exitGuide])。
  PlayMode _modeBeforeGuide = PlayMode.repeatAll;

  /// 当前引导态(none = 普通播放)。
  QueueGuide get guide => _guide;

  /// 是否处于心动模式。
  ///
  /// 判定从"歌单浏览态标题"换成引导态: 标题只是展示, 引导态才是"下一首怎么来"的
  /// 真相; 两者由 [enterGuide]/[exitGuide] 一起改。
  bool get heartActive => _guide == QueueGuide.heart;

  /// 是否处于私人FM。
  bool get fmActive => _guide == QueueGuide.fm;

  /// 进入引导态(心动模式/私人FM)。
  ///
  /// 记下进入前的 [PlayMode] 供 [exitGuide] 恢复; 已经在别的引导态时以新态为准
  /// (不覆盖记录的 mode —— 记录的是"回到普通播放时该用什么模式")。
  void enterGuide(QueueGuide guide) {
    if (guide == QueueGuide.none) {
      exitGuide();
      return;
    }
    if (_guide == guide) return;
    if (_guide == QueueGuide.none) _modeBeforeGuide = queue.mode;
    _guide = guide;
    notifyListeners();
  }

  /// 退出引导态。
  ///
  /// [restoreMode] = true 恢复进入前的 [PlayMode](默认: 别处退出引导时用);
  /// [restoreMode] = false 强制回列表循环 —— 播放条/通知栏的「播放顺序」按钮在
  /// 引导态下就是这个语义(用户要求"按一下回到列表循环")。
  ///
  /// 必须与**歌单浏览态标题**一起改: 只改 mode 会留下「图标还是心动 / 再点只弹
  /// 列表循环 / 歌单不重排」三连(2026-11-18 用户反馈)。
  void exitGuide({bool restoreMode = true}) {
    if (_guide == QueueGuide.none) return;
    final wasHeart = _guide == QueueGuide.heart;
    _guide = QueueGuide.none;
    queue.mode = restoreMode ? _modeBeforeGuide : PlayMode.repeatAll;
    if (wasHeart) leaveHeartMode();
    notifyListeners();
  }

  /// 队列被别处改过(引导态续播追加了一批/切了下一首): 面板要跟着重排。
  ///
  /// `PlayQueue` 本身不是 ChangeNotifier, 面板订阅的是本控制器, 所以引导态的
  /// 续播路径必须显式叫一声(用户反馈: FM 切下一首时列表不跟随刷新)。
  void queueChanged() => notifyListeners();

  /// 面板自己那条路由(open 时建、push 完清空; null = 没开).
  ///
  /// 为什么要自己持有 route: [Navigator.maybePop] 关的是「栈顶」而不是「我」——
  /// 面板之上还压着「清空确认框」时, 切 tab 只关掉确认框, 面板自己还开着
  /// (用户 2026-11-18 反馈, U-02)。拿到自己这条就能 `removeRoute`。
  ModalBottomSheetRoute<void>? _route;

  /// 收起面板(若开着).
  ///
  /// 切底部 tab 的主路径已改成 `app_shell.dart` 的 `dismissAllPopups()`(它按
  /// NavigatorObserver 的登记表一次收掉所有浮层); 这里保留「只关自己」的入口,
  /// 供面板内部/别处与既有测试使用, 语义是**只摘自己那条 route**。
  void close() {
    final route = _route;
    _route = null;
    _open = false;
    if (route == null) return;
    dismissPopupRoute(route);
  }

  /// 播放队列面板: 看队列 / 点项跳播 / 左滑删(原来只有 "$inQueue/$total" 文本, 完全黑箱)
  Future<void> open() async {
    if (_open) {
      // 已展开: 再点一次 = 收起(只关自己, 见 close)
      close();
      return;
    }
    if (queue.items.isEmpty) {
      toast('播放队列是空的');
      return;
    }
    // 首次展开先告知「左滑移除」: 面板行尾只剩拖拽手柄, 不说一句没人知道能滑。
    // 用户可以勾「确认后不再展示」, 之后永久不弹(存 settings.json)。
    await _maybeShowSwipeHint();
    if (!isMounted()) return;
    final context = contextOf();
    if (!context.mounted) return;
    _open = true;
    final navigator = Navigator.of(context);
    final route = buildAppSheetRoute<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: PlayQueueSheet(
          items: queue.items,
          index: queue.index,
          onSelect: (song) {
            Navigator.of(sheetContext).pop();
            jumpTo(song);
          },
          onRemove: remove,
          onMove: move,
          onClear: clear,
          // 面板跟着真实队列走: 心动模式切换/自动续播/别处删歌立刻重排(用户反馈)
          queue: queue,
          changes: this,
        ),
      ),
    );
    _route = route;
    try {
      await navigator.push(route);
    } finally {
      if (identical(_route, route)) _route = null;
      _open = false;
    }
  }

  /// 首次展开队列时告知「左滑可以把歌曲从队列里移除」, 并允许永久关掉。
  Future<void> _maybeShowSwipeHint() async {
    final settings = AppSettings.instance;
    if (settings.queueSwipeHintDismissed) return;
    final context = contextOf();
    if (!context.mounted) return;
    var dontShowAgain = false;
    await showAppDialog<void>(
      context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('小提示'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('左滑一首歌, 可以把它从播放队列里移除。'),
              // 不另加间距: CheckboxListTile 自带上下留白(token 门也省了越界风险)
              CheckboxListTile(
                value: dontShowAgain,
                onChanged: (value) =>
                    setLocal(() => dontShowAgain = value ?? false),
                title: const Text('确认后不再展示'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
    );
    if (dontShowAgain) {
      await settings.update(queueSwipeHintDismissed: true);
    }
  }

  // ---------------- 面板内交互 ----------------

  /// 队列面板拖拽排序: PlayQueue 自己修下标, 当前曲目不变 ⇒ 不需要重播/换歌
  void move(int from, int to) {
    if (!isMounted()) return;
    queue.moveTo(from, to);
    notifyListeners();
  }

  /// 队列面板「清空」: 面板已经做过二次确认, 这里只负责清队列 + 停播
  Future<void> clear() async {
    if (!isMounted()) return;
    queue.clear();
    notifyListeners();
    await stopAfterEmpty();
  }

  /// 队列面板里点某一首: 定位到它再播(曲目可能已被别处挪过, 重新查下标)
  Future<void> jumpTo(rust.SongDto song) async {
    final i = queue.items.indexOf(song);
    if (i < 0) return;
    queue.jumpTo(i);
    notifyListeners();
    await playSong(song, explicit: true);
  }

  /// 队列面板删除: 删的不是当前项时只动列表; 删的是当前项时明确换到顶上来的下一首,
  /// 队列被删空则停播(否则播放器会继续放一首已经从队列里消失的歌)
  void remove(rust.SongDto song, bool wasCurrent) {
    final i = queue.items.indexOf(song);
    if (i < 0) return;
    queue.removeAt(i);
    notifyListeners();
    if (!wasCurrent) return;
    final next = queue.current;
    if (next == null) {
      unawaited(stopAfterEmpty());
    } else {
      unawaited(playSong(next, explicit: false));
    }
  }

  /// 队列空了之后的收尾: 标记用户停止 + 清落盘现场 + 停播(原 `_stopAfterQueueEmpty`)
  Future<void> stopAfterEmpty() async {
    setUserStopped(true);
    // 队列没了就没有"现场"可恢复; 不清的话下次启动会恢复出一个空壳播放条
    unawaited(clearSavedState());
    toast('播放队列已清空, 播放已停止');
    await stopPlayback();
  }

  // ---------------- 播放模式轮转 ----------------

  /// 播放顺序轮转: 列表循环 → 单曲 → 顺序 → 随机 → 列表循环(**只有 4 档**)。
  ///
  /// 心动模式/私人FM 不在轮转里(2026-11-19 用户反馈 4/5): 它们由自己的入口进入,
  /// 有自己的续播逻辑。引导态下这个按钮的语义 = 「退出引导回到列表循环」
  /// ([exitGuide] 的 restoreMode: false), 图标由 [heartActive]/[fmActive] 换成
  /// 火焰/广播(见 `notificationModeIcon` 与播放条)。
  ///
  /// 反馈用顶部浮层, 不挡播放条上那个按钮(用户反馈)。
  Future<void> cycleMode() async {
    if (_guide != QueueGuide.none) {
      exitGuide(restoreMode: false);
      toastTop(playModeLabels[PlayMode.repeatAll]!);
      unawaited(syncActionState());
      return;
    }
    final next = nextNotificationMode(queue.mode);
    queue.mode = next;
    notifyListeners();
    toastTop(playModeLabels[next]!);
    unawaited(syncActionState());
  }

  /// 顶部短浮层: 只做"模式切换"这类即时反馈, 不拦截点击、不遮播放条按钮。
  void toastTop(String message) {
    if (!isMounted()) return;
    final context = contextOf();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final scheme = Theme.of(context).colorScheme;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.paddingOf(ctx).top + 12,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: scheme.inverseSurface,
              elevation: 4,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  message,
                  style: TextStyle(
                    color: scheme.onInverseSurface,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Timer(const Duration(milliseconds: 900), () {
      if (entry.mounted) entry.remove();
    });
  }
}
