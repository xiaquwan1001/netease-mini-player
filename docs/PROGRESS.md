# 进度记录(Progress)

> 最近更新: **2026-11-17(八)**。已发布版本 **v0.21.0**(歌词高光行居中 + 详情页/冷启动预取 · AppImage 菜单集成 ·
> 设备级门与桌面无头冒烟进 `ci-gates`), 见批次时间线最上面那条。
> 面向新读者的速览在下一节; 按日期的批次记录从「批次时间线」起倒序(最新在上)。
> 下一轮做什么: [`docs/remaining-batches.md`](remaining-batches.md) **§11**(功能) / **§12**(结构性债务) / **§13**(平台层审计剩余);文档总索引: [`docs/README.md`](README.md);
> 架构决策: [`docs/archive/architecture-restart.md`](archive/architecture-restart.md);
> 历史批次:v1(WebView 版) → [`docs/archive/PROGRESS-v1.md`](archive/PROGRESS-v1.md),
> 2026-11-03~11-12 批次与专题小节 → [`docs/archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> **本文件只保留 v0.8.0 起的活跃时间线**(2026-11-15 精简: 1656 行 → 517 行); 更早批次已归档。

## 进度总览(2026-11-17 复核)

**当前门禁**(本机实测, 离线口径; **权威口径只在本表**, README/README.en/remaining-batches 都是指针)。
复核口径: **2026-11-17 晚在 main 上合并 p18/uib-c/p10/p11 四条车道后逐门重跑**(编排者独立跑, 不采信 worker 自报);
本轮数字变化: Rust **300→313**(P-18 数据目录迁移 8 例 + P-10 播放引擎 5 例) · Dart **1074→1088**(纵向 pitch 渲染断言等) ·
golden 只重出 recommend 2 张(8/12 二分取消后日推预览行左移 4dp、行矮 8dp) · 新增设备级门 `androidTest`(模拟器, 手工)。

| 门 | 结果 |
|---|---|
| `cargo test --offline --workspace --exclude ncm-api-rs` | **313** 通过 / 0 失败(排除 vendor 联网 smoke) |
| `cargo clippy --workspace --all-targets -- -D warnings` | **0 warning** |
| `cargo fmt --all -- --check` | 干净 |
| `flutter test --exclude-tags network`(全量, 含 golden) | **1089** 通过 / 1 skip / 0 失败(golden **18** 张; network 标签需真实凭据, 本地/CI 都不跑)。2026-11-17(二) 加 2 例(纵向 pitch 渲染断言 / 已并入行留白用例) |
| `./gradlew :app:testDebugUnitTest`(`ci-gates.sh android-unit`, 已进 `verify`) | **3** 通过 / 0 失败(EQ 三端共享夹具的 Kotlin 侧) |
| `ci-gates.sh android-instrumented`(`connectedDebugAndroidTest`, 需模拟器; `NCM_INSTRUMENTED=1` 才进 `verify`) | **3** 通过 / 0 失败(`NotificationSlotsTest`: 通知渠道 + 5 个 action 槽位 + 状态回推; 2026-11-17 a34 实跑) |
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

## 2026-11-16(日) 收尾批: 拆壳 S8 完成 + 明文白名单 + EQ 三端测试网(**v0.19.0**)

4 条 lane 并行。期间机器重启一次, 最后一条 lane 的工作已落盘由主会话验完接续; 文档 lane 误报"工作树干净"被合并前抓到(实际 5 文件未提交), 由主会话补提交。

### 前端结构: 拆壳 **S0–S8 全部完成**

| 阶段 | 结果 |
|---|---|
| **S8-1** `home/home_wiring.dart`(127) | 8 条进程级静态钩子收成 `attach()/detach()`: `Playback.setSkipHandlers` / `setActionHandlers` / `AppSettings.addListener` / `actionsHost` / `playerBarActions` / `ArtistNav.onOpenAlbum` / `UpdateCheckHost.pendingPrompt` / `pageDepth`; dispose 全部解绑, `actionsHost`/`playerBarActions`/`onOpenAlbum` **置 null**(逐项核查过读方容忍 null) |
| **S8-2** 搬家 | `HomePage`/`_HomePageState` 整体搬到 `src/home/home_page.dart`(1550) |
| **S8-3** 门面 | `main.dart` **1562 → 48 行**(只剩 `main()` + 5 组 `export ... show`), 9 个 import main.dart 的测试零改动 |
| 多实例语义 | 用 `static HomeWiring? _latest` + "只有最近 attach 者 detach 时才清全局槽位", 无需引用计数: 旧实例销毁不会清新实例绑定 |

**总账**: 审计起点 main.dart **3877 行 → 48 行**; `src/home/` 现为 8 个文件(6 个 controller + home_page + home_wiring), 从"一个巨型 State"变成"一个外壳 + 六个职责单一状态机"。

### 平台层修复

- **P-22 明文流量收窄**: 取证后确认实际走明文的只有 `music.126.net`(图片降级链最后一级)、`music.163.com`(登录 WebView)、`vod.126.net`(MV 直链兜底); 新增 `res/xml/network_security_config.xml`(默认 `cleartextTrafficPermitted=false` + 三域名白名单), manifest 去掉全局 `usesCleartextTraffic`。**受影响面界定**: 该配置只约束 Android 网络栈(ExoPlayer/WebView), Rust `reqwest` 与 Dart `dart:io HttpClient` 不受影响 ⇒ 封面/歌词/评论走 dart:io 天然不受限。模拟器实测取链播放/封面/歌词/评论四链路正常, `Cleartext HTTP traffic ... not permitted` 0 条; MV 与下载未运行时验证(已在交付注明回退法: manifest 换回一行)。

### 测试网

- **P-05 中期 / P-11 起步**: EQ 文本解析三端 **共享 fixture** `ui/test/fixtures/eq_profile_cases.json`(479 行, 覆盖 >20 filter 截断、±24dB 钳制、`Preamp` 缺省、单位/大小写变体、非法行号、空串), 三端各写断言(Dart `eq_profile_fixture_test`、Rust `ncm-domain` 测试、Kotlin `EqProfileParserFixtureTest`)。
- Kotlin 侧把邮箱解析逻辑从 `EqAudioProcessor`(240 行) 抽成无 Android 依赖的 `EqProfileParser.kt`(249), 并首次给 Android 加 **JVM 单测**(3 例, `./gradlew :app:testDebugUnitTest` 通过)。注意: 本机跑该任务必须 `source tools/env.sh`(否则 Gradle 会挑到无 javac 的 java-25 JRE, 报 "does not provide the required capabilities: [JAVA_COMPILER]")。
- Dart 侧顺带抽出 `src/eq_biquad.dart`(170) 供曲线绘制与 fixtures 共用。

### 门禁(合并后 main 复跑)

`cargo test --offline` **300** / clippy 0 warning / fmt 干净; `flutter test --exclude-tags network` **1061 通过 0 失败**(18 张 golden 无变化) / `dart analyze` 0 issue / `dart format --check` 干净 / `check-tokens --strict` + `check-write-guard` OK; Android debug 双 ABI 出包(92MB / 104MB) + Kotlin JVM 单测 3 例通过。

### 过程

- 一次 `assembleDebug` 因 cargokit 构建失败退出(exit 69), 重跑即通过; 期间主机另有并发 cargo 构建写同一 target 目录 ⇒ 判为并发/机器抖动, 非代码问题(与当天 4 起硬件异常同源, 证据见 `~/hw-stability/evidence/inbox/`)。
- 文档 lane 把门禁数字与版本号对齐现状、并新增 `docs/remaining-batches.md` **§13 审计剩余债务**(P-11 完整版 / P-05 长尾 / P-18 后半 app-id / P-10 方案 B), 另产出 worktree 清理清单(可回收约 114G)。


## 2026-11-16(日) 第六批: S7 账号动作 + 深浅色 + UA 单一来源 + seek 如实反馈(**v0.18.0**)

4 条 lane 并行。两条 lane 分别动了 `ncm-ffi/src/api.rs` 与 codegen 产物, 合并后**重跑 codegen 确认零 diff** 才继续(避免 Dart/Rust content hash 不一致)。

### 前端结构

- **main.dart 拆壳 S7**: 新增 `src/home/account_actions.dart`(500, `ChangeNotifier`): 登录/退出/切号/刷新/清凭据、账号簿入口、二级页导航(`openUserList/openPlaylist/openLikedDetail/leaveLibrary`)、列表态唯一写入口(`applyPlaybackStarted/enterHeartMode/setPlaySource/clearQueuePlaylistId`)、日推缓存按 uid 分区的入口; main.dart **1874 → 1562**(−312)。
  `src/home/` 现 6 个 controller 合计 2749 行, main.dart 从本批开工前 3095 → **1562**(−49%)。
- `_libraryTitle` 写点收口为**单一文件四处**(全在 `account_actions.dart`), 页面 0 写点; `PlaybackCoordinator.libraryTitleOf` 与 `QueueSheetController.libraryTitleOf` 改注入只读函数, S6 契约不变。

### 平台层修复

| 缺陷 | 修法 |
|---|---|
| **P-09** 登录页/MV 页固定浅色 | 平台无 `Theme.Material.DayNight`, 故用「同名 style + `values-night` 覆盖」(`LoginTheme`/`MvTheme`); `LoginActivity` 硬编码 `0xFFF5F5F5/0xFF1A1A1A` 改取 `@color/login_chrome_bg/fg`(浅 `#F5F5F5`/夜间 `#121212`, 文字 `#E6E6E6`); MV 页黑边恒纯黑但父主题随系统。模拟器(新建 p09daynight / 5558, 未抢 5554·5556)实测: 夜间采样 `#121212/#E6E6E6`, 浅色与改前一致 |
| **P-21** 播放 UA 双份手抄常量 | `identity.rs` 为唯一真值 → `ncm-ffi #[frb(sync)] playback_user_agent()` → Dart 启动握手时 `setUserAgent` → Kotlin `resolvedUserAgent()`(注入值 ?: 兜底常量), 注入值变化会重建一次 ExoPlayer(UA 在构建 DataSource 时被捕获); 防漂移: Rust 单测校验版本号格式 + Dart 幂等注入测试 3 例 + Kotlin `NCM-UA` 日志在不一致时打 W 并列两串 |
| **P-10** 渐进播放期 seek 静默失败 | 方案 A(如实反馈)而非 B(pending_seek, 需重建解码器): `PlaySource::seekable()` + `PlayerState.seekable/seek_error` + `Cmd::Seek` 有界回执(1.5s) + `Player::seek -> Result`; 进度条不可 seek 时换同款轨道 + `AbsorbPointer`, 拖/点弹「缓存中, 暂不可跳转」。**额外修掉审计没写到的缺陷**: `EqSource` 自研包装层没实现 `try_seek`(rodio 默认返回 NotSupported) ⇒ 桌面连完整落盘的文件也跳不动, 本次透传给内层 decoder |

### 门禁(合并后 main 复跑)

`cargo test --offline` **298** / clippy 0 warning / fmt 干净; `flutter test --exclude-tags network` **1037 通过 0 失败**(18 张 golden **无变化**) / `dart analyze` 0 issue / `dart format --check` 干净 / `check-tokens --strict` + `check-write-guard` OK。

### 过程

- 两次合并后 `dart format --set-exit-if-changed` 抓到 3 个未格式化文件(`ua_injection_test` / `player_bar` / `player_bar_seek_test`), 各补一个 `style:` 提交 —— 教训: **合并复查清单必须包含格式门**, 不能只看 worker 自报。
- P-10 遗留: 同一首歌下载完成后(解码器已是非 seekable)**仍需重播一次**才能 seek; 本机无音频输出设备, 端到端"拖一次"只能在 Linux 桌面上手验。


## 2026-11-16(日) 第五批: S6 队列面板 + 增益斜率统一 + Android 生命周期 + 打包加固(**v0.17.0**)

平台层审计后续批, 4 条 lane 并行(互不共享热文件)。本轮起所有 worker 都要求「每段可工作改动先 commit」——当天机器又出现两次 rustc ICE(页缓存代码页坏, 已洗 `~/.cargo/registry` 恢复), 该措施避免了再次丢中间态。

### 前端结构

- **main.dart 拆壳 S6**: 新增 `src/home/queue_sheet_controller.dart`(430, `ChangeNotifier`): 面板开关/空队列提示、点项跳播、拖拽重排、删非当前项与删当前项、清空(二次确认仍在面板内)、清空后收尾(`userStopped`→`clearSavedState`→`stopPlayback`)、存为歌单、模式轮转、顶部短浮层; main.dart **2156 → 1874**(−282)。`PlayQueue` 仍留页面按引用注入(不复制); 队列来源标题 `_libraryTitle` 刻意不外移(搜索态/心动/恢复共享真相)。
- 新增 `queue_sheet_controller_test.dart`(14 例)与 `audio_tuning_slew_test.dart`(4 例); 测试 **1010 → 1028**。

### 平台层修复

| 缺陷 | 修法 |
|---|---|
| **P-03** 增益变化三端不一致(桌面恒定 3 dB/s 且关不掉) | `PlaybackTuning.gain_slew_db_per_sec` 打通 Rust→FFI→Dart; `with_slew(0)` 语义改为**真瞬时**(旧实现 0 会回落默认 3); Dart 两端统一 `loudnessDynamic ? 3.0 : 0.0`; 运行期可 `set_slew` 切换。Rust 测试 290→**294** |
| **P-07** MV 播放无生命周期门 | `onPause` 记位置 + `video.pause()`, `onResume` 仅在"因生命周期暂停"时续播; 关键坑: 窗口重可见时 VideoView 会重建 MediaPlayer, `VideoView.seekTo` 在未进 playback state 时只记待办 ⇒ 最终在 `onPrepared` 里用裸 `mp.seekTo` 落回位置 |
| **P-08** 登录 cookie 清理做两遍且第二遍不等回调 | 清 cookie 只保留 `LoginActivity` 一处, `loadUrl` 移进 `removeAllCookies { flush; loadUrl }` 回调, 页面必然晚于清理开始加载 |
| **P-17** AppImage 工具链未 pin | pin `appimagetool 1.9.1` + 按 ARCH 内置 sha256; 下载走 `.part`→校验→`mv`, 缓存也校验, 失败打印期望/实际 sha; 调用处不再掩埋 stderr(两次尝试输出落日志并在失败时原样打印) |
| **P-18** 两平台标题/尺寸不一致 | Linux 标题 `minincm`→`轻音 MiniNCM`, Windows 尺寸 1180×780→1280×720 与 Linux 对齐; **application-id 仍不动**(会牵动单实例与用户数据路径, 另立项) |
| **P-20** 注释漂移 | `.gitlab-ci.yml` 头部口径改为「仅镜像仓、不参与发布验收」; `main.dart` 启动注释归位(更新检查与调音各自紧邻其调用) |

### 实测证据

- P-07/P-08 均在模拟器实测(a36/emulator-5556, 未碰他人 5554 实例): `dumpsys audio` 显示按 Home 后 `state:started→paused`、回页 `paused→started`; 续播位置 11253ms→13225ms(非从 0); 登录页 WebView 正常加载 music.163.com 且无 FATAL。
- P-17 正向/反向都验过: 改错 hash → exit 1 且不执行二进制; 损坏缓存 → 自动重下 → exit 0; 假工具 rc=7 → 完整 stderr 可见。

### 门禁(合并后 main 复跑)

`cargo test --offline` **294** / clippy 0 warning / fmt 干净; `flutter test --exclude-tags network` **1028 通过 0 失败**(18 张 golden **无变化**) / `dart analyze` 0 issue / `dart format --check` 干净 / `check-tokens --strict` + `check-write-guard` OK。

### 硬件稳定性(按规则 12 只登记)

当天本项目相关已登记 3 起: 两次整机 soft lockup(rebuilt 前 `kcompactd0`/`ctrl-c` stuck)、一次 `flutter build linux` 与一次 Android 构建的 **rustc ICE**(`Ty::fn_sig() called on non-fn type`); 后者经 `posix_fadvise(DONTNEED)` 洗页缓存后恢复, 指向内存/页缓存而非代码。证据在 `~/hw-stability/evidence/inbox/` 三个目录。


## 2026-11-16(日) 第四批: S5 动作宿主 + Android 通知可靠性 + CI 门禁统一 + 调音诚实化(**v0.16.0**)

平台层审计(`.pi/plans/arch-audit-platform-2026-11-16.md`)后的第一批修复, 4 条 lane 并行; 期间本机两次非正常重启, 一条 lane 的验收步骤被打断, 代码已先落 WIP 再由续做 worker 完成编译与模拟器验收。

### 前端结构

- **main.dart 拆壳 S5**: 新增 `src/home/song_action_wiring.dart`(467): `_buildActionsHost` 的「…」菜单宿主、14 个歌曲/歌单/艺人/专辑/播客动作闭包(喜欢/加队列/下一首/收藏到歌单/新建歌单/分享/评论/艺人/专辑/下载/不感兴趣/相似歌曲/百科)全部搬出; main.dart **2503 → 2156**(−347)。菜单项零增删(golden 18 张未变)。
- 测试基线 **992 → 1010**(新增 `notification_action_state_test` 7 例、`audio_tuning_apply_test`、音频设置页平台分支用例)。

### 平台层修复(审计 P-01/P-02/P-04/P-05/P-06)

| 缺陷 | 修法 |
|---|---|
| **P-01** 上划清任务后通知栏 4 按钮 + 耳机键静默失效 | 意图与消费者解耦: `requestSkip/requestAction` 无同进程消费者时走 `PendingIntent` 拉起 App 并带 `EXTRA_PLAYBACK_ACTION`(`PlaybackService.kt:725`), `MainActivity` 捕获后排队(60s TTL), Dart `actionHandlersReady` 握手后就绪重放; 兜底队列与 Intent 二选一(防同一次点击双执行); BAL 拦截时 Toast + logcat 诚实降级 |
| **P-02** 红心/模式图标服务重建后不自愈 | 原生 `requestActionStateSync`(onConnect + 握手) → Dart `_resyncActionState` 用最近已知值立刻补推; `setActionState` 幂等短路(值未变不跨通道); poll 内每 5s 节流重推 |
| **P-04** 桌面「边听边存」是安慰剂 | 桌面改为只读说明(Linux「恒开(渐进下载+落盘)」/ Windows「不可用(整首下载后播放)」), 缓存上限仍可调 |
| **P-05**(立即项) EQ 解析失败静默旁路 | 消费 `configure` 回显, `eqApplied==false` → `NCM-EQ` 日志 + 状态变化时提示一次(新增 `rootMessengerKey`/`showGlobalToast`) |
| **P-06** 冷启动调音参数丢失 | `not_ready` 改 200/500/1000ms 有限重试, 其它异常不再 `catch (_) {}` 吞掉 |

**已知限制(诚实记录)**: Android 10+ 的 BAL 限制会拦掉后台拉起 Activity(`Abort background activity starts`), 因此上划清任务后点通知按钮的实际动作要等用户打开 App 才补执行; 期间按钮有 Toast + logcat 反馈, 且排队的意图只执行一次(模拟器实测: 点通知本体回 App 后 `ncm.MODE` 补执行、模式图标实际变化)。

### CI / 门禁

- 新增 `tools/ci-gates.sh`(唯一实现): `version/check-version/rust-lint/rust-test/dart-format/dart-analyze/write-guard/tokens/flutter-test/verify`; `tools/ci.sh`、`ci.yml`、`release.yml` 全部转发。
- **修掉发版门比 CI 弱**: `release.yml` 原来 `--exclude-tags 'network || golden'`(排除 golden) → 统一 `--exclude-tags network` 并补装 `fonts-noto-cjk`; `check-tokens --strict` 与 `check-write-guard` 首次进 GitHub CI; 版本解析从 5 处收敛到一处。
- 补 `packaging/linux/build-tarball.sh`(文档原先指向不存在的脚本) + metainfo 版本断言。
- **发布验收口径(用户 2026-11-16 拍板)**: USTC GitLab 无云 runner, 此后不考虑其流水线; 代码仍双推作镜像, **GitHub CI + Release 绿即发完**。

### 门禁(合并后 main 复跑)

`cargo test --offline` **290** / clippy 0 warning / fmt 干净; `flutter test --exclude-tags network` **1010 通过 0 失败**(18 张 golden **无变化**) / `dart analyze` 0 issue / `dart format --check` 干净 / `check-tokens --strict` + `check-write-guard` OK。
**本轮起 Release 流水线会真正跑 golden**(P-13 修复前一直是跳过的)。


## 2026-11-16(日) 重构第三批: S4 播放协调器 + P1/P2 文件拆分 + 平台层审计(**v0.15.0**)

4 条 lane 并行(互不共享热文件: 只有 S4 动 `main.dart`), 合并后主会话独立复跑门禁。

### 前端结构

| 项 | 结果 |
|---|---|
| main.dart 拆壳 **S4** | 新增 `src/home/playback_coordinator.dart`(567, `ChangeNotifier`): 500ms 轮询 + `_ticker`、STATE_ENDED 即时续播(`_advancing` 临界区)、现场恢复/5s 节流落盘、下一首直链预取、通知栏封面、响度增益簿记、`playSongsList/playSong/toggle`(`PlaybackBridge.bind` 目标); main.dart **2899 → 2503**(−396) |
| **P1 拆分** | `comment_thread.dart` 1699 → **8 行 barrel**(`comment/` 5 文件: 状态机 916 / 楼中楼 tile 409 / 回复面板 194 / 输入条 170 / typedef 21); `feed_view.dart` 1190 → **7 行 barrel**(`feed/` 3 文件: 主体 607 / 卡片 278 / 艺人筛选条 313); 私有类靠 `part/part of` 留在库内, 12 个测试与各页面 import 零改动 |
| **P2 搬运** | `vip_page` 761→507 + `vip/vip_mapping.dart` 258; `medal_wall` 610→488 + `medal/medal_mapping.dart` 125; `cover_art` 699→558 + `image/url_rewrite.dart` 147(URL 改写/像素档位 7 个纯函数同族下移, 避免循环 import); 对外符号靠 `export` 保持 |

### 状态真相归属(S4)

搬进协调器: 播放态快照 `player`、轮询/续播、现场恢复与落盘、预取、通知栏封面、响度增益簿记、起播入口。
留在页面: 队列 `PlayQueue`(引用注入, 不复制)、拖拽进度、搜索页列表态(`libraryTitle`/`queuePlaylistId`/`playSource`)、依赖 BuildContext 的导航/调色板/seek/toast、`_publishPlayerBar` 帧后投递契约。
歌词边界: `poll()` 只调 `lyric.followPlayer()`; 歌词展开期 120ms 高频 ticker 仍归 `LyricController` —— **ticker 单点, 无双 tick**。

### 平台层审计(新)

`.pi/plans/arch-audit-platform-2026-11-16.md`(419 行, 只读产出): Kotlin 1949 行/6 文件(`PlaybackService` 641 + `MainActivity` 487 双巨文件)、`ncm-playback` 1687 行、tools 746、CI 794(4 份配置)。**缺陷 22 条(P1×6/P2×11/P3×5)**, 前 5: ①上划清任务后通知栏按钮与耳机键静默失效 ②通知按钮红心/模式状态无自愈 ③响度增益三端语义不一致(桌面 3dB/s vs Android 瞬时) ④桌面「边听边存」是安慰剂 ⑤EQ 文本解析三份实现且 Kotlin 回显到不了 UI。三条系统风险: 平台层零自动化覆盖、CI 四处手抄且发版门比 CI 弱、构建/打包可移植性单点(tencent 镜像、AppImage 工具未 pin)。

### 门禁(合并后 main 上复跑)

`cargo test --offline` **290** / clippy 0 warning / fmt 干净; `flutter test --exclude-tags network` **992 通过 0 失败**(18 张 golden **无变化**) / `dart analyze` 0 issue / `dart format --check` 干净 / `check-tokens --strict` + `check-write-guard` OK。


## 2026-11-16(日) 重构第二批: S3 搜索 controller + PlaybackBridge 单入口 + provider 按域拆分(**v0.14.0**)

承 2026-11-15 的两份审计与前一批拆壳 S0–S2, 本批 3 条 lane 并行(各自 worktree), 主会话合并后独立复跑门禁。中途本机断电一次, 三条 lane 的半成品全部存活, 按「续做」方式重派, 无代码损失。

### 前端结构

| 项 | 结果 |
|---|---|
| main.dart 拆壳 **S3** | 新增 `src/home/search_controller.dart`(364, `ChangeNotifier`): 综合搜索结果 / 输入联想(卡片+精确实体+纯关键词) / 搜索历史 / 落地页热词与推荐词 / 请求代次 token / 300ms 联想防抖 / busy 全部搬出; main.dart **3095 → 2899**(−196), 页面只留输入框与焦点、导航回调与 `_error` 横幅 |
| **PlaybackBridge 单入口** | 新增 `src/playback_bridge.dart`: `playSongs` / `appendNext` / `openPlaylist` 三个 handler 在 `_HomePageState.initState` `bind()` 一次; 删掉 `UserNav.onPlaySongs` / `ArtistNav.onPlaySongs` 两条静态旁路与 20 个文件的构造参数透传 —— `onPlaySongs` 在 `ui/lib` **158 → 0 处**; 保留 `playlistId`(心动模式/定位正在播放)与 `source`(日推/私人FM)附加语义; 测试注入改 `debugOverride`/`resetDebugOverride` |

### 后端/Rust

- `ncm-provider/src/lib.rs` **1321 → 30 行**(模块声明 + `pub use` + 文件分工表): 拆成 `capability.rs`(140) / `error.rs`(90) / `params.rs`(82) / `trait.rs`(948) / `registry.rs`(89); **对外路径零变化**, 下游 crate 与 FFI 未改、未触发 codegen。
- 复核确认上一批已落地的三项无需重做: `lock_ignore_poison`(30 处)、`fsutil::write_atomic`(7 处)、ttml 的裸 `fs::rename` 已被 `write_atomic` 取代。

### 门禁(本机实测, 合并后 main 上复跑)

`cargo test --offline` **290** / clippy **0 warning** / fmt 干净; `flutter test --exclude-tags network` **992 通过 0 失败**(18 张 golden, **golden 无变化**) / `dart analyze` **0 issue** / `dart format --check` 干净 / `check-tokens --strict` + `check-write-guard` OK。

### 过程

- 合并 `lane/playback-bridge` 时 main.dart 出现 1 处 `initState` 冲突(S3 的搜索 controller 装载 vs 旧 `_searchFocus.addListener` + 两条静态旁路): 保留 controller 装载、丢弃已被 controller 内部接管的焦点监听与静态赋值, 冲突后 `dart analyze` 干净、全量 992 例通过。
- S3 的 `SearchController` 与 Flutter `material.SearchController` 同名, main.dart 用 `import ... as search_state` 前缀消歧(后续引用同此约定)。
- 仓库卫生同批做: 删除 6 个已合并的陈旧 lane worktree(含 12G 的 lane-notif-order), 回收 **21G**(磁盘 626G/937G 已用, 264G 可用); 主仓 tracked 树 md5 查重无重复文件。


## 2026-11-15(六) 架构重构批(前后端 7 条并行 lane, **v0.13.0**)

前置: 两份只读审计(`.pi/plans/arch-audit-frontend-2026-11-15.md` / `-backend-`), 按「收益÷成本」排序后分 3 波派发 16 条 lane(每条独立 git worktree + 分支, 主会话合并并独立复跑门禁)。

### 前端结构

| 项 | 结果 |
|---|---|
| main.dart 拆壳 | **3917 → 3095**(−822, −21%), 新增 `src/lyric_source.dart`(271) / `notification_mode.dart`(31) / `back_policy.dart`(54) / `app_shell.dart`(241) / `home/lyric_controller.dart`(403); 公开符号靠 `export` 保持, 既有测试零改动 |
| P0 页面拆分 | `detail_page.dart` 1558→12(barrel, `src/detail/` 9 文件) / `messages_page.dart` 886→171(`src/messages/` 6) / `discover.dart` 882→13(`src/discover/` 7) |
| 歌曲行统一 | `song_tile.dart` 收敛出唯一 `SongRow`, **11 处**私有歌曲行改用它(discover 3 / artist 2 / user 1 / album / recommend 2 / similar / mine 2), 删除 `discover_song_row.dart` |
| 四态收口 | `AsyncView` 覆盖 **16 个域**: vip / 勋章墙 / 专辑页 / discover 全部页签 / messages 四个页签 / detail 头部与曲目 / 动态流 / 评论区与楼层回复 |
| 测试 | 新增 `fakes.dart`(32 份 `song()` 工厂收敛)、`async_view_test`+`error_views_test`(30 例)、`comment_fourstate_test`、cache 账号隔离 4 例; golden **12→18**(补歌单详情/艺人页/动态流) |

### 后端/Rust

- **`FfiError{kind,retryable,detail}` 跨桥**: 160 个导出从 `Result<T, String>` 收口, `retryable` 首次跨桥; Dart 侧 `isNetworkError`/`friendlyError` 改按 `kind` 决策(不再 `contains('[network]')` 猜)。
- 锁中毒容忍: `ncm-service` 25 处 `lock().unwrap()` → `lock_ignore_poison()`(中毒即续用)。
- `fsutil::write_atomic` / `write_atomic_private`: 收 6 处 `create_dir_all→tmp→rename` 样板; 模块注释里落了 `<dataDir>` 子目录 owner 表。
- 日推缓存按账号隔离(`<dataDir>/cache/daily-playlists/uid-<n>/`), 登出/切号/清凭据时清上一个账号 —— 修「切号后 A 的日推给 B 看」。

### 试过但回退

- `ncm-ffi/src/api.rs` 拆成 `api/mod.rs` + `api/dto.rs`(mirror 集中): FRB 2.13 **按 Rust 命名空间生成 Dart 文件**, codegen 后 64 个 class 搬到 `rust/api/dto.dart`, 88 文件/145 处 import 失联(`dart analyze` 928 issues)。**结论: api.rs 保持单文件命名空间**(判据已记入 `.pi/memory/notes-build.md`)。
- Provider 拆 8 个 trait: 131 个方法里 123 个已有默认 `Unsupported` 体, 收益被高估 → 判定不做。

### 门禁

`cargo test` **290** / clippy 0 warning / fmt 干净; `flutter test --exclude-tags network` **992 通过 0 失败**(18 张 golden) / `dart analyze` 0 issue / `check-tokens --strict` + `check-write-guard` OK / 接口覆盖 135/136(FFI 160)。CI: golden 已进流水线(装 `fonts-noto-cjk`, 只排 `network` 标签), `ui/dart_test.yaml` 统一标签/超时/并发。

### 过程

- 16 条 lane 里 2 条被 **SIGSEGV** 杀掉、1 次系统异常重启打断 1 条 —— 证据已落 `~/hw-stability/evidence/inbox/`(2026-11-15 两条); 重派时把大任务拆小(先 commit 再继续), 无代码损失。


## 2026-11-15(六) 逐字歌词默认 AMLL + 签到数据源纠偏(**v0.12.5**)

用户两条反馈 + 一次前后端架构审计。

### 1. 逐字歌词默认走 AMLL TTML(修回归)

- 现象: 实际播放中绝大多数歌显示的是网易云 yrc, AMLL 几乎没被用上 —— 不是链路坏了, 是
  `auto` 择优的 **0.9 短路**把 TTML 探测整个跳过了(2026-11-09 抽样 17 首: AMLL 覆盖 6/17,
  但 auto 下实际只落到 2/17 ≈ 12%)。
- 处置: 默认偏好 `auto` → **`amll`**; 设置页三态顺序改为 AMLL 优先 / 自动择优 / 网易云优先;
  `LyricSourcePreference` 语义不变(yrc 侧仍是缺失/退化时的回退)。
- 迁移: `settings.json` 加 `schemaVersion`(2), 旧文件里的 `auto` 一次性抬到 `amll`,
  之后再手动改回 `auto` 不会被覆盖。
- 延迟: `amll` 分支把 yrc 与 TTML **并发**发起(此前串行, TTML 5s 超时后白等一轮才轮到 yrc)。

### 2. 黑胶会员页签到"今日未签到 / 累计 0"

- 根因: 会员详情页的签到区取 `vip_sign_info`(乐签成长值记录, 用户不参与时整份 `score=0`),
  而「我的」页签到卡取 `signin_progress`(云贝签到)。两个数据源 → 同一屏两个相反结论。
- 处置: `VipOverview.sign`(`vip_sign_info`)删除, 换成 `daily_sign: SigninStatus`
  (**唯一权威签到源**); `vip_overview` 的 join 里第三路改为 `signin_progress`;
  `VipSign`/`VipSignDay` DTO 与 `parse_vip_sign` 一并删除, CLI `ncm vip` 同步改输出累计/连续/本周。
- UI: 会员页签到卡改为「今日已签到/今天还没签到 + 累计/连续/本周 + 最近 7 天日历 + 签到按钮」,
  「我的」页重复的 `SigninCard` 删除(入口保留: 我的 → 黑胶会员), 签到后静默刷新整页。
- 副产品: 接口覆盖 136/136 → **135/136**(唯一未接入是弃用的 `vip_sign_info`, 属有意为之)。

### 门禁

`cargo test --offline --workspace --exclude ncm-api-rs` **286** / clippy 0 warning / fmt 干净;
`flutter test` **946 + 1 skipped**(golden `mine_360x800` 因删卡片重建基线) / `dart analyze` 0 issue /
`check-tokens --strict` + `check-write-guard` OK;`api-coverage` 135/136(FFI 160, 6 无 UI 入口)。


## 2026-11-15(六) 播放队列面板排版 + 「正在播放」去重(**v0.12.4 已发布**)

- **反馈**: 队列面板标题被行尾挤成「当前播…」(截图 12:17); 序号/删除/拖拽把中间歌名压窄。同时被问「正在播放」整页的标题与返回按钮归谁管、是否重复。
- **谁在管(未改结构)**: 「正在播放」整页 = 搜索 tab 的歌单浏览态, 标题与返回键**只有一处** —— `main.dart` 的 `_buildTopBar`(title = `_libraryTitle`, leading → `_closeLibrary`); body 里没有第二个标题/返回键; 系统返回键经 `HomeBackGuard` → 同一个 `_closeLibrary`(同一动作两条入口, 不是重复 UI)。队列面板是另一层: `play_queue_sheet.dart` 的 `SheetHeader`(标题「当前播放队列」, 无返回键)。
- **真正的重复在数据层**: 「正在播放」页原先自己存一份 `_library` 快照, 队列面板删/拖/清空后它仍是旧列表, 在这页点一首还会把整队重置回旧顺序。现在删掉这份副本, `_sourceSongs` 对"正在播放/心动模式"直接读 `_queue.items`(单一真相), 队列空态文案也随之改成「播放队列是空的」。
- **面板排版**: 标题行三处一起收才够(单改一处仍会截断): 计数 `共 N 首` → `N 首` 且降到 labelSmall、动作按钮 48→40dp(新的 `_SheetIconButton`, 行内删除键共用, 高度仍 48)、标题栏横向留白 12→8。实测 360dp × 1.5 字号: 标题可用宽度 116 → 181dp(整句需 144), 不再 ellipsis。行内: contentPadding 16+16 → 4+4(`kCardRowInset`)、`horizontalTitleGap` → `kRowTitleGap`(8)、拖拽手柄横向内缩 8→4 ⇒ 歌名起点 60→40dp、删除键 270→298dp、手柄 308→332dp, 中间 +48dp。
- **回归网**: 新增 2 例(标题不 ellipsis 的 `RenderParagraph.didExceedMaxLines` 断言 + 序号/删除/拖拽/中间宽度断言), 原 5 处「共 N 首」断言随文案更新; 全量 `flutter test` **949**。

## 2026-11-15(六) 用户 2 条: 启动落推荐 + 历史日推合并本地缓存(**v0.12.3 已发布**)

- **启动默认 tab 改为「推荐」(1)**。根因不是导航默认值一项: `_restorePlayback` 会把上次的队列同时写进
  `_library/_libraryTitle`(搜索页的"歌单浏览态"), 而默认 tab 又是「搜索」, 于是冷启动第一眼就是
  "正在播放"的歌单列表。两处一起改: `_tab = 1` / `_tabVisited = {1}`, 恢复现场**只恢复队列+播放位置**,
  不再进歌单浏览态(队列仍可从播放条/播放队列进)。返回键语义: 推荐 tab 按返回先回搜索 tab, 再按才退出
  (两条 `ui_batch_a_back_nav_test` 用例随之更新)。
- **每日推荐歌单的本地缓存有入口了**: 设置 →「每日推荐歌单缓存」启用(保留 3/7/30 天)后,
  「推荐 → 每日推荐 → 历史日推」把磁盘上的缓存天与在线最近 5 次**按日期合并去重**, 本地有的那天右侧带
  「本地」徽标。点开: 在线日期照旧列当日曲目, 纯本地日期直接列当天缓存的推荐歌单(可点进歌单);
  同一天两边都有时曲目在上、缓存歌单在下。在线接口失败但本地有缓存时列表不整屏报错, 只在顶部一行提示 +「重试」。
- 新增 `DailyPlaylistCache.days()`(按日期倒序, 坏文件跳过并删除) + 5 例测试(daily_cache 2 / discover 3)。

## 2026-11-15(六) 文档精简 + 钥匙串探测超时(**未发版, HEAD=b72af21 v0.12.2**)

> 背景: 2026-11-14 23:58 掉电导致 `.git` 部分对象 0 字节、HEAD 不可读; 已从 GitHub 取回原提交
> `b72af21`, main 与 tag `v0.12.2` 均复原(`git fsck` 干净、工作区干净)。本节从该提交往后接。

- **文档精简(纯文档, 不改行为)**: `docs/PROGRESS.md` **1656 → 517 行**(175 KB → 57 KB) ——
  2026-11-12 及更早的 60 个按日小节 + 「专题小节」迁到
  [`docs/archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)(1175 行), 本文件只留 v0.8.0 起的活跃时间线。
  颟带修掉三处真错: 头部版本号停在 v0.12.1; 版本时间线里 v0.9.0 整行写了两遍; 2026-11-14(二) 的 7-lane 小节与
  三份发布记录被追加在「专题小节」之后(破坏倒序时间线)。另给「分类条均分 4+3」标注**作废(2026-11-14 晚)**
  (v0.12.2 已回退为单横排 + 横向拖拽)。
- **门禁数字收口**: 同一套数字曾散在 `PROGRESS` 头部 / `README` / `README.en` / `remaining-batches §11` 四处并已分叉
  (实测 272/284/940 三套)。现在**只留 PROGRESS 头部一张表**, 其余三处改指针; 本轮实测更新为
  `cargo test` **287** / `flutter test` **942**(+1 skipped) / `api-coverage` **136/136**(FFI 160)。
- **修一个真 bug: Linux 钥匙串被锁时启动可能挂死**。`SecretServiceStore::available()` 是 zbus **同步**调用且无超时,
  collection locked 时会一直等解锁提示(无桌面会话 ⇒ 永不返回), 而它由 `credential_store::open_backend()`
  在启动路径上同步调用。实测(修前): 单测 `credential_keyring::tests::available_is_cached_and_never_panics`
  **>70s 不返回**; 全量 `cargo test` 与 `flutter test`(frb_smoke_test 的 setUpAll)卡在同一处。
  根因证据: `busctl --user call ... Collection.Locked` = `true`(default alias = `login`, 已锁)。
- **修法**: `probe_with_timeout(PROBE_TIMEOUT = 2s, probe_secret_service)` —— 探测在独立线程跑, 主线程 `recv_timeout`;
  超时归 `Unavailable`, 上层照旧回落「用户同意的 0600 明文」(同意门语义不变), 结果仍进 `OnceLock` 缓存。
  新增 3 例单测(超时真的在时限内返回 / 结果透传 / 探测命中缓存)。修后: 同一套 keyring 测试 **8 例 / 2.0s 全绿**,
  全量 `cargo test` **287** / `flutter test` **942** 都能跑完(修前跑不完)。
- 门禁: `cargo fmt --check` 干净 · `clippy` 0 warning · `dart analyze` 0 issue · `check-tokens --strict` OK ·
  `check-write-guard` OK。

## 2026-11-14(五) 用户第四/五轮反馈 + 文档收敛(**v0.12.1 / v0.12.2 已发布**)

> 发布记录(2026-11-14 23:30 核实): tag `v0.12.1`(versionCode 30)双推 GitHub + USTC GitLab;
> GitHub Actions **Release #43609028858 全绿 14m46s / CI #43609028874 全绿 9m26s**, Release 9 资产
> (android-arm64 apk 29.6 MB / linux-x64 tar.gz 15.7 MB / linux-arm64 tar.gz 15.5 MB / x86_64.AppImage 15.2 MB /
> deb amd64 11.5 MB / deb arm64 10.6 MB / windows-x64.zip 17.5 MB / windows-x64-setup.exe 14.0 MB / SHA256SUMS);
> USTC GitLab **#9390 全绿**(rust / flutter / build-linux-x64 / build-android-arm64 / build-android-debug)。
> 待人工验证: 真机装 0.12.1 看分类条两排是否都贴满右边距、设置页字号只剩滑块。

- **分类条末尾的空缺**(**作废(2026-11-14 晚)**: 均分几何已按用户第五轮反馈回退, 见本节最后两条): 用户截图里「胶囊分类条最后一排右边空一块」——`Wrap` 按 chip 自然宽度左对齐换行,
  7 个分类在 3 列下排成 3/3/1, 最后一排只 1 个 chip。`CategoryBar` 改为**按最宽 chip 测算列数 → 均分条数
  到各排(7 条 2 排 = 4+3)→ 每排 `Expanded` 等分整行**, 于是每排左右都贴页面留白, 不再有空缺;
  新增 `category_bar_layout_test` 断言"每排最后一个 chip 贴右边距、同排等宽、间隔 6"。联想面板与搜索结果共用同一组件, 一起修好。
  实图核对: 360dp/7 分类 = 4+3 两排, 5 分类(带条数)= 3+2。
- **字号档位 chip 移除**: 设置页「界面字号」已有 0.80~1.50 步长 0.05 的滑块, 「小/标准/大/特大」chip 是重复入口,
  删掉 `AppSettings.textScales`, `textScaleLabel` 一律给百分比(`textScaleHint` 同步), 只留滑块 + A/A 两端提示 + 预览行。
- **文档收敛**(子代理执行, 主会话复核): `docs/` 根目录 13 份已完工专题 `git mv` 进 `docs/archive/`
  (对照表见 `docs/archive/README.md`「2026-11-14 归档批次」), `docs/README.md` 重写为唯一索引(5 节 + 每行最后更新日期);
  被代码注释引用的 `plan-2026-11-09-settings-and-player.md`/`credential-storage-options.md` 留原位并在 §4 写明解绑条件。
  GitHub 仓库 description 同步改写为: 非官方三端客户端 + Rust 内核(协议/身份/加解密/播放) + Flutter 单份 UI + v1 WebView 已归档重写 + MIT。
- **分类条最终改回"单横排 + 横向拖拽"**(用户第五轮反馈, 拍板): 不换行就不存在"末尾空缺/两排对齐/宽度被拉伸"任何一类问题;
  `CategoryBar` = `SingleChildScrollView(horizontal) + Row`(chip 自然宽度, 间隔 6), 联想面板与搜索结果共用;
  条数少于一屏时表现与普通一行一致, 多于一屏时右侧 chip 天然露出一截提示可拖。回归用例改为
  "同一横排 / 可拖到最后一个 / 切换选中不改宽高", 屏外分类点击的用例先 `tester.ensureVisible`。
- **分类顺序按日用查找频率从高到低**(同轮用户口径, 与"单横排"配套): 歌曲 → 艺人 → 专辑 → MV → 播客 → 歌单 → 用户。
  顺序由调用方列表决定, `CategoryBar` 自身不重排 —— 搜索结果改 `_Section` 枚举顺序
  (`songs, artists, albums, mvs, podcasts, playlists, users`), 联想面板改 `_kindOrder`
  (`song, artist, album, mv, playlist`)。回归: 结果页断言 7 个 chip 的 `left` 严格递增、联想断言 5 个 chip 同排且顺序。
- 门禁: `dart analyze` 0 issue · `flutter test` **941 通过 / 1 跳过**(golden `settings_360x800` 按新版重出) ·
  `dart format --set-exit-if-changed` 干净 · `check-tokens.sh --strict` OK。

## 2026-11-14(二) 用户反馈 15 项落地(7 lane 并行)

一次性修完用户这一轮 15 条 UI 需求, 每路独立 worktree/分支, 编排者逐条重跑测试后合并。
本机门禁: `dart analyze` 0 issue; 全量 `flutter test` **919 passed / 1 skipped**(含 12 张 golden,
本轮重建 settings/mine 各两张); `cargo test --offline --workspace` 全绿
(service 197 / ffi 46 / domain 33 / playback 7 / provider 7 / cli 6 / vendor 4);
`cargo clippy --offline --workspace --all-targets` 0 warning; `cargo fmt --check` 干净;
`tools/check-tokens.sh --strict` / `check-write-guard.sh` OK。

| # | 需求 | 落点 |
|---|---|---|
| 1 | OLED 纯黑从「主题四档」拆回独立开关(跟随系统 + 纯黑可并存) | settings_view: 三档 + `SwitchListTile`, `isOledDarkEffective/oledDarkLabel` 只说明「仅在深色生效」, 不改 themeMode |
| 2 | 「我的」可见简介/动态/编辑入口, 与用户主页同构 | mine_view 资料本层持有 + `_SelfPageEntry`/`_MySignatureSection`/`_MyFeedSection`(复用 UserEventsList); 编辑简介仅 UI 入口(后端缺 update 接口, 已验证 vendor 无该端点) |
| 3 | 动态分享支持保存图片/转发 + 可选水印 | 新增 `feed_share.dart`: FeedShareCard/CommentShareCard + 分享/转发面板, 截图走 `capturePng`, 水印画进边界 |
| 4 | 长按动态/评论弹出转发详情页 | FeedForwardSheet / CommentShareSheet; 详情页 `_forward` 从 AlertDialog 换成同一面板 |
| 5 | 关注/粉丝不可见时别露 `[internal]code=400` | Rust `check_follow_list` → `ProviderErrorKind::Forbidden` + 中文文案; UI `friendlyError` 去掉 kind 前缀, 登录表补 forbidden |
| 6 | 云盘后端 + 我的入口 | vendor 4 模块(`/api/v1/cloud/get`、`get/byids`、`/api/cloud/del`、`/api/cloud/dowonload`) + service `cloud.rs` + FFI `userCloud/cloudDelete/cloudSongUrl` + `cloud_page.dart`(列表/播放/删除/加载更多); 上传(NOS 分片)未做 |
| 7 | 通知按钮顺序: 上一首→播放/暂停→下一首→喜欢→顺序 | PlaybackService 用 `setMediaButtonPreferences` + 显式槽位; a34 实测 actions=5 且无重复下一首 |
| 8 | 网格列数对所有展示面生效 | `layout.dart::CoverGrid`(真实宽度均分 n 列、末行左对齐), 搜索各分区/新碟/广场统一; 我的收藏与艺人页沿用 CoverRow 口径 |
| 9 | 相似艺人改横排可拖拽(头像在上) | `SimilarArtistsRow` 72dp 项宽、无自动滚动(测试钉住 3s 位移=0) |
| 10 | 搜索联想/结果的 MV 分类 + MV 播放页评论区 | backend `cloudsearch type=1004` + `MvItem`; UI `_Section.mvs`/联想 mv 分组; `mv_page` 接 CommentThread(kind=mv) |
| 11 | 动态下拉刷新补历史; 标签移到昵称下 | feed 改 `feedPage` 真游标(events/lastTime/more) + 触底加载更早 + 按 id 合并去重; 用户/艺人统计行进 `ProfileIdentity.meta`(头像右侧昵称下) |
| 12 | 用户等级恒 0 | `parse_profile_detail` 回退读响应顶层 `level`(原来只读 profile.level); UI 不再 fallback 显示 Lv.0 |
| 13 | 艺人页推荐单曲/专辑并入纵向 tab | tab: 推荐单曲(有)/全部歌曲/专辑/MV/动态(有); 删除信息区重复横滑区块与详细艺人弹层 |
| 14 | 搜索联想过早截断 | 去掉 `ConstrainedBox(maxHeight:280)`, 改 `Positioned.fill` 覆盖层, 面板内部自滚动 |
| 15 | 边缘空白/视图不满宽 | 抽 `kPagePadding/kGridInsets` 并统一搜索框/精确实体条/联想/落地页/详情页错误空态 |

已知尾巴: ①编辑简介仍缺后端(需 `user/update` 类端点, vendor 未移植); ②云盘上传未做, 云盘 4 个端点未做真机抓包复核;
③艺人「动态」tab 用 `userEvents(artistId)` 尽力而为, 无专用接口; ④通知顺序仅 AOSP 14 模拟器验证;
⑤搜索结果之外的「我的收藏/艺人页」仍用 CoverRow, 未切 CoverGrid。


### 2026-11-14(二) 追加: 编辑简介 + 云盘上传 + 艺人动态结论

- **编辑简介已接通**: vendor `user_profile_update.rs` → `POST /api/user/profile/update`(weapi, 只发 signature 的局部更新);
  service `update_signature`(登录校验 + 132 字符上限 `normalize_signature`) → FFI `updateSignature` → `main.dart` 注入
  `MineView.saveSignature`, 「我的 → 编辑简介」现在是真保存并回读资料。
- **云盘上传已实现**: vendor `cloud_upload_check / cloud_nos_token / cloud_upload_info / cloud_pub / cloud_music_status`;
  service `cloud_upload` 按上游五步(md5 查重 → NOS token → 整文件 POST `complete=true` → info/v2 重试 → 状态轮询 → pub/v2);
  FFI `cloudUpload(filePath)`; Android `ncm/upload#pickAudio`(ACTION_OPEN_DOCUMENT → cache 副本)、Linux zenity/kdialog、
  Windows PowerShell 选文件; 云盘页右上角上传 + 进度对话框 + 秒传提示。**分片上传未做**(单请求路径与上游前端一致)。
  新增依赖 `md-5 0.10`(本地 registry 已缓存); CLI 加 `ncm cloud-upload <path>` 便于真机/桌面自测。
- **艺人动态结论(不可做)**: 上游 `/api/artist/detail/dynamic` 实测只返回 `concert/followed/videoNum`, 不是动态流;
  Binaryify 快照里也没有 artist event 模块 ⇒ 艺人「动态」tab 继续用 `userEvents(artistId)` 尽力而为, 不要再去翻这个端点。
- 门禁: cargo fmt/clippy(0 warning)/test 全绿(service 198); `dart analyze` 0 issue; `flutter test` **923 passed / 1 skipped**;
  `check-tokens --strict` OK(上传图标固定尺寸已加 token-ok); debug APK 出包并装回前台模拟器。

## 2026-11-14(四) 用户第三轮 16 项反馈(**v0.12.0 已发布**)

用户原话 16 条(搜索页 1-2 / 联想 3-6 / 动态与评论 7-10、13-14 / 我的与设置 11-12、15-16),
外加追加需求「正在播放的歌曲要在同一个歌单里高亮」。

- **搜索分类 tab 的"奇怪缩进"是几何问题, 不是 padding 问题**: 分类条原来是 `Padding + Wrap`,
  父级 `Column`(默认 `crossAxisAlignment.center`)给的是松约束 ⇒ Wrap 收缩到内容宽度后被**居中**;
  再加上选中项默认 checkmark 会改变 chip 宽度, 于是"选中第二排时两排突然对齐、缩进消失"。
  修法: 抽出 `ui/lib/src/category_bar.dart`(`SizedBox(width: infinity)` + `WrapAlignment.start`
  + `showCheckmark: false`), 搜索结果与输入联想共用; `test/category_bar_layout_test.dart` 用
  「两排首个 chip 的左边界 == kPagePadding」「切到第二排时每个 chip 位置/宽度不变」锁死。
- **联想改成分类 tab**(需求 3/5): 一次只渲染一个分类(带条数), 默认打开"个性化排序后第一条"所属分类;
  Rust 侧 `rank_suggest`: 按"是否与我关注的艺人相关"重排(类间 + 类内, 稳定), 关注列表 5 分钟缓存
  (不打风控敏感的 sublist); 每类上限 3→10(服务端通常只给 2~6 条)。
  封面: 专辑改用**专辑自己的** `picUrl`(以前先取 artist.picUrl ⇒ 联想专辑全是歌手头像),
  歌曲缺图用一次 `song_detail` 批量补(按 id 缓存 500 条), 失败静默。
- **键盘弹出与联想面板之间的空缺(需求 4/6)**: Scaffold 已按 `viewInsets.bottom` 收缩, 而根布局的底部
  导航栏仍占 80dp ⇒ 内容底边 = 键盘顶 - 80dp。现在键盘在场时导航栏一并让位
  (`test/bottom_chrome_padding_test.dart` 加断言)。
- **动态/评论(7-10/13/14)**: 详情页显式分享/转发图标; 转发动态 / 分享卡片图 / 复制链接收敛到一个面板;
  长按评论有与「回复」同源的 `primaryContainer` 选中底色(1.5s 褪去); 评论分享卡片补
  「来自‹歌曲/歌单/专辑/播客/MV›《标题》」+ 点赞数/回复数(`commentSourceKindLabel`);
  点赞从动作行上移到「用户名 + 发布时间」行并显示数量; 他人主页/艺人页「动态」tab 复用共享
  `FeedSongMiniCard`/`FeedVideoThumb`, 图片与分享内容自动展示。
- **字号"重启回默认"的真因(需求 11)**: `AppSettings._save()` 整份重写 settings.json, 而
  `writeAsString` 是先 truncate 再写 ⇒ 两次写并发时产生半截文件, 下次启动 `jsonDecode` 失败被吞
  ⇒ 所有偏好静默回默认。改为**串行 + 原子替换**(写 `.tmp` 再 rename)、坏文件改名 `.bad` 留存;
  `_file == null` 时 `_save()` 直接返回(以前会串到上一个落盘任务的 Future, 那个 Future 可能属于
  已结束的 zone ⇒ widget 测试假死 10 分钟)。UI 换成 0.80~1.50 步长 0.05 滑块 + 四个预设档位。
- **点法统一(需求 12)**: 关注/粉丝列表整行(含头像/名字)进对方「动态」(默认 tab, 留在同一栈内);
  关注动态流作者栏整行筛动态, 主页入口只留在动态卡片里。
- **我的动态并入我的主页(需求 15)**: 删掉预览区块, 入口升格为整行按钮, golden 重出。
- **一排/两排(需求 16)**: 我的与他人主页的歌单/播客/专辑横滑都走 `CoverRow(rows: coverRows)`。
- **正在播放高亮(追加需求)**: 新增 `ui/lib/src/now_playing.dart`(`nowPlayingSongId` +
  `NowPlayingHighlight`), HomePage `_publishPlayerBar` 帧后投递; 歌单/专辑 detail 曲目、日推与历史日推、
  艺人全部歌曲、搜索结果(`SongTile` 不传 `active` 也读全局)、我的页两个预览、听歌排行、播客单集行
  (按 `program.song.id`)统一「序号→喇叭 + 主色歌名 + selected 底色」, 切歌实时跟随。

**门禁**: `flutter test` 940 通过 / 1 skip; `dart analyze` 0 issue; `dart format --set-exit-if-changed`
干净; `check-tokens --strict` OK; `check-write-guard` OK; `cargo test` 284 通过、clippy 0 warning、fmt 干净;
`flutter build apk --debug` 成功。两个子代理 lane(feed/comment、profile/settings)在独立 worktree 完成后
由主代理独立重跑全量测试与门禁再合并。

## 2026-11-14(四) 发布记录 v0.12.0

- **GitHub**: CI(main) `43603964002` **success**;Release(tag) `43603963758` **success**, 9 个资产:
  android-arm64 apk 29.6MB / linux x64 tar.gz 15.7MB / linux arm64 tar.gz 15.5MB / x86_64 AppImage 15.2MB /
  windows setup.exe 14.0MB / windows zip 17.5MB / amd64 deb 11.5MB / arm64 deb 10.6MB / SHA256SUMS.txt。
- **USTC GitLab**: pipeline **#9380**(tag v0.12.0) **success**;main #9355 的发布 job 为 manual(按需 play)。
- 版本: `0.12.0+29`(`kAppVersion` 同步);tag `v0.12.0` 双推;两条流水线均一次全绿(交付前已对改动文件
  跑 `dart format` + `cargo fmt --all`, 未触发前两轮的 formatter 门禁红点)。
- 待人工验证(不阻塞发布): ①联想面板底部是否真的顶到键盘(需求 4/6);②分类 tab 两排在各种选中状态下的
  对齐观感(需求 1/2);③播放态高亮的语汇(喇叭 + 主色歌名)在日推/歌单/播客单集里是否够醒目;
  ④字号滑块拖到 1.15/1.35 后杀进程重进, 确认不再回默认(需求 11 的现场验证)。

## 2026-11-14(三) 用户第二轮 15 项反馈(**v0.11.0 已发布**)

用户看着真机截图提的第二轮 15 条, 逐条落地。门禁: `dart analyze` 0 issue;
`flutter test` **928 passed / 1 skipped**(golden 里 mine 两张重建);
`cargo test --offline --workspace` 全绿(service 200 / domain 46 / playback 33 / provider 1 / ffi 1);
`cargo clippy --workspace --all-targets -D warnings` 0 warning; `cargo fmt --check` 干净;
`tools/check-tokens.sh --strict` / `check-write-guard.sh` OK; debug APK(x86_64+arm64)出包成功。

| # | 需求 | 落点 |
|---|---|---|
| 1 | 艺人页统计行加粉丝数、横条占满整卡宽(数字被截断) | vendor 新增 `artist/follow/count/get`(**参数名 `id`**) → `ArtistDetail.fans_count/followed` → 身份卡改 `footer` 放 `ProfileStatRow`(粉丝 + 作品数), 不再挤 meta 列; 关注按钮初始态用 `isFollow` |
| 2 | 推荐单曲「播放全部」左顶格; 「共 N 首」移到全部歌曲 tab | `artist_sections` 改 InkWell+Row(去掉 IconButton 隐形内边距); 计数搬到 `_AllSongsTab` 头部 |
| 3 | 搜索 🔍 从顶栏右上角移到全部歌曲 tab「共 N 首」右侧 | `_AllSongsTab` 自带 开/关搜索 + 输入框, 删除 `ProfileScaffold.searchBar` 用法与 top-right action |
| 4 | 已有账号时添加账号, 关闭/失败登录页仍提示「登录成功」 | Rust `login_with_cookie` 只有在入参含非空 `MUSIC_U` 时才合并(`+单测`); Android `finishCancelled()` 不再回传 cookie, `onActivityResult` 仅 RESULT_OK 才取 |
| 5 | 取关/取消喜欢的撤销弹窗不自动回落、遮挡内容 | SnackBar 统一 floating + 3s(撤销条 4s); 取消喜欢/取消关注去掉「撤销」按钮只留短提示; `showUndoToast` 仅留给取消收藏歌单 |
| 6 | 简介并进昵称下方(关注/粉丝/等级之上), 不要独立条目; 他人同理 | `ProfileIdentity` 新增 `subtitleAction/subtitleMaxLines`; 「我的」页删 `_MySignatureSection`(改行内「编辑简介」); 他人主页删「简介」区块 |
| 7 | 他人主页动态实际是自己的、且不显示图片 | 根因同 11(端点); 另 `_EventSummaryCard` 此前不渲染图片, 现补 `FeedImageGrid` |
| 8 | 他人主页去掉 关注/粉丝 tab(交给 chip) | `_tabSpecs` 只留内容分类; chip 直接进关注/粉丝列表页 |
| 9 | 他人主页「我喜欢」单独一栏 + 最近若干首, 其余歌单分栏 | `user/playlist` 的 `specialType=5` 单独成「我喜欢」栏(`_LikedPreview` 前 20 首 + 查看全部); 其余进「歌单」栏 |
| 10 | 电台已并入播客, 检查文案 | UI 文案统一「播客」(广场/榜单/空态/搜索分区/详情空态); **接口仍是 djradio/dj_program, 未迁移** |
| 11 | 艺人页动态接线错(显示自己的动态) | 根因: `/api/v1/event/get` 丢弃 uid + 拿 artistId 当 uid。改 `POST /api/event/get/<uid>` + 用 `artist/head/info/get.data.user.userId`, 无绑定账号不生成 tab |
| 12 | 仅分享歌曲的动态不再重复附带专辑/歌曲图片 | `feed_media.feedAttachedImages()` 剔除与 `coverUrl`/`song.coverUrl` 相同的图 |
| 13 | 图片预览太小, 按附图数量排版 | `FeedImageGrid`: 1 张铺满(4:3) / 2 张两列 / 3+ 三列; 列表卡 / 详情 / 摘要卡共用 |
| 14 | 官方板块合并现状(电台/笔记/MV) | 见下「调研结论 A」 |
| 15 | 我们的 API 理解偏差 | 见下「调研结论 B」 |

**调研结论 A(板块合并/迁移)**: ①「电台」2020-11 起产品层更名「播客」, **接口未迁移**(djradio/dj/program 仍在用, 本仓 2026-11 实测 10 个端点匿名 200) ⇒ 只改 UI 文案;
②「社区」2024-01 改名「动态」, 2024-11「笔记」上线并成为社区主形态(图文/带音乐), 但上游快照**没有按用户取笔记的端点** ⇒ 不新造「笔记」tab;
③ MV 在数据层是艺人页独立分区(`artist/mvs`), 不属于动态; 艺人动态无专用 feed 端点(与旧结论一致);
④ 云盘/数字专辑/排行榜/我的收藏名称与入口未变。

**调研结论 B(API 语义偏差, 已全部修正)**: ①他人动态端点错(见 #11); ②艺人粉丝数/关注态来自 `artist/follow/count/get`(artist detail 不给); ③`artist/head/info/get` 的 `data.user` 才是艺人绑定账号, `data.eventCount` 可用于判断; ④他人主页的「我喜欢的音乐」= `specialType=5` 歌单(公开时匿名可取), 而他人听歌排行恒无权限;
⑤`user/playlist` 只回公开歌单, 私密歌单只有自己登录可见。「普通用户 vs 音乐人」是两套独立数据, 页面互跳只走 `profile.artistId` / `data.user.userId`。

## 2026-11-14(三) 发布记录 v0.11.0

- **GitHub**: CI(main) `43581417264` **success**;Release(tag) `43581446131` **success**,
  9 个资产(android-arm64 apk 28MB / linux x64+arm64 tar.gz 14MB ×2 / x86_64 AppImage 14MB /
  windows setup.exe 13MB + zip 16MB / amd64+arm64 deb 10MB ×2 / SHA256SUMS.txt)。
- **USTC GitLab**: pipeline **#9350**(tag v0.11.0) **success**;main #9349 的发布 job 为 manual(按需 play)。
- 版本: `0.11.0+28`(`kAppVersion` 同步);tag `v0.11.0` 双推;接口覆盖 136/136。
- 本轮 CI 一次全绿(交付前已对本轮改动文件跑 `dart format` + `cargo fmt --all`)。
- 待人工验证(不阻塞发布): ①登录页「关闭/失败」不再提示登录成功(需真机点一次);
  ②登录态下他人动态的隐私降级文案;③艺人页「动态」只在绑定账号的艺人上出现(周杰伦 6452 没有);
  ④视觉过目: 艺人统计行整卡宽/播放全部顶格/全部歌曲 tab 头部「共 N 首 + 🔍」/动态配图 1-2-3 排版。

## 2026-11-14(二) 发布记录 v0.10.0

- **GitHub**: CI(main) `43574520104` **success**;Release(tag) `43574524610` **success**,
  9 个资产(android-arm64 apk / linux x64+arm64 tar.gz / x86_64 AppImage / windows setup.exe+zip / amd64+arm64 deb / SHA256SUMS.txt)。
- **USTC GitLab**: pipeline **#9340**(tag v0.10.0) **success**;main #9339 的发布 job 为 manual(按需 play)。
- 版本: `0.10.0+27`(`kAppVersion` 同步);tag `v0.10.0` 双推。
- 首轮 CI 唯一红点 = **dart format 门禁**:本轮 lane 写入的 15 个文件没按 Dart 3.13 格式化
  (tag 流水线同样有 `dart format --set-exit-if-changed lib test`)。处置:只格式化这 15 个文件 +
  补 5 处 formatter 折叠后触发的 `curly_braces` ⇒ 删旧 tag/release 后按格式化提交重推, 全绿。
  **教训**:lane 交付前应对自己改过的文件跑 `dart format <files>`(不要全仓), 否则 tag 流水线必红;
  已发布的 tag 如需重指, 先 `gh release delete` 再删远端 tag, 否则 Release job 会撞已有资产。

## 2026-11-14: 通知封面/下一首 + 播放现场记忆 + 乐观续播 + 主题四档(**v0.9.1 已发布**)

用户报了一批 APK 侧的体验问题, 这一批先落"播放与通知"与"设置页主题"两块:

**Android 通知栏**
- 通知/锁屏/车载的封面改成**当前播放内容自己的图**(歌曲封面 / 播客封面, 都走 `SongDto.coverUrl`)。
  Media3 按 URL 自己取图会用默认 UA, 被网易 CDN 回 403(通知上就是空白), 所以由 Dart 侧
  `fetchImageBytes`(浏览器 UA + 已有字节 LRU)下好再经 `ncm/player#play` 的 `artwork` 传给 native。
  取图带 300ms 超时: 拿不到就沿用上一张/空白, **绝不为了封面拖慢播放**。
- 通知栏新增**「下一首」**自定义按钮(`CMD_NEXT=/ncm.NEXT`): 系统紧凑视图只放 3 个动作,
  已有喜欢/播放顺序两个自定义按钮时"下一首"会被挤掉(用户实测下拉状态栏只剩「上一首/暂停」)。
  点击仍只发意图, 换曲在 Dart 队列里做(与耳机键/锁屏同一条 `skipNext`)。

**播放现场记忆(`ui/lib/src/playback_state.dart`)**
- `<dataDir>/play_state.json`(先写 .tmp 再 rename): 队列 + 下标 + 位置 + 播放模式 + 列表标题。
- 启动恢复播放条(封面/曲名/队列/进度), **不自动出声**; 点播放才取链并从上次位置续播。
- 播放中每 5s 节流落盘, 换曲/暂停立刻落盘; 清空队列时抹掉现场。
- 坏 JSON / 缺字段 / 越界下标 / 重复曲目全部容错(7 例单测, 见 `ui/test/playback_state_test.dart`)。

**乐观续播(减少"每首之间卡一下")**
- 原生 `STATE_ENDED` 立即回调 Dart(`trackEnded`), 不再等 500ms 轮询发现"位置到末尾"。
- 播放起来后后台**预取下一首直链**(带 4 分钟时效, 随机/单曲循环不预取), 换曲时省掉数百毫秒取链。
- 桌面端本来就是边下边播(`PlaySource::Growing`), 未改。

**VIP 跳过语义修正(`playback_policy`)**
- 「自动跳过 VIP 歌曲」只约束**自动续播/切歌**; 用户主动点选的歌必播(官方也是试听前 30s),
  只有取链真的拿不到直链才继续往后跳。三处点播入口(列表/搜索/队列面板)传 `explicit: true`。

**设置页: 主题模式合并 OLED 纯黑**
- 主题模式从「跟随/浅色/深色 + 独立 OLED 开关」合成**四档**(跟随/浅色/深色/纯黑),
  存储字段不变(`themeMode` + `oledDark`), 旧 `settings.json` 直接可读。
  原设计在浅色态下那个开关是「开了但没效果」的无效状态, 合并后消失。
- 「主题色」tile 改用 `SizedBox(width: infinity)` + `bodyLarge`/`bodyMedium`,
  与同卡 ListTile 的左边界与字重对齐(之前被外层 Column 居中 ⇒ 多缩进一截 + 标题更粗)。

**发布与 CI(v0.9.1)**
- GitHub:CI(main)`43556951477` 绿(9m54s);Release(v0.9.1)`43556963532` 绿,8 个资产
  (android-arm64 apk / linux x64+arm64 / AppImage / deb x64+arm64 / windows zip+setup / SHA256SUMS)。
- USTC GitLab:pipeline 9334(tag v0.9.1) 5 个 job 里 4 绿,唯一失败是 **build-android-debug 的产物上传**:
  两个 ABI 的 debug APK 合计 187MB,超过实例 artifact 上限 ⇒ `413 Request Entity Too Large`。
  已修(`77d2b6a`):只上传 x86_64(模拟器验收用),arm64 真机包由 GitHub Release 出正式签名版;
  main pipeline 9335 手动 play 该 job 实测 **success**。**v0.9.1 的 tag pipeline 无法回改**,下一版 tag 起生效。
- `git-dual-push` 只推当前分支,不推 tag ⇒ tag 要单独 `git push <remote> vX.Y.Z`(本次已双推)。

**搜索限流(车道 lane/cache2, 已合入)**
- 新增 `core/crates/ncm-service/src/read_cache.rs`: 进程内 TTL 300s + 200 条 LRU + 同 key 单飞。
- 白名单只放与账号无关的只读接口(搜索族 / 歌单详情 / 专辑详情 / 歌词), user_*/每日推荐/收藏/
  私信/喜欢状态/song_detail 一律不缓存; 会话变更清空缓存防串号。
- 效果: 模拟 `search_all` 连搜 5 轮, 上游请求 30 → 6; 5 分钟内重复搜索上游 0 次。
- 单测 11 条(`cargo test --offline -p ncm-service` 177 → 188), clippy 0 warning。

## 2026-11-13(六): 匿名诊断一键提交 + 列表行 A 级修复 + 我的页排序(v0.9.0)

| # | 需求 | 落地 |
|---|---|---|
| 1 | 「一键传」但小白无 GitHub 账号、不自建服务器 | **Cloudflare Worker 代理建 issue**: `tools/diag-worker/`(白名单二次脱敏 + PII 兜底 + KV 限流 10/h + `clientId` 幂等 + GitHub 3 次退避重试/8s 超时); 客户端 `diag_upload.dart`(15s 超时、0.5/1/2s 退避、4xx 不重试、错误带 `retryable`)。**token 由用户部署时手动创建**(fine-grained PAT 只勾 Issues: write + 单仓库, `wrangler secret put`), 仓库/客户端零 token、端点默认空 |
| 2 | 我的页: 收藏专辑放到收藏播客前 + 两栏目按最近交互优先 | `recent_order.dart` 三个纯函数; `AppSettings.touchInteraction/lastInteractionMs`(settings.json 里存 `kind:id → ms`, 上限 200 条); 栏目顺序: 默认专辑在前, 谁最近被交互过谁前移; 栏目内条目按最近交互倒序、无记录保持后端顺序; 交互打点在 `_openPlaylist`/`_openPodcastRadio`/`showAlbumPreview`(专辑入口 10 处, 收在入口一处) |
| 3 | 列表行 A 级(必坏)7 处 + 2 处真 bug | 见 `docs/ui-row-audit.md`: comment 时间/IP 与动作行、feed 相对时间、profile 横幅 overlay、歌单广场 chip 行、曲目行行尾、队列行尾两个 48dp 按钮全部加 flex/封顶; `digital_album_page` 与 `radio_subscribers_page` 的"有 ellipsis 没 maxLines"(先换行再省略, 行高翻倍)补 `maxLines: 1` |

**诊断上传的三层不稳定与兜底**(写在 `tools/diag-worker/README.md`): `*.workers.dev` 在国内连通性差
⇒ 绑自定义域; GitHub 5xx ⇒ Worker 内退避重试 + 幂等键(重发不建重复单); 用户网络差 ⇒ 客户端重试,
且**无论成败都先落盘本地 JSON**, 失败提示里直接给本地路径。端上端点为空时整行禁用, 不会静默失败。

坑: 诊断页的开关没有外层 `AnimatedBuilder`, 点开关视觉不动(值其实已变) ⇒ 该分组自己监听 `AppSettings`;
新加用例 `test/one_click_diag_test.dart` 锁住"未配置端点时必须禁用"。

## 2026-11-13(五): 设置三项 + 主页统一 + golden 网 + 术语(v0.9.0)

| # | 需求 | 落地 |
|---|---|---|
| 1 | 设置里能「播放跳过 VIP 歌曲」 | 规则抽成纯函数 `playback_policy.dart`(只跳 fee=1 的会员曲目, 不碰 fee=4 数字专辑、不碰无版权); `_playSong` 的续播循环里静默跳过、整轮结束提示一次(否则自动续播会连环弹窗) |
| 2 | 每日推荐歌单本地缓存 + 可选跨度 + 清理日期 | `daily_cache.dart`: `<dataDir>/cache/daily-playlists/YYYY-MM-DD.json`, 同日命中不再联网、离线可兜底、损坏自动丢弃; 设置 → **缓存** 分组: 保留 0/3/7/30 天 + 立即清理 + 上次清理时间(下拉即清, 免得 30→3 天的旧文件要等下次手动清) |
| 3 | 凭据存储右边重复的 android-keystore 文本框 | `_CredentialStorageTile` 删掉 `trailing: Text(status.backend)`(与 subtitle 的说明重复) |
| 4 | 诊断与数据里默认可匿名发送 debug 数据 | 开关 + 「生成匿名诊断包」(`debug_report.dart`): 只导环境/设置/provider id/凭据后端 kind, **不含**昵称/uid/cookie, deviceId 只留 FNV 摘要; 无自建端点 ⇒ 不自动上传, 落盘到 `debug/` 由用户自己决定发哪里 |
| 5 | 关注页点头像进主页, 且与搜索进入的个人主页同一份排版 | 新增 `artist_nav.dart`(与 `user_nav.dart` 同形): 关注页横向艺人 chip 与「全部艺人」面板**只把 40dp 头像**包成入口, 整块仍是筛选; 主页侧统一 8 处口径(主标题字号/头像 64/统计行复用 `ProfileStatChip`/新增 `ProfileSection` 统一分区几何/分区顺序 简介→作品→相似/首屏错误态 `ProfileLoadError`/缺条目直接不渲染) |
| 6 | 「歌手」→「艺人」 | 48 个前端文件(含测试与注释)统一替换; codegen(`lib/src/rust/`)不动 |
| 附加 | golden 视觉回归网 | 6 页 × 2 视口(360×800 / 300×640@1.25)= 12 张; 用 `FontLoader` 加载系统 Noto CJK(否则渲染方块), 只在本机 Linux 生成/校验, CI 暂不接 |
| 附加 | 列表行审计 | `docs/ui-row-audit.md`: 49 处行骨架 → A 必坏 7 / B 潜在 12 / C 一致性 18(歌曲行 6 种留白); 给出 `ListRow` API 草案与 10 条改造顺序 |

坑(已记进 `.pi/memory/notes-ui-rules.md`): 真 IO 在 `testWidgets` 的 FakeAsync 里**永远不完成**(本次 `debug_report_test` 卡了 7 分钟才发现) ⇒ 落盘类用例一律用普通 `test()` + `TestWidgetsFlutterBinding.ensureInitialized()`。

## 2026-11-13(四): 规则层收口(唯一 AsyncView / SectionTitle / token 门)

起因是一句判断: "能感知问题, 但说不出规范, 只能逐个打补丁, 越修越慢"。对照检查后
发现本项目**已有**规则层骨架(layout.dart 栅格、AdaptiveText、LoadingView/InlineError、
118 个 widget test), 缺的是三处收敛 + 一张网。

| 缺口(量化) | 落地 |
|---|---|
| 异步四态有 **5 份实现**: 2 份私有 `_AsyncSection`(mine/recommend) + ranking/chart/mv 各手写 `FutureBuilder` + style_page 2 处 | 收敛成唯一 `lib/src/async_view.dart`; `grep -rn 'FutureBuilder<' ui/lib/` 现在只剩它内部 1 处。顺带修掉一个潜伏 bug: 箭头体 `setState(() => _future = ...)` 会把 Future 当返回值, mv_page 一按「重试」就断言失败 |
| 同一小组标题实现 **6 遍**(padding 有 top:4/bottom:6、bottom:6、bottom:8 三种) | `SectionTitle`(titleSmall) + `kSectionTitleGap`; `SectionHeader`(titleMedium) 与它共用私有 `_titleRow`(尾部 60% + FittedBox 规则只留一份)。`grep 'class _SectionTitle'` = 0 |
| 间距/圆角/字号散写: 175 处 `SizedBox(height: 字面量)`、圆角 7 种值、`fontSize` 直写 49 处 | `tools/check-tokens.sh`: 集合外数值必须消除或写 `// token-ok: 理由` 显式例外。基线 20 处已清零, ci.sh 切成 `--strict` |
| golden test = 0, custom_lint 无 | **未做**(下一轮 P2); 结论: golden 只在本机 Linux 生成/只在 Linux CI 跑, 选 6 个高价值页 × 2 档 |

两条纪律(写进 review 口径):
1. **改页面 vs 改契约**: 契约件是 `layout.dart` / `adaptive_text.dart` / `section_header.dart` /
   `song_tile.dart` / `cover_art.dart`, 动之前必须数影响面 + 跑 `layout_metrics_test`、
   `narrow_width_audit_test`;
2. **一个动作只允许一个控件**: v0.8.1 的 5 条反馈(账号管理 3 个入口、热搜「关闭」+ ❌、
   相对图地址被静默丢弃、active 行 onTap 恒 null、cookie 残留误判已登录)都属于契约缺失,
   不是手滑。

验收: cargo test 277 / clippy 0 / fmt 干净; flutter test **752** / `dart analyze` 0 /
`dart format` 干净 / `check-tokens --strict` OK。

## 2026-11-13(三): 用户反馈 8 项 UI 修复(v0.8.1)

第一批"上一轮未提交"的工作先归档成 `feat:` 提交(歌手专辑分页 / 私信 / 消息页重做 / 搜索页热搜开关与排行榜 /
方格列数 / debug APK CI), 随后按 8 条反馈逐项修。

| # | 反馈 | 根因 | 处置 |
|---|---|---|---|
| 1 | 「我的」昵称/关注数**下面还遮着一条横条**, 点漏出的部分也进账号管理; 背景右上角还有「账号管理」 | `ProfileBanner` 用 `Transform.translate(-12)` 上浮身份卡 —— transform **不改布局占位**, 后面再补一条 12dp `surface` 色块 ⇒ 卡片底部实际多出 12dp 且整块在 `InkWell` 内 | 改成 `Stack`(图 `Positioned` + 身份卡 `Padding(top: height-lift)`), 不再有补色条; 删掉右上角药丸与未登录时的「账号管理」按钮, 账号入口统一收进 **设置 → 账号管理** |
| 2 | 账号与会员二级页的会员栏与「我的」页会员/签到重复 | 会员是「我的」页资产, 二级页又放一份 | 删二级页「会员」分组(+ 去 `onOpenVip` 参数), 页面标题改「账号管理」 |
| 3 | 已登录时想加第二个账号, 跳转 Web 立刻返回 | WebView 的 cookie 仓库里还留着上一个账号的 `MUSIC_U` ⇒ 登录页判定"已登录"原地结束 | `MainActivity` 打开登录页前 + `LoginActivity.onCreate` 各清一次 WebView cookie(账号簿在 Rust 侧, 不受影响) |
| 4 | 登录 Web 页无法返回 | 官方登录页是 SPA, 页内 history 很深, 系统返回键只会一页页退网页; 没有可见的关闭入口 | `LoginActivity` 加顶栏「关闭」, 系统返回键直接 `finishCancelled()`(放弃登录并把 cookie 交回) |
| 5 | 退出账号后账号簿里的行点不动, 只能重新扫码 | 行 `onTap: account.active ? null : ...` —— 未登录时"上次登录的账号"正好是 active 行 | 只在"已登录 + 当前账号"时禁用; 切号成功(`onSwitchAccount` 改为返回 bool)就地翻转成已登录态 |
| 6 | 热搜关键词的关闭按钮与右边 ❌ 功能重复 | 「收起」+ ❌ 两枚控件做同一件事 | 只留一个按钮: 关闭 = 收起 + 落盘, 再点开启; 删 ❌ |
| 7 | 清除凭据弹窗文案「出二手可用」不知所云; 安卓 KeyStore 加密说明应在设置 | 文案带场景推销; 凭据后端状态放在账号页隐私栏 | 文案改为「退出登录并删除本机保存的全部账号凭据, 之后需要重新登录」; 「凭据存储」行搬到 **设置 → 关于**(`_CredentialStorageTile`) |
| 8 | **回归**: 风格推荐每个方框都是占位符 | `style_list` / `style_preference` 的 `picUrl` 是 `yyimgs/<hash>/<id>` **相对路径**, 过去一律 `filter(starts_with("http"))` 丢弃 | 新增 `parse::image_url`: 相对路径补成 `https://p1.music.126.net/<hash>/<id>.jpg`(实测 200 image/jpg), 绝对地址原样保留 |

回归用例: `profile_banner_test`(身份卡底部 = 卡片底部)、`account_page_privacy_test`(未登录点账号即登录 / 凭据行已搬走)、
`hot_search_toggle_test`(只剩一个开关、无 ❌)、`ui_batch_c_ia_test`(设置页账号入口 / 账号页无会员栏)、
`ncm-service` 的 `style_preference_mapping`(相对图解析成 CDN 绝对地址)。

## 2026-11-13(二): 用户反馈 10 项 UI 收口 + 艺人/用户主页统一(v0.8.0)

用户一次性提了 10 条 UI 反馈。除了直接改, 还先派了三路**只读分析**(布局栅格 / 跑马灯+逐字歌词 /
主页结构), 因为若干问题看起来是调样式, 实际是口径或测量 bug。

### 真 bug, 不是观感问题

| 现象 | 根因 |
|---|---|
| "明明放得下却还在滚" | `MarqueeText._measure` 只拿 `widget.style`, **没合并 `DefaultTextStyle`** —— AppBar 标题不传 style(继承 20sp), 测量却按 TextPainter 默认 14sp, 宽度偏小 ~30%: 既误判"放得下"(ellipsis 截断, 该滚不滚), 也算短 distance(滚一小段就到头) |
| 跑马灯左右双向晃 | `TweenSequence` 第 4 段是 `Tween(distance→0)` 反向回滚 |
| 行尾按钮"缩了却没变窄" | `IconButton` 默认 `tapTargetSize.padded` 把命中区强行撑到 48x48, **覆盖 constraints.minWidth** |
| 艺人背景像马赛克 | 横幅传 `width: double.infinity, height: 170` → `imageCandidates` 丢掉非有限宽 → 实际只请求 `param=170y170` 方图, 再放大 6 倍铺满 1080x510;而且 `NetImage` **从未接清晰度档位** |
| 逐字歌词一字一字亮 | `wordStylesAt` 早就算出每词 `progress`, 但渲染只读 `state`;同时位置只有 120ms 一次采样(300ms 的词只有 2~3 个台阶) |
| 「查看全部」与标题不在同一水平线 | `_SectionHeader` 有 **三份私有副本**, 两份用 `CrossAxisAlignment.end` + 40dp TextButton |
| 歌单/专辑/艺人长名字不滚动 | 全仓只有 4 处用跑马灯, 其余一律 `maxLines:1 ellipsis` |

### 落地(按反馈编号)

1. **VIP/付费/无版权标**从"歌手之前"移到**歌名之后**, 与推荐/歌单/队列统一(`SongTitleWithBadges`)。
2. 行尾「喜欢」+「…」宽度 48→**40dp**(高度仍 48), 两枚合计 96→80dp。
3. 每日推荐全页去掉行尾「不感兴趣」(同一动作在「…」菜单), 整条 `onDislike` 注入链一并删除。
4. 歌词页 AppBar 标题 22sp→显式 **20sp + height 1.25**(22sp 默认行高下中文歌名下半段被工具条裁掉)。
5. **跑马灯内核重写**: 测量与渲染共用 `DefaultTextStyle.merge(style)`;溢出死区 8px;动画 key 改用内容 hash
   (原先 `identityHashCode(String)` 会在父级重建时每帧变 → 反复从 0 重播);单向循环(尾部停 1s 瞬跳回起点);
   `AnimatedBuilder` 的 child 提到 builder 外 + `RepaintBoundary`(原先**每帧重排整段 paragraph**)。
   再做**统一迁移**: 新增 `AdaptiveText(mode: ellipsis|marquee|wrap)`, A 类 30 处开滚动、B 类 2 处多行、
   C 类(副标题/时长/创建者/播放条)明确不动;徽标口径改成"标题可用宽 = 行宽 − 实测Σ徽标宽"。
6. **逐字歌词字内进度**: `KaraokeLine` + `CustomPainter`(两份 TextPainter 共用几何 + `getBoxesForSelection` +
   双层裁剪 + 8px 渐变软边), 行内 `Ticker` 本地插值到 60fps(只刷 repaint notifier, 不 setState);
   活动行字号 18→15 与静态行统一, 消除换行重排抖动。
7. 动态行去掉用户名后的「单曲/动态」标记(不提供额外信息)。
8. **背景图**: 新增 `neteaseSizedUrl`(矩形 param)/`bannerRequestPx`(档位内核算子, 上限 1080)/
   `sizedImageCandidates`;新增 `ProfileBanner`(高清图 + 右上角全屏药丸 + 点击进 `showImageViewer` 保存**原图**) +
   `ProfileIdentity`(身份卡上浮 12px 移出图外, 不再压图)。360dp@3x: 省流 540y330 / 标准 720y440 / 超清 1080y660。
9. **艺人/用户主页统一**: 共用 `ProfileScaffold`(SliverAppBar + 身份卡 + 统计 chip + 声明式 tab);
   用户页从"只有 1 个歌单分区"变成 歌单(横滑卡片, 标题 2 行)+ 关注 + 粉丝 三个 tab, 空分区不渲染;
   艺人页原有 6 分区与动态 tab 规则不变。数据面新增 `Playlist.subscribed` / `userPlayRanking(uid)` /
   `userEvents(uid)` 三个 FFI(实测: 他人听歌排行匿名态恒空;`event/get` 匿名 301 需登录;
   `/api/user/playlist` 的 `subscribed` 恒 null ⇒ 该端点只能表达"创建", 拆创建/收藏需换 `playlist_detail`)。
10. **横向留白栅格**: `layout.dart` 建常量(kPagePadding 12 / kCardRowInset 4 / kSongRowPadding / kCardMargin / kSectionGap),
    唯一 `SectionHeader` 取代三份副本;我的页实测距屏 消息中心 64→48、我喜欢/最近听过 76→60、听歌排行 100→88,
    资料卡绘制面 24/276→12/288, 标题与「查看全部」中心线差 12dp→**0**。

### 这一轮挖出来、但不属于 10 条的三个额外缺陷(都已修)

- `ranking_view.dart` 表头 Row 在 300dp×1.625 下**溢出 9.5px** —— 它一直在首屏外, 加了"高视口"用例后才暴露;
  `SegmentedButton` 改 `Flexible + FittedBox(scaleDown)`。
- mine_view 三处写死 `SizedBox(height:176)` → `CoverRow`(1.625 字号下原本纵向溢出 5px)。
- `artist_sections` 专辑卡片固定 160 高同样在 1.625 下溢出 4px → 按 `textScaler` 算高。

### 过程纪律

所有车道都在独立 `git worktree` 里跑, **编排者独立重跑全量门禁后才合并**(不采信 worker 自报);
每轮合并后再跑一遍。合并时处理了 4 处冲突(mine_view / artist_page / profile_header / user_page_test),
原则是"取重构后的结构 + 保住语义"。格式门还当场抓住我自己的失误(手插一行超宽, CI format 报红)。

## 2026-11-13: 结构性债务第 1 波(门禁 + 两个大文件拆分)

**先说门禁**:仓库此前没有格式门也没有 clippy 门,`cargo fmt --check` 有 368 处差异、
`dart format` 会重排 143 文件。本轮先做纯格式提交,再把三道门加进 CI(本地 / GitHub / USTC 三处同口径),
之后任何改动都必须过 `cargo fmt --check` · `cargo clippy -D warnings` · `dart format --set-exit-if-changed`。

- **纯格式提交**:`cargo fmt --all` + `dart format lib test`;顺带补 3 处折行后触发 `curly_braces` 的花括号(不改语义)。
- **CI 门**:`.github/workflows/ci.yml` / `.gitlab-ci.yml` / `tools/ci.sh` 三处同步;CI 实测 Rust 与 Flutter 两个 job 全绿。

**UI 状态件统一(`state_views.dart`)**:`CircularProgressIndicator` 48 处 / 26 文件 → 5 处 / 1 文件;
页面级 `LoadingView` 34 处、按钮/行尾 `LoadingView.inline` 14 处、`EmptyView` 25 处 / 15 文件;
空态文案一字未改;15 处裸 `ListView.builder` 只加 `// 非分页: <理由>`(私信 reverse 锚底、固定条数榜单、
嵌在详情页滚动体内等),不强改结构;`search_loading.dart` 收敛成 `LoadingView` 薄封装。新增 5 例测试(含 18dp 矮槽位 overflow 回归)。

**`netease.rs` 按能力域拆分**:8110 行单文件 → `netease/{mod,provider,parse,song,search,community,vip,playlist,radio,account,comment,artist,album,lyric}.rs`
(最大 1038 行);`provider.rs` 保留唯一的 `impl Provider`(116 个方法各一行转发到各域固有方法,零逻辑);
111 个 `#[test]` 按域拆 9 个文件。**核验方式**:拆分前后函数名单各 371 个完全一致(无丢无增)、`#[test]` 111=111、
`cargo test` 271 不变、`api-coverage` 123/123。

**唯一一处源码 grep 断言加固**:`marquee_long_title_test` 原来用 `indexOf(...)` 之间的 substring 读源码
(上次 CI RangeError 的根因),改成「正则锚点 + 窗口 + 断言前剥行注释」;负向验证:把 `titleLarge` 改成
`titleMedium` 后该测试立刻失败,还原即绿。

> 两个车道都在独立 worktree 里跑,编排者独立重跑全量门禁后才合并(不采信 worker 自报)。
> 剩余债务(能力 trait / AppSettings)见 `docs/remaining-batches.md` §12;
> 未做的平台层审计项(P-11 完整版 / P-18 后半 / P-10 方案 B)见同文件 §13
> (P-05 长尾 / P-12 / P-22 已于 2026-11-16 落地, §13 已标「作废」)。

## 历史批次(≤2026-11-12)与专题小节

> 2026-11-12 及更早的按日批次记录, 以及按主题沉淀的专题小节(歌词打分/自动更新/arm64 CI/Keystore 通道层等),
> 已于 2026-11-15 迁出本文件: [`archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> 这里只保留 v0.8.0 起的活跃时间线; 结论层仍在 `.pi/memory/*.md`, 不要再往本文件追加"专题小节"。
