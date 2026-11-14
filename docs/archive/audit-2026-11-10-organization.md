# 项目整理审计 · 2026-11-10(只读调研, 未改任何代码)

> 核实手段: `bash tools/api-coverage.sh`、`cd ui && flutter test --exclude-tags network`、
> `cargo test --offline`、rg/grep 源码、git log。所有数字为 2026-11-10 实测。

**实测基线(所有断言以此为准)**:
- api-coverage: vendor 118 / 已调用 118(100%) / 未接入 0 / **FFI 导出 132** / UI 无入口 **3**(cache_stats·eq_profile_normalize·player_tuning)
- flutter test(排除 network): **351 passed**(+1 skip 需复核)
- 记忆/文档里的旧数字: 90/94/98/99/103/113/114/125/123/47 变体/362/349 均已过期或口径不一

## A. 过期/矛盾断言(逐条: 文件:行 | 现状 | 建议)

| # | 位置 | 问题 | 建议 |
|---|---|---|---|
| A1 | docs/plan-2026-11-09-settings-and-player.md:187-194 | 「### 下一波(未开工)」列 S4/S3/S5/D7批4-7, 但同文件 §10 执行记录(154-183 行)已记录 S4 批1/批2(b3bcf55/f073a9b)、S3(5504fad)、S5a(c6ea894)、D7 已 57/57 关闭(见 246a1be) — 直接自相矛盾 | 改为「~~下一波~~ 已全部完成」或删除该节, 保留指向 §10 |
| A2 | docs/remaining-batches.md:14 | 「Wave 8 进行中(B5 逐字歌词…覆盖 114/382)」与下一行 15「Wave 9 完成…覆盖 118/382」矛盾; B5 已完成(见 docs/b5-word-lyric-notes.md 与 PROGRESS) | 删「进行中」, 改「Wave 8 完成」 |
| A3 | docs/remaining-batches.md:6,9-13 | 头部口径 90/94/98/99/103/113/114/382 一串历史数字, 与文末 196 行及 api-coverage.md 的 118/382 不一致 | 头部只保留一句「当前 118/382, 见 docs/api-coverage.md」, 历史数字留在执行记录里 |
| A4 | backend-service-options.md:16,24,30,31,35,105,141,145,162 | 全文按旧基线 **114/382、删 268 模块、382 个 endpoint 文件**写; 实际 P1+P2 裁剪已落地(2026-11-09): 118/118/0, vendor 12k→4.1k LOC | 顶部加「⚠ 本文写于裁剪前(基线 114/382), 裁剪已于 2026-11-09 落地, 见 backend-prune.md」; §g 候选里的 118/43 落差数字同步复核 |
| A5 | docs/api-coverage.md:3 | 「FFI 125 个里仅剩 3 个无 UI 入口」— 实测 FFI 导出已 **132** | 更新为 132 |
| A6 | docs/archive/ffi-cleanup-d1d2d5.md:45 | 「FFI 导出 123(125→123)」— 实测 132 | 归档说明或在文首标注「数字为当时快照, 现值见 api-coverage.md」 |
| A7 | api-overlap-audit.md:4 | 「FFI 导出 125」同上 | 同 A6 |
| A8 | README.md:17,126 / README.en.md:17,126 / docs/PROGRESS.md:4,46 | 宣称 flutter test **362+1skip**; 实测 `flutter test --exclude-tags network` = **351 passed**(362 只有把 network 标签用例算入才可能, 且离线跑不了) | 改为「351 离线 + N 网络用例(标签 network)」并写明口径; 或本地全量跑一次拿真实数字再填 |

| A9 | docs/PROGRESS.md:4,46 vs :98 | 同一文件内部矛盾: 顶部/46 行写 flutter test 362, §4 收口门(98 行)记录 351+1skip; 实测离线 351 | 统一: 顶部写「351+1skip(离线口径)」 |
| A10 | README.md:17 / README.en.md:17 徽章 | 「Dart 362 + Rust 169」; 实测 Dart 离线 351、Rust 170(32+31+106+1, ncm-provider 也有 1 例) | 改徽章与 126 行表格, 或写明口径来源 |
| A11 | .pi/memory/HINDSIGHT.md:52-54 | 「待办: 设备 cookie 持久化…genDeviceId() 每次随机」— 已过期: core/crates/ncm-service/src/identity.rs:5 注明设备 cookie 与登录 cookie 一起落盘 | 在该条目后补一行「(2026-11-09 已落地, 见 identity.rs)」 |
| A12 | .pi/memory/HINDSIGHT.md:296-297 | 「Gradle release 仍用 debug 签名」— 已过期: c7644d9/dff762b 已落地正式签名机制(同文件 327-342 行已记录) | 给 296 行条目加「已解决」标注 |
| A13 | .pi/memory/HINDSIGHT.md:299-301 | 「--exclude-tags network(349 例)」数字过期(实测 351); setup-android 替代方案已进 68f2cbc | 更新数字 |
| A14 | api-channel.md:32 | 「桌面版(未实现内嵌登录)」表述含糊(Android WebView 登录已实现) | 明确写「Android 已有 WebView 登录, Linux 内嵌登录未做」 |
| A15 | docs/remaining-batches.md:20 | 「newest_albums/toplist_catalog 接上 UI」与 15 行「Wave 9 完成」及 wave9-endpoint-notes.md「已接入(FFI/CLI)」口径打架: 契约层已完成仅 UI 未接 | 改成「契约层已就绪, 仅剩 UI 接入」 |
| A16 | docs/remaining-batches.md:234 | C2①「清空搜索历史缺二次确认」— 已实现: ui/lib/src/search_landing.dart:35-43 AlertDialog + ui/test/c2_clear_history_confirm_test.dart | 划掉①标已完成 |
| A17 | docs/remaining-batches.md:207 | §9.1 D7 待办卡 — D7 已 57/57 关闭(246a1be) | 标记已完成 |

| A18 | docs/remaining-batches.md:216 | 「无 UI 入口 2(删完 D1/D2 后应为 0)」— 实测仍为 3(cache_stats/eq_profile_normalize/player_tuning), 且「应为 0」未发生 | 更新为 3 并列出函数名 |

## B. 闲置与冗余(路径 | 规模 | 动作 | 理由)

| # | 路径 | 规模 | 动作 | 理由 |
|---|---|---|---|---|
| B1 | .pi/trash/files/ncm.1794022613 | 116 MB 二进制 | 删(清空回收站) | 11-07 丢弃的旧构建产物, git 不追踪 |
| B2 | .pi/trash/files/.dartServer.1794037664/ | 缓存目录 | 删 | dart analyzer 缓存无价值 |
| B3 | .pi/trash/files/{_*probe_test,dbg_test}.dart.*、user_medal.json.* | ~4KB ×4 | 删 | 一次性调试探针 |
| B4 | screenshots/ 全部 4 张 | 2.2 MB | 归档或删 | 全仓 0 引用(README 只用 docs/images/): all-charts-detail/all-charts-page/gui-a36-01/newest-albums-tab |
| B5 | docs/archive/ui-batch-b2.md | 31 行 | 合并进 PROGRESS 后删 | 日期占位「2026-xx」没填的一次性修复记录 |
| B6 | docs/archive/ffi-cleanup-d1d2d5.md | 64 行 | 归档 | 车道已收口, 数字已过期(A6) |
| B7 | docs/ui-batch-{a,b,c,d,d6,d6b}.md + archive/ui-song-detail-share.md | ~800 行 | 末尾状态并入 PROGRESS.md 后移 docs/archive/ | 已执行完的车道记录, 与 PROGRESS.md 同事实双写 |
| B8 | backend-service-options.md | 184 行 | 顶部加过时横幅 | 决策已定(不切库、裁剪已落地), 只剩 §6 复测清单有价值 |
| B9 | docs/b8-dumps/*.json | 小 | 保留或移测试 fixture | 若无单测引用, 归入 ui/test/fixtures 更合理 |
| B10 | dist/*.apk + *.tar.gz | 41 MB | 本地可删 | git 不追踪, GitHub Release 已托管正式产物(SHA256SUMS) |
| B11 | docs/plan-2026-11-09-settings-and-player.md | 194 行 | 修 A1 后归档 | 三波全部执行完, 只剩「依赖人耳的 5 条」 |

## C. 计划文件归档建议

| 文件 | 状态 | 建议 |
|---|---|---|
| .pi/plans/2026-11-05-ui-restructure.md | 6 项需求已全部落地(playlist_detail/feed_view/评论/分享等均存在于 ui/lib/src) | 移 .pi/plans/archive/ 或文首加「已完成」 |
| .pi/plans/2026-11-06-feature-pack.md | 文件内自标「2026-11-06 完成·7 项已落地」 | 移 .pi/plans/archive/ |
| .pi/trash/{files,info} | 回收站积压(含 116MB 二进制) | 用户确认后清空 |

## 复核(2026-11-10 第二轮, 主线会话手工核对)

主线已把下列项**实际改掉并提交**(不是建议): A2/A5/A6/A7/A8/A9/A10/A11/A12/A13/A14/A17/A18 以及 B8 的过时横幅;
数字口径统一跑 `bash tools/api-coverage.sh` 复算为 **123/123, FFI 139, 无 UI 入口 4**(新增 `word_lyric_with_fallback`);
测试基线更新为 `cargo test --offline --workspace` **242** / `flutter test --exclude-tags network` **504**(证据 `.pi/artifacts/gates-2026-11-10.md`)。
另补完 B2 遗留(队列面板拖拽排序 + 清空, 提交 `b34bb00`), 并把 `.git` 对象库损坏的恢复过程写进 `.pi/memory/FAILURES.md`。

### 仍待用户确认(不动手删)
| 路径 | 实测 | 建议 |
|---|---|---|
| `dist/MiniNCM-0.1.1-release-signed.apk` | 55 MB, git 未追踪 | 删(Release 已托管正式产物; 但 0.1.1 未发 Release? → 需要你确认是否还留作本地装机包) |
| `docs/ui-batch-{a,b,b2,c,d,d6,d6b}.md` + `archive/ui-song-detail-share.md` + `archive/ffi-cleanup-d1d2d5.md` | 共 ~780 行, 事实与 PROGRESS.md 双写 | 并入 PROGRESS 后移 `docs/archive/`(README/CONTRIBUTING 有 2 处引用需同步改链) |
| `docs/b8-dumps/` | 120 KB(README + 2 个 json 样例) | 保留(是勋章接口形状的唯一留痕, 无测试引用) |
| `~/netease-mini-player-git-bak-20261110` | 26 MB, 仓外 | 确认仓库无恙后删 |
| `.pi/trash/` | 4 KB | 空壳, 可删 |

`screenshots/`(B4)与 `.pi/trash` 里 116 MB 旧产物(B1/B2/B3)在本轮之前已被清掉, 无需再处理。

