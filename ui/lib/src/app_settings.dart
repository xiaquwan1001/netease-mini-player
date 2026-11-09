import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// 全局 UI/播放偏好. 只存轻量 JSON, 放在 Rust 用的同一个 dataDir 下,
/// 双端(Android/Linux)都不依赖平台插件.
///
/// 设置项刻意保持"少而稳定": 主题模式、界面字号、取链音质。
/// 账号/凭据不在这里(由 Rust 的 identity.json + 账号簿负责)。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  ThemeMode themeMode = ThemeMode.system;

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

          if (raw['oledDark'] is bool) oledDark = raw['oledDark'] as bool;
          volumeGainDb = _doubleOf(raw['volumeGainDb'], 0.0).clamp(-40.0, 0.0);
          if (raw['loudnessNormalize'] is bool) {
            loudnessNormalize = raw['loudnessNormalize'] as bool;
          }
          loudnessTargetLufs =
              _doubleOf(raw['loudnessTargetLufs'], -16.0).clamp(-30.0, -5.0);
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
          if (raw['streamCache'] is bool) streamCache = raw['streamCache'] as bool;
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
    double? textScale,
    String? audioLevel,
    int? coverRows,
    bool? clearSearchOnTabSwitch,
    bool? showHotSearch,
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
  }) async {
    if (themeMode != null) this.themeMode = themeMode;
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
      await file.writeAsString(jsonEncode({
        'themeMode': _themeName(themeMode),
        'textScale': textScale,
        'audioLevel': audioLevel,
        'coverRows': coverRows,
        'clearSearchOnTabSwitch': clearSearchOnTabSwitch,
        'showHotSearch': showHotSearch,
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
      }));
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

  static double _doubleOf(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;
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
