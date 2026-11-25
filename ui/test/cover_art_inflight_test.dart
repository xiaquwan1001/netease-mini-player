// 封面取字节的并发合并(审计 U8, 2026-11-25)。
//
// 一屏几十张封面首次加载时, 同一 URL 会被两条路同时请求: 列表里的 `NetImage`
// (走 Flutter ImageCache)与 `fetchImageBytes`(看大图/取主色/通知栏封面, **绕过**
// ImageCache)。旧实现 `_fetch` 在 `await` 之后才落缓存 ⇒ 并发调用各发一次请求。
//
// 这里盯的是两件不联网就能验的事:
// - 并发调用必须拿到**同一个在途 Future**(= 只发一次请求);
// - 那次失败后在途条目必须被摘掉, 否则一次失败会被永久记住(之后再也取不到图)。
//
// 为什么用 127.0.0.1:9: discard 端口上没有监听者 ⇒ 立刻 ECONNREFUSED,
// 用例不依赖外网(网络被禁的环境下也只是换一种连接错误, 断言不变)。
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart';

const String _url = 'https://127.0.0.1:9/inflight.jpg';

void main() {
  test('同一 URL 的并发取字节共用一个在途 Future, 失败后可以重试', () async {
    final first = fetchImageBytes(_url);
    final second = fetchImageBytes(_url);
    expect(
      identical(first, second),
      isTrue,
      reason: '并发调用必须合并成一次请求(旧实现在 await 之后才落缓存 ⇒ 两次)',
    );

    // 两个调用者都拿到同一次失败(不是 unhandled error, 也不是第二个请求)
    await expectLater(first, throwsA(anything));
    await expectLater(second, throwsA(anything));

    // 失败的在途条目已摘掉: 下一次调用是一次真正的新请求
    final retry = fetchImageBytes(_url);
    expect(
      identical(first, retry),
      isFalse,
      reason: '失败的 Future 不能留在在途表里, 否则这条路永久取不到图',
    );
    await expectLater(retry, throwsA(anything));
  });
}
