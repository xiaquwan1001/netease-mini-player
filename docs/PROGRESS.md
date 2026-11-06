# 进度记录(Progress)

> 最近更新: 2026-11-05(底部四栏 + 双端实测)。
> 协议细节见 `.pi/skills/netease-cloud-music-api-reverse/SKILL.md`;
> 架构决策见 `docs/architecture-restart.md` §11;M0 清单见 `docs/m0-plan.md`;
> 通道实测见 `docs/api-channel.md`。

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
