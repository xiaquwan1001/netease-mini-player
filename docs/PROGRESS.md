# 进度记录(Progress)

> 最近更新: **2026-11-15(六)**。当前版本 **v0.12.3**(冷启动落在推荐 + 历史日推合并本地缓存)。
> 面向新读者的速览在下一节; 按日期的批次记录从「批次时间线」起倒序(最新在上)。
> 下一轮做什么: [`docs/remaining-batches.md`](remaining-batches.md) **§11**;文档总索引: [`docs/README.md`](README.md);
> 架构决策: [`docs/archive/architecture-restart.md`](archive/architecture-restart.md);
> 历史批次:v1(WebView 版) → [`docs/archive/PROGRESS-v1.md`](archive/PROGRESS-v1.md),
> 2026-11-03~11-12 批次与专题小节 → [`docs/archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> **本文件只保留 v0.8.0 起的活跃时间线**(2026-11-15 精简: 1656 行 → 517 行); 更早批次已归档。

## 进度总览(2026-11-15 复核)

**当前门禁**(本机实测, 离线口径; **权威口径只在本表**, README/README.en/remaining-batches 都是指针):

| 门 | 结果 |
|---|---|
| `cargo test --offline --workspace --exclude ncm-api-rs` | **287** 通过 / 0 失败(排除 vendor 联网 smoke) |
| `cargo clippy --workspace --all-targets -- -D warnings` | **0 warning** |
| `cargo fmt --all -- --check` | 干净 |
| `flutter test`(全量, 含 golden) | **947** 通过 / 1 跳过(golden 12 张) |
| `dart format --set-exit-if-changed lib test` | 干净 |
| `dart analyze` | **0 issue**(error / warning / info 全清) |
| `tools/check-write-guard.sh` | OK(测试不触网/不直连写接口) |
| `tools/check-tokens.sh --strict` | **OK**(间距/圆角/字号 0 越界, 例外必须写 `// token-ok: 理由`) |
| 接口覆盖 | **136/136**(FFI 导出 160, 其中 6 个无 UI 入口: cache_stats / cloud_song_url / consent_plaintext_storage / eq_profile_normalize / player_tuning / user_play_ranking) |

凭据落盘 0600 文件骨架 + 系统钥匙串(Android Keystore / Linux secret-service / Windows DPAPI)。

**版本时间线**:

| 版本 | 日期 | 里程碑 |
|---|---|---|
| v0.1.0 | 2026-11-08 | 首个公开预览版(Android APK + Linux tar.gz, MIT LICENSE, 第三方许可盘点) |
| v0.1.1 / v0.2.x | 2026-11-09~10 | 窄屏修复 + 正式签名/版本号纪律;设置项扩充 R1–R7、UI/UX 走查批 A–C、**Windows 桌面版合入**、v0.2.2 三端发布 |
| v0.3.x | 2026-11-10~11 | 桌面打包(deb/AppImage/setup.exe)、歌单写接口、图片清晰度三档、**v0.3.2 六种资产发布**;v0.3.3 修 Ubuntu 22.04 GLib 基线 |
| **v0.3.4** | **2026-11-11** | **手机号+短信验证码登录(网页通道)**、动态评论写入改 eapi(修 404)、评论区对话化、动态流行内赞·评论·分享、发表后回填定位;Release 6 种资产 |
| **v0.3.5** | **2026-11-11** | **技术债 D 批收敛**(弹层 21/21 统一、格式化去重、podcast 658→190 行、45 文件窄屏回归归零) + Windows 向导中文化 + 写接口静态门禁 `tools/check-write-guard.sh` |
| **v0.4.0** | **2026-11-11** | 播放条常驻二级页 + 风格推荐配图窗格 + Linux **arm64** 原生 CI 腿 |
| **v0.5.0 / v0.5.1 / v0.5.2** | 2026-11-11~12 | 主题色切换(五 seed)+ 播放条数据层重构;v0.5.1 重发修 arm64 CI;v0.5.2 红色改 M3 fidelity 策略 |
| **v0.5.3 / v0.5.4** | 2026-11-12 | 凭据调研 + 桌面冒烟脚本 + CI apt 重试;凭据地基(FileStore 0600 + 同意门 + 明文迁移 + DPAPI P0) + 凭据不再过 FFI 回 Dart。**两者 CI 未出全套产物, 由 v0.5.5 取代** |
| **v0.5.5** | **2026-11-12** | 凭据后端三端落地(Android Keystore / Linux secret-service / Windows DPAPI) + USTC GitLab CI build 阶段;Release 6+2 分发物(含 arm64) + SHA256SUMS |
| **v0.6.0** | **2026-11-12** | 排行榜移到搜索落地页、我的收藏歌单/播客/专辑二级页、我的页区块 keepAlive、歌曲行留白收紧、搜索加载占位 |
| **v0.6.1** | **2026-11-12** | 自动更新频率(off/daily/weekly/monthly)+ 启动发现新版本弹窗、全站横向留白统一、代码审计整改(CoverCard/CoverRow 合并、死参数删除、分页代际守卫) |
| **v0.7.0** | **2026-11-12** | 播放条重排(播放顺序归位/队列入口移到行尾/删除详情页底部控制条)、歌单内搜索播放策略(全列表/追加队列)、艺人跳转、对齐与低优先审计收口 |
| **v0.7.1** | **2026-11-12** | 用户反馈 10 项:VIP 标记/播放条上一首/歌词截断/长字滚动/队列叠加/搜索横向分类/艺人主页分区/缩进收口 |
| **v0.8.0** | **2026-11-13** | 用户反馈 10 项 UI 收口(徽标位置/行尾按钮/每日推荐/歌词标题字号/跑马灯内核重写+全仓统一/逐字字内进度/动态标记/背景高清+全屏保存/横向留白栅格) + **艺人/用户主页统一骨架** + 数据面 3 个 FFI(`Playlist.subscribed` / `userPlayRanking` / `userEvents`) |
| **v0.8.1** | **2026-11-13** | 用户反馈 8 项: 账号入口收敛到设置(删「我的」页药丸/未登录按钮/底部多余横条)、账号页去会员重复栏、登录 WebView 清 cookie(可加第二个账号)+ 顶栏关闭(可返回)、退出后账号簿可点即登录、热搜单一开关(删 ❌)、清除凭据文案去歧义、Keystore 说明搬到设置→关于、**风格推荐配图修复**(yyimgs 相对路径补 CDN 绝对地址) |
| **v0.9.0** | **2026-11-13** | **规则层收口**(唯一 `AsyncView` / `SectionTitle` / `check-tokens --strict`) + 用户 6 条(播放跳过 VIP / 每日推荐歌单本地缓存 / 凭据存储去重 / 匿名 debug 数据 / 关注页头像进主页且与搜索同一份排版 / 「歌手」→「艺人」) + **匿名诊断一键提交**(Cloudflare Worker 代理建 issue) + **我的页按最近交互排序** + 列表行 A 级 7 处修复 + **golden 视觉回归网**(6 页 × 2 视口) |
| **v0.10.0** | **2026-11-14** | 用户 15 项反馈(OLED 开关/我的页同构/动态分享卡片/转发面板/forbidden 文案/云盘列表/通知按钮顺序/网格列数/相似艺人横排/MV 搜索+评论区/动态游标补历史/等级 0/艺人页纵向 tab/联想面板/边缘留白) + 编辑简介 + 云盘上传 |
| **v0.11.0** | **2026-11-14** | 用户第二轮 15 项 + API 语义纠偏:艺人页粉丝数与整卡宽统计行、播放全部顶格、共 N 首/搜索移入全部歌曲 tab、**登录假成功修复**、提示条 floating 3s、简介并入昵称下、**他人/艺人动态端点修复**(`/api/event/get/<uid>` + 绑定 userId)、去关注粉丝 tab、「我喜欢」单独成栏、电台→播客文案、仅分享歌曲不重复附图、图片按张数排版;新增 2 个 vendor 端点 |
| **v0.12.0** | **2026-11-14** | 用户第三轮 16 项:分类 tab 对齐根因修复(居中缩进/checkmark 变宽)、联想改分类 tab + 关注艺人加权排序 + 封面补齐、键盘弹出导航栏让位、动态统一转发面板 + 评论选中态 + 评论卡片语境/计数 + 他人动态自动展示媒体、**字号落盘原子化**(根治"重启回默认")+ 精细滑块、关注行/作者栏点法统一、我的动态并入我的主页、一排/两排覆盖更多横滑;新增 **正在播放高亮**(全局 nowPlayingSongId) |
| **v0.12.1** | **2026-11-14** | 分类条末尾空缺(均分 4+3 两排)、字号档位 chip 删除(只留滑块)、`docs/` 根 13 份完工专题归档 + 索引重写 |
| **v0.12.2** | **2026-11-14** | 分类条回退为**单横排 + 横向拖拽**(不再做换行/均分几何) + 分类顺序按日用频率(歌曲→艺人→专辑→MV→播客→歌单→用户) |
| **v0.12.3** | **2026-11-15** | 冷启动默认落「推荐」tab(不再被恢复的播放现场顶到"正在播放"列表) + 每日推荐歌单本地缓存在「历史日推」里合并去重 + 「本地」标记 |

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
> 剩余债务(能力 trait / main 拆壳 / AppSettings)见 `docs/remaining-batches.md` §12。

## 历史批次(≤2026-11-12)与专题小节

> 2026-11-12 及更早的按日批次记录, 以及按主题沉淀的专题小节(歌词打分/自动更新/arm64 CI/Keystore 通道层等),
> 已于 2026-11-15 迁出本文件: [`archive/PROGRESS-2026-11-03-11-12.md`](archive/PROGRESS-2026-11-03-11-12.md)。
> 这里只保留 v0.8.0 起的活跃时间线; 结论层仍在 `.pi/memory/*.md`, 不要再往本文件追加"专题小节"。
