import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/home/search_controller.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;

/// 只桩住「猜你想搜」候选池用到的接口(`defaultSearch`; 另两个联想/历史接口留着断言「不再调用」), 其余调动直接抛(测试没覆盖到就是 bug)。
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
  Future<rust.DefaultSearch?> crateApiSearchDefaultSearch() async {
    defaultCalls++;
    if (failDefault) throw StateError('未登录');
    return defaults;
  }

  @override
  Future<List<String>> crateApiSearchSearchSuggestKeywords({
    required String keywords,
  }) async {
    suggestCalls.add(keywords);
    return suggests[keywords] ?? const <String>[];
  }

  @override
  Future<List<String>> crateApiSearchSearchHistory() async {
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

  test('只保留官方默认词一个, 不再用联想词扩池', () async {
    _api.reset(
      defaults: const rust.DefaultSearch(
        keyword: 'Mili',
        showText: '🔥Mili 你的十月榜首',
      ),
      history: const ['七里香', '晴天'],
      suggests: const {
        'Mili': ['Mili', 'Mili Fly,My Wings', '密林', '迷恋'],
        '七里香': ['七里香', '夜曲'],
      },
    );
    final c = controllerFor(() => DateTime(2026, 11, 20, 10));
    addTearDown(c.dispose);

    await c.refreshRecommended();

    // 2026-11 用户口径: 上游只给一个词, 其余联想词是对它的自动补全 ⇒ 只留这一个
    expect(c.recommended.map((e) => e.keyword).toList(), ['Mili']);
    expect(SearchController.recommendedLimit, 1);
    expect(c.recommended.single.reason, '🔥Mili 你的十月榜首');
    // 不再请求联想词/历史(否则又会把同一个意图拆成四个格子)
    expect(_api.suggestCalls, isEmpty);
    expect(_api.historyCalls, 0);
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

  test('默认词接口失败/未登录: 候选池为空(不拿联想词顶替)', () async {
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
    expect(c.recommended, isEmpty, reason: '没有官方默认词就整块不渲染');
    expect(_api.suggestCalls, isEmpty);
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
