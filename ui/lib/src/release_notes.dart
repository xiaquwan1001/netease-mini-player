/// 版本特性公告(给用户看的「这次更新带来了什么」)。
///
/// 为什么不用 GitHub release 正文: 那里是提交流水(commit 标题, 面向开发者、中英
/// 混杂, 一条修复可能拆成三行)。公告是产品语言, 所以单独维护在这里, key 与 tag
/// 同名(`vX.Y.Z`), 值是每行一条的用户可感知变化。
///
/// 两个消费方共用这一份数据(别再各写一份文案):
/// - 发现新版本弹窗(`update_dialog.dart`): 列出**当前版本之后**的所有公告条目;
/// - 更新后首次启动弹窗: 只列当前版本这一条(见 `home/startup.dart`)。
///
/// 发版时在这里加一条即可; 没有条目的版本不显示公告(不是每个 patch 都值得说)。
const Map<String, List<String>> kReleaseHighlights = <String, List<String>>{
  'v0.39.0': <String>[
    '每日推荐本地缓存改成「只增不减」的索引: 当天不播放也会缓存, 不再出现只存一两首、或者一首都没有的天',
    '历史日推去掉跨天重复: 与更早日期重复的曲目折叠成一行, 点开仍可播放',
    '更新弹窗补上「新特性公告」, 更新后首次启动会告诉你这次改了什么',
  ],
};

/// 版本号归一化: 去掉 `v`/`V` 前缀与 `+build` 段, 只留展示用的 `X.Y.Z[-pre]`。
String normalizeVersionKey(String version) {
  var s = version.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);
  return s;
}

/// 某个版本自己的公告条目; 没有返回空表。
///
/// 表里的 key 带 `v` 前缀(与 tag 同名), 查询时两边都归一化再比, 调用方传
/// `0.39.0` / `v0.39.0` / `v0.39.0+90` 都能命中。
List<String> highlightsFor(String version) {
  final wanted = normalizeVersionKey(version);
  for (final entry in kReleaseHighlights.entries) {
    if (normalizeVersionKey(entry.key) == wanted) return entry.value;
  }
  return const <String>[];
}

/// 比 [currentVersion] 新的公告条目(升序拼接), 供更新弹窗一次列出跨版本变化。
///
/// 只比较公告表里有的版本, 不关心中间的 patch: 用户从 v0.38.8 直接跳到 v0.40.0
/// 时, 中间两条公告都会列出来(按版本号升序, 旧的在上)。
List<String> highlightsSince(String currentVersion) {
  final current = normalizeVersionKey(currentVersion);
  final newer =
      kReleaseHighlights.keys
          .where((tag) => compareVersionKeys(tag, current) > 0)
          .toList()
        ..sort(compareVersionKeys);
  return <String>[for (final tag in newer) ...highlightsFor(tag)];
}

/// `a < b ? -1 : a > b ? 1 : 0`, 逐段数字比较(公告表内部用, 不依赖 UI 层的比较器)。
int compareVersionKeys(String a, String b) {
  List<int> parse(String raw) =>
      normalizeVersionKey(raw)
          .split('.')
          .map((p) => int.tryParse(p) ?? 0)
          .toList();
  final x = parse(a);
  final y = parse(b);
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final p = i < x.length ? x[i] : 0;
    final q = i < y.length ? y[i] : 0;
    if (p != q) return p > q ? 1 : -1;
  }
  return 0;
}
