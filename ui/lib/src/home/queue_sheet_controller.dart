import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;

import '../cover_art.dart' show CoverArt;
import '../net_retry.dart' show friendlyError, retryNetwork;
import '../notification_mode.dart' show nextNotificationMode;
import '../play_queue_sheet.dart';
import '../player_bar.dart' show playModeLabels;
import '../queue.dart';
import '../rust/api.dart' as rust;
import '../sheet_header.dart' show SheetHeader;

/// 播放队列面板 + 播放模式轮转(从 main.dart 的 `_HomePageState` 搬出,
/// 2026-11 拆壳 S6, 对应审计 G10 + `_queueSheetOpen`)。
///
/// 搬的是什么(逐行等价搬运, 不改时序/不改阈值/不改面板尺寸):
/// - **面板开关状态** [isOpen](原 `_queueSheetOpen`)与 [open](原 `_openQueueSheet`:
///   已展开时再点 = 收起, 空队列给提示, `isScrollControlled` + `showDragHandle`)。
/// - **面板内的四项交互**: 拖拽重排 [move](原 `_moveInQueue`)、滑删/长按删
///   [remove](原 `_removeFromQueue`: 删当前项时换到顶上来的下一首, 删空则停播)、
///   清空 [clear](原 `_clearQueue`: 二次确认在面板里, 这里只清队列 + [stopAfterEmpty])、
///   点项跳播 [jumpTo](原 `_jumpToQueueSong`: 重新查下标再 `playSong(explicit)`)。
/// - **「存为歌单」全链路** [saveAsPlaylist](原 `_saveQueueAsPlaylist` +
///   `_createPlaylistFromQueue` / `_addQueueToPlaylist` / `_queueSongIds` /
///   `_queuePlaylistDefaultName`): 选已有歌单或新建, 批量 `playlistTracksAdd`。
/// - **播放模式轮转** [cycleMode](原 `_cycleMode`: 列表循环 → 单曲 → 顺序 → 随机 →
///   心动 → 列表循环)与顶部短浮层 [toastTop](原 `_toastTop`)。
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
    required this.loggedIn,
    required this.playSong,
    required this.stopPlayback,
    required this.clearSavedState,
    required this.setUserStopped,
    required this.heartMode,
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

  /// 是否已登录(原 `_info?.loggedIn == true`, 存为歌单要用)。
  final bool Function() loggedIn;

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

  /// 播放队列面板: 看队列 / 点项跳播 / 滑删或长按删(原来只有 "$inQueue/$total" 文本, 完全黑箱)
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
            onSaveAsPlaylist: saveAsPlaylist,
          ),
        ),
      );
    } finally {
      _open = false;
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

  // ---------------- 存为歌单 ----------------

  /// 队列面板「存为歌单」: 选已有歌单或新建, 把队列(面板已按 id 去重)整批加进去.
  /// 批量走 playlistTracksAdd(vendor /playlist/manipulate/tracks 原生支持多 id);
  /// 「我喜欢的音乐」(special)在官方网页端也走同一接口, 不再单独走红心.
  Future<void> saveAsPlaylist(List<rust.SongDto> songs) async {
    if (songs.isEmpty || !isMounted()) return;
    if (!loggedIn()) {
      toast('存为歌单需要先登录');
      return;
    }
    List<rust.Playlist> lists;
    try {
      lists = await retryNetwork(rust.myPlaylists);
    } catch (e) {
      if (!isMounted()) return;
      toast('存为歌单失败: ${friendlyError(e)}');
      return;
    }
    if (!isMounted()) return;
    final context = contextOf();
    if (!context.mounted) return;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: Column(
            children: [
              SheetHeader(
                title: '存为歌单',
                subtitle: '把队列里的 ${songs.length} 首歌存进去',
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  child: const Icon(Icons.add, size: 20),
                ),
                title: const Text('新建歌单'),
                subtitle: const Text('创建后把队列加进去'),
                onTap: () => Navigator.pop(sheetContext, 'create'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final pl = lists[i];
                    return ListTile(
                      dense: true,
                      leading: CoverArt(url: pl.coverUrl, size: 40, radius: 4),
                      title: Text(
                        pl.special ? '我喜欢的音乐' : pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${pl.trackCount} 首'),
                      onTap: () => Navigator.pop(sheetContext, pl),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !isMounted()) return;
    if (picked is String) {
      await _createPlaylistFromQueue(songs);
      return;
    }
    final pl = picked as rust.Playlist;
    await _addQueueToPlaylist(pl, songs);
  }

  /// 新建歌单并把整个队列存进去(默认名: 来自播放队列 M-D HH:mm)
  Future<void> _createPlaylistFromQueue(List<rust.SongDto> songs) async {
    final controller = TextEditingController(text: _queuePlaylistDefaultName());
    final name = await showDialog<String>(
      context: contextOf(),
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !isMounted()) return;
    try {
      final id = await rust.createPlaylist(name: name, privacy: 0);
      final ok = await rust.playlistTracksAdd(
        playlistId: id,
        songIds: _queueSongIds(songs),
      );
      if (!isMounted()) return;
      toast(ok ? '已存入《$name》, ${songs.length} 首' : '歌单已建, 加入未生效');
    } catch (e) {
      if (!isMounted()) return;
      toast('存为歌单失败: ${friendlyError(e)}');
    }
  }

  /// 把队列存进已有歌单
  Future<void> _addQueueToPlaylist(
    rust.Playlist pl,
    List<rust.SongDto> songs,
  ) async {
    try {
      final ok = await rust.playlistTracksAdd(
        playlistId: pl.id,
        songIds: _queueSongIds(songs),
      );
      if (!isMounted()) return;
      final shown = pl.special ? '我喜欢的音乐' : pl.name;
      toast(ok ? '已存入《$shown》, ${songs.length} 首' : '加入未生效, 请稍后重试');
    } catch (e) {
      if (!isMounted()) return;
      toast('存为歌单失败: ${friendlyError(e)}');
    }
  }

  Uint64List _queueSongIds(List<rust.SongDto> songs) =>
      Uint64List.fromList([for (final s in songs) s.id.toInt()]);

  /// 「存为歌单」的默认歌单名
  String _queuePlaylistDefaultName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '来自播放队列 ${now.month}-${now.day} ${two(now.hour)}:${two(now.minute)}';
  }

  // ---------------- 播放模式轮转 ----------------

  /// 播放顺序轮转: 列表循环 → 单曲 → 顺序 → 随机 → 心动 → 列表循环。
  ///
  /// 心动模式是否可用由 [heartMode] 自己判断(未登录/无种子时会给提示并回落),
  /// 切换成功/失败的反馈用顶部浮层, 不挡播放条上那个按钮(用户反馈)。
  Future<void> cycleMode() async {
    if (heartActive) {
      queue.mode = PlayMode.repeatAll;
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
