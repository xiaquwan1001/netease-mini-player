import 'rust/api.dart' as rust;

import 'package:flutter/material.dart';

import 'marquee_text.dart';


/// 当前播放队列面板(播放条上的 Icons.queue_music 打开)。
///
/// 只做展示与"意图表达": 列表是传入的快照, 删除/切歌通过回调交给 [_HomePageState],
/// 由它去改真正的 PlayQueue 并驱动播放 —— 所以这个 widget 可以脱离 Rust 单独测。
class PlayQueueSheet extends StatefulWidget {
  const PlayQueueSheet({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    required this.onRemove,
    this.onMove,
    this.onClear,
  });

  final List<rust.SongDto> items;

  /// 当前播放项的下标(-1 = 没有当前项)
  final int index;

  /// 点某一首: 跳过去播
  final ValueChanged<rust.SongDto> onSelect;

  /// 删除某一首; wasCurrent 为 true 表示删的是正在播的那首
  final void Function(rust.SongDto song, bool wasCurrent) onRemove;

  /// 拖拽排序: 把 from 处的项移到 to 处(当前曲目不变, 下标由面板与宿主各自修正)。
  /// 为 null 时面板仍可拖动但只改本地视图 —— 生产环境必须接上。
  final void Function(int from, int to)? onMove;

  /// 「清空队列」(面板头部): 宿主负责清 PlayQueue 并在需要时停播。
  final void Function()? onClear;

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

  /// 长按/点删除图标: 先确认(误删一手滑就要重新找歌)
  Future<void> _confirmRemove(int i) async {
    if (i < 0 || i >= _items.length) return;
    final song = _items[i];
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从播放队列移除?'),
        content: Text(
          song.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) _removeAt(i);
  }

  /// 清空队列: 二次确认(清空会连当前播放一起停, 误触代价高)
  Future<void> _confirmClear() async {
    if (_items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
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
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '当前播放队列',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  _items.isEmpty ? '共 0 首' : '共 ${_items.length} 首',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (_items.isNotEmpty && widget.onClear != null)
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_outlined),
                    tooltip: '清空队列',
                    onPressed: _confirmClear,
                  ),
              ],
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
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    // 拖拽手柄只在自己的行上(整行长按留给"移除"), 见下面的 drag_handle
                    buildDefaultDragHandles: false,
                    itemCount: _items.length,
                    onReorder: (from, to) {
                      // ReorderableListView 的 to 是"插入到该下标之前"的语义
                      _move(from, to > from ? to - 1 : to);
                    },
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
                        onDismissed: (_) => _removeAt(i),
                        child: ListTile(
                          dense: true,
                          selected: current,
                          leading: SizedBox(
                            width: 28,
                            child: Center(
                              child: current
                                  ? Icon(Icons.volume_up,
                                      size: 18, color: scheme.primary)
                                  : Text(
                                      '${i + 1}',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(color: scheme.outline),
                                    ),
                            ),
                          ),
                          title: MarqueeText(
                            song.name,
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
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 20),
                                tooltip: '从队列移除',
                                onPressed: () => _confirmRemove(i),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 12),
                                  child: Icon(
                                    Icons.drag_handle,
                                    size: 20,
                                    color: scheme.outline,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          onTap: () {
                            // 面板自己先跟着切(独立/常开使用时一致; 宿主一般会顺手关掉面板)
                            setState(() => _index = i);
                            widget.onSelect(song);
                          },
                          onLongPress: () => _confirmRemove(i),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
