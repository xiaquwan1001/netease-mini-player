import 'rust/api.dart' as rust;

/// 错误 kind 的文本名, 与 Rust 侧 `ncm_provider::ProviderErrorKind::as_str` 一致:
/// network / auth / riskControl / notFound / unsupported / forbidden / internal。
///
/// 跨桥之后 Dart 拿到的是结构化的 [rust.FfiError](kind/retryable/detail 三个字段),
/// 不用再靠文本前缀猜; 下面这些字符串解析**只为兼容老路径**(测试里手工构造的
/// `Exception('[network] ...')`、以及不会进 FfiError 的本地异常)。
const _kindNetwork = 'network';
const _kindForbidden = 'forbidden';

/// 取错误 kind: [rust.FfiError] 直接读字段, 其它异常兜底解析 `[kind]` 前缀。
String? errorKind(Object? e) {
  if (e is rust.FfiError) return e.kind;
  final m = RegExp(r'\[(\w+)\]').firstMatch(e?.toString() ?? '');
  return m?.group(1);
}

/// 把异常渲染成与 Rust 侧 `Display` 一致的文本(`[kind] detail`),
/// 便于日志/兜底文案继续可读; 非 FfiError 一律走 `toString()`(行为不变)。
String describeError(Object? e) {
  if (e is rust.FfiError) return '[${e.kind}] ${e.detail}';
  return e.toString();
}

/// 网络类错误(移动网络抖动/切网时常见 connection reset / os error 104)。
bool isNetworkError(Object? e) => errorKind(e) == _kindNetwork;

/// 是否值得重试: 结构化错误直接看 provider 给的 `retryable`(只有网络抖动类为 true),
/// 老字符串路径仍按 `[network]` 前缀判断。鉴权/风控/无版权一律立刻抛出。
bool isRetryableError(Object? e) {
  if (e is rust.FfiError) return e.retryable;
  return isNetworkError(e);
}

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
      if (!isRetryableError(e) || tries >= attempts) rethrow;
      await wait(delay * tries);
    }
  }
}

/// 给用户看的错误文案: 网络问题不要甩整串 os error 给他。
///
/// 按 [rust.FfiError.kind] 决策(不再靠 contains 猜), 用户可见文案与改造前一致:
/// - network: 统一"网络不稳定, 已自动重试仍失败, 请稍后重试"
/// - forbidden: "对方设置了隐私"(关注/粉丝列表不可见等), Rust 侧 detail
///   已经是能直接读的中文, 不要把内部 kind 前缀露给用户(用户反馈看到的
///   "[internal]code=400" 就是这类)
/// - 其它 kind: 保留 `[kind] detail` 原文, 方便定位问题
String friendlyError(Object e) {
  final kind = errorKind(e);
  if (kind == _kindNetwork) {
    return '网络不稳定, 已自动重试仍失败, 请稍后重试';
  }
  if (kind == _kindForbidden) {
    final detail =
        (e is rust.FfiError
                ? e.detail
                : e.toString().split('[$_kindForbidden]').last)
            .trim();
    return detail.isEmpty ? '没有权限查看' : detail;
  }
  return describeError(e);
}
