# docs/archive —— 已完工车道的执行记录

这里的文档都是**已完成批次的过程记录**（现状与结论已并入 [`../PROGRESS.md`](../PROGRESS.md)），
保留是为了查"当时怎么验的、踩了什么坑"，不再随代码更新。新批次请只写 PROGRESS 的小节。

| 文件 | 内容 | 状态 |
|---|---|---|
| [ui-batch-a.md](ui-batch-a.md) | UI/UX 审计 A 批：返回键三级语义 / 时长格式 / 红心可点 / 48dp | ✅ 已完成(2026-11-09) |
| [ui-batch-b.md](ui-batch-b.md) | B 批：评论输入面板 + 播放队列面板 | ✅ |
| [ui-batch-b2.md](ui-batch-b2.md) | B2：评论面板键盘避让（后续的队列拖拽排序/清空见 PROGRESS 2026-11-10 小节） | ✅ |
| [ui-batch-c.md](ui-batch-c.md) | C 批：信息架构重排（设置瘦身 / 账号入口 3→1 / 专辑 Dialog→全页） | ✅ |
| [ui-batch-d.md](ui-batch-d.md) | D 批：技术债收敛的一部分 | ✅ |
| [ui-batch-d6.md](ui-batch-d6.md) / [ui-batch-d6b.md](ui-batch-d6b.md) | D6：PagedListView 抽取与迁移 | ✅ |
| [ui-song-detail-share.md](ui-song-detail-share.md) | 播放条合并 + 歌曲详情页 + 分享卡片 | ✅ |
| [PROGRESS-v1.md](PROGRESS-v1.md) | v1(WebView 版)阶段进度记录, 从 PROGRESS 拆出归档 | 📦 归档(2026-11-13) |
| [remaining-batches-history.md](remaining-batches-history.md) | 待办规划历史口径: B0 收尾批 / 推荐波次 / 精简项排队 / UI 走查批 A–D / §11.A-1 2026-11-14 反馈批 | 📦 归档(2026-11-17) |
| [PROGRESS-2026-11-13-11-19.md](PROGRESS-2026-11-13-11-19.md) | v0.8.0–v0.19.0 的按日批次明细(S 级拆壳各步 / 平台层审计落地 / 列表行 B+C 级 / 各用户反馈批), 从 PROGRESS 迁出 | 📦 归档(2026-11-17) |
| [DOCS-REPORT-2026-11-10.md](DOCS-REPORT-2026-11-10.md) | 文档整理子代理的一次性报告（**数字为当时快照**：248/522，现值见 PROGRESS 头部） | 📦 归档(2026-11-11) |
| [ffi-cleanup-d1d2d5.md](ffi-cleanup-d1d2d5.md) | D1/D2/D5：删死导出 + `ffi_forward!` 宏收敛（**数字为当时快照**：导出 123；现值见 api-coverage.md） | ✅ |
| [plans-2026-11/](plans-2026-11/README.md) | 2026-11-13 ~ 11-19 的 31 份车道任务书/执行记录(原本地 `.pi/plans/`, gitignore), 每份对到落地提交; 含 `HANDOFF-2026-11-19.md`(**已作废**)与 4 份只读审计 | 📦 归档(2026-11-19) |

## 2026-11-17 归档批次(PROGRESS 第二次拆分)

`docs/PROGRESS.md` 从 1212 行压到 517 行: v0.19.0 及更早的按日批次(2026-11-13 ~ 11-16)整段迁出,
主文件只留 **v0.20.0 起**的活跃批次(版本时间线表仍覆盖 v0.8.0 起全部版本)。

| 旧路径 | 新路径 | 归档理由 |
|---|---|---|
| docs/PROGRESS.md §「2026-11-16(日) 收尾批 v0.19.0」…「2026-11-13 结构性债务第 1 波」 | [PROGRESS-2026-11-13-11-19.md](PROGRESS-2026-11-13-11-19.md) | 活跃批次只保留 v0.20.0 起; 旧批次明细不再随开发更新, 一行摘要留在版本时间线表。**归档** |

## 2026-11-15 归档批次(PROGRESS 拆分)

`docs/PROGRESS.md` 从 1656 行压到 517 行: 2026-11-12 及更早的按日批次(60 个 `##` 小节)与
「专题小节」(歌词打分择优 / 自动更新 / arm64 CI / Keystore 通道层 / 启动 3s 归因等)整段迁出。
结论层早已在 `.pi/memory/`(`notes-build.md` / `notes-api.md` / `notes-ui-rules.md`), 这里只留"当时怎么验的"。

| 旧路径 | 新路径 | 归档理由 |
|---|---|---|
| docs/PROGRESS.md §「2026-11-12(晚)」…「v2 重启(2026-11-03)」+「专题小节」 | [PROGRESS-2026-11-03-11-12.md](PROGRESS-2026-11-03-11-12.md) | 活跃时间线只保留 v0.8.0 起; 早期批次与专题小节不再随开发更新。**归档** |

## 2026-11-14 归档批次(从 `docs/` 根目录迁入)

这一批的共同点: 工作已完工/结论已定, 且其中可执行的部分**已并入 [`../PROGRESS.md`](../PROGRESS.md) 或 `.pi/memory/`**。
迁移用 `git mv`, 历史链接按"旧路径 → 新路径"对照解析(旧路径 = `docs/<文件名>`)。

| 旧路径 | 新路径 | 归档理由 |
|---|---|---|
| docs/architecture-restart.md | [architecture-restart.md](architecture-restart.md) | 2026-11-03 架构选型与决策记录; 决策早已落地(三端现状注记见 PROGRESS)。**归档(决策留痕)** |
| docs/m0-plan.md | [m0-plan.md](m0-plan.md) | M0 基建周清单, 全部完成。**归档** |
| docs/build-vs-fork.md | [build-vs-fork.md](build-vs-fork.md) | 2026-10-31 fork/PR/自建真机实测对比, 结论(只对 Melodia 提 PR)已执行。**归档** |
| docs/community-projects.md | [community-projects.md](community-projects.md) | 2026-10-31 社区项目盘点与路线选择; 已被架构重启取代。**归档** |
| docs/backend-service-options.md | [backend-service-options.md](backend-service-options.md) | 后端形态调研; 结论"不换形态、只裁剪"已落地。**归档** |
| docs/backend-prune.md | [backend-prune.md](backend-prune.md) | vendor 裁剪执行记录(382→118 endpoint, 12k→4k LOC), 已落地验收。**归档** |
| docs/api-overlap-audit.md | [api-overlap-audit.md](api-overlap-audit.md) | D1–D7 重叠审计, 全部执行完(方案 c 已裁决不切)。**归档** |
| docs/d7-frb-domain.md | [d7-frb-domain.md](d7-frb-domain.md) | D7 frb 直透 domain 车道日志, 57/57 收口、车道已关。**归档** |
| docs/audit-2026-11-10-organization.md | [audit-2026-11-10-organization.md](audit-2026-11-10-organization.md) | 2026-11-10 文档/代码整理审计, 条目已逐条处理。**归档** |
| docs/ui-ux-audit.md | [ui-ux-audit.md](ui-ux-audit.md) | UI/UX 走查(P0 3 / P1 15 / P2 13); P0/P1 已修, 余项在 ui-row-audit.md 与 batches 里跟。**归档** |
| docs/research-2026-11-10-lyric-and-color.md | [research-2026-11-10-lyric-and-color.md](research-2026-11-10-lyric-and-color.md) | 歌词跟随与封面取色调研, 已落地(算法思想移植)。**归档** |
| docs/license-agpl-evaluation.md | [license-agpl-evaluation.md](license-agpl-evaluation.md) | MIT vs AGPL 评估, 结论"保持 MIT"已执行。**归档** |
| docs/api-channel.md | [api-channel.md](api-channel.md) | interface vs interface3 通道实测, 结论"保持库默认 App 形态"已定。**归档** |

## 2026-11-19 归档批次(docs 根目录收口)

| 旧路径 | 新路径 | 归档理由 |
|---|---|---|
| docs/plan-2026-11-09-settings-and-player.md | [plan-2026-11-09-settings-and-player.md](plan-2026-11-09-settings-and-player.md) | 7 项全部验收; 行号口径已失效。代码注释里的路径同步改指本目录 |
| docs/credential-storage-options.md | [credential-storage-options.md](credential-storage-options.md) | 决策已固化在 `.pi/memory/notes-credentials.md`, 本文留调研过程 |
| docs/ui-row-audit.md | [ui-row-audit.md](ui-row-audit.md) | A/B/C 三级全部清零, 结论已进 `.pi/memory/notes-ui-rules.md` |
| docs/lx-plugin.md | [lx-plugin.md](lx-plugin.md) | 未落地设计稿 + 面向外部项目 Melodia, **加作废 banner** |
| docs/melodia-pr-workflow.md | [melodia-pr-workflow.md](melodia-pr-workflow.md) | 外部项目流程, 与本仓重启后的工程无关, **加作废 banner** |
| `.pi/plans/*.md`(31 份, gitignore) | [plans-2026-11/](plans-2026-11/README.md) | 车道任务书全部已落地, 整批留档 + 落地提交索引表 |
| docs/{b4,b5,b7,b10,b12,b13,c1,c2,c3,wave9}-*.md(10 份 908 行) | → [../api-notes-snapshot-20261119.md](../api-notes-snapshot-20261119.md) | 同体裁批次笔记合并成一份快照(原文零删改, 原文件删除) |
