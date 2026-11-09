# 进度记录(Progress)

> 最近更新: 2026-11-08 晚(**播放条合并成一行 + 歌曲详情页(分享卡片/翻译开关/歌词多选/定位当前句)**;
> 门禁 `flutter test --exclude-tags network` 351 通过(离线口径, 网络 smoke 单列) / `cargo test` 32+31+106+1 / `dart analyze` 0 error 0 warning /
> Linux+Android 双端构建通过。详见 `docs/ui-song-detail-share.md`)。
> 同日前序: **设置项扩充 R1–R7 全部落地**(精细音量/响度均衡/OLED 纯黑/GitHub 关于页/淡入淡出·硬解·边听边存·缓存上限/AutoEQ 曲线/播放条贴底栏)
> + **D7 frb 直透 domain 车道关闭(57/57)** + 顶部栏去重(任务书按计划日期命名 `docs/plan-2026-11-09-settings-and-player.md`)。
> 更早: 接口覆盖 118/118、FFI 132 个里 3 个无 UI 入口(`cache_stats`/`eq_profile_normalize`/`player_tuning`)、后端轻量化调研、逐字歌词契约、电台/数字专辑/评论统计/等级勋章/搜索增强/黑胶会员/消息增强等。
> 协议细节见 `.pi/skills/netease-cloud-music-api-reverse/SKILL.md`;
> 架构决策见 `docs/architecture-restart.md` §11;M0 清单见 `docs/m0-plan.md`;
> 通道实测见 `docs/api-channel.md`。

## v2 · 2026-11-10: 通知栏快捷按钮 / 响度曲线 GUI / 歌词跟随 / 封面取色 / 热搜开关

| 需求 | 落点 | 证据 |
|---|---|---|
| 通知栏「喜欢 / 播放顺序」 | Kotlin `MediaSession.setCustomLayout` + `onCustomCommand` → `ncm/player` 转发; Dart `Playback.setActionHandlers/setActionState`; main.dart 轮转 列表循环→单曲→顺序→随机→心动 | 模拟器 logcat `custom actions=[Action:mName='喜欢'…, '播放顺序']`; 单测 4 例 |
| 响度均衡确认 | Rust R128 → `replay_gain_db` → Media3 `configure gain` | 模拟器实测: lufs **-13.001**, target -16 ⇒ `configure gain=-2.9989051818847656`(逐位吻合); 另一首 -21.76 ⇒ **+5.76**; `loudness.json` 落盘 |
| 响度曲线 GUI(免导入) | `eq_curve_chart.dart`(对数频响曲线 + 可拖柱) + 首次自动生成 10 段全 0dB 默认曲线; 「清除」→「重置为默认」; 修柱状拖动被 ListView 手势 arena 吞掉的既有 bug | 模拟器: 不导入直接拖 Filter 3 → **+17.4 dB** 写回 `settings.json`(名称变「自定义曲线」), 重置回默认; 新增 20 例 |
| 长歌名竖排/超界 + 详情页字号小 | `MarqueeText`(放不下才横向滚动, 否则普通 Text); 列表行缺 `maxLines` 是竖排根因; 歌词页 AppBar `titleMedium→titleLarge`, 头卡 `→headlineSmall` | `marquee_long_title_test.dart` 5 例(300dp×1.25 单行不溢出 / reduce motion 退化 ellipsis) |
| 歌词 seek 后不跟随 | 暂停判据 `ScrollUpdateNotification→ScrollStartNotification` 的 `dragDetails`; `_seekTo` 无条件恢复跟随 + `_syncLyricIndex(force:true)`; `WordLyricView.didUpdateWidget` 恢复即时回行 | 模拟器: 手动滑歌词→暂停跟随; 拖/点进度条后歌词回当前句并继续跟随; 新增 4 例 |
| 背景色跟随封面 | `cover_palette.dart`(纯 Dart 复刻 node-vibrant: 5bit 直方图 + Vibrant/DarkVibrant/Muted 打分 + 无彩回退 + LRU) + `CoverBackdrop`(300ms 渐变) | 歌词页背景像素随封面变色(粉系封面 → (255,248,247) 而非主题默认); 16 例单测 |
| 搜索「热搜建议」开关 | `showHotSearch`(默认 true) + 设置「通用」开关 + 搜索页不渲染热榜, 留历史/猜你想搜 | 4 例 |

调研: [`docs/research-2026-11-10-lyric-and-color.md`](research-2026-11-10-lyric-and-color.md) —— SPlayer-Next/lyric-dom(AGPL, 只借鉴思路)、node-vibrant(MIT, 算法可移植)、Mei(ljyh223, Apache-2.0)、逐字歌词实现对照。

门禁: `dart analyze` 0 error / 0 warning(40 info) · `flutter test --exclude-tags network` **403 全绿** · `bash tools/build-android.sh` OK。

## v2 · 首个公开预览版 v0.1.0(2026-11-08)

**发布**: tag `v0.1.0` → Release 资产 `MiniNCM-0.1.0-android-arm64.apk`(27.9MB, arm64, release 构建)
+ `MiniNCM-0.1.0-linux-x64.tar.gz`(15MB)+ `SHA256SUMS.txt`;版本号 `pubspec 0.1.0+1` / `kAppVersion 0.1.0`。

**许可**: 根目录新增 `LICENSE`(MIT);`THIRD_PARTY_NOTICES.md` 盘点全部第三方组件
(网易云接口实现 ncm-api-rs = **WTFPL**,其上游 api-enhanced = **MIT**,© 2013-2022 Binaryify;
symphonia = MPL-2.0 未修改;symphonia/qr_flutter 等 BSD-3)并附关键许可全文。

**CI**: `.github/workflows/ci.yml` —— rust 测试(alsa 依赖)+ `dart analyze` +
`flutter test --exclude-tags network`(联网 smoke 打 `network` 标签,`ui/dart_test.yaml`) + Linux bundle 构建;
`.github/workflows/release.yml` —— 打 tag 自动出 arm64 APK + Linux tar.gz 并挂 Release。
首次绿灯记录: CI run `42484875142`(3 个 job 全成功)。

**门面**: 英文 `README.en.md`(中英互链)、CI/License 徽章、`CONTRIBUTING.md`。

**已知限制**: Android APK 仍是 debug 签名(v0.1.0 产物, 无法覆盖升级 —— 已定方案见
[`docs/android-signing.md`](android-signing.md): 固定 keystore + `key.properties`/Secrets 注入,
`versionCode` 用 `tools/bump-version.sh` 递增);Linux 未做 AppImage/deb;
格式检查(`cargo fmt`/`dart format`)未纳入 CI。

## v2 · 播放条合并 + 歌曲详情页(2026-11-08)

用户三条要求一次落地, 详见 `docs/ui-song-detail-share.md`:

1. **播放条两排合并成一排**: 封面 + 曲名/进度 + 喜欢/上一首/播放/下一首(40dp 紧凑点击区);
   播放模式/心动/队列移到详情页底部横条, 行尾 "..." 移进详情页 AppBar。
2. **歌曲详情页**: 右上角分享 + 翻译开关(仅 tlyric 存在时) + "..."; 歌词长按进多选并分享所选;
   右下角一键定位当前句; 手指拖动即暂停跟随(`dragDetails` 判定)。
3. **分享**: `src/song_share.dart` 卡片(封面/曲名/歌手/专辑/歌词/二维码) → RepaintBoundary 导出 PNG;
   Android 自建 `ncm/share` 通道(FileProvider + clipData + ACTION_SEND; 保存走 MediaStore),
   桌面落 `~/Pictures/MiniNCM`; 二维码依赖 `qr_flutter`(纯 Dart)。

门禁: `flutter test` 通过(本轮新增 11 例; 当时数字含 network 标签用例, 离线口径见 2026-11-09 小节 = 351) / `dart analyze` 0 error 0 warning;
a34 模拟器实测通过(翻译开关 / 多选分享 / 保存 680x628 PNG / 系统分享面板 / 定位当前句)。

## v2 · 设置项扩充 + 播放体验修复(R1–R7)与 D7 收尾(2026-11-09)

任务书: `docs/plan-2026-11-09-settings-and-player.md`(§10 有逐批执行记录);
FFI 车道: `docs/d7-frb-domain.md`(车道已关闭)。

### 1. 七项需求全部落地

| # | 需求 | 落点 | 证据 |
|---|---|---|---|
| **R1** | 推荐页两排封面 overflow | `recommend_view.dart::_CoverRow` 外层 `height*2` 少算 4px 行间距 → `height*2+4` | `s1_two_row_overflow_test.dart`(先复现 `overflowed by 4.0 pixels` 再转绿) |
| **R2** | 设置里精细音量(dB) | `PlaybackTuning.gain_db`(Rust) + Media3 `configure*gainDb`(Android) | a36: `configure gain=-12.0` 实测生效 |
| **R2b** | 曲间音量平衡(响度均衡) | Rust 自实现 BS.1770-4 `LoudnessMeter` + `loudness.json` 缓存 + `replay_gain_db` 叠加到增益 | a36: 播 20s 后测出 `lufs=-7.33` → `configure gain=-8.67`(target −16) |
| **R3** | 「关于」给 GitHub 网址 | `src/app_meta.dart` + 设置页「开源仓库/版本与许可」, 走 `PlatformBridge.openUrl` | `s2_about_page_test.dart`(含 `ncm/open` 通道 mock 断言 URL) |
| **R4** | 播放条与底栏之间的空白 | 播放条自己的 `SafeArea` 又吃一次 bottom inset(`NavigationBar` 内部已有) → `SafeArea(bottom:false)` | a36 像素 A/B: 空白 **115px → 52px**, 差值 63px = 24dp 手势 inset |
| **R5** | 淡入淡出 / 硬解 / 音质 / 边听边存 / 缓存上限 | 淡入 `fade_in(ValueAnimator)`; 硬解 `MediaCodecSelector` 过滤非硬件 codec; `SimpleCache`+`LeastRecentlyUsedCacheEvictor`; `AudioCache::enforce_limit`(Linux, 保护正在播文件) | a36: `cache/audio` 落盘 10MB; `configure ... cache=true limit=256MB` |
| **R6** | OLED 纯黑 | `src/theme.dart::buildDarkTheme(oled:)`, surface 系列压 `#000000`、onSurface `#E6E6E6` | a36 像素采样: 页面/卡片/底栏/状态栏全 `(0,0,0)`; 关闭前 `(35,25,25)` |
| **R7** | 响度均衡 + AutoEQ 曲线导入导出 | `ncm-domain::EqProfile`(权威解析/序列化, 带行号错误) + `ncm-playback::biquad`(RBJ PK/LS/HS) + `AudioProcessor`(Android) + Dart `eq_profile.dart`(导入即时校验) | 「播放与音质」二级页 5 组控件, 曲线导入/导出/清除 + 20 例测试 |

### 2. 车道与提交(13 个 commit)

| 车道 | 内容 | 提交 |
|---|---|---|
| S1 | R1 修复 + 回归用例 | `dd175cf` |
| S2a + 编排者 | R3 关于页 / R6 OLED 主题与开关 / R4 播放条贴底栏 | `7a9cdcc` / `ad463ad` |
| S4 批1 | 曲线解析 + biquad + R128 + 缓存 LRU | `b3bcf55` |
| S4 批2 | 流式 LoudnessMeter + LoudnessStore + FFI 契约 + Dart 接线 | `f073a9b` |
| S5a | 「播放与音质」设置页 + 曲线导入导出 | `c6ea894` |
| S3 | Android Media3: 精细音量/淡入/硬解/边做边存/EQ AudioProcessor | `5504fad` |
| 编排者 | R2b 手机端闭环(Media3 缓存文件 → Rust 测量) | `c57387c` |
| AGC | 动态限速 <=3 dB/s 接到 Rust 与 Media3 | `67fbd03` |
| 编排者 | 顶部栏去重(四 tab 无 AppBar) + 搜索页去横幅 | `30065cf` / `7dd3bf7` |
| D7 批4+5 / 批6 | 搜索·播客·电台 17 个 + 数字专辑·VIP·私信 19 个 Dto 直透 domain | `0ff7f78` / `79729c2` |

### 3. 顺带完成与口径变更

| 项 | 结论 |
|---|---|
| **D7 车道关闭** | `#[frb(mirror)]` **57 个**, `api.rs` 2500→**2324 行**; 剩余 21 个 `*Dto` 全属必须保留(16 个 (b)/(c) + 5 个 S4 新增 FFI 投影) |
| **顶部信息架构** | 五个 tab 首页全部无 AppBar(标题与底部导航重复); 搜索页去掉「轻音 MiniNCM」横幅; 歌词/歌单浏览态保留顶部栏; a36 实测首行上移 147px≈56dp |
| **APK ABI** | `tools/build-android.sh` 改为只出 `arm64 + x86_64`: `armeabi-v7a` 在当前 rustc+NDK lld 下链接失败(`.debug_aranges unsupported compression type (44)`), 与业务代码无关 |
| **R2b 两个真 bug** | ①缓存 key 用 http 直链而播放时升级 https ⇒ SimpleCache 永远命中不了; ②未测到时把 0 dB 写进增益缓存被当成"已测" ⇒ 补测再也不发生。**两个都只能靠 adb 实测发现** |

### 4. 收口门(编排者独立重跑)

| 命令 | 结果 |
|---|---|
| `cargo build --offline --workspace --all-targets` | 0 error / **0 warning** |
| `cargo test -p ncm-domain -p ncm-playback -p ncm-service` | **32 + 31 + 106** 全绿(起点 22 + 0 + 97) |
| `cd ui && dart analyze` | **0 error / 0 warning**(39 条历史 info) |
| `cd ui && flutter test` | **351 passed + 1 skip**(起点 309 + 1) |
| `bash tools/build-android.sh` | 0 error, a36 安装启动、五 tab 切换无崩溃 |

### 5. 剩余(仅真机听感验收)

1. 动态响度(`loudnessDynamic`)开关下增益应按 <=3 dB/s 平滑过渡而非瞬跳;
2. EQ 极端正增益曲线是否可听出削波(只做样本级 [-1,1] 限幅, 无 makeup gain);
3. 淡入时长手感(缓冲比 fadeMs 长时首句没有淡入);
4. 响度均衡开/关 A/B;
5. 硬解关闭后各格式仍能出声(MediaCodecSelector 用"过滤非硬件 codec"而非 `emptyList()`)。

## v2 · 后端精简与体量实测(2026-11-09)

| 项 | 状态 | 证据 |
|---|---|---|
| 产物体积 | 📄 已测 | release `libncm_ffi.so` 13.6 MiB → **strip 后 8.6 MiB**; debug 215 MiB; Linux debug bundle 304 MB; APK(debug, 4 ABI) **231.8 MB**, 其中 Rust 只占 arm64 16.4 MB(7%), `libflutter.so`×3 = 118 MB + `kernel_blob` 46.6 MB + Vk validation 15.2 MB ⇒ **包体大头是 Flutter 运行时/debug 配置, 不是协议库** |
| 运行时占用 | 📄 已测 | Linux debug bundle(Xvfb, Impeller)首帧后 **RSS 555 MB / 84 线程**; Rust core release CLI 单次 search **峰值 8.7 MB**, wall 0.52 s ⇒ core 侧 MB 级, UI 侧大头是 debug 未 AOT |
| 构建产物占地 | 📄 已测 | 仓库 27 GB 中 26.9 GB(99.6%)是产物: `ui/build` 18 GB(`rust_lib_minincm` 单目录 12 GB) + `core/target/debug` 8.9 GB; 源码+文档+参考仓 ≈55 MB |
| §3 P3 门判定 | ✅ 已定 | 门槛「strip 后 vendor 相关代码 >5 MB 才考虑方案 c」——整个动态库也才 8.6 MiB ⇒ **门未通过, 自写最小客户端仍不推荐** |
| 新候选 `netease-music` 0.1.1 | ⛔ spike 结论: 暂不切 | src **2,448 行**, 依赖 **132 包**(↓81), 搜索/歌词与现实现**完全一致**, Android 交叉编译配 NDK 即过; 但取链匿名态两端都被风控(ncm 404 / crate -460)、**身份每进程随机需自建回灌层**、appver 形态更粗、43/118 封装落差 ⇒ 净收益仅「少 2.4k 行加解密」。门槛与复测清单见 `docs/backend-service-options.md` §6 |
| **P1+P2 裁剪** | ✅ 已做(2026-11-09) | vendor endpoint **382→118**(未接入 **0**, 100%)、LOC **12,035→4,069**(−66%)、体积 1.7 M→564 K、`api/mod.rs` 566→252 行; `tokio` 从 vendor 直接依赖**整体移除**(库本体不用), 死特性 `server`(axum/bin/5 个可选依赖)一并删除; 依赖数 **213/279/257 → 207/274/252**; 冷编 vendor **1.40→0.65 s**; release `.so` 14,246,736→**14,157,856**(strip 8,971,728→**8,918,104**); 门禁: `--all-targets` 0 error + **119** 测试全绿 + coverage 118/0。详见 `docs/backend-prune.md` |
| 收益排序 | 📄 结论 | 打包配置(release + split-per-abi, 231 MB→约 30–40 MB/ABI) > Rust 依赖瘦身(~~P1 裁 vendor / P2 tokio~~ ✅已完成) > 方案 c |

详细数据与测量命令: `docs/backend-service-options.md` §5–§6。

### 附带: API/实现重叠审计(只读, `docs/api-overlap-audit.md`)

| 结论 | 证据 |
|---|---|
| 代码已高度去重 | 语义重叠多为"同名不同义", provider 已用 `comments(kind)`/`by_area` 等 enum 合并; **无重复 friendlyError**(错误映射集中在 `netease.rs:329` `map_error/map_code/check_body/take_body`, 全文件仅 5 处直接构造 `ProviderErrorKind::*`); **无 >200 行函数**(最大 `parse_feed_events` 120 行, 318 个函数中 191 个 <20 行); **Capability 实为 35 个**(`ncm-provider/src/lib.rs:30`), 之前口头引用的 47 是 `Capability::` 出现次数不是枚举项数 |
| 口径脚本 bug 已修 | `tools/api-coverage.sh` 的 camel 匹配大小写敏感 ⇒ `lyric_lines_i18n`(`lyricLinesI18N`, 大写 N, `main.dart:875` 在用)被误报; 已改小写化比对, 真实**死导出 = 2**(`search` `api.rs:160` / `lyric_lines` `api.rs:607`, UI 调用均为 0) |
| 可精简收益 | 保守 ~430–670 行(FFI 死导出 + Dart 样板 + 文档); 激进 D7(frb 直接透传 domain DTO, 删 74 个 Dto ≈646 行 + 内联转换 ~400 行)可达 ~1400–1800 行, 但需给 domain 加 frb 注解 + 双端全量回归, **排在 vendor 裁剪之后另开车道** |
| 无应删写接口 | follow/like/playlist_edit/comment_delete/reply/sign_in 全部有 UI 入口且在用 |

### 附带: UI/UX 走查(只读, `docs/ui-ux-audit.md` 506 行)

页面级质量不差(17 个二级页均有 AppBar 返回、删除类操作都有确认),但有三类结构性问题:

| 级别 | 条目 | 证据 |
|---|---|---|
| **P0(3)** | ①**返回键语义完全没做**: 全仓 `PopScope/WillPopScope` = **0** 处 ⇒ 歌词页/非首 tab 按系统返回直接退出 App; ②**评论区无「写评论」入口**(只有 `CommentReplyHook` 与 `rust.replyComment`, 无输入框); ③**播放队列零 UI**(`queue.dart` 只有 `PlayQueue<T>` 数据结构, 播放条仅显示 `inQueue/len` 序号) | `rg PopScope ui/lib`=0; `comment_thread.dart` 无 TextField; `queue.dart:23` 仅数据类 |
| **P1(15)** | 歌曲行时长显示 `245s`(`song_tile.dart:147` 直接 `durationMs~/1000`+s)、红心指示器不可点但歌单详情同款可点、专辑详情用 Dialog 无返回、分页全靠按钮无自动加载、8 页无下拉刷新、6 类高频控件 <48dp、播放条 168dp 占屏 39%、评论标题必溢出、底部安全区缺失 | 逐条 file:line 见报告 §7 |
| **P2(13)** | 6 处错误态各写一份、6 份 SnackBar、5 份时长格式化、弹层 4 种标题写法、0 处 `Semantics`、深色 2 处硬编码、~~`podcast.dart` ~300 行死代码~~(实测**整文件非死代码**, 真正零调用的只有 `showPodcastSheet`+`_PodcastBrowser*` 约 88 行且被 10 处测试占用)、300dp 回归只覆盖 15/45 测试文件 | 同上 |

**结构事实校正**: 底栏实际是 **5 栏**(搜索/推荐/关注/我的/**设置**), 不是 README 长期写的 4 栏 —— 已在 README/AGENTS 校准。
Top5 速修与 A–D 批次切分见 `docs/remaining-batches.md` §10。

### 第二波已落地批次(2026-11-09, 4 条车道并行 + 编排者独立复核)

| 批次 | 结果 | 关键证据 |
|---|---|---|
| **D1+D2+D5** FFI 清理 | ✅ | 删死导出 `search`/`lyric_lines`(+ `SearchResultDto`): 导出 **125→123**、**「UI 没有入口」3→0**; 新增 `ffi_forward!` 宏(直转/`map`/`map_each` 三分支)收敛 **22** 个转发封装, `api.rs` 净 **−80 行**; release `.so` 14,157,856→**14,068,144**(strip 8,918,104→**8,880,312**) |
| **D6** 列表三态抽象 | ✅ | 新 `paged_list_view.dart`(`loader(cursor)` 注入 + `PagedPage{items,hasMore,nextCursor}` + `keyOf` 去重 + grid/list 双模式 + 加载更多失败保旧数据), 迁移 **4 页**(user_list/messages 私信/playlist_square/ranking_view), 新增 8 用例 |
| **A** UI 速修 | ✅ | `HomeBackAction` 纯函数 + `HomeBackGuard(PopScope)`(优先级: 歌词>非首 tab>歌单浏览>交还系统); `formatSongDuration`(245s→04:05); 红心改可点 `IconButton`; 6 类高频控件提到 **48dp**; 出口文案统一「全部」; 新增 **22** 用例(含 7 条 `handlePopRoute()` 驱动的三级返回键测试) |
| **B** 缺失面板 | ✅ | 评论可发: 底部「写评论…」→ `_ComposeSheet`(空文本/发送中禁用、失败保草稿可重试、`viewInsets` 键盘避让、乐观插入按对象身份回滚), 走 `CommentSendHook` 复用 `rust.replyComment`(commentId=0), **零新增 FFI**; 播放队列: `PlayQueue` 补 `removeAt`/`moveTo`(`main.dart` 播放条 → `PlayQueueSheet`, 高亮/跳播/滑删+长按删确认/空态, 删当前项自动播下一首、删空 stop); 新增 **18** 用例(全离线注入) |
| **D** 技术债收敛 | ✅ | 新增 `format.dart`(时长, 收编 4 份实现/6 调用点)、`error_views.dart`(3 页 7 处)、`toast.dart`(收编 10 处 SnackBar); 弹层 8 处补 `showDragHandle` + podcast 自绘头部改走 `SheetHeader`(新增 trailing 槽); 5 页补底部 SafeArea; 净 **−98 行**; 新增 7 用例。**勘误**: 审计"podcast.dart ~300 行死代码"为误判(整文件非死代码, 真死点是 `showPodcastSheet`+`_PodcastBrowser*` ≈88 行且被 10 处测试占用) |
| **B2** 键盘遮挡 | ✅ | `showCommentsSheet` 根节点补 `viewInsets.bottom` padding + 高度 `max(200, 75%屏高−insets)`(只加 padding 不改高度会留白), 收起自动回弹; 顺带给该弹层加可选 hook 注入以便离线测键盘; 新增 4 用例 |
| **D6b** 继续迁移 | ✅ | `new_release`(4 页签)/`all_charts`/`digital_album` 迁到 `PagedListView`, 净 **−271 行**, 未改被锁定的组件; `radio_explore`/`style_page` 因「多 section 内嵌三态」需先给组件加能力, 已列建议 |
| **C** 信息架构重排 | ✅ | 设置瘦身为 3 组 + 2 个二级页(`settings_account_page`/`settings_diagnostics_page`); 账号入口 **3→1**(统一到「我的」, 未登录显示引导); 推荐页首屏 **8→5 区块**(合并日推歌曲+歌单/新歌+新碟, 风格推荐下沉榜单 chips); 专辑详情 **Dialog→全页**、日推/最近听过 **sheet→全页**; 新增 11 条可达性用例, 6 处断言随结构调整改写(0 删除); 视觉待人工过目清单见 `docs/ui-batch-c.md` §7 |
| 收口门(编排者重跑) | ✅ | 全量 `flutter test` **305 passed + 1 skip**(skip 为既有网络 smoke); 用例声明 **235→289 只增不减**(改写 3 处断言语义: playlist_square 触底自动加载、recommend_view 更多→全部、frb smoke search→searchAll); `dart analyze` **error/warning = 0**; `cargo build --workspace --all-targets` 0 error; 119 Rust 测试全绿 |

## v2 · 功能包: 收尾 Wave9(§4 接口 + 电台缺口 + 后端形态调研)(2026-11-09)

| 能力 | 状态 | 证据 |
|---|---|---|
| 最新专辑(UI) | ✅ | 新碟上架「更多」→ 新增第 4 页签「精选新碟」: 12 张封面网格(注入式 loader), 点卡走专辑预览 |
| 全部榜单(UI) | ✅ | 推荐页「排行榜 → 全部」→ `all_charts_page.dart`: 7 组(置顶/官方/特色/曲风/全球/语种/更多)封面卡 + 更新频率; `canPlay=false` 灰显不可点; 点条目直接进歌单详情(榜单即歌单) |
| 最新专辑 | ✅ | `album_newest`: **不是 album_new 的重复**(固定 12 张编辑精选、无 total、id 集合与前 5 完全不同) → `newest_albums`(Capability::NewRelease) + FFI + CLI `ncm album-newest` |
| 榜单 v2 | ✅ | `toplist_detail_v2`: **没有 v1 的 trackUpdateTime 数字字段**,"更新 N 首/刚刚更新"只混在 `updateFrequency` 文案里;真正增量是 categoryCode 分组(7 组 45 榜)+ `canPlay` → `ToplistCatalog` + FFI + CLI `ncm toplist-v2` |
| MV/视频评论 | ✅ | `comment_mv`/`comment_video` 与歌曲评论**同形**(`R_MV_5_`/`R_VI_62_`),直接复用 `parse_comments`/`CommentPage`; provider `comments()` 新增 kind `mv`/`video`;实测 `comments mv 5436712` total=689 |
| 相似用户 | ⛔ 不做 | `simi_user` 登录态下 id/userId 两种参数、多个 uid 实测**恒回空数组**(`userprofiles: []`),无可解析形状,已记档 |
| 电台节目榜 | ✅ | 电台广场新增「节目」页签(`radioToplist(kind:'program')`: 排名 badge + 节目名 + 电台·主播·时长);点行直接播放(无音频回落电台详情) |
| 电台听众页 | ✅ | 新 `radio_subscribers_page.dart`: 电台详情 AppBar「听众」→ 列表(头像/昵称/签名), **时间游标真分页**(provider/FFI 新增 `time_ms`, 用上一页最后一条 subscribeTimeMs), 空态/错误重试/去重 |
| 后端形态调研 | 📄 | `docs/backend-service-options.md`: 结论 **不换形态、只裁剪** —— vendor 12,035 LOC/382 endpoint 我们只用 118(31%),但 vendor 边际依赖为 **0**(213-crate 服务树差集为空)、单独重编译仅 1.3s ⇒ 不是编译/依赖瓶颈;延迟 search 中位 0.39s、detail 0.14s;体积大头是 reqwest/tokio/rustls 网络栈,换方案也省不掉 |
| 回归 | ✅ | Rust service **102** 单测(收尾 +6, 游标改动后全绿); Flutter **231** 用例; `tools/ci.sh` → **CI OK**; a36 独立走查: 节目榜页签/节目播放/听众列表真实数据 |

**协议/实测事实**:
- `album_newest` 响应 `{code, albums[12]}`,专辑对象与 `album_new` 同构;无 total、无分页。
- `toplist_detail_v2` 响应 `{code, data:[{categoryCode, list:[{id,name,coverUrl,updateFrequency,targetType:"PLAYLIST",canPlay}]}]}`,
  分组顺序 TOPPING/OFFICIAL/FEATURE/MUSIC_STYLE/GLOBAL/LANGUAGE/MORE;个别条目 `id=0` 且 `canPlay=false`。
- `comment_mv`/`comment_video` 与歌曲评论同形, 只有 thread 前缀不同; video 的测试 id 可能 200+空。
- `dj_subscriber` 的 `time` 参数是**上一页最后一条 subscribeTime(ms)**, 首页传 -1。
- 详细样例见 `docs/wave9-endpoint-notes.md`; 后端形态测算见 `docs/backend-service-options.md`。

## v2 · 功能包: 逐字歌词契约 B5-1 + 列表页空态统一(2026-11-09)

| 能力 | 状态 | 证据 |
|---|---|---|
| 逐字歌词 UI | ✅ | `word_lyric_view.dart`: 逐字(karaoke)着色(已唱 primary / 未唱 55% 不透明)+ 行级自动滚动; 数据流改为注入 `List<WordLyricLineData>` + `ValueListenable<int> positionMs`, 组件不碰 FFI; 只有当前行随 tick 重建(其余行静态 RichText + RepaintBoundary), 换行才通知整列表 |
| 逐字回归 | ✅ | Flutter 215→**223**(+8: 三时间点词级推进/行滚动/无逐字回落/空态/300dp+1.25/含标点词文本/销毁后无残留监听/纯逻辑 `wordStylesAt`); a36 实测: Lonely(Nana, 有 yrc) 放大截图可见「Usin' our」已唱红色、「hands to buy and supply」未唱灰色; 纯音乐曲目正确回落行级 |
| 逐字歌词契约 | ✅ | `lyric_new`(`/api/song/lyric/v1`, vendor 写死 yv=0 就回 yrc) → domain `WordLyric/WordLyricLine/WordItem` + `parse_word_lyric`; provider `word_lyric`(复用 `Capability::Lyric`) + FFI `word_lyric_lines` + CLI `ncm yrc <id>`; UI 由 B5-2 跟进 |
| 退化策略 | ✅ | 逐字头坏 → 整行退化为单个整词(start/end=0)；JSON 署名行保留为单词行；缺 yrc → 空结果不报错；`has_word_timing` 全退化时为 false 供 UI 回落 |
| 列表页口径 | ✅ | ranking_view 整页首屏失败 → 整页错误视图(重试) 并修掉 `setState(() => _future = _load())` 返回 Future 的断言隐患; style_page 下拉刷新失败保留旧数据(改 SnackBar); album_preview 空曲目空态; user_list_page 空态补可操作提示 |
| 回归 | ✅ | Rust domain 9→**22**(+13) / service 89→**92**(+3); Flutter 203→**215**(+11 列表页三态与 300dp); `dart analyze` 0 error; `tools/ci.sh` → CI OK |

**协议/实测事实(YRC)**:
- 端点 `lyric_new`;旧 `lyric` 永远没有 yrc。两种行混排:署名 JSON 行 `{"t":0,"c":[{"tx":"作词: "},...]}`(t 可为负)
  与逐字行 `[行start,行dur](词start,词dur,0)字(...)字`;词文本可含空格/标点, 词时长可为 0。
- **`ytlrc`/`yromalrc` 抽样 8+ 首恒空**(vendor body 写死 ytv/yrv=0, vendor 禁改) ⇒ 逐字级翻译暂时拿不到,
  翻译只能用行级 `tlyric`;要 yrc 级翻译需上游开参数口。
- 老歌(如 晴天 186016)无 yrc;UI 必须保留整行滚动回落。
- 详细样例与门禁记录见 `docs/b5-word-lyric-notes.md`。

## v2 · 功能包: 电台只读 B10 + 设置页通道自检(2026-11-09)

| 能力 | 状态 | 证据 |
|---|---|---|
| 电台广场 | ✅ | 推荐页「推荐播客 → 更多」: 分类胶囊(19 分类) + 精选分组(dj_category_recommend, 每组 3 个) + 推荐电台(dj_recommend_type, 真实分类 id 才给数据) + 热门榜(rank/score). 点行复用 `showPodcastDetail` |
| 榜单族 | ✅ | `dj_toplist`(电台榜, 顶层 `toplist`, 元素带 rank/score/lastRank) / `dj_toplist_hours``newcomer``popular`(**主播榜不是电台榜**) / `dj_toplist_pay`(付费精品, 电台) / `dj_program_toplist`(节目榜) |
| 主播 | ✅ | `dj_subscriber`(顶层 `hasMore`+`subscribers`, 游标是 time 不是 offset); CLI `ncm radio-sub` |
| CLI | ✅ | `ncm radio-cats` / `radio-rec` / `radio-top <type>` / `radio-sub <id>`; raw 补 10 个接线 |
| 通道自检 | ✅ | 设置页「诊断 → Rust 通道自检」: 调 FFI `ping`, 显示耗时与返回值, 失败给 friendlyError 可重试, 防重入; 补上「FFI 有导出但 UI 无入口」的 ping 缺口 |
| 回归 | ✅ | Rust `ncm-service` 83→**89** 单测(+6); Flutter 192→**203** 用例(+6 电台页 / +5 自检); `dart analyze` 0 error; 双端构建通过; a36 走查: 入口/分类切换/榜单/详情跳转/断网错误态+重试 |
| 环境坑 | ⚠️ | 本机 `flutter analyze` 稳定 SIGSEGV(analysis server 并发标记 GC 崩), 清缓存/删 `~/.dartServer` 均无效 ⇒ analyze 门改用 `cd ui && dart analyze`, `tools/ci.sh` 会停在 analyze 步, 其余步骤手工补跑(见 FAILURES 2026-11-09) |

**协议/实测事实**:
- `dj_catelist`(`/api/djradio/category/get`)顶层直接 `categories`, **没有 code 字段**; 19 个分类。
- `dj_recommend_type`(`/api/djradio/recommend`)的 **type=0 返回空 `djRadios`**(文档口径差异), 必须传真实分类 id
  (如 2001); 响应带 `hasMore`。
- `dj_toplist_hours/newcomer/popular` 实测是**主播(用户)榜**, `data.list[]` 是 `{nickName, avatarUrl, score,
  userFollowedCount}`; 只有 `dj_toplist`/`dj_toplist_pay`/`dj_program_toplist` 是电台/节目。
- `dj_subscriber` 分页游标是**时间戳**, 不是 offset; 返回完整 user 结构。
- `dj_toplist` 元素的推荐语字段名是小写 `rcmdtext`(与其它接口的 camelCase 不一致)。
- 详细响应片段见 `docs/b10-radio-notes.md`。

## v2 · 功能包: 数字专辑只读 B12 + 纯 Dart 车道(2026-11-09)

| 能力 | 状态 | 证据 |
|---|---|---|
| 已购数字专辑 | ✅ | `digital_album_purchased`: 顶层 `paidAlbums`+ `total`(**无 data 包装**); 实测 2 张(伍六七原声大碟 / 冀西南林路行), 行显示 歌手·份数·购买日期 |
| 专辑详情 | ✅ | `digital_album_detail`: 字段在 `album`(albumId/albumName/artistName/coverUrl) + `product`(price/pubTime/tags/descr); `descr` 的 `</br>` 要过滤; BottomSheet 显示 ¥15.0 · 独家/无损 → 销量 2.0万 + 简介 |
| 销量 | ✅ | `digital_album_sales` 实际端点 `/api/vipmall/albumproduct/album/query/sales`, 入参键 **`albumIds`**; `data` 是 **{专辑id串: 销量} map**(实测 `{"120605500":1300053}`), 不是数组 |
| 已购单曲 | ✅ | `song_purchased` = `/api/single/mybought/song/list`, `data.{count,hasMore,list}`; 本账号 list 为空(DTO 兼容 id/songId 两种命名) |
| 入口 | ✅ | 「我的」→「数字专辑(只读)」(`widget.loggedIn` 过滤, 未登录不显示); 下单接口 `digital_album_ordering` **不做** |
| 播客单集详情 | ✅ | `podcast_program`: 节目行新增 ⓘ 按钮(有/无音频都给), 弹层拉完整简介 + 「播放本集」; 列表弹层与全页(`detail_page.dart`)两条路径都接 |
| 错误文案统一 | ✅ | main/discover/song_actions 里 7 处裸 `'$e'` 改为 `friendlyError(e)` 并补语境前缀(登录失败/切换账号失败/退出登录失败/收藏失败…) |
| 回归 | ✅ | Rust `ncm-service` 78→**83** 单测(+5 数字专辑); Flutter 181→**192** 用例(+5 digital_album_page / +6 program_detail); analyze 0 error; `tools/ci.sh` → **CI OK**(vendor smoke 8/8); a36 走查: 我的页入口/已购列表/详情弹层/节目详情弹层 |

**协议/实现事实**:
- `digital_album_purchased` 与 `song_purchased` **匿名会报 auth 错** → UI 用 `loggedIn` 过滤入口, provider 侧仍保留 auth 错误映射。
- `digital_album_sales` 的 vendor 入参键是 `albumIds`(CLI query 键名 `ids`); 返回 map 而不是列表, 解析要按 albumId 字符串查。
- `digital_album_detail` 的 `product.saleNum` 恒 0, 真实销量只能走 sales 接口。
- 详细真实响应片段见 `docs/b12-digital-album-notes.md`。

## v2 · 功能包: 评论统计 B2(comment_info_list)(2026-11-09)

| 能力 | 状态 | 证据 |
|---|---|---|
| 统计条 | ✅ | 评论区标题下方一行「💬 评论 197万 · 分享 11万 · ❤ 点赞 352」; 数据来自 `comment_info_list`, 加载失败/无数据时**整条不显示**(不打扰用户) |
| 资源类型 | ✅ | 歌曲/歌单/专辑/播客/视频共用 `split_thread_id` 反解 type; **动态(A_EV_2_…)不支持**, 直接 unsupported |
| 数字格式 | ✅ | 组件内 `formatCompactCount`: <1000 原样 / 千 / 万(一位小数去 `.0`); 300dp + 1.25 字号不溢出, 每项 Flexible + FittedBox |
| CLI | ✅ | `ncm comment-info <song|playlist|album|podcast|mv|video> <id>`; 实测歌曲 186016 = 评论 1969911(100w+) / 分享 109723 / 点赞 352 |
| 回归 | ✅ | Rust `ncm-service` 75→78 单测全绿(+3: 实测形状 / data 缺失空数组兼容 / 四种资源同形); Flutter 174→181 用例全绿(+7 统计条); analyze 0 error; codegen 一次 + `cargo build -p ncm_ffi`; a36 走查 |

**协议/实现事实**:
- `comment_info_list`(`/api/resource/commentInfo/list`, weapi)入参是 **`type`(资源类型数字)+ `ids`(逗号分隔)**,
  **不是 threadId** —— 传 threadId 只会拿到 200 + 空数组(最容易踩的一条)。
- 响应 `data` 是**数组**(一个 id 一项): `{commentCount, commentCountDesc, commentUpgraded, comments,
  latestLikedUsers, liked, likedCount, musicianSaidCount, resourceId, resourceType, shareCount, threadId}`。
- **没有 `subscribedCount`(收藏数), 也没有 `hotCount`(热评数)** —— 官方文档里有字段但实测不回,
  UI 不要为这两个补占位; 歌单收藏数仍取 `PlaylistDetail`。
- `likedCount` 是**这条评论线程整体被点赞数**(歌曲 186016=352); `resourceType` 是服务端归一后的子类型
  (歌曲=4/专辑=3/歌单=0/播客=1/视频=62), **与请求的 type 数值不同**, 不要拿它当入参, `threadId` 才是权威。
- `commentCountDesc` 是官方展示文案("100w+"/"999+", 少评论时为空串); 我们仍用自己算的紧凑数字
  (197万), 文案字段留给需要"官方观感"的地方。

## v2 · 功能包: 等级/勋章 B8(user_level / user_medal)(2026-11-08)

| 能力 | 状态 | 证据 |
|---|---|---|
| 等级 | ✅ | `user_level`: Lv.9 / 听歌 2301/12000 / 登录 350/350 / 进度 19.18%; **进度按听歌数算**(不是成长值), 权益文案 `$` 分隔 |
| 勋章墙 | ✅ | `user_medal`(uid 必填): 5 分类 200 枚(已获得 157 / 进行中 16 / 未开始 14 / 即将获得 13); 未获得灰显仍占位 |
| 入口 | ✅ | 我的页「等级与勋章」→ 勋章墙: 顶部等级卡(LevelBadge Lv.9 + 进度 2301/12000) + 每行 3 枚勋章网格, 下拉刷新 |
| 限流处理 | ✅ | `/api/medal/user/page` 服务端限流很严(连打 5 次只通 2 次); provider 做有界重试(1.5s/3s 退避, 业务错不重试), 实测 5/10 → 9/10 |
| CLI | ✅ | `ncm level` / `ncm medals`; raw 补 `user_medal` 接线(`ncm raw user_medal uid=<uid>`) |
| 回归 | ✅ | Rust `ncm-service` 70→75 单测全绿(+5: 等级映射/缺 data/空勋章/勋章映射/medalNum 兜底跳坏条目); Flutter 174 用例全绿(medal_wall 11 + 映射 3); analyze 0 error; codegen 一次 + `cargo build -p ncm_ffi`; `tools/ci.sh` → CI OK; a36 走查: 我的页入口 + Lv.9 等级卡 + 200 枚勋章网格 |

**协议/实现事实**:
- `user_level`(`/api/user/level`): `data={level,nowPlayCount,nextPlayCount,nowLoginCount,nextLoginCount,progress,info,userId}`;
  `progress` 是 0..1 的听歌进度(2301/12000=0.19175), 没有等级名(等级名只在 `vip_growthpoint` 里)。
- `user_medal`(`/api/medal/user/page`, eapi) **uid 必填**(空串 → `code=499`); 唯一数据源是
  `data.categoryMedalBlockVos[].medalVOS[]`, `data.obtainMedals[]` 是其中已获得的那部分(重复解析会翻倍计数)。
- 勋章 `status` 四态: `OBTAIN` / `NOT_OBTAIN_PROCESS` / `NOT_OBTAIN_NO_PROCESS` / `WILL_OBTAIN`;
  `medalNum` 与 `OBTAIN` 枚数、`obtainTime != null` 枚数三者一致(以 status 为准)。
- 易踩字段: `medalCode` 是字符串; `progress`/`rankText`/`levelTitle` 本身是文案字符串(非数字); 徽章图 http/https 混用。
- 勋章接口**限流在服务端**, 与客户端并发/是否先打 user_level 无关: 连打必被 reset, 隔 ≥10s 才稳。
  → UI 侧不要为"勋章枚数"再单独请求一次(已移除多余 FFI), 直接用列表长度。

## v2 · 功能包: 搜索增强 B4(精确实体 / 关键词联想 / 热搜榜)(2026-11-07)

| 能力 | 状态 | 证据 |
|---|---|---|
| 精确实体条 | ✅ | `search_multimatch` → `search_exact`: 搜索框输入后在联想上方显示「精确匹配」分区(歌手圆形头像 / 歌单 / 电台); 实测输入 `Taylor Swift` 出「歌手 Taylor swift + 电台」, 点歌手卡片进歌手页 |
| 空命中判定 | ✅ | multimatch 的"空命中伪装成功"(`code=200 + orders:[]`)按 `orders.isEmpty()` 当无命中, 不渲染也不报错 |
| 关键词联想兜底 | ✅ | `search_suggest_keywords`(mobile, `type=mobile`) → 卡片与实体都空时显示「猜你想搜」chips; 纯关键词串 6 条, 去重保序 |
| 热搜榜 | ✅ | `search_hot_detail`(`/api/hotsearchlist/get`)固定 20 条, **服务端不给 rank**, 榜位按数组下标推导; 搜索落地页热门榜改用它, 失败回退 `search_hot` |
| CLI | ✅ | `ncm exact <kw>` / `ncm suggestkw <kw>` / `ncm hotdetail`, 另给 raw 分支补了 `search_hot_detail` 接线 |
| 回归 | ✅ | Rust `ncm-service` 65→70 单测全绿(+5 组: 关键词去重/空 result/缺 keyword、exact 有命中与假成功、hot_detail 榜位字段); Flutter 157→160 用例全绿(search_exact_bar 7 + 关键词条 1); analyze 0 error; `tools/ci.sh` → CI OK; a36 走查: 精确匹配分区、点卡片进歌手页、无命中空态 |

**协议/实现事实**:
- `search_multimatch` 只回"精确实体改写"(每类最多 1 条, 无分页无高亮), 且 `晴天`/`Taylor`/`Chinese Football` 都是 `orders:[]` 的"假成功";
  `type` 参数实测无效。它不能当多类型匹配数据源 —— 多类型卡片仍走 `search_suggest`(web)。
- `voice`(电台命中)结构与 `dj_detail` 完全不同: id/name 在 `baseInfo` 里, `baseInfo.dj.nickname` / `baseInfo.radio.programCount` / `baseInfo.listenerCount`。
- `search_hot_detail`(`/api/hotsearchlist/get`, weapi, body `{}`)回 `data:[{searchWord,score,iconType,iconUrl,content,source,url}]`, **无 rank 字段**, 榜位 = 数组下标 + 1。
- mobile 联想 `search_suggest` 加 `type=mobile` 后只回 `result.allMatch[].keyword`(6 条纯串), 与 web 版(实体卡片)是同一路径的两个形态。

## v2 · 功能包: 黑胶会员只读 B3(2026-11-07)

| 能力 | 状态 | 证据 |
|---|---|---|
| 会员卡 | ✅ | `vip_info_v2` + `vip_growthpoint`: 黑胶·叁 / 成长值 2195 / 今日 +6 / 到期 2026-11-10; `is_vip` 只认 `associator.expireTime > now`(过期账号 vipLevel 仍是旧值) |
| 本周签到 | ✅ | `vip_sign_info` 只回最近 7 天且 `score > 0` 才算已签(未签那天的 recordId/time 也是 0); 实测"本周已签 1/7 天 · 今日已签" |
| 任务 | ✅ | `vip_tasks` 的 `taskList[].taskItems[]` 平铺; `name` 常为空串→回退 `action`; `targets=null` 不渲染进度条, 只显示状态 |
| 入口 | ✅ | 设置页新增「会员 / 黑胶会员」卡片 → `VipPage`; 未登录走"登录后可查看会员信息 + 登录"空态, 不报鉴权错 |
| 数据聚合 | ✅ | provider 一次 `vip_overview`(4 个子接口并行 join4), 单个子接口失败只让对应字段为 None; 全部失败才返回错误 |
| CLI | ✅ | `ncm vip`: 等级/成长值/本周签到/任务一次打印(headless 可复现) |
| 回归 | ✅ | Rust `ncm-service` 60→65 单测全绿; `flutter analyze` 0 error; Flutter 152 用例全绿(vip_page 7 例 + vip_mapping 4 例); codegen 一次 + `cargo build -p ncm_ffi`; `tools/ci.sh` → CI OK; a36 走查: 登录态(资料卡/签到条/任务条)与未登录空态均正常 |

**协议/实现事实**:
- `vip_info_v2`(`/api/music-vip-membership/client/vip/info`) 的会员判定必须用 `associator.expireTime > data.now`;
  `vipCode`/`vipLevel` 在过期后仍是旧值。`redVipAnnualCount = -1` 表示未知/非年费。
- `vip_growthpoint` 的今日成长值在 `userLevel.extJson` 这个 **JSON 字符串**里(`todayScore`), 不是对象字段。
- `vip_sign_info`(`/api/vip/sign` 系)返回的是**最近 7 天数组**, 没有"本月/累计"维度; UI 只能显示"本周 X/7 天"。
- `vip_tasks` 的 `taskItems[].name` 实测为空串, 可读标题在 `action`; `targets` 非 null 的形状未实测(兼容 数字/数组)。
- `tools/ci.sh` 里 vendor 匿名联网 smoke(search/toplist)本轮随机挂 2 例, 属已知上游风控抖动; workspace 单测/analyze/flutter test/双端构建全绿。

## v2 · 功能包: 消息增强 @我/最近联系人/私信分页(2026-11-07 深夜)

| 能力 | 状态 | 证据 |
|---|---|---|
| @我 页签 | ✅(只读) | `msg_forwards`: 消息中心第四页签"@我"(未读数取 pl_count 的 forward); 本账号为空, 走空态"还没有@我"; 非空条目形状未实测, Rust 侧防御式解析 + 合成单测覆盖 |
| 最近联系人 | ✅ | `msg_recentcontact`: 私信页签顶部横滑条(头像/备注名优先/昵称), 数据是 data.follow("可发起私信的联系人/关注列表"), 服务端顺序不重排 |
| 会话分页 | ✅ | `msg_private` limit/offset: 触底前 300px 预取 + 底部"加载更多"按钮; 按 user id 去重, 返回条数 < limit 显示"没有更多了" |
| 聊天分页 | ✅ | `msg_private_history`: 聊天面板改 reverse 列表(最新在下), 顶部"加载更早"用当前最早一条 time_ms 当 before_ms, 按 id 去重, 不重复拉最新页 |
| 回归 | ✅ | Rust 离线 81 单测全绿(ncm-service 57→60, 新增 @我 空响应/合成条目/最近联系人 3 组); flutter analyze 0 error; messages_page_test 7/7(旧 3 例改签名 + 新 4 例); codegen 一次 + cargo build -p ncm_ffi 通过; vendor 匿名接口集成测试(banner/toplist)本轮网络抖动随机挂, 与本批无关, 交由编排者 ci.sh 复核 |

**协议事实(写进代码注释/记忆)**:
- `msg_forwards` 顶层是 **`forwards` / `lasttime` / `more` / `newCount`**; 空账号拿不到非空条目形状,
  ForwardItem 全字段 Option/serde(default), 解析不出任何 id 的条目直接跳过;
  时间戳按"10 位=秒"归一成毫秒(假设, 待真实数据复核)。
- `msg_forwards` 的 vendor 实现只发 **offset/limit**(没有 lasttime 游标), trait 的 last_time_ms 参数保留形状、当前恒取最新一页。
- `msg_recentcontact` 的 vendor 实现发**空 body**(limit 不上送, 只能客户端截断); 返回只有 `data.follow` 一个数组。

## v2 · 功能包: B0 纯 Dart 收尾(歌词纯文本 / 播客详情刷新 / 资料卡关注数 / 窄屏)(2026-11-07)

| 能力 | 状态 | 证据 |
|---|---|---|
| 纯文本歌词兜底 | ✅ | `lyric.dart` 新增 `parseLrc`(时间轴 / 纯文本回退 / 格式异常容忍 / tlyric 按毫秒合并) + `PlainLyricView`; `main.dart` 在 `lyricLinesI18N` 为空或抛错时改走 `rust.lyric` 原始 LRC: 有轴等价逐行高亮, 只有纯文本则按行展示, 都没有才显示可读错误短文案 |
| 播客详情刷新 | ✅ | `podcast.dart`: 详情打开即并行刷新 `podcast_radio` + `podcast_program`, 列表数据只作首屏占位; 两级列表加 RefreshIndicator; 刷新失败保留旧数据 + 顶部错误条(重试/关闭), 一个数据都没有才整页重试。默认 loader 走 `rust.podcastRadio`, 现有调用点零改动生效 |
| 资料卡关注数刷新 | ✅ | `profile_header.dart` 变 StatefulWidget(`ProfileHeaderState.refreshCounts()`, 可注入 `loadDetail`); `mine_view.dart` 把「关注/粉丝列表」回调改成返回 Future, pop 回来重拉资料卡, 关注/取关后数字立即更新(不再等重进页面) |
| 空态/错误态 + 窄屏 | ✅ | 三页文案统一(短中文 + 重试按钮); 300dp + 1.25 字号有 widget 用例守护(长文本不溢出), 未改全局主题 |
| 回归 | ✅ | Flutter 141 用例全绿(lyric 5→14 / podcast 2→7 / 新增 profile_header_test 5 例); `flutter analyze --no-fatal-infos` 0 error; Linux 构建通过; a36 模拟器实测: 消息 4 页签 / 最近联系人横滑条 / 会话滚到底「没有更多了」/ 聊天「加载更早」/ 资料卡返回数字正常 |

**协议/实现事实**:
- `lyric_lines`(逐行)与 `lyric`(原始 LRC)是两条独立链路: 前者解析后为空时(纯文本歌词)必须回退后者, 否则只会显示「暂无歌词」。
- 聊天历史翻旧页用「当前最早一条 time_ms」当 `before`, 与 `parse_private_history` 已翻正的升序列表配合, 不会重复拉最新页。

## v2 · 功能包: 评论热门 + IP 归属(2026-11-07 晚)

| 能力 | 状态 | 证据 |
|---|---|---|
| 热门评论页签 | ✅ | `comment_hot`: 评论区新增"全部/热门"两个 ChoiceChip; 热门单独走 `/api/v1/resource/hotcomments/<threadId>` 并独立翻页, 计数显示热门总数(9405)而不是全部评论数(312165); 模拟器 a36 实测切换正常 |
| IP 归属地 | ✅ | 普通评论在昵称行尾显示 `ipLocation.location`(实测 河北/广西/上海/浙江/山西/重庆/辽宁/天津/福建/北京); 精彩评论的 location 是空串, 所以不显示 |
| "热门"角标 | ✅ | `hotComments` 里的评论在昵称旁显示小号"热门"标签, 与最新评论区分开 |
| 翻页修正 | ✅ | 修掉既有 bug: "全部"页的 offset 原来用 `_items.length`(含 15 条热评), 会重复拉热评并跳过 5 条最新; 改为只数非热评项, 并追加时按 commentId 兜底去重 |
| 回归 | ✅ | Rust 73 单测(服务层 57, 新增热门页 hasMore/热门标记/IP 补全); Flutter 118 用例(新增热门页签 1 例 + 翻页 offset/去重 1 例); Android APK 构建通过; 模拟器 a36 实机走过全部/热门切换、IP 展示、翻页 |

**协议事实(已写进代码注释)**:
- 普通评论页 `/api/v1/resource/comments/<threadId>` 同时返回 `hotComments` 与 `comments`,
  热评**没有 IP 归属地**, 且同一评论可能在两处重复; 去重时保留先到的热评版本, 再用后一份补 `ipLocation`。
- 热门评论页 `comment_hot` 的分页字段是 **`hasMore`**(不是普通页的 `more`), 且 `total` 是热门评论总数。
- 动态(`A_EV_2_<eventId>_<uid>`)的 threadId 不能直接给热门接口(只认 eventId), UI 对动态隐藏热门页签。

## v2 · 功能包: 新歌/新碟分地区 + 歌手榜(2026-11-08)

| 能力 | 状态 | 证据 |
|---|---|---|
| 新歌分地区 | ✅ | `top_song`: 推荐页"新歌速递"的"更多"→ 新歌页签 + 地区胶囊(全部/华语/欧美/日本/韩国), 列表带时长、可整批起播; 实测全部=日系新歌, 华语=法老/刘森/张杰 |
| 新碟分地区 | ✅ | `top_album`: 同页新碟页签 + 同款地区胶囊, 点开专辑封面预览; 实测华语=Lan/Iceberg、日本=久石譲交响组曲 |
| 热门歌手榜 | ✅ | `top_artists`: 歌手页签(头像/昵称/粉丝数 1691 万粉丝), 点进歌手页; 实测榜首林俊杰/陈奕迅/薛之谦 |
| 回归 | ✅ | Rust 56 单测(新增新歌/新碟合并去重/歌手榜解析 3 组); Flutter 116 用例(新页 4 例 + 推荐页"更多"入口断言); Linux + APK 构建通过; 模拟器 a36 三页签 + 地区切换实机走过 |

**协议事实**:
- `top_song` 的 `type` 其实是 **areaId**: 实测只有 **0 全部 / 7 华语 / 8 日语 / 16 韩语 / 96 欧美** 有货(1~6、17、18 等一律返回空数组)。
- `top_album` 的 `area` 是字符串(ALL/ZH/EA/JP/KR); **部分地区 weekData 为空、monthData 才有货**(ZH 就是这样),
  所以要 weekData+monthData 合并按 id 去重再截断, 否则"华语新碟"会空。
- `top_artists` 的返回顺序是服务端热度序, **不是 fansCount 倒序**(林俊杰 1691 万排在薛之谦 2158 万前), 前端别自己重排。
- 新歌响应的 `data[]` 是完整 song 对象, 但字段名是 `artists`/`album`/`duration`(不是 cloudsearch 的 `ar`/`al`/`dt`),
  现有 `parse_song_with` 两者都认, 直接复用。

## v2 · 功能包: 消息中心(2026-11-07 晚)

| 能力 | 状态 | 证据 |
|---|---|---|
| 未读计数 | ✅ | `pl_count`: "我的"页消息入口角标 + 分项摘要("私信 18"); 实测 18 未读 |
| 私信会话 | ✅ | `msg_private`: 头像/昵称/最后一条消息/相对时间/未读气泡, 按最近时间倒序 |
| 私信记录 | ✅(只读) | `msg_private_history`: 点会话开底部面板, 气泡按发送方左右分列; 尾部提示"只读, 回复请到官方客户端"(vendor 无发包接口) |
| 通知 | ✅ | `msg_notices`: 点赞/关注/系统通知; `notice` 是 JSON 字符串, 取 `generalNotice.actionDesc` + `user.nickname/avatarUrl`, 解析不出时用 pushMsg/"系统通知" |
| 评论消息 | ✅ | `msg_comments`: 评论内容 + 被评论资源名(取 `resourceJson.name`), 兜底显示我方原评论 `beRepliedContent` |
| 回归 | ✅ | Rust 53 单测(新增 msg_text/会话/通知/评论解析 3 组); Flutter 112 用例(消息页 3 例 + 入口卡 2 例); Linux + APK 构建通过; 模拟器 a36 实机走过三个页签与会话面板 |

**协议事实(写进代码注释/记忆)**:
- `pl_count` 的键是 **`msg` / `notice` / `comment` / `forward`**(不是 private/notices/...), 合计即角标。
- 私信/通知正文都是**双层 JSON 字符串**: 外层 `lastMsg`/`notice`, 内层还有 `msg` 或 `generalMsg{title,inboxBriefContent}`;
  `msg_text()` 的优先级 = `msg` → generalMsg 标题/摘要 → `pushMsg`(实测会员通知的 pushMsg 是一大段营销文案, 标题更合适)。
- 私信历史 `msgs[]` 是**倒序**给的, Rust 侧翻成正序再交给 UI。
- `msg_comments` 必须带自己的 uid(参数名 `uid`), 走 `/api/v1/user/comments/<uid>`。

**未做**: 会话只读(不提供发送), 也不做已读回执上报。(@我 与最近联系人已于本日「消息增强」批次补上)

## v2 · 功能包: 最近播放分类 / 签到 / 评论删除 / 歌曲百科(2026-11-07 下午)

| 能力 | 状态 | 证据 |
|---|---|---|
| 最近播放分类 | ✅ | `record_recent_album` / `record_recent_playlist` / `record_recent_dj`: "最近听过"四个页签(单曲/专辑/歌单/播客); 实测专辑 8 张、播客 8 个(点专辑→封面预览, 点歌单/播客→详情) |
| 云贝签到 | ✅ | `signin_progress` + `daily_signin`: "我的"顶部签到卡(今日状态 + 累计/连续/本周天数), 点"签到"后变"已签到"并提示云贝数; 实测累计 13 天 / 本周 5 天 |
| 评论删除 | ✅(单测) | `comment_delete`: 只有 `userId == my_uid` 的评论显示"删除", 二次确认后本地移除并减总数 |
| 歌曲百科 | ✅ | `song_wiki_summary`: 歌曲菜单"歌曲百科"(曲风/推荐标签/语种/BPM/获奖成就/影视节目/乐评); 实测《孤勇者》7 条 |
| 回归 | ✅ | Rust 50 单测(新增最近播放/签到/百科解析 3 组); Flutter 107 用例(新增四个页签/签到卡/评论删除/百科面板 7 例); Linux + APK 构建通过; 模拟器 a36 实机走过四个新入口 |

**协议事实(踩过, 已写进代码注释)**:
- `daily_signin` 的 `type=0`(安卓通道) 实测回 `code=200 msg=功能暂不支持`, **只有 `type=1`(web) 真的签到成功**;
  重复签到回 `Invalid parameter: 重复签到` → provider 先查 `signin_progress.today.todaySignedIn` 再决定是否发请求。
- 签到进度的三套计数在 `data.stats[]` 里按 id 区分: **6001 累计 / 4001 每周 / 5001 连续(28 天循环)**, 取 `currentProgress`。
- `record_recent_*` 的形状是 `{code, data:{list:[{data:{...}}]}}`(每项外面套一层 `lastSong/uiPlaylistType`),
  且**最近播放歌单不带 `trackCount`** → UI 只在 >0 时显示曲目数。
- `song_wiki_summary` 返回的是装修块富文本(`data.blocks[]`), 只需 `SONG_PLAY_ABOUT_SONG_BASIC` 那个块;
  Rust 侧压成 label/value 对(标题取 `creative.uiElement.mainTitle.title`, 值取 `resources[].uiElement.mainTitle` +
  `subTitles` 或 `textLinks[].text`)。该接口 vendor 走 eapi, 安卓身份实测也正常, 但仍保留了 weapi 兜底。
- 顺手修掉两处会挡住 `flutter analyze` 的既有告警(detail_page 死函数 + `rust.myUid()` 未 await),
  现在 `bash tools/ci.sh` 能一路跑到双端构建通过。

**未做/待评估**: 评论区还不显示热门评论与 IP 归属(`comment_hot`/`comment_info_list`);
`record_recent_video`/`record_recent_voice` 需要视频播放器/创作者内容, 暂不做;
`vip_sign*`/`sign_happy_info` 是黑胶专属任务, 可后续做只读展示。
- 另: 非日推/FM 的歌点"不感兴趣"服务端回 `code=432`, 目前会原样弹 `操作失败: [internal] code=432`;
  若要更友好, 需要在 UI 侧限制入口(只在日推/FM 队列里显示)。

## v2 · 功能包: 不感兴趣 / 历史日推(2026-11-07 中午)

| 能力 | 状态 | 证据 |
|---|---|---|
| 日推不感兴趣 | ✅ | `recommend_songs_dislike`: 每日推荐每行 ⊖ → 接口写成功、列表本地移除; 实测"Sahara/Joe Satriani"消失 |
| FM 不感兴趣 | ✅ | `fm_trash`: 歌曲菜单"不感兴趣"在 FM 队列(`onPlayFm` 标记 `_fmActive`)时走"不再播放", 其余场景走日推 dislike |
| 历史日推 | ✅ | `history_recommend_songs` + `..._detail`: 每日推荐面板第三个页签, 日期列表 → 某天的歌单; 实测 2026-11-05~11-01 五天, 打开 11-05 得到 34 首 |
| 回归 | ✅ | Rust 47 单测(新增历史日期解析); Flutter 97 用例(日推不感兴趣/历史日推/菜单显隐); Linux + APK 构建通过 |

**环境坑(重要)**: `tools/build-linux.sh` 报 `rust-lld: undefined hidden symbol ... wire__crate__api__ping_impl` 链接失败,
是 **cargokit 的增量缓存坏了**(与代码无关): 删掉
`ui/build/linux/x64/debug/plugins/rust_lib_minincm/cargokit_build` 再构建即好。
历史日推是**黑胶 VIP 专属**, 非 VIP 时 dates 为空, UI 给一句说明。

## v2 · 功能包: 新歌新碟 / 相似推荐(2026-11-07 上午)

| 能力 | 状态 | 证据 |
|---|---|---|
| 新歌速递 | ✅ | `personalized_newsong`(曲目嵌在 result[].song): 推荐页 6 首预览, 点任意一首按整批起播; 实测 Hong Kong(feat.王菲季候风)/The Weeknd 等 |
| 新碟上架 | ✅ | `album_new`: 推荐页封面横排(歌手·曲数), 点开专辑弹窗; 实测 Coco Jones/瓷ci/Lil Baby |
| 相似歌曲 | ✅ | `simi_song` + `simi_playlist`: 歌曲菜单「相似歌曲」→ 面板(相似歌曲列表 + 相似歌单横排); 实测《泪海》→ 再见太难/甲乙丙丁… + 3 张相似歌单 |
| 相似歌手 | ✅(需登录) | `simi_artist`: 歌手页「相似歌手」胶囊, 点开递归进歌手页; 匿名调用返回 Authentication required, UI 静默隐藏 |
| 回归 | ✅ | Rust 46 单测(新增新歌/相似解析 1 组); Flutter 93 用例(推荐页改为高视口一次断言, 新增相似面板 1 例); Linux/APK 构建通过 |

**踩坑**: 推荐页测试用 `scrollUntilVisible` 在超长页面里容易 "Bad state: No element"(横向 ListView 抢到 `Scrollable.first` /
元素被回收)。改为 `tester.view.physicalSize = Size(1200, 4200)` 一次性构建整页, 稳定且更快。

## v2 · 功能包: 评论互动 / 关注粉丝(2026-11-07 凌晨)

| 能力 | 状态 | 证据 |
|---|---|---|
| 评论区统一 | ✅ | 新增 `comment_thread.dart`, 歌曲/歌单/专辑/播客/动态共用: 列表分页 + 点赞(乐观更新, 失败回滚) + 楼层回复 + 发回复; 旧的 `_CommentsSection`/`_EventComments` 两份实现(约 250 行)删除 |
| 评论点赞 | ✅ | `comment_like`: 模拟器实测 624 → 625 且红心点亮(真实写入) |
| 楼层回复 | ✅ | `comment_floor`(threadId → type+id 反解): 实测"回复 18"面板列出真实楼层 + 底部输入框(`comment_reply`) |
| 关注/粉丝列表 | ✅ | `user_follows`/`user_followeds`/`follow`/`user_subcount`: 资料卡"关注 44/粉丝 11"可点 → 两 tab 列表 + 行内关注/取关; 实测关注 44 人、粉丝 11 人列表均正常 |
| 回归 | ✅ | Rust 47 单测(新增 threadId 往返/楼层/用户列表 2 组); Flutter 92 用例(新增 comment_thread 3 例、user_list 2 例); Linux 构建通过 |

**protocol 备忘**: 评论点赞/楼层接口只吃 `type + id`(vendor 自己拼 threadId), 动态的 id 段是 `eventId_userId`,
所以 `split_thread_id` 要把整段保留; `CommentPage.thread_id` 由 provider 回填后 UI 直接用。

## v2 · 功能包: 排行榜 / 歌单广场 / 收藏专辑 / 歌单编辑(2026-11-06 深夜)

| 能力 | 状态 | 证据 |
|---|---|---|
| 排行榜 | ✅ | `toplist_detail` → 推荐页「排行榜」横排(飙升/新歌/原创… 65 个榜单, 带"刚刚更新/每周四更新"), 点开走歌单详情; 实测截图 |
| 歌单广场 | ✅ | `playlist_catlist` + `top_playlist` + `top_playlist_highquality`: 热门/精品切换 + 语种/风格/场景/情感/主题 五组分类 chips + 三列网格 + offset 分页; 推荐页「推荐歌单」右侧「歌单广场」入口 |
| 收藏的专辑 | ✅ | `album_sublist` 我的页横排卡片(名称/歌手/曲数); 专辑弹窗加收藏按钮(本地状态翻转, 无"是否已收藏"查询接口) |
| 歌单编辑 | ✅ | 自己的歌单(creator_id == my_uid)才显示 ⋮: 编辑歌单信息(名称/简介) / 移出曲目(点行=移出, 带模式提示条) / 删除歌单; 「收藏到歌单」面板新增「新建歌单」(playlist_create + 直接收藏) |
| 回归 | ✅ | Rust 47 单测(新增榜单/分类/歌单桶/专辑条目 4 组); Flutter 87 用例(新增 playlist_square、专辑收藏、榜单断言); Linux 构建通过; Android a36 实测四项 |

**vendor 限制**: `playlist_privacy` 把 privacy 写死 0(只能取消私密), 改私密/改排序/换封面/改标签本轮不做。

## v2 · 功能包: 关注艺人分类 / 听歌排行 / 风格推荐(2026-11-06 晚)

| 能力 | 状态 | 证据 |
|---|---|---|
| 关注动态按艺人分类 | ✅ | 分类行按"互动频率"排序: 本页(30 条)每人的 动态数×6 + 点赞 + 评论×2 + 转发×2, 同分按最近发布; 只放前 8 位 |
| 全部艺人入口 | ✅ | 分类行末尾固定「进入全部」→ 底部面板 = 本页艺人(带 动态数/互动数) + `subscribed_artists` 里本页没发动态的已关注艺人; 可回到「全部动态」 |
| 听歌排行 | ✅ | 我的页最下方区块: 总排行/当周切换(`play_ranking(period)`: all/week), 前 5 条 + 「查看全部」整页(`ranking_view.dart`); 行内显示名次/播放次数, 点击按榜单顺序起播 |
| 风格推荐入口 | ✅ | 推荐页「风格推荐」(`style_preference`): 网易云按听歌口味算的曲风; 未登录/为空自动退化成通用曲风表(style_list 二级标签), 保证有入口; 点开 `style_page.dart` 看该曲风的歌单 + 歌曲 |
| 回归 | ✅ | Rust 单测新增 4 个解析用例(排行/曲风偏好/曲风列表/曲风歌曲歌单); Flutter 新增 feed_view/ranking_view/style_page 用例, 全量 84 通过; frb 桥重生成 + cdylib 重编 |

**接口实测**: `play_ranking` 需登录(匿名 code≠200); 曲风偏好匿名返回空数组 → 必须退化; 曲风歌单字段是 `cover/songCount`(不是 `coverImgUrl/trackCount`)。

## v2 · 功能包: 搜索分板块 / 图片 / 歌曲操作 / 关注 tab / 我喜欢顺序(2026-11-06)

| 能力 | 状态 | 证据 |
|---|---|---|
| 搜索分板块 | ✅ | `rust.searchAll` 并发 cloudsearch type=1/10/100/1000/1009 → 单曲/歌手/专辑/歌单/播客五区(空区不渲染); type=2000(声音/节目)实测返回空, 未单列 |
| 搜索显式取消 | ✅ | 输入框清空按钮 + 「取消」按钮; 取消后丢弃在途结果(请求代次 `_searchToken`) |
| 图片 | ✅ | 歌曲行封面/歌手圆头像/专辑/歌单/播客卡片/歌手页横幅/评论头像/动态配图; **CDN 对 `Dart/x (dart:io)` UA 回 403, 统一带浏览器 UA+Referer**; `?param=NxN` 缩略图(全宽图片跳过, 防 Infinity.toInt 崩溃) |
| VIP 误标修复 | ✅ | `Song::is_vip()` 只认 fee=1; fee=8 是「低音质免费」, 之前 21/30 首免费歌被误标 VIP |
| 我喜欢的音乐顺序 | ✅ | `liked_songs_ordered`: playlist detail `trackIds[].at` 按收藏时间倒序, 不再依赖 likelist 顺序 |
| 关注独立 tab | ✅ | 底部五栏: 搜索/推荐/关注/我的/设置; `feed_view.dart` 复用 feed_events, 动态图片可看大图、视频封面点击交系统打开 |
| 歌曲操作菜单 | ✅ | 每行 `...` + 播放条 `...`: 下一首播放/喜欢/收藏到歌单/分享/查看评论/歌手信息/专辑信息/下载; 评论复用 `showCommentsSheet`; 歌手页 `showArtistDetail`(热门歌曲+专辑) |
| 下载 | ✅ | Android DownloadManager(免存储权限, 存 Download/MiniNCM); Linux curl 到 `~/Downloads` |
| 个人资料卡 | ✅ | `profile_detail` (user_detail: 背景图/头像/签名/关注/粉丝/等级) + Mine 顶部 `ProfileHeader` |
| 回归 | ✅ | Rust 49 个本地单测(Song fee8/Artist 头像等); Flutter 76 用例(新增 search_results/song_actions); analyze 仅 7 条历史 info; Linux/APK debug 构建通过 |

**环境事实**: a36 模拟器上图片偶发 403(Dart UA 修正后仍有), 同一 URL 在 Linux 桌面正常; 属模拟器 NAT/中间设备对 CDN 的差异(Chrome 也报 No internet), 真机/Linux 不受影响。

## v2 · 底部四栏 + 搜索/推荐/我的/设置(2026-11-05)

| 能力 | 状态 | 证据 |
|---|---|---|
| 底部导航 | ✅ | 搜索/推荐/我的/设置四栏,播放条与导航栏同处 `bottomNavigationBar`,播放器状态跨 tab 不重建 |
| 搜索落地页 | ✅ | 历史 + 猜你想搜 + 10 条热词榜;热词点击直接搜索;必须等 `rust.init()` 后再拉 |
| 推荐页 | ✅ | 每日推荐歌曲/歌单、推荐播客、每日私人 FM、心动模式入口 |
| 我的页 | ✅ | 我喜欢、收藏歌单、收藏播客、关注艺人、关注动态(艺人分享单曲可播放) |
| 设置页 | ✅ | 账号/账号簿、主题(跟随/浅色/深色)、界面字号、取链音质、设备 ID/数据目录、清空搜索历史 |
| 新 provider | ✅ | `hot_search/default_search`、`personal_fm`、`subscribed_podcasts`、`subscribed_artists`、`feed_events` + DTO/FFI/桥/单测 |
| Android 模拟器实测 | ✅ | a36(Android 16):热词/搜索/推荐/私人 FM 播放(`PLAYING`)/我的/动态/设置/主题切换 |
| Linux 实测 | ✅ | Xvfb + 真实账号(隔离 `NCM_DATA_DIR`):四栏/热词/推荐封面/我的/设置/歌曲播放(00:10 推进) |
| 回归 | ✅ | Rust 31 个 service 测试;Flutter 69 个测试;Linux/APK debug 构建通过 |

本轮实测发现并修复: `Capability::PersonalFm` 漏声明(私人 FM 报 no provider)、
关注动态线上字段是 `event`/`type` 而非 `events`/`eventType`。
完整流程与踩坑见 **`docs/testing-dual-platform.md`**。

## v2 · M2+ 播放链 + 队列(2026-11-03 晚, 模拟器 a36 / Android 16)

全部在模拟器上验证(真机那条"安装二次确认"不再阻塞日常迭代)。

| 能力 | 状态 | 证据 |
|---|---|---|
| 模拟器安装/启动 | ✅ | `avd headless a36` + `adb install -r -t` 0.7s;UI 正常渲染(Impeller/GLES) |
| 搜索(模拟器) | ✅ | "晴天" 返回 10+ 条,eapi 直连正常 |
| Media3 播放 | ✅ | ExoPlayer `state=PLAYING`,position 136s→142s 实时推进,通知栏标题正确 |
| 直链 https 升级 | ✅ | `preferHttpsStreamUrl`(playback.dart)+ 3 个单测;见下方根因 |
| 播放队列 | ✅ | `ui/lib/src/queue.dart` 纯逻辑 + 9 个单测;点列表重置队列并定位 |
| 上一首/下一首 | ✅ | 点歌 → next 切到第 3 首;prev 回到上一首(从头播) |
| 播放模式 | ✅ | 列表循环 → 单曲循环 → 顺序播放 三档轮转(snackbar + 图标) |
| 进度条 seek | ✅ | 滑杆拖动到底部方式实测,拖动中冻结量程 |
| 自动续播 | ✅ | seek 到 90% 播完后自动切下一首(轮询 500ms + 临界区保护) |
| 客户端形态自洽 | ✅ | 安卓 = `os=android/appver=8.20.20/channel=xiaomi` + 安卓 App UA + 移动版网页;桌面 = `os=pc` + 官方 PC UA。设备端 identity.json 已就地迁移(deviceId 不变),搜索/播放正常 |
| VIP 音质验证 | ✅ | 同一首 fee=1 曲目(布拉格广场 210049):**匿名 00:30 试听**(取链 size 481KB) vs **VIP 账号 04:54 完整时长**(列表标 294s);fee=8 曲目(屋顶)匿名即可 320k 完整 |
| 多账号账号簿 | ✅ | `accounts.json` 按 uid 存**登录凭据**(不含设备指纹), 存储于 0600;账号簿面板列出昵称/当前账号, **一键切回无需重新扫码**(实测:退出→点账号→logged_in=true, deviceId 不变);登录/启动时自动 `account_sync_active` 记录昵称 |
| 账号切换/退出 | ✅ | 顶栏账号图标 → 底部面板(切换账号/退出登录);退出清 MUSIC_U/__csrf/JSESSIONID 并清 WebView cookie,**设备指纹不变**(deviceId/\_ntes_*/WNMCID/NMTID 保留),登录页立即重开 |
| 登录(官方网页) | 🟡 代码就绪, 待真实登录 | LoginActivity(WebView) + MUSIC_U 轮询 + `ncm/auth` 通道 + Rust 合并落盘;`ncm login-cookie` 端到端验证过(设备指纹保留);当前模拟器内 **chromium/WebView 的 TLS 被中间设备重置**,同一 guest 里 rustls 正常 → 属宿主网络问题(另一路在修),真实登录需用户扫码 |
| 歌词 | ✅ | `ncm-domain::lrc` 解析([mm:ss.xx]/多标签/offset/翻译对齐, 12 单测) + 播放页歌词自动滚动高亮;英文歌显示中文翻译;换曲自动重新拉词 |
| Linux 回归 | ✅ | `flutter test` 18 通过(含 `NCM_AUDIO_TEST` 真实播放);`flutter analyze` 0 issue |

### 本轮两个根因

1. **明文 http 直链在本机被中间设备回 502**(空 body)→ ExoPlayer 报
   `UnrecognizedInputFormatException: None of the available extractors could read the stream`。
   这不是解码问题:模拟器内 `nc www.baidu.com 80` 同样 502,而 https(443) 一切正常;
   宿主自身 `curl` 走 80 是 200(说明是转发/NAT 路径上的拦截)。
   → 播放统一升级到 https(CDN 同路径 `https://m701.music.126.net/...` 返回 200/audio-mpeg)。
2. **主机代理环境变量会毒化 Rust 侧请求**:clash 没起时 `HTTPS_PROXY=http://127.0.0.1:7890`
   让 reqwest 报 `error sending request for url (...)`,与"设备风控/接口变更"极像。
   → `ncm-service` 在网络错误里附代理提示;跑 CLI/测试前先 `env -u https_proxy ...`。

### 验证手法(下次照抄)

```bash
~/bin/avd headless a36                       # 无窗口模拟器, 15s 起
bash tools/build-android.sh                  # 增量 ~10s
adb -s emulator-5554 install -r -t ui/build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell am start -W -n com.minincm.minincm/.MainActivity
adb -s emulator-5554 exec-out screencap -p > /tmp/shot.png   # 直接看 UI
adb -s emulator-5554 shell dumpsys media_session | grep metadata  # 校验播放态/曲目
```

注意:手势导航条会吞掉屏幕最底部约 20dp 的点击(坐标别贴底,UI 已加 8dp 边距)。

### 登录链(2026-11-04)

`LoginActivity`(纯 `android.webkit.WebView`, 零第三方依赖)负责官方移动端授权页:
设备默认移动 UA + `https://music.163.com/login`(302 到 `y.music.163.com/m/login`),
每 1.5s 轮询 `music.163.com`/`163.com` 两个域的 cookie,出现 `MUSIC_U` 即回传并结束。
Dart 侧 `src/auth.dart` 拿到 cookie 后调 `login_with_cookie`,Rust 与设备指纹合并写
`identity.json`(0600);UI 刷新 `init()` 显示"已登录"。

- 取消/未登录路径已验证:返回键 → `未获取到登录态` 提示,无崩溃。
- 端到端(不含网络)用 CLI 验证:`NCM_DATA_DIR=/tmp/x ncm login-cookie "MUSIC_U=dummy"`
  → `whoami` 显示 `logged_in = true` 且 `_ntes_nuid/deviceId` 保持原值。
- **待办**:宿主网络恢复后重新打开授权页,由用户完成登录(扫码/手机号),再验 VIP 音质解锁。

### 改 Rust API 后的固定三步(踩过)

```bash
flutter_rust_bridge_codegen generate --rust-input crate::api \
  --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust   # 1. 重生成桥
cargo build -p ncm_ffi --manifest-path core/Cargo.toml            # 2. 重编 cdylib
cd ui && flutter test                                            # 3. 否则报 content hash 不一致
```
`flutter test` 的 `frb_smoke_test` 直接加载 `core/target/debug/libncm_ffi.so`,
所以第 2 步漏了会得到 `Bad state: Content hash on Dart side (...) is different from Rust side`,
**不是桥代码生成错**。

## v2 · M2(Android)状态(2026-11-03, vivo X200 Ultra)

| 项 | 状态 | 证据/备注 |
|---|---|---|
| release APK 构建 | ✅ | 22.0MB(arm64,Media3 1.9.4 + Rust core) |
| 安装 | ✅ | vivo **安装二次确认无法绕过**:每次都要用户在手机上点「安装/继续安装」;`push + pm install` 只是减少弹窗层级 |
| 启动 | ✅ | ExoPlayerImpl / MediaSessionImpl 初始化成功,Impeller(Vulkan) 正常 |
| Rust core 在设备上运行 | ✅ | UI 显示 device_id、搜索按钮可点 |
| 搜索(设备 5G) | ✅(模拟器已验,真机待复测) | 模拟器 10+ 条正常;真机那条 `error sending request` 疑似同一处裸机网络/代理差异 |
| Media3 播放 | ✅(模拟器已验,真机待复测) | 见上一节;真机需注意明文 http 可能被运营商/NAT 拦 |

### 已知问题(下次接手第一件事)

1. **真机 vs 模拟器差异待复测**:模拟器上搜索/播放全通,真机上 Rust 侧 https 曾报
   `error sending request`。真机复测前先排除:代理类 VPN/私有 DNS/运营商 80 端口策略。
2. **队尾停止的"顺序播放"未在设备上验**:逻辑有单测覆盖(`queue_test.dart`),设备上要真播到队尾才能看。
3. **vivo 安装确认不可绕过**:每次覆盖安装都由用户在设备上点确认;脚本会阻塞等待并提示,
   不点/锁屏会报 `INSTALL_FAILED_ABORTED: User rejected permissions`(不要误判为脚本或包问题)。
4. **vendor 自带集成测试并发/连跑易失败**: `cargo test -p ncm-api-rs --test integration`
   并行或短时间内连跑会因风控/限流挂 2~3 条(`test_banner/test_search/test_countries_code_list`),
   单跑或间隔重试即过 —— 不是我们的回归。本仓库测试用 `cargo test -p ncm-domain` 等本地用例为准。

### 本轮 Android 侧踩坑

- Kotlin **块注释可嵌套**:文档注释里写 `http://*` 会引入 `/*`,导致 "Unclosed comment" 编译失败。
- ExoPlayer 默认 UA 是 ExoPlayerLib,网易 CDN 会拒;必须显式设置 UA/Referer。
- 直链是 plain-http,`AndroidManifest` 必须 `usesCleartextTraffic="true"`(或 networkSecurityConfig 白名单)。
- 电脑同时插多台设备时,所有 adb 命令都要 `-s <serial>`;脚本已支持 `ANDROID_SERIAL`。

## v2 · M2(Linux 播放)进度(2026-11-03)

| 能力 | 状态 | 证据 |
|---|---|---|
| 音频缓存(直链时效内落盘) | ✅ | `ncm play` 缓存到 `<data>/audio/<id>.mp3` |
| Linux 播放(rodio 0.23 + CPAL/ALSA) | ✅ | 真实曲目 pos 0→5.3s 前进, dur 148.8s |
| 播放控制(play/pause/resume/stop/seek/volume/state) | ✅ | FFI 暴露, Dart 端 500ms 轮询 |
| 桥接端到端音频测试 | ✅ | `flutter test --dart-define=NCM_AUDIO_TEST=true` 6 用例全绿 |
| Android Media3 后端 | ⏳ | 需要 `platform/android` Kotlin 层(下一步) |
| 队列/上下曲/循环 | ⏳ | 目前单曲播放 |

系统依赖: Linux 需要 `libasound2-dev`(编译期, 已装; 运行期只需 libasound2 本身)。

## v2 重启(2026-11-03): M0 完成情况

| 步 | 内容 | 状态 | 证据 |
|---|---|---|---|
| S1 | Flutter 3.47.9 用户级安装 + Linux bundle 构建 | ✅ | `ui/build/linux/x64/debug/bundle/minincm` 构建通过 |
| S2 | cargo workspace 五 crate + ncm-domain 单测 | ✅ | `cargo test` 8 用例全绿 |
| S3 | vendor `ncm-api` + CLI 搜索 | ✅ | `ncm search 晴天` 返回 336 条, 0.2s |
| S4 | CLI 取链 + 下载 | ✅ | `ncm url 3455095614 --download` 得到 320k mp3, 5.7MB |
| S5 | 通道 spike(interface vs interface3) | ✅ | 两条都通, 保持库默认; 见 `docs/api-channel.md` |
| S6 | FRB 桥 + 双端 UI smoke | ✅ | `flutter test` 4 用例(含真实网络搜索/取链) |
| S7 | Android 交叉编译 | ✅ | debug APK 168MB(4 ABI, 带符号), **release arm64 APK 21.1MB** |
| S8 | tools/CI 脚本 | ✅ | `tools/env.sh` / `build-linux.sh` / `build-android.sh` / `ci.sh` |

### 本轮关键事实

- **协议层零自研**: `core/vendor/ncm-api` = api-enhanced 的 Rust 移植(382 个 api 模块, rustls),
  锁定 commit 见 `core/vendor/UPSTREAM.txt`。
- **库的两个默认值必须覆盖**: `device_id` 是进程级随机(`LazyLock`)→ 我们落盘后 `set_device_id()` 注入;
  `_ntes_nuid/_ntes_nnid/NMTID/WNMCID` 缺失时也随机 → 我们首启生成并写入 cookie,永久复用。
- **cargokit 命名坑**: Rust crate 名含 `-` 时,产物是 `libncm_ffi.so` 但 cargokit 找 `libncm-ffi.so` →
  链接失败。**crate 名必须用下划线**(`ncm_ffi`)。
- **FRB 类型**: Rust `u64` 在 Dart 侧是 `BigInt`(id/durationMs),写 UI 时注意。
- 本机 Flutter 3.47.9 默认 NDK = **28.2.13676358**(空 SDK 时 gradle 会尝试自动下载,建议预装)。
- Gradle wrapper 默认从 services.gradle.org 拉 9.3.1-all(卡在 KB/s); 已改腾讯镜像 `-bin.zip`,并预置到
  `~/.gradle/wrapper/dists` 绕过 JVM 直连。`tools/env.sh` 同时导出 rustup 的 USTC 镜像,
  否则 cargokit 自动补 target 会卡死在 static.rust-lang.org。
- 构建产物: `ui/build/app/outputs/flutter-apk/app-release.apk` = **21.1MB**(arm64)。
- 未连真机(adb devices 为空),Android 端尚未做安装/冷启动/PSS 实测。


# 进度记录(Progress)

> 最近更新: 2026-11-02。里程碑式记录 "做到了什么 / 怎么验证的 / 下一步",
> 协议细节放 `.pi/skills/netease-cloud-music-api-reverse/SKILL.md`,
> LX 音源脚本工坊(插件契约 + 回归台 + 真机导入)见 `docs/lx-plugin.md`,
> 社区项目与路线选择见 `docs/community-projects.md`,
> fork/PR/自建对比见 `docs/build-vs-fork.md`,
> 给 Melodia 提 PR 的分支/构建/真机验证/截图流程见 `docs/melodia-pr-workflow.md`。

## 当前状态: v1 全链路可用(真机验证)

| 环节 | 状态 | 验证方式 |
|---|---|---|
| 构建环境 | ✅ | `bash tools/setup-android-env.sh` 一键装 JDK21 + Gradle8.9 + SDK34 |
| 构建 | ✅ | `bash tools/build.sh` → `app-debug.apk`,**96 KB** |
| 真机安装 | ✅ vivo X200 Ultra / Android 16 / WebView 138 | 冷启动 242ms,空闲 PSS 126MB |
| 登录 | ✅ 官方**移动端**网页授权(手机号/QQ/微信/扫码都在页内) | 抓到 `MUSIC_U` 自动落地并回主界面 |
| 搜索 | ✅ eapi `interface3` `/api/cloudsearch/pc` | 真机搜索 "jay" 返回列表 |
| 播放 | ✅ 原生 MediaPlayer | 免费歌与(VIP 登录后)会员歌均出直链并出声 |
| 歌词 | ⏳ provider 已实现 `lyric()`,UI 未接 | — |

## 本轮踩过并解决的坑(都已写进代码注释/技能)

1. **JDK 17.0.2 不能用于 AGP 8.5.2**:`validateSigningDebug` 抛
   `CgroupInfo.getMountPoint() ... anyController is null`(cgroup v2 探测 NPE)。换 **Temurin 21.0.9** 通过。
2. **下载源**:`api.adoptium.net`/github releases/cdn.azul.com 直连超时 → Temurin 走 USTC 镜像;
   `services.gradle.org` 仅 KB/s → Gradle 走腾讯云镜像;sdkmanager 要求 proxy 变量 **unset**(非空值)。
3. **vivo 装包**:`adb install` 被拒(`INSTALL_FAILED_ABORTED: User rejected permissions`)→
   `adb push /data/local/tmp/` + `adb shell pm install -r -t`;锁屏状态下必失败(需唤醒解锁)。
4. **登录按钮无响应**:`bridge.js` 没暴露 `Native.loginWeb` → JS 抛 TypeError。桥的每个 Native.*
   都要有 JS 包装 + try/catch + toast。
5. **二维码区是死 UI**:`#qr` 无 JS 驱动 → 永远"加载中"。
6. **播放地址 400 参数错误**:`/eapi/song/enhance/player/url/v1` 必须带 `encodeType:'flac'`。
7. **"数据非 json"**:该接口报错时返回**两个拼接 JSON**(`{..}{..}`),需容错解析;`-110` = 会员/版权受限。
8. **原生扫码被 8821 拦死**:eapi 与 weapi 两条通道都在用户确认后返回
   `8821 安全环境风险`。根因是**交互式风控挑战**,验证结果绑在"完成验证的那个客户端"的设备 cookie 上,
   不是 IP(与 Ncrust `spec/api/login.md` 的独立调研一致)。→ 登录改用官方网页。
9. **网页登录不能伪造桌面 UA**:`music.163.com/#/login` + Windows Chrome UA = 桌面 SPA(重、二维码小、
   手机号/QQ/微信二级页加载不出来)。**设备默认移动 UA + 无 hash 的 `/login`** → 302 到
   `https://y.music.163.com/m/login` = 官方移动端授权页(已修复 `LoginActivity`)。
10. **fetch 与原生桥的分工**:带 `Cookie` 头是 fetch 的 forbidden header,必抛 → `bridge.post`
    自动回退 `Native.httpPost`(OkHttp 风格 cipher);而登录成功后 `MUSIC_U` 只能从
    WebView CookieManager 读(fetch 对 JS 隐藏 Set-Cookie)。

## 关键协议事实(详细见技能文档)

- 播放地址: `/eapi/song/enhance/player/url/v1`,`ids` + `level` + **`encodeType`**;匿名下 VIP 歌 `-110`。
- 私人FM `/api/v1/radio/get`、每日推荐 `/api/v3/discovery/recommend/songs`:api-enhanced 标 weapi,
  但**实测 eapi 封装同样 200**(匿名 FM 返回 1 首,登录后为批量)。
- 心动模式 `/api/playmode/intelligence/list` 接受 eapi,需登录态(301)。
- 客户端身份 cookie 决定很多静默行为(见 `docs/build-vs-fork.md` 第 3 节):
  `os`/`appver`/`osver` 缺失会静默封顶音质,写操作会被 `403 illegal request!`。

## 待办(按优先级)

1. **设备身份持久化**(最高优先,影响所有请求的风控评级):
   首次启动生成一套 `deviceId` / `NMTID` / `_ntes_nuid` / `_ntes_nnid` / `WNMCID` / `WEVNSM`,
   **永久复用、登出也不换**。当前 `loadCookie()` 里 `genDeviceId()` 每次随机 = 每次"换一台新设备"。
2. **身份 cookie 规范化**:注入 `os=pc` / `appver=3.0.6` / `osver=10.0.19045`(对齐官方 PC 客户端),
   避免静默降音质与写操作 403。
3. **插件能力声明 v2**:`capabilities: ['login','search','songUrl','lyric','personalFm','heartMode','dailyRecommend']`,
   宿主只调声明过的能力。
4. **私人FM / 每日推荐**(eapi 已验证,只需加能力键 + 列表页)。
5. ~~**内存优化**:登录 WebView 复用、`setRendererPriorityPolicy` 降级、SPA 懒加载(目标 ≤ 90MB idle)。~~
   降级为低优先:实验台形态不追求 idle 指标(Melodia 的 `LxPluginEngine` 已有按需创建+空闲回收的现成做法)。
6. 心动模式(依赖 playlistId 上下文,放队列重构之后)、歌词滚动、seek/进度条。


## 对外贡献(Melodia,2026-10-31)

| 类型 | 编号 | 内容 | 状态 |
|---|---|---|---|
| Issue | [#134](https://github.com/rinchao0721/Melodia/issues/134) | 社区源插件应可优先于官方直链(VIP 账号下插件完全不可达);附探针实测 | 待回应 |
| PR | [#135](https://github.com/rinchao0721/Melodia/pull/135) | `docs/netease-playurl-identity.md`:播放直链接口身份/音质实测语义 | 待合并 |
| PR | [#136](https://github.com/rinchao0721/Melodia/pull/136) | 修复 #128 心动模式 400:未指定上下文时挑选红心歌单(`specialType==5`),附 3 例单测 | 待合并 |
| 评论 | [#133](https://github.com/rinchao0721/Melodia/issues/133#issuecomment-6544358387) | 社区源 VIP 歌听不了的实测定位(12s 超时偏紧、kg 平台脚本自身报错、四类失败形态) | 已发 |
| PR | [#137](https://github.com/rinchao0721/Melodia/pull/137) | 社区源解析超时可配置(12s/30s)+ 各平台失败原因汇总回传 | 待合并 |
| PR | [#139](https://github.com/rinchao0721/Melodia/pull/139) | 播放器级增益(0~-40 dB,逐档 0.4 dB):与系统音量/音量平衡相乘,压低蓝牙耳机最小档;已在真机验证 | 待合并 |
| PR | [#140](https://github.com/rinchao0721/Melodia/pull/140) | 音乐库顶栏常驻设置入口:设置与账号解耦,未登录也能进设置(真机验证:未登录可达「播放与下载」) | 待合并 |
| PR | [#141](https://github.com/rinchao0721/Melodia/pull/141) | 修复 #132 相似歌曲漫游循环:续接改追加(不再 `appendAfter` 截断队尾)+ 相似曲目去重;5 例单测 + 真机队列 6→8 增长验证 | 待合并 |
| PR | [#142](https://github.com/rinchao0721/Melodia/pull/142) | #127 歌单/推荐歌曲列表显示序号(复用 `SongRow.index`);真机截图存 fork 的 `pr-assets` release | 待合并 |
| 评论 | [#138](https://github.com/rinchao0721/Melodia/issues/138#issuecomment-6558443320) | 云盘 .m4a 不能播:追问 matchType/日志/mp3 对照/官方客户端行为 | 等回复 |
| PR | [#144](https://github.com/rinchao0721/Melodia/pull/144) | 新增顺序播放(`SEQUENCE`) + 播放模式并入控制行等距五键(模式/上一首/播放/下一首/队列),分享与输出设备移到封面右上角;真机验证四态轮转、300dp 五键对称、队尾自然播完停止 | 待合并 |

#136 的根因实测(同一登录态只换 `playlistId`):红心歌单 200;自建/收藏歌单 400
「不支持该歌单类型」;`0` 400「歌单不存在」。原实现取歌单列表**首项**当上下文,
红心歌单不置顶的账号必挂 —— 这解释了 #128「换账号就正常」。


## 收尾状态(2026-11-01)

**本地可复现的最小验证**(不需要设备):

```bash
node tools/lx-plugin-harness.mjs      # 匿名:inited 握手 / 直链可取 / 试听拒绝,全 PASS
```

**对外产出**(全部在 Melodia 上游,非本仓库):

| 编号 | 内容 | 状态 |
|---|---|---|
| issue #134 | 社区源插件应可优先于官方直链(VIP 账号下不可达) | 待回应 |
| PR #135 | 播放直链身份/音质实测语义(文档) | MERGEABLE |
| PR #136 | 修复 #128 心动模式 400(红心歌单 `specialType==5`)+ 3 单测 | MERGEABLE |
| PR #137 | 社区源超时可配置(12s/30s)+ 失败原因汇总回传 | 待合并 |
| #133 评论 | 社区源 VIP 歌听不了的实测定位 | 已发 |
| PR #139 | 播放器级增益(0~-40 dB,逐档 0.4 dB),与系统音量/音量平衡相乘;真机蓝牙耳机验证 | 待合并 |
| PR #140 | 设置入口与登录态解耦(音乐库顶栏常驻);真机未登录状态验证可达「播放与下载」 | 待合并 |

**下次接着做**(按价值排序):

0. #144 已补完验证并更新 PR:顺序播放自然播完停在队尾(`state=STOPPED`,位置=时长)、
   300dp 下五键等距、截图已进 PR 正文;等上游 review。
   下一件可做「UI 控件展示项」(#126:侧边栏/首页板块自定义;底栏的 `BottomBarLayout` + 拖拽弹层可直接复用)。
   vivo 锁屏歌词已定位为厂商白名单私有通道(见 `.pi/memory/HINDSIGHT.md`),应用侧无解,最多补设置页说明。
1. 等上游 review #139 / #140:若维护者更希望用「guest 侧边栏」而不是顶栏齿轮,
   改 `ProfileSidebar + MelodiaApp` 的 nullable 化即可(已在 `docs/melodia-pr-workflow.md` 记录现状)。
2. #139 的两个可选延伸(都还没做):音量键细调(拦截 `KEYCODE_VOLUME_*`,1/4 档虚拟音量梯)、
   桌面端(桌面已有 mpv 0~100,不需要)。
3. 等上游对 #134 表态 → 决定是否补沙盒契约缺口(见 `docs/lx-plugin.md` 第 6 节:
   `utils.crypto.aesEncrypt/rsaEncrypt/randomBytes`、`utils.buffer` 正确语义、`statusCode` 透传)。
4. 若 #137 被接受,同款诊断可推广到 UNM 分支(目前只汇总了社区源侧)。
5. 本仓库的 MiniNCM 保持「协议实验台」定位:新协议结论先在这里测,再以 issue/PR 形式回流上游。

## 未决问题(需要决策)

- ~~**路线**:继续 WebView 插件化(96KB APK / 126MB RAM)还是转向原生(= fork Ncrust 3.9MB / 87MB)。~~
  **已定(2026-11):PR 为主,只对 Melodia;不 fork 任何一方。** MiniNCM 降级为协议/风控实验台
  + LX 插件脚本工坊,Ncrust 仅作低资源参照。见 `docs/build-vs-fork.md` 第 6 节。
- 原生扫码是否还值得保留:目前保留为"快捷尝试",命中 8821 时提示改用官方网页登录。

---

## B13: 逐字歌词第二来源 AMLL TTML(2026-11-10)

yrc 无逐字或逐字行覆盖率 < 0.6 时, 自动改用 AMLL 社区库的 TTML 逐字(api.amll.dev,
按 ncmMusicId 查询), 复用现有逐字渲染; 都没有再回退行级 LRC。TTML 原文落盘
`dataDir/ttml/<id>.ttml`, 无数据/解析失败写 `<id>.none` 避免反复打 API。
实现: `core/crates/ncm-domain/src/ttml.rs`(解析器+14 单测)、
`core/crates/ncm-service/src/ttml_source.rs`(抓取+缓存+聚合, 8 单测)、
FFI `word_lyric_with_fallback` / `ttml_lyric_lines`、`ui/lib/main.dart` 三来源
`resolveLyricSource`(假 loader 7 单测) + 歌词页左下角来源小字标注。
实测响应记录: `docs/b13-ttml-lyrics-notes.md`。


---

## C2: 逐字歌词来源偏好与打分择优(2026-11-11)

TTML 来源从「yrc 缺失才回退」升级为用户可控三态偏好(设置 → 播放与音质 → 歌词来源):
`auto`(默认, 打分择优) / `netease`(只用 yrc, 缺失才 TTML, 旧 0.6 覆盖率口径) /
`amll`(优先 TTML, 失败再 yrc)。
打分纯函数 `score_word_lyric`(Rust)与 Dart 镜像 `scoreWordLyric`: 覆盖率 0.3 +
时间单调 0.2 + 首字贴行首 0.15 + 每行粒度 0.15 + 行级 LRC 一致性 0.2;
auto 下 yrc 得分 ≥ 0.9 直接短路, 不探测 TTML(省网络); 得分接近时才取行级 LRC
做一致性加分。择优理由一行短文案进来源标注(如「逐字歌词 · AMLL(择优: yrc 时间错乱)」)。
TTML 探测经 `TtmlProbe` trait 注入, 测试不联网。
实现: `core/crates/ncm-service/src/ttml_source.rs`(打分+择优+偏好, 10 新单测)、
`core/crates/ncm-ffi/src/api.rs`(word_lyric_with_fallback 加 preference/reason)、
`ui/lib/src/app_settings.dart` + `settings_audio_page.dart`(分段控件)、
`ui/lib/main.dart`(解析与标注, 9 新单测)、真实抽样 `docs/c2-lyric-source-quality.md`
(AMLL 覆盖 6/17, 纯比较 AMLL 6/6 胜, 真实 auto 口径 AMLL 2/17)。

