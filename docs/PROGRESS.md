# 进度记录(Progress)

> 最近更新: **2026-11-14(五)**。当前版本 **v0.12.1**(2026-11-14 打包, 分类条末尾空缺修复 + 字号档位精简 + docs 归档收敛)。
> 面向新读者的速览在下一节; 按日期的批次记录从「批次时间线」起倒序(最新在上)。
> 下一轮做什么: [`docs/remaining-batches.md`](remaining-batches.md) **§11**;文档总索引: [`docs/README.md`](README.md);
> 架构决策: [`docs/archive/architecture-restart.md`](archive/architecture-restart.md);v1(WebView 版)历史已移入 [`docs/archive/PROGRESS-v1.md`](archive/PROGRESS-v1.md)。

## 进度总览(2026-11-14 核实)

**当前门禁**(本机实测, 离线口径):

| 门 | 结果 |
|---|---|
| `cargo test --offline --workspace` | **284** 通过 / 0 失败(排除 vendor 联网 smoke) |
| `cargo clippy --workspace --all-targets -- -D warnings` | **0 warning** |
| `cargo fmt --all -- --check` | 干净 |
| `flutter test`(全量, 含 golden) | **940** 通过 / 1 跳过(golden 12 张) |
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
| **v0.9.0** | **2026-11-13** | **规则层收口**(唯一 `AsyncView` / `SectionTitle` / `check-tokens --strict`) + 用户 6 条(播放跳过 VIP / 每日推荐歌单本地缓存 / 凭据存储去重 / 匿名 debug 数据 / 关注页头像进主页且与搜索同一份排版 / 「歌手」→「艺人」) + **匿名诊断一键提交**(Cloudflare Worker 代理建 issue) + **我的页按最近交互排序** + 列表行 A 级 7 处修复 + **golden 视觉回归网**(6 页 × 2 视口) || **v0.9.0** | **2026-11-13** | **规则层收口**(唯一 `AsyncView` / `SectionTitle` / `check-tokens --strict`) + 用户 6 条(播放跳过 VIP / 每日推荐歌单本地缓存 / 凭据存储去重 / 匿名 debug 数据 / 关注页头像进主页且与搜索同一份排版 / 「歌手」→「艺人」) + **匿名诊断一键提交**(Cloudflare Worker 代理建 issue) + **我的页按最近交互排序** + 列表行 A 级 7 处修复 + **golden 视觉回归网**(6 页 × 2 视口) |
| **v0.10.0** | **2026-11-14** | 用户 15 项反馈(OLED 开关/我的页同构/动态分享卡片/转发面板/forbidden 文案/云盘列表/通知按钮顺序/网格列数/相似艺人横排/MV 搜索+评论区/动态游标补历史/等级 0/艺人页纵向 tab/联想面板/边缘留白) + 编辑简介 + 云盘上传 |
| **v0.11.0** | **2026-11-14** | 用户第二轮 15 项 + API 语义纠偏:艺人页粉丝数与整卡宽统计行、播放全部顶格、共 N 首/搜索移入全部歌曲 tab、**登录假成功修复**、提示条 floating 3s、简介并入昵称下、**他人/艺人动态端点修复**(`/api/event/get/<uid>` + 绑定 userId)、去关注粉丝 tab、「我喜欢」单独成栏、电台→播客文案、仅分享歌曲不重复附图、图片按张数排版;新增 2 个 vendor 端点 |
| **v0.12.0** | **2026-11-14** | 用户第三轮 16 项:分类 tab 对齐根因修复(居中缩进/checkmark 变宽)、联想改分类 tab + 关注艺人加权排序 + 封面补齐、键盘弹出导航栏让位、动态统一转发面板 + 评论选中态 + 评论卡片语境/计数 + 他人动态自动展示媒体、**字号落盘原子化**(根治"重启回默认")+ 精细滑块、关注行/作者栏点法统一、我的动态并入我的主页、一排/两排覆盖更多横滑;新增 **正在播放高亮**(全局 nowPlayingSongId) |

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

## 2026-11-14(五) 用户第四轮两条反馈 + 文档收敛(**v0.12.1 已发布**)

> 发布记录(2026-11-14 23:30 核实): tag `v0.12.1`(versionCode 30)双推 GitHub + USTC GitLab;
> GitHub Actions **Release #43609028858 全绿 14m46s / CI #43609028874 全绿 9m26s**, Release 9 资产
> (android-arm64 apk 29.6 MB / linux-x64 tar.gz 15.7 MB / linux-arm64 tar.gz 15.5 MB / x86_64.AppImage 15.2 MB /
> deb amd64 11.5 MB / deb arm64 10.6 MB / windows-x64.zip 17.5 MB / windows-x64-setup.exe 14.0 MB / SHA256SUMS);
> USTC GitLab **#9390 全绿**(rust / flutter / build-linux-x64 / build-android-arm64 / build-android-debug)。
> 待人工验证: 真机装 0.12.1 看分类条两排是否都贴满右边距、设置页字号只剩滑块。

- **分类条末尾的空缺**: 用户截图里「胶囊分类条最后一排右边空一块」——`Wrap` 按 chip 自然宽度左对齐换行,
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
- 门禁: `dart analyze` 0 issue · `flutter test` **941 通过 / 1 跳过**(golden `settings_360x800` 按新版重出) ·
  `dart format --set-exit-if-changed` 干净 · `check-tokens.sh --strict` OK。

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


## 2026-11-12(晚): v0.6.0 → v0.7.1 四连发(用户回归驱动)

一晚连发四个版本, 全部 GitHub Release 全绿(8 资产 + SHA256SUMS), 另 USTC GitLab tag pipeline 同步通过。

- **v0.6.0**(18:21): 排行榜移到搜索落地页(`chart_section.dart`);我的收藏歌单/播客/专辑加「查看全部」二级页
  (`my_collections_page.dart`);我的页区块 keepAlive(滚出视野不再重载, 下拉刷新按 generation 换代);
  SongTile 留白 16+16→8+4 且搜索结果满宽;搜索中显示 `SearchLoading` 占位。
- **v0.6.1**: 自动更新频率枚举 `UpdateCheckInterval`(off/daily/weekly/monthly, 默认 daily) + 启动发现新版本
  由主界面 pendingPrompt 弹窗(`update_dialog.dart`, 与设置页手动检查共用弹窗);横向留白统一
  (settings/mine `ListTileTheme contentPadding=12`、歌曲行 `layout.dart:kSongRowPadding`);审计整改:
  `cover_row.dart` 合并三份 CoverCard/CoverRow、删 `RecommendView.loadCharts` 死参数、PagedListView/comment_thread
  加代际守卫防刷新后旧分页拼入(报告: `docs/audits/2026-11-12-*.md`)。
- **v0.7.0**: 播放条重排(Slider 2dp、播放顺序归位含心动档、队列入口移到行尾、详情页底部控制条整条删除、
  模式切换反馈改顶部浮层);歌单内搜索播放策略 `AppSettings.librarySearchPlayAction`(fullList/appendCurrent);
  专辑详情艺人可点、动态/评论头像 → 用户主页;低优先审计收口(radio 听众页 PagedListView、SnackBar→showToast、
  TabController 延帧 dispose、formatOneDecimal 合并、推荐页歌曲卡满宽、听歌排行 8/4、我的页 12 栅格)。
- **v0.7.1**: 用户反馈 10 项(VIP 标记/播放条上一首/歌词截断/长字滚动/队列叠加/搜索横向分类/艺人主页分区/缩进收口)。
- **踩坑(已写进 CODE 断言)**: `marquee_long_title_test` 曾用写死缩进的源码 substring 定位控件, 被 `dart format`
  重排后 CI 抛 RangeError ⇒ 源码 grep 类断言必须用正则, 且跑过 format 后必须重跑全量。
- **门禁**: 本轮收尾实测 `cargo test` 271 / `flutter test --exclude-tags network` 674 / `dart analyze` 0e0w / clippy 0 warning。

## 2026-11-12(下午): 凭据三端验证收口 + 主题色提亮

- **Android Keystore 模拟器实测通过**: a34(x86_64) debug 包(须 `--target-platform android-x64`)登录测试小号后
  `run-as` 见 `files/cred/{account_*.bin, session.bin}` 均为**密文 0600**; 期间修掉 Gradle 缓存 kotlin-reflect jar
  损坏(ClassFormatError Illegal UTF8)导致的 debug 构建失败(删 `~/.gradle/caches/modules-2` 的 kotlin-reflect 即愈)。
- **Linux secret-service**: D-Bus 探针 set/get/delete OK; AppImage xvfb 启动渲染正常; 用户真机登录 + 颜色验收通过。
- **Windows dpapi 单测接进 CI**: windows.yml 加 `cargo test -p ncm-service dpapi`, dispatch run 43173625885 success(首次真编真测)。
- **主题色五 seed 提亮**(用户"整体偏暗淡的棕色"反馈): 旧 seed 是 Material 600/700/800 深色调, 换 500 级高饱和并拉开
  色相 —— 绿 16A34A / 蓝 2196F3 / 橘 FF9100(红 F40000 / 粉 E5007E 不变); theme_accent_test 8/8, 用户视觉验收通过。
- Release v0.5.5 补正文; 资产/Latest 指向此前已正确, 应用内更新检查走 /releases/latest 不需改。

## 2026-11-12: 凭据地基合入 + 凭据不再过 FFI + apt 兜底按架构选源

- **凭据存储地基(lane L1)合入**: `ncm-service/src/credential_store.rs`(trait/`FileStore` 0600+同意门/
  `CredentialPolicy`/`CredentialStatus`/Windows DPAPI P0)、`IdentityStore` 接入(会话与账号凭据入 store,
  落盘文件只留骨架)、旧明文一次性迁移(best-effort, 失败保留明文不阻塞)。合并前修了一个**自锁死**:
  `migrate_legacy_cleartext` 在整段迁移里持有 `self.creds` 锁又调 `load_accounts()` 拿同一把非重入 Mutex,
  门禁复现为测试挂死(`futex_do_wait`);改为只克隆 `Arc`。
- **凭据不再回传 Dart**(决策点 4 执行): `QrLoginCheck`/`PhoneLoginResult` 去 `cookie` 换 `logged_in`,
  凭据改走内部 `QrLoginOutcome`/`PhoneLoginOutcome`(provider → service → ffi 之间流动, FFI 落盘后丢弃);
  新增 FFI `credential_status()` / `consent_plaintext_storage(bool)`。codegen 三步已跑,Dart fixture 同步。
- **CI apt 兜底修**: arm64 runner 的归档在 `ubuntu-ports`(之前给 `/ubuntu` ⇒ `Unable to locate package`),
  且兜底源生效后 apt 仍会挑 runner 自带 azure 源下载 ⇒ 改为一律 `-o Dir::Etc::sourcelist=<兜底>` 只信兜底源。
- 门禁: `cargo test --workspace --exclude ncm-api-rs` **237 passed** / `flutter test --exclude-tags network` **642** /
  `dart analyze` 0 error 0 warning(38 info, 与 main 基线一致) / write-guard OK / `cargo build -p ncm_ffi` OK。

## 2026-11-11(六): 写接口静态门禁(§11.C1 收尾)

评论发送是**真实写操作**, 发版走查要求「CI 不触网」。仓库的做法一直是把写接口全部
经注入的假钩子(CommentSendHook / SongActionHost / likeEvent 参数…) 换成假实现, 但这条
**只靠自觉**。本轮把它变成可执行的门禁:

- 新增 `tools/check-write-guard.sh`: 扫 `ui/test/**`, 一旦出现对写接口
  (`replyComment/deleteComment/likeComment/likeEvent/forwardEvent/forwardMessage/
  shareResource/createPlaylist/playlistTracksAdd/reportComment/signin/logout`) 的**直连**调用就失败;
  另外 `@Tags(['network'])` 的测试也不允许调写接口。读类接口不拦(离线 mock / network 白名单)。
- 已接进 3 处: `.github/workflows/ci.yml` 的 flutter job、`release.yml` 的 verify job、`tools/ci.sh`。
- 现状: 脚本对当前仓库 **0 命中**(评论/点赞/转发/分享/歌单写确实全在注入钩子里), 属于"防回归"型门禁。

这样 §11.C1「评论发送写操作走查(发布前硬门)」的两半都齐了: 人工一侧由用户真机实测覆盖
发送/失败/回滚(v0.3.4 前完成), 机器一侧由本门禁保证 CI/发版流水线不去写线上数据。

## 2026-11-11(五): 技术债 D 批收敛(6 路并行 + 主会话收口)

按 `docs/remaining-batches.md` §11.B2 派了 6 个子代理并行, 每个只碰自己那份文件; 全量门禁由主会话统一跑。

| 项 | 开工前实测 | 结果 | 证据 |
|---|---|---|---|
| **底部弹层统一** | 21 处 `showModalBottomSheet`, 仅 4 处用 `SheetHeader` | 21/21 全部 `showDragHandle: true` + `SheetHeader`; `SheetHeader` 扩出 `subtitle/leading/trailing`(旧调用方零改动) | `ui/test/song_actions_test.dart` 等 15 文件 +90 例 |
| **时长/日期格式化去重** | 8 处各写一份 | 收敛进 `lib/src/format.dart`(新增 `formatDurationShort` m:ss / `formatDateYmd`); `song_tile` 的定长口径保留同名导出并委托共享实现 | `ui/test/format_test.dart` +5 例 |
| **podcast.dart 半死入口** | 658 行, `showPodcastSheet`+`_PodcastBrowser*` ≈88 行零生产调用 | **658 → 190 行**; 生产链路(`showPodcastDetail`→`ProgramDetailSheet`)未动; 两个测试改直测存活组件 | `podcast_test` 256→77 行 · `program_detail_test` 206→154 行 |
| **窄屏 + 1.25 字号回归** | 43 个渲染型测试文件缺这条 | 本轮补 **45 个文件**(3 个子代理 + 主会话收口 10 个), 渲染型测试缺口归零(剩余的 `adaptive_text_row_page_test` 本身就是 300/320/360 × 1.0/1.25/1.625 审计) | 逐文件新增用例; 详见 `.pi/artifacts/debt-narrow-*.md` |
| **Windows 安装向导中文化** | 只有内置英文(缺 `ChineseSimplified.isl`, v0.3.1 因此挂过) | 随包 `packaging/windows/ChineseSimplified.isl`(21.5 KB, is-7_1_1 官方内置版) + `[Languages]` 双语言; CI 加兜底拷贝(choco innosetup 仍 6.7.1 不自带) | `packaging/windows/README.md` 记来源/许可; .iss 引用静态核查通过(本机无 ISCC, 真验证待 CI) |
| **deb 依赖闭包** | 未验证 | 见上一节: 68 个外部库 100% 被现 Depends 覆盖 | ldd→dpkg→闭包比对 |

**顺手修掉的真缺陷(都是补窄屏回归时才暴露的)**:
1. `lib/src/settings_audio_page.dart`: 「目标电平」`DropdownButton` 的 trailing 在 300dp+1.25 下触发框架断言
   *Trailing widget consumes the entire tile width* → `ConstrainedBox(maxWidth:124)` + `isDense` + **`isExpanded`**
   (缺 `isExpanded` 时选中项拿到松约束、ellipsis 不生效, 反而任意宽度溢出 94px —— 这一版先踩再修)。
2. `lib/src/play_queue_sheet.dart`: 统一表头后标题变两行, 矮视口纵向溢出 2px → 队列面板改单行标题
   (计数移到 trailing), `narrow_width_audit_test` 12 组组合恢复全绿。

门禁: `cargo test --offline --workspace` **254** · `flutter test --exclude-tags network` **617**(+46) ·
`dart analyze` **0 error / 0 warning(38 info, 比开工前少 4 条)**。

## 2026-11-11(四): deb 依赖闭包核查(无容器环境下的替代验证)

§11.C3「deb 依赖收紧/最小系统验证」本机没有 docker/podman(拉镜像也不现实), 改用**依赖闭包静态核查**,
结论可量化且可复跑:

| 项 | 方法 | 结果 |
|---|---|---|
| 二进制真实需要的共享库 | 解包 `dist/minincm_0.3.2_amd64.deb` 后对 `minincm` 与 `lib/libncm_ffi.so` 做 `ldd`, 取并集 | **70** 个(含 bundle 自带 2 个: `libflutter_linux_gtk.so`/`libncm_ffi.so`) |
| 每个库的提供者 | `dpkg -S /lib/x86_64-linux-gnu/<lib>`(排除 `*-cross` 误判) | 68 个外部库全部映射到具体 deb, 无 UNKNOWN |
| 声明依赖是否够 | 从 `Depends` 根包出发按 `PreDepends/Depends` 做 BFS 求传递闭包(`LC_ALL=C apt-cache depends`, 137 个包) | **68/68 全被覆盖**, 缺口 0 |
| Ubuntu 24.04 命名 | `apt-cache show` 查 Provides | 声明的 `libgtk-3-0`/`libasound2` 在 24.04 由 **`libgtk-3-0t64`/`libasound2t64` Provides**, 装机不会因改名失败; 22.04 仍是原名 |

脚本与中间产物: `/tmp/debchk/{analyze.sh,closure3.sh,final.sh}`(一次性验证, 不入库)。
判据说明: 闭包覆盖 = 最小系统上 apt 装得齐所有 `.so` 的直接依赖; 但**运行期数据文件**(字体、
GStreamer 插件等)不在 Depends 语义内, 仍需一台真最小桌面环境点开跑一次(本轮未做)。

## v2 · 2026-11-11(三): 楼层预览 · 动态流行内操作 · 发表后回填定位

三条都是用户真机反馈的使用摩擦, 落点全在 UI 层(无新 FFI):

| 需求 | 做法 | 证据 |
|---|---|---|
| 回复默认折叠, 每次都要点开 | 顶层评论行内**直接预览**前 K 条回复: K = `replyCount>=3 ? 2 : 1`, 候选按点赞降序稳定排序; 每个父评论只拉 1 页(limit 4)、并发上限 2、失败静默; 单独给「展开全部 N 条回复」入口(不依赖预览成功); **「回复」按钮改成直接写回复与展开拆开** | `ui/test/comment_reply_preview_test.dart` 8 例 |
| 动态流只有数量标识, 每次都要进详情 | 卡片操作行可点化: **点赞**(乐观翻转 + 失败回滚 + snackbar)、**评论**(进详情并定位到评论区, 不自动弹输入框; 详情页 `ListView`→`SingleChildScrollView` 以便视口外锚点可定位)、**分享**(面板: 转发动态 / 复制链接) | `ui/test/feed_row_actions_test.dart` 8 例 |
| 发评论后不刷新: 头像空白、昵称「我」, 且不聚焦到新评论 | 发表成功后**静默重取第一页**(不显示整页 loading, 失败保留乐观项不打成错误页), 用服务端的真实昵称/头像/时间替换乐观项, 并把这条**滚进视野 + 高亮 1.8s**; 服务端偶尔还没带回新评论时保留乐观项(不让它凭空消失) | `ui/test/comment_post_refresh_test.dart` 2 例(回填替换 / 静默失败保留) |

门禁: `flutter test --exclude-tags network` **571**(+21) · `dart analyze` 0 error / 0 warning(42 info) · `cargo test --offline --workspace` 254。

**同日晚补一条(真机反馈"回复混合新旧两种情况")**: 动态评论接口会把**一部分回复直接放在顶层列表**返回
(带 `parentCommentId` + `beReplied`), 于是同一屏里既有被收进楼层的、也有"裸的单独成条"的。
新增 `_absorbOrphanReplies()`: 按 parentId 把这类回复从顶层摘掉、塞进所属楼层的行内预览(主评论不在本页时
保留在顶层并显示「回复 @某人」, 不静默丢弃); 「展开全部 N 条回复」的 N 改取 max(服务端计数, 本地条数),
因为接口有时 replyCount=0 却仍返回回复。

**行内预览形态再改一版(同日, 用户反馈「总是显示展开一条评论」)**: 旧规则是 K = replyCount>=3 ? 2 : 1,
导致 1 条回复也顶着「展开全部 1 条回复」。现在: 行内**最多缩进展示 3 条**(小头像 + 左侧竖线缩进,
有被回复者时带「回复 @某人」); **回复 ≤3 条全部展示、不出展开按钮**; 超过 3 条才给「展开全部 N 条回复」,
且 N = max(服务端 replyCount, 本地条数)。`ui/test/comment_orphan_reply_test.dart` 增至 5 例(含 >3 条的分支)。

> 顺手记一笔环境坑: 本轮 `cargo test` 一次链接失败 `rust-lld: error: invalid symbol index`(增量对象损坏),
> `cargo clean -p ncm_ffi` 后一次通过 —— 不要为此清整个 `core/target`(会删掉 12 GB 且重编很久)。

## v2 · 2026-11-11(二): 评论区两处修复(真机反馈)

用户真机反馈两个真 bug, 根因都不是"界面不好看":

| 现象 | 根因 | 落点 | 证据 |
|---|---|---|---|
| 动态详情底部的「评论」按钮一点就**退出页面**, 不进输入模式 | `feed_detail_page.dart` 里写成了 `onPressed: () => Navigator.pop()`(把"回到评论区"误当导航) | `CommentThreadState` 公开 + `CommentThread.focusComposer()`(滚到评论区 + 打开写评论面板, 面板 TextField 自带 autofocus); 详情页改用 `GlobalKey<CommentThreadState>` 调它, 无评论区的动态保持禁用 | `ui/test/feed_detail_comment_entry_test.dart` 3 例(不 pop / 聚焦 / 禁用态 + 300dp·1.25 不溢出) |
| 回复**不被归属到主评论**, 在下方像独立评论 | `parse_comment` 只取了 content/赞/楼层数, 把楼层接口里的 `parentCommentId` 与 `beReplied[0].user.nickname` 丢了 | domain `Comment` 新增 `replied_to`/`parent_id`; 解析补全; 列表行与楼层列表都展示「回复 @某人」 | `ncm-service` 单测 `comment_reply_attribution`(有归属/顶层/空昵称三种); `ui/test/comment_attribution_test.dart` 3 例 |

FFI 未加函数(只是 `Comment` 镜像 +2 字段, codegen 重生成)。门禁: `cargo test --offline --workspace` **254**(+1) ·
`flutter test --exclude-tags network` **550**(+6) · `dart analyze` 0 error / 0 warning(42 info)。

> **待确认**: 写侧仍是 weapi `/api/v1/resource/comments/reply`(api-enhanced 新版走 xeapi v3、旧版 eapi v2)。
> 服务端是否**忽略 commentId 把回复当顶层评论**还没实测 —— 需要一次真实回复写操作 + 读回楼层对比;
> 读数侧已能区分(嵌套的回复只出现在楼层里, 顶层列表不会有它)。

## v2 · 2026-11-11: 手机号 + 短信验证码登录(网页登录通道)

扫码登录之外的第二条官方路径。**关键判断: 只做网页登录族(weapi), 不碰 App 原生登录族(eapi)** ——
后者在交互式风控下稳定回 8821, 前者与扫码同族、已知可走。

| 项 | 落点 | 证据 |
|---|---|---|
| 数据面 | `Provider::login_sms_send`(weapi `/api/sms/captcha/sent`) + `login_sms_verify`(`/api/login/cellphone`); 新 domain `SmsCodeSent{code,message,expires_in}` / `PhoneLoginResult{cookie,nickname,avatar_url}` | 凭据与扫码 803 一致**只在 Set-Cookie**, body 只有 account/profile; 缺 `MUSIC_U` 直接报 Internal 不"假成功" |
| 错误归类 | 新增 `check_body_with(body, map)` + `map_login_code`: 400(号码/验证码不合法)→`Auth` 不可重试, 503(发码太频繁)→`Internal` **可重试**, 8821 仍走全局 →`RiskControl` | 宿主实测非法号码 `ncm login-sms 1000000`: `code=400: 手机号码不符合规范`(通道可达、错误映射生效) |
| 输入规范化 | `normalize_phone`: 容忍空白/连字符/括号/`+`, 区号缺省 86, 号码 6–15 位、区号 1–4 位, 非法直接 `Auth` | `normalize_phone_accepts_common_input` |
| 登录弹层(UI) | `login_sheet.dart` 第 2 个 tab「手机号登录」: 区号+号码、获取验证码(按服务端 `expires_in` 冷却, 下限 60s)、填码登录; 命中 8821 时**显式提示改用扫码**; 切到该 tab 后停止二维码轮询(`_tab != 0` 短路) | `ui/test/login_sheet_phone_test.dart` 4 例(发码→冷却→登录成功关弹层/风控引导/空输入不打接口/切 tab 停轮询) |
| CLI | `ncm login-sms <手机号> [验证码] [--country 86]`: 不带验证码时先发码再读 stdin, 成功后 `apply_login_cookie` 落盘 | `--help` 头注释 + 宿主烟测 |

FFI: `loginSmsSend`/`loginSmsVerify`(144→**146**)。

错误文案: 桥侧的 `[auth|riskControl|...] detail` 经 `friendlyLoginError` 换成人话(只换标签、
保留「发送验证码失败:」这类动作前缀与服务端原文, Dart 的 `Exception:` 去掉); 弹层里风控引导仍按原始
`_error` 判定, 不受文案影响。`ui/test/login_sheet_error_test.dart` 4 例。门禁: `cargo test --offline --workspace` **253**(+4) ·
`flutter test --exclude-tags network` **544**(+8) · `dart analyze` 0 error / 0 warning(41 info) · 接口覆盖 123/123。

> **待真机验**: 需要用户用真实手机号收一条短信走完 8821 之外的正常链路(本机只能验到通道可达与错误映射);
> 桌面/安卓共用同一份 Rust 链路, 弹层同源, 三端行为一致。

## v2 · 2026-11-10(六): 他人主页路由(听众/粉丝 → 用户页) · 发布包体积实测

| 项 | 落点 | 证据 |
|---|---|---|
| **他人主页** | 新 `ui/lib/src/user_page.dart`: 资料卡(背景/头像/昵称/签名/关注·粉丝·等级) + 「TA 的歌单」列表, 点歌单进已有歌单详情页(带播放回调). 数据面新增 `Provider::user_profile`(user/detail) 与 `Provider::user_playlists_of`(user/playlist) —— 都**不需要登录**, 与只读当前账号的 `profile_detail` 分开; FFI `userProfile`/`userPlaylistsOf`(142→**144**) | `ncm user <uid>` 宿主实测(匿名): 下去玩 uid=1822714196 → 关注 44/粉丝 11/公开歌单 12 个, 与网页端一致 |
| 路由接通 | `radio_subscribers_page` 的听众行、`user_list_page` 的粉丝/关注行都能点进主页(`onOpenUser` 仍可覆盖); 播放回调从 `_PodcastDetailPage`/`main._openFollows` 一路带下去, 否则"点进主页点歌单不能播" | `ui/test/user_page_test.dart` 4 例(资料+歌单渲染/空态/失败重试/无播放回调只提示) |
| 发布包体积实测(§11 B4) | `docs/archive/backend-service-options.md` **附录 B**: 六种产物的下载体积 vs 首装体积 + 40 MB bundle 的逐文件拆解 | deb 11 MB→40 MB 安装; AppImage 14.6 MB; bundle 里 `libncm_ffi.so` **15 MB 未 strip**, strip 后 9 MB(本轮只测不改) |

门禁: `cargo test --offline --workspace` **249** · `flutter test --exclude-tags network` **536**(+4) · `dart analyze` 0 error / 0 warning · 接口覆盖 123/123, FFI **144**。

**已明确不改**: Rust cdylib strip(省 6 MB/产物)会丢 release 崩溃栈符号, 暂不动; Flutter 引擎 19 MB 是"一份 UI 三端"的代价。

## v2 · 2026-11-10(五): 桌面端官方扫码登录 · deb 门面元数据 · 账号隐私修复

三个用户报的真问题, 一个文档整理批。**根因都不是"界面不好看", 而是缺一层能力/元数据。**

| 问题 | 根因 | 落点 | 证据 |
|---|---|---|---|
| **桌面端点「登录」没法唤起官方网页登录**, 只能 `ncm login-cookie` 粘 cookie | 桌面没有 Android 那套 WebView + `CookieManager`, 读不到浏览器里 **HttpOnly** 的 `MUSIC_U`; 旧代码 `Auth.loginWeb()` 在非 Android 直接抛 `UnsupportedError`, 命令行成了唯一入口 | 走**官方网页登录的扫码通道**(与"原生登录族/8821"无关): 新增 `Provider::login_qr_create/login_qr_check` → `/api/login/qrcode/unikey`(weapi, type=1) 取 unikey, 二维码内容 `https://music.163.com/login?codekey=<unikey>`, 轮询 `/api/login/qrcode/client/login`; **803 的凭据在 Set-Cookie 不在 body**。FFI `loginQrCreate/loginQrCheck`(142), Dart 新弹层 `login_sheet.dart`(二维码 + 状态 + 刷新 + 导入 Cookie + 打开官方登录页), `main.dart::_login` 桌面分支改走它, 账号页未登录也给出「登录」按钮 | `ncm login-qr` 宿主实测: 拿到 unikey、轮询回 `801 Pending`(无 8821); Rust 单测 `qr_login_check_states_and_cookie`(800/801/802/803/400 + 803 缺 MUSIC_U 必须报错); widget 测试 6 例(状态机/过期停轮询/导入成功/无 MUSIC_U/空输入/申请失败重试) |
| **下载的 deb 预览显示 `minincm` 且没有图标**, 装完才变成「轻音 MiniNCM」+图标 | 包里只有 `.desktop`(安装后才被读), **缺 AppStream 元数据**; 文件管理器/软件中心预览非安装态包时读的就是它 | 新增 `packaging/linux/io.github.xiaquwan1001.MiniNCM.metainfo.xml`(中文名/英文名/summary/描述/launchable/icon/categories/releases) 与 `/usr/share/pixmaps/minincm.png` 兜底; `.desktop` 补 `Name[zh_CN]`/`Comment[en]`/`Keywords[zh_CN]`; AppImage 也带上同一份 metainfo | `appstreamcli validate --no-net` **通过**(只剩 3 条 info); `dpkg-deb -c` 可见 metainfo+pixmaps+hicolor; 包重打后 11 MB |
| **没登录的空账号占位显示成上次登录的昵称 + VIP 标**(疑隐私泄露) | 账号页把账号簿(accounts.json)里的缓存**无脑当当前账号渲染**: 头部 VIP 标只看 `active` 不看登录态; 另有一份过期登录态(cookie 字符串还在但服务端已失效)会一直显示"已登录 + 缓存昵称/VIP" | ① 未登录时头部/账号簿**一律不显示 VIP 标**, 行内文案改成「上次登录的账号(当前未登录)」; ② 桌面/移动都给出「清除本机登录凭据」(退出 + 删每个账号的 `MUSIC_U`, 二次确认, 保留 device_id); ③ 启动时 `accountSyncActive` 兼作登录态校验: **只有服务端明确回 `[auth]` 才清登录态**, 网络/风控失败不动 | `ui/test/account_page_privacy_test.dart` 4 例(未登录零 VIP 标/已登录 2 个/空账号簿无清除入口/清除需二次确认); 迁移前本地 `accounts.json` 实测确为明文 `MUSIC_U`(0600) |

**文档整理批**(子代理, 未改代码): `docs/README.md` 新建文档索引(活跃/归档)、`docs/PROGRESS.md` 加「进度总览」、
README/README.en 门面重排(三端口径 + 功能分组 + Releases 下载表 + 英文版过时门禁 170/351 订正为 249/532);
GitHub 仓库 description 改为三端口径、topics 补 `windows`/`desktop`/`third-party-client`(共 10 个)。
报告见 `docs/DOCS-REPORT-2026-11-10.md`。

门禁(编排者独立重跑): `cargo test --offline --workspace` **249 通过 / 0 失败**(vendor 4 例匿名联网 smoke 需清空代理变量才绿, 与 ci.sh 口径一致) ·
`flutter test --exclude-tags network` **532 通过 / 0 失败**(+10) · `dart analyze` **0 error / 0 warning**(42 info) ·
`flutter build linux --release` 通过 · `tools/api-coverage.sh` vendor **123/123**, FFI **142**。

**未做/留给下一轮**: 真机/模拟器上的扫码确认(需用户拿手机扫一次)、Windows 端同一条链路的冒烟(本机编不了)、
`ncm login-qr` 之外的 `login_qr_check` 803 端到端(等真实扫码)。

## v2 · 2026-11-10(四): 封面清晰度按设备分辨率取图 + 档位可调 + 看大图保存原图

| 项 | 落点 | 证据 |
|---|---|---|
| 缩略图按**真实像素**请求 | 之前直接把逻辑尺寸当像素数(44dp 的封面向 CDN 要 44px 的图, 在 2~3 倍 DPR 的手机上被放大显示 ⇒ 肉眼可见的糊)。新增 `coverRequestPx(context, logicalSize)` = 显示尺寸 × 设备像素比 × 档位倍数, 下限 60 / 上限 1600; `CoverArt` 用它算 `?param=NxN` | `ui/test/cover_quality_test.dart`: dpr 1/2/3/2.75 与三档的像素断言(44dp@3x = 132px) |
| 清晰度档位(设置项) | `AppSettings.coverQuality` = `CoverQuality{dataSaver 0.75x / standard 1.0x(默认) / ultra 2.0x}`, 持久化到 `settings.json` 的 `coverQuality`; 设置 → 通用 → 「封面与图片清晰度」打开选择面板, **三档各带一张同一张图、不同请求像素的真实预览**(能直接看出差别), 选完立即生效 | 面板三档文案 + 点「超清」写设置并关面板; 持久化读回用例 |
| 改动只通知图片 | 档位用独立的 `ValueNotifier<CoverQuality>`, 不让"音量滑块拖动"这类高频 `notifyListeners()` 把上百个封面全部重建 | `CoverArt` 的 `AnimatedBuilder` 监听该 notifier |
| 看大图**保存原图** | 全屏看图(动态配图/专辑封面)改 `_ImageViewer`: 双指缩放 + 左右翻页 + 序号 + 关闭; 右上角「保存原图」下载 **CDN 原图字节**(不是屏幕上的缩略图)后落盘 —— Android 走 `ncm/share` 的 MediaStore(`Pictures/MiniNCM`), Linux/Windows 落 `~/Pictures/MiniNCM` | 用例: 取图 URL 升级 https / 存的是原图字节 / 文件名带扩展名 / 失败 toast 不崩 |
| 解耦 | 保存字节抽到新文件 `image_io.dart`(`saveImageBytes`), `song_share.dart` 改为委托它 —— 否则 `cover_art.dart`(要看大图保存)与 `song_share.dart`(已 import cover_art)会成环 | `dart analyze` 0 error / 0 warning |

门禁: `flutter test --exclude-tags network` **510 → 522**(+12 例; 其中 2 例是**组件级**断言 —— 44dp@3x 真正请求 `param=132y132`, 切超清后同一封面变 `param=264y264`),
`dart analyze` 0 error / 0 warning(41 info)。
模拟器(emulator-5554)实测: 设置 →「封面与图片清晰度」三档面板可开、选「超清」后 `files/ncm/settings.json` 落盘 `"coverQuality":"ultra"`、设置项副标题同步。

## v2 · 2026-11-10(三): 歌单写接口 + 队列「存为歌单」 · v0.2.2 三端发布

| 项 | 落点 | 证据 |
|---|---|---|
| 歌单写接口(provider) | `create_playlist(name, privacy)` 补 `privacy`(0 公开 / 10 私密); 新增 **批量** `playlist_tracks_add(playlist_id, &[u64])`(vendor `/playlist/manipulate/tracks` 原生支持多 id), 默认实现 `unsupported`, 能力键沿用 `PlaylistEdit` | `ncm-service` **+6** parse 单测(`parse_created_playlist` / `parse_playlist_edit_result`, 用真实响应片段) |
| 响应形状(实测) | `create`: id 在顶层, `playlist.id` 冗余兜底; `tracks add`: `{"code":200,"count":N,"trackIds":"[1,2]"}` —— **trackIds 是字符串**不是数组, `count` = 服务端接受数(重复曲目跳过); 失败 `{"code":500,"msg":...}` | `docs/b7-playlist-write-notes.md` |
| FFI + codegen | `createPlaylist(name, privacy)` / `playlistTracksAdd(playlistId, songIds)`; frb 把 `Vec<u64>` 映射成 frb 自带 **`Uint64List`**(不是 `dart:typed_data`) | FFI 导出 139→**140** |
| UI | `PlayQueueSheet` 头部「存为歌单」(`playlist_add`, 空队列不渲染), 快照**按 id 去重**后经 `onSaveAsPlaylist` 回调交宿主(面板仍可脱机单测); 宿主 `_saveQueueAsPlaylist` = 选「新建歌单」(默认名「来自播放队列 M-D HH:mm」)或我的歌单列表 → 批量加入 → toast; 未登录先提示 | `ui/test/queue_sheet_save_test.dart` **+6** 例(空队列无按钮/出现/回调快照/去重/防重复点击/失败不崩) |
| 模拟器实测(emulator-5554) | 队列 2 首 → 「存为歌单」→ 新建 → **服务端复核**: 歌单「来自播放队列 11-10 11:52」出现在我的歌单且正好 2 首(After Hours / Hong Kong); 选已有歌单重复添加幂等(仍 2 首); logcat 0 崩溃 | 截图 `.pi/artifacts/b7/01..05*.png`; `ncm-cli playlists` 复核 |
| 实测发现并修 | `myPlaylists` 网络失败原先被**静默吞掉**(面板一片空白) → 补 try/catch + toast | — |
| 协议坑(入笔记) | 抓包时遇到「`code=500` 但服务端半成功入库」—— 写接口不能只看 code, 要回头查 `user/playlist` 确认, 否则会留下孤儿歌单; 本次两处孤儿已 `playlist_delete` 清掉 | `docs/b7-playlist-write-notes.md` |

门禁(本批实测, 编排者独立重跑): `cargo test --offline --workspace` **248 通过 / 0 失败**(不含 vendor 联网 smoke 时 224) ·
`dart analyze` **0 error / 0 warning**(41 info) · `flutter test --exclude-tags network` **510 通过 / 0 失败** ·
`tools/api-coverage.sh` vendor **123/123**, FFI **140**, 无 UI 入口 4。

### v0.2.2 发布(三端)

- `release.yml` 重构: 新增 `build-windows` job(`windows-latest` 上 `flutter build windows --release` → `MiniNCM-<ver>-windows-x64.zip`),
  原来的 Android/Linux job 只上传 artifact, 新增 `publish` job 统一 `download-artifact` + 算 `SHA256SUMS` + 创建 Release
  ⇒ 消除两个 job 并发抢建 Release 的竞态, 且 checksum 覆盖三端; `overwrite_files: true` 支持重跑同一 tag。
- 已发布 **v0.2.2**: `MiniNCM-0.2.2-android-arm64.apk`(28.5 MB) / `MiniNCM-0.2.2-linux-x64.tar.gz`(15.0 MB) /
  **`MiniNCM-0.2.2-windows-x64.zip`(17.0 MB)** / `SHA256SUMS.txt`; tag 上 Release 流水线 4 个 job(verify / Android+Linux / Windows / publish)全绿。
- 文档同步: README 与 README.en 改为三端描述(副标题/徽章/架构图/构建说明/进度表/门禁表), 项目 AGENTS.md 与
  `docs/archive/architecture-restart.md`、`docs/testing-dual-platform.md` 补 Windows 口径(本机 Linux 编不了 Windows, 只能靠 CI + 用户机器冒烟)。

## v2 · 2026-11-10(续): 队列面板拖拽排序/清空 · .git 损坏修复 · 门禁复核

| 项 | 落点 | 证据 |
|---|---|---|
| 播放队列拖拽排序(B2②) | `play_queue_sheet.dart` 由 `ListView` 换成 `ReorderableListView` + 行尾 `ReorderableDragStartListener` 拖拽手柄(`buildDefaultDragHandles:false`, 整行长按仍留给"移除"); 行的 key 换成与 items 平行的稳定 key 列表(同一首歌可在队列里出现多次, 且下标会随排序变化); 宿主 `main.dart::_moveInQueue` → `PlayQueue.moveTo`(纯逻辑早已就绪) | `ui/test/queue_sheet_test.dart` 新增 1 例: 把第一首拖到队尾 ⇒ 顺序变、当前曲目不变(`index` 2→0)、**不触发换歌**; 文件内 9 例全绿 |
| 播放队列「清空」(B2④) | 面板头部 `delete_sweep_outlined` + 二次确认对话框(`共 N 首, 清空后当前播放会停止`); 宿主 `_clearQueue` 清 `PlayQueue` 并走既有的 `_stopAfterQueueEmpty`(停播 + toast) | 2 例: 确认后队列空/停播/空态文案; 取消则一首不少 |
| 「存为歌单」⛔ 未做 | FFI 里**没有任何歌单写接口**(`rg 'playlist_create|tracks_add|playlist_edit' core/crates/ncm-ffi/src/api.rs` = 0), 要做需新开 Rust 车道(codegen) + 真实登录态写验证 | 阻塞原因记在 `docs/remaining-batches.md` §10 B2 行 |
| 顺带修掉上一提交的告警 | `ui/test/update_checker_test.dart` 未使用的 `toast.dart` import ⇒ `dart analyze` 由 1 warning 回 0 | `dart analyze` 0 error / 0 warning |
| `.git` 对象库损坏修复 | `main` 指向的提交(927b929)连同 64 个 loose object 一起变成 0 字节, `git status/log` 全挂 `bad object HEAD`; 同时工作树里 `ui/windows/**` 等 24 个文件被清零。用索引重建 blob(先删空对象文件, 否则 `hash-object -w`/`write-tree` **静默跳过**)→ `write-tree` → `commit-tree -p 7eab656` → `update-ref`; 工作树用 `git checkout --` 从索引还原 | 索引里 25 个缺失 blob 的 sha 与工作树 `git hash-object` **逐条相符**(内容无损), 重建提交 `8a3f9a2`; `git fsck --connectivity-only` 仅剩悬空 commit; 备份在 `~/netease-mini-player-git-bak-20261110` |

门禁(独立子代理复核, 报告 `.pi/artifacts/gates-2026-11-10.md` + 原始日志 `.pi/artifacts/logs/`):

| 命令 | 结果 |
|---|---|
| `cargo test --offline --workspace` | **242 通过 / 0 失败**(含 vendor 4 例联网 smoke, 校园网直连网易域名可达, 真 PASS 非 WARN) |
| `dart analyze` | **0 error / 0 warning**(41 info 风格提示) |
| `flutter test --exclude-tags network` | **504 通过 / 0 失败 / 0 skip** |

`flutter` 工具链顺带更新的两个生成/配置文件(`ui/analysis_options.yaml` 排除 `windows/**`、`ui/windows/flutter/generated_plugins.cmake` 补 `rust_lib_minincm` FFI 注册)一并提交。

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

调研: [`docs/archive/research-2026-11-10-lyric-and-color.md`](archive/research-2026-11-10-lyric-and-color.md) —— SPlayer-Next/lyric-dom(AGPL, 只借鉴思路)、node-vibrant(MIT, 算法可移植)、Mei(ljyh223, Apache-2.0)、逐字歌词实现对照。

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

用户三条要求一次落地, 详见 `docs/archive/ui-song-detail-share.md`:

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
FFI 车道: `docs/archive/d7-frb-domain.md`(车道已关闭)。

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

### 5. ~~剩余(仅真机听感验收)~~ → ✅ 2026-11-10 真机全部通过

> 用户 2026-11-10 在真机上把下列 5 条听感项全部走查通过(MV 播放也在真机验过)。原清单保留作验收口径:

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
| 新候选 `netease-music` 0.1.1 | ⛔ spike 结论: 暂不切 | src **2,448 行**, 依赖 **132 包**(↓81), 搜索/歌词与现实现**完全一致**, Android 交叉编译配 NDK 即过; 但取链匿名态两端都被风控(ncm 404 / crate -460)、**身份每进程随机需自建回灌层**、appver 形态更粗、43/118 封装落差 ⇒ 净收益仅「少 2.4k 行加解密」。门槛与复测清单见 `docs/archive/backend-service-options.md` §6 |
| **P1+P2 裁剪** | ✅ 已做(2026-11-09) | vendor endpoint **382→118**(未接入 **0**, 100%)、LOC **12,035→4,069**(−66%)、体积 1.7 M→564 K、`api/mod.rs` 566→252 行; `tokio` 从 vendor 直接依赖**整体移除**(库本体不用), 死特性 `server`(axum/bin/5 个可选依赖)一并删除; 依赖数 **213/279/257 → 207/274/252**; 冷编 vendor **1.40→0.65 s**; release `.so` 14,246,736→**14,157,856**(strip 8,971,728→**8,918,104**); 门禁: `--all-targets` 0 error + **119** 测试全绿 + coverage 118/0。详见 `docs/archive/backend-prune.md` |
| 收益排序 | 📄 结论 | 打包配置(release + split-per-abi, 231 MB→约 30–40 MB/ABI) > Rust 依赖瘦身(~~P1 裁 vendor / P2 tokio~~ ✅已完成) > 方案 c |

详细数据与测量命令: `docs/archive/backend-service-options.md` §5–§6。

### 附带: API/实现重叠审计(只读, `docs/archive/api-overlap-audit.md`)

| 结论 | 证据 |
|---|---|
| 代码已高度去重 | 语义重叠多为"同名不同义", provider 已用 `comments(kind)`/`by_area` 等 enum 合并; **无重复 friendlyError**(错误映射集中在 `netease.rs:329` `map_error/map_code/check_body/take_body`, 全文件仅 5 处直接构造 `ProviderErrorKind::*`); **无 >200 行函数**(最大 `parse_feed_events` 120 行, 318 个函数中 191 个 <20 行); **Capability 实为 35 个**(`ncm-provider/src/lib.rs:30`), 之前口头引用的 47 是 `Capability::` 出现次数不是枚举项数 |
| 口径脚本 bug 已修 | `tools/api-coverage.sh` 的 camel 匹配大小写敏感 ⇒ `lyric_lines_i18n`(`lyricLinesI18N`, 大写 N, `main.dart:875` 在用)被误报; 已改小写化比对, 真实**死导出 = 2**(`search` `api.rs:160` / `lyric_lines` `api.rs:607`, UI 调用均为 0) |
| 可精简收益 | 保守 ~430–670 行(FFI 死导出 + Dart 样板 + 文档); 激进 D7(frb 直接透传 domain DTO, 删 74 个 Dto ≈646 行 + 内联转换 ~400 行)可达 ~1400–1800 行, 但需给 domain 加 frb 注解 + 双端全量回归, **排在 vendor 裁剪之后另开车道** |
| 无应删写接口 | follow/like/playlist_edit/comment_delete/reply/sign_in 全部有 UI 入口且在用 |

### 附带: UI/UX 走查(只读, `docs/archive/ui-ux-audit.md` 506 行)

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
| **C** 信息架构重排 | ✅ | 设置瘦身为 3 组 + 2 个二级页(`settings_account_page`/`settings_diagnostics_page`); 账号入口 **3→1**(统一到「我的」, 未登录显示引导); 推荐页首屏 **8→5 区块**(合并日推歌曲+歌单/新歌+新碟, 风格推荐下沉榜单 chips); 专辑详情 **Dialog→全页**、日推/最近听过 **sheet→全页**; 新增 11 条可达性用例, 6 处断言随结构调整改写(0 删除); 视觉待人工过目清单见 `docs/archive/ui-batch-c.md` §7 |
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
| 后端形态调研 | 📄 | `docs/archive/backend-service-options.md`: 结论 **不换形态、只裁剪** —— vendor 12,035 LOC/382 endpoint 我们只用 118(31%),但 vendor 边际依赖为 **0**(213-crate 服务树差集为空)、单独重编译仅 1.3s ⇒ 不是编译/依赖瓶颈;延迟 search 中位 0.39s、detail 0.14s;体积大头是 reqwest/tokio/rustls 网络栈,换方案也省不掉 |
| 回归 | ✅ | Rust service **102** 单测(收尾 +6, 游标改动后全绿); Flutter **231** 用例; `tools/ci.sh` → **CI OK**; a36 独立走查: 节目榜页签/节目播放/听众列表真实数据 |

**协议/实测事实**:
- `album_newest` 响应 `{code, albums[12]}`,专辑对象与 `album_new` 同构;无 total、无分页。
- `toplist_detail_v2` 响应 `{code, data:[{categoryCode, list:[{id,name,coverUrl,updateFrequency,targetType:"PLAYLIST",canPlay}]}]}`,
  分组顺序 TOPPING/OFFICIAL/FEATURE/MUSIC_STYLE/GLOBAL/LANGUAGE/MORE;个别条目 `id=0` 且 `canPlay=false`。
- `comment_mv`/`comment_video` 与歌曲评论同形, 只有 thread 前缀不同; video 的测试 id 可能 200+空。
- `dj_subscriber` 的 `time` 参数是**上一页最后一条 subscribeTime(ms)**, 首页传 -1。
- 详细样例见 `docs/wave9-endpoint-notes.md`; 后端形态测算见 `docs/archive/backend-service-options.md`。

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
| S5 | 通道 spike(interface vs interface3) | ✅ | 两条都通, 保持库默认; 见 `docs/archive/api-channel.md` |
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


## 专题小节(按主题, 非时间序)

> 接口/凭据/CI/主题等按主题沉淀的细节小节, 不属于时间序批次记录。
> 新增批次请写进上面的倒序时间线, 不要追加到文件末尾。

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


## 自动更新检查(2026-11)

启动/手动检查 GitHub Releases(`xiaquwan1001/netease-mini-player` 的 latest release)是否有新版本, 并引导下载。

- 纯 Dart 无新依赖: `ui/lib/src/update_checker.dart`。
  - `compareVersions(a,b)` 逐段数字比较, 支持 `v` 前缀、`+N` build 段、semver 预发布规则; 非法输入返回 0 不抛。
  - `checkForUpdate`: 请求 latest API(Accept `application/vnd.github+json`, 8s 超时), 按平台选资产(android ⇒ `-android-*.apk`, linux ⇒ `-linux-*.tar.gz`), 无匹配资产回退 `html_url`; 任何错误(网络/404/坏 JSON/超时)返回 null 不抛。
  - `checkForUpdate` 可注入 `client`/`apiBase`/`fetch`/`preferAndroid`; **测试全走假 HttpClient/假 fetcher, 绝不真联网**。
  - 本地验证: 把 `apiBase` 指到本地假 JSON(如 `python3 -m http.server` 起一个 release JSON, 传 `apiBase: 'http://127.0.0.1:8000/latest.json'`)即可离线复现解析与资产选择; 测试已覆盖同样路径。
- UI: 设置 →「关于」新增「检查更新」项(检查中 loading; 有新版本弹窗: 版本号 + notes 前 200 字 + 「前往下载」走 `PlatformBridge.openUrl` + 「稍后」; 无新版 toast「已是最新版本」); 启动静默检查发现新版本只在「检查更新」项上点亮红点, 不弹窗。
- 设置: `updateCheckOnStartup` 开关(默认开); `AppSettings` 落盘 `lastUpdateCheckMs`(24h 节流)与 `skippedUpdateVersion`(点「稍后」跳过的版本, 启动检查不再提示)。
- main.dart 仅在 `_bootstrap` 后追加一行 `unawaited(runStartupUpdateCheck(AppSettings.instance))`(首帧后 3s 后台检查)。
- 测试: `ui/test/update_checker_test.dart` 25 例(版本比较/资产选择/错误路径/假 HttpClient/节流与跳过/关于项 UI)。

## C3 — MV 播放(2026-11-09)

- vendor: 恢复 `mv_detail.rs` / `mv_url.rs`(git show 5cfc301^), mod.rs 重新注册。
- Rust: `MvDetail`/`MvUrl` DTO; provider trait 默认 unsupported + netease 实现(`parse_mv_detail`/`parse_mv_url`, 7 个 parse 单测用真实响应形状); FFI `mvDetail`/`mvUrl`; frb codegen 一次。
- 接口实测(`ncm raw`, 见 docs/c3-mv-playback-notes.md): mv_url data 是单对象, 签名直链 expi=3600s, http/https 都通, 请求 1080 实回 r=480(按实际档位返回)。
- UI: 新增 `mv_page.dart`(封面+标题/歌手/播放量/发布时间/最高清晰度/简介 + 播放按钮, FutureBuilder 错误态可重试) + `mv_playback.dart`(MvPlayback: Android 走 `ncm/mv` MethodChannel, 桌面走 openUrl 外链并明示无内嵌播放; 直链 http→https); artist_page MV 卡片 onTap 接 showMvPage(仅接线)。
- Android: 新增 `MvPlayerActivity.kt`(独立 VideoView + MediaController, 刻意不进 Media3 歌曲队列; 16:9 居中适配, keep screen on, onPause/onDestroy stopPlayback, 解析失败可读 toast), MainActivity 注册 `ncm/mv` play, Manifest 注册 Activity(Theme.Material.NoActionBar)。
- 模拟器实测(emulator-5554, x64 debug 包): 搜索→歌手信息→MV tab→点 MV→播放: NuPlayer state=started(video/avc + audio/mp4a-latm), 双截图帧变化, 暂停/返回键回 MV 详情页, logcat 0 FATAL, 退出后无残留解码器。截图 .pi/artifacts/c3/。
- 测试: test/mv_page_test.dart 6 例(详情渲染/加载失败重试/无链接错误态/播放调用+https 转换/桌面外链分支/取链异常错误态)。门禁: cargo test 46+31+1+140 全绿; dart analyze 0 error/warning(41 info 均在他人文件); flutter test --exclude-tags network 501 全绿; build-android.sh OK。
- 注: settings_view.dart 曾有另一车道的空安全编译错误挡构建, 已做最小 `info!.latest` 修复(仅此一行)。

## UI: 播放条常驻(2026-11-11 二)

用户反馈: 推荐 → 每日推荐「全部」等二级页一压上来, 底部的歌曲播放条就没了。
要求是"除了打字上屏(键盘)时被挡, 播放条任何时候都该在"。

- 结构: 播放条与底部导航从 `HomePage.bottomNavigationBar` 上移到根布局
  `PlayerBarHost`(`MaterialApp.builder` 内, 渲染在 Navigator **之下**的 Column 兄弟位),
  因此任何压在首页上的路由(日推全部/歌单广场/风格详情/搜索页…)都能看到它;
  是"占位"不是"覆盖": 二级页自己的底部面板/滚动区都落在它上方, 弹层也不会被它压住。
- 播放条本身抽成 `_MiniPlayerBar`(纯展示 + 回调), 状态/队列仍在 `_HomePageState`
  (只有一份); 每次 HomePage 构建后**帧后**把底部条投递到 `playerBarSlot`
  (同步写会在 build 阶段 markNeedsBuild 祖先)。
- 壳里自带一个全屏 Overlay: 播放条的 Slider/Tooltip 用 OverlayPortal 画气泡, 必须有
  Overlay 祖先, 而它又在 Navigator 之外。条目内容用 ValueNotifier 更新(否则卡在旧 Navigator)。
- 让位规则: 键盘弹出(`viewInsets.bottom > 0`)时整条不占位; 底部 tab 只在首页处于栈顶时
  出现 —— 用 `_PageDepthObserver` 数"非弹层路由"层数(用 ModalRoute.isCurrent 会让
  弹一个底部面板就丢掉导航栏)。二级页上点曲名: 先 popUntil 回首页再展开歌词。
- 测试: `ui/test/player_bar_host_test.dart` 3 例(二级路由压上来/弹出仍在、键盘弹出让位、
  无曲目不占位); `top_bar_no_duplicate_test`/`ui_batch_a_back_nav_test` 的 HomePage 宿主
  改成同一个 `PlayerBarHost` 壳(否则 NavigationBar 不再出现)。

## UI: 风格推荐直接显示配图窗格(2026-11-11 二)

用户反馈: 推荐 → 风格推荐原本只有关键词 chips, 配图要点进风格详情才看得到, 要求把配图
窗格上移到推荐页直接可见。

- `_StyleChips`(ActionChip + 钢琴图标) → `_StyleTiles`: 一行横滑的「配图 + 名字」窗格
  (88dp, 与详情页头部同一张 `tag.coverUrl`), 点开仍进 `showStyleDetail`; 无名配图时退回
  同尺寸钢琴图标占位。位置语义不变(仍在排行榜区块内、榜单之后)。
- 数据侧确认: 登录态 `/api/tag/my/preference/get` 的 `tagPreferenceVos[].picUrl` 是**绝对地址**
  (实测 5 个曲风全有图); 未登录走 `style_list`, picUrl 是 `yyimgs/...` 相对路径,
  Rust 侧本来就丢掉了 → 匿名用户看到的是图标占位(与改动前一致)。
- 测试: `ui/test/style_tiles_test.dart` 2 例(有配图渲染 CoverArt / 无配图退回图标; 300dp+1.625 不溢出)。

## CI: Linux arm64(2026-11-11 二)

- 现实约束: **Flutter 桌面不支持交叉编译** ⇒ arm64 只能在 arm64 runner 上原生构建。
- `ci.yml` 的 `build-linux` 改成 matrix(`ubuntu-24.04`/x64 + `ubuntu-24.04-arm`/arm64),
  产物名 `linux-debug-bundle-<arch>`。
- `release.yml` 新增 `build-linux-arm64` job: 原生构建 → `file` 校验 aarch64 + GLib 符号基线 →
  出 `MiniNCM-<ver>-linux-arm64.tar.gz` + `minincm_<ver>_arm64.deb`; publish 的 needs 带上它。
  arm64 暂不出 AppImage(appimagetool 的 aarch64 产物本机没验过)。
- 打包脚本按 `uname -m` 推断 bundle 目录(x64/arm64)与发行架构名(deb: amd64/arm64;
  AppImage: x86_64/aarch64), 可用 `ARCH=`/`BUNDLE=`/`APPIMAGE_ARCH=` 覆盖。

## 结论: Linux 桌面"启动 3s"是 debug 模式的 JIT 成本(2026-11-11 二)

里程碑实测(debug bundle, 见 `.pi/memory/notes-build.md`): 进程→Dart main 0.38s;
FRB `RustLib.init` 21ms; `dlopen` 237MB 的 debug `libncm_ffi.so` 1ms; HomePage 首帧 build 仅 2ms;
**首帧 layout/paint 3.4~4.2s**。同一台机空项目首帧≈1.2s(环境地板), `home:` 换成一行 Text
后立刻回到 1.1s; 软件渲染同样 3.36s ⇒ 与 Rust/网络/图片/GPU 无关, 是 debug JIT 首次执行
首页那一大坨代码的成本。要秒开用 release/profile 包, 不必再往 Rust 侧查。

## Linux arm64 分发(AppImage + 文档)(2026-11-11)

v0.4.0 已有 arm64 的 tar.gz + deb CI, 但 AppImage 只有 x64 进了 release workflow, 也没有本地打包文档。

**做了什么**
- `packaging/linux/build-appimage.sh` 增加架构交叉校验: 用 `readelf -h` 读 bundle 里 minincm 的
  ELF Machine 字段, 与目标 AppImage 架构比对(x86-64↔x86_64 / AArch64↔aarch64), 不匹配直接报错退出,
  杜绝"x86_64 内容的 aarch64.AppImage"。
- 新建 `packaging/linux/README.md`: 本地构建 deb/AppImage/tar.gz 完整命令、ARCH/BUNDLE/APPIMAGE_ARCH
  覆盖、aarch64 注意事项、CI job→资产表。
- 未发现 x64 硬编码(目录与架构名均按 uname -m 推断), 脚本保持 bash 3.2 兼容。

**x64 端到端验证**(复用主工作区 x64 release bundle, 产物写本 worktree dist/)
- AppImage: `MiniNCM-0.4.0-linux-x86_64.AppImage` 生成, `file` 显示 ELF 64-bit x86-64;
- deb: `minincm_0.4.0_amd64.deb` 生成, `dpkg-deb -I` 显示 Architecture: amd64;
- 校验反例: `APPIMAGE_ARCH=aarch64` + x64 bundle ⇒ 脚本报"架构不匹配"并以非零退出, 校验有效。

**arm64 未验证的部分**
- aarch64 机器上跑 `build-appimage.sh` 端到端(含 `appimagetool-aarch64.AppImage` 下载后能否运行);
- 打出的 aarch64 AppImage 能否直接启动;
- 架构校验分支在 arm64 上的正例。**因此 arm64 AppImage 不进 release workflow**(`.github/workflows/**`
  未改), 验证通过后再加 CI job。

**arm64 上怎么验**
1. `cd ui && flutter build linux --release`
2. `bash packaging/linux/build-appimage.sh dist` → `file dist/MiniNCM-*-linux-aarch64.AppImage` 应显示 aarch64, 直接运行应能启动;
3. 反例: `APPIMAGE_ARCH=x86_64 bash packaging/linux/build-appimage.sh /dev/null/dist`(输出目录不存在即可) 应报架构不匹配退出;
4. 通过后参照 `packaging/linux/README.md` 的 CI 资产表补 workflow job。

## 主题色(视觉风格)切换(2026-11-11 二)

用户要求: 提供视觉风格切换(绿/蓝/橘/粉), 且每个颜色都能配深色/浅色。

- 做法: 色板只是 `colorSchemeSeed`, "浅色/深色" 仍由既有「主题模式」(跟随/浅色/深色)决定
  ⇒ 两者正交组合出 5 色 × 2 亮度, 不是 10 个独立配置; 同一 seed 生成两套配色, 语义一致。
- `theme.dart`: `enum AccentPalette`(neteaseRed/green/blue/orange/pink) 带稳定 id(持久化)、label、seed,
  `fromId` 未知值回落默认; `buildLightTheme/buildDarkTheme` 增加 `accent` 参数(默认 = 与改造前完全一致)。
  OLED 纯黑与色板正交。
- `app_settings.dart`: `accent` 字段 + `settings.json` 的 `accent` 键 + `update(accent:)`。
- `settings_view.dart`: 「界面」区块新增「主题色」一行色点(Wrap, 36dp 圆点, 选中带对勾+描边);
  不用 SegmentedButton: 5 个色板在 300dp+1.25 下会挤爆分段控件。
- 测试 `ui/test/theme_accent_test.dart` 7 例: 五色板浅/深 primary 各不相同、默认等价改造前、
  OLED×色板正交、fromId 回落、settings.json 往返、点色点即切换、300dp+1.625 不溢出。

## 批次 1 子代理三路产出(2026-11-11 二)

- **W1 播放条数据层**: 新增 `ui/lib/src/player_bar.dart`(`PlayerBarData`/`PlayerBarActions`/`MiniPlayerBar`),
  `playerBarHost` 改为监听 `playerBarData`+`playerBarActions`+`playerBarSlot` 三槽自建播放条;
  不再"每帧投递整棵 Widget", 数据相等时不通知。`main.dart` 少了约 280 行。
- **W2 打包**: `build-appimage.sh` 加架构交叉校验(readelf Machine vs APPIMAGE_ARCH)+ `packaging/linux/README.md`;
  x64 端到端复验通过(AppImage 14MB / deb amd64 / 反例正确报错)。arm64 AppImage 仍待 aarch64 机器验证。
- **W3 窄屏回归**: `player_bar_narrow_test`(改成用真实 `MiniPlayerBar` 组件) + `style_tiles_narrow_test` 共 10 例。
- 合并纪律: 每路一个 git worktree(`~/ncm-wt/w*`)+ 独立分支, 合并前丢掉 lane 里的 `.lane-notes.md`,
  合并后由编排者独立重跑 `dart analyze` + 全量 `flutter test`(最终 641 例全绿)。

## CI: arm64 腿换掉 subosito/flutter-action(2026-11-11 二)

v0.4.0 / v0.5.0 两次 Release 都在 `build-linux-arm64` 的 flutter-action 步骤挂掉(
`Unable to determine Flutter version ... architecture: arm64`, 显式 `flutter-version` 也一样) ⇒ publish 被 skip、整版没资产。
改成 arm64 腿从官方 git 源直装 Flutter(`git clone --depth 1 -b 3.47.9` + `precache --linux`), x64 腿保留 action;
CI 的 `Build Linux bundle (arm64)` 已由红转绿, v0.5.1 用这套配置重发。

## 桌面冒烟清单与脚本骨架(2026-11-11)

- 新增 `docs/smoke-desktop.md`: 桌面端发布前冒烟共 31 条可勾选清单(安装 deb/AppImage/tar.gz、
  启动与外观、登录、播放、我的/设置/账号、退出重开、已知受限项), 每条带通过判据(看什么、跑什么命令)。
  人工 28 条 / 脚本自动 3 条, 目标全程 ≤ 10 分钟。
- 新增 `tools/smoke-desktop.sh`(可执行, bash 3.2 兼容, 外部命令缺失一律 SKIP 不 fail):
  - `--env`: 发行版/GLib/图形会话(Wayland-X11)/音频后端 + bundle 架构与 GLib 符号基线
    (思路同 build-deb.sh 的 nm 检查) + `~/.local/share/ncm` 存在性与权限;
  - `--run BUNDLE=<路径> [--wait-window]`: 启动 bundle 里的 minincm 采 15 秒启动耗时, 结束打印日志尾部;
    无图形会话(容器/SSH)时优雅 SKIP; debug 包首帧慢是 debug JIT 成本, 数值仅 release 包作数;
  - `--report`: 把 --env/--run 拼成可直接贴 issue/PR 的 markdown。
- 约束: 脚本不联网、不写 /tmp(日志在 `~/.cache/minincm-smoke/`); 未接入 release workflow
  (不动 .github/**), 后续建议发布后手动触发人工冒烟 checklist issue, 仅文档建议。

## Android Keystore 凭据后端(通道层)(2026-11-11)

- 新增 `KeystoreChannel.kt`(通道 `ncm/keystore`) + `ui/lib/src/keystore.dart` + 单测,
  对应调研报告 §2c 的凭据后端通道层。
- **存的是什么**: 原生侧把 value 用 Android Keystore 的 AES-256-GCM 密钥加密后,
  以 `iv(12B) + 密文` 落盘到 `filesDir/cred/<key>.bin`(先写 .tmp 再 rename 原子替换);
  Dart 侧只见 String, 不落任何明文。
- **key alias**: `minincm-cred-v1`, 不设 setUserAuthenticationRequired(后台可无感读取)。
- **失败语义**: 清数据/备份恢复导致密钥丢失或解密失败(AEADBadTag)时, 原生删掉旧密文
  并返回 null/false, `KeyPermanentlyInvalidatedException` 已捕获, 不抛到 Dart;
  非 Android 上 `available()==false`、`put()` 返回 false, 不偷写明文。
- **尚未接线到 Rust identity**: 本 lane 只交付通道与 Dart 封装, 未接 main.dart 业务流程,
  也未实现 Rust 侧 trait(由另一 lane 接入)。
- **模拟器 a34 手动验**:
  ```bash
  ~/bin/avd headless a34   # 启动模拟器后装 debug 包并打开 app
  adb shell run-as com.minincm.minincm.dev ls files/cred        # 看密文文件
  adb shell run-as com.minincm.minincm.dev cat files/cred/<key>.bin | xxd | head  # 应为 iv+密文
  adb logcat -s flutter | grep -iv music_u   # 确认无明文泄漏
  ```

## Linux secret-service 后端(2026-11-12, lane p2)

| 项 | 状态 | 证据 |
|---|---|---|
| 实现 | ✅ | `core/crates/ncm-service/src/credential_keyring.rs`: `SecretServiceStore`(`#[cfg(target_os="linux")]`), keyring 3.6.3 + `sync-secret-service`, service=`com.minincm.minincm`, account=`CredentialKey::id()` |
| 探测 | ✅ | `available()` 只构造不存在的 entry 读一次(不写探针 secret), 结果 OnceLock 缓存; 无 D-Bus → `Unavailable`, 不 panic |
| 错误映射 | ✅ | NoEntry→Unavailable; NoStorageAccess/PlatformFailure→Unavailable(语义=未登录); 其余→Backend; 绝不 panic |
| open_backend | ✅ | linux 分支: keyring 可用→`Secure{backend:"secret-service"}`; 不可用→原同意门/回退(语义不变), fallback reason 提及 secret-service 不可用 |
| 依赖 | ✅ | `[target.'cfg(target_os="linux")'.dependencies]` — Android/Windows 不编译; Cargo.lock 3195→3251 行(+56) |
| 测试 | ✅ | 默认(CI 无 D-Bus) 242 passed 0 failed; 真实 D-Bus 会话(`NCM_KEYRING_TEST=1`) keyring 5 测试全绿: available 缓存/真实 put-get-remove/spike/open_backend 报 secret-service/降级子进程回落同意门(未同意写被拒) |
| 回退语义 | ✅ | 无 D-Bus(zbus 进程内缓存连接, 用子进程重执行模拟): open_backend → None + PlaintextFallback; 同意后 FileStore, 未同意写 → AccessDenied |

降级配方(锁屏/无桌面): `NCM_KEYRING_TEST=1 cargo test -p ncm-service keyring` 内含子进程模拟无 D-Bus; 无头 spike 配方见 credential_keyring.rs 注释(须 `gnome-keyring-daemon --unlock` 空密码解锁, 否则 gcr-prompter 卡死)。

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

