import 'rust/api.dart' as rust;

/// 列表可见性策略(与官方一致):
/// - 无版权 **且没被收藏** 的曲目: 搜不出来 / 不显示(官方也是直接消失, 不做交互)
/// - 无版权 **但已在我喜欢里** 的曲目: 保留 + 灰显, 点了只给"暂无版权"提示
/// - 正常曲目: 原样
///
/// 纯函数, 便于单测(UI 里只负责渲染结果和"隐藏了 N 首"的提示)。
List<rust.SongDto> visibleSongs(List<rust.SongDto> all, Set<BigInt> liked) {
  return [
    for (final s in all)
      if (s.playable || liked.contains(s.id)) s,
  ];
}

/// 被隐藏掉的无版权曲目数量(用于列表顶部那句"已隐藏 N 首…")
int hiddenUnplayableCount(List<rust.SongDto> all, Set<BigInt> liked) {
  var n = 0;
  for (final s in all) {
    if (!s.playable && !liked.contains(s.id)) n += 1;
  }
  return n;
}
