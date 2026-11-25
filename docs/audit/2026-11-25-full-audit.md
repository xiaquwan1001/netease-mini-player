# 审计报告(只读子代理产出, 编排者归档 2026-11-25)

# 全仓功能性审计（2026-11-25，四条只读车道 + 同批落地复核）

> 范围: ① Rust 核心资源争用/并发正确性 ② Flutter+Kotlin 资源争用/泄漏 ③ 实现重复与功能冲突
> ④ 显示不正确/状态不同步。只报**有代码证据**的问题; 拿不准的标『待验证』, 并在同一批次的修复车道里判定。
> 审计原始记录(四份带证据代码片段的 raw 报告、修复车道任务书)见会话产出, **仓库侧以本文件为准**;
> 落地与门禁数字见 [`../PROGRESS.md`](../PROGRESS.md) 头部 v0.40.0 与
> [`../remaining-batches.md`](../remaining-batches.md) §11「2026-11-25 全仓审计遗留」。
> 行号是 **v0.40.0 落地后**的位置(修复前的行号只在原始证据里, 不在这里引用)。

## Review(结论)

- **无 P0**。四条车道共 4 份报告: P1 **13 条**、P2 **33 条**, 已全部有结论(修 / 登记 / 证伪)。
- **13 条 P1 全部落地**(2026-11-25 批次, commit `fix(audit): 全仓功能审计收口`), 每条都配「修复前红、修复后绿」的判据用例;
  其中 3 条是**用户可感知**的: 播错歌(U1)、听歌历史被清(R1)、云盘翻页跳回顶部(V1)。
- **明确证伪 2 条**: U9(热身轮播冷却 Timer 泄漏)在 `dispose()` 里早已 `cancel`;
  「`fetch` 路径每次 ENOENT」是 **`b070cbd` 起的既有缺陷**(`fetch` 从不创建 `.part`), 不是本批并发修复引入的。
- **仍开着 6 项**: D08 EQ 三端系数、D09 淡入淡出语义、D11 指纹 `appver`/UA(均需产品决策/高风险)、
  R2 的**跨进程**丢更新(进程内已修)、U2 的换曲瞬间时长(通道回传需改 codegen)、U3/U7 的 Kotlin 焦点语义。
  登记在 [`../remaining-batches.md`](../remaining-batches.md) §11。
- 门禁: `bash tools/ci-gates.sh verify` = **ALL GATES OK**(Rust **564** · Dart **1588 passed / 10 skipped** ·
  golden **21** 零重出 · clippy 0 · `dart analyze` 0 · Kotlin JVM 单测 32 · `lintDebug` 0 error)。

## 一、四条车道总表

| 车道 | 主题 | 结论 | P0 | P1 | P2 |
|---|---|---|---|---|---|
| A | Rust 核心资源争用 / 并发正确性 | P1 5 条全修; P2 中 2 条已修(R6/R9), 5 条在飞(L6) | 0 | 5 | 7 |
| B | UI/Kotlin 资源争用 / 泄漏 | P1 2 条全修; P2 中 4 条已修(U4/U5/U6/U8), 2 条在飞(L7), 1 条证伪(U9) | 0 | 2 | 7 |
| C | 实现重复 / 功能冲突 | P1 4 条全修; P2 中 9 条已修 + 1 条部分(D15), 3 条需产品决策(D08/D09/D11), 1 条设计债(D16) | 0 | 4 | 14 |
| D | 显示不正确 / 状态不同步 | P1 2 条全修; P2 5 条全修(含 V7『待验证』定性) | 0 | 2 | 5 |

前提已钉死(不是猜测): `flutter_rust_bridge` 的普通函数跑多线程池、`async` 函数跑多线程 tokio ⇒
两个 Dart `unawaited` 调用在 Rust 侧**真并行**。B 车道的 U1/U2 与 A 车道的 R1–R5 都建立在这个前提上。

## 二、13 条 P1(现象 / 根因 / 修法 / 判据)

### 2.1 Rust 并发(A 车道)

**R1｜原子写的临时文件名固定, 并发写同一文件会交错**(`core/crates/ncm-service/src/fsutil.rs:325,334,356`)
- 现象: `history.json` 偶发解析失败 ⇒ **本地播放历史整份清空**; 同类还有 loudness/设置落盘。
- 根因: tmp 名固定 `<name>.tmp`, 两个并发写各自 `create+truncate+write` 同一个 tmp, 再各自 rename ⇒ 内容交错。
- 修法: tmp 名唯一化 `<name>.tmp.<pid>.<seq>` + 进程内 `static WRITE_LOCK: Mutex<()>` 串行化 + `sync_all`。
- 判据: `fsutil::tests::concurrent_writes_never_interleave_and_leave_no_tmp`(并发写后无残留 tmp、内容完整)。

**R2｜响度表每次 open 整表读、整表写, 无锁** (`loudness_store.rs:28` + `ncm-ffi/src/api/playback.rs:119`)
- 现象: 切歌时 UI 有 4 处 `unawaited(applyLoudnessForTrack)`, 后写者用旧快照覆盖 ⇒ **刚测的响度丢更新**。
- 根因: 读-改-写窗口跨进程内多个调用, 无串行化(进程内)。
- 修法: 表级 `write_lock()`(锁内重读再合并)。**跨进程仍未解决**(见 §六)。
- 判据: `loudness_store::tests::concurrent_puts_keep_both_tracks`。

**R3｜同一首并发 `play_track` 无单飞, 两个下载截断同一个 `.part`**(`cache.rs:353` + `api/playback.rs:105`)
- 现象: 连点/重叠起播 ⇒ 双下载交错、rename ENOENT、**播放乱码或一上来没声音**。
- 根因: 第二个调用 `prepare_part`(`remove+create+truncate`)把第一个正在写的 inode 摘掉, 两边从 0 写同一路径。
- 修法: `start_progressive` 单飞 —— 同 key 已在飞时返回 `leader: false` 的句柄(共享 `part_path`/`done`, **只播不下载**);
  收尾由 `ProgressiveLeader::Drop` 兑现(删残片 / 置 `done` / 摘表, 见 `cache.rs:656-670`)。
- 判据: `cache::tests::start_progressive_reuses_inflight_download_for_same_key` ·
  `enforce_limit_never_evicts_playing_part` · `prepare_part_creates_missing_file_and_clears_stale_bytes`。

**R4｜每首起播都 `tokio::spawn` 整曲下载且丢弃句柄**(`api/playback.rs:23,30,150-160`)
- 现象: 快速切歌时旧下载继续占带宽直到读完; 配额统计还豁免 `.part` ⇒ **缓存超限**。
- 根因: 无取消、无并发上限。
- 修法: `download_slots()` 信号量(并发上限 3) + `bump_download_epoch()` 代际 —— 每次起播推进代际, 在飞下载按块检查
  发现过期即走 `download_progressive_cancellable` 收尾; `.part` 计入配额。
- 判据: `cache::tests::enforce_limit_counts_partial_downloads`(间接锁住「`.part` 计入配额」);
  代际取消本身靠日志 + 代码路径(无独立单测, 需真机复现连点)。

**R5｜音频命令线程被 `Decoder::build()` 的 10ms 阻塞循环挂住**(`ncm-playback/src/lib.rs:824,847,1142`)
- 现象: 起播瞬间 Pause/Stop/Seek/Volume **排队**, seek 1.5s 必超时。
- 根因: 渐进播放时解码器在空 `.part` 上阻塞等字节(上限 90s), 而命令线程与解码同一线程。
- 修法: `PendingPlay` —— `build_growing` 改成非阻塞探测(`probe_reads` 拿到 EOF 就返回), 命令线程回到事件循环,
  有新字节再由 tick 重试 `attempt_pending_play`; 用户 Pause 在待起播期间**被记住**。
- 判据: `build_growing_does_not_block_on_empty_part`(修复前在空 `.part` 上卡 5s, 默认上限 90s) ·
  `probe_reads_report_eof_instead_of_waiting` · `pending_play_starts_on_first_bytes_and_keeps_user_pause`。

### 2.2 UI/Kotlin 争用(B 车道)

**U1｜并发切歌「最后完成者覆盖」⇒ 播错歌**(`ui/lib/src/home/playback_coordinator.dart:288,369,507-582`)
- 现象: 快速连点 / 自动续播取链期间用户点歌 / 私人 FM ⇒ **声音是 B, 队列与高亮是 A**。
- 根因: 两次 `playSong` 各自 await 取链, 谁后返回谁把播放器设成自己的曲目; 而 `queue.index`/落盘属于另一次。
- 修法: `int _playGen` 代际守卫(`_superseded(gen)` 在每个 await 之后判定, 旧代直接 return)。
  范式与 `paged_list_view.dart`/`detail_faces.dart`/`comment_thread.dart` 一致。
- 判据: `ui/test/playback_coordinator_test.dart`「先发起的取链后返回: 旧的那次不覆盖播放器/快照/队列」
  (**修复前红: `plays == [2,1]`**)·「旧代取不到直链也不提示/不跳过」。

**U2｜`play` 通道回读 MediaController 缓存 ⇒ 旧曲位置落给新曲**(`MainActivity.kt:400-441,491-497`)
- 现象: 换曲后 5s 内退出, 冷启动按**旧曲位置**续播; 新曲 `startPositionMs` 可能超过自身时长 ⇒ 一按播放就跳下一首。
- 根因: `setMediaItem/prepare/play` 只是把命令发给会话, MediaController 缓存的 `PlayerInfo` 要靠 binder 回调刷新,
  而本方法还在主线程 ⇒ `stateMap(c)` 读到的是上一首的 `trackId/positionMs` 且 `playing=false`;
  这份快照被 Dart 直接 `adoptPlayer` 并立刻 force 落盘。
- 修法: `play` 分支返回值**用请求参数拼**(`playResult(trackId, startMs, volume)`), 不回读 controller。
- 判据: 通道层无自动化判据(Dart 侧现有用例锁住「落盘用已知 startMs」口径), 需真机复现: 换曲 → 5s 内杀进程 → 冷启动看续播位置。

### 2.3 实现重复 / 功能冲突(C 车道)

**D03｜`fetch` 与「边下边播」各写一套重试/门槛/rename, 且不等价**(`cache.rs:604-621` 唯一链: `stream_to_part_with_retry` + `finish_part`)
- 现象: Windows「下完再播」与 `ncm-cli play` 失败后 `.part` 不删 ⇒ 下次从残缺文件接着解码(一上来没声音/杂音), 残片长期占盘。
- 根因: 两处同构逻辑手抄两遍, `fetch` 那条不删 `.part`、rename 失败不重试。
- 修法: 合成一条链(`prepare_part` → `stream_to_part_with_retry` → `finish_part`), 64KiB 有效门槛 `MIN_VALID_AUDIO_BYTES` 一处定义。
- 判据: `cache::tests::prepare_part_creates_missing_file_and_clears_stale_bytes` · 既有下载门槛 / HTML 劫持用例(改前改后都绿, 锁住行为不变)。

**D05｜同一行红心两条路径, 有一条从不回流**(`ui/lib/src/home/song_action_wiring.dart:166` vs `ui/lib/src/detail/playlist_detail_page.dart:351,818`)
- 现象: 歌单详情页同屏两处红心(行尾 + 三点菜单)状态不同步, 从菜单改的那次**没有乐观更新也不 `syncActionState`**。
- 根因: 行内红心走动作宿主 B 路径, 菜单喜欢走旧 A 路径。
- 修法: 收成单入口 `toggleLikeFor`, 详情页 `onToggleLike` 一律走宿主; 配套 `likedOf` 访问器(见 §五 D06)。
- 判据: `ui/test/playlist_detail_like_test.dart`「D05: 详情页红心走动作宿主(不是自己再写一次 setLiked)」。

**D07｜LRC 兜底解析与 Rust 实现不同口径**(`core/crates/ncm-domain/src/lrc.rs:29,34` vs `ui/lib/src/lyric.dart:110`)
- 现象: 同一首歌在「Rust 解析成功」与「Dart 兜底解析」两条路上**时间轴不同**。
- 根因: Dart 兜底丢 `[offset]`、不去重、4 位小数按千位毫秒算 ⇒ 整首错位。
- 修法: `lyric.dart` 对齐 Rust 口径(offset 位移、去重、3 位小数截断、秒 ≥60 丢标签、翻译键用位移后毫秒)。
- 判据: `ui/test/lyric_test.dart` 新增「parseLrc 与 Rust lrc.rs 对等」7 条(期望值抄自 `lrc.rs` 的
  `offset_dedup_and_extra_fraction_digits` 等用例)。

**D12｜下载请求头三套, 桌面 curl 没有 Referer**(`ui/lib/src/platform.dart:102` / `cache.rs:24` / `MainActivity.kt:210`)
- 现象: 桌面端「下载到本地」在部分 CDN 上 **403**。
- 根因: 桌面走平台 `curl`, 请求头手拼且漏了 `Referer: https://music.163.com/`(Android 的 `DefaultHttpDataSource` 带了)。
- 修法: 头部口径收一份(`kMusic163Referer` + `kDownloadUserAgent`), 三处引用同一常量。
- 判据: `ui/test/platform_download_headers_test.dart`「必带 Referer(常量与 Rust 的 `DOWNLOAD_REFERER` 同值)」·「UA 有则透传(`-A`), 没有就不发」。

### 2.4 显示不正确(D 车道)

**V1｜`AsyncView` 只判 `connectionState` ⇒ 换 future 时插一帧 LoadingView 并把列表整个卸载**(`ui/lib/src/async_view.dart:137`)
- 现象: 云盘「加载更多」/删除一首后**跳回顶部**; 风格页刷新与歌单头部**闪回**。
- 根因: 父层换 future 时 `FutureBuilder` 会先给一帧 `waiting`, 此时 `hasData` 已有数据但旧代码仍渲染加载态 ⇒ 子树被卸载重建。
- 修法: 加载态条件是 `connectionState != done && !snap.hasData`(手里有旧数据就继续渲染旧数据)。
  因此不需要加 `PageStorageKey` —— 列表根本没被重挂载。
- 判据: `ui/test/async_view_test.dart`「future 分支: 换 future 的那一帧不闪 loading, 滚动位置不丢」
  (只 `pump()` 一帧断言; 既有用例用 `pumpAndSettle` 抓不到这一帧)。

**V2｜歌词请求失败后 `_lyricTrackId` 已占位 ⇒ 同曲永远短路, 无重试入口**(`ui/lib/src/home/lyric_controller.dart:219-233` + `lyrics_page.dart`)
- 现象: 一次网络抖动后, 该曲歌词永远显示「信息不可用」, 只能切歌才能恢复。
- 根因: 失败也把 `_lyricTrackId` 写住, 重进的守卫 `if (_lyricTrackId == trackId) return` 直接短路; 错误态也没有重试按钮。
- 修法: 失败**不占位**(清 `_lyricTrackId`) + `retryLoad()` 按当前曲目重取; 错误态给「重试」。
- 判据: `ui/test/lyrics_error_retry_test.dart`「歌词取数失败: 错误态带「重试」, 点了重新发一次请求」·
  `ui/test/lyric_test.dart`「失败不占位: 同一首失败后再 load 会重新发请求」·「重试通道: `retryLoad` 按当前曲目重新取一次」。

## 三、明确被证伪的两条(不要再按缺陷处理)

- **U9「热身轮播 `wheel_refresh.dart:71` 冷却 Timer 未在 `dispose` cancel」= 审计误报**。
  代码里 `dispose()` 早已 `cancel()`, 报告读到的是修订前版本的印象。**不改**。
- **「`fetch` 路径每次 ENOENT」不是本批并发修复引入的回归**。`b070cbd` 起 `fetch` 就**从不创建 `.part`**
  (写数据那侧是 `write + truncate`), 于是 Windows「下完再播」与 `ncm-cli play` 每次 ENOENT。
  D03 合并时补上 `prepare_part(&part)` 后连带修掉。⇒ 修 R3/D03 后若再看到 ENOENT, 那是**另一个**问题(先查 `.part` 是否被配额清掉)。

## 四、已核实做对、不要"顺手改"的

- Core 锁**不跨 await**; 插件快照解耦有判据用例; FFI 零 `StreamSink`(UI 走 500ms 轮询); HTTP 客户端基本复用;
  `ncm-plugin` 有界队列 + 取消守卫。
- 两个 ticker 共用同一个 `poll()`(不是双轮询); 全局槽位只有 `app_shell` 一处帧后写;
  通知按钮状态有 `onConnect → resync` 自愈闭环; 跑马灯单 `AnimationController` 无泄漏。
- `PlaybackStateStore.save` 的 tmp+rename 内容始终完整(与 R1 的 `fsutil` 不同: 它自带唯一 tmp)。
- Android `SimpleCache` / `Downloads` / Rust `AudioCache` 三处目录互斥, Dart 侧无同文件竞争 ——
  竞争面在 Rust 内部(R3/R4), 不在「Dart 与 Kotlin 抢同一个文件」。

## 五、P2 全清单(登记状态)

| 车道 | 条目 | 状态 |
|---|---|---|
| A | R6 inflight 清理非 RAII(`read_cache.rs:238-320`) | **已修**(RAII 守卫, `release_inflight` 走 Drop) |
| A | R7 `DATA_DIR/CORE/PLUGIN` 三步 set 非原子 + `init()` 返回入参 dir(`api.rs:189-197`) | 在飞(L6) |
| A | R8 每次 `fetch_ttml` 新建 `reqwest::Client`(`ttml_source.rs:358`) | 在飞(L6) |
| A | R9 `OnceLock<Result<Client>>` 永久缓存首次失败(`cache.rs:172`) | **已修** |
| A | R10「检查→打开」TOCTOU 被配额删掉后静默无声(`cache.rs:277` ↔ `ncm-playback/lib.rs:955`) | 在飞(L6) |
| A | R11 `LAST_EVENT/LAST_WARN` 全局单槽(`plugins/route.rs:468`) | 在飞(L6) |
| A | R12 读锁做取走语义 + 文档漂移(`api/plugin.rs:237`) | 在飞(L6) |
| B | U3 ALWAYS_PLAY 档 MV 起播与歌曲淡出重叠双声(`mv_playback.dart:104`) | 在飞(L7) |
| B | U4 MV 焦点 PAUSE 无条件 `pausedByFocus=true`(`MvPlayerActivity.kt:63-67`) | **已修**(只在焦点真丢时置位) |
| B | U5 `releaseCache()` 早于 `old.release()`(`PlaybackService.kt:490,988-1007`) | **已修**(`rebuildPlayer` 先 `old.release()` 再 `buildExoPlayer()`: 新缓存实例创建时旧 player 已释放, 不会两个 `SimpleCache` 同开一个目录) |
| B | U6 淡入「等起声」listener 只挂初始 player(`PlaybackService.kt:173,791-804`) | **已修**(`attachFadeGate` 在 `rebuildPlayer` 后重挂) |
| B | U7 ALWAYS_STOP 档每次 `configure` 都放弃并重抢焦点(`PlaybackService.kt:532-560`) | 在飞(L7) |
| B | U8 `cover_art.dart` 静态 HttpClient 无并发上限、同 URL 不合并 | **已修**(同 URL 共用一个在途 Future) |
| B | U9 热身轮播冷却 Timer 未 cancel(`wheel_refresh.dart:71`) | **证伪**(见 §三) |
| C | D01 相对时间 ×3 · D02 `mm:ss` ×2 | **已修**(`format.dart` 单份) |
| C | D04 64KiB 门槛 ×5 | **已修**(`MIN_VALID_AUDIO_BYTES` 一处) |
| C | D06 红心快照不同步 | **已修**(`likedOf` 访问器 + `_syncLikedFromHost`, 见下) |
| C | D08 EQ 三端系数(Dart 自述 LS/HS 忽略 Q) | **仍开**(需产品决策) |
| C | D09 淡入淡出两端语义不同(Android 三次曲线 + 有淡出 / 桌面线性且暂停无淡出) | **仍开**(需产品决策) |
| C | D10 版本比较两份 | **已修**(`version_compare_parity_test.dart` 4 条对等断言) |
| C | D11 identity `appver` 与 UA 版本自相矛盾 | **仍开**(碰风控指纹, 需最早单独立项 + 真机验证) |
| C | D13 VIP 头像/封面取色走裸 `NetworkImage`(可能 403) | **已修**(走 `cover_art` 的 UA 加载) |
| C | D14「是不是 Android」8 份 | **已修 8/8**(收口到 `platform_is.dart`, 三处 `debugForceAndroid` 合成一份) |
| C | D15 原子写三份 | **部分**: `fsutil` 为唯一实现, 另两处只加「指向 `fsutil`」注释(跨层依赖, 不合并) |
| C | D16 设置校验三处(`audioLevel` setter 无白名单) | **仍开**(生产只走 `update()`, 纯设计债) |
| C | D17 `player_bar.dart:149` 陈旧注释 | **已修** |
| C | D18 `ci.sh` 单包 vs `build-android.sh` split-per-abi | **已修**(两处口径一致) |
| D | V3 我的页消息未读数不刷新(`mine_view.dart:299`) | **已修**(`message_entry_card_test.dart`「从消息中心返回后重取未读数」) |
| D | V4 艺人榜粉丝数自写 `formatFans`(无亿档、0 显示空串) | **已修**(口径统一, `user_page_test.dart`「关注/粉丝大数字走 `formatFanCount`(万/亿一位小数)」) |
| D | V5 大数字原样铺出(12000 万) | **已修**(`comment_stats_bar_test.dart`「亿档: 100000000 → 1亿」· `playlist_detail_test.dart`「头部信息行: 播放量按量级显示, 首数保持精确」) |
| D | V6 Windows 设置页「Linux 端为纯软解」文案 | **已修**(`s5_audio_settings_page_test.dart`「Windows: 边听边存说明为不可用(整首下载后播放)」) |
| D | V7『待验证』换歌但 `positionMs` 未变时高亮不重算(`word_lyric_view.dart:241`) | **已定性并修**(`word_lyric_view_test.dart`「换歌: lines 变了而播放位置没变, 高亮按新表重算」) |

**D06 的落地口径**(从「部分」到「已修」, 用户选了推荐项 ①): `showPlaylistDetail(..., likedOf)` 传**访问器**而非快照,
详情页每次 build 开头 `_syncLikedFromHost()` 把宿主(主页 `_liked`)真相刷进页内副本, 只对本页已知 id 求值;
旧 `likedIds` 快照入参继续兼容。判据: `playlist_detail_like_test.dart`「宿主红心变了时详情页跟着回流」
(**去掉 `_syncLikedFromHost()` 调用即红**, 已实测)。

## 六、仍开着的(下一轮的输入)

| 项 | 为什么没做 | 落地条件 |
|---|---|---|
| **D08** EQ 三端系数(Android AudioEffect / Rust 双二阶 / Dart 预览) | 三端滤波器实现不同, 统一要产品决策「跟哪一端」+ 真机听感 | 需产品拍板 |
| **D09** 淡入淡出语义(`fadeMs` 在两端不等价) | 改文案还是桌面补淡出, 是产品取舍 | 需产品拍板 |
| **D11** identity `appver` 与 UA 版本不一致 | 碰风控指纹, 改错会被判异常客户端 | 单独立项 + 真机验证 |
| **R2 跨进程** | 进程内已用写锁 + 锁内重读解决; 两个进程共用同一 dataDir 仍会丢更新 | 需要跨进程文件锁(平台差异大) |
| **U2 时长回传** | 通道回传 DTO 时长要改 codegen(公共签名), 本批红线不允许 | 按 AGENTS「改 Rust API 三步」单独立项 |
| **U3 / U7 Kotlin 焦点语义** | MV 与歌曲淡出重叠、每次 `configure` 重抢焦点 | 见 `remaining-batches.md` §11 同名条目 |
| **D16** 设置 setter 校验收口 | 生产只走 `update()`, 纯设计债 | 顺手批带过即可 |
| **-462 人机验证的 App 内闭环** | 要先拿到一次真实 -462 的完整回包(字段名 / 是否需要 `event_id`+`sign`) | 见 [`../remaining-batches.md`](../remaining-batches.md) §11.A-8 |

## 七、门禁与复跑

- 全量: `bash tools/ci-gates.sh verify` ⇒ **ALL GATES OK**
  (Rust **564**: domain 50 + playback 55 + plugin 80 + provider 1 + service 365 + ffi 13;
  Dart **1588 passed / 10 skipped**; golden **21** 张零重出; clippy 0 warning; `dart analyze` 0; Kotlin JVM 32; `lintDebug` 0 error)。
- 只改 Rust 存储层时: `bash tools/ci-gates.sh rust-test`(或 `cd core && timeout 600 cargo test -p ncm-service --lib`)。
- 只改 UI 显示层时: 涉及 `AsyncView` / 歌词的用例**必须含单帧断言** —— `pumpAndSettle` 会跨过「换 future 的那一帧」, 抓不到闪回。
- 真机项(U2 落盘、R4 代际取消、U3 双声)在本机跑不出来, 只能真机复现后回填判据。
