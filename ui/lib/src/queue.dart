/// 播放队列(纯逻辑, 无 IO/无 UI), 便于单测.
///
/// 约定:
/// - 手动上一首/下一首: 总是移动, 列表首尾循环(单曲循环也允许手动跳);
/// - 自动续播(onEnded): 受 PlayMode 约束 —— 单曲循环原地重播, 顺序播放在队尾停止,
///   列表循环回到队首。
enum PlayMode {
  /// 顺序播放: 播完队尾即停
  sequence,

  /// 列表循环: 播完回到队首继续
  repeatAll,

  /// 单曲循环
  repeatOne,
}

class PlayQueue<T> {
  PlayQueue({this.mode = PlayMode.repeatAll});

  final List<T> _items = [];
  int _index = -1;

  /// 播放模式可变, 切换立即影响下一次自动续播
  PlayMode mode;

  List<T> get items => List.unmodifiable(_items);
  int get index => _index;
  bool get isEmpty => _items.isEmpty;

  T? get current => (_index >= 0 && _index < _items.length) ? _items[_index] : null;
  bool get hasNext => _items.isNotEmpty;

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
    _index = (_index + 1) % _items.length;
    return current;
  }

  /// 手动上一首(队首向前回到队尾)
  T? previous() {
    if (_items.isEmpty) return null;
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

  /// 跳到与 target 相同的那一项(点击列表时用, 避免下标签重不一致)
  T? jumpToItem(T target) {
    final i = _items.indexOf(target);
    return i < 0 ? null : jumpTo(i);
  }
}
