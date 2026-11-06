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
