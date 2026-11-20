import '../rust/api_all.dart' as rust;

/// 合并两页动态(刷新/加载更早共用): 按 id 去重, [first] 的副本优先(最新的
/// 点赞/评论状态跟手), [second] 中未出现过的条目按原顺序追加到末尾。
///
/// **刷新必须用它, 不能用新页整体替换**: 关注流/个人空间的"最新页"(lastTime=-1)
/// 经常只回 1~3 条, 直接替换会让列表从 3 条掉到 1 条(2026-11-18 用户反馈
/// 「下拉刷新只有一条」)。合并的语义是"新内容进得来, 老内容不消失"。
List<rust.FeedEventDto> mergeFeedEvents(
  List<rust.FeedEventDto> first,
  List<rust.FeedEventDto> second,
) {
  final seen = <BigInt>{};
  final out = <rust.FeedEventDto>[];
  void take(List<rust.FeedEventDto> src) {
    for (final e in src) {
      if (seen.add(e.id)) out.add(e);
    }
  }

  take(first);
  take(second);
  return out;
}
