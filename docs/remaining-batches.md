# 剩余待办 · 分批与并行派发规划

> 用途: 后续每轮开工前先在这里选批次, 按「并行矩阵」决定能不能同时派。
> 配套: `docs/api-coverage.md`(接口差集, 用 `bash tools/api-coverage.sh` 复算)、
> `docs/PROGRESS.md`(已落地功能与协议事实)、`docs/archive/remaining-batches-history.md`(历史分批口径)。
>
> 口径日期: **2026-11-13**。覆盖率 **123/123(100%)**, FFI 导出 **150** 个, 其中 5 个无 UI 入口
> (`cache_stats`/`consent_plaintext_storage`/`eq_profile_normalize`/`player_tuning`/`word_lyric_with_fallback`);
> 数字一律跑 `bash tools/api-coverage.sh` 复算。
>
> **当前状态**: 功能批次 Wave 1–9 全部完成、D7(frb 直透 domain) 57/57 关闭、技术债 D 批收口、
> 设置项扩充 R1–R7 落地、真机听感验收通过; 三端分发六种产物 + arm64 腿, 当前版本 **v0.7.1**。
>
> **下一轮从哪挑**: 见本文件末尾 **§11 · 待办(2026-11-13 更新)**。

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

## 11. 待办(2026-11-13 更新)

> 这一节是「下一轮从哪挑」的**唯一入口**; §2–§3、§6–§8 是批次目录与派发流程, 历史口径见
> `docs/archive/remaining-batches-history.md`。
> 当前基线(2026-11-13 本机实测, 离线口径): 覆盖率 **123/123** · `cargo test` **271** · `cargo clippy` **0 warning** ·
> `flutter test --exclude-tags network` **674** · `dart analyze` 0 error / 0 warning · write-guard OK。

### A. 只剩这些没做(按成本排序)

| 序 | 项 | 说明 | 成本 |
|---|---|---|---|
| 1 | 视觉人工过目 | 账号页层级 / 新歌新碟合并块 / 风格 chips 归属 / 全页 AppBar+TabBar 高度 / 设置页密度 / 我的页会员行位置 —— v0.7.0–v0.7.1 已按反馈改过一轮, 仍需人眼确认 | S(需人眼) |
| 2 | AppImage 桌面集成 | 首启提示「是否集成到应用菜单」(`desktop-file-install` 逻辑, 可选) | S |
| 3 | deb 运行期最小桌面冒烟 | 依赖闭包已静态核查 100% 覆盖; 字体/插件等运行期数据文件仍需真最小桌面点一次 | S |
| 4 | Windows / 桌面扫码登录冒烟 | 同一份 Rust 链路, 本机没有 Windows 桌面, 只能 CI 或用户机验 | S |
| 5 | 桌面 keyring 装包后冒烟 | secret-service 已在真实 D-Bus 下过单测, `.deb`/AppImage 装后未点 | S |

### B. 已完成(供对照, 不要重做)

详细验收证据见 `docs/PROGRESS.md` 对应日期小节; 已完工车道的执行记录见 `docs/archive/`:

- 只读批次 B1–B5 / B8 / B10 / B12 / B13(TTML) 与写接口 B7a(歌单 create / 批量加曲); FFI 清理 D1/D2/D5/D7(frb 直透 domain 57/57)。
- 技术债 D 批(弹层 21/21 统一、格式化去重、podcast 658→190 行、45 文件窄屏回归归零)与视觉批 A–C。
- 手机号+短信验证码登录(用户真机验过)、评论发送写操作走查 + `tools/check-write-guard.sh`。
- 桌面打包四态(deb / AppImage / tar.gz / setup.exe)、Linux arm64 腿、Windows 向导中文化、AppStream 元数据。
- 凭据三端(Android Keystore / Linux secret-service / Windows DPAPI) + 凭据不再过 FFI 回传 Dart。
- v0.6.0–v0.7.1 用户回归四连发(见 `docs/PROGRESS.md`「2026-11-12(晚)」)。

### C. 需要新能力的 L 级(单独立项, 不要混批)

视频/最近播放页页签(需视频播放器) · 听歌识曲(录音 + 指纹) · **云盘**(分片上传; 旧编号 B13 与「B13 逐字歌词 TTML」撞号, 以后只称「云盘」) ·
MV 列表页/视频详情(播放器已有) · 一起听(房间 + 心跳, 需双端联调) · 动态发送(发包 + 审核语义) ·
云贝任务(兑换类不碰) · 音源插件化(QuickJS 宿主 + lx 兼容层, 设计边界见 `docs/architecture-restart.md`)。

### D. 明确不做

App 原生登录族(eapi, 8821 风控) —— **网页登录族**的手机号+验证码登录已在 2026-11-11 落地, 两者不是一回事 ·
埋点上报 · 内部灰度与算法向量 · 支付与兑换 · 创作者中心与粉丝中心 · 账号安全改绑 · `simi_user`(实测恒空)。
