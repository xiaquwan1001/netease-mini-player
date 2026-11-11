# 剩余待办 · 分批与并行派发规划

> 用途: 后续每轮开工前先在这里选批次, 按「并行矩阵」决定能不能同时派。
> 配套: `docs/api-coverage.md`(接口差集, 用 `bash tools/api-coverage.sh` 复算)、
> `docs/PROGRESS.md`(已落地功能与协议事实)、`.pi/memory/`(踩坑)。
> 口径日期: 2026-11-11。**当前覆盖率 123/123(100%), FFI 导出 146 个其中 4 个无 UI 入口**
> (`cache_stats`/`eq_profile_normalize`/`player_tuning`/`word_lyric_with_fallback`) ——
> 数字一律跑 `bash tools/api-coverage.sh` 复算, 本文件不再维护历史快照(历史数字见 `docs/PROGRESS.md`)。
>
> **当前状态(2026-11-10 收尾)**: 功能批次 Wave 1–9 全部完成、D7(frb 直透 domain) 57/57 关闭、
> 设置项扩充 R1–R7 落地、真机听感验收通过; 发布链路已出**六种分发物**(APK / deb / AppImage / tar.gz / windows setup.exe / windows zip)。
> 历史波次与每批验收证据不再堆在这里 —— 见 `docs/PROGRESS.md`(按日期分小节)与 `docs/archive/`(已完工车道的执行记录)。
>
> **下一轮从哪挑**: 见本文件末尾 **§11 · 待办(2026-11-10 收尾版)**。

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
| ~~**B3 会员只读**~~ ✅已做 | 黑胶会员卡/成长值/本周签到/任务(不碰支付) | `vip_info_v2` `vip_growthpoint` `vip_sign_info` `vip_tasks` | `vip_overview` 1 个聚合方法(内部 join4) + FFI 1 个 | `vip_page.dart` + `settings_view.dart` 入口 | 已验(a36 登录/未登录) |
| ~~**B4 搜索增强**~~ ✅已做 | 精确实体条/关键词联想/热搜榜 | `search_multimatch` `search_suggest`(web/mobile) `search_hot_detail` | parse 3 + FFI 3 | `search_exact_bar.dart`(新) + `search_suggest.dart` + 落地页热榜 | 已验(a36) |

## B4 搜索增强 · 预研结论(2026-11-07, 实测)

完整实测记录与响应样例见 [`docs/b4-search-notes.md`](b4-search-notes.md)。要点:

- **`search_multimatch` 不是多类型匹配的数据源**: 它只回 1 条"精确实体改写"(歌手/歌单/电台),
  且 `晴天`/`Taylor`/`Chinese Football` 全返回 `{"code":200,"result":{"orders":[]}}` ——
  **空命中伪装成成功**, 必须按 `orders.is_empty()` 判空; `type` 参数实测无效。
- **多类型联想用 `search_suggest`**: web 版(`/api/search/suggest/web`)返回 songs/artists/albums/playlists
  实体卡片(现有 `parse_suggest` 已经在吃这个); mobile 版(`type=mobile`)只回 6 条纯关键词串, 适合下拉候选。
- **`search_hot_detail` / `search_match` 无法实测**: CLI 的 raw 分支没有对应 arm(会落 `unknown raw method`),
  vendor 里实现都在; 要用先给 CLI 加接线。`search_match` 语义是"本地文件→线上歌曲匹配", 与 B4 无关, 建议排除。
- `search_hot` 固定 10 条、无 rank/score; `search_default`(`/api/search/defaultkeyword/get`)顶层用 `data` 而非 `result`。
- CLI 的 raw 子命令参数是**位置参数 `key=value`**, 不是 `--param key=value`。

| ~~**B8 等级/勋章**~~ ✅已做 | 等级进度 + 勋章墙 | `user_level` `user_medal` | parse 2 + FFI 2(勋章接口有界重试) | `medal_wall.dart`(新) + `mine_view.dart` 入口 | 已验(a36) |

### M 级 · 要新交互/新页面/vendor 有限制(1 轮 1 个, 1~2 天量)

| 批次 | 目标 | 接口 | 风险点 |
|---|---|---|---|
| ~~**B5 逐字歌词**~~ ✅ 已完成(契约层+UI 车道) | 歌词页逐字高亮 | `lyric_new`(已接) `song_lyrics_mark*`(只读 dump, 写不接) | 契约层已合入；**ytlrc/yromalrc 实测恒空** ⇒ 翻译只能行级; 老歌无 yrc 必须回落 |
| **B6 榜单 v2** | 「更新 N 首」/歌手榜细分 | `toplist` `toplist_detail_v2` `toplist_artist` | ROI 低, 现有 detail 已够用 |
| **B7 歌单细分编辑** | 私密切换/标签/排序/换封面 | `playlist_privacy` `playlist_order_update` `playlist_tags_update` `playlist_cover_update` | **vendor 把 privacy 写死 0**; 其余要自己拼请求或上传 |
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

## 4. B0 · 纯 Dart 收尾批(任何轮次都能搭车)

不新增接口, 只把「已接后端但 UI 没入口」补齐, 是唯一可以随时和 Rust 批并行的车道:

- `lyric_lines` / `lyric` 纯文本歌词的备用展示;
- `podcast_program` / `podcast_radio` 详情刷新(列表已有数据, 详情页未刷新);
- `follow_counts` 关注/取关后的资料卡数字刷新;
- 删除 `search` 导出(需 codegen → 归到下一次 Rust 批的 codegen 窗口, 不单独做);
- 纯 UI/测试打磨: 窄屏(vivo 768dpi)+大字号回归、空态/错误态文案、`ui/test` 补例。

文件白名单: `ui/lib/src/{lyric,podcast,profile_header,detail_page}.dart` + `ui/test/*`。
禁止碰: `netease.rs` `ncm-provider` `ncm-ffi` `ui/lib/src/rust/*`。

## 5. 推荐波次(pipeline)

```
Wave 1:  [Rust] B1 消息增强            ｜ [Dart] B0 收尾(lyric/podcast/profile_header)
Wave 2:  [Rust] B3 会员只读            ｜ [Dart] B1 的 UI 集成与测试(等 codegen 合入)
Wave 3:  [Rust] B4 搜索增强            ｜ [Dart] B3 的 UI 集成
Wave 4:  [Rust] B5 逐字歌词(可选)      ｜ [Dart] B4 的 UI 集成
Wave 5:  B2/B8 这类小批可插空; 或转 M 级 B7/B10/B12
```

规则:
1. 每波结束由**编排者**收口: `bash tools/ci.sh` → 模拟器走查(a34/a36 可分工并行, 同一功能只需一台) → 更新 docs + memory → commit。
2. 同一波内 Rust 批先落 **DTO + provider + FFI + codegen**(schema 先行), Dart 批只依赖已定稿 DTO。
3. 不允许 Dart 批直接改 `ui/lib/src/rust/*`(那是生成物, 会被下次 codegen 覆盖)。

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
> 模型写真实 `provider/id`(如 `ustc-pool/ustc-worker`), 不用别名; `tools` 必须显式列出。

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

## 9. 精简项排队(2026-11-09 审计产出, 按依赖顺序)

> 来源: `docs/api-overlap-audit.md`(D1–D7) + `docs/backend-service-options.md` §3/§5.5(P1/P2)。
> 硬约束: **codegen 是全局串行点, cargo 共用 `core/target`** ⇒ 下列批次互斥, 一律串行。

| 序 | 批次 | 内容 | 触碰面 | 前提 |
|---|---|---|---|---|
| 1 | ~~**P1+P2 vendor 裁剪**~~ ✅ **已完成**(2026-11-09) | 删 264 个未接 endpoint + `api/mod.rs` 清单 + tokio 移除 + 死特性 `server` 删除; 382→118/12k→4.1k 行/冷编 1.40→0.65 s/119 测试全绿 | `core/vendor` | 见 `docs/backend-prune.md` |
| 2+3 | ~~**D1+D2 删死导出 + D5 转发宏**~~ ✅ **已完成**(2026-11-09) | 导出 125→123、「UI 无入口」3→0; `ffi_forward!` 宏收敛 22 封装, 净 −80 行 | `ncm-ffi` + codegen(已用一次) | 见 `docs/archive/ffi-cleanup-d1d2d5.md` |
| 4 | ~~**D6 PagedListView**~~ ✅ **已完成**(2026-11-09, 后续又补迁 3 页) | 新组件 + 迁移 7 页(messages/user_list/playlist_square/ranking/new_release/all_charts/digital_album); **仍可迁**: `radio_explore_page`、`style_page`(均未用组件) | 纯 Dart | 见 `docs/archive/ui-batch-d6.md` |
| 5 | ~~**D7 frb 透传 domain**~~ ✅ **已完成**(2026-11-09, 57/57) | 删 74 个 Dto struct(`api.rs`)≈646 行 + 内联转换 ~400 行 | `ncm-domain` + `ncm-ffi` + Dart | 见 `docs/d7-frb-domain.md`; 车道已关闭 |
| — | ~~方案 c: 换 `netease-music`~~ | ⛔ 已裁决不切 | — | 见 `docs/backend-service-options.md` §6 门槛 |

**决策记录(2026-11-09, 用户已批准)**:
- **D7 批准做, 记为待办**(不做前置条件, 但要等 1–4 收口, 单独一波), 验收口径见下 §9.1。
- **D1/D2 直接删, 不留 release 周期**(两个都是零调用死导出, provider/CLI 侧不受影响)。
- 顺序不变: 1 → 2+3(含 D1/D2) → 4(可与 2+3 同波) → 5(D7)。

### 9.1 D7 待办卡(frb 直接透传 domain DTO) —— ✅ 已完成(2026-11-09, 57/57 直透)

> 以下保留为验收口径留痕; 实际收口记录见 `docs/d7-frb-domain.md`。

- **目标**: 删掉 `ncm-ffi/src/api.rs` 里 74 个重复的 `*Dto` struct(≈646 行)及其内联转换(~400 行),
  让 frb 直接暴露 `ncm-domain` 类型; `ui/lib/src/rust/` 由 codegen 重新生成。
- **前置**: ①P1 vendor 裁剪已合; ②D1/D2/D5 已合(减少 codegen 冲突面);
  ③`ncm-domain` 加 frb 注解前先确认它仍是**纯数据 crate**(不得引入 flutter_rust_bridge 之外的运行时依赖)。
- **契约要求**: domain 类型需实现 frb 可见的形态(字段 `pub` + `#[frb]`/mirror 宏策略二选一, 开工前先做 10 行 spike 决定走 mirror 还是直接注注解)。
- **门禁(编排者自己跑, 不信 worker)**: `cargo build --offline --workspace` 0 error;
  `cargo test -p ncm-domain -p ncm-service` 全绿; `dart analyze` 0 error;
  `flutter test` 全量绿(离线口径当时 235+, 2026-11-10 复核 **504**); `bash tools/api-coverage.sh` = 118/0、无 UI 入口 3(`cache_stats`/`eq_profile_normalize`/`player_tuning`);
  双端构建 + 模拟器走查(空态/未登录各一次)。
- **回滚**: `git restore --staged --worktree core/crates/ncm-domain core/crates/ncm-ffi ui/lib/src/rust` 一键还原。
- **收益**: 合计约 1400–1800 行(含保守项), 且以后新增接口不再重复定义三层 DTO。

## 10. UI/UX 走查批次(A–D, 2026-11-09 审计产出)

> 来源 `docs/ui-ux-audit.md`(506 行, 每条带 file:line)。P0=3 / P1=15 / P2=13。
> **验证口径**: 这些批次**不要**用 `build-android`/`ci.sh` 验证 UI —— 用 `flutter test test/xxx.dart` 单文件
> + 设备走查; 且 A 批的 `PopScope` 改动**必须配一条 widget 测试**(返回键三次: 歌词→tab→退出), 否则后续易回退。

| 批次 | 内容 | 对应条目 | 成本 | 并行性 |
|---|---|---|---|---|
| ~~**A · S 速修**~~ ✅ **已完成**(2026-11-09) | 返回键 `PopScope` 三级语义 + `formatSongDuration` + 红心可点 + 6 类控件 48dp + 出口文案统一「全部」; 新增 22 用例 | P0-7.1 + P1-7.4/7.6/7.7/7.12/7.13/7.17 | ~~S~~ 已做 | 见 `docs/archive/ui-batch-a.md` |
| ~~**B · 两个新面板**~~ ✅ **已完成**(2026-11-09) | 评论输入(`_ComposeSheet` + `viewInsets` 避让 + 失败保草稿)、队列面板(`PlayQueueSheet` + `removeAt`/`moveTo` + 8 条单测); 新增 18 用例 | P0-7.2 / P0-7.3 | ~~M~~ 已做 | 见 `docs/archive/ui-batch-b.md` |
| ~~**B2 · B 的遗留**~~ ✅ 已完成(2026-11-10) | ①~~`showCommentsSheet` 缺 `viewInsets` padding~~ ✅ 已修(76c3399 + `ui_batch_b2_keyboard_test.dart`) ②~~`moveTo` 已就绪未接拖拽排序 UI~~ ✅ 已接(`PlayQueueSheet` 改 `ReorderableListView` + 拖拽手柄, 宿主 `_moveInQueue`) ③~~`PlayQueueSheet` 拆到独立文件~~ ✅ 已拆 ④~~面板「清空」~~ ✅ 已做(`delete_sweep` + 二次确认 + 清空即停播); ④~~面板「存为歌单」~~ ✅ 已做(2026-11-10 第三批: `create_playlist(name,privacy)` + 批量 `playlist_tracks_add` + 选歌单/新建对话框, 模拟器服务端复核 2 首) | B 遗留 | ~~S~~ 已做 | 见 `docs/PROGRESS.md` 末节; 新增 3 例 widget 测试 |
| **⚠ 发布前硬门(写接口)** | 评论发送走 `rust.replyComment`(commentId=0)是**真实写操作**: 必须用测试号 + a34/a36 走查一次(发送/失败/回滚), 且确认不在 CI 里触网 | 安全 | S | 不做不得发版 |
| ~~**C · 信息架构重排**~~ ✅ **已完成**(2026-11-09) | 设置瘦身 + 2 个二级页、账号入口 3→1、推荐页首屏 8→5、专辑 Dialog→全页、日推/最近听过 sheet→全页; 新增 11 条可达性用例 | 见 `docs/archive/ui-batch-c.md` | ~~M~~ 已做 | **视觉待人工过目**: 账号页层级/新歌新碟合并块/风格 chips 归属/全页 AppBar+TabBar 高度/设置页密度/我的页会员行位置 |
| **C2 · C 的遗留** | ①~~清空搜索历史缺二次确认~~ ✅ 已修(`search_landing.dart:35-43` AlertDialog + `ui/test/c2_clear_history_confirm_test.dart`) ②若要全局账号入口恢复, 加一行即可 ③推荐播客仍在第 2 屏(审计 §5.5 有意保留) | C 遗留 | S | ①已完成 |
| **D · 技术债收敛** | 抽 `fmtDuration`/`error_views`/`showToast`、弹层统一 `SheetHeader`+`showDragHandle`、删 `podcast.dart` 的半死入口(实测非整文件: 仅 `showPodcastSheet`+`_PodcastBrowser*` ≈88 行零生产调用, 且被 10 处测试当宿主, 需同步改写 ⇒ 未做)、补 300dp+1.25 回归到剩余 30 个测试文件 | P2 全部 + P1-7.15/7.16/7.18 | M | 纯重构, 可与 C 并行但**不要同时改同一文件** |

**与 §9 的互斥关系**: A–D 全是纯 Dart 车道, 与 §9 的 Rust/codegen 批次(2/3/5)**可并行**; 但 A/B/C/D 之间按上表错序。


## 11. 待办(2026-11-10 收尾版)

> 这一节是"下一轮从哪挑"的唯一入口; 上面 §2–§10 是历史分批口径, 已完成项保留作决策留痕。
> 当前基线: 覆盖率 123/123 · FFI **146**(4 个无 UI 入口) · `cargo test --offline --workspace` **254** ·
> `flutter test --exclude-tags network` **570** · `dart analyze` 0 error / 0 warning(41 info)。
>
> **新增待办(2026-11-10 五批产出)**: ①桌面扫码登录需**真机扫一次**确认(803 端到端, 现在只验到 801 与单测);
> ②Windows 端扫码登录冒烟(同一份 Rust 链路, 本机编不了); ③deb 的 AppStream 预览需在 GNOME Software /
> KDE Discover 实机看一眼(元数据已通过 `appstreamcli validate`); ④账号隐私再收一步: `accounts.json` 里的
> `MUSIC_U` 仍是**明文 0600**, 若要上"系统钥匙串"(Linux secret-service / Windows DPAPI)需单独立项。

### A. 最近三批已完成(供对照, 不要重做)

| 批次 | 内容 | 证据 |
|---|---|---|
| v0.3.x 桌面打包 | deb / AppImage / Windows setup.exe + `release.yml` 四 job 收口(verify → build + build-windows → publish) | Release v0.3.2 六种资产; `packaging/` |
| 歌单写接口 | `create_playlist(name,privacy)` + 批量 `playlist_tracks_add` + 队列「存为歌单」 | `docs/b7-playlist-write-notes.md`; 模拟器服务端复核 |
| 图片清晰度 | 按设备像素取图 + 三档设置 + 看大图保存原图 | `ui/test/cover_quality_test.dart` 12 例; 模拟器落盘核对 |

### B. 纯 Dart 车道(可与任何 Rust 批并行)

| 序 | 项 | 说明 | 成本 |
|---|---|---|---|
| ~~1~~ | ~~**主播/听众 → 用户主页路由**~~ ✅ **已完成**(2026-11-10 六) | 新增 `user_page.dart`(资料卡 + 公开歌单, 点歌单可播) + `Provider::user_profile`/`user_playlists_of`(匿名可用) + 听众/粉丝行接通; 见 `docs/PROGRESS.md` 最新小节 | ~~S~~ 已做 |
| 2 | **D 批技术债** | 抽 `fmtDuration`/`error_views`/`showToast`、弹层统一 `SheetHeader`+`showDragHandle`、`podcast.dart` 半死入口(≈88 行, 被 10 处测试当宿主)、300dp+1.25 回归补到剩余 30 个测试文件 | M |
| ~~3~~ | ~~视觉待人工过目~~ → 2026-11-11 已按反馈改掉: 楼层内联预览 + 动态流行内赞/评论/分享 + 发评论后回填定位 | 需求已实现, 视觉仍可人眼扫一眼 |
| 3 | 视觉待人工过目 | C 批遗留: 账号页层级 / 新歌新碟合并块 / 风格 chips 归属 / 全页 AppBar+TabBar 高度 / 设置页密度 / 我的页会员行位置 | S(需人眼) |
| ~~4~~ | ~~发布包体积实测~~ ✅ **已完成**(2026-11-10 六) | 结论在 `docs/backend-service-options.md` **附录 B**: 下载 vs 首装体积 + bundle 逐文件拆解 + strip 机会(15→9 MB) | ~~S~~ 已做 |

### C. 发布/打包跟进(小改, 可攒一起发)

| 序 | 项 | 说明 |
|---|---|---|
| 0 | ~~桌面登录只能导 cookie~~ ✅ **已修**(2026-11-10 五) | 桌面端改走官方网页**扫码**登录(`Provider::login_qr_*` + `login_sheet.dart`), 不再需要命令行; 见 `docs/PROGRESS.md` 最新小节 |
| 0 | ~~deb 预览显示 minincm 且无图标~~ ✅ **已修**(2026-11-10 五) | 补 AppStream `metainfo.xml` + `/usr/share/pixmaps` 图标, `appstreamcli validate` 通过 |
| 0 | ~~未登录时占位显示上次账号的昵称/VIP~~ ✅ **已修**(2026-11-10 五) | 未登录一律不渲染 VIP 标 + 新增「清除本机登录凭据」+ 启动时按 `[auth]` 校验登录态 |
| 1 | **评论发送写操作走查(发布前硬门)** —— 读数侧已备(回复归属 `replied_to`/`parent_id`, 2026-11-11), 只剩一次真实回复写操作确认服务端是否认 `commentId` | `rust.replyComment`(commentId=0) 是真实写操作: 测试号 + 模拟器各走一次发送/失败/回滚; 确认 CI 不触网 |
| 2 | Windows 安装向导中文化 | 需要把官方 `ChineseSimplified.isl` 一起放进 `packaging/windows/`(Inno 安装包不自带, v0.3.1 因此编译失败过) |
| 3 | deb 依赖收紧 | 目前 `libgtk-3-0/liblzma5/libasound2`, 未在最小系统(纯 server + desktop 环境)验证过; 有条件时用容器验一次 |
| 4 | AppImage 桌面集成 | 首启提示"是否集成到应用菜单"(需 `desktop-file-install` 逻辑, 可选) |

### C'. 2026-11-11 已完成

| 项 | 说明 | 证据 |
|---|---|---|
| **手机号 + 短信验证码登录** | 登录弹层第 2 个 tab + `ncm login-sms`; 走**网页登录通道**(weapi `sms/captcha/sent` + `login/cellphone`), 凭据取自 Set-Cookie; 命中 8821 时提示改回扫码; 400→Auth、503→可重试 | `ui/test/login_sheet_phone_test.dart` 4 例 + `login_sheet_error_test.dart` 4 例(错误文案归一); 宿主实测非法号码 `code=400: 手机号码不符合规范`; FFI 144→146 |
| **待真机验(唯一残留)** | 真实手机号收短信走完正常登录链路(本机只验到通道可达与错误映射) | 需用户用自己的号码操作一次 |

### D. 需要新能力的 L 级(单独立项, 不要混批)

B9 视频/最近播放页签(需视频播放器) · B11 听歌识曲(录音 + 指纹) · B13 云盘(分片上传) ·
B14 MV 列表页/视频详情(播放器已有) · B15 一起听(房间 + 心跳, 需双端联调) · B16 动态发送(发包 + 审核语义) ·
B17 云贝任务(兑换类不碰) · 音源插件化(QuickJS 宿主 + lx 兼容层, 设计边界见 `docs/architecture-restart.md`)。

### E. 明确不做

App 原生登录族(eapi, 8821 风控) —— **网页登录族**的手机号+验证码登录已在 2026-11-11 落地, 两者不是一回事 · 埋点上报 · 内部灰度与算法向量 · 支付与兑换 · 创作者中心与粉丝中心 · 账号安全改绑 ·
`simi_user`(实测恒空)。

