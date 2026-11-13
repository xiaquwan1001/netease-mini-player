# 文档索引(docs/)

> 每个文件一行用途。状态口径: **活跃** = 会随开发继续更新;**归档** = 结论已定/工作已完成, 只作留痕查证。

## 核心入口

| 文件 | 用途 · 状态 |
|---|---|
| PROGRESS.md | 进度记录:门禁基线 + 版本时间线 + 按日期批次(倒序)+ 专题小节;v1 历史已拆到 `archive/PROGRESS-v1.md`。**活跃** |
| remaining-batches.md | 待办与分批规划, **下一轮从 §11 挑活**(§4/§5/§9/§10 已完成, 已移入 `archive/remaining-batches-history.md`)。**活跃** |
| api-coverage.md | 接口覆盖清单(vendor ↔ 本仓库), 跑 `bash tools/api-coverage.sh` 复算。**活跃** |
| README.md | 本文件: 文档索引。**活跃** |
| testing-dual-platform.md | Android/Linux/Windows 三端测试记录与自测方法。**活跃** |
| architecture-restart.md | 架构选型与决策记录(含 Windows 合入后的现状注记)。**归档(决策留痕)** |
| android-signing.md | Android 签名与 versionCode 纪律, 发版必读。**活跃** |
| android-keystore-wiring-design.md | 凭据后端接线设计(Keystore/secret-service/DPAPI 三端)。**活跃** |
| smoke-desktop.md | 桌面端冒烟测试清单。**活跃** |
| credential-storage-options.md | 凭据存储方案调研与决策留痕。**归档(已选型落地)** |

## 批次接口实测笔记(真实响应形状 / 协议坑)

| 文件 | 内容 |
|---|---|
| b4-search-notes.md | B4 搜索增强(联想/热词/多匹配) |
| b5-word-lyric-notes.md | B5 逐字歌词契约层 |
| b7-playlist-write-notes.md | B7 歌单写接口(含 code=500 半成功坑) |
| b10-radio-notes.md | B10 电台只读补充 |
| b12-digital-album-notes.md | B12 数字专辑只读 |
| b13-ttml-lyrics-notes.md | B13 AMLL TTML 逐字第二来源 |
| c1-artist-page-notes.md | C1 歌手详情页接口 |
| c2-lyric-source-quality.md | C2 逐字歌词来源质量抽样 |
| c3-mv-playback-notes.md | C3 MV 播放接口 |
| wave9-endpoint-notes.md | Wave 9 收尾只读 endpoint |
| api-channel.md | interface vs interface3 通道实测。**归档(结论已定)** |

## 调研 / 决策留痕(全部归档)

| 文件 | 内容 |
|---|---|
| audit-2026-11-10-organization.md | 2026-11-10 项目整理审计 |
| api-overlap-audit.md | D1–D7 API/实现重叠审计(全部执行完) |
| backend-prune.md | vendor 裁剪执行记录(264 个 endpoint 删除) |
| backend-service-options.md | 后端服务形态调研(结论: 不切换) |
| build-vs-fork.md | fork/PR/自建对比(结论: 只对 Melodia 提 PR) |
| community-projects.md | 社区项目资源盘点 |
| license-agpl-evaluation.md | MIT vs AGPL 评估(结论: 保持 MIT) |
| m0-plan.md | M0 基建周清单(已完成) |
| plan-2026-11-09-settings-and-player.md | 设置扩充 + 播放体验任务书(已验收) |
| research-2026-11-10-lyric-and-color.md | 歌词跟随与封面取色调研(已落地) |
| ui-ux-audit.md | UI/UX 走查报告(P0/P1 已修) |
| d7-frb-domain.md | D7 frb 直透 domain 收口(车道已关) |
| lx-plugin.md | LX 音源脚本工坊(搁置, 待插件化立项) |
| melodia-pr-workflow.md | 给 Melodia 提 PR 的工作流。**活跃(提 PR 时用)** |

## 其他

| 目录 | 内容 |
|---|---|
| archive/ | 已完工车道执行记录 + `PROGRESS-v1.md`(v1 WebView 时代进度) + `remaining-batches-history.md`(历史分批口径)。**归档** |
| audits/ | 代码/UI 审计报告(`2026-11-12-code-audit.md` · `-ui-layout.md` · `-ui-alignment.md`)。**活跃** |
| images/ | README 截图素材 |
| spikes/ · b8-dumps/ | 零散 spike 产物与原始接口 dump |

新读者路径: 根 README → 本文件 → `PROGRESS.md` 进度总览。