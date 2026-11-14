/// 网络类错误的重试(移动网络抖动/切网时常见 connection reset / os error 104)。
///
/// Rust 侧把错误统一成字符串, 前缀就是 kind, 见 ncm-provider::ProviderError:
///   "[network] error sending request ... <- Connection reset by peer (os error 104)"
/// 所以这里只按前缀判断: **只重试网络错误**, 鉴权/风控/无版权一律立刻抛出。
bool isNetworkError(Object? e) => e?.toString().contains('[network]') ?? false;

/// 给"读类"操作(搜索/取链/歌单/红心列表)套一层退避重试。
/// 写类操作(收藏)默认不重试, 避免重复副作用。
Future<T> retryNetwork<T>(
  Future<T> Function() op, {
  int attempts = 3,
  Duration delay = const Duration(milliseconds: 500),
  Future<void> Function(Duration)? sleep,
}) async {
  final wait = sleep ?? (Duration d) => Future<void>.delayed(d);
  var tries = 0;
  while (true) {
    try {
      return await op();
    } catch (e) {
      tries += 1;
      if (!isNetworkError(e) || tries >= attempts) rethrow;
      await wait(delay * tries);
    }
  }
}

/// 给用户看的错误文案: 网络问题不要甩整串 os error 给他
String friendlyError(Object e) {
  if (isNetworkError(e)) {
    return '网络不稳定, 已自动重试仍失败, 请稍后重试';
  }
  final raw = e.toString();
  // [forbidden] 是"对方设置了隐私"(关注/粉丝列表不可见等): Rust 侧的 detail
  // 已经是能直接读的中文, 不要把内部 kind 前缀露给用户(用户反馈看到的
  // "[internal]code=400" 就是这类). 其它 kind 保持原样, 方便定位问题.
  if (raw.contains('[forbidden]')) {
    final detail = raw.split('[forbidden]').last.trim();
    return detail.isEmpty ? '没有权限查看' : detail;
  }
  return raw;
}
