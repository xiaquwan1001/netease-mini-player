import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/home/search_controller.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;

/// 只桩住「猜你想搜」候选池用到的三个接口, 其余调动直接抛(测试没覆盖到就是 bug)。
///
/// flutter_rust_bridge 的 mock 只能装一次, 所以这里用**一个可变实例**:
/// [reset] 在每个用例开头换掉数据与计数器。
class _FakeRustApi implements RustLibApi {
  rust.DefaultSearch? defaults;
  Map<String, List<String>> suggests = const <String, List<String>>{};
  List<String> history = const <String>[];
  bool failDefault = false;

  int defaultCalls = 0;
  List<String> suggestCalls = <String>[];
  int historyCalls = 0;

  void reset({
    rust.DefaultSearch? defaults,
    Map<String, List<String>> suggests = const <String, List<String>>{},
    List<String> history = const <String>[],
    bool failDefault = false,
  }) {
    this.defaults = defaults;
    this.suggests = suggests;
    this.history = history;
    this.failDefault = failDefault;
    defaultCalls = 0;
    suggestCalls = <String>[];
    historyCalls = 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<rust.DefaultSearch?> crateApiDefaultSearch() async {
    defaultCalls++;
    if (failDefault) throw StateError('未登录');
    return defaults;
  }

  @override
  Future<List<String>> crateApiSearchSuggestKeywords({
    required String keywords,
  }) async {
    suggestCalls.add(keywords);
    return suggests[keywords] ?? const <String>[];
  }

  @override
  Future<List<String>> crateApiSearchHistory() async {
    historyCalls++;
    return history;
  }
}

final _FakeRustApi _api = _FakeRustApi();

SearchController controllerFor(DateTime Function() now) => SearchController(
  text: TextEditingController(),
  focus: FocusNode(),
  onSearchFailed: (_) {},
  onClearSearchError: () {},
  onLeaveLibrary: () {},
  now: now,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _api));

  test('多个来源合并去重、默认词优先、最多 4 个', () async {
    _api.reset(
      defaults: const rust.DefaultSearch(
        keyword: 'Mili',
        showText: '🔥Mili 你的十月榜首',
      ),
      history: const ['七里香', '晴天'],
      suggests: const {
        'Mili': ['Mili', 'Mili (Live)', 'Mili 歌词'],
        '七里香': ['七里香', '夜曲'],
      },
    );
    final c = controllerFor(() => DateTime(2026, 11, 20, 10));
    addTearDown(c.dispose);

    await c.refreshRecommended();

    expect(c.recommended.map((e) => e.keyword).toList(), [
      'Mili', // 默认词永远第一
      'Mili (Live)',
      'Mili 歌词',
      '七里香', // 第二个种子的联想词
    ]);
    expect(c.recommended.length, SearchController.recommendedLimit);
    // 官方理由跟着默认词走, 其它候选没有理由
    expect(c.recommended.first.reason, '🔥Mili 你的十月榜首');
    expect(c.recommended[1].reason, isNull);
    // 两个种子各请求一次
    expect(_api.suggestCalls, ['Mili', '七里香']);
    // 候选池里的词不会重复
    expect(c.recommended.map((e) => e.keyword).toSet().length, 4);
  });

  test('10 分钟内再进搜索页不重新请求; 过期后换新集合', () async {
    _api.reset(
      defaults: const rust.DefaultSearch(keyword: '旧词', showText: '旧理由'),
    );
    var clock = DateTime(2026, 11, 20, 10);
    final c = controllerFor(() => clock);
    addTearDown(c.dispose);

    await c.refreshRecommended();
    expect(c.recommended.single.keyword, '旧词');
    expect(_api.defaultCalls, 1);

    // TTL 内(9 分钟): 不刷新, 但已有内容也不清空
    clock = clock.add(const Duration(minutes: 9));
    await c.refreshRecommended();
    expect(_api.defaultCalls, 1, reason: 'TTL 内应复用上次结果');
    expect(c.recommended.single.keyword, '旧词');

    // 过期(11 分钟)后重新拉: 新集合替换旧集合
    _api.reset(
      defaults: const rust.DefaultSearch(keyword: '新词', showText: '新理由'),
    );
    clock = clock.add(const Duration(minutes: 2));
    await c.refreshRecommended();
    expect(_api.defaultCalls, 1);
    expect(c.recommended.single.keyword, '新词');
    expect(c.recommended.single.reason, '新理由');
  });

  test('force 绕过 TTL', () async {
    _api.reset(
      defaults: const rust.DefaultSearch(keyword: '词', showText: '理由'),
    );
    final clock = DateTime(2026, 11, 20, 10);
    final c = controllerFor(() => clock);
    addTearDown(c.dispose);

    await c.refreshRecommended();
    await c.refreshRecommended(force: true);
    expect(_api.defaultCalls, 2);
  });

  test('默认词接口失败: 静默降级到历史种子的联想词', () async {
    _api.reset(
      failDefault: true,
      history: const ['晴天'],
      suggests: const {
        '晴天': ['晴天', '晴天 (Live)'],
      },
    );
    final c = controllerFor(() => DateTime(2026, 11, 20, 10));
    addTearDown(c.dispose);

    await c.refreshRecommended();

    expect(_api.defaultCalls, 1);
    expect(c.recommended.map((e) => e.keyword).toList(), ['晴天', '晴天 (Live)']);
    expect(c.recommended.every((e) => e.reason == null), isTrue);
  });

  test('所有来源都空/失败: 候选池为空(整块不渲染), 且不会无限重试', () async {
    _api.reset(failDefault: true);
    final c = controllerFor(() => DateTime(2026, 11, 20, 10));
    addTearDown(c.dispose);

    await c.refreshRecommended();
    expect(c.recommended, isEmpty);
    expect(c.recommendedLoading, isFalse);

    // 失败也记时间戳: TTL 内不反复打网络
    await c.refreshRecommended();
    expect(_api.defaultCalls, 1);
  });

  test('候选池与当前展示相同则不替换(避免无意义重建)', () async {
    _api.reset(
      defaults: const rust.DefaultSearch(keyword: '同一个词', showText: '理由'),
    );
    var clock = DateTime(2026, 11, 20, 10);
    final c = controllerFor(() => clock);
    addTearDown(c.dispose);

    await c.refreshRecommended();
    final before = c.recommended;
    clock = clock.add(const Duration(minutes: 30));
    await c.refreshRecommended();
    expect(_api.defaultCalls, 2);
    expect(identical(c.recommended, before), isTrue);
  });
}
