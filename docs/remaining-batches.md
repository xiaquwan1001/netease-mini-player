# 剩余待办 · 分批与并行派发规划

> 用途: 后续每轮开工前先在这里选批次, 按「并行矩阵」决定能不能同时派。
> 配套: `docs/api-coverage.md`(接口差集, 用 `bash tools/api-coverage.sh` 复算)、
> `docs/PROGRESS.md`(已落地功能与协议事实)、`docs/archive/remaining-batches-history.md`(历史分批口径)。
>
> 口径日期: **2026-11-17**。**覆盖率 / FFI 导出数 / 测试数一律跑脚本现算**, 本文件不再维护副本
> (`bash tools/api-coverage.sh`、`bash tools/ci-gates.sh list`); 权威数字只在
> [`PROGRESS.md`](PROGRESS.md) 头部「当前门禁」表(2026-11-16 实测: 覆盖 **135/136**、FFI 导出 **161**、
> Rust **300** / Dart **1074**, golden **18**; Android `testDebugUnitTest` **3**, `row-padding` 门 OK)。
>
> **当前状态**: 功能批次 Wave 1–9 全部完成、D7(frb 直透 domain) 57/57 关闭、技术债 D 批收口、
> 平台层审计 22 条已落 **21 条**(P-01..P-22 只剩 **P-11 完整版**; P-18 后半与 P-10 方案 B 均于 2026-11-17 落地并已合入 main)、main.dart 拆壳 **S0–S8 全部完成**(3877→**48 行**门面, `ui/lib/src/home/`);
> 列表行 A 级清零、**B 级 12 条清零(2026-11-16 晚)**、**C 级第一批已落(2026-11-17: 四个具名行留白口径 + `row-padding` 门)**;
> Android 侧门禁已进 CI(`android-unit` 阻塞 / `android-lint` 仅暴露, 现状 67 error)。
> 三端分发六种产物 + arm64 腿, 已发布版本 **v0.19.0**(其后 main 上还有一条未发版批次)。
>
> **下一轮从哪挑**: **§11 · 待办**(功能/小改, 2026-11-13 起维护) → **§12 · 结构性债务** → **§13 · 平台层审计剩余项**(2026-11-16 登记)。

## 1. 硬约束(决定哪些事不可能真并行)

| 约束 | 影响 |
|---|---|
| 所有 provider 方法都写在同一个 `core/crates/ncm-service/src/netease.rs`(4700+ 行) | 两个批次同时加接口 = 同文件冲突 |
| Provider trait 在 `core/crates/ncm-provider/src/lib.rs`, FFI 在 `core/crates/ncm-ffi/src/api.rs` | 同上, 且必须成对改 |
| `flutter_rust_bridge_codegen` 一次重写 `ui/lib/src/rust/*` + `core/crates/ncm-ffi/src/frb_generated.rs` | **codegen 是全局串行点**, 同一时刻只能有一个批次跑它 |
| `cargo` 共用 `core/target`, Gradle/Flutter 共用 `ui/build` | 两个批次同时 `cargo test`/`flutter build` 会互相排队或锁死 |
| 模拟器有两台(**a34 / a36**, 一般占 5554/5556), 真机只在发布冒烟用 | 单台设备内实测串行; 两台可各跑一个批次(用 `adb -s` 指定), 但同一账号的写操作仍要串行 |
| UI 测试按文件拆分(`ui/test/*.dart`), `flutter test` 可全量跑 | Dart 测试本身可并行开发, 但全量跑建议集成时一次 |

**结论**: 同仓同工作树里, 真正安全的并行度是 **2**: 一条「Rust 桥」车道(独占 codegen) + 一条「纯 Dart」车道(只改自己那份 `ui/lib/src/*.dart` 与 `ui/test/*.dart`)。
超过 2 条要么上 `git worktree`(合并时仍需串行 codegen), 要么只做只读调研/文档。

## 2. 批次清单(按成本分级)

### S 级 · 只读接口 + 现有 DTO 能装下(1 轮 1 个, 半天量)

| 批次 | 目标 | 新增接口 | Rust 改动 | UI 文件 | 设备 |
|---|---|---|---|---|---|
| ~~**B1 消息增强**~~ ✅已做 | @我 / 最近联系人 / 私信分页 | `msg_forwards` `msg_recentcontact` | parse 2 个 + FFI 2 个 | `messages_page.dart` | 已验(a36) |
| ~~**B2 评论统计**~~ ✅已做 | 评论/分享/点赞计数(无收藏数/热评数) | `comment_info_list` | `CommentStats` DTO + parse + FFI 1 个 | `comment_stats_bar.dart`(新) + `comment_thread.dart` | 已验 |
| ~~**B3 会员只读**~~ ✅已做 | 黑胶会员卡/成长值/每日签到/任务(不碰支付) | `vip_info_v2` `vip_growthpoint` `signin_progress` `vip_tasks`(`vip_sign_info` 已弃用) | `vip_overview` 1 个聚合方法(内部 join4) + FFI 1 个 | `vip_page.dart` + `settings_view.dart` 入口 | 已验(a36 登录/未登录) |
| ~~**B4 搜索增强**~~ ✅已做 | 精确实体条/关键词联想/热搜榜 | `search_multimatch` `search_suggest`(web/mobile) `search_hot_detail` | parse 3 + FFI 3 | `search_exact_bar.dart`(新) + `search_suggest.dart` + 落地页热榜 | 已验(a36) |
| ~~**B8 等级/勋章**~~ ✅已做 | 等级进度 + 勋章墙 | `user_level` `user_medal` | parse 2 + FFI 2(勋章接口有界重试) | `medal_wall.dart`(新) + `mine_view.dart` 入口 | 已验(a36) |

> B4 搜索增强的实测细节(`search_multimatch` 空命中伪装成功、`type` 参数无效、CLI raw 用位置参数 `k=v`)全部在 [`docs/b4-search-notes.md`](b4-search-notes.md), 本文件不再复述。

### M 级 · 要新交互/新页面/vendor 有限制(1 轮 1 个, 1~2 天量)

| 批次 | 目标 | 接口 | 风险点 |
|---|---|---|---|
| ~~**B5 逐字歌词**~~ ✅ 已完成(契约层+UI 车道) | 歌词页逐字高亮 | `lyric_new`(已接) `song_lyrics_mark*`(只读 dump, 写不接) | 契约层已合入；**ytlrc/yromalrc 实测恒空** ⇒ 翻译只能行级; 老歌无 yrc 必须回落 |
| **B6 榜单 v2** | 「更新 N 首」/歌手榜细分 | `toplist` `toplist_detail_v2` `toplist_artist` | ROI 低, 现有 detail 已够用 |
| **B7b 歌单细分编辑**(与已完成的 B7a 写接口 create/加曲是两回事, 见 §11.A) | 私密切换/标签/排序/换封面 | `playlist_privacy` `playlist_order_update` `playlist_tags_update` `playlist_cover_update` | **vendor 把 privacy 写死 0**; 其余要自己拼请求或上传 |
| ~~**B10 电台补充**~~ ✅已做(只读) | 电台榜单/分类/推荐/主播 | `dj_toplist*` `dj_catelist` `dj_category_*` `dj_recommend_type` `dj_program_toplist` `dj_subscriber` | 12 DTO + 6 parse + FFI 4 + `radio_explore_page.dart`(新); **`dj_sub` 订阅与 `dj_difm_*`(6) 不做**(写/语义未验证) |
| ~~**B12 数字专辑只读**~~ ✅已做 | 已购/销量/详情 | `digital_album_detail` `digital_album_purchased` `digital_album_sales` `song_purchased` | 6 DTO + 4 parse + FFI 4 + `digital_album_page.dart`(新) + 我的页入口; 下单不碰 |

### L 级 · 需要新能力(单独立项, 不建议和上面混批)

| 批次 | 能力 | 前置 |
|---|---|---|
| B9 | 最近播放的视频/声音页签 | 视频播放器落地(Media3/mpv 已有, UI/防盗链未做) |
| B11 | 听歌识曲 `audio_match` | 录音权限 + 约 10s 指纹采集, Kotlin/Linux 各一套采集 |
| B13 | 云盘 | 分片上传 + 文件选择 + 匹配库 |
| B14 | MV/视频 | 播放器 + 视频详情/时间线 |
| B15 | 一起听 | 房间 + 心跳 + 指令同步, 需双端联调 |
| B16 | 动态发送/话题 | 发包链路 + 审核/删除语义 |
| B17 | 云贝任务/兑换 | `yunbei_*`(11), 兑换类不碰 |
| B18 | 资料/账号安全 | 跳官方网页, 不自己实现 |

### X 级 · 明确不做(避免重复评估)

原生登录族(8821 风控) / 埋点上报 / 内部灰度与算法向量 / 支付与兑换 / 创作者中心与粉丝中心 / 账号安全改绑。

## 3. 并行矩阵

| 组合 | 能否并行 | 说明 |
|---|---|---|
| 任两个 S 级 | ❌ | 都要改 `netease.rs` + `api.rs` + codegen |
| 一个 S/M 级 + 「纯 Dart 收尾批」 | ✅ | Dart 批只改自己文件(见 §4 B0) |
| 一个 S/M 级 + 「只读调研/文档」 | ✅ | 调研不改代码, 产物写 `/tmp` 或 docs |
| 一个 Rust 批 + 另一个批的「mock 版 UI + widget test」 | ✅ | 前提: DTO 形状已先定稿(见 §5 schema 先行) |
| 两个 Rust 批(不同 worktree) | ⚠️ | 可行但合并要串行 codegen, 只有大改(如 B5)才值得 |
| 两条设备实测 | ✅(上限 2) | 各绑一台模拟器(a34/a36), 用 `adb -s emulator-5554/5556` 区分; 写操作(点赞/签到/歌单编辑)不要两台同时用同一账号 |
| 两次 `flutter build` / `cargo build` | ❌ | 构建锁, 由编排者最后跑一次 `bash tools/ci.sh` |

> 「4. B0 · 纯 Dart 收尾批(任何轮次都能搭车)」是已完成/历史口径, 原文见 [`docs/archive/remaining-batches-history.md`](archive/remaining-batches-history.md)。

> 「5. 推荐波次(pipeline)」是已完成/历史口径, 原文见 [`docs/archive/remaining-batches-history.md`](archive/remaining-batches-history.md)。

## 6. 单批固定流程(所有批次共用)

1. **抓形状**: 先用 `ncm-cli` 加临时命令或 `NCM_DUMP_*` 打印真实响应, 不按文档猜字段。
2. **domain**: `ncm-domain` 加/改 DTO(`serde(default)` 兼容旧数据) + parse 函数单测。
3. **provider**: trait 默认实现返回 `unsupported` + `netease.rs` 实现; 新能力记得加 `CAPABILITIES`(否则 FFI 报 "no provider supports xxx")。
4. **FFI + codegen**(独占窗口):
   `flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust`
   然后 `cargo build -p ncm_ffi`(漏了会报 content hash 不一致)。
5. **UI**: 先写 mock loader 的 widget test, 再接真实 Rust 调用。
6. **实测**: 模拟器 a34 或 a36 手动路径 + logcat(两台可并行分担不同批次); 真机只在发布冒烟。
   a34(API 34)与 a36(API 36)版本不同, 涉及系统行为(Media3/通知/权限)的批次建议两台各跑一次。
7. **收口**: 更新 `docs/api-coverage.md` 数字(跑 `tools/api-coverage.sh`)、`docs/PROGRESS.md` 新小节、`.pi/memory/HINDSIGHT.md` 协议事实。
8. **提交**: 一个批次一个 commit, 消息格式 `feat: <能力>(<关键接口>)`。

## 7. 派发工单模板(fabric_exec)

> 只派 **1 个批次/1 个子代理**; 用 `agents.spawn` 异步, 不要在一个程序里 `Promise.allSettled` 等全部。
> 模型写真实 `provider/id`(如 `custom.ustc-pool/ustc-worker`, **必须带 `custom.` 前缀**), 不用别名; `tools` 必须显式列出。

```text
【批次】B1 消息增强
【必读】AGENTS.md、docs/remaining-batches.md §6、docs/PROGRESS.md 最近两节、.pi/memory/HINDSIGHT.md
【范围】只做 msg_forwards / msg_recentcontact + 私信分页; 不碰支付/发送
【允许改】core/crates/ncm-service/src/netease.rs(仅新增 parse/impl)、
          core/crates/ncm-provider/src/lib.rs、core/crates/ncm-ffi/src/api.rs、
          core/crates/ncm-domain/src/lib.rs、ui/lib/src/messages_page.dart、ui/test/messages_page_test.dart、
          docs/PROGRESS.md、docs/api-coverage.md、.pi/memory/HINDSIGHT.md
【禁止】ui/lib/src/rust/*(生成物)、core/vendor/*、tools/*、flutter build、其他批次文件
【codegen】本批是 Rust 批: 允许跑, 且必须只跑一次; 跑完 cargo build -p ncm_ffi
【步骤】① 先用 CLI/env dump 抓真实响应并写进注释 ② domain+parse+单测 ③ trait+impl+CAPABILITIES
        ④ FFI+codegen ⑤ UI(widget test 先行) ⑥ 模拟器实测 ⑦ docs/memory 更新
【验收(必须把命令输出贴回)】
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  cargo test --manifest-path core/Cargo.toml
  (cd ui && flutter analyze --no-fatal-infos && flutter test)
【落盘节奏】每完成 ①②④ 各写一次文件/commit 说明, 不要攒到最后一次性输出
【自报不可信】最终由编排者重跑 ci.sh + 模拟器走查
【设备】本批用 a36(或 a34), 用 adb -s emulator-XXXX 指定; 不要两台同时写同一账号
```

**编排者收口清单**
- [ ] `git status` 只含本批文件; 无生成物手改
- [ ] `bash tools/ci.sh` → `CI OK`(编排者自己跑, 不信 worker); 其中 vendor 的 4 例
      **匿名真实联网 smoke**(P1 裁剪后 8→4, 删的 4 例打在未接入 endpoint 上)允许打 `WARN` 不阻塞(上游风控/公网抖动, 3 次重试), 需要硬核验公网时
      `NCM_VENDOR_SMOKE_STRICT=1 tools/ci.sh`; 本地 workspace 单测/analyze/flutter test/双端构建仍是硬门
- [ ] 模拟器走查(a34/a36 任选一台; 系统相关改动两台各一次), 空态/未登录各一次
- [ ] `bash tools/api-coverage.sh` 数字与 docs 一致
- [ ] memory 写入协议事实(字段名/分页字段/风控坑)
- [ ] 一个 commit, 不含 `.pi/fabric/mesh/state.json`

## 8. 风险与注意事项

- **同文件冲突是主要成本**: 两个 Rust 批并行后合并 `netease.rs` 往往比串行做更慢; 默认串行。
- **codegen 产物冲突无法手工解决**: 一律由当前 codegen 窗口的批次重新生成, 其他批次 `git checkout -- ui/lib/src/rust core/crates/ncm-ffi/src/frb_generated.rs` 后再合。
- **接口形状不可信文档**: vendor 是 api-enhanced 移植, 但 hasMore/more、areaId/area 这类差异反复出现, 必须先 dump。
- **写操作先小样本**: 签到/评论/歌单编辑先在模拟器用测试号验证, 避免污染真实账号数据。
- **两台模拟器都只跑 debug 包**: a34/a36 可并行分担批次, 但端口(5554/5556)与账号写入要错开; vivo 只在 release 冒烟, 且会被用户拿走。
- **长跑任务设时间盒**: 子代理单批 15 分钟无进展就落盘卡点收尾, 换直连模型重派。

> 「9. 精简项排队(2026-11-09 审计产出, 按依赖顺序)」是已完成/历史口径, 原文见 [`docs/archive/remaining-batches-history.md`](archive/remaining-batches-history.md)。

> 「10. UI/UX 走查批次(A–D, 2026-11-09 审计产出)」是已完成/历史口径, 原文见 [`docs/archive/remaining-batches-history.md`](archive/remaining-batches-history.md)。

## 11. 待办(2026-11-17 更新)

> 这一节是「下一轮从哪挑」的**唯一入口**(功能/小改); **结构性债务单独立项见末尾 §12**(含派发波次);
> **平台层审计确认未做的 2 条债务(P-11 完整版 / P-10 方案 B)见 §13**(P-18 后半已于 2026-11-17 落地)。
> P-05 长尾 / P-12 / P-22 已于 2026-11-16 落地, §13 已标「作废」。
> §2–§3、§6–§8 是批次目录与派发流程, 历史口径见 `docs/archive/remaining-batches-history.md`。
> **基线数字不在这里维护**(曾经 4 处各写一套 ⇒ 已实测分叉): 唯一权威是 [`PROGRESS.md`](PROGRESS.md) 头部「当前门禁」表。
> 本节只管「还剩什么没做」。

### A. 只剩这些没做(按成本排序, 2026-11-17 复核后重写)

| 序 | 项 | 说明 | 成本 |
|---|---|---|---|
| 1 | 视觉人工过目 | 账号页层级 / 新歌新碟合并块 / 风格 chips 归属 / 全页 AppBar+TabBar 高度 / 设置页密度 / 我的页会员行位置 —— 已按反馈改过两轮, 仍需人眼确认 | S(需人眼) |
| 2 | 主页新数据面接页面 | `userPlayRanking` / `userEvents` 已有 FFI 但无 UI 入口(FFI 161 里 6 个无入口);实测他人听歌排行匿名态恒空、`event/get` 匿名 301 需登录 ⇒ **接了也看不到东西**, 等有登录态真机再决定是否做「常听/动态」tab。另: `/api/user/playlist` 的 `subscribed` 恒 null(实测), 拆「创建/收藏」需改用 `playlist_detail` | S~M |
| 3 | deb 运行期最小桌面冒烟 | 依赖闭包已静态核查 100% 覆盖; 字体/插件等运行期数据文件仍需真最小桌面点一次 | S |
| 4 | Windows / 桌面扫码登录冒烟 | 同一份 Rust 链路, 本机没有 Windows 桌面, 只能 CI 或用户机验 | S |
| 5 | 桌面 keyring 装包后冒烟 | secret-service 已在真实 D-Bus 下过单测, `.deb`/AppImage 装后未点 | S |
| 6 | **诊断 Worker 落地**(用户手动) | 代码与 8 步部署说明已在 `tools/diag-worker/`; 需要用户: 建 fine-grained PAT(只勾 Issues: write + 单仓库) → `wrangler secret put GH_TOKEN` → 部署 → 绑自定义域(workers.dev 国内不稳) → 把 `https://<域>/diag` 填进 `app_meta.dart: kDiagUploadEndpoint` 再发版。**仓库/客户端零 token** | S(需用户) |

> 原表里 §11.A-2(A) / A-7 / A-8 / A-9 / A-10 已于 2026-11-14~17 全部清零, 一行结论见下面 §11.B。

### B. 已完成(供对照, 不要重做)

详细验收证据见 `docs/PROGRESS.md` 对应日期小节; 已完工车道的执行记录见 `docs/archive/`:

- 只读批次 B1–B5 / B8 / B10 / B12 / B13(TTML) 与写接口 B7a(歌单 create / 批量加曲); FFI 清理 D1/D2/D5/D7(frb 直透 domain 57/57)。
- 技术债 D 批(弹层 21/21 统一、格式化去重、podcast 658→190 行、45 文件窄屏回归归零)与视觉批 A–C。
- 手机号+短信验证码登录(用户真机验过)、评论发送写操作走查 + `tools/check-write-guard.sh`。
- 桌面打包四态(deb / AppImage / tar.gz / setup.exe)、Linux arm64 腿、Windows 向导中文化、AppStream 元数据。
- 凭据三端(Android Keystore / Linux secret-service / Windows DPAPI) + 凭据不再过 FFI 回传 Dart。
- v0.6.0–v0.7.1 用户回归四连发(见 `docs/archive/PROGRESS-2026-11-03-11-12.md`「2026-11-12(晚)」)。
- 原 §11.A 的 ✅ 项(一行结论, 明细见 `docs/PROGRESS.md` 与 `archive/PROGRESS-2026-11-13-11-19.md`):
  **AppImage 首启「集成到应用菜单」**(2026-11-17, `89f523b`; 只写 `~/.local/share/applications` + hicolor 图标, 无需 root, 拒绝/已装不再问) ·
  **行高按 textScaler 缩放**(2026-11-14, `layout.dart: rowExtentFor` 全仓唯一实现) ·
  **筛选条 84 竖溢**(2026-11-14, `avatarStripHeightFor`) ·
  **列表行 C 级收敛**(2026-11-16/17: B 级 12 条清零 → 四个具名留白口径 → 取消 8/12 二分(现统一 12 线)→ 纵向 pitch 0/6 → `SongRow` 4 个静态工厂去重 12 处; 门 `check-row-padding.sh --strict` 已进 verify) ·
  **golden 接入 CI**(v0.13.0 12→18 张并进 CI; v0.16.0 门禁统一到 `tools/ci-gates.sh`)。

### C. 需要新能力的 L 级(单独立项, 不要混批)

视频/最近播放页页签(需视频播放器) · 听歌识曲(录音 + 指纹) · **云盘分片上传**(主体已接入, 只差 >单请求上限的大文件分片; 旧编号 B13 与「B13 逐字歌词 TTML」撞号, 以后只称「云盘」) ·
MV 列表页/视频详情(播放器已有) · 一起听(房间 + 心跳, 需双端联调) · 动态发送(发包 + 审核语义) ·
云贝任务(兑换类不碰) · 音源插件化(QuickJS 宿主 + lx 兼容层, 设计边界见 `docs/archive/architecture-restart.md`)。

### D. 明确不做

App 原生登录族(eapi, 8821 风控) —— **网页登录族**的手机号+验证码登录已在 2026-11-11 落地, 两者不是一回事 ·
埋点上报 · 内部灰度与算法向量 · 支付与兑换 · 创作者中心与粉丝中心 · 账号安全改绑 · `simi_user`(实测恒空)。

## 12. 结构性债务(2026-11-13 审计产出 · 单独立项, 不要和功能批混)

> 都是「改形状不改行为」, 每项**一个 commit 一条车道**; 先做 12.0 把门禁补齐, 再动后面的。
> 现状数据均为 2026-11-13 本机实测。

### 12.0 门禁补齐(S · 半天 · **必须第一个做**)

CI 现在只有 `cargo test` / `dart analyze` / `write-guard` / `flutter test`, **没有格式门也没有 clippy 门**。

| 现状 | 数字 |
|---|---|
| `cargo fmt --all -- --check` | **368 处差异**(netease.rs 125 / api.rs 63 / ttml_source.rs 32 / credential_store.rs 23 …) |
| `dart format lib test` | 会重排 **143 文件**,+5846 −4405(已实测并回退, 不要顺手跑) |
| `cargo clippy --workspace --all-targets` | 0 warning(2026-11-13 已清零, 需要门来锁住) |

> **2026-11-18 补记**: Android 侧第三道门 `:app:lintDebug` 也已补齐 —— 67 error 清到 **0**
> (media3 `UnstableApi` opt-in 收口 + `LoginActivity` 迁 `OnBackPressedDispatcher`), 已进
> `tools/ci-gates.sh verify` 与 GitHub CI 阻塞门。细节见 `PROGRESS.md` 2026-11-18 条。

做法:
1. **纯格式提交**:`cargo fmt --all` + `dart format lib test`,**同一个 commit 里不放任何逻辑改动**(用 `git diff -w` 自检只看格式)。
2. 同 commit 给 `.github/workflows/ci.yml` / `.gitlab-ci.yml` / `tools/ci.sh` 加三个 step:
   `cargo fmt --all -- --check` · `cargo clippy --workspace --all-targets -- -D warnings` · `dart format --set-exit-if-changed lib test`。
3. 之后任何改动都必须过格式门(否则 CI 红)。

验收: CI 三个新 step 全绿;`cargo test` / `flutter test` 数字不变。
**并行性: 独占** —— 格式提交会和任何在飞车道撞车, 必须先落地再开别的。

### 12.1 `netease.rs` 按能力域拆模块 ✅ **已完成(2026-11-13)**

结果: 8110 行 → `netease/{mod,provider,parse,song,search,community,vip,playlist,radio,account,comment,artist,album,lyric}.rs`
(最大 1038 行);`provider.rs` 保留唯一 `impl Provider`(116 个方法一行转发,零逻辑);111 个 `#[test]` 拆 9 文件。
函数名单前后各 371 个完全一致、`cargo test` 271 不变、`api-coverage` 123/123。

原状(留档): 8110 行 / 126 个顶层 fn,全部 provider 方法与 parse 混在一个文件(改任意接口都必冲突)。

目标: 拆成 `netease/{mod,parse,song,lyric,playlist,comment,community,account,radio,vip}.rs` ——
**先拆纯 parse 函数**(无状态、已有单测覆盖), 再拆 `impl Provider for NeteaseProvider` 的方法块。

验收: `cargo test` 全绿、public API 与 FFI 零变化(`api-coverage.sh` 仍 123/123)、单文件 ≤1200 行。
**并行性: 与 12.2 互斥**(同文件);与 12.3/12.4/12.5 可并行。

### 12.1b 后端审计剩余两条的**裁决(2026-11-17 复核)**

> 来源 `.pi/plans/arch-audit-backend-2026-11-15.md` §7 建议 3 / 4。原计划第 3 项(锁中毒统一 + `fsutil` 收敛)
> 只差落地, 第 5 项(`api.rs` 按域拆)是唯一还开着的 M 级项。

**① 锁中毒 + `fsutil` 收敛 —— 生产侧已清零, 本批补了门**

| 检查 | 结果(2026-11-17 实测) |
|---|---|
| `rg '\.lock\(\)\.unwrap\(\)' core/crates` | **5 处, 全在 `ncm-playback` 的 `#[cfg(test)]` 模块里**(1316/1333/1351/1413/1532) |
| 生产代码里的同类写法 | **0**(`ncm-ffi` 用 `lock().map_err(..)`, `ncm-service` 用 `unwrap_or_else(|e| e.into_inner())`) |
| `fsutil::write_atomic` / `write_atomic_private` | 已是唯一实现, 7 个调用点(identity/credential×2/loudness/ttml/history) |
| 门 | 新增 `tools/ci-gates.sh lock-poison`(`bash tools/check-lock-poison.sh`, 已进 `verify`): 只放行 `#[cfg(test)]` 模块内, 负向探针实测会红 |

**② `api.rs` 按域拆 —— 结论: 现在不拆, 触发条件写明**

现状(2026-11-17 实测): `api.rs` **3 325 行** / `pub fn` 30 个 + `ffi_forward!` 78 处 = **FFI 导出 161** / 65 个 `#[frb(mirror)]`
/ 文件内已有 **20 个 `// ----` 分节**(即"逻辑上已按域分节", 只是没分文件)。Dart 侧 **173 个文件** 引用 `rust/api.dart`。

- **收益**: 单文件变短、按域 review 更省; 但 Dart 侧 import 面不变(FRB 生成的 `api.dart` 仍是单一入口),
  也就是说**收益是"编辑体验", 不是行为/性能/架构边界**(边界早已由 crate 结构守住: `ncm-ffi` 的 Cargo.toml 里没有 `ncm-api-rs`)。
- **成本**: 迁移 161 个导出 + 65 个 mirror 会牵动 173 个 Dart 文件的 import 面(审计按 141 估, 现已 173),
  且必须整体重跑 codegen(`flutter_rust_bridge_codegen generate`) + 全量 `flutter test` 才能证明零 diff。
- **风险**: FRB 2.13 解析以 `rust_input` 为根的**模块树**; `api.rs → api/mod.rs + api/domain/*.rs` 形状合法,
  但 mirror 一旦跟着散开, Dart 类路径会碎成 N 份 —— 审计建议"mirror 先全搬 `api/dto.rs`"。
- **裁决(2026-11-17)**: **暂不拆**。触发条件(任一满足再做): ① 出现第二个需要并行改 FFI 的贡献者/车道;
  ② `api.rs` > 4 000 行; ③ 某次 code review 因单文件过大漏看(事故后复盘判定)。
  第一步永远只搬 mirror 到 `api/dto.rs` + 观察一次 codegen 零 diff, 不动业务 fn。
- **明确不做**: `ncm-service` 拆 `ncm-store`(审计 §7 建议 7, L 级 2~3 天, 当前无第二个消费方);
  `ncm-domain/src/lib.rs`(1 771 行 / 92 DTO)按域拆 —— 必须与 `api.rs` 拆同批, 单做只增加 mirror 路径漂移风险。

### 12.2 `Provider` 拆成能力 trait(M · 1~2 天)

现状: `pub trait Provider` **一个 trait 120 个方法**(god trait),任何新实现都要空实现一大片。

目标: 切 `ReadProvider / LyricProvider / PlaylistReadProvider / PlaylistWriteProvider / CommentProvider /
AccountProvider / RadioProvider / CommunityProvider`,再用
`pub trait Provider: ReadProvider + LyricProvider + … {}` 保持现有调用点(超 trait 自动提供全部方法)。

验收: `cargo test` 全绿、FFI 与 Dart 零变化; 新增的 mock provider(测试)可按能力只实现需要的那部分。
**并行性: 与 12.1 互斥**(两者都要大改 `netease.rs` 的 impl 头)。

### 12.3 UI 载入 / 空态 / 错误 / 分页统一 ✅ **已完成(2026-11-13)**

结果: `state_views.dart`(`LoadingView` / `LoadingView.inline` / `EmptyView`);
`CircularProgressIndicator` **48 处 / 26 文件 → 5 处 / 1 文件**,页面级 LoadingView 34 处、inline 14 处、EmptyView 25 处 / 15 文件;
文案一字未改;15 处裸 `ListView.builder` 只加 `// 非分页: <理由>`;新增 5 例测试。

原状(留档):

| 现状 | 数字 |
|---|---|
| 手写 `CircularProgressIndicator` 的文件 | **26 个**(已有 `search_loading.dart` 但只覆盖搜索) |
| 空态文案散落 | 9 个文件各自写「暂无 / 还没有 …」 |
| 用 `PagedListView` 的页面 | 11 处(其余用裸 `ListView.builder`, 分页语义不一致) |

目标: 抽 `LoadingView` / `EmptyView`(文案集中) / `ErrorView`(扩 `error_views.dart`),分页统一走 `PagedListView`
(不用的地方必须写明理由, 例如固定 10 条的榜单)。

验收: `rg -c CircularProgressIndicator ui/lib/src` ≤ 3(只剩共享组件); 全量测试绿; 300dp + 1.25 字号回归不退化。
**并行性: 纯 Dart 车道**, 可与 12.1 并行;但与 12.4 改同一批页面时要错开。

### 12.4 `main.dart` 拆壳 ✅ **已完成(2026-11-16, S0–S8)**

结果: `ui/lib/main.dart` **3877 → 48 行**(只剩 export 门面), 主体在
`src/home/home_page.dart`(1550)+ `home_wiring.dart`(127)+ 6 个 controller; 全量测试与 golden 绿。
原「S8 未提交: `~/ncm-wt/main-split` … main.dart 1555 行」**已作废(2026-11-16)**: 分支 `lane/main-split`
已合入 main, 且 2026-11-16 收尾批清掉了全部 lane worktree(只留 `~/ncm-wt/ldata`)。
目标 ≤1200 行, 其余进 `ui/lib/src/home/`(实际落点已从早期写的 `ui/lib/src/app/` 改为 `home/`)。

验收: 全量测试绿;release 包冷启动时间不变(用 `tools/devui` 的 `--run` 取数)。
**并行性: 与 12.3 冲突**(同批页面), 二选一先做。

### 12.5 去掉最后一处源码 grep 断言 ✅ **已完成(2026-11-13)**

结果: 改成「正则锚点 + 窗口 + 断言前剥行注释」,并做负向验证(titleLarge→titleMedium 立刻失败)。原状(留档):

`ui/test/marquee_long_title_test.dart` 仍 `readAsStringSync('lib/main.dart')` 做 substring 断言 ——
上一次 CI 挂(RangeError)就是它写死缩进。改成 geometry / widget 树断言(项目里已有大量同类写法可照抄)。

验收: `rg 'readAsStringSync' ui/test` 只剩读 `settings.json` / `pubspec.yaml` 的用例; 该测试文件仍能拦住回退。

### 12.6 `AppSettings` 形状(M · 可选, 加设置项前做) —— **第一步已完成(2026-11-18)**

现况: `ui/lib/src/app_settings.dart` **732 → 584 行**, 编解码已按域拆到同库 part
`ui/lib/src/app_settings_codec.dart`(七个 `_apply*` 同构于唯一一份 `toJson()`: 外观 / 播放 / 搜索
/ 平台窗口 / 更新 / 诊断 / 交互记录); `load()` 里 60 行 if 链 → `applyStoredJson(raw)`。
门: `ui/test/app_settings_codec_roundtrip_test.dart`(4 例) —— 落盘 key 面 = 期望表 + 全字段
写→读往返 + 二次落盘字节稳定 + 缺字段向后兼容 + `schemaVersion<2` 迁移。加设置项现在是
「字段 + 某域 `_apply` + `toJson` + 期望键表」四处且**漏一处测试就红**。

**未做(仍开着)**: 字段本身还是可变单例, `notifyListeners()` 仍靠调用方手工发(高频
音量拖动会带动全页重建, 只是封面用 `ValueNotifier` 单独避开了)。要做就做**不可变快照 +
统一 diff 通知**, 但那要连带改设置页与所有读点(≈ 一次重构批的量)。
**触发条件(任一)**: ① 下次真加 ≥3 个设置项; ② 再出现「某控件拖动导致全页重建/掉帧」的反馈;
③ 某次通知漏发 / 多发造成状态与落盘不一致的 bug。
**并行性: 与 12.3 冲突**(设置页)。

### 12.7 FFI 逐接口样板(低优先 · 暂不做)

`api.rs` 2757 行里大部分是 `ffi_forward!` 样板(加一个接口 = FFI 一处 + Dart 一处 + 测试一处)。
接口数不翻倍就不动;若真要动, 方向是「按能力域批量生成 + 一份导出清单」, 不是继续手抄。

### 12.8 派发建议

| 波次 | 车道 | 说明 |
|---|---|---|
| 第 0 波(独占) | 12.0 格式 + 门禁 | 一个人一条车道, 落地后再开别的 |
| ~~第 1 波~~ ✅ **已完成 2026-11-13** | 12.1 Rust 拆分 ∥ 12.3 UI 统一 | 两个 worktree 并行,编排者独立重跑门禁后合并 |
| 第 2 波(2 条) | 12.2 能力 trait ∥ ~~12.4 main 拆分~~ ✅ | 12.1/12.3/12.4 均已落地(12.4 **S0–S8 全完成, main.dart 48 行**); 只剩 **12.2 god trait 未拆** |
| 零散 | 12.5 / 12.6 | 随时可搭车, 都是一天内 |

每波收口由编排者**独立重跑**(数字现算, 勿抄): `cargo test` · `cargo clippy` 0 · `dart analyze` 0 · `flutter test` · `api-coverage` · `write-guard` OK; 权威值见 `PROGRESS.md` 头部「当前门禁」表。

## 13. 平台层审计剩余项(2026-11-16 登记 · 只登记不排期)

> 来源: `.pi/plans/arch-audit-platform-2026-11-16.md`(22 条: P1×6 / P2×11 / P3×5)。
> **已落 21 条**: P-01..P-22 除下表 P-10 的**真机听感**与 P-11 的第 ③ 项(通知点击需真机)以外全部落地;
> **P-11 的桌面自动化部分 2026-11-18 已补齐**(交互级 X11 断言进入 `tools/smoke-desktop-headless`)。
> **P-18 后半 已完成(2026-11-17)**: application-id 与 AppStream id 统一到
> `io.github.xiaquwan1001.MiniNCM`(`ui/linux/CMakeLists.txt` + `.desktop` 文件名 + `StartupWMClass`
> + metainfo `<launchable>`), 桌面端由 `G_APPLICATION_NON_UNIQUE` 改回**严格单实例**,
> 用户数据目录 `~/.local/share/ncm` → `~/.local/share/io.github.xiaquwan1001.MiniNCM`
> 带**一次性迁移**(幂等; 同设备 rename / 跨设备 copy+校验+rename; 失败回退旧目录;
> 旧目录留 `.migrated` 标记)。迁移口径/四态判据/降级步骤见 `.pi/memory/notes-build.md` 与
> `core/crates/ncm-service/src/fsutil.rs` 模块注释; `$NCM_DATA_DIR` 显式指定时不迁移。
> 2026-11-17 复核时又订正了两条早已完成的：
> - **P-12** 已随 P-01/P-02 批落地(`b6281b8`, `PlaybackService.kt:92` `setSessionActivity(openAppPendingIntent())`), 不再排。
> - **P-22** cleartext 白名单 `6a3ea6f` 已合入 main(2026-11-16, `res/xml/network_security_config.xml` + manifest
>   改 `android:networkSecurityConfig`, 不再有全局 `usesCleartextTraffic`) ⇒ 原「在飞/未提交」记载**作废(2026-11-16)**。
> - **P-05 长尾**(EQ 三端共享 fixture)也已落地 `7274fcf`(2026-11-16): 同一份
>   `ui/test/fixtures/eq_profile_cases.json` 被 Rust(`ncm-domain/src/eq_profile.rs:435` `include_str!`)、
>   Dart(`ui/test/eq_profile_fixture_test.dart`)、Kotlin(`EqProfileParserFixtureTest.kt`, 已进 `android-unit` 门)
>   三边读取 ⇒ 原「待办」记载**作废(2026-11-16)**。
> 下表只写「为什么没做 / 触发条件 / 预计工作量」; 方案原文在审计文件里, 不在此复制。

> **P-11 第一步已落(2026-11-17)**: 仓库有了首个 instrumented 设施 ——
> `ui/android/app/src/androidTest/kotlin/com/minincm/minincm/NotificationSlotsTest.kt`(3 例: 通知渠道 importance /
> action 槽位 = 上一首→播放暂停→下一首→喜欢→播放顺序 + `compactActions` / 喜欢·模式状态回推) +
> `tools/devui/notif-slots`(解析 `dumpsys notification --noredact` 的 `NotificationRecord` 排版, PASS/FAIL,
> 带离线样例自测) + `tools/devui/androidtest`(`connectedDebugAndroidTest` 的设备守卫: 只允许 `emulator-*`)。
> 观察口径: 断言对象是 Media3 用生产 `mediaButtonPreferences` 拼出的 Notification, 不是常量表。
> **该批未实跑**(开工时无模拟器), 编译门 `compileDebugAndroidTestKotlin` + `testDebugUnitTest` 已绿。

| 项 | 为什么没做 | 触发条件(什么时候做) | 预计工作量 |
|---|---|---|---|
| **P-11 完整版** · 桌面自动化(**Android instrumented** 第一步 2026-11-17 已落, 设备级门已接 ci-gates · **桌面交互级断言 2026-11-18 已落**) | 审计只给方向(纯函数抽测 / Kotlin JVM 单测 / adb 断言), 要新建设备无关测试设施; 现状 `ui/android/app/src/` 只有 `main`/`debug`/`profile` + 刚建的 `test/`(只有 EQ 夹具一个类), **无 `androidTest/`**; `tools/devui` 只有截图/点击脚本, 没有通知槽位断言。审计里的 6 条 P1 已全部修完并真机验过 ⇒ 紧急度下降 | ① 下一次动 `PlaybackService` 的通知/按钮槽位; ② 或再出现「只有真机能发现」的回归(参照 P-01/P-02 那一类) | ~~M~~ ⇒ **只剩 ③**: ① ~~接进 `ci-gates.sh`~~ ✅(2026-11-17: `android-instrumented` 子命令, 无模拟器 SKIP, `NCM_INSTRUMENTED=1` 才进 verify, a34 实跑 3/3); ② 桌面(Linux)自动化 ✅(2026-11-17 起步 + **2026-11-18 交互级**: `tools/smoke-desktop-headless` 第 ⑧ 段真的注入 X11 输入 —— windowfocus 回读 · XTEST space/Tab/space/Escape · 播放条 4 次点击 · 缩窗 640x480/320x240/还原, 每步断言存活 + 几何/标题/Map State 不变 + 主窗口仍 1 个 + 日志无崩溃痕迹; 实测 PASS 26 项 / 61s); ③ 通知**点击**行为仍靠真机冒烟。**已知边界**: xvfb 无 WM 时看不到 Dart 层状态(语义树空/标题是编译期常量) ⇒ 「空格真的切了播放」需 app 侧埋点(debug 日志 / `--e2e` 通道)才能断言, 属后续立项 |
| **P-05 长尾** · EQ 三份解析共享 fixture | 立即项(失败回显 `eqApplied`)已在 v0.16.0 落地; 中期项要把同一段 AutoEQ 文本当 fixture, 让 Dart/Kotlin/Rust 各断言系数与错误行号, 三端各需一套夹具读取器 | ① 再改任一份 EQ 解析(单位大小写 / `Preamp` 缺省 / `ON`-`OFF` 变体); ② 或出现「曲线看着在跑但没生效」的反馈 | S–M(≈ 半天~1 天, 纯测试, 不动产品代码) |
| ~~**P-10 方案 B** · pending_seek~~ ✅ **已全部落地(2026-11-17 引擎 + 2026-11-18 UI 面)** | 已做: 渐进期 seek 登记成待跳(`SeekOutcome::Queued` + `PlayerState::pending_seek_ms`)、下载完成后**换源重建**可 seek 解码器并跳到待跳位置(25ms 淡入消爆音, 播放/暂停态·音量·EQ·时长沿用)、同一首歌下载完成后不再需要重播一次才能 seek。设计见 `core/crates/ncm-playback/P10-NOTES.md`, 批次记录见 `PROGRESS.md` 2026-11-17 条。**UI 面 2026-11-18**(`fe604e2`): 进度条在渐进期照常可拖(`canSeek` 只看量程)、拇指停在待跳点、信息行前缀「已排队→mm:ss」、真被拒才从 `seek_error` 回传并 toast; `flutter test` 1128→1130 | 遗留(需真人/真机): 真机听感微调(`SWAP_FADE` 常量是否有可闻接缝) | 剩余 ≈ S(真机听感冒烟, **需用户**) |

> 明确不做(审计 §3.3 已判, 不再重提): Kotlin 改从 Rust 拿 EQ 系数(跨 FFI 传数组 + 采样率协商) ·
> 给 Gradle 引 ktlint/detekt 插件 · 把 `APPLICATION_ID` 当**顺手改**(P-18 后半已按「连数据目录迁移/单实例/打包一起做」的口径落地, 见 §13 顶部注记 —— 单独改 id 仍然是禁止项)。
