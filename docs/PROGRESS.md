# 进度记录(Progress)

> 最近更新: **2026-11-17(八)**。已发布版本 **v0.21.0**(歌词高光行居中 + 详情页/冷启动预取 · AppImage 菜单集成 ·
> 设备级门与桌面无头冒烟进 `ci-gates`), 见批次时间线最上面那条。
> 面向新读者的速览在下一节; 按日期的批次记录从「批次时间线」起倒序(最新在上)。
> 下一轮做什么: [`docs/remaining-batches.md`](remaining-batches.md) **§11**(功能) / **§12**(结构性债务) / **§13**(平台层审计剩余);文档总索引: [`docs/README.md`](README.md);
> 架构决策: [`docs/archive/architecture-restart.md`](archive/architecture-restart.md);
> 历史批次:v1(WebView 版) → [`docs/archive/PROGRESS-v1.md`](archive/PROGRESS-v1.md),
> 2026-11-03~11-12 批次与专题小节 → [`docs/archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> **本文件只保留 v0.20.0 起的活跃批次**(2026-11-17 精简: 1212 行 → 517 行; v0.8.0–v0.19.0 的按日明细见
> [`archive/PROGRESS-2026-11-13-11-19.md`](archive/PROGRESS-2026-11-13-11-19.md), 一行摘要仍在下面的版本时间线表)。

## 进度总览(2026-11-17 复核)

**当前门禁**(本机实测, 离线口径; **权威口径只在本表**, README/README.en/remaining-batches 都是指针)。
复核口径: **2026-11-17 晚在 main 上合并 p18/uib-c/p10/p11 四条车道后逐门重跑**(编排者独立跑, 不采信 worker 自报);
**v0.21.0 发版后(2026-11-17)再次独立重跑复核**: Rust 313 · Dart 1106 · golden 18 张 · 四道 checker 全 OK。
本批数字变化: Rust **300→313**(P-18 数据目录迁移 8 例 + P-10 播放引擎 5 例) · Dart **1074→1106**(纵向 pitch 渲染断言 + v0.20.1/v0.21.0 反馈批用例) ·
golden 只重出 recommend 2 张(8/12 二分取消后日推预览行左移 4dp、行矮 8dp) · 新增设备级门 `androidTest`(模拟器, 手工)。

| 门 | 结果 |
|---|---|
| `cargo test --offline --workspace --exclude ncm-api-rs` | **313** 通过 / 0 失败(排除 vendor 联网 smoke) |
| `cargo clippy --workspace --all-targets -- -D warnings` | **0 warning** |
| `cargo fmt --all -- --check` | 干净 |
| `flutter test --exclude-tags network`(全量, 含 golden) | **1106** 通过 / 0 skip / 0 失败(golden **18** 张; network 标签需真实凭据, 本地/CI 都不跑) |
| `./gradlew :app:testDebugUnitTest`(`ci-gates.sh android-unit`, 已进 `verify`) | **3** 通过 / 0 失败(EQ 三端共享夹具的 Kotlin 侧) |
| `ci-gates.sh android-instrumented`(`connectedDebugAndroidTest`, 需模拟器; `NCM_INSTRUMENTED=1` 才进 `verify`) | **6 例 → 5 通过 / 1 skip**(`NotificationSlotsTest` 3: 渠道 + 5 个 action 槽位 + 状态回推; `NotificationClickTest` 3, 其中 1 例 assume-skip —— 通知点击被 BAL 拦, 需真人开 App 才补执行; 2026-11-17 a34 实跑) |
| `./gradlew :app:lintDebug`(`ci-gates.sh android-lint`, **不在 `verify`) | **67 error / 9 warning**(必红: 66×media3 缺 `@OptIn(UnstableApi::class)` + 1×`GestureBackNavigation`; 未用 baseline 掩盖, 详见批次时间线最上面那条) |
| `dart format --set-exit-if-changed lib test` | 干净 |
| `dart analyze` | **0 issue**(error / warning / info 全清) |
| `tools/check-write-guard.sh` | OK(测试不触网/不直连写接口) |
| `tools/check-tokens.sh --strict` | **OK**(间距/圆角/字号 0 越界, 例外必须写 `// token-ok: 理由`) |
| `tools/check-row-padding.sh --strict`(`ci-gates.sh row-padding`, 已进 `verify`) | **OK**(25 处行留白 / **3 个**具名口径 + 纵向只允许 0/6; 具名工厂 `SongRow.xxx(` 也计入 —— 数量比 C 步前少 2 处是因为同构参数收进了工厂, 见 2026-11-17 两个小节) |
| 接口覆盖 | **135/136**(FFI 导出 161, 其中 6 个无 UI 入口: cache_stats / cloud_song_url / consent_plaintext_storage / eq_profile_normalize / player_tuning / user_play_ranking; 唯一未接入 `vip_sign_info` 是**有意弃用**, 见 v0.12.5 小节) |

凭据落盘 0600 文件骨架 + 系统钥匙串(Android Keystore / Linux secret-service / Windows DPAPI)。

**版本时间线**:

| 版本 | 日期 | 里程碑 |
|---|---|---|
| **v0.21.0** | **2026-11-17** | **用户 6 项反馈批**: ① Android 逐字歌词高光行贴左(`TextPainter` 只给 maxWidth) ② Linux 播放条宽屏留白/控件间隔 ③ 未登录时推荐页不再暴露 `[auth] Unknown error`(登录态门 + `friendlyError` auth 分支) ④ Linux 登录弹层切 tab 自动收起 ⑤ PC 网页登录风控**静态分析报告**(5 条差异, 未改登录码) ⑥ 超长当前行歌词横向自动滚动(复用唯一跑马灯内核); Dart **1089→1106**, golden 未变 |
| **v0.20.1** | **2026-11-17** | **反馈批**(两条用户反馈 + 两处平台缺口): ① 歌词高光行 18→16sp 且两种行都居中(修「换行时左右瞬移」) ② 冷启动恢复/进详情页**主动预取**歌词(不再干等「信息不可用」) ③ **AppImage 首启集成到应用菜单** ④ `ci-gates.sh` 新增 `android-instrumented`(a34 3/3) 与 `desktop-smoke`(xvfb+dbus 无头冒烟); Dart **1075→1089** |
| **v0.20.0** | **2026-11-17** | **四车道批**: P-18 后半(application-id 统一 + 数据目录一次性迁移)· P-10 方案 B(渐进期 seek 登记 + 下载完成换源重建解码器)· 列表行 C 级收尾(8/12 二分取消 + 纵向 pitch + SongRow 工厂)· P-11 第一步(首个 `androidTest` + `notif-slots` 断言脚本); Rust **300→313** / Dart **1061→1075** |
| **v0.19.1** | **2026-11-17** | **门禁/收敛批**(两个未发版批次一并出): Android 门进 CI(`android-unit` 进 `verify`, `android-lint` 暂只暴露) + 列表行 **B 级 12 条清零**(`kRowTrailingMaxRatio`/`capRowTrailing`) + **C 级第一批**(四个具名行留白口径 + `row-padding` 门) + 修掉会挂死 `cargo test` 的 keyring 写路径; Rust 300 / Dart **1074** |
| **v0.19.0** | **2026-11-16** | **收尾批**(4 lane): **拆壳 S8 完成** —— `home/home_wiring.dart` 收口 8 条静态钩子的 attach/detach + `HomePage` 搬到 `home/home_page.dart`(1550) + main.dart **1562→48 行门面**(审计起点 3877); **P-22** 明文流量收窄到 `music.126.net`/`music.163.com`/`vod.126.net` 白名单; **P-05 中期/P-11 起步** EQ 三端共享 fixture(479 行) + Kotlin 纯逻辑抽取与 JVM 单测 3 例; 文档债务登记 §13; Rust **298→300** / Dart **1037→1061** |
| **v0.18.0** | **2026-11-16** | **第六批**(4 lane): main.dart **1874→1562** 拆壳 **S7**(账号/登录态/列表态导航 → `home/account_actions.dart`, `_libraryTitle` 收口单一文件)、**P-09** 登录/MV 页跟随系统深浅色(同名 style + values-night)、**P-21** 播放 UA 收敛 Rust 单一来源(FFI→Dart→Kotlin 兜底+漂移日志)、**P-10** 渐进播放 seek 如实反馈并修掉 `EqSource` 未实现 `try_seek`(桌面完整文件本该能跳); Rust **294→298** / Dart **1028→1037** |
| **v0.17.0** | **2026-11-16** | **第五批**(4 lane): main.dart **2156→1874** 拆壳 **S6**(队列面板 → `home/queue_sheet_controller.dart`)、**P-03** 增益斜率 `gain_slew_db_per_sec` 打通 Rust→FFI→Dart(`0=瞬时`, Rust 290→294)、**P-07/P-08** MV 跟随生命周期 + 登录 cookie 清理去重(模拟器实测)、**P-17/P-18/P-20** AppImage 工具 pin+sha256、两平台标题尺寸统一、注释纠偏; 测试 **1010→1028** |
| **v0.16.0** | **2026-11-16** | **第四批**(平台层审计后的第一批修复, 4 lane): main.dart **2503→2156** 拆壳 **S5**(动作宿主+14 个动作闭包 → `home/song_action_wiring.dart`)、**P-01/P-02** Android 通知栏按钮上划清任务后仍可用 + 红心·模式自愈、**P-04/P-05/P-06** 桌面「边听边存」如实说明 + EQ 失败可观测 + 冷启动调音重试、**CI 门禁统一**(`ci-gates.sh` 唯一实现, golden 进发版门); 测试 **992→1010** |
| **v0.15.0** | **2026-11-16** | **重构第三批**(4 lane): main.dart **2899→2503** 拆壳 **S4**(轮询/续播/现场恢复/预取/响度簿记 → `src/home/playback_coordinator.dart` 567 行)、**P1** `comment_thread` 1699→8 + `feed_view` 1190→7 barrel(part 保私有)、**P2** vip/medal 映射层与 cover_art 纯函数下移、**平台层只读审计**(22 条缺陷, P1×6); 门禁 992 / 290, golden 无变化 |
| **v0.14.0** | **2026-11-16** | **重构第二批**(3 条并行 lane, 断电后按续做重派): main.dart **3095→2899** 拆壳 **S3**(搜索状态/联想/热词/历史 → `src/home/search_controller.dart`)、**PlaybackBridge 单入口**(`onPlaySongs` 透传 158→0, 删 UserNav/ArtistNav 静态旁路与 20 文件构造参数)、`ncm-provider/lib.rs` **1321→30** 行按 capability/error/params/trait/registry 拆分(对外路径不变); 门禁 992 / 290, golden 无变化; 同批回收 21G 磁盘 |
| **v0.13.0** | **2026-11-15** | **架构重构批**(48 提交, 7 条并行 lane): main.dart **3917→3095**(S0 纯逻辑 / S1 全局壳 / S2 歌词控制器)、detail/messages/discover 三个 P0 页面按页拆分(1558/886/882 → 子树)、**SongRow 收敛 11 处**、四态全部收口到 AsyncView(16 个域)、`FfiError{kind,retryable,detail}` 跨桥(160 导出)、锁中毒容忍 + fsutil 原子写收敛、日推缓存按 uid 隔离 + 登出清理、golden **12→18** 且进 CI、测试工厂 `fakes.dart` 收敛 32 份；门禁 992 / 290 |
| **v0.12.5** | **2026-11-15** | 逐字歌词**默认走 AMLL TTML**(设置可切回网易云/自动择优, 旧 `auto` 一次性迁移) + 黑胶会员页签到数据源从 `vip_sign_info` 改回 `signin_progress`(修「今日未签到/累计 0」与「我的」页签到卡自相矛盾) |
| **v0.12.4** | **2026-11-15** | 播放队列面板排版: 标题不再被行尾挤成「当前播…」, 序号贴左/删除与拖拽贴右, 中间歌名 +48dp; 「正在播放」页改为直接读队列(删掉过期副本) |
| **v0.12.3** | **2026-11-15** | 冷启动默认落「推荐」tab(不再被恢复的播放现场顶到"正在播放"列表) + 每日推荐歌单本地缓存在「历史日推」里合并去重 + 「本地」标记 |
| **v0.12.2** | **2026-11-14** | 分类条回退为**单横排 + 横向拖拽**(不再做换行/均分几何) + 分类顺序按日用频率(歌曲→艺人→专辑→MV→播客→歌单→用户) |
| **v0.12.1** | **2026-11-14** | 分类条末尾空缺(均分 4+3 两排)、字号档位 chip 删除(只留滑块)、`docs/` 根 13 份完工专题归档 + 索引重写 |
| **v0.12.0** | **2026-11-14** | 用户第三轮 16 项:分类 tab 对齐根因修复(居中缩进/checkmark 变宽)、联想改分类 tab + 关注艺人加权排序 + 封面补齐、键盘弹出导航栏让位、动态统一转发面板 + 评论选中态 + 评论卡片语境/计数 + 他人动态自动展示媒体、**字号落盘原子化**(根治"重启回默认")+ 精细滑块、关注行/作者栏点法统一、我的动态并入我的主页、一排/两排覆盖更多横滑;新增 **正在播放高亮**(全局 nowPlayingSongId) |
| **v0.11.0** | **2026-11-14** | 用户第二轮 15 项 + API 语义纠偏:艺人页粉丝数与整卡宽统计行、播放全部顶格、共 N 首/搜索移入全部歌曲 tab、**登录假成功修复**、提示条 floating 3s、简介并入昵称下、**他人/艺人动态端点修复**(`/api/event/get/<uid>` + 绑定 userId)、去关注粉丝 tab、「我喜欢」单独成栏、电台→播客文案、仅分享歌曲不重复附图、图片按张数排版;新增 2 个 vendor 端点 |
| **v0.10.0** | **2026-11-14** | 用户 15 项反馈(OLED 开关/我的页同构/动态分享卡片/转发面板/forbidden 文案/云盘列表/通知按钮顺序/网格列数/相似艺人横排/MV 搜索+评论区/动态游标补历史/等级 0/艺人页纵向 tab/联想面板/边缘留白) + 编辑简介 + 云盘上传 |
| **v0.9.0** | **2026-11-13** | **规则层收口**(唯一 `AsyncView` / `SectionTitle` / `check-tokens --strict`) + 用户 6 条(播放跳过 VIP / 每日推荐歌单本地缓存 / 凭据存储去重 / 匿名 debug 数据 / 关注页头像进主页且与搜索同一份排版 / 「歌手」→「艺人」) + **匿名诊断一键提交**(Cloudflare Worker 代理建 issue) + **我的页按最近交互排序** + 列表行 A 级 7 处修复 + **golden 视觉回归网**(6 页 × 2 视口) |
| **v0.8.1** | **2026-11-13** | 用户反馈 8 项: 账号入口收敛到设置(删「我的」页药丸/未登录按钮/底部多余横条)、账号页去会员重复栏、登录 WebView 清 cookie(可加第二个账号)+ 顶栏关闭(可返回)、退出后账号簿可点即登录、热搜单一开关(删 ❌)、清除凭据文案去歧义、Keystore 说明搬到设置→关于、**风格推荐配图修复**(yyimgs 相对路径补 CDN 绝对地址) |
| **v0.8.0** | **2026-11-13** | 用户反馈 10 项 UI 收口(徽标位置/行尾按钮/每日推荐/歌词标题字号/跑马灯内核重写+全仓统一/逐字字内进度/动态标记/背景高清+全屏保存/横向留白栅格) + **艺人/用户主页统一骨架** + 数据面 3 个 FFI(`Playlist.subscribed` / `userPlayRanking` / `userEvents`) |
| **v0.7.1** | **2026-11-12** | 用户反馈 10 项:VIP 标记/播放条上一首/歌词截断/长字滚动/队列叠加/搜索横向分类/艺人主页分区/缩进收口 |
| **v0.7.0** | **2026-11-12** | 播放条重排(播放顺序归位/队列入口移到行尾/删除详情页底部控制条)、歌单内搜索播放策略(全列表/追加队列)、艺人跳转、对齐与低优先审计收口 |
| **v0.6.1** | **2026-11-12** | 自动更新频率(off/daily/weekly/monthly)+ 启动发现新版本弹窗、全站横向留白统一、代码审计整改(CoverCard/CoverRow 合并、死参数删除、分页代际守卫) |
| **v0.6.0** | **2026-11-12** | 排行榜移到搜索落地页、我的收藏歌单/播客/专辑二级页、我的页区块 keepAlive、歌曲行留白收紧、搜索加载占位 |
| **v0.5.5** | **2026-11-12** | 凭据后端三端落地(Android Keystore / Linux secret-service / Windows DPAPI) + USTC GitLab CI build 阶段;Release 6+2 分发物(含 arm64) + SHA256SUMS |
| **v0.5.3 / v0.5.4** | 2026-11-12 | 凭据调研 + 桌面冒烟脚本 + CI apt 重试;凭据地基(FileStore 0600 + 同意门 + 明文迁移 + DPAPI P0) + 凭据不再过 FFI 回 Dart。**两者 CI 未出全套产物, 由 v0.5.5 取代** |
| **v0.5.0 / v0.5.1 / v0.5.2** | 2026-11-11~12 | 主题色切换(五 seed)+ 播放条数据层重构;v0.5.1 重发修 arm64 CI;v0.5.2 红色改 M3 fidelity 策略 |
| **v0.4.0** | **2026-11-11** | 播放条常驻二级页 + 风格推荐配图窗格 + Linux **arm64** 原生 CI 腿 |
| **v0.3.5** | **2026-11-11** | **技术债 D 批收敛**(弹层 21/21 统一、格式化去重、podcast 658→190 行、45 文件窄屏回归归零) + Windows 向导中文化 + 写接口静态门禁 `tools/check-write-guard.sh` |
| **v0.3.4** | **2026-11-11** | **手机号+短信验证码登录(网页通道)**、动态评论写入改 eapi(修 404)、评论区对话化、动态流行内赞·评论·分享、发表后回填定位;Release 6 种资产 |
| v0.3.x | 2026-11-10~11 | 桌面打包(deb/AppImage/setup.exe)、歌单写接口、图片清晰度三档、**v0.3.2 六种资产发布**;v0.3.3 修 Ubuntu 22.04 GLib 基线 |
| v0.1.1 / v0.2.x | 2026-11-09~10 | 窄屏修复 + 正式签名/版本号纪律;设置项扩充 R1–R7、UI/UX 走查批 A–C、**Windows 桌面版合入**、v0.2.2 三端发布 |
| v0.1.0 | 2026-11-08 | 首个公开预览版(Android APK + Linux tar.gz, MIT LICENSE, 第三方许可盘点) |

**各批次一句话结论**(详细验收证据见下方按日期小节与 `docs/archive/`):

- **M0**(基建): Rust workspace 五 crate + FRB 桥 + headless CLI, 双端能启动、协议库真实取到直链。✅
- **vendor 裁剪 P1+P2**: 删 264 个未接 endpoint, vendor 12k→4.1k LOC, 冷编 1.40→0.65s。✅
- **FFI 清理 D1/D2/D5/D7**: 死导出删除、转发宏收敛、frb 直透 domain(57/57), 车道已关闭。✅
- **功能批次 B1–B4/B8/B10/B12**(S 级只读): 消息增强/评论统计/会员只读/搜索增强/等级勋章/电台/数字专辑全部落地并实测。✅
- **B5+B13 逐字歌词**: yrc 契约层 + AMLL TTML 第二来源 + 打分择优(偏好三态可调)。✅
- **B7 歌单写接口**: create/批量加曲 + 队列「存为歌单」, 服务端复核通过。✅
- **UI 批 A–D**: 速修/评论输入/队列面板/信息架构重排 + D 批技术债(弹层统一/格式化去重/死码清理/窄屏回归归零)全部完成。✅
- **播放质量**: 精细音量、响度均衡(R128→ReplayGain)、AutoEQ、逐字歌词、封面取色、歌词跟随。✅
- **三端与打包**: Windows 合入, 六种分发物由 Release 流水线统一产出(另 USTC GitLab CI 出 Linux/Android 腿)。✅
- **真机听感验收**: EQ 削波/淡入手感/响度 A/B/硬解, 2026-11-10 通过。✅
- **下一步**: `docs/remaining-batches.md` §11(视觉人工过目、AppImage 桌面集成、L 级立项)。
### 桌面分发打包(v0.3.1 起)

| 产物 | 做法 | 本地实测 |
|---|---|---|
| `minincm_<ver>_amd64.deb` | `packaging/linux/build-deb.sh`: 纯 `dpkg-deb`, 装到 `/opt/minincm`(Flutter bundle 结构不动, 二进制才找得到 `data/`/`lib/`) + `/usr/bin/minincm` 软链 + desktop/icon + `Depends: libgtk-3-0, libasound2, liblzma5` | **11 MB**; `dpkg-deb -x` 后 `ldd` 无 missing; `dpkg-deb -I` 元数据正确 |
| `MiniNCM-<ver>-linux-x86_64.AppImage` | `packaging/linux/build-appimage.sh`: AppDir(`usr/bin` 放整套 bundle) + AppRun 转发 + `appimagetool`(缺则下载到 `~/.cache`), 无 FUSE 时 `--appimage-extract-and-run` | **14 MB**; `--appimage-extract` 结构正确, `xvfb-run ./AppRun` 能起 Impeller 渲染(8s 后被 timeout 杀掉属正常) |
| `MiniNCM-<ver>-windows-x64-setup.exe` | `packaging/windows/installer.iss`(Inno Setup): 开始菜单/桌面快捷方式 + 卸载项 + LICENSE, Flutter 已带 VC 运行库故整目录打包; 免安装 zip 保留 | 只能由 CI(`windows-latest`)或用户 Windows 机器编, 本机无法本地验证 |

`release.yml` 现在是 4 个 job: `verify`(测试门) → `build`(Android+Linux, 含 deb/AppImage) + `build-windows`(zip + setup.exe) → `publish`
(统一 `download-artifact` + 一份 `SHA256SUMS` + 创建 Release), 消除了两个 job 抢建 Release 的竞态。

> **CI 实测(2026-11-10 v0.3.2)**: 四个 job 全绿, Release 产出 **6 种资产** —— apk 28.5 MB / tar.gz 15.0 MB /
> AppImage 14.6 MB / deb 11.1 MB / windows zip 17.0 MB / windows setup.exe 13.7 MB + SHA256SUMS。
> 期间修掉一处真错误: Inno Setup 官方安装包**不含** `ChineseSimplified.isl` ⇒ v0.3.1 的 Windows job 编译失败; 改为只用内置英文语言包(应用名/快捷方式仍是中文)。

> 顺带修掉一处**版本耦合的测试**: `update_checker_test.dart` 里 `releaseJson()` 的默认 tag 原本写死 `v0.3.0`,
> 版本号 bump 到 0.3.0 后"同一版本不算更新"让两条断言在 CI 上挂(本地还停在 0.2.2 所以没暴露) ⇒ 默认 tag 改 `v9.9.9`。

## 批次时间线(倒序, 最新在上)

## 2026-11-17(三) 平台审计 P-18 后半: application-id 与 AppStream id 统一 + 数据目录一次性迁移(**未发版**)

用户 2026-11-17 拍板「按推荐做法直接做, 允许大变更(含用户数据目录一次性迁移), 接受迁移风险」。
三个提交: 数据目录迁移(含单测) / id 与打包对齐 / 文档。合并后 Rust 单测 **300→308**。

### 1) 桌面端标识收敛成一个串

| 位置 | 改后 |
|---|---|
| `ui/linux/CMakeLists.txt` `APPLICATION_ID` | `com.minincm.minincm` → **`io.github.xiaquwan1001.MiniNCM`** |
| `.desktop` 文件名(deb/AppImage) | `minincm.desktop` → `io.github.xiaquwan1001.MiniNCM.desktop` |
| `.desktop` `StartupWMClass` | `minincm` → `io.github.xiaquwan1001.MiniNCM`(= WM_CLASS = `g_set_prgname` 的值) |
| metainfo `<launchable>` | `minincm.desktop` → `io.github.xiaquwan1001.MiniNCM.desktop` |

两个打包脚本都新增硬断言: 脚本内的 `APPID` 必须等于从 `ui/linux/CMakeLists.txt` 读出的
`APPLICATION_ID`, 否则直接报错退出(避免打出任务栏不归组/AppStream 关联不上的包)。
**不动的名字**: 二进制 `minincm`(dpkg 包名全小写)、Android `applicationId com.minincm.minincm.dev`。

### 2) 单实例: `G_APPLICATION_NON_UNIQUE` → 严格单实例

Flutter 模板原本是 NON_UNIQUE(每次启动都是独立进程/窗口, 两个窗口会并发写同一份 dataDir)。
现在 `flags = static_cast<GApplicationFlags>(0)`(**不用** `G_APPLICATION_DEFAULT_FLAGS`, 那是
Since 2.74, 而 CMakeLists 把 GLib 基线钉在 2.72), `activate` 里若已有窗口就 `gtk_window_present`
后返回 —— 第二次启动只把主窗口提到前台, 不开新窗口。

取舍写进代码注释与 README: **迁移窗口期允许一旧一新同时运行**(新旧 id 不同, GApplication 互不可见);
代价是现在需要 session bus(桌面环境都有), 无 bus 时注册失败并退 1。

### 3) 用户数据目录一次性迁移(P-18 后半的"大变更")

新目录 `~/.local/share/io.github.xiaquwan1001.MiniNCM`, 旧目录 `~/.local/share/ncm`。判据:

| 磁盘现状 | 处置 |
|---|---|
| 新目录存在 | `KeptCurrent`: 什么都不做(幂等; 旧目录原样留着, 用户自己清) |
| 只有旧目录 | 同设备 `rename`(原子); `EXDEV` 才 copy 到同级 `.migrating-<pid>` → 校验(相对路径+字节数全量比对) → `rename` 成正式目录 |
| 新旧都没有 | `NoData`: 首次启动, 由上层按需创建 |
| 迁移失败 | `Failed`: 旧目录原样保留, **返回旧路径**(退回 P-18 之前的行为) + `eprintln` 告警, 临时目录必删 |

补充纪律: 迁移成功后旧目录留 `.migrated` 标记(写明新旧路径与降级步骤, 不静默删除);
调用点唯一在 `ncm_ffi::api::data_dir_default()`(`init` 里、`Core::open` 之前) ⇒ 任何缓存/凭据/
播放状态文件都在迁移之后才打开, 且是纯 `std::fs`(不依赖 GTK/DBus, headless 安全);
`$NCM_DATA_DIR` 显式指定时不迁移; Android 走平台通道传私有目录, 不经过这里。

单测 8 例(临时目录): 只有旧 / 只有新 / 两者都有 / 都没有 + 幂等(第二次 `KeptCurrent` 且不动新数据)
+ 跨设备 copy 分支(0600 权限保留、无 `.migrating-` 残骸) + 失败回退旧目录 + 校验能抓漏文件。

### 4) 本车道门禁与**未验证项**

`cargo test --offline --workspace --exclude ncm-api-rs` **308 passed / 0 failed** ·
`cargo clippy --workspace --all-targets -- -D warnings` **0 warning** · `cargo fmt --all --check` 干净 ·
`bash -n` 两个打包脚本 · metainfo XML 解析通过 · `grep -rn 'com\.minincm\.minincm' ui/linux packaging/linux`
只剩一条说明性注释。

**未验证(按车道约束由编排者收口)**: `flutter build linux`(runner C++ 只用 stub 头做过
`g++ -fsyntax-only -Wall -Werror` + GLib 2.72 基线的语法检查)、真打 deb/AppImage、
「任务栏归组」与「第二实例唤醒主实例」两条真机行为、真实用户目录的迁移(只在临时目录单测过)。

## 2026-11-17(四) 列表行 C 级收尾: 单一条 12 线 + 纵向 pitch + `ListRow` 组件化(**未发版**)

单会话、独立 worktree(`lane/uib-c`, 基于 `a883f6f`)。按 A→B→C 三步各自一个提交,
每步都是「改 → 跑 → 记」, 不攒到最后一起修测试。

### A) 取消 8/12 二分: 歌曲行并入页面 12 线

用户 2026-11-17 裁决(见 `remaining-batches.md` §11 A-9):**取消** `kSongRowPadding`(8/0/4) 与
`kPageRowPadding`(12/0/4) 的二分 —— 「行首是封面缩略图 ⇒ 8」这条口径收益只是 4dp 呼吸,
代价是同一页里封面行与序号行左右边界差 4dp、且与 SectionHeader / 页面标题线不共线。

- `layout.dart`: **删除 `kSongRowPadding`**(不做 deprecated 别名, 免得留下第五个可写名字),
  `kPageRowPadding` 的注释改写成「整页铺满的行, 歌曲行也是它」并记下这次裁决。
  头部栅格表那一行 `整页铺满的歌曲行` 从 8 改成 **12**。
- 调用点迁移: `song_tile.dart`(ListTile 臂的默认 `contentPadding`)与 `ranking_view.dart`
  (`_RankRow.padding` 默认)两处**代码**改常量; `recommend_view` / `discover/recent_played_page` /
  `comment/comment_thread` 三处只改注释里的常量名。**16 处 SongRow(tile 臂)调用点因此全部从 8 变 12。**
- 门禁: `tools/check-row-padding.sh` 的具名白名单 4 → **3**(删掉 `kSongRowPadding`),
  文件头写明「旧名故意不在白名单里, 谁再写它就会被判未登记」——这样回归是**自动**的,
  不需要再加一条 grep 规则。
- 测试: `layout_metrics_test` 的「歌曲行左右贴边」用例改断言 `kPageRowPadding.left`(12);
  「两级栅格 + 预览行」里原来断言「缩略图行比页面线更靠边」的那两条改成「整页行左右都 < 16」
  (Material 默认 16 才是被废弃的口径)。`song_tile_test` / `ranking_view_test` 两处写死
  `fromLTRB(8,0,4,0)` 的期望改成引用 `kPageRowPadding`(顺带不再写死数字)。
- **golden 只动了 2 张, 且只有 recommend**: 逐字节比对后
  `recommend_360x800.png` 变化 2661 px(0.924%, bbox `x∈[8,131] y∈[212,306]`)、
  `recommend_300x640_s125.png` 变化 3329 px(1.734%, bbox `x∈[8,147] y∈[220,322]`)——
  正好是「每日推荐」那三行预览歌曲行: 左边缘右移 4dp、文本可用宽度少 4dp 导致换行点变化。
  其余 16 张**一字节未变**, 原因逐个个案核实: `playlist_detail` 的曲目 sliver 上一批已经用
  `kPageRowPadding`(不是走 SongRow 默认), `artist` 页两处同理, `mine`/`messages`/`settings`/
  `account`/`search_landing`/`feed` 不含 tile 臂默认留白的歌曲行。

### B) 纵向 pitch 统一: 行高 = `rowExtentFor`, 行内纵向留白只有 0 和 6

**判定(实测, 不是印象)**: 同一套 `SongRow` 在 360dp 宽、textScaler 1.0 / 1.3 / 1.625 下,
改动前落在**四个**高度, 源头都不是「行 padding vertical」(那一直是 0), 而是四条隐式规则叠加:

| 行 / 容器形态 | 1.0 | 1.3 | 1.625 | 纵向高度实际由谁决定 |
|---|---|---|---|---|
| `SongRow`(ListTile 臂, 默认) | 64 | 63 | 76 | `ListTile` dense 两行 minHeight(64) + `minVerticalPadding`(4×2) |
| `SongRow`(tile 臂 + `visualDensity.compact`) | 53 | 63 | 76 | `VisualDensity.compact`(-2) 把 minHeight 压到 56, 内容再撑 |
| `SongRow`(tile 臂 + `kPreviewRowPadding` 6/6) | 76 | 75 | 88 | 上一行 + 上下各 6(唯一具名纵向留白) |
| `SongRow`(plain 自绘臂, 无 `itemExtent`) | 40 | 49 | 61 | 只有封面(`CoverArt` 40)高, 纵向无任何留白 |
| 裸 `ListTile`(title+subtitle, Material 默认) | 72 | 73 | 88 | Material 两行 minHeight(72) |
| `SliverFixedExtentList` + `itemExtent: rowExtentFor` | 56 | 72.8 | 91 | `itemExtent`(唯一本来正确的形态) |

(`rg` 侧同时确认: 行级 `contentPadding`/`padding` 里 `vertical:` 非零的只有
`kPreviewRowPadding` 一处具名常量; `minVerticalPadding:` 全仓 0 处; `dense: true` 10 个文件;
`visualDensity` 21 处 —— 也就是说「行内 padding 已经全是 0」, pitch 不统一是 **ListTile 隐式规则** 的锅。)

**落地(统一口径: 行内纵向留白 0, 行高 `rowExtentFor`)**:
- `layout.dart` 新增 `rowHeightBox(context, child)` = `SizedBox(height: rowExtentFor(context))`
  (基准 56 × 系统字号, 上限 2 倍), 并在 rowExtentFor 上方写清上面那张判定表。
- 包上它的行: `SongRow` 两臂(`_build` 出口一处, 覆盖 16 处调用点)、听歌排行 `_RankRow`、
  播放队列行、云盘歌曲行、数字专辑「已购单曲」行。**唯一保留的具名纵向留白是
  `kPreviewRowPadding`(6/6)**, 且它现在落在这个定高盒**内部**(盒子仍 56 × 字号,
  6 只是行内呼吸), 不再额外把行撑高到 76。
- 不改的: 专辑/歌单/艺人等**非歌曲**的 `ListTile` 行(卡片形态、leading 是 48 封面,
  且各有自己的两行文案), 本轮只统一歌曲行。
- **门禁两道**: ①`tools/check-row-padding.sh` 新增纵向段 —— 行留白算出的纵向值只允许
  `0`(22 处)或 `6`(2 处, 预览行), 其它数字直接 `--strict` 退出 1(实测注入
  `symmetric(vertical: 8)` 后 rc=1); ②`ui/test/layout_metrics_test.dart` 新增
  「列表行纵向 pitch」用例: 4 种行形态 × 4 种宽度 × 3 档字号, 断言**渲染出来的高度**
  `== rowExtentFor` 且无 overflow。**为什么高度用渲染断言而不是 grep**: 行高是
  `dense`/`minHeight`/`minVerticalPadding`/`visualDensity` 四条隐式规则算出来的,
  源码里看不到结果值; grep 只能拦 padding 里写的数字(那部分交给脚本)。
- golden: 只动 `recommend` 两张(与 A 步同一页的日推预览行): `360x800` 20738 px(7.201%,
  bbox 覆盖 y∈[265,800] 的整整一块, 因为三行预览行各矮 8dp 后**下方区块整体上移**),
  `300x640@1.25` 32046 px(16.691%, bbox y∈[281,629])。其余 16 张逐字节未变
  (mine/artist 的歌曲行都在首屏之下, 未被 golden 取景)。
- 顺带修 `queue_sheet_test` 的拖拽用例: 原来写死 `moveBy(0, 60)` ×2 假设行高 64,
  行高统一后只跨一行 ⇒ 改成按**实测行高**分 24 小步推进(RowReorder 只在跨过中点时换位)。

### C) `ListRow` 去重: 4 个静态工厂收掉 16 处同构调用点里的 12 处

审计 §6 起草 `ListRow` 的初衷(「手写 Row 的歌曲行」)在 v0.13.0 收敛成 `SongRow` 之后已经不存在,
剩下的重复**不在行骨架、而在调用点参数**: 同一种行在 3~5 个页面里逐字抄同一组参数
(tile/plain 臂、序号宽、封面尺寸、副标题口径、是否给时长、行尾是否封顶), 漏抄一处就分叉。

所以 C 步做的是「把同构参数命名成工厂」, **不是**新写一层组件 —— 每批 ≤5 处, 每批跑全量
`flutter test`(含 18 张 golden), 三批都是**零 golden 变化**:

| 提交 | 工厂 | 收敛的调用点 | 数 |
|---|---|---|---|
| `11c6483` | `SongRow.cardPreview` | 推荐页两个区块 / 相似歌曲面板 / 「我的」页两个预览区块 | 5 |
| `bd56101` | `SongRow.pageIndexed` | 每日推荐页签 / 历史每日推荐 / 最近听过·单曲页签 | 3 |
| `3710562` | `SongRow.cardIndexed` / `SongRow.artistSongs` | 艺人页热门单曲预览 + 他人主页喜欢预览 / 艺人页全部歌曲 + 搜索结果 | 2+2 |

实现口径: 用 **static 工厂**(委托主构造), 不用具名构造 —— `SongRow` 有 30 个 final 字段,
具名构造必须把它们逐个再初始化一遍, 等于第二个默认值源(改一个默认值就会两处分叉);
静态工厂只写死那 5~10 个"同构值", 其余继续走主构造默认值。

**还剩 3 处没被收敛**(各自形状唯一, 收敛无收益, 保留现状):
`detail/playlist_songs_sliver`(徽标放副标题行 + 乐观态并集 + 两位序号)、
`album_preview`(tile 臂 + 序号 + 无封面)、`search_results`/`home_page`(走 `SongTile` 旧 API)。

## 2026-11-17(八) 用户 6 项反馈批: 歌词高光贴左 · 桌面留白 · 未登录错误 · 登录弹层 · 登录风控调查 · 长歌词滚动(**未发版**)

> 三条车道(我 + 两个子代理)并行, 编排者独立复核: 每条都做了**负向验证**(把改动回退后对应用例必须红)。

| # | 用户反馈 | 根因 | 落地 |
|---|---|---|---|
| 1 | Android 歌词页「作词/作曲」等头部行在高光时从居中变左对齐(Linux 正常) | `word_lyric_view._layoutFor` 的 `TextPainter` 只 `layout(maxWidth:)`: 段落宽 = 文本自身宽, `textAlign.center` 居中后又被 `paintOffset` 反向量左移 ⇒ 净效果画在 x=0。静态行走 RichText(段落宽=行宽)所以正常; Linux 常走行级歌词不撞这条路径 | `layout(minWidth: maxWidth)` + 副标题显式 `TextAlign.center`; 回归「高光行与静态行同一对齐口径」(回退即红) |
| 2 | Linux 播放条控件挤在右下角、间距不自然 | 播放条按手机预算排版(左右 4dp + 控件零间隔), 1280 宽窗口上控件贴成一坨 | 按宽度分两档: 窄屏(<600) 沿用 4dp/零间隔, 宽屏用 `kPagePadding` + `kRowTitleGap`(全部 layout.dart 具名常量); `player_bar_spacing_test` |
| 3 | Linux 未登录时推荐页把 `[auth] Unknown error` 当错误占位显示 | 推荐歌单区块未登录也照发请求, 匿名被判 auth, `friendlyError` 把后端原文上屏 | ① 判据改成**登录态**: 未登录不发请求, 显示中性引导(`_LoginHint`); ② `friendlyError` 增加 auth 分支 → 「需要登录后才能查看」(原文只进 `describeError` 日志); ③ daily_playlists_tab 不再叠第二句前缀 |
| 4 | Linux 登录弹窗切底部 tab 后不收起 | `showModalBottomSheet` 返回 Future, 拿不到 route, 外部无法关它 | `login_sheet.dart` 自己持有 `ModalBottomSheetRoute` + `dismissLoginSheet()`(栈顶 pop / 非栈顶 removeRoute), `_onTabSelected` 调用 |
| 5 | PC 网页登录风控(短信 4 位 / 微信扫不了) | 见 `docs/reports/login-risk-analysis-2026-11-17.md`(静态分析): ① weapi 提交**空 `csrf_token`**(登录前没 `__csrf`) ② UA 是 Mac Chrome 而 cookie 是 Windows 桌面客户端(`deviceId/appver/osver`)自相矛盾 ③ 缺 `Origin/Accept-Language/Sec-Fetch-*`、Referer 少尾斜杠 ④ 走 `/weapi` 密文路由而非官方页明文 `/api` ⑤ reqwest TLS/JA3 + 登录前无页面预检 | **本批只出报告不改代码**(改登录链必须真机/抓包对照); 报告含 5 条判据与「必须真机验证」的实验步骤 |
| 6 | 过长歌词行只显示省略号, 不滚动 | 两个歌词视图的静态行都是 `maxLines:1 + ellipsis` | 抽出可复用内核 `MarqueeScroll`/`MarqueePlayGate`(`MarqueeText` 改成无状态壳, 全仓仍只有一台跑马灯), **当前行**超宽时横向滚动(只在播放中, 放得下就是居中静态文本), 非当前行保持省略号; `lyric_marquee_test` |

**门禁**: `tools/ci-gates.sh verify` **全绿**(Rust 313 / Dart **1106** 通过 / golden 18 张逐字节未变 / clippy 0 /
lock-poison / tokens / row-padding / android-unit 3); `desktop-smoke` 无头冒烟 PASS(窗口 1280x720 + WM_CLASS + 单实例);
`android-instrumented` 5 通过 + 1 assume-skip(通知点击的 BAL 限制, 见 notes-build)。

**环境事故(已按纪律归档)**: 同一时段 Gradle 缓存里 `launcher-0.0.9-alpha04.jar` 的
`api/config/ConfigBase.class` **CRC 损坏**(导致 UTP `ClassFormatError`), 以及 Flutter SDK 的 `impellerc`
在特定着色器路径上 **SIGILL**(rc=132, 其余着色器正常) —— 两件都判为**硬件位翻转**, 证据在
`~/hw-stability/evidence/inbox/2026-11-17-netease-mini-player-gradle-jar-corrupt/`; 处置 = 删掉损坏 artifact 重新下载。

## 2026-11-17(七) 用户两条反馈 + AppImage 菜单集成 + 设备级门进阶(**未发版**)

> 上一轮中断(主机 14:29 卡死重启)后接手, 三项全部本机实跑取证。

### 1) 歌词高光行不再左右瞬移(`58dc5e9`)

用户反馈: 「滚动歌词的高光行会从居中变成左对齐, 有一次瞬移, 应该始终居中, 正在播放行只略微增大字号」。

- 逐字视图(`word_lyric_view.dart`)早在 v0.9 就统一成 15sp/w600(注释里记着"活动行放大到 18 会整行重排 + 横向抖动");
  **行级兜底 `TimedLyricView` 漏改**, 仍是 active 18sp vs 静态 15sp。
- 改成 `kTimedLyricFontSize=15` / `kTimedLyricActiveFontSize=16`, 两种行都 `TextAlign.center`。
- 回归: `song_detail_lyric_test` 新增「高光行只略微增大字号且两种行都居中」(字号差 ≤1)。

### 2) 进详情页/冷启动即预取歌词(`97b94f2`)

用户反馈: 「退出重进后点开上次歌曲的详情, 缓存不命中就一直显示信息不可用, 直到点播放才开始取周边信息」。

根因: `lyric.load()` 只挂在 `_playSong`(真播)里; `restoreFromDisk` 恢复出来的曲目和「进歌词页」两条路径都不触发取数。

- `PlaybackCoordinator.restoreFromDisk`: 恢复现场后立刻 `lyric.load(song.id)`(幂等, 失败只进 `error`)。
- `LyricController.ensureLoaded()`: 进歌词页(`toggle()` 展开)时按播放态快照主动补一次。
- 回归: `lyric_prefetch_test` 3 例(无当前曲目时纯 no-op / toggle 会读播放态并触发 / 重复调用不放大)。

### 3) AppImage 首启「集成到应用菜单」(`89f523b`, §11.A-2)

deb 由包管理器装 desktop 文件; AppImage 是单文件, 菜单里没入口也没图标。新增 `ui/lib/src/desktop_integration.dart`:

| 项 | 做法 |
|---|---|
| 判据 | 只在 `APPIMAGE` 环境变量存在时问; 已装过 / 拒绝过(数据目录 `desktop-integration.asked`)不问 |
| 安装 | 写 `~/.local/share/applications/io.github.xiaquwan1001.MiniNCM.desktop` + `~/.local/share/icons/hicolor/256x256/apps/minincm.png`(不需要 root), 尽力跑 `update-desktop-database` |
| Exec | 写 AppImage **绝对路径**(包内那份 `Exec=minincm` 只在 deb 后成立), 含空格/引号按 desktop spec 转义 |
| 不依赖 | 不用 `desktop-file-install`(desktop-file-utils 各发行版不保证有) |
| 回归 | `desktop_integration_test` 10 例(判据/文本转义/临时 HOME 落盘幂等/缺图标降级/标记) |

### 4) 设备级 androidTest 进阶进门禁(`c57a845`, §13 P-11 ②)

`tools/ci-gates.sh android-instrumented`: 没有在线 emulator → SKIP 退 0; 设备纪律复用 `tools/devui/androidtest`
(非 `emulator-*` 拒绝); `verify` 里只有 `NCM_INSTRUMENTED=1` 才带上。**a34 实跑 3/3 通过, rc=0**。

途中两个坑(已记 `notes-build.md`):
① `rustc` 在 `x86_64-linux-android` 的 **增量缓存**上 ICE(`try_normalize_generic_arg_after_erasing_regions` does not have an unique index)
  → 删 `ui/build/rust_lib_minincm/build/<target>/debug/incremental` 重编即过(编译器自己提示 clean build)。
② 模拟器上残留旧 `.dev` 包(versionCode 4026)导致 `INSTALL_FAILED_VERSION_DOWNGRADE`;
  同时 `ui/build/app/outputs/apk/debug/app-debug.apk` 会是**旧版本产物**(aapt 显示 0.18.0/40) —— 删掉这两个 apk 强制重打再跑。

### 5) 桌面自动化起步: 无头冒烟脚本(`00f1381`, §13 P-11 ③)

此前桌面端自动化为零(全靠人工点)。新增 `tools/smoke-desktop-headless` + `ci-gates.sh desktop-smoke`:
在 `xvfb-run -a dbus-run-session` 里真跑 release bundle, 自动断言 ① 存活 8s ② `$NCM_DATA_DIR` 临时目录被创建
(不碰真实 HOME) ③ 同一 session 内第二个实例 2s 内退出(严格单实例) ④ SIGTERM 干净收尾。
缺 bundle / 缺 xvfb/dbus 退 3(门禁按 SKIP); `verify` 里 `NCM_DESKTOP_SMOKE=1` 才带上。本机实测 PASS。

### 6) §12/后端审计剩余两条裁决 + lock-poison 门(`ca8b5c4`)

- **锁中毒 + `fsutil` 收敛**: 生产侧已是 0(仅 `ncm-playback` 测试里 5 处放行), `write_atomic*` 是唯一实现(7 个调用点)。
  本批把它变成不会再回来: `tools/check-lock-poison.sh` + `ci-gates.sh lock-poison`(进 `verify`), 负向探针实测会红。
- **`api.rs` 按域拆**: 实测 3 325 行 / 导出 161(30 `pub fn` + 78 `ffi_forward`) / 65 mirror / Dart 侧 173 文件引用。
  结论**暂不拆**(收益是编辑体验而非架构边界, 边界已由 crate 结构守住), 触发条件与"先搬 mirror 到 `api/dto.rs`"的第一步
  写进 `docs/remaining-batches.md` §12.1b。

### 门禁(本机实测)

Dart **1089 通过 / 0 失败**(基线 1075 + 4 歌词用例 + 10 桌面集成用例; golden 18 张逐字节未变), `dart analyze` 0 issue,
`dart format --check` 干净。Rust 侧本批未改源码(**cargo test 313 / clippy 0** 沿用上一轮)。

## 2026-11-17(五) P-11 完整版第一步: 首个 androidTest 设施 + 通知槽位断言脚本(**未发版**)

平台层审计 P-11(「Android 侧零测试 / 没有设备级断言」)的**第一步**: 设施 + 脚本 + 编译门,
**模拟器 a34 上实跑 3/3 通过**(编排者收口时跑的, `am instrument`)。真机首次跑暴露一个测试自身的缺陷
(「Player is accessed on the wrong thread」⇒ 通知拼装必须回主线程, 已修, 见下), 这些正是设备级测试要抓的东西。

> ⚠️ **收口事故记录(必须记着)**: 编排者第一次收口时直接跑了 `./gradlew :app:connectedDebugAndroidTest`,
> 这个任务会**枚举所有在线设备**, 于是把测试 APK 装到了用户两台日常物理机(HUAWEI ELS-AN00 上还执行了 3 例、
> 全部失败正是上面那个线程缺陷; 华为机上原有 `com.minincm.minincm.dev`(versionCode 4026)被 UTP 一并卸载,
> 该机现在没有任何 minincm 包)。**纪律: connected* 任务一律先过 `tools/devui/androidtest` 的设备守卫,
> 或用 `adb -s emulator-5554 install` + `am instrument` 手动指定设备; 绝不裸跑 gradle connected 任务。**

### 1) `ui/android/app/src/androidTest/`(仓库首个 instrumented 测试设施)

| 项 | 内容 |
|---|---|
| Gradle | `testInstrumentationRunner = androidx.test.runner.AndroidJUnitRunner`; `androidx.test:runner:1.7.0` / `core-ktx:1.7.0` / `ext.junit:1.3.0` / `espresso-core:3.7.0`(走仓库既有 google()/mavenCentral(), 无新增镜像) |
| 用例 | `NotificationSlotsTest`(3 例, **不需要账号/网络/音频解码**): ① 通知渠道存在且 `IMPORTANCE_LOW`(无灯/无震动); ② action 槽位 = 上一首/播放暂停/下一首/喜欢/播放顺序 + `compactActions=[0,1,2]` + 「下一首」唯一; ③ `setActionState` 回推后第 4 位变「取消喜欢」再回「喜欢」 |
| 断言口径 | 断言对象是 **Media3 用生产 `mediaButtonPreferences` 真拼出来的 `Notification`**(`DefaultMediaNotificationProvider.createNotification` + 测试侧 `ActionFactory` 记录), **不是** `NOTIFICATION_BUTTON_ORDER` 常量表 —— 改一行槽位就会红 |
| 怎么拿到被测对象 | `bindService(PlaybackService, action=androidx.media3.session.MediaSessionService)` → `PlaybackService.instance` → 反射读 private `mediaSession`(生产代码不为测试开洞) |
| 为什么不 post 再读 | 「播放一首再读 `getActiveNotifications()`」需要账号 + 网络 + 前台服务启动, 在 CI 模拟器上是不稳定源; 「真机/模拟器上**实际 post 出来的**通知」由下面的 adb 脚本覆盖, 两者互补 |
| 跑法 | `DEV=emulator-5554 tools/devui/androidtest`(硬拦非 emulator 设备, 见下) |

### 2) `tools/devui/notif-slots` + `notif_slots_parser.py`(读`dumpsys notification --noredact`)

- 解析 AOSP `NotificationRecord.dump` 的排版(`NotificationRecord(... channel=... importance=...)` 头 +
  `actions={` 里的 `[i] "<title>" -> PendingIntent{...}` + `extras` 的 `compactActions`/`largeIcon`),
  逐条打 PASS/FAIL: 5 个 action、位置契约、第 2 位是系统 play/pause、渠道 `default_channel_id` 且 importance=2、
  `compactActions=[0,1,2]`、「下一首」唯一。退出码 0/1/2/3(全 PASS/有 FAIL/用法或设备纪律/读不到 dump)。
- **设备纪律内建**: `DEV` 不是 `emulator-*` 直接 exit 2(物理机上不装包、不清数据、不读通知)。
- 离线自测 `--selftest`: `tools/devui/notif-slots-samples/` 三个**按 AOSP 排版手写**的样例(1 PASS + 2 期望 FAIL:
  下一首被吞 / 顺序错位), 自测已验证判定方向正确。
- 新增 `tools/devui/androidtest`: `connectedDebugAndroidTest` 会往**所有**在线设备装 APK, 脚本先校验
  `DEV=emulator-*` 并把 `ANDROID_SERIAL` 传给 Gradle, 保证只碰那台模拟器。

### 3) 验收(本批实测命令)

```
./gradlew :app:compileDebugAndroidTestKotlin   -> BUILD SUCCESSFUL
./gradlew :app:testDebugUnitTest               -> BUILD SUCCESSFUL(既有 3 例 EQ 夹具单测未受影响)
tools/devui/notif-slots --selftest             -> 3/3 判定正确, exit=0
```

**未做(下一批)**: 把 `connectedDebugAndroidTest` 接进 `tools/ci-gates.sh`(需模拟器, 属 CI 接入项, 本轮只登记);
通知点击行为(点按钮真能跳歌/红心)仍需真机冒烟, 脚本只断言槽位不点按。

## 2026-11-17(六) P-10 方案 B: 边下边播也能跳(待跳登记 + 换源重建解码器)(**未发版 · 已合入 main**)

用户 2026-11-17 拍板「方案 B 直接做, 允许大变更」之后, 桌面渐进播放期的 seek 从「如实拒绝」升级为「真的能跳」。

- **待跳登记**: 渐进期(解码器 `with_seekable(false)`)收到 seek 不再报错, 而是登记进 `SeekPlanner`,
  `Player::seek` 回 `SeekOutcome::Queued`, 并通过新的 `PlayerState::pending_seek_ms` 如实回传给 UI
  (UI 文案与交互属 `ui/lib` 手写 Dart, 本轮未动)。后到的 seek 覆盖先到的。
- **换源重建**: 新增 `SourceStatus`(`Seekable` / `Growing` / `GrowingComplete(path)` / `GrowingFailed`)。
  下载完成(`done` 置位且 `.part` 已 rename 成正式缓存文件)后, 播放线程用**完整文件**重建可 seek 的解码器:
  先旁路验证「能打开 + 能 seek」(失败**不动当前播放**), 再 `clear()` + 追加新源(**25ms 淡入消爆音**),
  播放/暂停态、音量、EQ 链、时长原样保留, 位置等于待跳位置; `pos_base_ms` 负责把 rodio 的相对位置补回。
- **老遗留修掉**: 换源成功后来源升级成 `PlaySource::File(完整文件)` ⇒ 同一首歌下载完成后
  **不再需要重播一次才能 seek**。每条待跳只尝试一次, 失败写 `seek_error` 后清掉(不每个 tick 反复重建)。
- **FFI 契约**(只加字段, 不动手写 Dart): `PlayerStateDto.pending_seek_ms`; `play_track` 的渐进分支把
  `ProgressiveFetch.final_path` 交给播放线程; `player_seek` 对 `Queued` 只记日志不再当错误。codegen 跑一次
  (flutter_rust_bridge 2.13, 产物 `core/crates/ncm-ffi/src/frb_generated.rs` + `ui/lib/src/rust/*`)。
- **测试**(离线、**不需要声卡** —— 用 `Player::new()` + 手工从 `SourcesQueueOutput` 抽样本模拟混音器):
  ① 待跳登记返回「已排队」而不是失败; ② 换源后 `position_ms == pending` 且换源后**立刻有声**
  (证明解码器真从待跳位置开始, 而不是从文件开头的静音段); ③ 播放态保留(含暂停中换源不放起来);
  ④ 无 pending 时行为不变(`Seekable => Direct`); 另加「换源失败不打断当前播放」「下载失败不假装排队」两例。
- **本车道实测**: Rust `cargo test` **305** 通过(本 crate 41→46) / clippy 0 / `cargo fmt --check` 干净 /
  `dart analyze` **0 issue**。**未做**: 真机桌面听感冒烟(接缝是否可闻)、`flutter test` 全量;
  权威门禁数字仍在上面「当前门禁」表(合并时由编排者重跑后更新)。
- 设计与取舍落盘在 `core/crates/ncm-playback/P10-NOTES.md`(含未做的事项)。
## 2026-11-17(一) 列表行 C 级第一批 + 一条会挂死门禁的 keyring 测试(**未发版**)

单会话收尾批。`bash tools/ci-gates.sh verify` = **ALL GATES OK**(rc=0; Rust 300 / Dart **1074** /
android-unit 3 / `row-padding` 门新增)。

### 1) 先修门禁自身: keyring 测试会把 `cargo test` 挂死

跑基线 `verify` 时 `ncm-service` 的测试二进制卡了 **7 分钟以上**(`/proc/<pid>/task` 只剩一个线程
停在 D-Bus socket `poll_schedule_timeout`, 只能 SIGKILL), 门禁因此 rc=101。根因: 
`credential_keyring::tests::available_is_cached_and_never_panics` 在 `available()` 返回 **Ok** 时
(本机真有 D-Bus)会直接做 `put/get/remove` 真实 roundtrip —— 而本机 gnome-keyring 的 `login`
collection 处于 **locked**, `set_password` 会等解锁提示(无桌面会话 = 永不返回)。探针侧本来就有 2s 上限,
写路径没有。

处置: 写路径**只在 `NCM_KEYRING_TEST=1` 门控下**跑, 且即便门控也套 `probe_with_timeout(10s)`;
未门控时只验「探测可用 + 缓存一致」。修前 `--timed` 跑该 crate 无输出, 修后 **20 passed / 0.03s**。
教训: 读路径有时限不等于整条测试有时限, 任何**写真实系统服务**的测试都必须自带截止。

### 2) 列表行 C 级第一批: 四个具名留白口径 + `row-padding` 门

审计 `docs/ui-row-audit.md` 的 C 级 18 条里, 真问题只有一个: **同一个语义用了五种不同的合法数字**
(8/0/4、12/0/4、4/0/4、16/16 Material 默认、0/6), 而 `check-tokens.sh` 只管"数值是否在白名单",
拦不住它(数值全合法)。

- `layout.dart` 再收两个常量: **`kPageRowPadding`**(12/0/4, 整页铺满且行首非缩略图 ⇒ 与页面线严格共线)
  与 **`kPreviewRowPadding`**(0/6, 父容器已内缩的预览行)。加上既有 `kSongRowPadding` / `kCardRowPadding`
  = **四个具名口径**, 不再有第五种数字。
- 迁移 **16 处** + 5 处勘误标注(radio_explore ×4 / radio_subscribers ×1, 只补理由不改代码): `all_charts_page` / `new_release_page`(歌 / 碟 / 艺人) / `my_collections_page` /
  `discover/recent_played_page`(4 行; 同页此前单曲 8、专辑/歌单/播客 16 并存) / `style_page`(卡片内 16 ⇒ 4,
  修掉 12+16=28 的三重叠加) / `detail/playlist_songs_sliver` / `artist_page`(2 处 12/8 ⇒ 12/0) /
  `artist_sections` / `user_page` / `play_queue_sheet`。
- **动错判的勘误**: 审计 §4.2 说 5 处 `contentPadding: EdgeInsets.zero` 是"贴容器边", 实测外层 `ListView`
  已经 `fromLTRB(12,8,12,24)` ⇒ 行内再加就是三重叠加, 那 5 处**本来是对的**(就地补 `// token-ok:` 理由,
  不动代码); 审计 §4.1 说 `album_preview`/`similar_sheet` 是 16/16 也已过期(它们走 `SongRow` 默认 8/0/4)。
- 新门 `tools/check-row-padding.sh --strict`(已进 `verify`): 只看 `contentPadding:` 与
  `SongRow/SongTile` 的 `padding:`, 值必须是四个常量之一; `EdgeInsets.zero` 放行但要理由。
  回归: `layout_metrics_test.dart` 新增 1 例锁四个常量的几何关系(叠出 16 / 整页行贴 12 线)。

> 为何不一起把 `kSongRowPadding`(8) 并入 12: 那会动主页/推荐/详情三处 golden 与大体量视觉,
> 属"口径已统一、只差一个数值决策"的末尾项 ⇒ 留给用户拍板(见 `ui-row-audit.md` 头部状态段)。

## 2026-11-16(日, 晚) 平台门禁进 CI + 列表行 B 级 12 条(**未发版**)

两条 lane 并行(子代理跑一半遇整机重启, uib-rows 的改动已落盘, 由主会话复核、修正一处断言后提交)。
合并后 main 上跑完整 `bash tools/ci-gates.sh verify` = **ALL GATES OK**(Rust 300 / Dart **1071** / android-unit 3)。

### 1) Android 侧门禁进 CI(平台审计 **P-14 收口**)

`tools/ci-gates.sh` 此前完全没有 Android 侧的门(`list` 里 9 个子命令, 一条都不碰 `ui/android`)。

| 新增 | 内容 | 结论 |
|---|---|---|
| `android-unit` | `:app:testDebugUnitTest`(3 条 EQ 夹具单测, 热跑 1.5s), **已进 `verify`** ⇒ 发版门也跑 | 绿 |
| `android-lint` | `:app:lintDebug`(AGP 自带, **不引 ktlint/detekt**) | **红: 67 error** ⇒ 不进 `verify`, 只在 CI 里 `continue-on-error` 暴露 + 上传报告 |

两条共用一个 prepare: `gradlew` 与 `local.properties` 都被 `ui/android/.gitignore` 排除(新克隆不存在) ⇒ 用
`flutter build apk --debug --config-only` 现场生成(0.3s, 不动 `gradle-wrapper.properties`); `JAVA_HOME` 缺 `javac`
时回落 `~/android-dev/jdk`(本机 java-25 只有 JRE, 会报 `JAVA_COMPILER`)。三套 CI(`ci.yml` 新 `android` job /
`release.yml` 发版门 / `.gitlab-ci.yml` 对等 job)都只调这两个子命令, 不再手抄命令(审计 P-13 的教训)。

**lint 现状(不许用 baseline 掩盖)**: 66 × `UnsafeOptInUsageError`(media3 usage 缺 `@OptIn(UnstableApi::class)`,
main 源) + 1 × `GestureBackNavigation`(`LoginActivity.kt:176 onBackPressed`, API36 预测性返回) + 9 warning
(GradleDependency×3 / UseKtx×2 / SetJavaScriptEnabled / ObsoleteSdkInt / NewerVersionAvailable / ExportedService)。
**触发条件**: 想让它进发版门就先补 `@OptIn` 把 error 打到 0, 再删 `continue-on-error` 并挪进 `verify`。

### 2) 列表行审计 B 级 12 条(`docs/ui-row-audit.md` §3)

B 级两类通病: ①写了 `overflow: ellipsis` 但**没 `maxLines`** ⇒ 先换行再省略(长专辑名逐字竖排);
②行尾宽度**由内容决定** ⇒ 字号放大或数字位数一变就把标题区挤扁。

- `layout.dart` 新增唯一口径 `kRowTrailingMaxRatio = 0.45` + `capRowTrailing()`; 之前各页各写一套(0.4/0.45/不设)。
- B1 `digital_album_page` / B2 `radio_subscribers_page`: 补 `maxLines: 1`;
  B3 `cover_quality_sheet`(档位名 1 行/说明 2 行) 顺带把 `sheet_header` 写死的 `height: 52` 改 `minHeight`(1.3 倍字号原本竖溢 2px);
  B4 `song_wiki` 键值行(标签 1 行/值 2 行);
  B5 `song_tile` ListTile 臂行尾封顶(触顶时**时长先省略**, 歌名不被挤) / B6 `artist_page` / B7 `artist_sections` 用 `capTrailing`;
  B8 `ranking_view`(播放次数) / B9 `mine_view`(共 N 首) / B10 `new_release_page`(时长·发行日期) /
  B11 `messages` 三个 tab(相对时间) / B12 `user_list_page`(关注按钮) 用 `capRowTrailing`。
- 回归: `narrow_width_audit_test.dart` 新增 **10 条**用例(B1–B12, 各自 12 组合 300/320/360 × 1.0/1.25/1.3/1.625):
  无溢出 + 关键文本单行 + 不出屏 + 行尾 ≤ 行宽 45%。`artist_360x800` golden 按行尾封顶后的 0.27% 差异重出。

> **断言口径教训(主会话复核定下来的)**: B5 的原用例拿 `MarqueeText` 的宽度当"标题可用宽"的代理 ——
> 但它是**自撑到内容宽**的(长标题时恰好等于可用宽, 短标题时更窄), 把 `kRowTrailingMaxRatio` 从 0.45 改成 1.0
> 该数字一个像素都不变 ⇒ 断言与"封顶"解耦, 测不出回归。改成直接找 `capRowTrailing` 造的 `ConstrainedBox`
> 量实际宽度。**经验: 断言要量被测的那件事, 不要量"看起来相关"的量**。

## 更早批次详细记录(v0.8.0–v0.19.0)已归档

> 2026-11-13 ~ 2026-11-19 的按日批次明细(拆壳各步 / 平台层审计落地 / 列表行 B+C 级 / 各用户反馈批)
> 已于 2026-11-17 迁出本文件: [archive/PROGRESS-2026-11-13-11-19.md](archive/PROGRESS-2026-11-13-11-19.md)。
> 一行摘要仍在上面的「版本时间线」表里; 本文件只保留 **v0.20.0 起**的活跃批次。

## 历史批次(≤2026-11-12)与专题小节

> 2026-11-12 及更早的按日批次记录, 以及按主题沉淀的专题小节(歌词打分/自动更新/arm64 CI/Keystore 通道层等),
> 已于 2026-11-15 迁出本文件: [`archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> 本文件只保留 **v0.20.0 起**的活跃批次(v0.8.0–v0.19.0 见上方归档指针); 结论层仍在 `.pi/memory/*.md`, 不要再追加"专题小节"。
