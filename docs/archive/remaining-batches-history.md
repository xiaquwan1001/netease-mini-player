# 待办规划历史(归档)

> 从 `docs/remaining-batches.md` 拆出的已完成/历史口径小节(B0 收尾批、推荐波次、精简项排队、UI/UX 走查批 A–D),
> 只作决策留痕。当前待办入口见 [remaining-batches.md](../remaining-batches.md) §11。

## 4. B0 · 纯 Dart 收尾批(任何轮次都能搭车)

不新增接口, 只把「已接后端但 UI 没入口」补齐, 是唯一可以随时和 Rust 批并行的车道:

- `lyric_lines` / `lyric` 纯文本歌词的备用展示;
- `podcast_program` / `podcast_radio` 详情刷新(列表已有数据, 详情页未刷新);
- `follow_counts` 关注/取关后的资料卡数字刷新;
- 删除 `search` 导出(需 codegen → 归到下一次 Rust 批的 codegen 窗口, 不单独做);
- 纯 UI/测试打磨: 窄屏(vivo 768dpi)+大字号回归、空态/错误态文案、`ui/test` 补例。

文件白名单: `ui/lib/src/{lyric,podcast,profile_header,detail_page}.dart` + `ui/test/*`。
禁止碰: `netease.rs` `ncm-provider` `ncm-ffi` `ui/lib/src/rust/*`。

---

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

---

## 9. 精简项排队(2026-11-09 审计产出, 按依赖顺序)

> 来源: `api-overlap-audit.md`(D1–D7) + `backend-service-options.md` §3/§5.5(P1/P2)。
> 硬约束: **codegen 是全局串行点, cargo 共用 `core/target`** ⇒ 下列批次互斥, 一律串行。

| 序 | 批次 | 内容 | 触碰面 | 前提 |
|---|---|---|---|---|
| 1 | ~~**P1+P2 vendor 裁剪**~~ ✅ **已完成**(2026-11-09) | 删 264 个未接 endpoint + `api/mod.rs` 清单 + tokio 移除 + 死特性 `server` 删除; 382→118/12k→4.1k 行/冷编 1.40→0.65 s/119 测试全绿 | `core/vendor` | 见 `backend-prune.md` |
| 2+3 | ~~**D1+D2 删死导出 + D5 转发宏**~~ ✅ **已完成**(2026-11-09) | 导出 125→123、「UI 无入口」3→0; `ffi_forward!` 宏收敛 22 封装, 净 −80 行 | `ncm-ffi` + codegen(已用一次) | 见 `docs/archive/ffi-cleanup-d1d2d5.md` |
| 4 | ~~**D6 PagedListView**~~ ✅ **已完成**(2026-11-09, 后续又补迁 3 页) | 新组件 + 迁移 7 页(messages/user_list/playlist_square/ranking/new_release/all_charts/digital_album); **仍可迁**: `radio_explore_page`、`style_page`(均未用组件) | 纯 Dart | 见 `docs/archive/ui-batch-d6.md` |
| 5 | ~~**D7 frb 透传 domain**~~ ✅ **已完成**(2026-11-09, 57/57) | 删 74 个 Dto struct(`api.rs`)≈646 行 + 内联转换 ~400 行 | `ncm-domain` + `ncm-ffi` + Dart | 见 `d7-frb-domain.md`; 车道已关闭 |
| — | ~~方案 c: 换 `netease-music`~~ | ⛔ 已裁决不切 | — | 见 `backend-service-options.md` §6 门槛 |

**决策记录(2026-11-09, 用户已批准)**:
- **D7 批准做, 记为待办**(不做前置条件, 但要等 1–4 收口, 单独一波), 验收口径见下 §9.1。
- **D1/D2 直接删, 不留 release 周期**(两个都是零调用死导出, provider/CLI 侧不受影响)。
- 顺序不变: 1 → 2+3(含 D1/D2) → 4(可与 2+3 同波) → 5(D7)。

### 9.1 D7 待办卡(frb 直接透传 domain DTO) —— ✅ 已完成(2026-11-09, 57/57 直透)

> 以下保留为验收口径留痕; 实际收口记录见 `d7-frb-domain.md`。

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

---

## 10. UI/UX 走查批次(A–D, 2026-11-09 审计产出)

> 来源 `ui-ux-audit.md`(506 行, 每条带 file:line)。P0=3 / P1=15 / P2=13。
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
| ~~**D · 技术债收敛**~~ ✅ **已完成**(2026-11-11, 见 §11.B2) | 抽 `fmtDuration`/`formatDurationShort`/日期格式化进 `format.dart`、弹层 21/21 统一 `SheetHeader`+`showDragHandle`、`podcast.dart` 半死入口已删(658→190 行, 存活组件测试同步改写)、窄屏+1.25 回归补到 45 个测试文件 | P2 全部 + P1-7.15/7.16/7.18 | ~~M~~ 已做 | — |

**与 §9 的互斥关系**: A–D 全是纯 Dart 车道, 与 §9 的 Rust/codegen 批次(2/3/5)**可并行**; 但 A/B/C/D 之间按上表错序。
