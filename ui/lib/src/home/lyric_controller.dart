import 'dart:async';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../lru.dart';
import '../lyric.dart';
import '../lyric_source.dart';
import '../net_retry.dart' show friendlyError;
import '../playback.dart';
import '../rust/api_all.dart' as rust;
import '../song_share.dart' show shareableLyricLines;
import '../word_lyric_view.dart';

/// 歌词状态机(从 main.dart 的 `_HomePageState` 搬出, 2026-11 拆壳 S2)。
///
/// 只搬"数据 + 索引计算 + 状态变更"; **渲染仍在 `HomePage._buildLyrics`**,
/// UI 部分留到 S2 之后的步骤。搬运动作逐行等价: 切歌重置 / seek 强制跟随 /
/// 展开期 120ms ticker 启停 / 翻译开关 / 多选分享 / 来源偏好与回落链路全部照旧。
///
/// 所有权(为什么有些东西仍留在页面):
/// - 本类持有歌词数据、歌词列表的 [ScrollController]、高频刷新 ticker、
///   两个"播放位置/播放中"notifier(它们高频变更, 不能走整页 setState);
/// - `_player` 是播放态的唯一真相(S4 才搬), 这里只通过 [player] 回调读, 不复制;
/// - 轮询 `_pollPlayer` / toast / 行高(依赖 MediaQuery 系统字号)由页面注入,
///   避免把播放协调层或 BuildContext 拉进歌词状态机。
/// - 状态变化一律走 [notifyListeners]; 页面用 `addListener(→setState)` 订阅,
///   与拆分前"每处状态变更各自 setState"的重建语义一一对应。
class LyricController extends ChangeNotifier {
  LyricController({
    required this.player,
    required this.pollPlayer,
    required this.itemExtentOf,
    required this.toast,
    this.loaders,
    this.rawLyricOf,
  });

  /// 播放态快照(真相在页面的 `_player`)。
  final PlayerView? Function() player;

  /// 展开歌词期间的高频刷新(原 `_pollPlayer`)。
  final Future<void> Function() pollPlayer;

  /// 歌词行高: 基准 56dp 随系统字号等比放大, 取值依赖 BuildContext。
  final double Function() itemExtentOf;

  final void Function(String message) toast;

  /// 三来源 loader; null = 走 FFI 的 `rust.*`。
  ///
  /// `@visibleForTesting`: 只有单测会传(换假 loader, 全程不联网); 生产由页面
  /// 构造时不传, 一律走 FFI。
  @visibleForTesting
  final LyricSourceLoaders? loaders;

  /// 原始 LRC 兜底取数; null = 走 FFI 的 `rust.lyric`(同上, 只给单测注入)
  @visibleForTesting
  final Future<String> Function(BigInt trackId)? rawLyricOf;

  bool _disposed = false;

  /// 歌词列表的滚动控制器(详情页歌词 + 三个 LyricView 共用同一个)。
  final _lyricScroll = ScrollController();

  List<ParsedLyricLine> _lyricLines = const [];
  List<BigInt> _lyricTimes = const [];

  /// 纯文本歌词兜底(无时间轴): 逐行接口失败/返回空时用 [parseLrc] 从原始 LRC 里取。
  List<String>? _lyricPlain;
  BigInt? _lyricTrackId;
  String? _lyricError;

  /// 测试用: [load] 真正发起取数的次数(按曲目 id 幂等短路的不计入)。
  @visibleForTesting
  int debugLoadCount = 0;

  // 歌词来源("yrc"/"ttml"/"line")与择优理由不再上屏(左下角那条像水印的
  // 小字已按用户要求去掉); 打分/择优口径在 Rust(src/lyric_source.dart 只做转发).
  int _lyricIndex = -1;
  bool _showLyrics = false;

  /// 歌词是否跟随播放自动滚动: 用户手动滑歌词时置 false, 点"定位"再置回 true
  bool _autoFollowLyric = true;

  /// 详情页歌词多选: 长按进入, 点行加/减选, 选中后右上角变成分享/取消
  final Set<int> _selectedLyricLines = <int>{};

  /// 逐字(karaoke)歌词数据; 有则优先用 [WordLyricView], 无则回落行级/纯文本链。
  List<WordLyricLineData> _wordLines = const [];

  /// 播放位置(毫秒)注入给 [WordLyricView]: 刷新只重建当前行, 不整页 setState。
  final ValueNotifier<int> _wordPositionMs = ValueNotifier<int>(0);

  /// 播放中标志注入给 [WordLyricView]/[KaraokeLine]: 播放时才在行内插值到 60fps,
  /// 暂停/default 场景不排帧(省电, 也让 pumpAndSettle 能收敛)。
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);

  /// 展开歌词时的高频位置刷新(~120ms); 收起必须停掉, 避免后台耗电。
  Timer? _lyricTicker;

  // ---------------- 只读视图(页面渲染用) ----------------

  /// 歌词页是否展开(原 `_showLyrics`)。
  bool get visible => _showLyrics;

  bool get autoFollow => _autoFollowLyric;

  /// 多选态(原 `_lyricSelecting`)。
  bool get selecting => _selectedLyricLines.isNotEmpty;

  Set<int> get selected => _selectedLyricLines;

  List<ParsedLyricLine> get lines => _lyricLines;

  List<String>? get plain => _lyricPlain;

  String? get error => _lyricError;

  List<WordLyricLineData> get wordLines => _wordLines;

  /// 当前高亮的行级歌词下标(-1 = 还没唱到第一句)。
  int get activeIndex => _lyricIndex;

  ScrollController get scroll => _lyricScroll;

  ValueNotifier<int> get positionMs => _wordPositionMs;

  ValueNotifier<bool> get playing => _playing;

  /// 歌词行高(页面注入的 [rowExtentFor] 口径)。
  double get itemExtent => itemExtentOf();

  /// 歌词里有没有翻译(tlyric). 没有时整页不出现翻译开关, 免得点出个空开关
  bool get hasTranslation =>
      _wordLines.any((l) => (l.sub ?? '').trim().isNotEmpty) ||
      _lyricLines.any((l) => (l.sub ?? '').trim().isNotEmpty);

  /// 当前播放位置对应的歌词行(-1 = 还没唱到第一句)
  int get currentIndex {
    final pos = player()?.positionMs ?? BigInt.zero;
    if (_wordLines.isNotEmpty) return wordLineIndexAt(_wordLines, pos.toInt());
    if (_lyricTimes.isNotEmpty) return lyricIndexAt(_lyricTimes, pos);
    return -1;
  }

  /// 已解析歌词的会话级缓存(按曲目 id, LRU 24 首)。
  ///
  /// 旧实现只有"当前一首"这一槽: A→B→A 每次都重新取(实测 `debugLoadCount` 3),
  /// 而用户最常见的动作恰恰是「进详情页 → 返回 → 再进」(2026-11-28 缓存审计 P1-5)。
  /// 24 首 ≈ 一小时的播放历史, 内存可以忽略(纯文本/行级数据都是短的)。
  final LruMap<BigInt, _LyricSnapshot> _lyricCache =
      LruMap<BigInt, _LyricSnapshot>(maxEntries: 24);

  // ---------------- 加载 ----------------

  /// 把一份快照套到当前状态上(命中缓存与网络取回共用同一条路)。
  ///
  /// 只有 id 仍然是当前曲目时才生效 —— 在飞的请求回来后曲目已经换了,
  /// 套上去就会看到"新歌配旧歌词"。
  void _applySnapshot(BigInt trackId, _LyricSnapshot snap) {
    if (_disposed || _lyricTrackId != trackId) return;
    _lyricError = null;
    _wordLines = snap.word ?? const [];
    _lyricLines = snap.lines ?? const [];
    _lyricTimes = snap.times ?? const [];
    _lyricPlain = snap.plain;
    _lyricCache.put(trackId, snap); // 回填/触碰 LRU
    notifyListeners();
    if (snap.word != null) {
      // 逐字歌词靠 [positionMs] 自绘高光, 不需要行级下标
      _wordPositionMs.value = player()?.positionMs.toInt() ?? 0;
      _playing.value = player()?.playing ?? false;
    } else {
      syncIndex(player() ?? PlayerView.empty);
    }
  }

  Future<void> load(BigInt trackId) async {
    if (_lyricTrackId == trackId) return;
    _lyricTrackId = trackId;
    debugLoadCount += 1;
    if (!_disposed) {
      _lyricLines = const [];
      _lyricTimes = const [];
      _lyricPlain = null;
      _lyricIndex = -1;
      _lyricError = null;
      _wordLines = const [];
      notifyListeners();
      _wordPositionMs.value = 0;
    }
    // 会话缓存命中: 不再发请求(A→B→A 只取两次)
    final cached = _lyricCache[trackId];
    if (cached != null) {
      _applySnapshot(trackId, cached);
      return;
    }
    // B13/C2: 逐字歌词来源决策(按用户偏好, auto 打分择优), loader 可注入(单测不联网)。
    final resolved = await resolveLyricSource(
      trackId,
      loaders ??
          LyricSourceLoaders(
            yrc: (id) async => rust.wordLyricLines(trackId: id),
            ttml: (id) async => rust.ttmlLyricLines(trackId: id),
            lineLevel: (id) async => rust.lyricLinesI18N(trackId: id),
          ),
      preference: AppSettings.instance.lyricSourcePreference,
    );
    if (resolved != null && !_disposed && _lyricTrackId == trackId) {
      final word = resolved.word;
      if (word != null) {
        _applySnapshot(
          trackId,
          _LyricSnapshot(
            word: [
              for (var i = 0; i < word.lines.length; i++)
                WordLyricLineData(
                  startMs: word.lines[i].startMs,
                  endMs: word.lines[i].endMs,
                  words: [
                    for (final w in word.lines[i].words)
                      WordLyricWord(
                        startMs: w.startMs,
                        endMs: w.endMs,
                        text: w.text,
                      ),
                  ],
                  sub: i < word.translationLines.length
                      ? word.translationLines[i]
                      : null,
                ),
            ],
          ),
        );
        return;
      }
      final lines = resolved.line;
      if (lines != null && lines.isNotEmpty) {
        _applySnapshot(
          trackId,
          _LyricSnapshot(
            lines: [
              for (final l in lines)
                ParsedLyricLine(timeMs: l.timeMs, text: l.text, sub: l.sub),
            ],
            times: [for (final l in lines) l.timeMs],
          ),
        );
        return;
      }
    }
    try {
      final lines = await (loaders?.lineLevel ?? rust.lyricLinesI18N)(
        trackId: trackId,
      );
      if (_disposed || _lyricTrackId != trackId) return;
      if (lines.isNotEmpty) {
        _applySnapshot(
          trackId,
          _LyricSnapshot(
            lines: [
              for (final l in lines)
                ParsedLyricLine(timeMs: l.timeMs, text: l.text, sub: l.sub),
            ],
            times: [for (final l in lines) l.timeMs],
          ),
        );
        return;
      }
      // 逐行接口没有内容(纯文本/老格式歌词) → 退回原始 LRC
      await _loadRawLyric(trackId);
    } catch (e) {
      if (_disposed || _lyricTrackId != trackId) return;
      // 兜底: 原始 LRC 里往往还有纯文本可显示; 都没有才报错
      final ok = await _loadRawLyric(trackId);
      if (!ok && !_disposed && _lyricTrackId == trackId) {
        _lyricError = friendlyError(e);
        // 失败不占位: 占着 id 会让同一首永远走上面的幂等早退 ——
        // 退出重进歌词页、点「重试」都不再发请求, 只能切歌才可能恢复(用户反馈)。
        _lyricTrackId = null;
        notifyListeners();
      }
    }
  }

  /// 歌词错误态的「重试」: 清掉占位后按当前曲目重新取一次。
  Future<void> retryLoad() {
    final id = player()?.trackId;
    if (id == null) return Future<void>.value();
    _lyricTrackId = null;
    // 重试 = 用户明确要求"再取一次": 命中的那条会话缓存必须作废, 否则点了等于没点
    _lyricCache.remove(id);
    return load(id);
  }

  /// 原始 LRC 兜底(逐行接口失败/为空时): 有时间轴就等价于逐行高亮,
  /// 只有纯文本就走 [PlainLyricView]。返回是否有内容可用。
  Future<bool> _loadRawLyric(BigInt trackId) async {
    try {
      final raw = await (rawLyricOf ?? rust.lyric)(trackId);
      if (_disposed || _lyricTrackId != trackId) return false;
      final doc = parseLrc(raw);
      if (doc.isEmpty) return false;
      _applySnapshot(
        trackId,
        doc.hasTimeline
            ? _LyricSnapshot(
                lines: doc.timed,
                times: [for (final l in doc.timed) l.timeMs],
              )
            : _LyricSnapshot(plain: doc.plain),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------- 索引与跟随 ----------------

  void syncIndex(PlayerView state, {bool force = false}) {
    if (!_showLyrics || _lyricTimes.isEmpty) return;
    final idx = lyricIndexAt(_lyricTimes, state.positionMs);
    // force=true: seek(拖/点进度条、切歌)后即使落在同一句也要把列表滚回当前句
    if (idx == _lyricIndex && !force) return;
    _lyricIndex = idx;
    notifyListeners();
    _scrollLyricTo(idx);
  }

  /// 把播放位置/播放中喂给两个高频 notifier, 再刷新高亮行。
  /// (`_pollPlayer` 里的那三行, 顺序与条件保持不变。)
  void followPlayer(PlayerView state) {
    if (state.positionMs != BigInt.from(_wordPositionMs.value)) {
      _wordPositionMs.value = state.positionMs.toInt();
    }
    if (_playing.value != state.playing) _playing.value = state.playing;
    syncIndex(state);
  }

  void _scrollLyricTo(int idx) {
    if (!_autoFollowLyric) return;
    if (!_lyricScroll.hasClients || idx < 0) return;
    final position = _lyricScroll.position;
    final extent = itemExtent;
    final target = idx * extent - (position.viewportDimension - extent) / 2;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    _lyricScroll.animateTo(
      clamped,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  /// 提前取歌词/歌曲信息(事件驱动, 不需要等用户点播放)。
  ///
  /// 两个触发点:
  /// - 冷启动恢复上次播放现场(`PlaybackCoordinator.restoreFromDisk`)——恢复出来的
  ///   曲目在用户点播放之前不会走 `_playSong`, 也就没有任何取链动作;
  /// - 进歌曲详情页(歌词页, [toggle] 展开时)——缓存不命中时用户看到的是
  ///   「暂无歌词 / 信息不可用」干等。
  ///
  /// 幂等: [load] 内部按曲目 id 去重(只对**取成功过**的曲目), 重复调用不重复请求。
  /// 失败不占位, 所以退出重进/「重试」会重新发一次。错误照旧进 [error]。
  /// 返回的 Future 供测试等待。
  Future<void> ensureLoaded() {
    final id = player()?.trackId;
    if (id == null) return Future<void>.value();
    return load(id);
  }

  /// 播放条/详情页的"展开歌词"开关。
  void toggle() {
    _showLyrics = !_showLyrics;
    // 每次进入详情页都恢复"跟随 + 无选中", 避免上次留下的状态让人困惑
    _autoFollowLyric = true;
    _selectedLyricLines.clear();
    notifyListeners();
    if (_showLyrics) {
      // 进页面即开始准备资源(不等点播放): 缓存不命中时不再干等「信息不可用」
      unawaited(ensureLoaded());
      // 仅展开期间提高刷新频率; 收起/切 tab 时必须停掉。
      _lyricTicker?.cancel();
      _lyricTicker = Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => pollPlayer(),
      );
      final current = player();
      if (current != null) {
        syncIndex(current);
        _wordPositionMs.value = current.positionMs.toInt();
        _playing.value = current.playing;
      }
    } else {
      _lyricTicker?.cancel();
      _lyricTicker = null;
    }
  }

  /// 切 tab / 收起歌词: 只改状态 + 停 ticker, **不发通知**
  /// (调用方自己的 setState 会重建; 与拆分前"setState 里置 false、之后 cancel"等价)。
  void collapse() {
    _showLyrics = false;
    _lyricTicker?.cancel();
    _lyricTicker = null;
  }

  /// 一键回到当前唱到的那句(并恢复跟随)
  void locateCurrent() {
    final idx = currentIndex;
    resumeFollow();
    if (idx < 0) {
      toast('还没唱到第一句');
      return;
    }
    _scrollLyricTo(idx);
  }

  /// 恢复自动跟随(进入歌词页 / seek 后)。
  ///
  /// [notify] = false 供"调用方自己已经在 setState 里"的场景使用(seek), 避免多一次通知。
  void resumeFollow({bool notify = true}) {
    if (!_autoFollowLyric) {
      _autoFollowLyric = true;
      if (notify) notifyListeners();
    }
  }

  /// 用户手动滑歌词: 停止自动跟随(否则下一句会把列表拽回去, 根本看不远)
  void pauseFollow() {
    if (!_autoFollowLyric) return;
    _autoFollowLyric = false;
    notifyListeners();
  }

  // ---------------- 翻译 / 多选 / 取文本 ----------------

  void toggleTranslation() {
    final next = !AppSettings.instance.lyricTranslation;
    // 先重建一次(翻译键的图标/色), 再异步落设置 —— 与拆分前 setState(() {}) 同序。
    notifyListeners();
    unawaited(AppSettings.instance.update(lyricTranslation: next));
  }

  /// 长按歌词行: 进入多选并选中该行; 之后点击任意行加/减选
  void selectLine(int index, {bool longPress = false}) {
    if (longPress) {
      _selectedLyricLines.add(index);
    } else if (!_selectedLyricLines.remove(index)) {
      _selectedLyricLines.add(index);
    }
    notifyListeners();
    if (longPress && _selectedLyricLines.length == 1) {
      toast('已选中 1 句歌词, 继续点击可多选');
    }
  }

  void clearSelection() {
    if (_selectedLyricLines.isEmpty) return;
    _selectedLyricLines.clear();
    notifyListeners();
  }

  /// 选中行的文本(按行号排序, 最多 8 行 —— 分享卡片放不下更多)
  List<String> selectedTexts() {
    final indexes = _selectedLyricLines.toList()..sort();
    return shareableLyricLines([for (final i in indexes) _textAt(i)], max: 8);
  }

  /// 取第 [i] 行歌词的纯文本(逐字歌词把词拼回整行)
  String _textAt(int i) {
    if (_wordLines.isNotEmpty) {
      if (i < 0 || i >= _wordLines.length) return '';
      return [for (final w in _wordLines[i].words) w.text].join();
    }
    if (_lyricLines.isNotEmpty) {
      if (i < 0 || i >= _lyricLines.length) return '';
      return _lyricLines[i].text;
    }
    final plain = _lyricPlain;
    if (plain == null || i < 0 || i >= plain.length) return '';
    return plain[i];
  }

  @override
  void dispose() {
    _disposed = true;
    _lyricTicker?.cancel();
    _lyricScroll.dispose();
    _wordPositionMs.dispose();
    _playing.dispose();
    super.dispose();
  }
}

/// 一份「已解析好的歌词」: 逐字 / 行级 / 纯文本三者取其一。
///
/// 只存渲染需要的形状(不是 Rust 的原始 DTO), 这样会话缓存不用重新解析。
class _LyricSnapshot {
  const _LyricSnapshot({this.word, this.lines, this.times, this.plain})
    : assert(word != null || lines != null || plain != null, '空快照没有意义');

  /// 逐字歌词源(优先)
  final List<WordLyricLineData>? word;

  /// 行级歌词(有时间轴)
  final List<ParsedLyricLine>? lines;

  /// 与 [lines] 一一对应的时间轴(避免每次重新 map)
  final List<BigInt>? times;

  /// 无时间轴的纯文本(老格式歌词兜底)
  final List<String>? plain;
}
