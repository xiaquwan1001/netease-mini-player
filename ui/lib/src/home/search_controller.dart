import 'dart:async';

import 'package:flutter/widgets.dart';

import '../net_retry.dart' show friendlyError, retryNetwork;
import '../rust/api_all.dart' as rust;
import '../search_exact_bar.dart';
import '../search_landing.dart' show RecommendedKeyword;

/// 搜索状态机(从 main.dart 的 `_HomePageState` 搬出, 2026-11 拆壳 S3)。
///
/// 搬什么: 综合搜索结果([bundle])、输入联想(卡片/精确实体/纯关键词)、
/// 搜索历史、落地页热词与"猜你想搜"、请求代次 [_searchToken]、300ms 联想防抖、
/// 搜索忙碌标志([busy]), 以及只为它们服务的方法(搜索/取消/历史/热词/防抖/
/// 精确实体装配)。搬运动作逐行等价。
///
/// 不搬什么(**留在页面**):
/// - `_error` / `_retryLast`(顶部错误横幅属于整页, 也服务于歌单/心动模式);
/// - 歌单浏览态 `_libraryTitle` / `_libraryPlaylistId`(搜索只是"离开"它);
/// - 所有需要 BuildContext 的跳转(精确实体点开艺人/歌单/电台 = 页面的
///   `_openExact*`), 以及输入框/焦点本身(仍由页面持有, 这里只借用)。
///
/// 语义原样保留: 请求代次 token 丢弃旧结果 / mounted 守卫(这里用 [_disposed],
/// 页面 dispose 与本类 dispose 成对) / 300ms 防抖 / 常量空列表 /
/// 搜索即离开歌单浏览态 / 联想结果要校验"输入词没变"。
class SearchController extends ChangeNotifier {
  SearchController({
    required this.text,
    required this.focus,
    required this.onSearchFailed,
    required this.onClearSearchError,
    required this.onLeaveLibrary,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    focus.addListener(_onFocusChanged);
  }

  /// 时间源(只服务于「猜你想搜」的短 TTL; 测试注入假时钟, 生产就是 [DateTime.now])
  final DateTime Function() now;

  /// 搜索输入框(页面持有; 这里只读文本 / 写入联想着色)
  final TextEditingController text;

  /// 输入框焦点(页面持有; 失焦要收起联想, 重获焦点要刷新历史)
  final FocusNode focus;

  /// 搜索失败: 页面写 `_error` 并把 `_retryLast` 指回 [search](顶部横幅的重试)。
  final void Function(String message) onSearchFailed;

  /// 清掉顶部搜索错误(原 `_error = null` 与 `_retryLast = null` 的两处 setState)。
  final VoidCallback onClearSearchError;

  /// 搜索即离开歌单浏览态(原 setState 里的 `_libraryTitle/_libraryPlaylistId = null`)。
  final VoidCallback onLeaveLibrary;

  bool _disposed = false;

  // ---------------- 状态(真相同在) ----------------

  /// 搜索请求代次: 取消/重新搜索后旧请求的结果直接丢弃。
  int _searchToken = 0;

  Timer? _suggestDebounce;

  rust.SearchBundleDto? _bundle;

  /// 卡片式联想(web search_suggest)
  List<rust.SuggestItem> _suggestions = const [];

  /// 精确实体命中(search_multimatch; orders 为空 = 无命中)
  rust.SearchExact? _exact;

  /// 纯关键词联想(mobile search_suggest; 卡片/实体都空时的兜底)
  List<String> _keywordSuggestions = const [];

  List<String> _searchHistory = const [];

  // ---- 搜索落地页(热词/推荐词) ----
  List<rust.HotSearchTerm> _hotTerms = const [];

  /// "猜你想搜": **只放上游官方默认/推荐搜索词**(2026-11 用户口径: 官方一次只给一个,
  /// 其余联想词只是对它的自动补全, 一起摆出来等于把同一个意图说四遍)。
  /// 空列表 = 上游没给词(未登录常见) ⇒ 整块(含标题)不渲染。
  List<RecommendedKeyword> _recommended = const [];

  /// 上次拉候选池的时间(短 TTL 判定用; 失败也记, 避免每次进页面都重试打网络)
  DateTime? _recommendedFetchedAt;
  bool _recommendedLoading = false;
  bool _hotLoading = false;
  String? _hotError;

  bool _busy = false;

  // ---------------- 只读视图(页面渲染用) ----------------

  rust.SearchBundleDto? get bundle => _bundle;

  List<rust.SuggestItem> get suggestions => _suggestions;

  rust.SearchExact? get exact => _exact;

  List<String> get keywordSuggestions => _keywordSuggestions;

  List<String> get history => _searchHistory;

  List<rust.HotSearchTerm> get hotTerms => _hotTerms;

  /// 落地页「猜你想搜」的候选(空 = 没有任何可信候选, 整块不渲染)
  List<RecommendedKeyword> get recommended => _recommended;

  bool get recommendedLoading => _recommendedLoading;

  bool get hotLoading => _hotLoading;

  String? get hotError => _hotError;

  /// 搜索忙碌标志(原 `_busy`)。除搜索外, 心动模式/我喜欢的音乐也用它在
  /// 搜索条上显示"搜索中"并禁用按钮, 所以对外留 [setBusy]。
  bool get busy => _busy;

  /// 精确实体条视图(空命中由 SearchExactBar 自己隐藏)。
  SearchExactView? get exactView {
    final e = _exact;
    return e == null ? null : exactViewOf(e);
  }

  // ---------------- 搜索执行 / 取消 ----------------

  Future<void> search() async {
    final keyword = text.text.trim();
    if (keyword.isEmpty) return;
    final token = ++_searchToken;
    _suggestDebounce?.cancel();
    focus.unfocus();
    _busy = true;
    _suggestions = const [];
    _exact = null;
    _keywordSuggestions = const [];
    onClearSearchError();
    // 搜索即离开歌单浏览态, 结果列表要保持"这一屏是什么"的唯一来源
    onLeaveLibrary();
    if (_disposed) return;
    notifyListeners();
    try {
      final result = await retryNetwork(
        () => rust.searchAll(keywords: keyword, limit: 20),
      );
      if (_disposed || token != _searchToken) return;
      _bundle = result;
      notifyListeners();
      // 搜索历史是本地记录, 失败不影响搜索结果
      try {
        final history = await rust.recordSearch(keyword: keyword);
        if (!_disposed) {
          _searchHistory = history;
          notifyListeners();
        }
      } catch (_) {}
    } catch (e) {
      if (_disposed || token != _searchToken) return;
      onSearchFailed(friendlyError(e));
    } finally {
      if (!_disposed && token == _searchToken) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// 显式取消: 清掉输入、上一轮结果、联想和错误, 回到搜索落地页
  void clear() {
    _searchToken += 1;
    _suggestDebounce?.cancel();
    text.clear();
    focus.unfocus();
    _bundle = null;
    _suggestions = const [];
    _exact = null;
    _keywordSuggestions = const [];
    _busy = false;
    onClearSearchError();
    onLeaveLibrary();
    if (_disposed) return;
    notifyListeners();
  }

  /// 心动模式 / 我喜欢的音乐等非搜索流程借用同一个忙碌标志
  /// (拆分前它们直接 setState 改 `_busy`; 这里用通知换同一次重建)。
  void setBusy(bool value) {
    _busy = value;
    if (_disposed) return;
    notifyListeners();
  }

  // ---------------- 联想 / 历史 ----------------

  void _onFocusChanged() {
    if (_disposed) return;
    if (!focus.hasFocus) {
      _suggestions = const [];
      _exact = null;
      _keywordSuggestions = const [];
    } else {
      // 重新获得焦点: 刷新历史(别处可能新增过)
      unawaited(loadHistory());
    }
    notifyListeners();
  }

  Future<void> loadHistory() async {
    try {
      final list = await rust.searchHistory();
      if (_disposed) return;
      _searchHistory = list;
      notifyListeners();
    } catch (_) {
      // 历史读不出来不影响主流程
    }
  }

  /// 搜索落地页的热词榜. 与「猜你想搜」互相独立, 失败不影响搜索.
  Future<void> loadLanding() async {
    if (!_disposed) {
      _hotLoading = true;
      notifyListeners();
    }
    try {
      // 热搜用 hotsearchlist(带服务端榜位/热度, 固定 20 条); 失败再退回老的热词接口
      List<rust.HotSearchTerm> hot;
      try {
        final detail = await retryNetwork(rust.hotSearchDetail);
        hot = [
          for (final it in detail)
            rust.HotSearchTerm(rank: it.rank, keyword: it.keyword),
        ];
        if (hot.isEmpty) hot = await retryNetwork(rust.hotSearch);
      } catch (_) {
        hot = await retryNetwork(rust.hotSearch);
      }
      if (_disposed) return;
      _hotTerms = hot;
      _hotError = null;
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      _hotError = friendlyError(e);
      notifyListeners();
    } finally {
      if (!_disposed) {
        _hotLoading = false;
        notifyListeners();
      }
    }
  }

  // ---------------- 「猜你想搜」候选池 ----------------

  /// 候选上限 = **1**(只展示上游 API 返回的那一个词; 见 [recommendedLimit] 的字段注释)
  static const int recommendedLimit = 1;

  /// 候选池的短 TTL: 进入搜索页时按需重新拉, 10 分钟内复用上次结果。
  ///
  /// 不能做成永久缓存 —— 官方的默认词/联想词是"最近在听什么"的反映,
  /// 长期固定就成了死板的一块(2026-11 用户反馈"猜你想搜长期不变")。
  static const Duration recommendedTtl = Duration(minutes: 10);

  /// 进入搜索页时调用: 只有 TTL 到期(或从没拉过)才真正请求一次。
  ///
  /// [force] 给"重试"类入口用; 正常进页面不要传, 否则 10 分钟的短缓存就没意义了。
  Future<void> refreshRecommended({bool force = false}) async {
    if (_disposed || _recommendedLoading) return;
    final at = _recommendedFetchedAt;
    if (!force && at != null && now().difference(at) < recommendedTtl) {
      return;
    }
    await _loadRecommended();
  }

  /// 只取**官方「默认/推荐搜索」词**(`rust.defaultSearch`, 上游恒为 1 个, 带官方理由文案)。
  ///
  /// 2026-11 用户口径: 候选词实际只有一个, 后面的都是对第一个的联想/自动补充
  /// (如 `Mili` → `Mili Fly,My Wings` / `密林` / `迷恋`), 一起摆出来只是把同一意图说多遍 ⇒
  /// 不再用 `searchSuggestKeywords` 扩池, 也不掺热搜词(下方「热门搜索」已在展示同一批)。
  /// 接口失败/未登录 = 没有可信候选, 静默降级成空列表(整块不渲染)。
  Future<void> _loadRecommended() async {
    if (_disposed) return;
    _recommendedLoading = true;
    notifyListeners();

    // 官方默认/推荐搜索词: 上游恒给 1 个(未登录/接口失败时拿不到, 静默跳过)
    var next = const <RecommendedKeyword>[];
    try {
      final def = await rust.defaultSearch();
      if (_disposed) return;
      final keyword = (def?.keyword ?? '').trim();
      if (keyword.isNotEmpty) {
        next = List<RecommendedKeyword>.unmodifiable([
          RecommendedKeyword(keyword: keyword, reason: def?.showText),
        ]);
      }
    } catch (_) {}

    if (_disposed) return;
    // 新集合与当前展示一致就不替换, 避免进页面时无意义的重建/闪烁
    final same =
        next.length == _recommended.length &&
        List<int>.generate(
          next.length,
          (i) => i,
        ).every((i) => next[i] == _recommended[i]);
    if (!same) _recommended = next;
    _recommendedFetchedAt = now();
    _recommendedLoading = false;
    notifyListeners();
  }

  void onQueryChanged(String value) {
    _suggestDebounce?.cancel();
    // 让"清空/取消"按钮随输入内容即时出现
    if (!_disposed) notifyListeners();
    final q = value.trim();
    if (q.isEmpty) {
      _suggestions = const [];
      _exact = null;
      _keywordSuggestions = const [];
      notifyListeners();
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      // 三个来源并行: 联想卡片(web) / 精确实体(multimatch) / 纯关键词(mobile)
      final exactFuture = _loadExact(q);
      final keywordsFuture = _loadSuggestKeywords(q);
      try {
        final items = await rust.searchSuggest(keywords: q);
        if (_disposed || text.text.trim() != q) return;
        _suggestions = items;
        notifyListeners();
      } catch (_) {
        // 建议是锦上添花, 失败静默
      }
      final exact = await exactFuture;
      final keywords = await keywordsFuture;
      if (_disposed || text.text.trim() != q) return;
      _exact = exact;
      _keywordSuggestions = keywords;
      notifyListeners();
    });
  }

  Future<rust.SearchExact?> _loadExact(String q) async {
    try {
      final exact = await rust.searchExact(keywords: q);
      // orders 为空就是空命中伪装成 200, 当作没有
      return exact.orders.isEmpty ? null : exact;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _loadSuggestKeywords(String q) async {
    try {
      return await rust.searchSuggestKeywords(keywords: q);
    } catch (_) {
      return const [];
    }
  }

  /// DTO -> 精确实体条视图(空命中由 SearchExactBar 自己隐藏)
  SearchExactView exactViewOf(rust.SearchExact e) => SearchExactView(
    orders: e.orders,
    artists: [
      for (final a in e.artists)
        SearchExactArtist(
          id: a.id.toInt(),
          name: a.name,
          avatarUrl: a.avatarUrl,
        ),
    ],
    playlists: [
      for (final p in e.playlists)
        SearchExactPlaylist(
          id: p.id.toInt(),
          name: p.name,
          coverUrl: p.coverUrl,
          trackCount: p.trackCount.toInt(),
        ),
    ],
    podcasts: [
      for (final r in e.podcasts)
        SearchExactRadio(
          id: r.id.toInt(),
          name: r.name,
          coverUrl: r.coverUrl,
          djName: r.djName,
          programCount: r.programCount.toInt(),
        ),
    ],
  );

  /// 点联想词/历史/热词: 回填输入框(不触发 onChanged)再直接搜
  Future<void> searchKeyword(String keyword) async {
    text.text = keyword;
    text.selection = TextSelection.collapsed(offset: keyword.length);
    _suggestions = const [];
    _exact = null;
    _keywordSuggestions = const [];
    if (!_disposed) notifyListeners();
    await search();
  }

  Future<void> clearHistory() async {
    try {
      await rust.clearSearchHistory();
      if (_disposed) return;
      _searchHistory = const [];
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _suggestDebounce?.cancel();
    focus.removeListener(_onFocusChanged);
    super.dispose();
  }
}
