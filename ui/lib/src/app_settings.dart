import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'theme.dart' show AccentPalette;

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

class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  ThemeMode themeMode = ThemeMode.system;

  /// 视觉风格(主题色). 默认网易云红 = 与改造前完全一致; 浅色/深色共用同一个色板。
  AccentPalette accent = AccentPalette.neteaseRed;

  /// 1.0 = 跟随系统; 0.85/1.15/1.3 = 小/大/特大
  double textScale = 1.0;

  /// ncm-provider 的音质字符串: standard / higher / exhigh / lossless / hires
  String audioLevel = 'exhigh';

  /// 推荐页歌单/播客卡片每屏展示几排(1 排 = 横向滑动, 2 排 = 网格)
  int coverRows = 1;

  /// 切回"搜索"底部 tab 时是否丢弃上一次的输入/结果(默认丢弃, 避免残留)
  bool clearSearchOnTabSwitch = true;

  /// 搜索页是否展示「热门搜索」榜(默认展示; 关闭后只留历史与猜你想搜)
  bool showHotSearch = true;

  /// 封面/图片清晰度档位(见 [CoverQuality]). 默认 [CoverQuality.standard] = 按设备像素 1:1.
  ///
  /// 单独用 [ValueNotifier] 通知: 界面上封面可能有上百个, 不该让"音量滑块拖动"这类
  /// 高频 `notifyListeners()` 把所有图片都重建一遍。
  final ValueNotifier<CoverQuality> coverQualityListenable =
      ValueNotifier<CoverQuality>(CoverQuality.standard);

  CoverQuality get coverQuality => coverQualityListenable.value;

  set coverQuality(CoverQuality value) {
    if (coverQualityListenable.value != value) {
      coverQualityListenable.value = value;
    }
  }

  // ---------------- 播放与外观(2026-11 任务书 docs/plan-2026-11-09-settings-and-player.md) ----------------
  // 原则: 默认值一律等于"不改变现状", 老配置读进来行为不变.

  /// R6: 深色模式下用 OLED 纯黑(#000000)取代 Material 的 #121212
  bool oledDark = false;

  /// R2: 播放器级精细音量增益(dB). 与系统音量相乘, 0 = 不变.
  /// 范围 -40..0, 步进 0.5; 0 dB 时完全旁路.
  double volumeGainDb = 0.0;

  /// R2b/R7: 响度均衡(EBU R128 测量 -> ReplayGain 2.0 语义的静态增益)
  bool loudnessNormalize = false;

  /// 响度均衡目标电平(LUFS). 移动端常用 -16, 广播口径 -23.
  double loudnessTargetLufs = -16.0;

  /// R7: 动态 AGC 模式(默认 false = 静态 ReplayGain, 无 pumping)
  bool loudnessDynamic = false;

  /// R7: 生效的自定义响度曲线名(AutoEQ ParametricEQ.txt 导入时取文件名)
  String? eqProfileName;

  /// R7: 曲线原文(AutoEQ ParametricEQ.txt / GraphicEQ.txt). null = 旁路
  String? eqProfileText;

  /// R5: 淡入淡出时长(ms). 0 = 关闭
  int fadeMs = 0;

  /// R5: 优先硬解(仅 Android; Linux 纯软解无此概念)
  bool hardwareDecode = true;

  /// R5: 边听边存(流式缓存落盘)
  bool streamCache = true;

  /// R5: 缓存占用上限(MB)
  int cacheLimitMb = 512;

  /// 歌词页是否显示翻译(tlyric). 只有歌词本身带翻译时该开关才出现.
  bool lyricTranslation = true;

  /// C2: 逐字歌词来源偏好. auto = 打分择优(默认), netease = 只用 yrc(缺失才 TTML),
  /// amll = 优先 TTML(失败再 yrc).
  String lyricSourcePreference = 'auto';

  static const lyricSourceOptions = <String, String>{
    'auto': '自动择优',
    'netease': '网易云优先',
    'amll': 'AMLL 优先',
  };

  /// 各偏好的一句语义说明(设置页副标题).
  static String lyricSourceDescription(String pref) => switch (pref) {
    'netease' => '只用网易云 yrc, 缺失才用 AMLL TTML',
    'amll' => '优先 AMLL TTML, 失败再用网易云 yrc',
    _ => '给 yrc 与 AMLL 打分择优, yrc 质量高时不联网比较',
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

  static final textScales = <double, String>{
    0.85: '小',
    1.0: '标准',
    1.15: '大',
    1.3: '特大',
  };

  Future<void> load(String dataDir) async {
    _file = File('$dataDir/settings.json');
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString());
        if (raw is Map) {
          themeMode = _themeFrom(raw['themeMode']);
          accent = AccentPalette.fromId(raw['accent'] as String?);
          textScale = _doubleOf(raw['textScale'], 1.0).clamp(0.8, 1.5);
          final level = raw['audioLevel'];
          if (level is String && audioLevels.containsKey(level)) {
            audioLevel = level;
          }
          final rows = raw['coverRows'];
          if (rows is num && (rows.toInt() == 1 || rows.toInt() == 2)) {
            coverRows = rows.toInt();
          }
          final clearOnSwitch = raw['clearSearchOnTabSwitch'];
          if (clearOnSwitch is bool) clearSearchOnTabSwitch = clearOnSwitch;
          final hotSearch = raw['showHotSearch'];
          if (hotSearch is bool) showHotSearch = hotSearch;
          final coverQualityRaw = raw['coverQuality'];
          if (coverQualityRaw is String) {
            coverQuality = CoverQualityX.fromId(coverQualityRaw);
          }

          if (raw['oledDark'] is bool) oledDark = raw['oledDark'] as bool;
          volumeGainDb = _doubleOf(raw['volumeGainDb'], 0.0).clamp(-40.0, 0.0);
          if (raw['loudnessNormalize'] is bool) {
            loudnessNormalize = raw['loudnessNormalize'] as bool;
          }
          loudnessTargetLufs = _doubleOf(
            raw['loudnessTargetLufs'],
            -16.0,
          ).clamp(-30.0, -5.0);
          if (raw['loudnessDynamic'] is bool) {
            loudnessDynamic = raw['loudnessDynamic'] as bool;
          }
          final eqName = raw['eqProfileName'];
          if (eqName is String && eqName.isNotEmpty) eqProfileName = eqName;
          final eqText = raw['eqProfileText'];
          if (eqText is String && eqText.trim().isNotEmpty) {
            eqProfileText = eqText;
          }
          final fade = raw['fadeMs'];
          if (fade is num && fadeOptions.containsKey(fade.toInt())) {
            fadeMs = fade.toInt();
          }
          if (raw['hardwareDecode'] is bool) {
            hardwareDecode = raw['hardwareDecode'] as bool;
          }
          if (raw['streamCache'] is bool) {
            streamCache = raw['streamCache'] as bool;
          }
          final limit = raw['cacheLimitMb'];
          if (limit is num && cacheLimits.contains(limit.toInt())) {
            cacheLimitMb = limit.toInt();
          }
          final trans = raw['lyricTranslation'];
          if (trans is bool) lyricTranslation = trans;
          final srcPref = raw['lyricSourcePreference'];
          if (srcPref is String && lyricSourceOptions.containsKey(srcPref)) {
            lyricSourcePreference = srcPref;
          }
          // 自动更新检查(2026-11): 频率 + 节流/跳过记录
          // 兼容旧版布尔开关: true -> 每天, false -> 不自动检查。
          final playRaw = raw['librarySearchPlayAction'];
          if (playRaw is String) {
            librarySearchPlayAction = LibrarySearchPlayAction.values.firstWhere(
              (v) => v.name == playRaw,
              orElse: () => LibrarySearchPlayAction.fullList,
            );
          }
          final intervalRaw = raw['updateCheckInterval'];
          if (intervalRaw is String) {
            updateCheckInterval = UpdateCheckInterval.values.firstWhere(
              (v) => v.name == intervalRaw,
              orElse: () => UpdateCheckInterval.daily,
            );
          } else if (raw['updateCheckOnStartup'] is bool) {
            updateCheckInterval = raw['updateCheckOnStartup'] as bool
                ? UpdateCheckInterval.daily
                : UpdateCheckInterval.off;
          }
          if (raw['lastUpdateCheckMs'] is int) {
            lastUpdateCheckMs = raw['lastUpdateCheckMs'] as int;
          }
          final skipped = raw['skippedUpdateVersion'];
          if (skipped is String && skipped.isNotEmpty) {
            skippedUpdateVersion = skipped;
          }
        }
      }
    } catch (_) {
      // 配置损坏就用默认值, 不阻塞启动
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
    bool? clearSearchOnTabSwitch,
    bool? showHotSearch,
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
  }) async {
    if (librarySearchPlayAction != null) {
      this.librarySearchPlayAction = librarySearchPlayAction;
    }
    if (updateCheckInterval != null) {
      this.updateCheckInterval = updateCheckInterval;
    }
    if (themeMode != null) this.themeMode = themeMode;
    if (accent != null) this.accent = accent;
    if (textScale != null) this.textScale = textScale.clamp(0.8, 1.5);
    if (audioLevel != null && audioLevels.containsKey(audioLevel)) {
      this.audioLevel = audioLevel;
    }
    if (coverRows != null && (coverRows == 1 || coverRows == 2)) {
      this.coverRows = coverRows;
    }
    if (clearSearchOnTabSwitch != null) {
      this.clearSearchOnTabSwitch = clearSearchOnTabSwitch;
    }
    if (showHotSearch != null) this.showHotSearch = showHotSearch;
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
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'themeMode': _themeName(themeMode),
          'accent': accent.id,
          'textScale': textScale,
          'audioLevel': audioLevel,
          'coverRows': coverRows,
          'clearSearchOnTabSwitch': clearSearchOnTabSwitch,
          'showHotSearch': showHotSearch,
          'coverQuality': coverQuality.id,
          'oledDark': oledDark,
          'volumeGainDb': volumeGainDb,
          'loudnessNormalize': loudnessNormalize,
          'loudnessTargetLufs': loudnessTargetLufs,
          'loudnessDynamic': loudnessDynamic,
          'eqProfileName': eqProfileName,
          'eqProfileText': eqProfileText,
          'fadeMs': fadeMs,
          'hardwareDecode': hardwareDecode,
          'streamCache': streamCache,
          'cacheLimitMb': cacheLimitMb,
          'lyricTranslation': lyricTranslation,
          'lyricSourcePreference': lyricSourcePreference,
          'updateCheckInterval': updateCheckInterval.name,
          'librarySearchPlayAction': librarySearchPlayAction.name,
          'lastUpdateCheckMs': lastUpdateCheckMs,
          'skippedUpdateVersion': skippedUpdateVersion,
        }),
      );
    } catch (_) {
      // 落盘失败只影响下次启动, 当前会话仍生效
    }
  }

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
  LibrarySearchPlayAction librarySearchPlayAction =
      LibrarySearchPlayAction.fullList;

  /// 自动检查更新频率(默认每天; off 时仍可手动「检查更新」)
  UpdateCheckInterval updateCheckInterval = UpdateCheckInterval.daily;

  /// 上次启动检查的 epoch ms(按 [updateCheckInterval] 的周期节流; 手动检查不写)
  int? lastUpdateCheckMs;

  /// 用户点「稍后」跳过的版本 tag, 启动静默检查不再提示该版本
  String? skippedUpdateVersion;

  void recordUpdateCheck(int nowMs) {
    lastUpdateCheckMs = nowMs;
    // 节流记录走独立小落盘, 不 notifyListeners(避免无谓全页重建)
    _persist();
  }

  /// 「稍后」: 记住该版本, 启动检查不再提示
  void skipUpdate(String versionTag) {
    skippedUpdateVersion = versionTag;
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

/// 让 MaterialApp 跟随 AppSettings 重建(主题/字号即时生效)
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

/// 把用户选择的字号叠到系统字号上(系统无障碍设置仍然生效).
/// TextScaler 没有公开的"组合"API, 这里用 1sp 上的实际倍率相乘,
/// 对线性系统字号是精确的, 对非线性字号是合理近似.
MediaQueryData scaledMediaQuery(BuildContext context, double scale) {
  final data = MediaQuery.of(context);
  final base = data.textScaler.scale(1);
  return data.copyWith(textScaler: TextScaler.linear(base * scale));
}
