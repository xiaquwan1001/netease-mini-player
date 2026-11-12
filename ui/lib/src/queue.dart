import 'dart:math';

/// 播放队列(纯逻辑, 无 IO/无 UI), 便于单测.
///
/// 约定:
/// - 手动上一首/下一首: 总是移动(单曲循环也允许手动跳);
/// - 自动续播(onEnded): 受 PlayMode 约束 —— 单曲循环原地重播, 顺序播放在队尾停止,
///   列表循环回到队首, 随机播放随机挑一首(不会还是当前这首)。
enum PlayMode {
  /// 顺序播放: 播完队尾即停
  sequence,

  /// 列表循环: 播完回到队首继续
  repeatAll,

  /// 单曲循环
  repeatOne,

  /// 随机播放: 下一首从队列里随机挑(不与当前重复)
  shuffle,
}

class PlayQueue<T> {
  PlayQueue({this.mode = PlayMode.repeatAll, Random? random})
    : _random = random ?? Random();

  final List<T> _items = [];
  final Random _random;
  int _index = -1;

  /// 播放模式可变, 切换立即影响下一次自动续播
  PlayMode mode;

  List<T> get items => List.unmodifiable(_items);
  int get index => _index;
  bool get isEmpty => _items.isEmpty;

  T? get current =>
      (_index >= 0 && _index < _items.length) ? _items[_index] : null;
  bool get hasNext => _items.isNotEmpty;

  /// 随机播放时挑一个「不等于当前」的下标; 队列只有一首/空队列时原地不动。
  int _randomIndex() {
    final n = _items.length;
    if (n <= 1) return _index;
    int next;
    do {
      next = _random.nextInt(n);
    } while (next == _index);
    return next;
  }

  /// 用一批曲目替换队列并定位到 startAt
  void setAll(List<T> items, {int startAt = 0}) {
    _items
      ..clear()
      ..addAll(items);
    _index = _items.isEmpty ? -1 : startAt.clamp(0, _items.length - 1);
  }

  void clear() {
    _items.clear();
    _index = -1;
  }

  /// 手动下一首; 空队列返回 null
  T? next() {
    if (_items.isEmpty) return null;
    if (mode == PlayMode.shuffle) {
      _index = _randomIndex();
      return current;
    }
    _index = (_index + 1) % _items.length;
    return current;
  }

  /// 手动上一首(队首向前回到队尾; 随机模式下随机挑一首)
  T? previous() {
    if (_items.isEmpty) return null;
    if (mode == PlayMode.shuffle) {
      _index = _randomIndex();
      return current;
    }
    _index = (_index <= 0) ? _items.length - 1 : _index - 1;
    return current;
  }

  /// 当前曲目自然播完: 返回下一首要播的曲目, null 表示停止
  T? onEnded() {
    if (_items.isEmpty) return null;
    switch (mode) {
      case PlayMode.repeatOne:
        return current;
      case PlayMode.repeatAll:
        _index = (_index + 1) % _items.length;
        return current;
      case PlayMode.shuffle:
        _index = _randomIndex();
        return current;
      case PlayMode.sequence:
        if (_index + 1 >= _items.length) return null;
        _index += 1;
        return current;
    }
  }

  /// 播到指定下标(点击列表里的某一首)
  T? jumpTo(int i) {
    if (i < 0 || i >= _items.length) return null;
    _index = i;
    return current;
  }

  /// 追加到队尾(已在队列里则不重复添加), 不切歌。返回最终下标.
  int append(T item) {
    final existing = _items.indexOf(item);
    if (existing >= 0) return existing;
    _items.add(item);
    if (_index < 0) _index = 0;
    return _items.length - 1;
  }

  /// "下一首播放": 插到当前曲目之后(没有当前曲目时插到队首), 不切歌.
  /// 已在队列里则不重复插入, 只把它的位置挪到当前之后.
  int insertNext(T item) {
    final existing = _items.indexOf(item);
    var insertAt = _index < 0 ? 0 : _index + 1;
    if (existing >= 0) {
      _items.removeAt(existing);
      if (existing < _index) _index -= 1;
      insertAt = _index < 0 ? 0 : _index + 1;
    }
    insertAt = insertAt.clamp(0, _items.length);
    _items.insert(insertAt, item);
    if (_index < 0) _index = 0;
    return insertAt;
  }

  /// 从队列里删掉第 i 项(队列面板的滑删/长按删). 返回被删的项, 越界返回 null.
  ///
  /// 下标修正规则(UI 依赖它决定"要不要换歌"):
  /// - 删的是当前项: 当前位置由原来的下一首顶上(删的是队尾则当前项前移到新的队尾);
  /// - 删的是当前项之前的项: 当前下标 -1, 当前曲目不变;
  /// - 队列被删空: index 回到 -1, current 为 null.
  /// 调用方判断"删的是不是当前项"应在删除前比较 [index], 本方法只做纯下标修正.
  T? removeAt(int i) {
    if (i < 0 || i >= _items.length) return null;
    final removed = _items.removeAt(i);
    if (_items.isEmpty) {
      _index = -1;
      return removed;
    }
    if (i < _index) _index -= 1;
    if (_index >= _items.length) _index = _items.length - 1;
    return removed;
  }

  /// 拖拽排序: 把 from 处的项移到 to 处, 当前曲目保持不变(下标跟着修正).
  /// 下标越界或原地不动返回 false.
  bool moveTo(int from, int to) {
    final n = _items.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return false;
    final item = _items.removeAt(from);
    _items.insert(to, item);
    if (from == _index) {
      _index = to;
    } else if (from < _index && to >= _index) {
      _index -= 1;
    } else if (from > _index && to <= _index) {
      _index += 1;
    }
    return true;
  }

  /// 跳到与 target 相同的那一项(点击列表时用, 避免下标签重不一致)
  T? jumpToItem(T target) {
    final i = _items.indexOf(target);
    return i < 0 ? null : jumpTo(i);
  }
}
