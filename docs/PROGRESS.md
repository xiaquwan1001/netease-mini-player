# 进度记录(Progress)

> 最近更新: **2026-11-26**。已发布版本 **v0.41.8**(**Linux 侧 UI 交互审查 + 两端交互审计批量落地**): 用户报的两条先修掉 —— ① 进设置二级页时"闪一下"(逐帧复现: 推入路由的第一帧 `pageDepth > 1` 就把 NavigationRail 摘掉, 根布局从 Row 换 Column ⇒ 一级页横向跳 80dp、播放条 1200→1280 宽, 且这次重排落在转场动画开始之后) ⇒ 桌面导航**常驻** + 桌面页转场换 FadeForwards(旧页 0~25% 淡出, 450→220ms) + 播放条宽度改取自身约束; ② 同一次改动顺带补桌面键: **Esc 退一层**(接 `maybePop`, 与安卓返回键同一套优先级)、**空格=播放暂停(不翻页)**、**Ctrl+F / `/` 聚焦搜索**。随后两端只读审计(12+12 条, Linux 全部实测复现)挑 10 条落地: Android 状态栏/手势条图标随 **App 主题**(全仓此前 0 处 `SystemUiOverlayStyle`)、Login/MV 的 edge-to-edge insets、通知权限被拒后的「去系统设置」出口; 桌面 **最小窗口 420×480 + 尺寸记忆**(实测 200×300 会被夹住、900×600 重启后 0 偏差恢复); 播放条触控热区 34~38→**48dp**、拖动显示目标时间、右键走现有「歌曲操作」、**队列左滑可撤销**、Android 触感; 未登录「推荐歌单」从死路改成「去登录」; 首页补横屏 cutout 左右安全区。最后两条用户点单: **宽屏播放条音量入口**(与设置「精细音量」同一份 `AppSettings.volumeGainDb`, 实测拖到 -30.0 后 settings.json 同值)与 **MV 旋转重算画面**(几何只留一份 `applyVideoGeometry`; 实测竖 1079×607 ↔ 横 1808×1017, 关键坑是"只 post 一帧会抢在 layout 之前")。审计两条 P1 一并修: 二级页点歌单"点了没反应"(闭包握首页 context 绕过右栏判定)、搜索页按返回直接退 App(`canPop` 用快照算)。发布链同时修好: v0.41.6/v0.41.7 的 Release 都挂在 `Tests gate → android-unit`, 判据是 AGP marker POM 返回 200 却解析不到 ⇒ **不是版本不存在, 是 tag 流水线没有 Gradle 缓存**; 加 Google Maven 镜像 + verify job 缓存后 v0.41.8 的 Release 首次全绿(8 个产物)。门禁复核(编排者独立跑 `tools/ci-gates.sh verify`, 2026-11-26) = **EXIT=0 ALL GATES OK** —— Rust **581** · Dart **1686 passed**(仅排 network; 其中 golden **21** 张零重出) · Kotlin JVM **35** · clippy 0 · `dart analyze` 0 · `lintDebug` 0 error · 七道 checker OK; 另在独占 AVD `a36` 上做了真机级实测(深浅色状态栏图标/搜索返回/通知权限/横屏 cutout/MV 旋转), 未碰用户物理机。

> 上一版 **v0.40.0**(**全仓功能审计收口 —— 并发写/切歌竞态/显示口径/文案四类 13 个 P1 全修**: ① Rust 侧原子写 tmp 名唯一化 + 进程内写锁(并发写 `history.json` 不再交错, 那是「本地历史整份清空」的根因)、响度表锁内重读、同 key 下载单飞、下载并发上限 3 + 代际取消; 渐进起播改 `PendingPlay`(空 `.part` 上不再把音频命令线程挂 90s, Pause/Stop/Seek 即时响应); ② UI 侧切歌起播代际守卫(连点不再「后返回者覆盖」播错歌)、`play` 通道用请求参数返回值(换曲瞬间不再把旧曲位置落给新曲)、`AsyncView` 只在没有旧数据时进加载态(云盘「加载更多」不再跳回顶部)、歌词失败不占位 + 重试入口; ③ 重复实现合并(LRC 双解析对齐 Rust 口径、LRC 兜底不再丢 `[offset]`、红心单入口、下载请求头补 Referer、相对时间/`mm:ss`/版本比较各收一份、「是不是 Android」8 处收口到 `platform_is.dart`); ④ 顺带修掉 `fetch` 路径自 `b070cbd` 起从不创建 `.part` ⇒ Windows「下完再播」与 `ncm-cli play` 每次 ENOENT 的既有缺陷。**审计归档见 [`audit/2026-11-25-full-audit.md`](audit/2026-11-25-full-audit.md)**, 遗留(D08/D09/D11/R2 跨进程/U2 时长/U3·U7)见 `remaining-batches.md` §11「2026-11-25 全仓审计遗留」。门禁 `verify` = **ALL GATES OK**(Rust **564** · Dart **1588 passed / 10 skipped** · golden **21** 零重出 · Kotlin JVM **32** · clippy 0 · `dart analyze` 0; 复核 2026-11-25, 口径 `tools/ci-gates.sh verify`)。
>
> 上一版 **v0.39.0**(**用户反馈⑥ 三条 + 一个设置项**: ① 每日推荐本地缓存改成「只增不减」的索引 —— 根因有三条(歌单/单曲两条加载器**读-改-写交错**互相抹节, 后写者拿旧快照把对方那一节写成 null; 上游偶发 1~2 首的短响应直接覆盖掉 30 首; 单曲缓存原只挂在日推页上、账号键一变就放弃缓存 ⇒ 首页拉到的那份从不落盘)。修法: 每日期文件一把进程内串行锁 + **锁内重读**再合并 + 按 id **单调合并**(新响应只做增量补充), 首页「每日推荐」区块也走 `AccountActions.dailySongs` 缓存, `loadSongsForActive` 账号键不符时按当前键重建而不是透传; ② 历史日推跨天重复曲目折叠成一行「与更早的日推重复的 N 首」(点开仍可播, 日期列表副标题带「N 首与更早重复」), 与既有「歌单相同」标注同一口径; ③ **特性公告**: 新增 `release_notes.dart` 手工维护的用户语言条目, 「发现新版本」弹窗列当前版本之后的公告 + release 说明, 更新后首启弹「已更新到 X」(每版本一次, `AppSettings.announcedVersion` 把关, 全新安装不弹); ④ **「被其他 App 抢占时」设置项**(三档: 跟随系统(默认, 行为不变)/总是在后台播放(不申请不理会焦点)/总是停止播放(自己持焦点, 任何失去都暂停且**不自动续播**)), Android `AudioFocusPolicy` 纯逻辑 + 7 例 JVM 单测, MV 独立 Activity 同一口径, 桌面端系统混音无焦点概念(设置照常落盘, UI 明说只在 Android 生效)。门禁 `verify` = **ALL GATES OK**(Rust 572 · Dart **1550** · Kotlin 31 · golden 21 零重出; lld 坑仍按 `RUSTFLAGS=-fuse-ld=bfd` 处置)。
>
> 上一版 **v0.38.8**(**审计 P1 三条收口**: ① vendor `request.rs` 新增 `ensure_json_object` —— HTTP 200 + 非 JSON 对象(风控页/劫持 HTML/eapi 解密失败被 `unwrap_or` 吞掉)不再静默当成功, 而是报「上游响应不是 JSON 对象」, 与 -462 被吞同类残留(2026-11-24 错误码审计 #1); ② `friendlyError` 补 internal/notFound/unsupported 三条中性文案(`服务开小差了` / `内容不存在或已下架` / `当前版本不支持该功能`), 兜底臂错误不再把 `[internal] code=500` 原文甩给用户, 定位信息留在 `describeError`; ③ 云盘上传 NOS token 的 `resourceId` 缺失从静默空串改显式报错(v0.26.3 坑残余, 免白重试 5 次)。另: 两条只读审计(错误码 18 条 / 架构 6 条)归档 `docs/audit/2026-11-24-*.md`, vendor UPSTREAM.txt 补录 sortType×6 + server 特性裁剪。门禁 `verify` = **ALL GATES OK**(Rust 572 · Dart **1537** · golden 21 零重出; 本机 lld SIGSEGV 坑按既定处置 `RUSTFLAGS=-fuse-ld=bfd`)。受文案影响的老断言(9 个测试文件的 `[internal] boom` 字样)改用未知 kind 保留原文特性。
>
> 上一版 **v0.38.7**(**风控错误给用户可执行的出路**: `friendlyError` 之前只认 network/auth/forbidden, `riskControl` 落进兜底分支 ⇒ 界面上是 `[riskControl] code=-462: 请完成验证操作`(用户读不懂, 以为客户端坏了)。现在风险控制态给一句「被网易云安全风控拦截(需人机验证): 换网络(如手机流量)或登录后再试」+ 上游原文, 且**不把内部 kind 露给用户**; `retryable=false` 保证不会被 `retryNetwork` 反复重试(那只会加重风控)。用例 `net_retry_test` 新增 1 例(含文本前缀老路径)。门禁 `ALL GATES OK`。
>
> 上一版 **v0.38.6**(移动形态窗口(phosh 去应用名横栏, 逻辑宽≤1024 判移动, F11/MININCM_WINDOW 可覆写) + 封面背景发灰修正(kBackdropPrimaryMix 0.18→0.42, 加 kBackdropMinSaturation 不变量); 平板实机验收通过。)
>
> 上一版 **v0.38.5**(-462 风控不再被吞: vendor normalize_status 负数码原样保留 + 缺 msg 读 message, service -462→riskControl 收到; UI 走「被网易云安全风控拦截」引导。详见 .pi/memory/notes-api.md 的 -462 判据。)
>
> 上一版 **v0.38.4**(评论区补「时间」排序(CommentSortTab 三档, sortType=2) + 删单条「热门」标签; vendor comment_* 端点补 sortType 透传。)
>
> 上一版 **v0.38.3**(arm64 Linux 桌面修复(DATA_DIR 重复声明遮蔽回归 + 淡入只在恢复时生效 + 随包 WenQuanYi 字体救 CJK); deb 架构硬校验; 实机 elden 全通。)
>
> 上一版 **v0.38.2**(断电遗留 F6(淡出期对外报未播放, MainActivity stateMap 合并 isFadeOutPending)/F7(恢复续播位置 seekTo) 收口 + 封面面进度/总时长提示。)
>
> 上一版 **v0.38.0**(用户反馈第三批: SongRow.menuSource 默认 other 统一三点菜单 + 播客/歌单详情常驻搜索 + 他人常听无权限不报错 + 次数如实展示(预览 20 条)。)
>
> 上一版 **v0.37.0**(用户反馈第二批: 他人主页「常听」(FFI user_play_ranking 接线, 匿名 200+空数组, logged_in() 判登录态) + 设置页 IA 拆二级页面(settings_view 1062→171 行)。)
> 速览在下一节;**按日的批次记录已归档**(本文件只保留门禁基线 + 版本时间线, 批次明细见 `docs/archive/README.md`)。
> **门禁重跑史(第3~19+次, 2026-11-18~11-21)**: 每次(车道合并/发版前)编排者独立重跑 `tools/ci-gates.sh verify` 均 **EXIT=0 ALL GATES OK**; 数字演进 Rust 313→570 / Dart 1106→1554 / golden 18→21, 明细看 git 历史(本表只留最近一次)与环境坑注记(notes-wip.md)。
> 下一轮做什么: [`docs/remaining-batches.md`](remaining-batches.md) **§11**(功能, 余项均需人眼/真机) / **§12**(结构性债务, 主体已清) / **§13**(平台层审计剩余, 余项需真人);
> 2026-11-18 起的批次拆解与三条只读审计车道(文档/死代码/UI 浮层·返回栈·生命周期)见 `docs/archive/plans-2026-11/2026-11-18-next-batch.md`;文档总索引: [`docs/README.md`](README.md);
> 架构决策: [`docs/archive/architecture-restart.md`](archive/architecture-restart.md);
> 历史批次:v1(WebView 版) → [`docs/archive/PROGRESS-v1.md`](archive/PROGRESS-v1.md),
> 2026-11-03~11-12 批次与专题小节 → [`docs/archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> **本文件只保留 v0.20.0 起的活跃批次**(v0.8.0–v0.19.0 按日明细见 [`archive/PROGRESS-2026-11-13-11-19.md`](archive/PROGRESS-2026-11-13-11-19.md), 一行摘要仍在下面的版本时间线表)。

## 进度总览(2026-11-25 复核)

**2026-11-26 复核(v0.41.8 发版后, Linux UI 交互审查 + 两端交互审计批量落地, 编排者独立跑非 worker 自报)**: `bash tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK**
(Rust **581** · Dart **1686 passed**(`--exclude-tags network`)· golden **21** 张零重出 · Kotlin JVM **35** · clippy 0 warning · `dart analyze` 0 · `lintDebug` 0 error · 七道 checker OK),
与头部 v0.41.8 条目宣称的数字一致。**v0.41.6/v0.41.7 因为没有 Release 产物(CI 门可重复失败, 见 notes-build.md 2026-11-26 段), 其内容随 v0.41.8 一起首次发布。**

**2026-11-25 复核(v0.40.0 发版后, 审计批次 13 个 P1 落地, 编排者独立跑非 worker 自报)**: `bash tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK**
(Rust **564** · Dart **1588 passed / 10 skipped** · golden **21** 张零重出 · Kotlin JVM 单测 **32** · clippy 0 warning · `dart analyze` 0 · `lintDebug` 0 error · 七道 checker OK),
与头部 v0.40.0 条目宣称的数字**完全一致, 无分叉**。**旧口径数字(Rust 572 · Dart 1550)属 v0.39.0 之前那一版, 已作废**。

**2026-11-22 收尾核实(v0.38.0 之后无代码改动, 独立复跑)**: `bash tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK**
(Rust **545** · 全量 `flutter test` **1528 通过 / 0 失败** · golden **21** 张零重出 · clippy 0 · `dart analyze` 0 · android-unit/lint · 七道 checker OK),
与头部 v0.38.0 条目宣称的数字**完全一致, 无分叉**。同轮文档核实: `remaining-batches.md` §15 标题去「待开工」、§11 入口加「待办已清零」口径; `docs/health` FAIL 只剩 `~/hw-stability/.pi/memory/MEMORY.md` 超 50 KB(非本项目)。

**当前门禁**(本机实测, 离线口径; **权威口径只在本表**, README/README.en/remaining-batches 都是指针)。
复核口径: **2026-11-25, v0.40.0 发版后**(审计批次 13 个 P1 落地), 编排者独立跑 `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK**;
下表的数字就是这一轮的实测(Rust 564 · Dart 1588 passed / 10 skipped · golden 21 · Kotlin JVM 32 · clippy 0 · analyze 0)。
历史复核口径(留痕, 数字已过期): **2026-11-17 晚在 main 上合并 p18/uib-c/p10/p11 四条车道后逐门重跑**(编排者独立跑, 不采信 worker 自报);
**v0.21.0 发版后(2026-11-17)再次独立重跑复核**: Rust 313 · Dart 1106 · golden 18 张 · 四道 checker 全 OK。
(Rust **313** · Dart **1128** · golden 18 张 · clippy 0 · analyze 0 · 四道 checker OK · **android-lint 已 0 error 并进 verify**)。
全量 `flutter test` **1148 / 0 失败** · `dart analyze` **0** · 三门 checker OK · `api-coverage` 161 导出 / 9 无入口。
全量 `flutter test` **1148 通过 / 0 失败**(golden 18 未重出) · `dart format` 干净 · token / row-padding / write-guard 三门 OK;
Rust 侧本批未动(仍 313, 未重跑)。
Rust **325** 通过 / 0 失败 · clippy **0** · 格式门干净 · 全量 `flutter test` **1293 通过 / 0 失败**(golden **20** 张) ·
`dart analyze` **0** · Kotlin 单测 **10** 通过 / 0 失败 · `lintDebug` **0 error / 9 warning** · `docs`/`tokens`/`row-padding`/`sheet-entry`/`write-guard` 五道 checker OK。
**2026-11-21(Android 插件宿主接线, v0.34.0 发版前)重跑**: `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK** · Rust **505→503**(删掉 2 例只测「Android 空视图」构造函数的用例, 其余不动) · 全量 `flutter test` **1480 通过 / 0 跳 / 0 失败**(golden 21 零重出; 首跑因全量 `cargo clean` 后没重建 `libncm_ffi.so` 而有 10 例 skip, 重建后 0 skip) · `dart analyze` 0 · clippy 0 · `lintDebug` 0 error · Kotlin 单测 10 · 七道 checker OK。**环境注**: 本轮同窗口连遇三次产物损坏 —— `libm-*.rlib sh_addralign` / rust-lld `X86_64::relocate` SIGSEGV(全量 `cargo clean` 后消失) / cargokit 目标目录里 `.rcgu.o` 的 `unknown relocation (1977)`(清 `ui/build/rust_lib_minincm` 后消失) + Gradle JVM `SIGBUS BUS_ADRERR`;证据全部交 `~/hw-stability/evidence/inbox/20261121-netease-mini-player-*`(AGENTS 规则 12, 不在项目里深挖)。
**2026-11-21(插件平台自报, v0.33.4 发版前)重跑**: `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK** · Rust **505**(plugin provider +2 平台自报/空声明, service `sources_report_what_script_declared` +1) · 全量 `flutter test` **1480 通过 / 0 失败**(golden 21 零重出) · `dart analyze` 0 · clippy 0 · 七道 checker OK。**环境注**: 本轮首跑 `cargo test` 链接报 `rust-lld: ... libm-*.rlib: section sh_addralign is too large` = 产物损坏, `cargo clean -p libm` 后即绿(证据已交 `~/hw-stability/evidence/inbox/20261121-netease-mini-player-libm-rlib-addralign/`)。
**2026-11-21(插件日志通道, v0.33.3 发版前)重跑**: `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK** · Rust **502**(service `take_logs_groups_by_plugin_and_drains` +1) · 全量 `flutter test` **1479 通过 / 0 失败**(golden 21 零重出, `plugin_page_test` 日志段 +1) · `dart analyze` 0 · clippy 0 · 七道 checker OK。
**2026-11-21(取链歌曲上下文, v0.33.2 发版前)重跑**: `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK** · Rust **501**(plugin 65→67: `music_info_echo` 两例锁 musicInfo 字段口径) · 全量 `flutter test` **1478 通过 / 0 失败**(golden 21 零重出) · `dart analyze` 0 · clippy 0 · 七道 checker OK。
**同轮补记(2026-11-21, 插件页音源路由段落地后, v0.33.1 发版前)**: 只动 Dart ⇒ 未重跑 Rust 门; 全量 `flutter test --exclude-tags network` = **1478 通过 / 0 失败**(golden **21** 张零重出) · `dart analyze` **No issues found** · `dart format` 只格式化改动文件(干净) · 七道 checker 全 OK。
**同轮环境注**: 上一轮本车道因宿主机 ENOSPC(hw-stability 的 `pcache-guard` 把 `/proc/*/maps` 写成 154 GB)失败, 非代码问题; 本轮复跑即全绿, 磁盘 78%。
Rust **325** 通过 / 0 失败 · clippy **0** · 格式门干净 · 全量 `flutter test` **1289 通过 / 0 失败**(golden **20** 张) ·
`dart analyze` **0** · Kotlin 单测 **10** 通过 / 0 失败 · `lintDebug` **0 error / 9 warning** · 四道 checker(含 `sheet-entry` 待迁 0) OK。
(删掉「存为歌单」面板 5 例 + controller 2 例, 新增提示/live-sync/定位/行高 7 例)。
本批数字变化: v0.21.0 之后 Dart **1106→1124**(托盘关闭 lane `desktop_close_behavior_test.dart` 18 例) → **1124→1128**
(settings codec 4 例) → **1128→1130**(播放条 seek 排队 8 例重写, +2); Rust 未动(仍 313)。
golden 只重出 recommend 2 张(8/12 二分取消后日推预览行左移 4dp、行矮 8dp) · 新增设备级门 `androidTest`(模拟器, 手工)。




| 门 | 结果 |
|---|---|
| `cargo test --offline --workspace --exclude ncm-api-rs` | **564** 通过 / 0 失败(2026-11-25 实测; 只排除 vendor 联网 smoke)  domain **50** + playback **55** + **plugin 80**(lib 28 + integration 51: sandbox 20 + provider 16 + storage_file 7 + policy_public_api 4 + worker_limits 4) + plugin doctest 1 + provider **1** + service **365** + ffi **13** = 564; 542→564 = 2026-11-25 审计批次 13 个 P1 的判据用例(R1 并发写/2 响度表/3 下载单飞/5 渐进起播 5 例 + service/plugin/ffi 各若干) + L2 的 LRC 对等; 历史演进: 467→499 = 插件路由层(service +23 路由/回落判定, ffi +3 路由模式导出, plugin +2) + LX 兼容层(plugin +4: sandbox 17→20 / provider 6→7) → 501 = 取链上下文(plugin +2: `music_info_echo` 锁 musicInfo 字段口径) → 542 = 切片 A2 判定快照 + 桌面淡入包络 |
| `ncm-plugin` 门禁归属(§7.9) | **已并回主门禁**(2026-11-20 切片 2 第一步起 `rust-lint`/`rust-test` 不再 `--exclude`; 独立门 `rust-plugin` 删除, 口径只留一份)。**平台范围**: `service -> plugin` 依赖只在 `cfg(not(target_os = "android"))` 生效(rquickjs-sys 0.12.2 无 Android bindings), Android 构建不含插件 |
| `cargo clippy --workspace --all-targets -- -D warnings` | **0 warning** |
| `cargo fmt --all -- --check` · `dart format --set-exit-if-changed lib test` | 干净(两道格式门) |
| `flutter test --exclude-tags network`(全量, 含 golden) | **1588** 通过 / **10 skip** / 0 失败(golden **21** 张零重出; 2026-11-25 实测; 10 skip 全是 `ui/test/lyric_source_rust_parity_test.dart` —— 拿不到 `core/target/debug/libncm_ffi.so` 时整组 skip, 不是失败)  演进: 1123 → 1148 → 1163 → 1205 → 1243 → 1289(v0.26.0 夜间三车道) → 1293(v0.26.1 补测) → 1299(§12.6 按域 diff 通知 6 例) → 1320(S4 主从分栏 +21 例) → 1322(U-08 真壳首帧回归 +2 例) → 1372(v0.28.0 四车道) → 1401(用户反馈三提交) → 1464(v0.29.0) → 1467(v0.30.0) → 1467(v0.31.0: 纯重构/迁移, 零新增用例) → **1475**(v0.32.0 插件管理页 +8) → **1478**(v0.33.1 音源路由 +3) → **1479**(v0.33.3 日志段 +1) → **1480**(v0.33.4 平台自报 +1) → **1482**(v0.34.4 插件导入 +2) → **1550**(v0.39.0) → **1588**(v0.40.0: 13 个 P1 判据 + 歌词对等 7 例 + D06 回流, 见 [`audit/2026-11-25-full-audit.md`](audit/2026-11-25-full-audit.md)) |
| `./gradlew :app:testDebugUnitTest`(`ci-gates.sh android-unit`, 已进 `verify`) | **32** 通过 / 0 失败(2026-11-25 实测; `LoginCookiePolicyTest` 5 + `AudioFocusPolicyTest` 7 + `AudioBufferPolicyTest` 3 + `VolumeHandoffPolicyTest` 3 + `EqProfileParserFixtureTest` 3 + `FadePolicyTest` 7 + `MvAudioFocusPolicyTest` 4; EQ 三端共享夹具 + MV 音频焦点 + 缓冲水位 + 登录 cookie + 淡入曲线, 均不碰设备) |
| `ci-gates.sh android-instrumented`(`connectedDebugAndroidTest`, 需模拟器; `NCM_INSTRUMENTED=1` 才进 `verify`) / 可选 `android-test-emu`(钉 emulator-5554, 必须显式调用) | **6 例 → 5 通过 / 1 skip**(`NotificationSlotsTest` 3: 渠道 + 5 个 action 槽位 + 状态回推; `NotificationClickTest` 3, 其中 1 例 assume-skip —— 通知点击被 BAL 拦, 需真人开 App 才补执行)。**2026-11-19 复核**: a34(emulator-5554, SDK 34)连跑两轮均 **0 失败**, 用例 **15.9s** / 任务 **23–25s** |
| `./gradlew :app:lintDebug`(`ci-gates.sh android-lint`, **已进 `verify` + GitHub CI 阻塞门**) | **0 error / 9 warning**(9 条全是依赖版本提示)。2026-11-18 清零: 66×media3 `UnstableApi` 收口到类级 `@OptIn`/`@UnstableApi` + 1×`GestureBackNavigation` 迁到 `OnBackPressedDispatcher`; 仍未用 baseline 掩盖 |
| `ci-gates.sh desktop-smoke`(`NCM_DESKTOP_SMOKE=1` 才进 `verify`; 需现成 release bundle) | **PASS / 0 FAIL / 0 SKIP, 26 项 OK, 61s**(2026-11-18 本机实测): 启动+数据目录+`identity.json`+WM_CLASS+几何+单实例+SIGTERM · **⑦ 关闭行为三例**(默认退出 / 托盘降级 / 有宿主时 unmap + SecondaryActivate 恢复) · **⑧ 交互级**(windowfocus 回读 + XTEST 按键 4 次 + 播放条 4 次点击 + 缩窗 640x480/320x240/还原, 每步断言存活且几何·标题·Map State 不变, 主窗口仍 1 个, 日志无崩溃痕迹) |
| `dart analyze` | **0 issue**(error / warning / info 全清) |
| `tools/check-write-guard.sh` | OK(测试不触网/不直连写接口) |
| `tools/check-tokens.sh --strict` | **OK**(间距/圆角/字号 0 越界, 例外必须写 `// token-ok: 理由`) |
| `tools/check-row-padding.sh --strict`(`ci-gates.sh row-padding`, 已进 `verify`) | **OK**(25 处行留白 / **3 个**具名口径 + 纵向只允许 0/6; 具名工厂 `SongRow.xxx(` 也计入 —— 数量比 C 步前少 2 处是因为同构参数收进了工厂, 见 2026-11-17 两个小节) |
| `tools/check-docs.sh`(`ci-gates.sh docs`, 2026-11-19 新门, 已进 `verify`) | **PASS**: 相对链接死链 **0** · `docs/` 根未进索引 **0** · 白名单命中 **0/0**。扫描范围 = `docs/**/*.md` + 仓库根所有 `*.md`(锚点丢弃, 只校验文件部分); `docs/archive/**` 只查链接不强制进索引 |
| 接口覆盖 | **135/136**(唯一未接入 `vip_sign_info` 是**有意弃用**, 见 v0.12.5 小节)。FFI 导出 **171** 里 **6 个**无 UI 入口(2026-11-20 修 `tools/api-coverage.sh`: FFI 侧改收 `core/crates/ncm-ffi/src/api/*.rs`, 与 SERVICE 同口径 —— T2 拆目录后单文件只剩 `init`, 统计曾静默退化成「2」), 全是有意保留或待决策: **保留 4**(cache_stats / cloud_song_url / eq_profile_normalize / player_tuning) · **待产品决策 2**(consent_plaintext_storage / user_play_ranking)。2026-11-18 修了脚本的入口判定(类型名与构造调用曾把导出顶替成"有入口"), 并把 3 条真死出口删掉(161→158 / 9→6); 明细见 `docs/api-coverage.md` 文首与 `docs/archive/plans-2026-11/deadcode-audit-2026-11-18.md` |

凭据落盘 0600 文件骨架 + 系统钥匙串(Android Keystore / Linux secret-service / Windows DPAPI)。

**版本时间线**:

| 版本 | 日期 | 里程碑 |
|---|---|---|
| **v0.34.4** | **2026-11-21** | **插件导入(粘贴脚本文本)**(README §4 第 2 项的第一步):…(明细见 git 历史与本文件归档) |
| **v0.34.3** | **2026-11-21** | **Android 插件宿主设备侧验收**:…(明细见 git 历史与本文件归档) |
| **v0.34.2** | **2026-11-21** | **Release 构建 job 的 libclang 修正**: `release.yml` 的「Build Android + Linux assets」/「Build Linux arm64」两处 apt 列表由 `clang` 改为 `clang libclang-dev` —— `clang` 包不带 `libclang.so`, 而 Android 目标的 bindgen 必须有它(`android-bindgen-env.sh` 会明确报「找不到 libclan…(明细见 git 历史与本文件归档) |
| **v0.34.1** | **2026-11-21** | **Android 接线的 CI 修正**:…(明细见 git 历史与本文件归档) |
| **v0.34.0** | **2026-11-21** | **Android 插件宿主(四端统一)**(用户拍板走评估文档推荐路径 b):…(明细见 git 历史与本文件归档) |
| **v0.33.4** | **2026-11-21** | **插件平台自报(上游 LX `inited` 握手回传)**(审计补齐清单 #8): `ScriptEngine::declared_sources()` 从 `__lxSends()` 抽 `inited.data.sources` 的 key(去重+字典序, 形状不对给空不报错) → `Provider::declared_sources()` 默认空方法 + `ScriptProvider` 覆盖 → `PluginHost::sources()`(BTreeMap<…(明细见 git 历史与本文件归档) |
| **v0.33.3** | **2026-11-21** | **插件日志通道到 UI**(切片 3 波次 2 G): `ncm_provider::Provider` 新增默认 `take_logs() -> Vec<String>`(内置 provider 恒空) + `ScriptProvider` 覆盖(取走语义, 原 inherent 方法迁到 trait impl); `PluginHost::take_logs()` 遍历注册表按插件 id 分组、空组丢弃, `Core::plugin_take_logs()` 转发; F…(明细见 git 历史与本文件归档) |
| **v0.33.2** | **2026-11-21** | **取链带上歌曲上下文**(切片 3 波次 2 F): 新 `ncm_provider::SongUrlMeta{name,singer,album_name,album_id,interval,song_mid}` + `SongUrlRequest::with_meta`(`SongUrlRequest` 由 Copy 改 Clone; 取链闭包改影子引用捕获); `ncm-ffi::song_url` 加 `name/singer/album_name/interval…(明细见 git 历史与本文件归档) |
| **v0.33.1** | **2026-11-21** | **插件页「音源路由」段**(切片 3 波次 2 E): 设置 → 关于 → 插件里新增路由选择 —— `auto`(只有一个可用插件时用它, 多候选不一致回落内置)/ `builtin`(只用官方接口)/ `plugin:<id>`(优先某插件); 每能力两条只读判定行(`songUrl`/`search` 的 target · reason · detail, 来自 `plugin_route_plan` 纯判定); 写操作复用页内 `_run`(串行 + 重取数 + t…(明细见 git 历史与本文件归档) |
| **v0.33.0** | **2026-11-21** | **插件路由层接进产品链路 + 插件 LX 兼容层核心**(两车道):…(明细见 git 历史与本文件归档) |
| **v0.32.0** | **2026-11-20** | **插件宿主切片 2 收口 + §7.8 全收口**(两车道并行后合并):…(明细见 git 历史与本文件归档) |
| **v0.31.0** | **2026-11-20** | **审计 §7.7 第二刀 + §7.8 第一批 + 插件宿主切片 2 第一步**(三车道并行):…(明细见 git 历史与本文件归档) |
| **v0.30.0** | **2026-11-20** | **审计 §7.7 第一步 + 扫码登录口径**:…(明细见 git 历史与本文件归档) |
| **v0.29.0** | **2026-11-20** | **用户 8 条反馈 + 架构审计 §7 落地批**(9 条并行车道):…(明细见 git 历史与本文件归档) |
| **v0.28.0** | **2026-11-19** | **用户 12 条反馈批**(四车道):…(明细见 git 历史与本文件归档) |
| **v0.27.1** | **2026-11-19** | **U-08 收口**: 真壳首帧不再 `setState() called during build` —— `HomeWiring` 的两个 `ValueNotifier` 槽位(动作宿主/播放条回调)**一律帧后投递**(壳层 `ContentWidthLimit` 是 LayoutBuilder, 页面建树落在 layout 阶段), `_clearSlots` 对称帧后再清; 回归 `test/app_shell_first_frame_test.dart` 2 例…(明细见 git 历史与本文件归档) |
| **v0.27.0** | **2026-11-19** | **横屏双列 S4(方案 B 主从分栏)**: `detailPaneSlot` + `openDetail` 统一入口(**右栏不是路由**, 故 `pageDepth`/`modalRouteOpen`/`dismissAllPopups` 登记面零改动, 不加嵌套 Navigator); 歌单详情 `embedded` 形态; 返回键新层级 `closeDetailPane`(宽档只清右栏 / 窄档 pop, 两语义各有用例); 选中态用外框而非第二套行高亮; 840 …(明细见 git 历史与本文件归档) |
| **v0.26.4** | **2026-11-19** | **音源插件宿主切片 1(不接产品)**: 新 crate `ncm-plugin` —— rquickjs 0.12.2 宿主 + lx 兼容层(`lx.on/request/log/storage/utils`)+ 沙箱预算(8s interrupt / 32MB / 512KB 栈 / 8 请求)+ 逃逸面断言 + `ScriptProvider` 实现既有 `Provider`(未注册路由, 不进 `ncm_ffi`/APK)。红→绿实证(死循环与内存炸弹先红后绿)。Rust **347→368** |
| **v0.26.3** | **2026-11-19** | **云盘上传 400 修复**(用户报「安卓端上传任意音频都是上传识别失败, internal code 400, songid=0」): 根因 `/api/nos/token/alloc` 的 `resourceId` 是**数字**(如 84382086772), 旧代码用 `str_of` 只认字符串 ⇒ 传给 info/v2 的 resourceId 是空串 ⇒ 服务端回 `{"code":400,"songId":"0"}`; 顺带修 check 的 `songId…(明细见 git 历史与本文件归档) |
| **v0.26.2** | **2026-11-19** | `tools/smoke-appimage.sh` 修相对路径假 FAIL(`APPIMAGE=dist/xxx.AppImage` 文档写法在 cd 之后失效); 用真产物 v0.26.1 AppImage 实测 PASS/39s |
| **v0.26.1** | **2026-11-19** | 补播放条取链提示的渲染级回归(4 例) —— 纯测试提交, 产物与 v0.26.0 等价; Dart **1293** |
| **v0.26.0** | **2026-11-19** | **夜间三车道发版**:…(明细见 git 历史与本文件归档) |
| **v0.25.0** | **2026-11-18** | 双列 **S2**(播客详情 300-12-528 + 1280x720 golden) · **U-03** 统一浮层入口 `showAppSheet`(31 处 + `check-sheet-entry` 门) · 生命周期守卫 **U-05/06/07**; Dart 1243 |
| **v0.24.0** | **2026-11-18** | 用户 4 条反馈(桌面播放条去队列排位 / 关注页横条按可用宽自适应 + 点击语义统一 / 刷新合并 / 桌面滚轮到顶刷新) + **AppImage 冒烟脚本** + 双列 **S0/S1**(歌单详情双列) |
| **v0.23.0** | **2026-11-18** | 用户 10 条反馈: 播放条三档文案 / EQ 导入先走 Rust 校验 + 图表 +15% / **Linux 托盘 7 项播放控制** / **定时关闭**(立刻·播完这首) / 字号滑块落点对齐 / Android 省略「关闭主窗口时」 |
| **v0.22.1** | **2026-11-18** | **U-01** 切页收起全部浮层(单一入口 `dismissAllPopups`) + **U-02** 队列面板不再误关确认框 + **U-04** MV 双音源(暂停歌曲 + 音频焦点) + FFI 死导出 -3(161→158) |
| **v0.22.0** | **2026-11-18** | 宽屏三档响应式(断点 + 内容限宽 + 宽档 NavigationRail, 弹层留白随遮罩压暗) + `api-coverage` 门假绿修复(6→9) + 死码清账 51 行 + 删 `cupertino_icons` |
| **v0.21.0** | **2026-11-17** | **用户 6 项反馈批**: ① Android 逐字歌词高光行贴左(`TextPainter` 只给 maxWidth) ② Linux 播放条宽屏留白/控件间隔 ③ 未登录时推荐页不再暴露 `[auth] Unknown error`(登录态门 + `friendlyError` auth 分支) ④ Linux 登录弹层切 tab 自动收起 ⑤ PC 网页登录风控**静态分析报告**(5 条差异, 未改登录码) ⑥ 超长当前行歌词横向自动滚动(复用唯一跑马灯内核); Dart **1089→1106**, golden 未变 |
| **v0.20.1** | **2026-11-17** | **反馈批**(两条用户反馈 + 两处平台缺口): ① 歌词高光行 18→16sp 且两种行都居中(修「换行时左右瞬移」) ② 冷启动恢复/进详情页**主动预取**歌词(不再干等「信息不可用」) ③ **AppImage 首启集成到应用菜单** ④ `ci-gates.sh` 新增 `android-instrumented`(a34 3/3) 与 `desktop-smoke`(xvfb+dbus 无头冒烟); Dart **1075→1089** |
| **v0.20.0** | **2026-11-17** | **四车道批**: P-18 后半(application-id 统一 + 数据目录一次性迁移)· P-10 方案 B(渐进期 seek 登记 + 下载完成换源重建解码器)· 列表行 C 级收尾(8/12 二分取消 + 纵向 pitch + SongRow 工厂)· P-11 第一步(首个 `androidTest` + `notif-slots` 断言脚本); Rust **300→313** / Dart **1061→1075** |