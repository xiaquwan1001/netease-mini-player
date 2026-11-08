# 任务书 · 设置项扩充 + 播放体验修复(2026-11-09)

> 状态: **执行中**(本文是唯一权威清单; 断电/换会话后从这里接着做)。
> 2026-11-09 进度: D7 批1–3 已收口(cargo 空闲); **R1 ✅ / R3 ✅ / R6 ✅ / R4 ✅(待 a36 视觉走查)**;
> 剩下 R2 / R2b / R5 / R7 = S3(Android)/ S4(Rust)/ S5(设置 UI)。执行记录见 §10。
> 关联: 进度 `docs/PROGRESS.md`; 队列 `docs/remaining-batches.md`; 审计 `docs/ui-ux-audit.md`
> 基线: HEAD = `2d53b68`(C2 完成, 模拟器 a36 GUI 已装新包); 后台车道 `D7`(frb 透传 domain) 正在改 `core/crates/ncm-ffi/api.rs`, **独占 codegen 与 cargo**

## 0. 需求清单(用户原话归纳, 共 7 项)

| # | 需求 | 类别 |
|---|---|---|
| **R1** | 推荐页切成两排(`coverRows=2`)时出现 **overflow 警告** | 🐞 bug |
| **R2** | 设置加入 **精细音量分贝调节**(在系统刻度之上提供更精确范围) | ✨ 播放 |
| **R2b** | 设置加入 **不同歌曲之间的音量平衡**(响度均衡) | ✨ 播放 |
| **R3** | 设置「关于」给出 **本项目 GitHub 网址** | ✨ 信息 |
| **R4** | **底栏与播放横条之间有一段空白**: 播放条应下移贴住底栏, 上方内容多留空间 | 🐞 布局 |
| **R5** | 参考 Melodia 增加控制项: **淡入淡出 / 硬解 / 音质选择 / 边听边存 / 缓存占用上限** | ✨ 播放 |
| **R6** | **深色模式提供 OLED 专用纯黑** | ✨ 外观 |
| **R7** | 设置加入 **响度均衡** + **自定义响度曲线配置文件的加载与导出**(社区成熟格式) | ✨ 播放 |

## 1. 现状事实(已核实, 改前必读)

- 设置模型: `ui/lib/src/app_settings.dart` 单例 + `settings.json` 落盘(与 Rust 同一 dataDir)。现有字段: `themeMode` / `textScale` / `audioLevel`(音质 standard..hires, **已存在**) / `coverRows`(1|2) / `clearSearchOnTabSwitch`。
- 设置页: `ui/lib/src/settings_view.dart`(C 批后瘦身为 3 组 + 账号/诊断二级页); 主题/字号/音质已在此。
- 主题构造在 `ui/lib/main.dart:85-94`(`theme` / `darkTheme` / `themeMode`) ⇒ **改主题必须动 main.dart**。
- 底栏: `main.dart:1841` `bottomNavigationBar: Column(mainAxisSize.min, [ _buildPlayerBar(...), NavigationBar(...) ])`; 播放条 `main.dart:2200` `Material(elevation:8)` → `SafeArea` → `Padding(horizontal:4)` → `Column[Slider, Row[封面/标题/5 按钮]]`。**空白来源需实测定位**(候选: 播放条 `SafeArea` 在底栏之上重复吃 inset / Slider 默认留白 / Material 阴影视觉缝)。
- Android 播放: `PlaybackService.kt`(Media3 `ExoPlayer` + `MediaSessionService`, 单 MediaItem, 队列在 Dart); `MainActivity.kt:143` 起 `ncm/player` 通道: `play/pause/resume/stop/seek/volume/state/dataDir`, 其中 `volume` 直接写 `c.volume = 0..1`。
- 外部链接: `ui/lib/src/platform.dart` `PlatformBridge.openUrl()` 已可用(Android `ncm/open` / Linux `xdg-open`) ⇒ **R3 不需新插件**。
- 音质已贯通: `main.dart:846/1406` 取链传 `AppSettings.instance.audioLevel`。
- 缓存: Rust `core/crates/ncm-service/src/cache.rs` 的 `AudioCache`(播完落盘); Android 侧**无** Media3 缓存层。
- 平台矩阵: **Android = Media3(ExoPlayer/Kotlin)**; **Linux = rodio 0.23 + symphonia(纯 Rust)**; 「硬解」在 Linux 无意义 ⇒ 该项仅 Android 显示。
- GitHub: `git remote origin` = **https://github.com/xiaquwan1001/netease-mini-player**(用户确认自行创建, 直接使用)。

## 2. 技术选型(社区成熟格式, 不自造)

### 2.1 响度均衡 → **EBU R128 / ITU-R BS.1770-4**
- 测量每曲 **integrated loudness (LUFS)** + true peak; 目标默认 **-16 LUFS**(移动端常用), 可配 -23/-18/-16/-14。
- 应用语义对齐 **ReplayGain 2.0**: `gain = targetLufs - measuredLufs`(静态, 无 pumping); 另提供「动态(AGC)」可选模式。
- 缓存测量结果到 `dataDir/loudness.json`(key=trackId, value={lufs,peak,measuredAt}), 未测曲目首播先按 0 dB, 后台补测。
- 测量实现放 Rust(`ebur128` crate 或 symphonia 解码后自算, 优先 crate), Android 复用 Rust 结果, 不重复实现。

### 2.2 自定义响度曲线 → **AutoEQ `ParametricEQ.txt`**(事实标准)
```
Preamp: -6.0 dB
Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71
Filter 2: ON LS Fc 120 Hz Gain 2.5 dB Q 0.70
```
- 支持 `PK` / `LS` / `HS`; 可选兼容 `GraphicEQ.txt`(频点-增益折线 → 转 biquad 链)。
- 导入: 文件(Android SAF / Linux 文件对话框)或粘贴文本; **导出**: 当前曲线写回同格式, 往返一致。
- 校验: 解析失败给行号 + 原因且不生效; 上限 20 filter(EqualizerAPO 惯例); 增益裁剪 ±24 dB。
- 实现: biquad(二阶 IIR)链; Android 在 `AudioProcessor` 链, Linux 在 rodio `Source` 包装。

## 3. 设置 schema(编排者先落地, 各车道只读不改)

新增 `AppSettings` 字段(**默认值 = 不改变现状**), 全部落 `settings.json`:

| 字段 | 类型 | 默认 | 取值 | 需求 |
|---|---|---|---|---|
| `oledDark` | bool | false | 深色下用纯黑 #000 | R6 |
| `volumeGainDb` | double | 0.0 | -40 〜 0, 步进 0.5 | R2 |
| `loudnessNormalize` | bool | false | 响度均衡开关 | R2b/R7 |
| `loudnessTargetLufs` | double | -16.0 | -23/-18/-16/-14 | R2b/R7 |
| `loudnessDynamic` | bool | false | 动态 AGC(默认静态 RG2.0) | R7 |
| `eqProfileName` | String? | null | 生效曲线名 | R7 |
| `eqProfileText` | String? | null | 曲线原文(AutoEQ ParametricEQ.txt) | R7 |
| `fadeMs` | int | 0 | 0/200/500/1000 | R5 |
| `hardwareDecode` | bool | true | 仅 Android | R5 |
| `streamCache` | bool | true | 边听边存 | R5 |
| `cacheLimitMb` | int | 512 | 128/256/512/1024/2048 | R5 |

> `audioLevel`(音质选择)已存在 ⇒ R5 的「音质选择」只需在设置里保持 + 补 Hi-Res 需会员说明。

## 4. 分批与车道切分

### 可立即并行(纯 Dart, 不受 D7 影响)

| 车道 | 内容 | 文件白名单 | 验收 |
|---|---|---|---|
| **S1 · R1** | 定位并修 `coverRows=2` 溢出; 加回归测试 | `ui/lib/src/recommend_view.dart` + 新建 `ui/test/s1_two_row_overflow_test.dart` | 300/360dp + textScale1.25 + coverRows=2 无 `RenderFlex overflowed`; analyze 0 |
| **S2 · R3+R6** | 「关于」加 GitHub 链接(`PlatformBridge.openUrl`); OLED 纯黑主题(新建 `ui/lib/src/theme.dart`, 深色基底 #000 + surface 层级); 设置页加「OLED 纯黑」开关 | `ui/lib/src/settings_view.dart`, `app_settings.dart`, 新建 `theme.dart` + 测试 | 深色+开关时 Scaffold/NavigationBar/播放条背景 = `#000000`(widget 断言); 关于项点击调用 openUrl(注入验证); analyze 0 |
| **M · R4** | 编排者本人改 `main.dart`(避开 S2 热点文件): 诊断空白来源 → 播放条贴住底栏 | `ui/lib/main.dart` | 截图前后对比 + 窄屏不溢出 + 全量测试绿 |

### D7 收口后才能开(需 cargo / Android 构建)

| 车道 | 内容 | 落点 | 备注 |
|---|---|---|---|
| **S3 · Android 播放能力** | 精细音量(增益×系统音量)、淡入淡出(ramp)、硬解开关(`MediaCodecSelector`)、边听边存(`SimpleCache`+`CacheDataSource`)、缓存上限(`LeastRecentlyUsedCacheEvictor`)、响度增益应用、biquad EQ(`AudioProcessor`) | `PlaybackService.kt` / `MainActivity.kt` / `ui/lib/src/playback.dart` | 需 android 构建 ⇒ 与 D7 cargo 互斥 |
| **S4 · Rust/Linux 侧** | rodio 增益/淡入淡出/EQ(biquad Source)、R128 测量(`ebur128`)、`loudness.json`、`AudioCache` 上限淘汰、AutoEQ 曲线解析(共享) | `ncm-playback`, `ncm-service/cache.rs`, `ncm-domain` 曲线类型, `ncm-ffi` 导出 | 需 codegen ⇒ 与 D7 互斥 |
| **S5 · 设置全量 UI** | R2/R2b/R5/R7 全部项接进设置页(分组: 外观/播放/音质与缓存/账号/关于/诊断) + 曲线导入导出入口 | `settings_view.dart` + 新 `settings_audio_page.dart` | 依赖 S3/S4 契约; 与 S2 同文件 ⇒ 排 S2 之后 |

**硬约束**: codegen 是全局串行点; Android 构建会编译 Rust ⇒ S3/S4 必须串行且等 D7。

## 5. 验收口径(逐项)

- **R1**: 两排 + 300/360dp + textScale1.25 无 overflow; 模拟器走查无黄黑条; 卡片文本 `maxLines`+`ellipsis`。
- **R2**: 增益作用于「播放器音量」而非系统音量(两者相乘); 0 dB = 不变; -40 dB 近静音; 即时生效; 重启保持。
- **R2b/R7 响度**: 默认静态(RG2.0); 开/关 A/B 可听差; 动态模式限速 ≤3 dB/s 防 pump; 未测曲目按 0 dB + 后台补测。
- **R7 曲线**: 导入合法 → 生效且可导出往返一致; 导入非法 → 明确报错且不生效; 20 filter 上限; 关闭 = 旁路直通。
- **R3**: 关于显示 `https://github.com/xiaquwan1001/netease-mini-player`, 点击系统浏览器打开; 附许可(vendor WTFPL / 本项目 MIT)与版本号。
- **R4**: 播放条底沿与 NavigationBar 顶沿无可见缝(截图对比), 内容区高度相应增加; 无曲目时不留空。
- **R5**: 淡入淡出 0/200/500/1000ms 且切歌不爆音; 硬解关掉强制软解仍可播(仅 Android); 边听边存命中时二次播放不联网; 缓存达上限按 LRU 淘汰且不删正在播的文件。
- **R6**: 深色+OLED → 背景严格 `#000000`(不是 #121212); 对比度不低于 Material 规范; 关掉回原深色。

## 6. 测试与门禁(所有车道)

- `cd ui && dart analyze` **error/warning = 0**(本机 `flutter analyze` 稳定 SIGSEGV, 只用 `dart analyze`)
- `cd ui && flutter test` 全量绿, **用例数只增不减**(当前基线 **309 passed + 1 skip**)
- Rust 改动: `cargo build --offline --workspace --all-targets` 0 error + `cargo test -p ncm-domain -p ncm-service` **119 全绿**
- 收口由编排者**独立重跑**, 不采信 worker 自报; 提交前 `git status` 只含本批文件
- 播放类改动(音量/淡入淡出/EQ/缓存)**必须上 a36 走查**, widget 测试不能替代

## 7. 风险与回滚

| 风险 | 处置 |
|---|---|
| 响度测量成本高(需完整解码) | 只对首播后台测 + `loudness.json` 缓存; 未测先 0 dB |
| 自写 DSP 爆音/失真 | 先「静态增益 + 单 biquad」小样本上机听感, 再扩到 20 filter |
| 硬解语义含糊(Media3 默认已优先硬件) | 定义两态「优先硬解(默认)/仅软解」, 仅 Android 显示 |
| 缓存 LRU 误删正在播文件 | evictor 跳过当前播放曲目 id; 单测覆盖 |
| 曲线文件不可信 | 只解析数值不执行代码; 上限 20 filter + 增益裁剪 ±24 dB |
| 与 D7 抢 cargo/codegen | S3/S4 等 D7 完成后再开; S1/S2/M 纯 Dart 不受影响 |

**回滚**: 每批独立 commit; 纯 UI 批 `git revert <sha>`; 涉及 `core/` 的批 `git restore --staged --worktree core/crates ui/lib/src/rust`。

## 8. 执行顺序

1. **现在**: 落盘任务书 → 扩展 `AppSettings` schema → 开 **S1** + **S2**; 编排者同时做 **M(R4)**。
2. S1/S2/M 收口后: 等 **D7** → 开 **S4**(Rust: R128/曲线解析/缓存上限/淡入淡出)。
3. S4 契约稳定后开 **S3**(Android Media3) → a36 走查。
4. 最后 **S5** 接全部设置 UI(含曲线导入导出) + 全量回归 + 人工视觉过目。

## 9. 待用户确认(可先按默认值实现)

- 响度均衡默认目标电平: 建议 **-16 LUFS**(移动端); 广播口径 -23。
- 缓存上限默认 **512 MB**。
- 「硬解」Linux 不适用 ⇒ 该设置项仅 Android 显示。

## 10. 执行记录(增量, 每批落盘)

### 2026-11-09 · 第一波: R1 + R3 + R6 + R4

| 需求 | 结论 | 提交 | 测试 |
|---|---|---|---|
| R1 两排封面 overflow | ✅ `_CoverRow` 外层 `height*2` 少算 4px 行间距 → `height*2+4` | `dd175cf` | `s1_two_row_overflow_test.dart`(2 例, 先复现 4.0px 再转绿) |
| R3 关于页 GitHub | ✅ `src/app_meta.dart` + 「开源仓库」「版本与许可」两项, 走 `PlatformBridge.openUrl` | `7a9cdcc` | `s2_about_page_test.dart`(3 例) |
| R6 OLED 纯黑 | ✅ `src/theme.dart`(`buildDarkTheme(oled:)`, surface 全黑 + onSurface #E6E6E6)+ 设置页「OLED 纯黑」开关 | `7a9cdcc` | `r6_oled_theme_test.dart`(4 例) |
| R4 播放条贴底栏 | ✅ 根因 = 播放条自己的 `SafeArea` 又吃了一次 bottom inset(`NavigationBar` 内部已有 SafeArea), 改 `SafeArea(bottom:false)` | `7a9cdcc` | 无单测(播放条依赖 Media3 通道, Linux 测试环境走不到); **a36 已 A/B 走查, 见下** |

门禁: `dart analyze` 0 error/0 warning(39 info); `flutter test` **318 passed + 1 skip**(基线 309, 新增 9)。

**a36 走查记录(2026-11-09, 模拟器 a36 1080x2400)**

- R4 A/B 量化(同一屏同一曲目, 像素测量): 播放条内「控制行最低像素 → NavigationBar 顶沿」的空白
  修复前 **115 px**, 修复后 **52 px**, 差值 **63 px = 24 dp = 系统手势条 inset** —— 证实那条空白就是重复吃掉的
  bottom inset。剩余 52 px 是播放条自身的 `IconButton` 内边距 + 末尾 `SizedBox(height: 8)`, 属设计内留白。
- R6 像素采样(设置 → 深色 → 打开「OLED 纯黑」): 页面中部 / 空白区 / 卡片内 / 底部导航栏 / 状态栏
  全部 `(0,0,0)`; 关闭前同位置为 `(35,25,25)`(M3 带色 surface)、`(26,17,17)`。
- 结论: R4/R6 视觉验收通过(仍有「色带/间距」的观感判断留给你过目, 截图在 `/tmp/a36-fix.png`、
  `/tmp/a36-oled.png`)。

### 下一波(未开工)

- **S4(Rust, 先做)**: rodio 增益/淡入淡出、biquad EQ、R128 测量 + `loudness.json`、`AudioCache` 上限淘汰、AutoEQ 曲线解析。契约稳定后再做 S3。
- **S3(Android Media3)**: 精细音量增益、淡入淡出 ramp、硬解开关、`SimpleCache`+LRU、响度增益、EQ AudioProcessor。
- **S5(设置 UI)**: 把 R2/R2b/R5/R7 全接进设置页(分「外观/播放/音质与缓存/关于/诊断」)+ 曲线导入导出。
- D7 剩余批4–批7(见 `docs/d7-frb-domain.md` §3)。
- 唯一 cargo/codegen 车道约束仍然有效: S3/S4 与 D7 不能同时跑。

