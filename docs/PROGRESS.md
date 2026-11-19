# 进度记录(Progress)

> 最近更新: **2026-11-19**。已发布版本 **v0.28.0**(**用户 12 条反馈批**; v0.27.1 U-08 真壳首帧修复; v0.27.0 横屏双列 S4 主从分栏; v0.26.4 音源插件宿主切片 1; v0.26.3 云盘上传 400 修复; v0.26.2 修 `smoke-appimage` 相对路径假 FAIL; v0.26.1 播放条取链提示渲染级回归; v0.26.0 音源信息无损 + 缓冲/下载加固 + 详情页歌词⇄封面 + 匿名诊断通道),
> 见批次时间线最上面那条; 速览在下一节, 批次记录从「批次时间线」起倒序。
> 下一轮做什么: [`docs/remaining-batches.md`](remaining-batches.md) **§11**(功能, 余项均需人眼/真机) / **§12**(结构性债务, 主体已清) / **§13**(平台层审计剩余, 余项需真人);
> 2026-11-18 起的批次拆解与三条只读审计车道(文档/死代码/UI 浮层·返回栈·生命周期)见 `docs/archive/plans-2026-11/2026-11-18-next-batch.md`;文档总索引: [`docs/README.md`](README.md);
> 架构决策: [`docs/archive/architecture-restart.md`](archive/architecture-restart.md);
> 历史批次:v1(WebView 版) → [`docs/archive/PROGRESS-v1.md`](archive/PROGRESS-v1.md),
> 2026-11-03~11-12 批次与专题小节 → [`docs/archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> **本文件只保留 v0.20.0 起的活跃批次**(v0.8.0–v0.19.0 按日明细见 [`archive/PROGRESS-2026-11-13-11-19.md`](archive/PROGRESS-2026-11-13-11-19.md), 一行摘要仍在下面的版本时间线表)。

## 进度总览(2026-11-17 复核)

**当前门禁**(本机实测, 离线口径; **权威口径只在本表**, README/README.en/remaining-batches 都是指针)。
复核口径: **2026-11-17 晚在 main 上合并 p18/uib-c/p10/p11 四条车道后逐门重跑**(编排者独立跑, 不采信 worker 自报);
**v0.21.0 发版后(2026-11-17)再次独立重跑复核**: Rust 313 · Dart 1106 · golden 18 张 · 四道 checker 全 OK。
**2026-11-18 早(lint 清零 + settings codec 拆分后)第三次重跑**: `tools/ci-gates.sh verify` = **ALL GATES OK**
(Rust **313** · Dart **1128** · golden 18 张 · clippy 0 · analyze 0 · 四道 checker OK · **android-lint 已 0 error 并进 verify**)。
**2026-11-18 中(P-11 交互级 + P-10 UI 面后)第四次重跑**: 仍 **ALL GATES OK**, Dart **1130**。
**2026-11-18 晚(死码清账后)第七次重跑**(编排者独立): `cargo test` **313** · clippy **0** · fmt 干净 ·
全量 `flutter test` **1148 / 0 失败** · `dart analyze` **0** · 三门 checker OK · `api-coverage` 161 导出 / 9 无入口。
**2026-11-18 晚(响应式布局三档 + 弹层留白压暗后)第六次重跑**(编排者独立): `dart analyze` **0 issue** ·
全量 `flutter test` **1148 通过 / 0 失败**(golden 18 未重出) · `dart format` 干净 · token / row-padding / write-guard 三门 OK;
Rust 侧本批未动(仍 313, 未重跑)。
**2026-11-19 晚(用户验收三项通过后, v0.26.2 之后文档/门禁提交树上)第九次重跑**(编排者独立, `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK**, 54s):
Rust **325** 通过 / 0 失败 · clippy **0** · 格式门干净 · 全量 `flutter test` **1293 通过 / 0 失败**(golden **20** 张) ·
`dart analyze` **0** · Kotlin 单测 **10** 通过 / 0 失败 · `lintDebug` **0 error / 9 warning** · `docs`/`tokens`/`row-padding`/`sheet-entry`/`write-guard` 五道 checker OK。
**2026-11-19 晚(合并 §12.6 第二步车道 `lane/settings-snapshot` 后)第十次重跑**(编排者独立, lane 内与 main 合并后各跑一次, 均 **EXIT=0 ALL GATES OK**): Rust **325** · 全量 `flutter test` **1299 通过 / 0 失败**(golden **20** 张, +6 例 `app_settings_scoped_notify_test.dart`) · `dart analyze` **0** · 其余门同上。
**2026-11-19 晚(合并云盘分片车道 `lane/cloud-chunk-upload` 后)第十一次重跑**(编排者独立, lane 内与 main 合并后各跑一次, 均 **EXIT=0 ALL GATES OK**): Rust **325→345**(service 227→247, 分片规划/引擎/续传/重试 + 云盘单请求路径假 HTTP 服务 20 例) · 全量 `flutter test` **1299** · clippy **0** · `dart analyze` **0** · 五道 checker OK。
**2026-11-19 晚(云盘上传 400 修复后, v0.26.3 发版前)第十二次重跑**(编排者独立): `tools/ci-gates.sh verify` **EXIT=0 ALL GATES OK** · Rust **345→347**(+2 例 resourceId/songId 解析回归) · Dart **1299** · clippy **0** · `dart analyze` **0** · `lintDebug` 0 error · 五道 checker OK。
**2026-11-19 晚(合并横屏主从分栏 S4 车道 `lane/wide-s4` 后)第十四次重跑**(编排者独立, lane 内与 main 合并后各跑一次, 均 **EXIT=0 ALL GATES OK**): Rust **368** · 全量 `flutter test` **1320 通过 / 0 失败**(golden **21** 张, 既有 20 张零重出) · `dart analyze` **0** · clippy **0** · `lintDebug` 0 error · 六道 checker OK。
**2026-11-19 晚(合并音源插件宿主切片 1 车道 `lane/plugin-host` 后)第十三次重跑**(编排者独立, lane 内与 main 合并后各跑一次, 均 **EXIT=0 ALL GATES OK**): Rust **347→368**(+ncm-plugin 21 例) · Dart **1299** · golden 20 · clippy **0** · `dart analyze` **0** · `lintDebug` 0 error · 六道 checker OK。
**2026-11-19 晚(v0.27.0 之后、U-08 修复树)第十五次重跑**(编排者独立, `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK**): Rust **368** · 全量 `flutter test` **1320→1322 通过 / 0 失败**(golden **21** 张零重出) · `dart analyze` **0** · clippy **0** · 六道 checker OK。**注**: 本轮首跑被本机随机 SIGSEGV 打断(`flutter_tester` 的 `Shell subprocess crashed with segmentation fault`, 同文件单跑 2/2 绿 ⇒ 非回归), 证据已上交 `~/hw-stability/evidence/inbox/20261119-netease-mini-player-fluttertester-segv/`, 复跑即绿。
**2026-11-19 早(夜间三车道合并回 main 后, v0.26.0 发版前)第八次重跑**(编排者独立, `tools/ci-gates.sh verify` = **EXIT=0 ALL GATES OK**):
Rust **325** 通过 / 0 失败 · clippy **0** · 格式门干净 · 全量 `flutter test` **1289 通过 / 0 失败**(golden **20** 张) ·
`dart analyze` **0** · Kotlin 单测 **10** 通过 / 0 失败 · `lintDebug` **0 error / 9 warning** · 四道 checker(含 `sheet-entry` 待迁 0) OK。
**2026-11-18 下(队列/播放条 7 条用户反馈批后)第五次重跑**: 仍 **ALL GATES OK**, Dart **1123**
(删掉「存为歌单」面板 5 例 + controller 2 例, 新增提示/live-sync/定位/行高 7 例)。
本批数字变化: v0.21.0 之后 Dart **1106→1124**(托盘关闭 lane `desktop_close_behavior_test.dart` 18 例) → **1124→1128**
(settings codec 4 例) → **1128→1130**(播放条 seek 排队 8 例重写, +2); Rust 未动(仍 313)。
golden 只重出 recommend 2 张(8/12 二分取消后日推预览行左移 4dp、行矮 8dp) · 新增设备级门 `androidTest`(模拟器, 手工)。

| 门 | 结果 |
|---|---|
| `cargo test --offline --workspace --exclude ncm-api-rs` | **368** 通过 / 0 失败(排除 vendor 联网 smoke; domain 49 + playback 47 + provider 1 + service **249** + plugin **21** + ffi 1; service 227→247 = 云盘分片 20 例, 247→249 = 云盘解析回归 2 例; plugin 21 = 沙箱 14 + provider 6 + doctest 1) |
| `cargo clippy --workspace --all-targets -- -D warnings` | **0 warning** |
| `cargo fmt --all -- --check` · `dart format --set-exit-if-changed lib test` | 干净(两道格式门) |
| `flutter test --exclude-tags network`(全量, 含 golden) | **1322** 通过 / 0 skip / 0 失败(golden **21** 张(v0.27.0 起: 双列 2 张 + 主从分栏 1 张 + 既有 18); network 标签需真实凭据, 本地/CI 都不跑)。演进: 1123 → 1148 → 1163 → 1205 → 1243 → 1289(v0.26.0 夜间三车道) → 1293(v0.26.1 补测) → 1299(§12.6 按域 diff 通知 6 例) → 1320(S4 主从分栏 +21 例) → **1322**(U-08 真壳首帧回归 +2 例) |
| `./gradlew :app:testDebugUnitTest`(`ci-gates.sh android-unit`, 已进 `verify`) | **10** 通过 / 0 失败(EQ 三端共享夹具 3 + MV 音频焦点策略 4 + 缓冲水位策略 `AudioBufferPolicy` 3; v0.26.0) |
| `ci-gates.sh android-instrumented`(`connectedDebugAndroidTest`, 需模拟器; `NCM_INSTRUMENTED=1` 才进 `verify`) / 可选 `android-test-emu`(钉 emulator-5554, 必须显式调用) | **6 例 → 5 通过 / 1 skip**(`NotificationSlotsTest` 3: 渠道 + 5 个 action 槽位 + 状态回推; `NotificationClickTest` 3, 其中 1 例 assume-skip —— 通知点击被 BAL 拦, 需真人开 App 才补执行)。**2026-11-19 复核**: a34(emulator-5554, SDK 34)连跑两轮均 **0 失败**, 用例 **15.9s** / 任务 **23–25s** |
| `./gradlew :app:lintDebug`(`ci-gates.sh android-lint`, **已进 `verify` + GitHub CI 阻塞门**) | **0 error / 9 warning**(9 条全是依赖版本提示)。2026-11-18 清零: 66×media3 `UnstableApi` 收口到类级 `@OptIn`/`@UnstableApi` + 1×`GestureBackNavigation` 迁到 `OnBackPressedDispatcher`; 仍未用 baseline 掩盖 |
| `ci-gates.sh desktop-smoke`(`NCM_DESKTOP_SMOKE=1` 才进 `verify`; 需现成 release bundle) | **PASS / 0 FAIL / 0 SKIP, 26 项 OK, 61s**(2026-11-18 本机实测): 启动+数据目录+`identity.json`+WM_CLASS+几何+单实例+SIGTERM · **⑦ 关闭行为三例**(默认退出 / 托盘降级 / 有宿主时 unmap + SecondaryActivate 恢复) · **⑧ 交互级**(windowfocus 回读 + XTEST 按键 4 次 + 播放条 4 次点击 + 缩窗 640x480/320x240/还原, 每步断言存活且几何·标题·Map State 不变, 主窗口仍 1 个, 日志无崩溃痕迹) |
| `dart analyze` | **0 issue**(error / warning / info 全清) |
| `tools/check-write-guard.sh` | OK(测试不触网/不直连写接口) |
| `tools/check-tokens.sh --strict` | **OK**(间距/圆角/字号 0 越界, 例外必须写 `// token-ok: 理由`) |
| `tools/check-row-padding.sh --strict`(`ci-gates.sh row-padding`, 已进 `verify`) | **OK**(25 处行留白 / **3 个**具名口径 + 纵向只允许 0/6; 具名工厂 `SongRow.xxx(` 也计入 —— 数量比 C 步前少 2 处是因为同构参数收进了工厂, 见 2026-11-17 两个小节) |
| `tools/check-docs.sh`(`ci-gates.sh docs`, 2026-11-19 新门, 已进 `verify`) | **PASS**: 相对链接死链 **0** · `docs/` 根未进索引 **0** · 白名单命中 **0/0**。扫描范围 = `docs/**/*.md` + 仓库根所有 `*.md`(锚点丢弃, 只校验文件部分); `docs/archive/**` 只查链接不强制进索引 |
| 接口覆盖 | **135/136**(唯一未接入 `vip_sign_info` 是**有意弃用**, 见 v0.12.5 小节)。FFI 导出 **158** 里 **6 个**无 UI 入口, 全是有意保留或待决策: **保留 4**(cache_stats / cloud_song_url / eq_profile_normalize / player_tuning) · **待产品决策 2**(consent_plaintext_storage / user_play_ranking)。2026-11-18 修了脚本的入口判定(类型名与构造调用曾把导出顶替成"有入口"), 并把 3 条真死出口删掉(161→158 / 9→6); 明细见 `docs/api-coverage.md` 文首与 `docs/archive/plans-2026-11/deadcode-audit-2026-11-18.md` |

凭据落盘 0600 文件骨架 + 系统钥匙串(Android Keystore / Linux secret-service / Windows DPAPI)。

**版本时间线**:

| 版本 | 日期 | 里程碑 |
|---|---|---|
| **v0.28.0** | **2026-11-19** | **用户 12 条反馈批**(四车道): ① 详情页封面面「保存封面」运行时必崩修复(`?? saveImageBytes` LUB 退化 + 命名参数, cover_art 全屏看图同款) + 封面面先出小图/大图淡入缓存 + 保存左边新增「查看评论」 + 歌词⇄封面切换记忆(`AppSettings.detailFace`) + 播放条封面点击切面; ② 每日推荐页签 300dp/1.25 裁字(`isScrollable` 自然宽) + 推荐播客卡副标题两行(CoverCard/CoverRow 行数参数化, 默认像素零变) + 推荐页顶栏「每日推荐」改自定义入口(`customQuickAction` 可换绑 5 动作, 持久化) + 顶栏 icon +10%(26.4); ③ 心动/私人FM 从「播放顺序」解耦(`QueueGuide`, 轮转只剩 4 档) + FM 连取 3 批自续播(`personal_fm` 服务端每批仅 2 首) + 队列面板跟随刷新 + FM 广播/心动火焰专属通知图标(不再与喜欢红心同图); ④ 关注页选中艺人走 `userEvents` 贪婪翻历史(发条月亮实测 16 条) + 听歌排行周榜空态(上游 type=1 当前不返回数据, 真接口取证) · 排序尊重接口官方顺序。golden 仅重出 recommend 2 张(有意变更); Rust 368→**369**(+周榜形状/保序回归), Dart 1322→**1372**; Release 9 产物全绿 |
| **v0.27.1** | **2026-11-19** | **U-08 收口**: 真壳首帧不再 `setState() called during build` —— `HomeWiring` 的两个 `ValueNotifier` 槽位(动作宿主/播放条回调)**一律帧后投递**(壳层 `ContentWidthLimit` 是 LayoutBuilder, 页面建树落在 layout 阶段), `_clearSlots` 对称帧后再清; 回归 `test/app_shell_first_frame_test.dart` 2 例(宽/窄两档真壳)。Dart **1320→1322**, Rust 368 不变。Release 9 产物全绿 |
| **v0.27.0** | **2026-11-19** | **横屏双列 S4(方案 B 主从分栏)**: `detailPaneSlot` + `openDetail` 统一入口(**右栏不是路由**, 故 `pageDepth`/`modalRouteOpen`/`dismissAllPopups` 登记面零改动, 不加嵌套 Navigator); 歌单详情 `embedded` 形态; 返回键新层级 `closeDetailPane`(宽档只清右栏 / 窄档 pop, 两语义各有用例); 选中态用外框而非第二套行高亮; 840 内切 左 408 / 间 12 / 右 420。Dart **1299→1320**(+21 例), golden **20→21**(`master_detail_1280x720`, 既有 20 张零重出) |
| **v0.26.4** | **2026-11-19** | **音源插件宿主切片 1(不接产品)**: 新 crate `ncm-plugin` —— rquickjs 0.12.2 宿主 + lx 兼容层(`lx.on/request/log/storage/utils`)+ 沙箱预算(8s interrupt / 32MB / 512KB 栈 / 8 请求)+ 逃逸面断言 + `ScriptProvider` 实现既有 `Provider`(未注册路由, 不进 `ncm_ffi`/APK)。红→绿实证(死循环与内存炸弹先红后绿)。Rust **347→368** |
| **v0.26.3** | **2026-11-19** | **云盘上传 400 修复**(用户报「安卓端上传任意音频都是上传识别失败, internal code 400, songid=0」): 根因 `/api/nos/token/alloc` 的 `resourceId` 是**数字**(如 84382086772), 旧代码用 `str_of` 只认字符串 ⇒ 传给 info/v2 的 resourceId 是空串 ⇒ 服务端回 `{"code":400,"songId":"0"}`; 顺带修 check 的 `songId`(128 位十六进制串)被 `u64_of` 解析成 0。真实账号 headless CLI 复现 → 修复 → 实测上传成功 → 删除测试歌曲; 新增 `str_or_num_of` + 2 例回归测试(真实响应形状)。Rust **345→347** |

[8 more lines in file. Use offset=71 to continue.]