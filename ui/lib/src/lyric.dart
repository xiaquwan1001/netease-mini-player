/// 歌词时间轴的小工具(纯逻辑, 便于单测).
///
/// UI 只需要两个问题的答案: 当前该高亮哪一行、下一行在哪 —— 都在这里。
///
/// 规则:
/// - 返回值为 [0, times.length) 的下标; -1 表示播放位置还没到第一句;
/// - `times` 必须升序(解析层已排序)。
int lyricIndexAt(List<BigInt> timesMs, BigInt positionMs) {
  var lo = 0;
  var hi = timesMs.length - 1;
  var found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (timesMs[mid] <= positionMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}
