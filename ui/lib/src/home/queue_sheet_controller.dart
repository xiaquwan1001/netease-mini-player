import 'dart:async';

import 'package:flutter/material.dart';

import '../app_settings.dart' show AppSettings;
import '../notification_mode.dart' show nextNotificationMode;
import '../play_queue_sheet.dart';
import '../player_bar.dart' show playModeLabels;
import '../queue.dart';
import '../rust/api.dart' as rust;

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
/// - **播放模式轮转** [cycleMode](原 `_cycleMode`: 列表循环 → 单曲 → 顺序 → 随机 →
///   心动 → 列表循环)与顶部短浮层 [toastTop](原 `_toastTop`)。
/// - **退出心动模式** [leaveHeartMode]: 2026-11-18 修 —— 以前只把 mode 改回列表循环,
///   歌单浏览态标题仍是「心动模式」⇒ `heartActive` 永远为真, 图标变不回来、
///   再点只反复弹「列表循环」(用户反馈)。
/// - **重要变更(2026-11-18 用户反馈)**: 「存为歌单」整条链路已删除(选歌单/新建/批量加曲
///   连同 `ui/test/queue_sheet_save_test.dart` 一并移除)。
/// - **队列来源标题的口径** [heartActive](原 `_heartActive`): 心动不是 `PlayMode`,
///   用"歌单浏览态标题 == 心动模式"识别; 标题本体仍是页面状态, 这里经
///   [libraryTitleOf] 只读。
///
/// 所有权边界(为什么这些仍留在页面):
/// - **队列 `PlayQueue` 由页面持有并注入引用**, 这里不复制(与
///   [PlaybackCoordinator] 同一口径): 拖拽/删除/清空/跳播改的就是页面那一份,
///   `_sourceSongs`、播放条快照读到的立刻是同一状态。
/// - **歌单浏览态标题**(`_libraryTitle`/`_libraryPlaylistId`/`_queuePlaylistId`)
///   归页面: 起播/恢复/搜索都会改, 不是队列面板的语义, 这里只读 [libraryTitleOf]。
/// - **心动模式取数**(`_heartMode`)与**通知栏状态回传**(`_syncActionState`)仍
///   在页面/协调器, 经 [heartMode] / [syncActionState] 注入调用。
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
    required this.libraryTitleOf,
    required this.toast,
    required this.playSong,
    required this.stopPlayback,
    required this.clearSavedState,
    required this.setUserStopped,
    required this.heartMode,
    required this.leaveHeartMode,
    required this.syncActionState,
  });

  /// 当前页面的 BuildContext(面板/对话框用; 调用瞬间取, 不缓存)。
  final BuildContext Function() contextOf;

  /// 页面是否还挂在树上(原 `mounted` 判定)。
  final bool Function() isMounted;

  /// 播放队列(真相在页面, 这里只持有引用)。
  final PlayQueue<rust.SongDto> queue;

  /// 当前"歌单浏览态"标题(原 `_libraryTitle`); 心动模式靠它识别。
  final String? Function() libraryTitleOf;

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

  /// 心动模式(在页面实现: 要改搜索忙碌态与歌单浏览态标题)。
  final Future<void> Function() heartMode;

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

  /// 是否处于心动模式队列(心动不是 PlayMode, 用队列标题识别)
  bool get heartActive => libraryTitleOf() == '心动模式';

  /// 收起面板(若开着).
  ///
  /// 底部导航切视图时调它: 面板是 modal route, 不会随 tab 切换自己消失,
  /// 会一直压在旧页面上(用户 2026-11-18 反馈: 切 tab 后顶部冒出一堆返回条目)。
  /// 用 [Navigator.maybePop] 而不是 pop: 面板已被别处关掉时不能误退页面。
  void close() {
    if (!_open) return;
    Navigator.of(contextOf()).maybePop();
  }

  /// 播放队列面板: 看队列 / 点项跳播 / 左滑删(原来只有 "$inQueue/$total" 文本, 完全黑箱)
  Future<void> open() async {
    if (_open) {
      // 面板在栈顶; pop 掉它即"收起"
      Navigator.of(contextOf()).pop();
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
    _open = true;
    try {
      await showModalBottomSheet<void>(
        context: contextOf(),
        isScrollControlled: true,
        showDragHandle: true,
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
    } finally {
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
    await showDialog<void>(
      context: context,
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

  /// 播放顺序轮转: 列表循环 → 单曲 → 顺序 → 随机 → 心动 → 列表循环。
  ///
  /// 心动模式是否可用由 [heartMode] 自己判断(未登录/无种子时会给提示并回落),
  /// 切换成功/失败的反馈用顶部浮层, 不挡播放条上那个按钮(用户反馈)。
  Future<void> cycleMode() async {
    if (heartActive) {
      // 退出心动模式: mode 与**歌单浏览态标题**必须一起改。
      // 以前只改 mode ⇒ heartActive 仍为真(它读的是标题), 于是图标一直是心动,
      // 再点还是走这个分支只弹「列表循环」, 队列也不重排(2026-11-18 用户反馈)。
      queue.mode = PlayMode.repeatAll;
      leaveHeartMode();
      notifyListeners();
      toastTop(playModeLabels[PlayMode.repeatAll]!);
      unawaited(syncActionState());
      return;
    }
    final next = nextNotificationMode(queue.mode);
    if (next == null) {
      await heartMode();
      if (heartActive) {
        toastTop('心动模式');
      } else {
        queue.mode = PlayMode.repeatAll;
        notifyListeners();
        toastTop(playModeLabels[PlayMode.repeatAll]!);
      }
    } else {
      queue.mode = next;
      notifyListeners();
      toastTop(playModeLabels[next]!);
    }
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
