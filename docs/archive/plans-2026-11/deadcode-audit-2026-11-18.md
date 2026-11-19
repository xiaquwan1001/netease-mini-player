# 死代码审计报告 (E 车道 · 2026-11-18)

> **只读审计**: 本报告没有删改任何一行产品代码。基线 HEAD `5b79e5a`(v0.21.0 后 8 个未发版切片)。
> 工作树里同时有 D 车道(docs/)与另一条 UI 车道(ui/lib/src/{app_shell,home_page,layout}.dart + 3 个新测试)在飞,
> 本报告的候选**已逐条交叉核过**: 没有任何一条候选的唯一引用者落在在飞改动里(grep 三个改动文件 + 4 个新文件 = 只命中 `layout.dart:31` 的声明本身)。
> 数字来源: 本机实测(命令与输出随条附上); 门禁数字一律抄自 `docs/PROGRESS.md` 头部「当前门禁」表。
> **行号口径**: 全部行号取自审计时刻的工作树; 在飞车道正在改 `layout.dart`/`app_shell.dart`/`main.dart`,
> 这些文件内行号可能整体位移(`kPageHorizontalPadding` 审计时在 `layout.dart:31`, 复核时已到 `:32`), 以符号名为准。
> 本文件在 `.pi/` 下, 该目录已进 `.gitignore`, 故不出现在 `git status`; 本车道改动仅此一份报告, 零代码改动。

---

## 0. 口径与覆盖

### 0.1 扫了多少

| 面 | 规模(本机实测) | 命令 |
|---|---|---|
| Dart 手写源 | **148** 个文件(`ui/lib/src` 共 152, 减去 4 个 `src/rust/` 生成文件) | `rg --files ui/lib -g '*.dart' -g '!**/src/rust/**' | wc -l` → 149(含 `main.dart`) |
| Dart 测试 | **162** 个文件 | `rg --files ui/test -g '*.dart' | wc -l` |
| Dart 顶层类型 | **483**(class 400 / enum 18 / extension 4 / typedef 61 / mixin 0) | 分项 `rg -c -N '^(?:abstract |sealed |final |base |interface )*class \w+'` 等 |
| Dart 顶层函数/常量 | **338** 条声明(与类型合并去重后 **821** 个符号) | 见 0.2 |
| Dart 类成员方法名 | **536** 个 | `rg -o '^  (?:static |@override )*<type> (\w+)\(' -r '$1'` |
| Rust | **72** 个 `.rs` / **43 372** 行(`core/crates` 全量, 含 `frb_generated.rs` 13 487 行 ⇒ 手写 **29 885** 行) | `rg --files core/crates -g '*.rs' | wc -l` → 72; `| xargs wc -l` → 43372 |
| Rust `pub` 项 | **733** 个(fn/struct/enum/trait/const/static/type) | `rg -o -N '^\s*pub (?:async )?(?:fn|struct|enum|trait|const|static|type) (\w+)'` |
| FFI 导出面 | **161**(脚本口径, 与 PROGRESS 头部表一致) | `bash tools/api-coverage.sh` → `FFI 导出函数 : 161` |
| Kotlin | **7** 个 main 文件 / **2 400** 行(`src/androidTest` 另 3 个文件 615 行, 合计 3 203 行) | `find ui/android/app/src/main -name '*.kt' | xargs wc -l` |
| Android res | **21** 个文件(8 个 `ic_notif_*.xml` / 4 个 values(-night) / 2 个 xml / 7 个 mipmap) | `find ui/android/app/src/main/res -type f | wc -l` |

### 0.2 统计口径(可复算)

1. **标识符频次表法**(主口径): 对"去掉 `//` 注释"的语料做全量标识符计数:
   `rg --files ui/lib -g '*.dart' -g '!**/src/rust/**' | xargs sed -e 's@//.*@@' | rg -o -N '[A-Za-z_]\w*' | sort | uniq -c`
   ⇒ lib 侧 **5 074** 个不同标识符; test 侧 **3 410** 个; `ui/lib/src/rust` 生成侧单独统计。
   符号声明名与频次表 join, `lib 计数 == 1`(只剩定义处)即进候选, 再**逐条 `rg -n -w` 复核**。
2. 频次表**故意把注释/字符串里的提及也算引用**(宁漏杀不错杀), 所以表里的"0 引用"一定是真 0。
3. 反过来, 去 `//` 注释会把含 `//` 的字符串截断(例: URL 里的 `$kRepoSlug`),
   因此**每条候选都另跑一次完整 `rg` 复核**; `kRepoSlug`/`kCompactMaxWidth` 正是这样被排除的假阳性。
4. 私有死代码理论上已清零,**两道门可证**:
   - Dart: `dart analyze` **0 issue**(抄自 PROGRESS 头部表); `unused_element`/`unused_field`/`unused_import` 是 analyzer **默认诊断**,
     `ui/analysis_options.yaml` 只 `include: package:flutter_lints/flutter.yaml` 未关掉它们 ⇒ 私有成员死码 = 0。
     `rg 'ignore: unused|ignore_for_file: unused' ui/lib ui/test` 只命中 3 个 FRB 生成文件。
   - Rust: `cargo clippy --workspace --all-targets -- -D warnings` **0 warning**(同上表); `rg 'allow\(dead_code\)' core/crates`
     **零命中** ⇒ 非 `pub` 死码 = 0。**所以本报告只可能剩公开面**。
5. **死文件检查**: 解析 `import/export/part` 关系, `lib` 下 153 个 dart 文件(含 main.dart)中
   **无仓内导入者的文件 = 0**(7 个 part 文件已按 `part of` 归并) ⇒ 不存在整文件死码。

### 0.3 已知盲区(结论保守的原因)

| 盲区 | 影响 | 处置 |
|---|---|---|
| Dart 没有反射, 但 FRB 生成层按**类型名**消费 | DTO 类型名在 lib 里 0 引用 ≠ 死(`VipGrowth`/`RadioRankedDj`/`MvItem` 等只经字段类型间接用) | **一律不判死** |
| Rust `#[frb(mirror)]` 的 `_AlbumBrief` 等 **65** 个镜像结构 | 名字只出现 1 次(声明处), 由 codegen 按名消费 | 不作为候选 |
| Kotlin 方法通道名是**字符串**, Dart 侧可能经变量传参 | 字面量计数只能作参考 | 改用"Kotlin 侧 `"x" ->` 逐名对 Dart 字面量"双向对照, 并对 `volume` 单独深挖 |
| 平台条件编译(`#[cfg(windows)]`、平台分支) | 本机(Linux)无法编译验证 Windows 分支 | 一律进 **D 级** |
| `ncm-cli` 的调用**算**仓内引用 | `signin_status`/`podcast_radio` 有 CLI 调用, 只是 UI 无入口 | 在 C 级注明"CLI 保留理由" |
| 在飞工作树改动(审计期间另一条 UI 车道加了 layout.dart +95 行) | 新增符号未被本报告覆盖 | 候选已交叉核对不受影响; 在飞新增代码另需一轮 |

---

## 1. A 级: 真死, 零风险可删

> 判定 = **lib+test 全仓零引用**(除定义处), 非 `@visibleForTesting`, 非 `part` 私有, 非平台专用。
> 每条都做了 `rg -n -w <符号> ui/lib ui/test -g '*.dart' -g '!**/src/rust/**'` 完整复核(唯一一条输出即定义处)。

### A1 · `requiresPurchase` — 2 行

`ui/lib/src/playback_policy.dart:13-14`(doc + 1 行函数体)

```
$ rg -w requiresPurchase ui/lib ui/test -g '*.dart' -g '!**/src/rust/**'
ui/lib/src/playback_policy.dart:14:bool requiresPurchase(rust.SongDto song) => song.paid;
```

同文件的 `requiresVip`(12 行)与 `shouldSkipVipSong`(21 行)仍在用; 注释自称"不在此策略范围内", 属于策略层预留未落地。
**注**: 若产品决定"数字专辑(fee=4)也要提示购买", 应保留并接线 —— 这是唯一需要一句话确认的 A 级项。

### A2 · `validateEqProfile` — 4 行

`ui/lib/src/audio_tuning.dart:88-90`(doc + 2 行)

```
$ rg -n 'eqProfileValidate|validateEqProfile' ui -g '*.dart'
ui/lib/src/audio_tuning.dart:89:Future<rust.EqValidationDto> validateEqProfile(String text) =>
ui/lib/src/audio_tuning.dart:90:    rust.eqProfileValidate(text: text);
ui/lib/src/rust/api.dart:297:Future<EqValidationDto> eqProfileValidate({required String text}) =>
```

即: Dart 这层 wrapper **没有调用方**, 而它自己才是 `rust.eqProfileValidate` 的唯一调用点 ⇒ 删 wrapper 等于 EQ 曲线校验在 UI 侧彻底不可达。
而 `_ImportEqDialog`(`settings_audio_page.dart:423`)导入 EQ 时并不校验 ⇒ **当前 UI 事实上不校验曲线**, 与"R7 导入时用"的设计意图脱节。
**建议**: 先确认是否要接回(接回只需在导入回调里 await 一次), 否则删除。

### A3 · `kImageHeaders` — 5 行

`ui/lib/src/cover_art.dart:29-33`(doc + 4 行常量)

```
$ rg -n -w kImageHeaders ui/lib ui/test -g '*.dart' -g '!**/src/rust/**'
ui/lib/src/cover_art.dart:30:const Map<String, String> kImageHeaders = {
```

文档自称"兼容旧引用(有些调用点可能还在用)", 实测**零调用点**。真正的请求头在 `_UaNetworkImage` 里直接设
(`cover_art.dart:51` `..userAgent = kImageUserAgent`、`:61` `req.headers.set(refererHeader, …)`),
`kImageUserAgent`(25 行)仍被 51 行使用, 删它不牵连。

### A4 · `DailyPlaylistCache.purge()` — 3 行

`ui/lib/src/daily_cache.dart:209-211`

```
$ rg -n -w 'purge' ui/lib ui/test -g '*.dart'      # 全仓只有 1 处
ui/lib/src/daily_cache.dart:210:  Future<bool> purge() =>
$ rg -n '\.purge\(\)' ui core -g '*.dart' -g '*.rs'  # 空
```

实例方法 `purge()` 是 `purgeAccount()` 的"当前账号"薄包装, 但登出/切号走的是
`account_actions.dart:416-419` → `DailyPlaylistCache.purgeAccount(...)`(静态, 直接传 key), 所以这层包装没人用。

### A5 · `DiagUploader.uploadJson` — 18 行

`ui/lib/src/diag_upload.dart:52-69`(doc + 全函数)

```
$ rg -n -w uploadJson ui/lib ui/test -g '*.dart' -g '!**/src/rust/**'
ui/lib/src/diag_upload.dart:53:  Future<DiagUploadResult> uploadJson(String json, {required String clientId}) {
```

调用方只有 `upload()`(`settings_diagnostics_page.dart:169-170` 走 `upload(payload, …)`),
"复用 DebugReport 落盘 JSON"这条路没人走。删掉不影响 `upload` 与 5 例 `diag_upload_test`(它们只用 `upload`)。

### A6 · `PROVIDER_NETEASE` — 1 行

`core/crates/ncm-service/src/lib.rs:34`

```
$ rg -n 'PROVIDER_NETEASE' . -g '!core/target'
./core/crates/ncm-service/src/lib.rs:34:pub const PROVIDER_NETEASE: &str = "netease";
```

`git log -S 'PROVIDER_NETEASE'` = 只有首个 core 提交(`41daac3`), **从未被引用**。
provider 名字的真实出口是 `netease/provider.rs:15` 的 `fn name()`, 其余 3 处 `"netease"` 字面量
(`identity.rs:50` / `ttml_source.rs:51,60`)各有语义, 与本常量无关。

### A7 · `NeteaseProvider::with_channel` — 9 行

`core/crates/ncm-service/src/netease/mod.rs:139-147`

```
$ rg -n -w with_channel core/crates -g '*.rs' -g '!**/frb_generated.rs'
core/crates/ncm-service/src/netease/mod.rs:140:    pub fn with_channel(session: Session, domain: Option<String>, ua: Option<String>) -> Self {
```

注释自称"风控实验用", 与 `new()`(124-138)是同一份构造体的两份拷贝(唯一差异是 domain/ua 从环境变量读)。
风控实验已收尾(v0.12 后无相关批次), 零调用点。要再做实验可从 git 历史恢复。

### A8 · `Player::set_gain_db` — 6 行

`core/crates/ncm-playback/src/lib.rs:433-438`

```
$ rg -n -w set_gain_db core/crates -g '*.rs' -g '!**/frb_generated.rs'
core/crates/ncm-playback/src/lib.rs:434:    pub fn set_gain_db(&self, gain_db: f32) {
```

精细增益的实际通道是 `player_configure(...)` → `Player::configure(tuning)`(`audio_tuning.dart:175` 在用),
`set_gain_db` 只是"改一个字段再 configure"的快捷方式, 无人调用。

**A 级合计: 8 条 / 48 行手写删除**(2+4+5+3+18+1+9+6)。

---

## 2. B 级: 仅测试/仅文档引用(删除要连带改测试)

| 符号 | 位置 | lib 内引用 | 测试引用 | 行数 | 说明 |
|---|---|---|---|---|---|
| `kBrandSeed` | `ui/lib/src/theme.dart:44` | 0(仅声明 + 4/65 行注释提及) | `ui/test/theme_accent_test.dart:59` | 1 | `rg -n -w kBrandSeed ui/lib …` → 只 3 行, 2 行是注释。主题已改走 `AccentPalette`, 该常量只剩"改造前等价性"断言锚点 |
| `kPageHorizontalPadding` | `ui/lib/src/layout.dart:31-33` | 0(仅声明) | `ui/test/layout_metrics_test.dart:157` | 3 | 页面横向留白实际统一走 `kPageInsets`/`kPageRowPadding`(`layout.dart:36` 起); 该常量只剩测试用 |
| `shouldShowBadges` | `ui/lib/src/adaptive_text_row.dart:18-27` | 0(仅声明) | `ui/test/adaptive_text_row_test.dart:28-38+`(整组) | 10 | 文档自称"供原来按可用宽断言的单测/调用方继续用"; 新口径 `shouldShowBadgesForWidth`(`adaptive_text.dart:46`)有 lib 调用点 |

**B 级合计: 3 条 / 14 行**, 附带改 3 个测试文件(其中 `adaptive_text_row_test.dart` 整个 `shouldShowBadges` group 要换成 `shouldShowBadgesForWidth` 等价断言)。

### 误判排除(看起来像 A/B, 实际不是)

- `_AppSettingsJsonCodec`(`ui/lib/src/app_settings_codec.dart:23`): 私有扩展名零引用, 但**成员**(`applyStoredJson` 等七个 `_apply*`)在 `app_settings.dart` 里被调用 ⇒ 活。
- `clearCoverPaletteCache` / `resetAudioTuningNotices` / `debugForceAndroid` / `debugInterpolating` 等 **11 个 `@visibleForTesting`** 全部被测试引用(`rg -c -w debugForceAndroid ui/test` → 24)。
- `kRepoSlug`(`update_checker.dart:17`)、`kImageUserAgent`、`kCompactMaxWidth` 等: 频次表里的"1"来自 sed 截断 URL 或注释剥离, 完整 `rg` 复核后均为活。
- `VipGrowth`/`RadioRankedDj`/`MvItem`/`StreamUrl` 等 DTO: lib 里 0 次"按名字"出现, 但经返回值/字段类型间接使用(**盲区**, 不判死)。

---

## 3. C 级: FFI 已导出但 Dart 无入口

### 3.1 **口径发现: 现状是 9 个, 不是文档写的 6 个**

```
$ bash tools/api-coverage.sh
vendor endpoint 模块 : 136
service 已调用        : 135  (99%)
未接入               : 1
FFI 导出函数          : 161
其中 UI 没有入口      : 7 -> cache_stats cloud_song_url consent_plaintext_storage eq_profile_normalize player_tuning playlist_tracks_add user_play_ranking
```

脚本报 **7**, 但按"调用形态"严格复核(`rust\.<camel>\b`)实测 **9**(另有 1 个大小写变体假阳性):

```
cache_stats                 cacheStats
cloud_song_url              cloudSongUrl
consent_plaintext_storage   consentPlaintextStorage
eq_profile_normalize        eqProfileNormalize
lyric_lines_i18n            lyricLinesI18n        ← 假阳性: 真实调用名是 FRB 大小写变体 lyricLinesI18N(lyric_controller.dart:150 + frb_smoke_test.dart:90)
player_tuning               playerTuning
playlist_tracks_add         playlistTracksAdd
podcast_radio               podcastRadio
signin_status               signinStatus
user_play_ranking           userPlayRanking
```

**脚本漏报 2 个的根因**(建议修 `tools/api-coverage.sh`): 它用 `rust\.([A-Za-z0-9_]+)` 取标识符后**小写化比对**,
于是 **DTO 类型名把同名导出函数"顶替"成了有入口** —— `rust.SigninStatus`(`vip_page.dart:28`)、`rust.PodcastRadio`
都被算作 `signin_status`/`podcast_radio` 的入口。修法: 只统计**调用形态**(`rust\.<name>\s*\(` 或把函数当值传递的 `rust\.<name>\s*[,)]`), 不把"类型注解里出现"算入口。

### 3.2 逐个判定(行数 = `api.rs` 里该 `pub fn` 的整段)

| # | 导出 | api.rs 位置 / 行数 | 判定 | 证据 |
|---|---|---|---|---|
| 1 | `cache_stats` | 1533-1540 / 8 | **有意保留** | 设置页只接了"按上限收敛" `rust.cacheEnforceLimit`(`audio_tuning.dart:306`); 统计面板未做。`docs/api-coverage.md:3` 明写"给未来设置项留的宿主口" |
| 2 | `cloud_song_url` | 3292-3298 / 7 | **有意保留** | 云盘行播放走 `song_url_v1`(已接), 这是直链备用; 同上文档明写 |
| 3 | `consent_plaintext_storage` | 858-864 / 7 | **待产品决策** | 凭据明文回退的"同意门"。设置页 `_CredentialStorageTile`(`settings_view.dart:582-601`)只读 `rust.credentialStatus()`, 没有同意开关; `consent` 概念在 Dart 侧只出现在注释里 ⇒ 功能面未落地 |
| 4 | `eq_profile_normalize` | 1478-1481 / 4 | **真死** | `EqProfile::parse + to_text()` 的规范格式只在此出口, UI 导入走 `eq_profile_validate`(且见 A2, 连 validate 都断了)。无调用形态、无 CLI 用 |
| 5 | `player_tuning` | 1511-1513 / 3 | **有意保留** | 与 `player_configure`(在用)成对: 只写不读。`docs/api-coverage.md` 明写"给未来设置项留" |
| 6 | `playlist_tracks_add` | 2690-2695 / 6 | **真死(本批回归)** | 唯一 Dart 调用点随「存为歌单」面板在 `1a688d8`(2026-11-18 队列/播放条批)删除: `git log -S 'playlistTracksAdd' -- ui` → `1a688d8 / 64e1aef / 8e41891`。provider 层方法仍在, 但 UI 已无批量加曲入口 |
| 7 | `podcast_radio` | 2146-2148 / 3 | **真死(早前有意清过)** | `git log -S 'podcastRadio' -- ui` → `5197a0e`("D 批收敛——…podcast 死码…")。现 `podcast_detail_page.dart` 只调 `podcastProgram`/`podcastPrograms`。**保留理由**: `ncm-cli/src/main.rs:1124` 仍在调 provider 层同名方法 |
| 8 | `signin_status` | 2919-2921 / 3 | **真死(数据源归并)** | `git log -S 'signinStatus' -- ui` → `59ff88d`("签到数据源归并")。现签到页数据来自 `rust.vipOverview()`(`vip/vip_mapping.dart:155`, 含 `signin_progress`)。**保留理由**: `ncm-cli/src/main.rs:886` 仍用 provider 层同名方法 |
| 9 | `user_play_ranking` | 2521-2539 / 19 | **待产品决策** | `docs/remaining-batches.md` §11.A-2 已裁决: 匿名态恒空 / `event/get` 匿名 301 ⇒ "接了也看不到东西, 等有登录态真机再决定"。底层 `play_ranking_of` 仍被 CLI 与 `play_ranking`(在用)共享 |

**C 级小结**: 9 个 = 4 个有意保留(1/2/5 + 3 的半保留) + 4 个真死(4/6/7/8, 共 **16 行** `api.rs`) + 1 个待决策(9)。
**文档口径(PROGRESS 头部表 + `docs/api-coverage.md` 都写 6)需更新为 9, 并区分"保留 / 真死"** —— 这不属于本车道(只读), 转给 D 车道或下一批。

---

## 4. D 级: 疑似死但要人判断

### D1 · 「用户音量档」整链无入口(**功能性发现, 优先级高于删码**)

`Playback.setVolume` 死掉不是终点 —— 它是整条链唯一入口:

| 层 | 位置 | 现状 |
|---|---|---|
| Dart wrapper | `ui/lib/src/playback.dart:413-421` | 零调用(`rg -n setVolume ui -g '*.dart' -g '*.kt'` → 仅 413 行声明) |
| Kotlin 通道处理 | `MainActivity.kt:439-443` `"volume" ->` | 只有这条 Dart 路径会发; 字面量 `'volume'` 在 lib 里 3 次出现全在死函数内(`playback.dart:415,416,442`) |
| Kotlin 语义 | `PlaybackService.kt:418-425 setUserVolume()` + `appliedVolume()` | 只被上面那支通道调用 |
| Rust FFI | `ncm-ffi/src/api.rs:1414-1415 player_set_volume` | 唯一渲染调用点在死函数里 |

⇒ **0..1 的"系统音量档"当前 UI 完全无法设置**(只有 dB 精细增益 `volumeGainDb` / 响度均衡可用)。
判定: **需产品决策** —— 要么补入口(设置页滑杆/播放条长按), 要么三端一起删(≈ Dart 9 + Kotlin ~10 + Rust 2 行)。
不要在没决策时单独删 Dart wrapper: 那会让"功能半成品"变成"功能彻底不存在且无线索"。

### D2 · `policy_backend_name`(`core/crates/ncm-service/src/credential_store.rs:504-506`)

`#[cfg(windows)]` 段的 DPAPI 后端名出口, **零引用**; 本机(Linux)编译不到该分支, 无法用 clippy 验证。
**待核实**: 诊断上报 `debug_report.dart:136` 读的是 `rust.credentialStatus()`, 与这个常量无关 ⇒ 大概率是早期"上报后端名"设计的残留。

### D3 · 依赖只为零个死符号引入: `cupertino_icons`

```
$ rg -n 'Cupertino|cupertino' ui/lib ui/test -g '*.dart'      # 无输出
ui/pubspec.yaml:  cupertino_icons: ^1.0.8
```

**零引用**(纯 `flutter create` 遗留), 且会往产物里塞一份 CupertinoIcons 字体资产。
其余 3 个依赖均在用: `rust_lib_minincm`(构建胶水)、`flutter_rust_bridge`(生成代码 import)、`qr_flutter`(`song_share.dart:9`/`feed_share.dart:3`)。
**建议单独一个 chore 提交移除**。

### D4 · 在飞改动不在本报告口径内

审计期间另一条 UI 车道在工作树里加了 `layout.dart` +95 行(断点常量 `kCompactMaxWidth`/`kContentMaxWidth`/`kRailWidth`/`kWideMinWidth`、`ContentWidthLimit`), 改了 `app_shell.dart`/`home_page.dart` 并新增 3 个测试。
这些符号**未纳入本次分级**(未提交的在飞代码, 且都在用)。等该车道合入后补一次增量扫描即可。

---

## 5. Top 10 建议删除清单 + 验证门

| # | 符号 | 级别 | 文件:行 | 行数 |
|---|---|---|---|---|
| 1 | `DiagUploader.uploadJson` | A | `ui/lib/src/diag_upload.dart:52-69` | 18 |
| 2 | `NeteaseProvider::with_channel` | A | `core/crates/ncm-service/src/netease/mod.rs:139-147` | 9 |
| 3 | `Player::set_gain_db` | A | `core/crates/ncm-playback/src/lib.rs:433-438` | 6 |
| 4 | `kImageHeaders` | A | `ui/lib/src/cover_art.dart:29-33` | 5 |
| 5 | `validateEqProfile`(先确认是否接回) | A | `ui/lib/src/audio_tuning.dart:88-90` | 4 |
| 6 | `DailyPlaylistCache.purge()` | A | `ui/lib/src/daily_cache.dart:209-211` | 3 |
| 7 | `requiresPurchase`(先确认 fee=4 策略) | A | `ui/lib/src/playback_policy.dart:13-14` | 2 |
| 8 | `PROVIDER_NETEASE` | A | `core/crates/ncm-service/src/lib.rs:34` | 1 |
| 9 | `shouldShowBadges`(连带换测试断言) | B | `ui/lib/src/adaptive_text_row.dart:18-27` | 10 |
| 10 | `kPageHorizontalPadding` + `kBrandSeed` | B | `ui/lib/src/layout.dart:31-33` / `theme.dart:44` | 4 |

**合计**: A 级 **48 行** + B 级 **14 行** = **62 行手写删除**(另需改 3 个测试文件)。
若同时清掉 C 级 4 条真死 FFI 再加 **16 行** `api.rs` ⇒ **78 行手写**;
codegen 重生成会顺带减掉约 9 行 `ui/lib/src/rust/api.dart` 声明与对应 `frb_generated` 线缆(自动, 不计入)。
量级: 约为 Dart 手写文件的 0.4% 量级, **不改任何行为** —— 属于"清账"而非"重构"。

### 建议的验证门(现成门禁全跑, 不新增)

```
bash tools/ci-gates.sh verify        # cargo test 313 / clippy 0 / fmt / dart analyze 0 / flutter test 1123 / golden 18 / 4 道 checker / android-lint 0
bash tools/api-coverage.sh           # C 级若动: 仍应报 161 导出, no-ui 名单与"保留清单"一致
bash tools/api-coverage.sh --list    # 未接入 endpoint 仍只有 vip_sign_info(有意弃用)
```

**动 FFI 时额外三步**(项目硬纪律): `flutter_rust_bridge_codegen generate …` → `cargo build -p ncm_ffi` → `flutter test`;
并同步 `docs/api-coverage.md` 与 `docs/PROGRESS.md` 头部表的"6 个无 UI 入口"为实测值 9。

### 提交切分建议(给下一批)

1. **commit-1**: A 级 Rust 3 条(A6/A7/A8) —— 只跑 `cargo clippy/test`, 不动 codegen。
2. **commit-2**: A 级 Dart 5 条(A1/A2/A3/A4/A5) —— 只跑 `dart analyze` + `flutter test`。
3. **commit-3**: B 级 3 条 + 测试断言迁移。
4. **commit-4**(可选, 需 codegen 独占窗口): C 级真死 FFI 4 条 + 文档口径从 6 改 9。
5. **commit-5**(独立 chore): `cupertino_icons` 移除。
6. D1(音量档)/D2/D3 之外的两条 D 级项等产品/真人确认, 不排期。
