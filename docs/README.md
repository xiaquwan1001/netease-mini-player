# 文档索引(docs/) —— 唯一入口

> 本文件是 `docs/` 的**唯一索引**: 每个仍留在 `docs/` 根目录的文件都在下面列全, 一行一句用途 + 最后更新时间。
> 状态口径: **活跃** = 会随开发继续更新;**归档** = 结论已定/工作已完成, 只作留痕; 已移入 `archive/` 的
> 见 [`archive/README.md`](archive/README.md)(含**旧路径 → 新路径**对照表, 历史链接按那张表解析)。
> 规则: 不新开文档 —— 新内容就地并入 `PROGRESS.md`(进度/决策)或 `.pi/memory/*.md`(机制/坑);
> 一次性调研/任务书写完并落地后, 由本索引记一行再 `git mv` 进 `archive/`。

## 1. 核心入口(先读这几个)

| 文件 | 用途 | 最后更新 |
|---|---|---|
| [PROGRESS.md](PROGRESS.md) | 进度总账:门禁基线 + 版本时间线 + 按日期批次(倒序)+ 专题结论;v1 历史见 `archive/PROGRESS-v1.md`。**活跃** | 2026-11-14 |
| [remaining-batches.md](remaining-batches.md) | 待办与分批规划: 硬约束/并行矩阵/批次清单, **下一轮从 §11 挑活**。**活跃** | 2026-11-14 |
| [api-coverage.md](api-coverage.md) | 接口覆盖清单(vendor ↔ 本仓库), 跑 `bash tools/api-coverage.sh` 复算。**活跃** | 2026-11-14 |
| [README.md](README.md) | 本文件: 文档索引(唯一入口)。**活跃** | 2026-11-14 |

## 2. 构建 / 发布 / 测试

| 文件 | 用途 | 最后更新 |
|---|---|---|
| [android-signing.md](android-signing.md) | Android 签名与 versionCode 纪律, 发版必读。**活跃** | 2026-11-09 |
| [android-keystore-wiring-design.md](android-keystore-wiring-design.md) | 凭据后端接线设计(Keystore / secret-service / DPAPI 三端)。**活跃** | 2026-11-12 |
| [testing-dual-platform.md](testing-dual-platform.md) | Android/Linux/Windows 三端测试记录与自测方法。**活跃** | 2026-11-10 |
| [smoke-desktop.md](smoke-desktop.md) | 桌面端(Linux/Windows)冒烟测试清单。**活跃** | 2026-11-11 |

## 3. 批次接口实测笔记(真实响应形状 / 协议坑, 只读参考)

| 文件 | 内容 | 最后更新 |
|---|---|---|
| [b4-search-notes.md](b4-search-notes.md) | B4 搜索增强(联想/热词/多匹配) | 2026-11-07 |
| [b5-word-lyric-notes.md](b5-word-lyric-notes.md) | B5 逐字歌词契约层 | 2026-11-07 |
| [b7-playlist-write-notes.md](b7-playlist-write-notes.md) | B7 歌单写接口(含 code=500 半成功坑) | 2026-11-10 |
| [b10-radio-notes.md](b10-radio-notes.md) | B10 电台只读补充 | 2026-11-07 |
| [b12-digital-album-notes.md](b12-digital-album-notes.md) | B12 数字专辑只读 | 2026-11-07 |
| [b13-ttml-lyrics-notes.md](b13-ttml-lyrics-notes.md) | B13 AMLL TTML 逐字第二来源 | 2026-11-09 |
| [c1-artist-page-notes.md](c1-artist-page-notes.md) | C1 歌手详情页接口 | 2026-11-09 |
| [c2-lyric-source-quality.md](c2-lyric-source-quality.md) | C2 逐字歌词来源质量抽样 | 2026-11-09 |
| [c3-mv-playback-notes.md](c3-mv-playback-notes.md) | C3 MV 播放接口 | 2026-11-10 |
| [wave9-endpoint-notes.md](wave9-endpoint-notes.md) | Wave 9 收尾只读 endpoint | 2026-11-07 |

协议/风控/加解密的**结论层**在 `.pi/memory/notes-api.md`; 这里只放"当时的原始响应长什么样"。

## 4. 保留在原位的归档文档(结论已定, 但被代码注释/活跃文档引用, 暂不移动)

| 文件 | 用途 | 为什么留在 `docs/` |
|---|---|---|
| [plan-2026-11-09-settings-and-player.md](plan-2026-11-09-settings-and-player.md) | 设置扩充 + 播放体验任务书(7 项已验收)。**归档** | `ui/lib`、`ui/test`、`core/crates/ncm-domain` 多处注释按此路径引用契约(§2.2/§5); 待这些注释下次改动时一并迁 `archive/`。最后更新 2026-11-10 |
| [credential-storage-options.md](credential-storage-options.md) | 凭据存储方案调研(已选型落地, 实现在 `credential_store.rs`/`credential_keyring.rs`)。**归档** | `core/crates/ncm-service/src/credential_store.rs`、`credential_keyring.rs` 注释按此路径引用。最后更新 2026-11-12 |
| [lx-plugin.md](lx-plugin.md) | LX 音源脚本工坊(Melodia 沙盒契约 + 回归台)。**搁置** | 待插件化立项, 结论仍会被引用。最后更新 2026-10-31 |

## 5. 其他

| 路径 | 用途 | 最后更新 |
|---|---|---|
| [archive/](archive/README.md) | 已完工/已决策的专题文档 + `PROGRESS-v1.md`(v1 WebView 时代) + `remaining-batches-history.md`。**归档** | 2026-11-14 |
| [audits/](audits/) | 近期审计报告: `2026-11-12-code-audit.md` · `-ui-layout.md` · `-ui-alignment.md` · `2026-11-13-asset-docs-audit.md`(数字为当时快照)。**活跃** | 2026-11-13 |
| [ui-row-audit.md](ui-row-audit.md) | 列表行/溢出全仓审计(49 处骨架 → A 必坏 7 / B 潜在 12 / C 一致性 18)+ `ListRow` API 草案与改造顺序; A 级已在 v0.9.0 清零, 剩 B/C 待收敛。**活跃** | 2026-11-13 |
| [melodia-pr-workflow.md](melodia-pr-workflow.md) | 给 Melodia 提 PR 的工作流。**活跃(提 PR 时用)** | 2026-11-02 |
| [spikes/](spikes/) | 零散 spike 产物(如 `2026-11-09-netease-music-spike.md`)。只读留痕 | 2026-11-07 |
| [b8-dumps/](b8-dumps/README.md) | B8 等级/勋章接口原始 dump(含 `user_medal.sample.json`)。只读留痕 | 2026-11-07 |
| images/ | README 截图素材(hero/手机截图/分享卡片) | — |
| [../tools/diag-worker/README.md](../tools/diag-worker/README.md) | 匿名诊断「一键提交」Worker 部署说明(8 步, 含 fine-grained PAT、自定义域、限流/幂等、已知不稳定点)。**活跃** | — |

新读者路径: 根 `README.md` → 本文件 → `PROGRESS.md` 进度总览 → `remaining-batches.md` §11 挑活。
