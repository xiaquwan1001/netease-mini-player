import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals, setEquals;
import 'package:flutter/material.dart';

import 'theme.dart' show AccentPalette;

// settings.json 的读写细节(按域解析 + 落盘 map)在 part 文件里。
// 字段仍全在本类(单例形状未变, §12.6 只拆「编解码」这一层)。
part 'app_settings_codec.dart';

/// 全局 UI/播放偏好. 只存轻量 JSON, 放在 Rust 用的同一个 dataDir 下,
/// 双端(Android/Linux)都不依赖平台插件.
///
/// 设置项刻意保持"少而稳定": 主题模式、界面字号、取链音质。
/// 账号/凭据不在这里(由 Rust 的 identity.json + 账号簿负责)。
/// 封面/图片清晰度档位.
///
/// 语义: 向网易云 CDN 请求缩略图时, 边长 = 显示逻辑尺寸 x 设备像素比 x 该档位倍数.
/// - [dataSaver] 0.75x: 省流, 视觉略软(移动网络/小内存机器)
/// - [standard] 1.0x: 屏幕 1:1 —— **默认**, 相当于"不再把 44dp 的图当 44px 用"
/// - [ultra] 2.0x: 缩放到非整数倍也锐利, 流量/内存换清晰度
enum CoverQuality { dataSaver, standard, ultra }

extension CoverQualityX on CoverQuality {
  /// 持久化用的稳定名字(不要改: 改了老配置读不回来)
  String get id => switch (this) {
    CoverQuality.dataSaver => 'dataSaver',
    CoverQuality.standard => 'standard',
    CoverQuality.ultra => 'ultra',
  };

  /// 设置界面的档位名
  String get label => switch (this) {
    CoverQuality.dataSaver => '省流',
    CoverQuality.standard => '标准',
    CoverQuality.ultra => '超清',
  };

  /// 一句话说明(设置项副标题)
  String get hint => switch (this) {
    CoverQuality.dataSaver => '按 0.75 倍屏幕像素取图, 流量最省',
    CoverQuality.standard => '按屏幕像素 1:1 取图, 与设备分辨率一致(推荐)',
    CoverQuality.ultra => '按 2 倍屏幕像素取图, 放大也锐利, 流量更大',
  };

  double get multiplier => switch (this) {
    CoverQuality.dataSaver => 0.75,
    CoverQuality.standard => 1.0,
    CoverQuality.ultra => 2.0,
  };

  static CoverQuality fromId(String? raw) => switch (raw) {
    'dataSaver' => CoverQuality.dataSaver,
    'ultra' => CoverQuality.ultra,
    _ => CoverQuality.standard,
  };
}

/// 点主窗口关闭按钮(或 Alt+F4)时的行为 —— 目前只有 Linux 桌面有第二条路径。
///
/// 默认 [CloseBehavior.quit]: 与改造前完全一致("点关闭就退出"), 老配置读进来行为不变。
/// Windows 端本轮**未实现**(窗口关闭仍是直接退出), 设置项在那边的文案必须如实说明,
/// 见 desktop_shell.dart 的 [closeBehaviorSubtitle]。
enum CloseBehavior {
  /// 直接退出(杀进程, 播放停止)
  quit,

  /// 隐藏主窗口到系统托盘, 进程/播放继续; 托盘「退出」才真的终止
  minimizeToTray,
}

extension CloseBehaviorX on CloseBehavior {
  /// 持久化用的稳定 id(不要改: 改了老配置读不回来)
  String get id => switch (this) {
    CloseBehavior.quit => 'quit',
    CloseBehavior.minimizeToTray => 'tray',
  };

  /// 设置页分段控件的档位名
  String get label => switch (this) {
    CloseBehavior.quit => '直接退出',
    CloseBehavior.minimizeToTray => '最小化到托盘',
  };

  static CloseBehavior fromId(Object? raw) =>
      raw == 'tray' ? CloseBehavior.minimizeToTray : CloseBehavior.quit;
}

/// 推荐页顶栏第一格「自定义」可绑定的动作(2026-11-19 用户口径: 这一格留给
/// 自定义功能, 不再和下方「每日推荐」区块的「全部」重复)。
///
/// 持久化用 [CustomQuickActionX.id](稳定字符串), 缺字段/未知值回落
/// [CustomQuickAction.ranking] —— 既不是重复入口, 又有真实落地页。
enum CustomQuickAction {
  /// 听歌排行(需登录, 与「我的」页同一个落地页)
  ranking,

  /// 新歌新碟分类页
  newRelease,

  /// 歌单广场
  playlistSquare,

  /// 历史日推(每日推荐页的第三个页签)
  historyDaily,

  /// 私人 FM
  personalFm,
}

extension CustomQuickActionX on CustomQuickAction {
  /// 持久化用的稳定 id(不要改: 改了老配置读不回来)
  String get id => switch (this) {
    CustomQuickAction.ranking => 'ranking',
    CustomQuickAction.newRelease => 'newRelease',
    CustomQuickAction.playlistSquare => 'playlistSquare',
    CustomQuickAction.historyDaily => 'historyDaily',
    CustomQuickAction.personalFm => 'personalFm',
  };

  /// 快捷卡文案(也是自定义浮层里单选项的标题)
  String get label => switch (this) {
    CustomQuickAction.ranking => '排行榜',
    CustomQuickAction.newRelease => '新歌新碟',
    CustomQuickAction.playlistSquare => '歌单广场',
    CustomQuickAction.historyDaily => '历史日推',
    CustomQuickAction.personalFm => '私人FM',
  };

  /// 缺字段/未知值一律回落默认动作(排行榜)。
  static CustomQuickAction fromId(Object? raw) => CustomQuickAction.values
      .firstWhere((v) => v.id == raw, orElse: () => CustomQuickAction.ranking);
}

/// 设置域: 与 app_settings_codec.dart 的七个 `_apply*` 一一对应。
///
/// 一次变更先算"哪些域真的变了"([AppSettingsSnapshot.diffTo]), 订阅方按域收通知;
/// 音量滑块这类高频写入因此不会再惊动外观/交互域的订阅者。
enum AppSettingsDomain {
  /// 外观: 主题/强调色/字号/封面行列/清晰度/OLED 纯黑
  appearance,

  /// 播放与音质: 音质档/跳过 VIP/精细音量/响度/EQ/淡入/解码缓存/歌词来源
  playback,

  /// 搜索与列表: 切换清空/热搜榜/日推缓存天数/歌单内点歌行为
  search,

  /// 平台与窗口: 关闭按钮行为
  platform,

  /// 自动更新: 检查频率与节流/跳过记录
  update,

  /// 诊断: 匿名诊断包开关
  diagnostics,

  /// 交互记录: 「我的」页排序时间戳 + 队列左滑提示记忆
  interactions,
}

/// [AppSettings] 的**不可变状态快照**(§12.6 第二步)。
///
/// 为什么要不可变: 以前这些偏好全是可变 public 成员, "一次操作到底改了哪些字段"
/// 无法机械判断, 于是只能整份 `notifyListeners()` —— 音量滑块每拖一格都会
/// 把根 MaterialApp(主题/字号/整棵树)重建一遍。现在每次变更产出**一份新快照**,
/// 新旧一比就知道变了哪些域(见 [diffTo]), 订阅方只收自己关心的域
/// (见 [AppSettings.addScopedListener] / [AppSettingsScopedBuilder])。
///
/// 语义纪律:
///   · 字段与 [AppSettings] 的同名 getter **一一对应**, 默认值等于"不改变现状";
///   · 校验/夹取仍然只发生在读侧与 [AppSettings.update](快照本身不夹), 与改造前一致;
///   · 拿到手里的旧快照**永不改变**(新变更只换 [AppSettings] 内部的那一份)。
@immutable
class AppSettingsSnapshot {
  const AppSettingsSnapshot({
    this.themeMode = ThemeMode.system,
    this.accent = AccentPalette.neteaseRed,
    this.textScale = 1.0,
    this.audioLevel = 'exhigh',
    this.coverRows = 1,
    this.gridColumns = 3,
    this.clearSearchOnTabSwitch = true,
    this.showHotSearch = true,
    this.skipVipSongs = false,
    this.dailyCacheDays = 7,
    this.anonymousDebug = false,
    this.queueSwipeHintDismissed = false,
    this.detailFace = 'lyrics',
    this.coverQuality = CoverQuality.standard,
    this.oledDark = false,
    this.customQuickAction = CustomQuickAction.ranking,
    this.volumeGainDb = 0.0,
    this.loudnessNormalize = false,
    this.loudnessTargetLufs = -16.0,
    this.loudnessDynamic = false,
    this.eqProfileName,
    this.eqProfileText,
    this.fadeMs = 0,
    this.hardwareDecode = true,
    this.streamCache = true,
    this.cacheLimitMb = 512,
    this.lyricTranslation = true,
    this.lyricSourcePreference = 'amll',
    this.closeBehavior = CloseBehavior.quit,
    this.librarySearchPlayAction = LibrarySearchPlayAction.fullList,
    this.updateCheckInterval = UpdateCheckInterval.daily,
    this.lastUpdateCheckMs,
    this.skippedUpdateVersion,
    this.interactions = const <String, int>{},
  });

  final ThemeMode themeMode;
  final AccentPalette accent;
  final double textScale;
  final String audioLevel;
  final int coverRows;
  final int gridColumns;
  final bool clearSearchOnTabSwitch;
  final bool showHotSearch;
  final bool skipVipSongs;
  final int dailyCacheDays;
  final bool anonymousDebug;
  final bool queueSwipeHintDismissed;

  /// 详情页上次停在的那一面('lyrics' | 'cover'), 见 [AppSettings.detailFace]。
  final String detailFace;
  final CoverQuality coverQuality;
  final bool oledDark;

  /// 推荐页顶栏第一格「自定义」绑定的动作(B7)。
  final CustomQuickAction customQuickAction;
  final double volumeGainDb;
  final bool loudnessNormalize;
  final double loudnessTargetLufs;
  final bool loudnessDynamic;
  final String? eqProfileName;
  final String? eqProfileText;
  final int fadeMs;
  final bool hardwareDecode;
  final bool streamCache;
  final int cacheLimitMb;
  final bool lyricTranslation;
  final String lyricSourcePreference;
  final CloseBehavior closeBehavior;
  final LibrarySearchPlayAction librarySearchPlayAction;
  final UpdateCheckInterval updateCheckInterval;
  final int? lastUpdateCheckMs;
  final String? skippedUpdateVersion;

  /// 最近交互记录(epoch ms), 只读视图; 新记录产出**新 map**, 老快照看不到。
  final Map<String, int> interactions;

  /// copyWith 里区分"没传"与"显式传 null"的哨兵([eqProfileName] 等可空字段要用)。
  static const Object _notPassed = Object();

  AppSettingsSnapshot copyWith({
    ThemeMode? themeMode,
    AccentPalette? accent,
    double? textScale,
    String? audioLevel,
    int? coverRows,
    int? gridColumns,
    bool? clearSearchOnTabSwitch,
    bool? showHotSearch,
    bool? skipVipSongs,
    int? dailyCacheDays,
    bool? anonymousDebug,
    bool? queueSwipeHintDismissed,
    String? detailFace,
    CoverQuality? coverQuality,
    bool? oledDark,
    CustomQuickAction? customQuickAction,
    double? volumeGainDb,
    bool? loudnessNormalize,
    double? loudnessTargetLufs,
    bool? loudnessDynamic,
    Object? eqProfileName = _notPassed,
    Object? eqProfileText = _notPassed,
    int? fadeMs,
    bool? hardwareDecode,
    bool? streamCache,
    int? cacheLimitMb,
    bool? lyricTranslation,
    String? lyricSourcePreference,
    CloseBehavior? closeBehavior,
    LibrarySearchPlayAction? librarySearchPlayAction,
    UpdateCheckInterval? updateCheckInterval,
    Object? lastUpdateCheckMs = _notPassed,
    Object? skippedUpdateVersion = _notPassed,
    Map<String, int>? interactions,
  }) {
    return AppSettingsSnapshot(
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
      textScale: textScale ?? this.textScale,
      audioLevel: audioLevel ?? this.audioLevel,
      coverRows: coverRows ?? this.coverRows,
      gridColumns: gridColumns ?? this.gridColumns,
      clearSearchOnTabSwitch:
          clearSearchOnTabSwitch ?? this.clearSearchOnTabSwitch,
      showHotSearch: showHotSearch ?? this.showHotSearch,
      skipVipSongs: skipVipSongs ?? this.skipVipSongs,
      dailyCacheDays: dailyCacheDays ?? this.dailyCacheDays,
      anonymousDebug: anonymousDebug ?? this.anonymousDebug,
      queueSwipeHintDismissed:
          queueSwipeHintDismissed ?? this.queueSwipeHintDismissed,
      detailFace: detailFace ?? this.detailFace,
      coverQuality: coverQuality ?? this.coverQuality,
      oledDark: oledDark ?? this.oledDark,
      customQuickAction: customQuickAction ?? this.customQuickAction,
      volumeGainDb: volumeGainDb ?? this.volumeGainDb,
      loudnessNormalize: loudnessNormalize ?? this.loudnessNormalize,
      loudnessTargetLufs: loudnessTargetLufs ?? this.loudnessTargetLufs,
      loudnessDynamic: loudnessDynamic ?? this.loudnessDynamic,
      eqProfileName: identical(eqProfileName, _notPassed)
          ? this.eqProfileName
          : eqProfileName as String?,
      eqProfileText: identical(eqProfileText, _notPassed)
          ? this.eqProfileText
          : eqProfileText as String?,
      fadeMs: fadeMs ?? this.fadeMs,
      hardwareDecode: hardwareDecode ?? this.hardwareDecode,
      streamCache: streamCache ?? this.streamCache,
      cacheLimitMb: cacheLimitMb ?? this.cacheLimitMb,
      lyricTranslation: lyricTranslation ?? this.lyricTranslation,
      lyricSourcePreference:
          lyricSourcePreference ?? this.lyricSourcePreference,
      closeBehavior: closeBehavior ?? this.closeBehavior,
      librarySearchPlayAction:
          librarySearchPlayAction ?? this.librarySearchPlayAction,
      updateCheckInterval: updateCheckInterval ?? this.updateCheckInterval,
      lastUpdateCheckMs: identical(lastUpdateCheckMs, _notPassed)
          ? this.lastUpdateCheckMs
          : lastUpdateCheckMs as int?,
      skippedUpdateVersion: identical(skippedUpdateVersion, _notPassed)
          ? this.skippedUpdateVersion
          : skippedUpdateVersion as String?,
      interactions: interactions ?? this.interactions,
    );
  }

  /// 与 [other] 相比**真的变了**的域(空集合 = 什么都没变)。
  ///
  /// 这是统一 diff 通知的唯一判据: 通知按域分发给
  /// [AppSettings.addScopedListener] 的订阅者, 全体 [AppSettings.addListener] 照旧。
  Set<AppSettingsDomain> diffTo(AppSettingsSnapshot other) {
    final changed = <AppSettingsDomain>{};
    if (themeMode != other.themeMode ||
        accent != other.accent ||
        textScale != other.textScale ||
        coverRows != other.coverRows ||
        gridColumns != other.gridColumns ||
        coverQuality != other.coverQuality ||
        oledDark != other.oledDark ||
        customQuickAction != other.customQuickAction) {
      changed.add(AppSettingsDomain.appearance);
    }
    if (audioLevel != other.audioLevel ||
        skipVipSongs != other.skipVipSongs ||
        volumeGainDb != other.volumeGainDb ||
        loudnessNormalize != other.loudnessNormalize ||
        loudnessTargetLufs != other.loudnessTargetLufs ||
        loudnessDynamic != other.loudnessDynamic ||
        eqProfileName != other.eqProfileName ||
        eqProfileText != other.eqProfileText ||
        fadeMs != other.fadeMs ||
        hardwareDecode != other.hardwareDecode ||
        streamCache != other.streamCache ||
        cacheLimitMb != other.cacheLimitMb ||
        lyricTranslation != other.lyricTranslation ||
        lyricSourcePreference != other.lyricSourcePreference) {
      changed.add(AppSettingsDomain.playback);
    }
    if (clearSearchOnTabSwitch != other.clearSearchOnTabSwitch ||
        showHotSearch != other.showHotSearch ||
        dailyCacheDays != other.dailyCacheDays ||
        librarySearchPlayAction != other.librarySearchPlayAction) {
      changed.add(AppSettingsDomain.search);
    }
    if (closeBehavior != other.closeBehavior) {
      changed.add(AppSettingsDomain.platform);
    }
    if (updateCheckInterval != other.updateCheckInterval ||
        lastUpdateCheckMs != other.lastUpdateCheckMs ||
        skippedUpdateVersion != other.skippedUpdateVersion) {
      changed.add(AppSettingsDomain.update);
    }
    if (anonymousDebug != other.anonymousDebug) {
      changed.add(AppSettingsDomain.diagnostics);
    }
    // 详情面偏好与交互记录同域: 它不参与渲染(当前面由 DetailFaces 自己持有),
    // 所以切面不该触发外观域订阅者(整棵 MaterialApp)重建。
    if (queueSwipeHintDismissed != other.queueSwipeHintDismissed ||
        detailFace != other.detailFace ||
        !mapEquals(interactions, other.interactions)) {
      changed.add(AppSettingsDomain.interactions);
    }
    return changed;
  }
}

class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  // ---------------- §12.6: 不可变快照 + 按域 diff 通知 ----------------

  /// 当前状态。**唯一权威**: 所有读点都经同名 getter 委托到这里。
  AppSettingsSnapshot _snapshot = const AppSettingsSnapshot();

  /// 当前状态的只读视图(拿到的快照永不改变, 可以安全存起来做前后比对)。
  AppSettingsSnapshot get snapshot => _snapshot;

  /// 按域订阅的回调: 一个回调只绑一组域(重复 add 会覆盖域集合)。
  final Map<VoidCallback, Set<AppSettingsDomain>> _scopedListeners =
      <VoidCallback, Set<AppSettingsDomain>>{};

  /// 批量窗口内的已完成域(一次 update()/load() 只发一次通知)。
  final Set<AppSettingsDomain> _batchedDomains = <AppSettingsDomain>{};

  int _batchDepth = 0;
  bool _batchDirty = false;
  int _quietDepth = 0;

  /// 订阅"只在 [domains] 里的域变化时"才回调(与全体 [addListener] 并存, 互不影响)。
  ///
  /// 用法: 高频写入点(音量滑块/播放参数)的消费者从 `addListener` 换成
  /// `addScopedListener({AppSettingsDomain.playback}, ...)`, 未变的域不再惊动它。
  void addScopedListener(
    Set<AppSettingsDomain> domains,
    VoidCallback listener,
  ) {
    assert(domains.isNotEmpty, '按域订阅至少要给一个域');
    _scopedListeners[listener] = Set<AppSettingsDomain>.of(domains);
  }

  void removeScopedListener(VoidCallback listener) {
    _scopedListeners.remove(listener);
  }

  /// 一次状态变更的唯一入口: 换快照 → 算 diff → 按域分发。
  ///
  /// 域集合为空(写的值和原来一样)时**不通知**: 旧实现里这类空写也会整份通知,
  /// 是"拖动滑块时全树重建"的另一半来源。
  void _update(AppSettingsSnapshot next) {
    final prev = _snapshot;
    if (identical(prev, next)) return;
    _snapshot = next;
    if (prev.coverQuality != next.coverQuality) {
      // 封面清晰度还有一批 ValueListenableBuilder 订阅者(上百个封面图),
      // 它们只吃 notifier, 不进全局通知(见 coverQualityListenable 的注释)。
      coverQualityListenable.value = next.coverQuality;
    }
    final changed = prev.diffTo(next);
    if (changed.isEmpty || _quietDepth > 0) return;
    if (_batchDepth > 0) {
      _batchedDomains.addAll(changed);
      _batchDirty = true;
      return;
    }
    _dispatch(changed);
  }

  /// 开一个批量窗口: 窗口内的多次写只发一次通知(update()/load() 用)。
  void _beginBatch() {
    _batchDepth++;
  }

  void _endBatch() {
    if (_batchDepth == 0) return;
    _batchDepth--;
    if (_batchDepth > 0) return;
    final changed = Set<AppSettingsDomain>.of(_batchedDomains);
    final dirty = _batchDirty;
    _batchedDomains.clear();
    _batchDirty = false;
    if (!dirty) return;
    _dispatch(changed);
  }

  /// 静默写(只改状态/落盘, 不通知): 更新检查的节流记录用, 保持旧语义。
  void _quiet(void Function() body) {
    _quietDepth++;
    try {
      body();
    } finally {
      _quietDepth--;
    }
  }

  void _dispatch(Set<AppSettingsDomain> changed) {
    // 全体监听者: 旧契约不变(任何变更都通知), 未迁移的读点零改动。
    super.notifyListeners();
    if (_scopedListeners.isEmpty) return;
    for (final entry in _scopedListeners.entries.toList(growable: false)) {
      // 回调里可能顺手 add/remove 订阅: 发之前确认这一条还在、域集合没被换掉。
      if (!identical(_scopedListeners[entry.key], entry.value)) continue;
      if (entry.value.any(changed.contains)) entry.key();
    }
  }

  @override
  void notifyListeners() {
    // 直接调 notifyListeners 的路径(测试/兼容旧代码)按"全领域变化"处理,
    // 否则按域订阅的 widget 会漏掉这类通知; 正常变更走 [_dispatch]。
    super.notifyListeners();
    if (_scopedListeners.isEmpty) return;
    for (final entry in _scopedListeners.entries.toList(growable: false)) {
      if (!identical(_scopedListeners[entry.key], entry.value)) continue;
      entry.key();
    }
  }

  ThemeMode get themeMode => _snapshot.themeMode;
  set themeMode(ThemeMode value) =>
      _update(_snapshot.copyWith(themeMode: value));

  /// 视觉风格(主题色). 默认网易云红 = 与改造前完全一致; 浅色/深色共用同一个色板。
  AccentPalette get accent => _snapshot.accent;
  set accent(AccentPalette value) => _update(_snapshot.copyWith(accent: value));

  /// 界面字号倍率(叠在系统字号之上)。1.0 = 跟随系统。
  ///
  /// 只有一个入口: 设置页滑块 [kTextScaleMin]..[kTextScaleMax] 步长 [kTextScaleStep],
  /// 永远落在 0.05 的格子上(见 [snapTextScale])。2026-11-14 用户反馈: 滑块已经够用,
  /// 「小/标准/大/特大」档位 chip 是重复的第二套入口, 已移除。
  double get textScale => _snapshot.textScale;
  set textScale(double value) => _update(_snapshot.copyWith(textScale: value));

  /// ncm-provider 的音质字符串: standard / higher / exhigh / lossless / hires
  String get audioLevel => _snapshot.audioLevel;
  set audioLevel(String value) =>
      _update(_snapshot.copyWith(audioLevel: value));

  /// 推荐页歌单/播客卡片每屏展示几排(1 排 = 横向滑动, 2 排 = 网格)
  int get coverRows => _snapshot.coverRows;
  set coverRows(int value) => _update(_snapshot.copyWith(coverRows: value));

  /// 方格网格(艺人专辑 / 新碟 / 歌单广场)每行列数, 2-4。
  ///
  /// 之前用 maxCrossAxisExtent 拍死列宽: 列数随屏幕漂移、格子末端留白。
  /// 改为显式列数 + 均分(见 [coverGridDelegate])。
  int get gridColumns => _snapshot.gridColumns;
  set gridColumns(int value) => _update(_snapshot.copyWith(gridColumns: value));

  /// 切回"搜索"底部 tab 时是否丢弃上一次的输入/结果(默认丢弃, 避免残留)
  bool get clearSearchOnTabSwitch => _snapshot.clearSearchOnTabSwitch;
  set clearSearchOnTabSwitch(bool value) =>
      _update(_snapshot.copyWith(clearSearchOnTabSwitch: value));

  /// 搜索页是否展示「热门搜索」榜(默认展示; 关闭后只留历史与猜你想搜)
  bool get showHotSearch => _snapshot.showHotSearch;
  set showHotSearch(bool value) =>
      _update(_snapshot.copyWith(showHotSearch: value));

  /// 播放时跳过 VIP 歌曲(默认关 = 保持现状: VIP 曲目仍然尝试取链, 取决于账号是否会员).
  ///
  /// 跳的是"需要黑胶会员"的曲目(fee=1 ⇒ SongDto.vip), 不是无版权曲目
  /// (后者本来就由 `playable == false` 处理)。列表里仍会显示, 只是切歌/续播时跳过。
  bool get skipVipSongs => _snapshot.skipVipSongs;
  set skipVipSongs(bool value) =>
      _update(_snapshot.copyWith(skipVipSongs: value));

  /// 每日推荐歌单的本地缓存天数: 0 = 关闭, 3/7/30 = 保留天数.
  ///
  /// 缓存的是歌单列表本身(不含歌曲/凭据), 关掉后下次进推荐页就要联网拉。
  int get dailyCacheDays => _snapshot.dailyCacheDays;
  set dailyCacheDays(int value) =>
      _update(_snapshot.copyWith(dailyCacheDays: value));

  /// 是否允许生成匿名诊断数据(见 debug_report.dart).
  /// 默认 false; 打开后只在用户主动点「生成匿名诊断包」时产出文件, 不会自动上传。
  bool get anonymousDebug => _snapshot.anonymousDebug;
  set anonymousDebug(bool value) =>
      _update(_snapshot.copyWith(anonymousDebug: value));

  /// 播放队列面板的「左滑可以把歌曲从队列里移除」提示是否已被用户确认不再展示。
  ///
  /// 默认 false ⇒ 首次展开队列时弹一次(带「确认后不再展示」勾选)。
  /// 放在设置里而不是内存变量: 用户点过「不再展示」就该永久生效, 不该下次启动又弹。
  bool get queueSwipeHintDismissed => _snapshot.queueSwipeHintDismissed;
  set queueSwipeHintDismissed(bool value) =>
      _update(_snapshot.copyWith(queueSwipeHintDismissed: value));

  /// 详情页「歌词 ⇄ 封面」上次停在的那一面('lyrics' | 'cover', 默认歌词)。
  ///
  /// 用户 2026-11-19 口径: 切面要**记住**, 换歌也不回歌词; 播放条封面点击就是在
  /// 这两面之间来回切。取值白名单见 [detailFaces]: 未知值在读/写两侧都会被丢弃,
  /// 旧 settings.json 缺字段时保持默认 'lyrics'(无需迁移, 也不报错)。
  String get detailFace => _snapshot.detailFace;
  set detailFace(String value) {
    // 白名单外的值直接丢弃(写侧唯一校验点, 手工改坏 settings.json 也进不来)
    if (!detailFaces.contains(value)) return;
    _update(_snapshot.copyWith(detailFace: value));
  }

  /// [detailFace] 的合法取值(顺序 = 语义顺序)。
  static const List<String> detailFaces = <String>['lyrics', 'cover'];

  /// 封面/图片清晰度档位(见 [CoverQuality]). 默认 [CoverQuality.standard] = 按设备像素 1:1.
  ///
  /// 单独用 [ValueNotifier] 通知: 界面上封面可能有上百个, 不该让"音量滑块拖动"这类
  /// 高频 `notifyListeners()` 把所有图片都重建一遍。
  final ValueNotifier<CoverQuality> coverQualityListenable =
      ValueNotifier<CoverQuality>(CoverQuality.standard);

  CoverQuality get coverQuality => _snapshot.coverQuality;

  /// 写快照时同步 notifier([_update] 里做), 老的封面订阅点零改动。
  set coverQuality(CoverQuality value) =>
      _update(_snapshot.copyWith(coverQuality: value));

  // ---------------- 播放与外观(2026-11 任务书 docs/archive/plan-2026-11-09-settings-and-player.md) ----------------
  // 原则: 默认值一律等于"不改变现状", 老配置读进来行为不变.

  /// R6: 深色模式下用 OLED 纯黑(#000000)取代 Material 的 #121212
  bool get oledDark => _snapshot.oledDark;
  set oledDark(bool value) => _update(_snapshot.copyWith(oledDark: value));

  /// B7: 推荐页顶栏第一格「自定义」绑定的动作(默认排行榜)。
  CustomQuickAction get customQuickAction => _snapshot.customQuickAction;
  set customQuickAction(CustomQuickAction value) =>
      _update(_snapshot.copyWith(customQuickAction: value));

  /// R2: 播放器级精细音量增益(dB). 与系统音量相乘, 0 = 不变.
  /// 范围 -40..0, 步进 0.5; 0 dB 时完全旁路.
  double get volumeGainDb => _snapshot.volumeGainDb;
  set volumeGainDb(double value) =>
      _update(_snapshot.copyWith(volumeGainDb: value));

  /// R2b/R7: 响度均衡(EBU R128 测量 -> ReplayGain 2.0 语义的静态增益)
  bool get loudnessNormalize => _snapshot.loudnessNormalize;
  set loudnessNormalize(bool value) =>
      _update(_snapshot.copyWith(loudnessNormalize: value));

  /// 响度均衡目标电平(LUFS). 移动端常用 -16, 广播口径 -23.
  double get loudnessTargetLufs => _snapshot.loudnessTargetLufs;
  set loudnessTargetLufs(double value) =>
      _update(_snapshot.copyWith(loudnessTargetLufs: value));

  /// R7: 动态 AGC 模式(默认 false = 静态 ReplayGain, 无 pumping)
  bool get loudnessDynamic => _snapshot.loudnessDynamic;
  set loudnessDynamic(bool value) =>
      _update(_snapshot.copyWith(loudnessDynamic: value));

  /// R7: 生效的自定义响度曲线名(AutoEQ ParametricEQ.txt 导入时取文件名)
  String? get eqProfileName => _snapshot.eqProfileName;
  set eqProfileName(String? value) =>
      _update(_snapshot.copyWith(eqProfileName: value));

  /// R7: 曲线原文(AutoEQ ParametricEQ.txt / GraphicEQ.txt). null = 旁路
  String? get eqProfileText => _snapshot.eqProfileText;
  set eqProfileText(String? value) =>
      _update(_snapshot.copyWith(eqProfileText: value));

  /// R5: 淡入淡出时长(ms). 0 = 关闭
  int get fadeMs => _snapshot.fadeMs;
  set fadeMs(int value) => _update(_snapshot.copyWith(fadeMs: value));

  /// R5: 优先硬解(仅 Android; Linux 纯软解无此概念)
  bool get hardwareDecode => _snapshot.hardwareDecode;
  set hardwareDecode(bool value) =>
      _update(_snapshot.copyWith(hardwareDecode: value));

  /// R5: 边听边存(流式缓存落盘)
  bool get streamCache => _snapshot.streamCache;
  set streamCache(bool value) =>
      _update(_snapshot.copyWith(streamCache: value));

  /// R5: 缓存占用上限(MB)
  int get cacheLimitMb => _snapshot.cacheLimitMb;
  set cacheLimitMb(int value) =>
      _update(_snapshot.copyWith(cacheLimitMb: value));

  /// 歌词页是否显示翻译(tlyric). 只有歌词本身带翻译时该开关才出现.
  bool get lyricTranslation => _snapshot.lyricTranslation;
  set lyricTranslation(bool value) =>
      _update(_snapshot.copyWith(lyricTranslation: value));

  /// C2: 逐字歌词来源偏好. amll = 优先 TTML(默认; 人工审核逐字库, 质量最稳),
  /// auto = 打分择优, netease = 只用 yrc(缺失才 TTML).
  ///
  /// 2026-11-15 口径变更: 默认从 'auto' 改为 'amll'。旧 auto 有 0.9 短路,
  /// yrc 质量正常时直接采用、根本不请求 TTML, 实测 AMLL 只覆盖 12% 的播放
  /// (docs/api-notes-snapshot-20261119.md), 等于"逐字库没被用上"。
  String get lyricSourcePreference => _snapshot.lyricSourcePreference;
  set lyricSourcePreference(String value) =>
      _update(_snapshot.copyWith(lyricSourcePreference: value));

  /// 点关闭按钮时的行为(默认 [CloseBehavior.quit] = 保持旧语义).
  ///
  /// 只有 Linux 桌面会真的把设置推给 GTK runner(见 desktop_shell.dart);
  /// 其它平台保留字段(不撒谎: 设置页在那边的文案写明"仅 Linux 生效")。
  CloseBehavior get closeBehavior => _snapshot.closeBehavior;
  set closeBehavior(CloseBehavior value) =>
      _update(_snapshot.copyWith(closeBehavior: value));

  /// settings.json 结构版本(用于一次性迁移旧默认值)。
  static const int settingsSchemaVersion = 2;

  static const lyricSourceOptions = <String, String>{
    'amll': 'AMLL 优先',
    'auto': '自动择优',
    'netease': '网易云优先',
  };

  /// 各偏好的一句语义说明(设置页副标题).
  static String lyricSourceDescription(String pref) => switch (pref) {
    'netease' => '只用网易云 yrc, 缺失才用 AMLL TTML',
    'auto' => '给 yrc 与 AMLL 打分择优, yrc 质量高时不联网比较',
    _ => '默认: 优先 AMLL TTML 逐字(人工审核库), 缺失再用网易云 yrc',
  };

  // 注意: double 作 key 不能用 const map(Dart 常量 map 的 key 必须原始相等语义)
  static final loudnessTargets = <double, String>{
    -23.0: '-23 LUFS(广播)',
    -18.0: '-18 LUFS',
    -16.0: '-16 LUFS(推荐)',
    -14.0: '-14 LUFS(响亮)',
  };

  static const fadeOptions = <int, String>{
    0: '关闭',
    200: '200 ms',
    500: '500 ms',
    1000: '1 s',
  };

  static const cacheLimits = <int>[128, 256, 512, 1024, 2048];

  File? _file;
  bool _loaded = false;

  bool get loaded => _loaded;

  static const audioLevels = <String, String>{
    'standard': '标准',
    'higher': '较高',
    'exhigh': '极高',
    'lossless': '无损',
    'hires': 'Hi-Res',
  };

  /// 界面字号的可调区间(滑块两端)与步长。
  ///
  /// 下限 0.80 而不是更小: 再小正文会低于可读极限; 上限 1.50 与系统字号相乘后
  /// 仍在布局的 2.0 上限内(layout.dart 的 rowExtentFor 等按 ≤2 倍设计)。
  static const double kTextScaleMin = 0.80;
  static const double kTextScaleMax = 1.50;
  static const double kTextScaleStep = 0.05;

  /// 滑块的格数(0.80..1.50 / 0.05 = 14)
  static int get textScaleDivisions =>
      ((kTextScaleMax - kTextScaleMin) / kTextScaleStep).round();

  /// 展示文案: 一律给百分比(如「120%」)。以前命中「小/标准/大/特大」时给档位名,
  /// 但档位 chip 已移除, 再叫"标准"只会让用户以为还有别的档位。
  static String textScaleLabel(double scale) => '${(scale * 100).round()}%';

  /// 把任意倍率吸附到 [kTextScaleStep] 的格子上并夹到区间内(纯函数)。
  ///
  /// 用"乘 20 取整再除 20"而不是反复加 0.05: 后者会累积浮点误差
  /// (0.8 + 0.05 * 7 = 1.1500000000000001), 读回来与预设档位比对不上。
  static double snapTextScale(double value) {
    final clamped = value.clamp(kTextScaleMin, kTextScaleMax);
    final steps = ((clamped - kTextScaleMin) / kTextScaleStep).round();
    final snapped = kTextScaleMin + steps * kTextScaleStep;
    return (snapped * 100).round() / 100;
  }

  /// 设置页副标题: 当前百分比 + 一句"是否跟随系统"。
  static String textScaleHint(double scale) =>
      '${textScaleLabel(scale)} · 叠在系统字号之上(系统无障碍大字号仍然生效)';

  Future<void> load(String dataDir) async {
    _file = File('$dataDir/settings.json');
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString());
        if (raw is Map) {
          // 按域解析在 app_settings_codec.dart(part), 加设置项只改那一处 + _toJson。
          //
          // 静默应用: 读盘期间不能让订阅者看到"半份配置"(旧的 settle 循环也一样),
          // 读完整份后由下面那一次 notifyListeners 统一通知(全体 + 全领域)。
          _quiet(() => applyStoredJson(raw));
        }
      }
    } catch (_) {
      // 配置读不出来(半截文件/手工改坏/盘满): 用默认值不阻塞启动, 但把坏文件
      // 改名留存 —— 否则下一次 _save() 会把它覆盖掉, 用户的所有偏好就永久丢了,
      // 而且没有任何证据可查。
      try {
        final file = _file;
        if (file != null && await file.exists()) {
          final bad = File('${file.path}.bad');
          if (await bad.exists()) await bad.delete();
          await file.rename(bad.path);
        }
      } catch (_) {
        // 保留坏文件失败也不影响启动
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> update({
    ThemeMode? themeMode,
    AccentPalette? accent,
    double? textScale,
    String? audioLevel,
    int? coverRows,
    int? gridColumns,
    bool? clearSearchOnTabSwitch,
    bool? showHotSearch,
    bool? skipVipSongs,
    int? dailyCacheDays,
    bool? anonymousDebug,
    bool? queueSwipeHintDismissed,
    String? detailFace,
    CoverQuality? coverQuality,
    bool? oledDark,
    double? volumeGainDb,
    bool? loudnessNormalize,
    double? loudnessTargetLufs,
    bool? loudnessDynamic,
    String? eqProfileName,
    String? eqProfileText,
    int? fadeMs,
    bool? hardwareDecode,
    bool? streamCache,
    int? cacheLimitMb,
    bool? lyricTranslation,
    String? lyricSourcePreference,
    UpdateCheckInterval? updateCheckInterval,
    LibrarySearchPlayAction? librarySearchPlayAction,
    CloseBehavior? closeBehavior,
  }) async {
    // 一次 update() 可能改多个域: 批量窗口保证只发一次通知(域集合是并集)。
    _beginBatch();
    try {
      _applyUpdateArgs(
        themeMode: themeMode,
        accent: accent,
        textScale: textScale,
        audioLevel: audioLevel,
        coverRows: coverRows,
        gridColumns: gridColumns,
        clearSearchOnTabSwitch: clearSearchOnTabSwitch,
        showHotSearch: showHotSearch,
        skipVipSongs: skipVipSongs,
        dailyCacheDays: dailyCacheDays,
        anonymousDebug: anonymousDebug,
        queueSwipeHintDismissed: queueSwipeHintDismissed,
        detailFace: detailFace,
        coverQuality: coverQuality,
        oledDark: oledDark,
        volumeGainDb: volumeGainDb,
        loudnessNormalize: loudnessNormalize,
        loudnessTargetLufs: loudnessTargetLufs,
        loudnessDynamic: loudnessDynamic,
        eqProfileName: eqProfileName,
        eqProfileText: eqProfileText,
        fadeMs: fadeMs,
        hardwareDecode: hardwareDecode,
        streamCache: streamCache,
        cacheLimitMb: cacheLimitMb,
        lyricTranslation: lyricTranslation,
        lyricSourcePreference: lyricSourcePreference,
        updateCheckInterval: updateCheckInterval,
        librarySearchPlayAction: librarySearchPlayAction,
        closeBehavior: closeBehavior,
      );
    } finally {
      _endBatch();
    }
    await _save();
  }

  /// [update] 的写入口: 校验/夹取口径全部保持改造前的样子(读侧与这里两处)。
  void _applyUpdateArgs({
    ThemeMode? themeMode,
    AccentPalette? accent,
    double? textScale,
    String? audioLevel,
    int? coverRows,
    int? gridColumns,
    bool? clearSearchOnTabSwitch,
    bool? showHotSearch,
    bool? skipVipSongs,
    int? dailyCacheDays,
    bool? anonymousDebug,
    bool? queueSwipeHintDismissed,
    String? detailFace,
    CoverQuality? coverQuality,
    bool? oledDark,
    double? volumeGainDb,
    bool? loudnessNormalize,
    double? loudnessTargetLufs,
    bool? loudnessDynamic,
    String? eqProfileName,
    String? eqProfileText,
    int? fadeMs,
    bool? hardwareDecode,
    bool? streamCache,
    int? cacheLimitMb,
    bool? lyricTranslation,
    String? lyricSourcePreference,
    UpdateCheckInterval? updateCheckInterval,
    LibrarySearchPlayAction? librarySearchPlayAction,
    CloseBehavior? closeBehavior,
  }) {
    if (closeBehavior != null) this.closeBehavior = closeBehavior;
    if (librarySearchPlayAction != null) {
      this.librarySearchPlayAction = librarySearchPlayAction;
    }
    if (updateCheckInterval != null) {
      this.updateCheckInterval = updateCheckInterval;
    }
    if (themeMode != null) this.themeMode = themeMode;
    if (accent != null) this.accent = accent;
    if (textScale != null) this.textScale = snapTextScale(textScale);
    if (audioLevel != null && audioLevels.containsKey(audioLevel)) {
      this.audioLevel = audioLevel;
    }
    if (coverRows != null && (coverRows == 1 || coverRows == 2)) {
      this.coverRows = coverRows;
    }
    if (gridColumns != null && gridColumns >= 2 && gridColumns <= 4) {
      this.gridColumns = gridColumns;
    }
    if (clearSearchOnTabSwitch != null) {
      this.clearSearchOnTabSwitch = clearSearchOnTabSwitch;
    }
    if (showHotSearch != null) this.showHotSearch = showHotSearch;
    if (skipVipSongs != null) this.skipVipSongs = skipVipSongs;
    if (dailyCacheDays != null && dailyCacheOptions.contains(dailyCacheDays)) {
      this.dailyCacheDays = dailyCacheDays;
    }
    if (anonymousDebug != null) this.anonymousDebug = anonymousDebug;
    if (queueSwipeHintDismissed != null) {
      this.queueSwipeHintDismissed = queueSwipeHintDismissed;
    }
    if (detailFace != null && detailFaces.contains(detailFace)) {
      this.detailFace = detailFace;
    }
    if (coverQuality != null) this.coverQuality = coverQuality;
    if (oledDark != null) this.oledDark = oledDark;
    if (volumeGainDb != null) {
      this.volumeGainDb = volumeGainDb.clamp(-40.0, 0.0);
    }
    if (loudnessNormalize != null) this.loudnessNormalize = loudnessNormalize;
    if (loudnessTargetLufs != null) {
      this.loudnessTargetLufs = loudnessTargetLufs.clamp(-30.0, -5.0);
    }
    if (loudnessDynamic != null) this.loudnessDynamic = loudnessDynamic;
    if (eqProfileName != null) this.eqProfileName = eqProfileName;
    if (eqProfileText != null) this.eqProfileText = eqProfileText;
    if (fadeMs != null && fadeOptions.containsKey(fadeMs)) this.fadeMs = fadeMs;
    if (hardwareDecode != null) this.hardwareDecode = hardwareDecode;
    if (streamCache != null) this.streamCache = streamCache;
    if (cacheLimitMb != null && cacheLimits.contains(cacheLimitMb)) {
      this.cacheLimitMb = cacheLimitMb;
    }
    if (lyricTranslation != null) this.lyricTranslation = lyricTranslation;
    if (lyricSourcePreference != null &&
        lyricSourceOptions.containsKey(lyricSourcePreference)) {
      this.lyricSourcePreference = lyricSourcePreference;
    }
  }

  /// 正在进行的落盘(串行化用, 见 [_save])
  Future<void>? _saving;

  /// 落盘: **串行 + 原子替换**。
  ///
  /// 为什么必须串行: 每次 [update]/[touchInteraction] 都会整份重写 settings.json,
  /// 而 `writeAsString` 是"先 truncate 再写"。两次写并发时后一个的 truncate 会插在
  /// 前一个还没写完的位置, 结果是一个**空/半截文件**; 下次启动 jsonDecode 直接抛错,
  /// 所有偏好静默回到默认值(用户看到的"字号没有记忆"就是这么来的)。
  ///
  /// 为什么必须原子: 写临时文件再 rename, 任何时刻磁盘上都有一份完整可解析的
  /// settings.json(rename 在同一目录内是原子的), 进程被杀也不会留下半截文件。
  Future<void> _save() {
    // 还没 load() 过(设置文件路径未知)时直接返回: 以前这里会顺手串到
    // "上一个落盘任务"上, 而那个 Future 可能属于**已经结束的 zone**(widget 测试
    // 每条用例一个 FakeAsync zone), 于是 await 永远不回来 —— 表现为整页用例卡死。
    if (_file == null) return Future<void>.value();
    final next = (_saving ?? Future<void>.value()).then(
      (_) => _writeSettings(),
    );
    _saving = next;
    return next;
  }

  Future<void> _writeSettings() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        // Windows 上 rename 不能覆盖已存在的文件: 退化成"删旧再改名"。
        // (移动端/桌面的主路径是上一行的原子 rename)
        if (await file.exists()) await file.delete();
        await tmp.rename(file.path);
      }
    } catch (_) {
      // 落盘失败只影响下次启动, 当前会话仍生效
    }
  }

  /// 每日推荐歌单缓存的可选天数(0 = 关闭)。
  /// 放在 AppSettings 里而不是缓存模块里: 设置页与缓存模块都要用同一组口径。
  static const List<int> dailyCacheOptions = [0, 3, 7, 30];

  static String dailyCacheLabel(int days) => days <= 0 ? '关闭' : '保留 $days 天';

  static String _themeName(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };

  static ThemeMode _themeFrom(Object? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  // ---------------- 自动更新检查(2026-11) ----------------

  /// 歌单内搜索后点歌: 默认切回完整列表(不会只播筛出来的几首)
  LibrarySearchPlayAction get librarySearchPlayAction =>
      _snapshot.librarySearchPlayAction;
  set librarySearchPlayAction(LibrarySearchPlayAction value) =>
      _update(_snapshot.copyWith(librarySearchPlayAction: value));

  /// 自动检查更新频率(默认每天; off 时仍可手动「检查更新」)
  UpdateCheckInterval get updateCheckInterval => _snapshot.updateCheckInterval;
  set updateCheckInterval(UpdateCheckInterval value) =>
      _update(_snapshot.copyWith(updateCheckInterval: value));

  /// 上次启动检查的 epoch ms(按 [updateCheckInterval] 的周期节流; 手动检查不写)
  int? get lastUpdateCheckMs => _snapshot.lastUpdateCheckMs;
  set lastUpdateCheckMs(int? value) =>
      _update(_snapshot.copyWith(lastUpdateCheckMs: value));

  /// 用户点「稍后」跳过的版本 tag, 启动静默检查不再提示该版本
  String? get skippedUpdateVersion => _snapshot.skippedUpdateVersion;
  set skippedUpdateVersion(String? value) =>
      _update(_snapshot.copyWith(skippedUpdateVersion: value));

  // ---------------- 最近交互记录(2026-11「我的」页按最近交互排序) ----------------

  /// 各类条目("打开/播放")最近一次交互的时间戳(epoch ms).
  ///
  /// key 形如 `album:123` / `podcast:45` / `playlist:67`; 只存在 settings.json
  /// 的 `interactions` 字段里 —— 排序是纯本地偏好, 不必新开文件/新依赖。
  ///
  /// 只读视图; 写记录产出**新 map**(老快照不会跟着变), 见 [touchInteraction]。
  Map<String, int> get _interactions => _snapshot.interactions;

  /// 记录条数上限: 超出丢最旧的, 防止 settings.json 长年累加无限变长。
  static const int interactionLimit = 200;

  static String _interactionKey(String kind, BigInt id) => '$kind:$id';

  /// 最近一次"打开/播放"某类条目的时间(epoch ms); 无记录返回 null。
  int? lastInteractionMs(String kind, BigInt id) =>
      _interactions[_interactionKey(kind, id)];

  /// 记录一次"打开/播放", 落盘并通知监听者(「我的」页据此重排区块与条目)。
  ///
  /// [nowMs] 仅供测试注入, 生产路径用当前时间。
  Future<void> touchInteraction(String kind, BigInt id, {int? nowMs}) async {
    // copy-on-write: 老快照持有的是旧 map, 不会被这次记录改到(§12.6 快照语义)。
    final next = <String, int>{
      ..._interactions,
      _interactionKey(kind, id): nowMs ?? DateTime.now().millisecondsSinceEpoch,
    };
    if (next.length > interactionLimit) {
      // 丢最旧: 按时间升序删到上限。量级只有 200, 排一次不心疼。
      final byAge = next.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final e in byAge.take(next.length - interactionLimit)) {
        next.remove(e.key);
      }
    }
    // 只改交互记录域: 通知按域分发(外观/播放域的订阅者不会被惊动)。
    _update(_snapshot.copyWith(interactions: next));
    await _save();
  }

  void recordUpdateCheck(int nowMs) {
    // 节流记录走独立小落盘, 不通知监听者(避免无谓全页重建, 与改造前一致)
    _quiet(() => lastUpdateCheckMs = nowMs);
    _persist();
  }

  /// 「稍后」: 记住该版本, 启动检查不再提示
  void skipUpdate(String versionTag) {
    _quiet(() => skippedUpdateVersion = versionTag);
    _persist();
  }

  Future<void> _persist() => _save();

  static double _doubleOf(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;
}

/// 自动更新检查频率(2026-11 用户要求: 默认每天检查; 可关/每周/每月)。
/// [period] 为 null 表示不自动检查(手动「检查更新」仍然可用)。
enum UpdateCheckInterval {
  off('不自动检查', '只在你点「检查更新」时联网'),
  daily('每天', '启动后静默检查一次, 发现新版本弹窗提示'),
  weekly('每周', '每周最多检查一次'),
  monthly('每月', '每月最多检查一次');

  const UpdateCheckInterval(this.label, this.hint);

  final String label;
  final String hint;

  Duration? get period => switch (this) {
    off => null,
    daily => const Duration(days: 1),
    weekly => const Duration(days: 7),
    monthly => const Duration(days: 30),
  };
}

/// 歌单/专辑详情里"筛选本页曲目"后点歌的行为。
enum LibrarySearchPlayAction {
  fullList('切到完整列表', '按整个歌单重建播放队列, 从目标歌曲开始'),
  appendCurrent('只添加当前歌', '保留现有播放队列, 把这歌加到队列末尾');

  const LibrarySearchPlayAction(this.label, this.hint);

  final String label;
  final String hint;
}

/// 让 MaterialApp 跟随 AppSettings 重建(主题/字号即时生效)。
///
/// 订阅的是**全体**通知(旧的兼容入口); 新代码请用 [AppSettingsScopedBuilder],
/// 只订阅自己真正要用的域, 否则音量滑块这类高频写入还是会把整棵树带上。
class SettingsScope extends StatelessWidget {
  const SettingsScope({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) => builder(context),
    );
  }
}

/// 只在 [domains] 里的设置域真的变化时重建(§12.6 第二步的消费侧入口)。
///
/// 与 `AnimatedBuilder(animation: AppSettings.instance)` 的区别: 后者订阅全体通知,
/// 音量滑块每拖一格都会重建整个 MaterialApp(主题/字号/全树); 这里只收自己那一域。
class AppSettingsScopedBuilder extends StatefulWidget {
  const AppSettingsScopedBuilder({
    super.key,
    required this.domains,
    required this.builder,
  });

  /// 关心的设置域(空集合会被断言拦下: 那就等于不订阅)。
  final Set<AppSettingsDomain> domains;

  final WidgetBuilder builder;

  @override
  State<AppSettingsScopedBuilder> createState() =>
      _AppSettingsScopedBuilderState();
}

class _AppSettingsScopedBuilderState extends State<AppSettingsScopedBuilder> {
  /// tear-off 存成字段: remove/listener 用同一个引用, 不多不少。
  late final VoidCallback _listener = _onSettingsChanged;

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addScopedListener(widget.domains, _listener);
  }

  @override
  void didUpdateWidget(AppSettingsScopedBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.domains, widget.domains)) {
      AppSettings.instance.removeScopedListener(_listener);
      AppSettings.instance.addScopedListener(widget.domains, _listener);
    }
  }

  @override
  void dispose() {
    AppSettings.instance.removeScopedListener(_listener);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// 把用户选择的字号叠到系统字号上(系统无障碍设置仍然生效).
/// TextScaler 没有公开的"组合"API, 这里用 1sp 上的实际倍率相乘,
/// 对线性系统字号是精确的, 对非线性字号是合理近似.
MediaQueryData scaledMediaQuery(BuildContext context, double scale) {
  final data = MediaQuery.of(context);
  final base = data.textScaler.scale(1);
  return data.copyWith(textScaler: TextScaler.linear(base * scale));
}
