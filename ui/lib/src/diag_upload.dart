import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 匿名诊断一键上传: POST 到 Worker(自建服务器不存在, token 只在 Worker)。
///
/// 为什么是"传给一个 Worker"而不是直连 GitHub: 建 Issue 要写权限 token,
/// token 一旦进客户端就等于公开(APK 可反编译)。Worker 侧持 token, 客户端只知道地址。
///
/// 职责边界: 这里只负责"把一份已经生成好的匿名 JSON 送到端点"和"把失败原因
/// 分类", 不决定失败后怎么办。'retryable' 由调用方解读: true=值得再试一次,
/// false=只能降级成本地文件让用户自己贴。
class DiagUploader {
  DiagUploader({
    required this.endpoint,
    this.clientFactory,
    this.timeout = const Duration(seconds: 15),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  /// 空字符串 = 未配置(构建时没注入端点), [upload] 直接抛 not_configured。
  final String endpoint;

  /// 单次尝试的超时。默认 15s: 移动网络下 Worker 冷启动 + GitHub 建单能到几秒。
  final Duration timeout;

  /// 测试注入: 默认 `HttpClient()`, 用例里可换成自定义实现。
  final HttpClient Function()? clientFactory;

  /// 退避用的等待(测试注入以跳过真等待)。
  final Future<void> Function(Duration) _sleep;

  /// 最多尝试 3 次(= 最多重试 2 次), 配合 [DiagUploader] 文档里的 0.5/1/2s 退避。
  static const int _maxAttempts = 3;
  static const List<Duration> _backoff = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

  /// 上传一份诊断包对象。[clientId] 是幂等键: 同一次"点击"用同一个 UUID,
  /// Worker 端据此避免重复建单。
  Future<DiagUploadResult> upload(
    Map<String, Object?> pkg, {
    required String clientId,
  }) {
    // 复制一份再合并: 不改调用方传进来的 map(它可能还要用来落盘)
    final body = <String, Object?>{...pkg, 'clientId': clientId};
    return _send(body);
  }

  /// 上传已序列化的 JSON 文本(用于复用 DebugReport 落盘的那份内容)。
  Future<DiagUploadResult> uploadJson(String json, {required String clientId}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      // 本地都在自己手里, 解析不了说明是程序 bug: 重试没有意义
      throw DiagUploadError(
        'bad_json',
        '诊断包不是合法 JSON: ${e.message}',
        retryable: false,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw DiagUploadError('bad_json', '诊断包顶层必须是对象', retryable: false);
    }
    return upload(decoded, clientId: clientId);
  }

  Future<DiagUploadResult> _send(Map<String, Object?> body) async {
    if (endpoint.trim().isEmpty) {
      // 未配置属于"产品上还没开这个功能", 不该被当成可重试故障
      throw DiagUploadError('not_configured', '未配置诊断上传端点', retryable: false);
    }
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw DiagUploadError(
        'bad_endpoint',
        '端点地址不合法: $endpoint',
        retryable: false,
      );
    }

    DiagUploadError? last;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) await _sleep(_backoff[attempt - 1]);
      try {
        return await _once(uri, body);
      } on DiagUploadError catch (e) {
        last = e;
        // 4xx / 结构错误: 再发一次会得到同样的答案, 立刻交给调用方降级
        if (!e.retryable) rethrow;
      }
    }
    throw last!;
  }

  /// 单次尝试: 每次新建 HttpClient 并在结束时强制关闭, 避免连接卡住泄漏。
  Future<DiagUploadResult> _once(Uri uri, Map<String, Object?> body) async {
    final client = (clientFactory ?? HttpClient.new)();
    client.connectionTimeout = timeout;
    try {
      // 整体超时(不只是连接): 服务端接了连接却不回包的情况也得收口
      return await _post(client, uri, body).timeout(timeout);
    } on TimeoutException {
      throw DiagUploadError(
        'timeout',
        '上传超时(${timeout.inMilliseconds}ms)',
        retryable: true,
      );
    } on SocketException catch (e) {
      // DNS 失败/连接被重置/代理阻断都走这里, 属于"可能下次就好"
      throw DiagUploadError('network', '网络错误: ${e.message}', retryable: true);
    } on HttpException catch (e) {
      throw DiagUploadError(
        'network',
        'HTTP 异常: ${e.message}',
        retryable: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<DiagUploadResult> _post(
    HttpClient client,
    Uri uri,
    Map<String, Object?> body,
  ) async {
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    // 直接写 UTF-8 字节: 让 Content-Length 确定, 服务端不用等 chunked
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final status = resp.statusCode;
    final Object? parsed = _tryJson(text);

    if (status == 200) {
      if (parsed is Map && parsed['ok'] == true) {
        final number = parsed['number'];
        final url = parsed['url'];
        if (number is int && url is String && url.isNotEmpty) {
          return DiagUploadResult(number: number, url: url);
        }
      }
      // 200 但形状不对: 服务端版本/契约不一致, 重试无益
      throw DiagUploadError(
        'bad_response',
        '服务端返回不是 {ok:true,number,url}: $text',
        retryable: false,
      );
    }

    final code = parsed is Map && parsed['error'] is String
        ? parsed['error'] as String
        : 'http_$status';
    // 4xx(白名单/限流/token)是我们或对方的策略问题, 重试只会更糟;
    // 5xx 多半是 GitHub 抖动, 值得再试。
    throw DiagUploadError(
      code,
      'HTTP $status: $text',
      retryable: status >= 500,
    );
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}

/// 上传成功的结果: Issue 编号 + 可点开的链接。
class DiagUploadResult {
  const DiagUploadResult({required this.number, required this.url});

  final int number;
  final String url;

  @override
  String toString() => 'DiagUploadResult(number: $number, url: $url)';
}

/// 上传失败。[code] 是稳定的机器可读码(not_configured/timeout/network/
/// rate_limited/unexpected_field/...), [retryable] 决定调用方"再试"还是"降级"。
class DiagUploadError implements Exception {
  const DiagUploadError(this.code, this.message, {required this.retryable});

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() =>
      'DiagUploadError($code, retryable: $retryable): $message';
}
