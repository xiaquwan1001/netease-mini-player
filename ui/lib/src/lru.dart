import 'dart:collection';

/// 统一的小容量 LRU 容器(LinkedHashMap + 条目上限)。
///
/// 之前有三处各写一份「LinkedHashMap + remove/re-add 触碰 + 手写淘汰」:
/// cover_art.dart 的图片字节缓存、cover_palette.dart 的取色缓存、
/// word_lyric_view.dart 的逐字歌词排版缓存。口径收敛在这里, 只保留一种语义:
///
/// - **读即触碰**: [operator []] 命中后把条目移到最新端(真 LRU, 不是先进先出);
/// - **写即触碰**: [put] 覆盖已存在的 key 也视为最新;
/// - **超上限淘汰**: 超出 [maxEntries] 或 [maxBytes] 时从最久未用的一端淘汰。
///
/// 只管容器, 不管 value 怎么产生: 「未命中就构造再 put」由调用方决定 ——
/// 取色缓存存的是 `Future`, 必须在 await **之前** put 才能合并并发请求。
class LruMap<K, V extends Object> {
  LruMap({this.maxEntries, this.maxBytes, int Function(V value)? sizeOf})
    : _sizeOf = sizeOf,
      assert(maxEntries == null || maxEntries > 0),
      assert(maxBytes == null || maxBytes > 0),
      assert(maxBytes == null || sizeOf != null, 'maxBytes 必须配 sizeOf');

  /// 条目上限; null 表示不设上限(仅当缓存生命周期由调用方兜住时才这样用)。
  final int? maxEntries;

  /// **字节**上限(需同时给 [sizeOf]); null = 只按条数淘汰。
  ///
  /// 为什么要有: 只限条数的缓存在"条目大小差两个数量级"时完全失控 ——
  /// 图片字节缓存 200 条里既有 20KB 的列表缩略图也有 2MB 的原图,
  /// 200 条的上界 = 400MB(2026-11-28 缓存审计 P1-2)。
  final int? maxBytes;

  /// 一条 value 占多少字节(只在 [maxBytes] 生效时被调用)
  final int Function(V value)? _sizeOf;

  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  /// 当前累计字节数(没配 [maxBytes] 时恒为 0, 不要拿它当"占了多少"用)
  int get bytes => _bytes;
  int _bytes = 0;

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
    final old = _map.remove(key); // 覆盖写同样挪到最新端
    if (old != null) _bytes -= _sizeOf?.call(old) ?? 0;
    _map[key] = value;
    _bytes += _sizeOf?.call(value) ?? 0;
    _evict();
  }

  /// 删除并返回原值(没有则 null)。
  V? remove(K key) {
    final old = _map.remove(key);
    if (old != null) _bytes -= _sizeOf?.call(old) ?? 0;
    return old;
  }

  void clear() {
    _map.clear();
    _bytes = 0;
  }

  void _evict() {
    final max = maxEntries;
    final maxB = maxBytes;
    while (true) {
      final tooMany = max != null && _map.length > max;
      // 字节超限时**至少留一条**: 单条就比上限大时也要能读到它(否则缓存形同关闭)
      final tooBig = maxB != null && _bytes > maxB && _map.length > 1;
      if (!tooMany && !tooBig) return;
      remove(_map.keys.first);
    }
  }
}
