# 文档索引(docs/) —— 唯一入口

> 本文件是 `docs/` 的**唯一索引**: 每个仍留在 `docs/` 根目录的文件都在下面列全, 一行一句用途 + 最后更新时间。
> 状态口径: **活跃** = 会随开发继续更新;**归档** = 结论已定/工作已完成, 只作留痕; 已移入 `archive/` 的
> 见 [`archive/README.md`](archive/README.md)(含**旧路径 → 新路径**对照表, 历史链接按那张表解析)。
> 规则: 不新开文档 —— 新内容就地并入 `PROGRESS.md`(进度/决策)或 `.pi/memory/*.md`(机制/坑);
> 一次性调研/任务书写完并落地后, 由本索引记一行再 `git mv` 进 `archive/`。

## 1. 核心入口(先读这几个)

| 文件 | 用途 | 最后更新 |
|---|---|---|
| [PROGRESS.md](PROGRESS.md) | 进度总账:**门禁基线(唯一权威口径)** + 版本时间线 + 按日期批次(倒序, 只留 v0.20.0 起);更早的见 `archive/PROGRESS-2026-11-13-11-19.md`、`archive/PROGRESS-2026-11-03-11-12.md` 与 `archive/PROGRESS-v1.md`。**活跃** | 2026-11-19 |
| [remaining-batches.md](remaining-batches.md) | 待办与分批规划: 硬约束/并行矩阵/批次清单, **下一轮从 §11 挑功能活, §12 结构性债务, §13 未做的平台层审计项**。**活跃** | 2026-11-18 |
| [api-coverage.md](api-coverage.md) | 接口覆盖清单(vendor ↔ 本仓库), 跑 `bash tools/api-coverage.sh` 复算。**活跃** | 2026-11-16 |
| [README.md](README.md) | 本文件: 文档索引(唯一入口)。**活跃** | 2026-11-18 |

## 2. 构建 / 发布 / 测试

| 文件 | 用途 | 最后更新 |
|---|---|---|
| [android-signing.md](android-signing.md) | Android 签名与 versionCode 纪律, 发版必读。**活跃** | 2026-11-09 |
| [android-keystore-wiring-design.md](android-keystore-wiring-design.md) | 凭据后端接线设计(Keystore / secret-service / DPAPI 三端)。**活跃** | 2026-11-12 |
| [testing.md](testing.md) | **多端测试指南(唯一入口)**: 上篇=日常自测流程(Android 模拟器 a34 · Linux Xvfb · 语义树驱动 uix/uitap/shot + 踩坑速查) · 下篇=桌面端(Linux/Windows)发布前 31 条人工冒烟清单(每条带通过判据, 配套 `tools/smoke-desktop.sh`)。2026-11-19 由 `testing-dual-platform.md`(旧标题误写「dual」, 实为三端)与 `smoke-desktop.md` 合并, 原文零删改。**活跃** | 2026-11-19 |

> 2026-11-19 合并(旧路径 → 新路径): `docs/testing-dual-platform.md`(三端测试记录, 标题误写「dual」)与
> `docs/smoke-desktop.md`(桌面冒烟 31 条)已删除, **内容原样**并入 [testing.md](testing.md) 的上篇/下篇;
> 代码注释与脚本里的旧路径按本行解析(历史归档件不改原文)。

## 3. 批次接口实测笔记(已合并为一份快照)

| 文件 | 内容 | 最后更新 |
|---|---|---|
| [api-notes-snapshot-20261119.md](api-notes-snapshot-20261119.md) | **10 份批次笔记的原文合并**(B4 搜索 / B5 逐字歌词 / B7 歌单写(含 code=500 半成功坑) / B10 电台 / B12 数字专辑 / B13 AMLL TTML / C1 歌手页 / C2 歌词来源质量抽样 / C3 MV / Wave9 endpoint), 每节带原小节标题, 顶部有索引。2026-11-19 精简时由 `b4/b5/b7/b10/b12/b13/c1/c2/c3/wave9-*.md`(共 908 行)合并且原文件删除(合并脚本逐行断言 missing=0, 一字未删) | 2026-11-19 |

协议/风控/加解密的**结论层**在 `.pi/memory/notes-api.md`; 这里只放"当时的原始响应长什么样"。

## 4. 2026-11-19 新归档的 5 份(原本留在 `docs/` 根, 现全部移入 `archive/`)

| 文件 | 用途 | 归档理由 |
|---|---|---|
| [archive/plan-2026-11-09-settings-and-player.md](archive/plan-2026-11-09-settings-and-player.md) | 设置扩充 + 播放体验任务书(7 项已验收)。**归档** | 7 项全落地、真机听感验收通过; 文中 `main.dart:NNNN` 行号已失效(main.dart 现为 48 行门面)。代码注释里的路径已同步改指 `docs/archive/`(§2.2/§5 契约仍从这里查) |
| [archive/credential-storage-options.md](archive/credential-storage-options.md) | 凭据存储方案调研(已选型落地, 实现在 `credential_store.rs`/`credential_keyring.rs`)。**归档** | 5 条决策已由用户拍板并固化在 `.pi/memory/notes-credentials.md`; 本文只留调研过程 |
| [archive/ui-row-audit.md](archive/ui-row-audit.md) | 列表行/溢出全仓审计(A 必坏 7 / B 潜在 12 / C 一致性 18)+ `ListRow` API 草案。**归档** | A/B/C 三级已全部清零(v0.9.0 + 2026-11-16/17 三批), 口径已进 `.pi/memory/notes-ui-rules.md` 与 `layout.dart` token; 文中 §4/§6/§7 行号是当时口径 |
| [archive/lx-plugin.md](archive/lx-plugin.md) | LX 音源脚本工坊(Melodia 沙盒契约 + 回归台)。**作废(2026-11-19)** | 未落地设计稿, 面向外部项目 Melodia; 文件头已加作废 banner, 立项时再取出 |
| [archive/melodia-pr-workflow.md](archive/melodia-pr-workflow.md) | 给 Melodia 提 PR 的工作流。**作废(2026-11-19)** | 针对被 fork 的 WebView 版(`legacy/`), 本仓已重启为独立工程; 文件头已加作废 banner |

## 5. 其他

| 路径 | 用途 | 最后更新 |
|---|---|---|
| [archive/](archive/README.md) | 已完工/已决策的专题文档(2026-11-19 新增 `plans-2026-11/`(31 份车道记录)与 5 份原在根目录的归档件) + 三段 PROGRESS 归档(`PROGRESS-v1.md` v1 WebView 时代 · `PROGRESS-2026-11-03-11-12.md` v2 早期批次 · `PROGRESS-2026-11-13-11-19.md` v0.8.0–v0.19.0 批次) + `remaining-batches-history.md`。**归档** | 2026-11-17 |
| [audits/](audits/) | 近期审计报告: `2026-11-12-code-audit.md` · `-ui-layout.md` · `-ui-alignment.md` · `2026-11-13-asset-docs-audit.md`(数字为当时快照)。**活跃** | 2026-11-13 |
| [reports/](reports/) | 只读调查报告: `login-risk-analysis-2026-11-17.md`(PC 网页登录为什么被风控 —— 静态分析, 未真登录/未扫码; 关联 v0.21.0 第 ⑤ 项)。**留档** | 2026-11-17 |
| [spikes/](spikes/) | 零散 spike 产物(如 `2026-11-09-netease-music-spike.md`)。只读留痕 | 2026-11-07 |
| [b8-dumps/](b8-dumps/README.md) | B8 等级/勋章接口原始 dump(含 `user_medal.sample.json`)。只读留痕 | 2026-11-07 |
| images/ | README 截图素材(hero/手机截图/分享卡片) | — |
| [../tools/diag-worker/README.md](../tools/diag-worker/README.md) | 匿名诊断「一键提交」Worker 部署说明(8 步, 含 fine-grained PAT、自定义域、限流/幂等、已知不稳定点)。**活跃** | — |

新读者路径: 根 `README.md` → 本文件 → `PROGRESS.md` 进度总览 → `remaining-batches.md` §11 挑活。
