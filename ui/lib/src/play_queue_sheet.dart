import 'rust/api_all.dart' as rust;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'app_sheet.dart';
import 'layout.dart'
    show kCardRowPadding, kQueueRowExtent, kRowTitleGap, rowExtentFor;
import 'platform_is.dart' show isAndroidPlatform;
import 'queue.dart';
import 'sheet_header.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'toast.dart' show showUndoToast;

/// 当前播放队列面板(播放条上的 Icons.queue_music 打开)。
///
/// 只做展示与"意图表达": 删除/切歌通过回调交给宿主, 由它去改真正的 PlayQueue
/// 并驱动播放 —— 所以这个 widget 可以脱离 Rust 单独测。
///
/// 面板的两层数据:
/// - [items]/[index] 是**打开瞬间的快照**(脱机/测试用, 也是首帧的真相);
/// - [queue] + [changes] 是**可选的真实队列**: 给了之后面板跟着它走 —— 心动模式切换、
///   自动续播、别处删歌都会立刻把列表与「当前高亮」重排(2026-11-18 用户反馈:
///   "当前播放队列的更新响应不及时"), 不再是一份打开时就定死的旧快照。
class PlayQueueSheet extends StatefulWidget {
  const PlayQueueSheet({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    required this.onRemove,
    this.onRestore,
    this.onMove,
    this.onClear,
    this.queue,
    this.changes,
  });

  final List<rust.SongDto> items;

  /// 当前播放项的下标(-1 = 没有当前项)
  final int index;

  /// 点某一首: 跳过去播
  final ValueChanged<rust.SongDto> onSelect;

  /// 删除某一首; wasCurrent 为 true 表示删的是正在播的那首
  final void Function(rust.SongDto song, bool wasCurrent) onRemove;

  /// 「撤销删除」: 把被滑删的那一首**插回原下标** [index](与 [onRemove] 严格互逆)。
  ///
  /// 为什么要宿主参与: 真正的队列在宿主手里(面板只表达意图), 面板自己能恢复的
  /// 只是本地视图 —— 不同步真队列的话, 下一次队列变更通知就会把这一行又抹掉。
  /// 为 null 时撤销只恢复本地视图(脱机/测试用, 生产必须接上)。
  final void Function(int index, rust.SongDto song)? onRestore;

  /// 拖拽排序: 把 from 处的项移到 to 处(当前曲目不变, 下标由面板与宿主各自修正)。
  /// 为 null 时面板仍可拖动但只改本地视图 —— 生产环境必须接上。
  final void Function(int from, int to)? onMove;

  /// 「清空队列」(面板头部): 宿主负责清 PlayQueue 并在需要时停播。
  final void Function()? onClear;

  /// 真实队列(只读): 非 null 时面板跟着它刷新(见类头注释)。
  final PlayQueue<rust.SongDto>? queue;

  /// 队列变更通知(通常是 QueueSheetController, 它持有真实队列引用)。
  final Listenable? changes;

  @override
  State<PlayQueueSheet> createState() => _PlayQueueSheetState();
}

class _PlayQueueSheetState extends State<PlayQueueSheet> {
  late final List<rust.SongDto> _items = List<rust.SongDto>.of(widget.items);

  /// 与 _items 一一对应的稳定 key: 同曲目可能在队列里出现多次, 不能拿 id 当 key;
  /// 也不能带下标(拖拽排序时下标会变, ReorderableListView 会因此丢状态)。
  late final List<Key> _keys = [
    for (var i = 0; i < _items.length; i++) UniqueKey(),
  ];

  late int _index = widget.index;

  /// 行高(itemExtent)与滚动控制器: 打开时直接定位到当前播放曲目, 顶部「定位」按钮复用。
  double? _extent;
  ScrollController? _scroll;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_syncFromQueue);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 行高随系统字号缩放(与列表行同一口径), 所以只能在拿到 MediaQuery 之后建滚动控制器。
    final extent = rowExtentFor(context, kQueueRowExtent);
    if (_scroll == null) {
      _extent = extent;
      _scroll = ScrollController(initialScrollOffset: _currentOffset(extent));
    } else if (_extent != extent) {
      // 字号档位在面板打开期间变了: 行高已变, 旧偏移没有意义 ⇒ 复位到当前曲目
      _extent = extent;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent(animate: false);
      });
    }
  }

  @override
  void didUpdateWidget(PlayQueueSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(_syncFromQueue);
      widget.changes?.addListener(_syncFromQueue);
      _syncFromQueue();
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_syncFromQueue);
    _scroll?.dispose();
    super.dispose();
  }

  /// 打开时的初始滚动位置: 让当前播放曲目落在可视区(不再从第 1 首开始).
  double _currentOffset(double extent) => _index <= 0 ? 0.0 : _index * extent;

  /// 「定位当前播放歌曲」(面板头部按钮): 滚动到当前曲目(带一点上边距, 不贴顶)。
  void _scrollToCurrent({bool animate = true}) {
    final scroll = _scroll;
    final extent = _extent;
    if (scroll == null || extent == null || _index < 0) return;
    if (!scroll.hasClients) return;
    final target = (_currentOffset(extent) - extent * 0.5).clamp(
      0.0,
      scroll.position.maxScrollExtent,
    );
    if (!animate) {
      scroll.jumpTo(target);
      return;
    }
    scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// 外部队列变了(心动模式切换/自动续播/别处删歌): 列表与高亮立刻按真实队列重排.
  ///
  /// 只在**内容或当前下标真的变了**时才 setState: 面板自己的拖拽/滑删也会让宿主
  /// 回写队列并通知, 那些情况本地已经是最新形状, 重建只会白丢拖拽 key。
  void _syncFromQueue() {
    if (!mounted) return;
    final queue = widget.queue;
    if (queue == null) return;
    final live = queue.items;
    var same = live.length == _items.length;
    if (same) {
      for (var i = 0; i < live.length; i++) {
        if (!identical(live[i], _items[i])) {
          same = false;
          break;
        }
      }
    }
    if (same && queue.index == _index) return;
    setState(() {
      _items
        ..clear()
        ..addAll(live);
      _keys
        ..clear()
        ..addAll([for (final _ in _items) UniqueKey()]);
      _index = queue.index;
    });
  }

  /// 拖拽排序: 本地先动(面板即时反馈), 下标修正规则与 PlayQueue.moveTo 保持一致
  void _move(int from, int to) {
    final n = _items.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    setState(() {
      _items.insert(to, _items.removeAt(from));
      _keys.insert(to, _keys.removeAt(from));
      if (from == _index) {
        _index = to;
      } else if (from < _index && to >= _index) {
        _index -= 1;
      } else if (from > _index && to <= _index) {
        _index += 1;
      }
    });
    widget.onMove?.call(from, to);
  }

  /// 本地先删(面板即时反馈), 再按 PlayQueue 同样的下标修正规则同步给宿主
  void _removeAt(int i) {
    if (i < 0 || i >= _items.length) return;
    final song = _items[i];
    final wasCurrent = i == _index;
    setState(() {
      _items.removeAt(i);
      _keys.removeAt(i);
      if (_items.isEmpty) {
        _index = -1;
      } else if (i < _index) {
        _index -= 1;
      } else if (_index >= _items.length) {
        _index = _items.length - 1;
      }
    });
    widget.onRemove(song, wasCurrent);
  }

  /// 左滑删除 + 可撤销条(2026-11-26 安卓交互审计 P2#6)。
  ///
  /// 与同面板的「清空」二次确认不一致: 左滑一眼就生效、误滑之后只能重新找歌。
  /// 这里改成「删了就删了, 但给 4 秒撤销窗口」——误滑代价从"找歌"降为"点一下"。
  ///
  /// [context] 是列表行的 context(必须在面板自带的 ScaffoldMessenger 之下, 见 [build])。
  void _dismissAt(BuildContext context, int i) {
    if (i < 0 || i >= _items.length) return;
    final song = _items[i];
    // 左滑成功 = 一次选择动作: Android 上给一声轻触感(桌面没振动器, 不假装有)
    if (isAndroidPlatform) HapticFeedback.selectionClick();
    _removeAt(i);
    showUndoToast(
      context,
      message: '已从队列移除《${song.name}》',
      onUndo: () => _restoreAt(i, song),
    );
  }

  /// 撤销删除: 把该曲插回**原下标**([i])。
  ///
  /// 下标修正与 [_removeAt] 互逆: 插回位置在当前项之前(或就是当前项) ⇒ 当前指数 +1,
  /// 当前曲目不变(并不把播放拽回被删的那首 —— 删除时已经换播了, 撤销只恢复列表)。
  /// 队列删空后撤销 ⇒ 它就落在唯一位置上成为当前项(播放仍停着, 由用户自己去播)。
  void _restoreAt(int i, rust.SongDto song) {
    if (!mounted) return;
    final at = i.clamp(0, _items.length);
    setState(() {
      _items.insert(at, song);
      _keys.insert(at, UniqueKey());
      if (_index < 0) {
        _index = at;
      } else if (at <= _index) {
        _index += 1;
      }
    });
    widget.onRestore?.call(at, song);
  }

  /// 清空队列: 二次确认(清空会连当前播放一起停, 误触代价高)
  Future<void> _confirmClear() async {
    if (_items.isEmpty) return;
    final ok = await showAppDialog<bool>(
      context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空播放队列?'),
        content: Text('共 ${_items.length} 首, 清空后当前播放会停止。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _items.clear();
      _keys.clear();
      _index = -1;
    });
    widget.onClear?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final extent = _extent ?? rowExtentFor(context, kQueueRowExtent);
    // 自带一层 ScaffoldMessenger + 透明 Scaffold: 队列面板是**模态** bottom sheet,
    // 根 ScaffoldMessenger 的 SnackBar 画在面板**底下**的页面里(400x800 实测落在
    // y=740~800, 正好被面板盖死), 左滑删除的撤销条就完全看不见。自带一层后
    // 撤销条浮在面板内部(悬浮条本来就不占体高度, 面板尺寸不变)。
    return ScaffoldMessenger(
      child: Scaffold(
        // 面板自己的背景/圆角由 ModalBottomSheet 的 Material 画, 这里只当宿主
        backgroundColor: Colors.transparent,
        body: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                // 8 而不是 12: 标题行与下面列表的左右边缘对齐(列表行 4dp + 图标内缩)
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SheetHeader(
                  // 单行标题(不放 subtitle): 队列面板在 300dp/矮视口下高度很紧,
                  // 双行标题会顶出 2px 纵向溢出(见 narrow_width_audit_test)
                  title: '当前播放队列',
                  // 标题区曾被行尾挤成"当前播…"(用户 2026-11-15 截图)。
                  // 三处一起收: 计数降字号 + 动作按钮收到 40dp(见 [_SheetIconButton])
                  // + 标题栏横向留白 12→8。只改其中一处仍会截断, 所以三条都在这里。
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        // '共 N 首' → 'N 首': 大字号下「共」和一个空格要吃掉 ~33dp,
                        // 正好是 6 字标题是否被截断的那一段(1.5× / 360dp 实测)。
                        '${_items.length} 首',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (_items.isNotEmpty && widget.onClear != null)
                        _SheetIconButton(
                          icon: Icons.delete_sweep_outlined,
                          tooltip: '清空队列',
                          onPressed: _confirmClear,
                        ),
                      // 「定位当前播放歌曲」: 长队列里当前项常在屏幕外, 以前只能自己往下翻。
                      // 位置在「清空」**后面**(用户 2026-11-18 指定), 无当前项时置灰。
                      if (_items.isNotEmpty)
                        _SheetIconButton(
                          icon: Icons.my_location,
                          tooltip: '定位当前播放歌曲',
                          onPressed: _index < 0
                              ? null
                              : () => _scrollToCurrent(),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '播放队列是空的\n在列表里点一首歌就会入队',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.only(bottom: 8),
                        scrollController: _scroll,
                        // 定高行: 「定位当前曲目」靠 index × 行高算偏移, 也顺带收掉行间空白
                        // (用户 2026-11-18: 队列行间距过大 —— 基准 56 → 48, 见 kQueueRowExtent)
                        itemExtent: extent,
                        // 拖拽手柄只在自己的行上(整行长按不再有动作: 移除只保留左滑,
                        // 与左滑重复的垃圾桶按钮 + 二次确认已于 2026-11-18 移除)
                        buildDefaultDragHandles: false,
                        itemCount: _items.length,
                        // onReorderItem 已按"移除后"修正过 newIndex, 直接用;
                        // (旧的 onReorder 是"插入到该下标之前", 需自己 to>from ? to-1 : to)
                        onReorderItem: _move,
                        itemBuilder: (context, i) {
                          final song = _items[i];
                          final current = i == _index;
                          return Dismissible(
                            key: _keys[i],
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: scheme.errorContainer,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: Icon(
                                Icons.delete_outline,
                                color: scheme.onErrorContainer,
                              ),
                            ),
                            onDismissed: (_) => _dismissAt(context, i),
                            child: ListTile(
                              dense: true,
                              selected: current,
                              // 行铺满: 序号贴左 4dp、拖拽手柄贴右 4dp,
                              // 中间(歌名+徽标)因此多出 ~34dp(用户 2026-11-15:
                              // "数字序号左移、删除和移动 icon 右移, 为中间内容腾空间")。
                              // 与 SongTile 用同一套 token: 不再出现 16+28+16+76 的
                              // 四段固定留白。
                              contentPadding: kCardRowPadding,
                              horizontalTitleGap: kRowTitleGap,
                              leading: SizedBox(
                                // token-ok: 队列序号列宽(两位数字 + 播放图标)的内容宽度
                                width: 28,
                                child: Center(
                                  child: current
                                      ? Icon(
                                          Icons.volume_up,
                                          size: 18,
                                          color: scheme.primary,
                                        )
                                      : Text(
                                          '${i + 1}',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(color: scheme.outline),
                                        ),
                                ),
                              ),
                              // 歌名 + VIP/付费/无版权标记(VIP 之前在这里完全看不到)
                              title: SongTitleWithBadges(
                                song: song,
                                marquee: true,
                                style: current
                                    ? TextStyle(
                                        color: scheme.primary,
                                        fontWeight: FontWeight.w600,
                                      )
                                    : null,
                              ),
                              subtitle: Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              // 行尾只剩拖拽手柄: 「从队列移除」的垃圾桶与二次确认已删除
                              // (与左滑删除功能重复, 用户 2026-11-18)
                              trailing: ReorderableDragStartListener(
                                index: i,
                                child: Padding(
                                  // 拖拽手柄贴到行右边缘(触控区由行高决定)
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 10,
                                  ),
                                  child: Icon(
                                    Icons.drag_handle,
                                    size: 20,
                                    color: scheme.outline,
                                  ),
                                ),
                              ),
                              onTap: () {
                                // 面板自己先跟着切(独立/常开使用时一致; 宿主一般会顺手关掉面板)
                                setState(() => _index = i);
                                widget.onSelect(song);
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板内的小图标按钮: 宽度固定 40dp(默认 48 会把标题/歌名挤窄),
/// 高度默认 40(标题栏)。
///
/// 只在这个文件里用 —— 不要拿它替换别处的 IconButton, 触控口径不同。
class _SheetIconButton extends StatelessWidget {
  const _SheetIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      iconSize: 20,
      padding: EdgeInsets.zero,
      // 命中区 = constraints(不是默认 48 的方形), 与排列宽度一致
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}
