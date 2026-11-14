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
| [remaining-batches-history.md](remaining-batches-history.md) | 待办规划历史口径: B0 收尾批 / 推荐波次 / 精简项排队 / UI 走查批 A–D | 📦 归档(2026-11-13) |
| [DOCS-REPORT-2026-11-10.md](DOCS-REPORT-2026-11-10.md) | 文档整理子代理的一次性报告（**数字为当时快照**：248/522，现值见 PROGRESS 头部） | 📦 归档(2026-11-11) |
| [ffi-cleanup-d1d2d5.md](ffi-cleanup-d1d2d5.md) | D1/D2/D5：删死导出 + `ffi_forward!` 宏收敛（**数字为当时快照**：导出 123；现值见 api-coverage.md） | ✅ |

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

> 未迁移的归档文档(结论已定但被代码注释引用, 暂留 `docs/` 原位): `plan-2026-11-09-settings-and-player.md`、
> `credential-storage-options.md` —— 见 [`../README.md`](../README.md) §4 的说明与解绑条件。
