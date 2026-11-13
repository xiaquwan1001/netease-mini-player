// 上传器契约: 幂等 clientId 必须真的发到服务端; 4xx 不重试; 5xx/超时可重试;
// 端点未配置时一个请求都不发。
//
// 全部用本地真 HttpServer(127.0.0.1, 端口 0), 完全离线。注意用普通 test():
// 真 socket IO 在 testWidgets 的 FakeAsync 里不会完成。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/diag_upload.dart';

/// 假 Worker: 记录请求次数与 body, 由 handler 决定怎么回。
class _FakeWorker {
  _FakeWorker._(this._server);

  final HttpServer _server;
  int requests = 0;
  final List<String> bodies = <String>[];

  String get endpoint => 'http://127.0.0.1:${_server.port}/diag';

  static Future<_FakeWorker> start(
    FutureOr<void> Function(HttpRequest req, int attempt) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final worker = _FakeWorker._(server);
    server.listen((req) async {
      worker.requests++;
      final attempt = worker.requests;
      worker.bodies.add(await utf8.decoder.bind(req).join());
      try {
        await handler(req, attempt);
      } catch (_) {
        // 客户端超时/关闭后先断开 socket, 服务端这时再写回会抛错; 与用例无关
      }
    });
    return worker;
  }

  Future<void> close() => _server.close(force: true);
}

void reply(HttpRequest req, int status, Object? body) {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  req.response.close();
}

/// 测试里跳过真退避等待(生产环境是 0.5/1/2s)。
Future<void> noSleep(Duration _) async {}

const String clientId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

void main() {
  test('200 + {ok:true} ⇒ 返回 number/url, 且 body 里带 clientId', () async {
    final worker = await _FakeWorker.start(
      (req, _) async => reply(req, 200, {
        'ok': true,
        'number': 42,
        'url': 'https://github.com/o/r/issues/42',
      }),
    );
    addTearDown(worker.close);

    final uploader = DiagUploader(endpoint: worker.endpoint, sleep: noSleep);
    final result = await uploader.upload({
      'schema': 1,
      'app': '0.9.0',
    }, clientId: clientId);

    expect(result.number, 42);
    expect(result.url, 'https://github.com/o/r/issues/42');
    expect(worker.requests, 1);
    final sent = jsonDecode(worker.bodies.single) as Map<String, dynamic>;
    expect(sent['clientId'], clientId, reason: '幂等键必须真的发出去');
    expect(sent['schema'], 1);
  });

  test('400 ⇒ 不重试(只发 1 次)且 retryable=false', () async {
    final worker = await _FakeWorker.start(
      (req, _) async => reply(req, 400, {'error': 'unexpected_field'}),
    );
    addTearDown(worker.close);

    final uploader = DiagUploader(endpoint: worker.endpoint, sleep: noSleep);
    await expectLater(
      uploader.upload({'schema': 1}, clientId: clientId),
      throwsA(
        isA<DiagUploadError>()
            .having((e) => e.code, 'code', 'unexpected_field')
            .having((e) => e.retryable, 'retryable', false),
      ),
    );
    expect(worker.requests, 1, reason: '4xx 重试不会变好');
  });

  test('500 → 500 → 200 ⇒ 第 3 次成功', () async {
    final worker = await _FakeWorker.start((req, attempt) async {
      if (attempt < 3) {
        reply(req, 500, {'error': 'github_failed'});
      } else {
        reply(req, 200, {
          'ok': true,
          'number': 7,
          'url': 'https://github.com/o/r/issues/7',
        });
      }
    });
    addTearDown(worker.close);

    final uploader = DiagUploader(endpoint: worker.endpoint, sleep: noSleep);
    final result = await uploader.upload({'schema': 1}, clientId: clientId);

    expect(result.number, 7);
    expect(worker.requests, 3, reason: '两次 5xx 后应再试一次并成功');
  });

  test('全 500 ⇒ 抛 retryable=true', () async {
    final worker = await _FakeWorker.start(
      (req, _) async => reply(req, 500, {'error': 'github_failed'}),
    );
    addTearDown(worker.close);

    final uploader = DiagUploader(endpoint: worker.endpoint, sleep: noSleep);
    await expectLater(
      uploader.upload({'schema': 1}, clientId: clientId),
      throwsA(
        isA<DiagUploadError>()
            .having((e) => e.code, 'code', 'github_failed')
            .having((e) => e.retryable, 'retryable', true),
      ),
    );
    expect(worker.requests, 3, reason: '最多 3 次尝试, 不能无限重试');
  });

  test('endpoint 为空 ⇒ not_configured 且不发请求', () async {
    // 起一个服务只为断言"真的一个包都没收到"
    final worker = await _FakeWorker.start(
      (req, _) async => reply(req, 200, {'ok': true}),
    );
    addTearDown(worker.close);

    final uploader = DiagUploader(endpoint: '', sleep: noSleep);
    await expectLater(
      uploader.upload({'schema': 1}, clientId: clientId),
      throwsA(
        isA<DiagUploadError>()
            .having((e) => e.code, 'code', 'not_configured')
            .having((e) => e.retryable, 'retryable', false),
      ),
    );
    expect(worker.requests, 0, reason: '未配置时不该产生任何网络请求');
  });

  test('超时(服务端 sleep 2s, 客户端 200ms) ⇒ retryable=true', () async {
    final worker = await _FakeWorker.start((req, _) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      reply(req, 200, {
        'ok': true,
        'number': 1,
        'url': 'https://github.com/o/r/issues/1',
      });
    });
    addTearDown(worker.close);

    final uploader = DiagUploader(
      endpoint: worker.endpoint,
      timeout: const Duration(milliseconds: 200),
      sleep: noSleep,
    );
    await expectLater(
      uploader.upload({'schema': 1}, clientId: clientId),
      throwsA(
        isA<DiagUploadError>()
            .having((e) => e.code, 'code', 'timeout')
            .having((e) => e.retryable, 'retryable', true),
      ),
    );
    expect(worker.requests, greaterThan(0));
  });
}
