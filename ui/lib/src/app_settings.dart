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

  /// 界面字号倍率(叠在系统字号之上)。1.0 = 跟随系统。
  ///
  /// 只有一个入口: 设置页滑块 [kTextScaleMin]..[kTextScaleMax] 步长 [kTextScaleStep],
  /// 永远落在 0.05 的格子上(见 [snapTextScale])。2026-11-14 用户反馈: 滑块已经够用,
  /// 「小/标准/大/特大」档位 chip 是重复的第二套入口, 已移除。
  double textScale = 1.0;

  /// ncm-provider 的音质字符串: standard / higher / exhigh / lossless / hires
  String audioLevel = 'exhigh';

  /// 推荐页歌单/播客卡片每屏展示几排(1 排 = 横向滑动, 2 排 = 网格)
  int coverRows = 1;

  /// 方格网格(艺人专辑 / 新碟 / 歌单广场)每行列数, 2-4。
  ///
  /// 之前用 maxCrossAxisExtent 拍死列宽: 列数随屏幕漂移、格子末端留白。
  /// 改为显式列数 + 均分(见 [coverGridDelegate])。
  int gridColumns = 3;

  /// 切回"搜索"底部 tab 时是否丢弃上一次的输入/结果(默认丢弃, 避免残留)
  bool clearSearchOnTabSwitch = true;

  /// 搜索页是否展示「热门搜索」榜(默认展示; 关闭后只留历史与猜你想搜)
  bool showHotSearch = true;

  /// 播放时跳过 VIP 歌曲(默认关 = 保持现状: VIP 曲目仍然尝试取链, 取决于账号是否会员).
  ///
  /// 跳的是"需要黑胶会员"的曲目(fee=1 ⇒ SongDto.vip), 不是无版权曲目
  /// (后者本来就由 `playable == false` 处理)。列表里仍会显示, 只是切歌/续播时跳过。
  bool skipVipSongs = false;

  /// 每日推荐歌单的本地缓存天数: 0 = 关闭, 3/7/30 = 保留天数.
  ///
  /// 缓存的是歌单列表本身(不含歌曲/凭据), 关掉后下次进推荐页就要联网拉。
  int dailyCacheDays = 7;

  /// 是否允许生成匿名诊断数据(见 debug_report.dart).
  /// 默认 false; 打开后只在用户主动点「生成匿名诊断包」时产出文件, 不会自动上传。
  bool anonymousDebug = false;

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
          themeMode = _themeFrom(raw['themeMode']);
          accent = AccentPalette.fromId(raw['accent'] as String?);
          textScale = snapTextScale(_doubleOf(raw['textScale'], 1.0));
          final level = raw['audioLevel'];
          if (level is String && audioLevels.containsKey(level)) {
            audioLevel = level;
          }
          final rows = raw['coverRows'];
          if (rows is num && (rows.toInt() == 1 || rows.toInt() == 2)) {
            coverRows = rows.toInt();
          }
          final cols = raw['gridColumns'];
          if (cols is num && cols.toInt() >= 2 && cols.toInt() <= 4) {
            gridColumns = cols.toInt();
          }
          final clearOnSwitch = raw['clearSearchOnTabSwitch'];
          if (clearOnSwitch is bool) clearSearchOnTabSwitch = clearOnSwitch;
          final hotSearch = raw['showHotSearch'];
          if (hotSearch is bool) showHotSearch = hotSearch;
          final skipVip = raw['skipVipSongs'];
          if (skipVip is bool) skipVipSongs = skipVip;
          final cacheDays = raw['dailyCacheDays'];
          if (cacheDays is num &&
              dailyCacheOptions.contains(cacheDays.toInt())) {
            dailyCacheDays = cacheDays.toInt();
          }
          final anonDebug = raw['anonymousDebug'];
          if (anonDebug is bool) anonymousDebug = anonDebug;
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
          // 交互记录: 旧配置没有这个字段 ⇒ 保持空 map, 不报错。
          // 先清空再读, 让 load() 幂等(重复 load 不叠加旧的会话内记录)
          _interactions.clear();
          final interactions = raw['interactions'];
          if (interactions is Map) {
            for (final entry in interactions.entries) {
              final key = entry.key;
              final value = entry.value;
              if (key is String && value is int) _interactions[key] = value;
            }
          }
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
      await tmp.writeAsString(
        jsonEncode({
          'themeMode': _themeName(themeMode),
          'accent': accent.id,
          'textScale': textScale,
          'audioLevel': audioLevel,
          'coverRows': coverRows,
          'gridColumns': gridColumns,
          'clearSearchOnTabSwitch': clearSearchOnTabSwitch,
          'showHotSearch': showHotSearch,
          'skipVipSongs': skipVipSongs,
          'dailyCacheDays': dailyCacheDays,
          'anonymousDebug': anonymousDebug,
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
          'interactions': _interactions,
        }),
        flush: true,
      );
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
  LibrarySearchPlayAction librarySearchPlayAction =
      LibrarySearchPlayAction.fullList;

  /// 自动检查更新频率(默认每天; off 时仍可手动「检查更新」)
  UpdateCheckInterval updateCheckInterval = UpdateCheckInterval.daily;

  /// 上次启动检查的 epoch ms(按 [updateCheckInterval] 的周期节流; 手动检查不写)
  int? lastUpdateCheckMs;

  /// 用户点「稍后」跳过的版本 tag, 启动静默检查不再提示该版本
  String? skippedUpdateVersion;

  // ---------------- 最近交互记录(2026-11「我的」页按最近交互排序) ----------------

  /// 各类条目("打开/播放")最近一次交互的时间戳(epoch ms).
  ///
  /// key 形如 `album:123` / `podcast:45` / `playlist:67`; 只存在 settings.json
  /// 的 `interactions` 字段里 —— 排序是纯本地偏好, 不必新开文件/新依赖。
  final Map<String, int> _interactions = <String, int>{};

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
    _interactions[_interactionKey(kind, id)] =
        nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (_interactions.length > interactionLimit) {
      // 丢最旧: 按时间升序删到上限。量级只有 200, 排一次不心疼。
      final byAge = _interactions.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final e in byAge.take(_interactions.length - interactionLimit)) {
        _interactions.remove(e.key);
      }
    }
    notifyListeners();
    await _save();
  }

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
