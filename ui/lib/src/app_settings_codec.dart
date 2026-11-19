part of 'app_settings.dart';

// settings.json 的**编解码唯一落点**(AppSettings 的 part)。
//
// 为什么单独一个文件(§12.6 结构性债务, 2026-11-18): 以前"加一个设置项"要在一个 700+ 行
// 的单例里改 4 处(字段声明 / load() 里 60 行 if 链 / update() 参数 / _writeSettings 的
// map 字面量), 而且 load 与 save 的字段清单没有任何机械手段保证一致 —— 漏一处就是
// "改完重启回默认"或"存了读不回来"。现在:
//
//   · 读: load() 只负责读文件与容错, 解析按**域**分成 _applyAppearanceJson /
//     _applyPlaybackJson / _applySearchJson / _applyPlatformJson / _applyUpdateJson /
//     _applyInteractionsJson 六块;
//   · 写: _toJson() 一份 map, 同样按域分块(与上面六块一一对应, 顺序无关紧要);
//   · 门: `ui/test/app_settings_codec_roundtrip_test.dart` 断言
//     「写出去的 key 面 = 期望的 key 面」+ 全字段写→读往返, 漏字段立刻红。
//
// 语义纪律(改动时必须保持):
//   · 默认值一律等于"不改变现状"; 老配置缺字段 ⇒ 保持字段初值, 不报错。
//   · 任何校验/夹取(音质白名单、列数 2..4、增益 -40..0、LUFS -30..-5 ...)都在读侧,
//     写侧只照搬当前值 —— 这样手工改坏的文件也只会被夹到合法区间。
//   · `schemaVersion` 只增不减, 迁移判据写在 _applyPlaybackJson 里。

extension _AppSettingsJsonCodec on AppSettings {
  /// 按域读入整份 settings.json(缺字段 = 保持默认, 不做"全量覆盖")。
  void applyStoredJson(Map<dynamic, dynamic> raw) {
    _applyAppearanceJson(raw);
    _applyPlaybackJson(raw);
    _applySearchJson(raw);
    _applyPlatformJson(raw);
    _applyUpdateJson(raw);
    _applyDiagnosticsJson(raw);
    _applyInteractionsJson(raw);
  }

  /// 外观: 主题/强调色/字号/封面行列/清晰度/OLED 纯黑。
  void _applyAppearanceJson(Map<dynamic, dynamic> raw) {
    themeMode = AppSettings._themeFrom(raw['themeMode']);
    accent = AccentPalette.fromId(raw['accent'] as String?);
    textScale = AppSettings.snapTextScale(
      AppSettings._doubleOf(raw['textScale'], 1.0),
    );
    final rows = raw['coverRows'];
    if (rows is num && (rows.toInt() == 1 || rows.toInt() == 2)) {
      coverRows = rows.toInt();
    }
    final cols = raw['gridColumns'];
    if (cols is num && cols.toInt() >= 2 && cols.toInt() <= 4) {
      gridColumns = cols.toInt();
    }
    final coverQualityRaw = raw['coverQuality'];
    if (coverQualityRaw is String) {
      coverQuality = CoverQualityX.fromId(coverQualityRaw);
    }
    if (raw['oledDark'] is bool) oledDark = raw['oledDark'] as bool;
    // B7 自定义快捷入口: 缺字段/未知值回落默认(排行榜), 老配置零迁移。
    final quickAction = raw['customQuickAction'];
    if (quickAction is String) {
      customQuickAction = CustomQuickActionX.fromId(quickAction);
    }
  }

  /// 播放/音质/响度/EQ/歌词来源/桌面关闭行为。
  void _applyPlaybackJson(Map<dynamic, dynamic> raw) {
    final level = raw['audioLevel'];
    if (level is String && AppSettings.audioLevels.containsKey(level)) {
      audioLevel = level;
    }
    final skipVip = raw['skipVipSongs'];
    if (skipVip is bool) skipVipSongs = skipVip;

    volumeGainDb = AppSettings._doubleOf(
      raw['volumeGainDb'],
      0.0,
    ).clamp(-40.0, 0.0);
    if (raw['loudnessNormalize'] is bool) {
      loudnessNormalize = raw['loudnessNormalize'] as bool;
    }
    loudnessTargetLufs = AppSettings._doubleOf(
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
    if (fade is num && AppSettings.fadeOptions.containsKey(fade.toInt())) {
      fadeMs = fade.toInt();
    }
    if (raw['hardwareDecode'] is bool) {
      hardwareDecode = raw['hardwareDecode'] as bool;
    }
    if (raw['streamCache'] is bool) {
      streamCache = raw['streamCache'] as bool;
    }
    final limit = raw['cacheLimitMb'];
    if (limit is num && AppSettings.cacheLimits.contains(limit.toInt())) {
      cacheLimitMb = limit.toInt();
    }
    final trans = raw['lyricTranslation'];
    if (trans is bool) lyricTranslation = trans;
    final srcPref = raw['lyricSourcePreference'];
    if (srcPref is String &&
        AppSettings.lyricSourceOptions.containsKey(srcPref)) {
      // schema < 2 的 'auto' 是旧默认值(0.9 短路导致 AMLL 几乎不被用),
      // 一次性抬到新默认 'amll'; 之后用户手动改回 'auto' 会被本版号挡住不再覆盖。
      final schema = raw['schemaVersion'];
      final legacy =
          schema is! num || schema.toInt() < AppSettings.settingsSchemaVersion;
      lyricSourcePreference = (legacy && srcPref == 'auto') ? 'amll' : srcPref;
    }
  }

  /// 搜索/列表交互与日推缓存天数。
  void _applySearchJson(Map<dynamic, dynamic> raw) {
    final clearOnSwitch = raw['clearSearchOnTabSwitch'];
    if (clearOnSwitch is bool) clearSearchOnTabSwitch = clearOnSwitch;
    final hotSearch = raw['showHotSearch'];
    if (hotSearch is bool) showHotSearch = hotSearch;
    final cacheDays = raw['dailyCacheDays'];
    if (cacheDays is num &&
        AppSettings.dailyCacheOptions.contains(cacheDays.toInt())) {
      dailyCacheDays = cacheDays.toInt();
    }
    final playRaw = raw['librarySearchPlayAction'];
    if (playRaw is String) {
      librarySearchPlayAction = LibrarySearchPlayAction.values.firstWhere(
        (v) => v.name == playRaw,
        orElse: () => LibrarySearchPlayAction.fullList,
      );
    }
  }

  /// 平台/窗口行为: 关闭按钮(仅 Linux 会真的推给 GTK runner, 其它平台保留字段)。
  void _applyPlatformJson(Map<dynamic, dynamic> raw) {
    // 缺字段/未知值一律回落"直接退出"(不改变旧用户预期)
    closeBehavior = CloseBehaviorX.fromId(raw['closeBehavior']);
  }

  /// 自动更新检查: 频率 + 节流/跳过记录(兼容旧版布尔开关 true→每天)。
  void _applyUpdateJson(Map<dynamic, dynamic> raw) {
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

  /// 诊断/隐私开关(匿名诊断包)。
  void _applyDiagnosticsJson(Map<dynamic, dynamic> raw) {
    final anonDebug = raw['anonymousDebug'];
    if (anonDebug is bool) anonymousDebug = anonDebug;
  }

  /// 「我的」页排序用的最近交互记录(epoch ms) + 队列面板「左滑移除」提示的记忆。
  ///
  /// 先清空再读, 让 load() 幂等(重复 load 不叠加旧的会话内记录)。
  void _applyInteractionsJson(Map<dynamic, dynamic> raw) {
    // 「先清空再读」让 load() 幂等(重复 load 不叠加旧的会话内记录);
    // §12.6 之后记录是快照里的不可变 map, 所以这里建一份新的整份写回。
    final restored = <String, int>{};
    final interactions = raw['interactions'];
    if (interactions is Map) {
      for (final entry in interactions.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is int) restored[key] = value;
      }
    }
    _update(_snapshot.copyWith(interactions: restored));
    // 队列面板的「左滑移除」提示: 用户勾过「不再展示」就永久生效
    final queueHint = raw['queueSwipeHintDismissed'];
    if (queueHint is bool) queueSwipeHintDismissed = queueHint;
    // 详情页「歌词 ⇄ 封面」的记忆面(用户 2026-11-19): 老配置缺字段 ⇒ 保持默认
    // 'lyrics'; 未知值由 setter 的白名单丢弃。
    final face = raw['detailFace'];
    if (face is String) detailFace = face;
  }

  /// 落盘用的整份 map —— 与上面七个 `_apply*` 一一对应。
  ///
  /// 新增设置项时**同时**改: 字段声明 → 某个 `_apply*` → 这里 → `update()` 参数(可选) →
  /// `ui/test/app_settings_codec_roundtrip_test.dart` 的期望 key 表(门会提醒你漏了哪一处)。
  Map<String, Object?> toJson() => {
    // ---- 外观 ----
    'themeMode': AppSettings._themeName(themeMode),
    'accent': accent.id,
    'textScale': textScale,
    'coverRows': coverRows,
    'gridColumns': gridColumns,
    'coverQuality': coverQuality.id,
    'oledDark': oledDark,
    'customQuickAction': customQuickAction.id,
    // ---- 播放/音质 ----
    'audioLevel': audioLevel,
    'skipVipSongs': skipVipSongs,
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
    'schemaVersion': AppSettings.settingsSchemaVersion,
    // ---- 搜索/列表 ----
    'clearSearchOnTabSwitch': clearSearchOnTabSwitch,
    'showHotSearch': showHotSearch,
    'dailyCacheDays': dailyCacheDays,
    'librarySearchPlayAction': librarySearchPlayAction.name,
    // ---- 平台/窗口 ----
    'closeBehavior': closeBehavior.id,
    // ---- 自动更新 ----
    'updateCheckInterval': updateCheckInterval.name,
    'lastUpdateCheckMs': lastUpdateCheckMs,
    'skippedUpdateVersion': skippedUpdateVersion,
    // ---- 诊断 ----
    'anonymousDebug': anonymousDebug,
    // ---- 交互记录 ----
    'interactions': _interactions,
    'queueSwipeHintDismissed': queueSwipeHintDismissed,
    'detailFace': detailFace,
  };
}
