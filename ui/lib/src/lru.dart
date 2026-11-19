import 'dart:collection';

/// 统一的小容量 LRU 容器(LinkedHashMap + 条目上限)。
///
/// 之前有三处各写一份「LinkedHashMap + remove/re-add 触碰 + 手写淘汰」:
/// cover_art.dart 的图片字节缓存、cover_palette.dart 的取色缓存、
/// word_lyric_view.dart 的逐字歌词排版缓存。口径收敛在这里, 只保留一种语义:
///
/// - **读即触碰**: [operator []] 命中后把条目移到最新端(真 LRU, 不是先进先出);
/// - **写即触碰**: [put] 覆盖已存在的 key 也视为最新;
/// - **超上限淘汰**: 超出 [maxEntries] 时从最久未用的一端淘汰。
///
/// 只管容器, 不管 value 怎么产生: 「未命中就构造再 put」由调用方决定 ——
/// 取色缓存存的是 `Future`, 必须在 await **之前** put 才能合并并发请求。
class LruMap<K, V extends Object> {
  LruMap({this.maxEntries}) : assert(maxEntries == null || maxEntries > 0);

  /// 条目上限; null 表示不设上限(仅当缓存生命周期由调用方兜住时才这样用)。
  final int? maxEntries;

  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  int get length => _map.length;
  bool get isEmpty => _map.isEmpty;
  bool get isNotEmpty => _map.isNotEmpty;

  /// 键的迭代顺序 = 从最久未用到最新(调试/断言用, 不要在遍历中改动缓存)。
  Iterable<K> get keys => _map.keys;
  Iterable<MapEntry<K, V>> get entries => _map.entries;

  bool containsKey(K key) => _map.containsKey(key);

  /// 读取并**触碰**(命中即成为最新)。未命中返回 null。
  V? operator [](K key) {
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value;
    return value;
  }

  /// 只读不触碰: 命中也不改变淘汰顺序。
  V? peek(K key) => _map[key];

  /// 写入(已存在则更新并触碰); 超出上限时淘汰最久未用的条目。
  void put(K key, V value) {
    _map.remove(key); // 覆盖写同样挪到最新端
    _map[key] = value;
    _evict();
  }

  /// 删除并返回原值(没有则 null)。
  V? remove(K key) => _map.remove(key);

  void clear() => _map.clear();

  void _evict() {
    final max = maxEntries;
    if (max == null) return;
    while (_map.length > max) {
      _map.remove(_map.keys.first);
    }
  }
}
