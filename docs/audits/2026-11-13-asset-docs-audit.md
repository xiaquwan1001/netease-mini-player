# 2026-11-13 项目资产 / 文档 / 代码审计

> 范围:代码死码与冗余、静态检查门、文档结构与进度口径、仓库内外资产、GitHub Release 完整性。
> 结论口径全部为**本机实测**(离线),不是估算。

## 1. 代码:无死代码,静态门从"有噪声"清到 0

| 项 | 审计前 | 审计后 |
|---|---|---|
| `cargo clippy --workspace --all-targets` | **35 warning** | **0 warning** |
| `dart analyze` | 0 error / 0 warning / **44 info** | **0 issue** |
| 死代码(分析器 unused_element / dead_code) | 无 | 无 |
| `dart format` 一致性 | 未纳入门(全仓为旧格式) | 仍未纳入,见下方"不要顺手跑" |

清零手段:

- Rust:机械项走 `clippy --fix`(bool 比较、`map_clone`、`io::Error::other`、`as_chunks`、f32 精度等),
  手工项 12 处(doc 列表缩进、`while let` 循环、`iter_mut().take()`、`sort_by_key`、`filter_map → map`、
  `RequestOption` 结构体字面量、冗余 guard、example 未用 import)。
- 修掉一处**被自动修复改坏的断言**:`word_lyric.rs` 里 `assert!(!x == false || x)` 被改成恒真表达式,
  按测试语义改回 `assert!(wl.has_word_timing)`(第三行确实有合法词级头)。
- Dart:43 条 lint 由 `dart fix --apply` 修(underscores / null-aware elements / 花括号 / 未用 import),
  另 1 条 `ReorderableListView.onReorder` 弃用改 `onReorderItem`(新 API 已修正 newIndex 语义)。

代码层面的**真实缺陷**只有一处配置不一致:`core/Cargo.toml` 的 `workspace.dependencies` 列了 `ncm-playback`,
但 `members` 漏了它(靠 path 依赖被自动纳入,`cargo -p ncm-playback` 语义不稳),已补进 members。

### 结构性债(本次不动, 记录风险)

| 文件 | 行数 | 说明 |
|---|---|---|
| `core/crates/ncm-service/src/netease.rs` | 8110 | 全部 provider 方法同文件,改接口必冲突;拆分需要按能力域切模块并重跑全量 |
| `ui/lib/main.dart` | 3512 | 宿主/路由/状态集中;再拆要先把 `_` 前缀成员迁出 |
| `core/crates/ncm-ffi/src/api.rs` | 2757 | 转发宏已收敛,剩余是逐接口样板 |
| `ui/lib/src/rust/*`、`frb_generated.rs` | 生成的 2.3 万行 | **不要手改**,只由 codegen 重写 |

### 两条纪律(已写进 `AGENTS.md`)

1. `cargo clippy --workspace --all-targets` 现在 0 warning,别再引入。
2. `dart format`(Dart 3.13 tall style)会重排全仓约 **10k 行**(本次实测 143 文件 / +5846 −4405)。
   本次已回退该 churn;要统一格式就单独立一次提交并同时把 `dart format --set-exit-if-changed` 加进 CI,
   否则下次又漂。源码 grep 类断言必须用正则,且跑过 format 后必须重跑全量测试。

## 2. 文档:按"入口 + 索引 + 指针"重排

| 文件 | 前 | 后 | 处理 |
|---|---|---|---|
| `docs/PROGRESS.md` | 1352 行, 内部**有两份文档头**, v1 段插在中间, 11-09~11-12 的专题小节被追加在文件末尾 | 1244 行, 单入口 | v1 段 → `docs/archive/PROGRESS-v1.md`;末尾专题小节加「专题小节(按主题, 非时间序)」标题并声明新批次写时间线;头部换成 2026-11-13 口径 |
| `docs/remaining-batches.md` | 296 行, §4/§5/§9/§10 全是已完成历史;S 级表被一块 B4 预研笔记**从中间打断**(B8 行成孤儿表) | 187 行 | §4/§5/§9/§10 → `docs/archive/remaining-batches-history.md` 并留指针;B4 笔记压成一行指向 `docs/b4-search-notes.md`(内容已在其中);§11 重写为「只剩这些没做 / 已完成不要再做 / L 级 / 明确不做」 |
| `README.md` / `README.en.md` | 门禁写 254/617/38 info;待办还写着 D 批技术债与短信登录待真机验 | 271/674/0 issue;待办改为 §11.A 五项;功能表补自动更新频率与歌单内搜索策略;文档表加 `docs/README.md` 索引 |
| `docs/README.md` | 缺 `audits/`, 归档目录描述未更新 | 补 audits 行、归档两新文件说明 |
| `.pi/memory/notes-wip.md` | 77 行"在飞状态", 实际全是已发布版本的明细(v0.5.5~v0.7.0) | 24 行 | 只留现场状态 + 门禁基线 + 环境注意,版本明细**只留指针**指回 PROGRESS |

补上的真实缺口:**v0.6.0 / v0.6.1 / v0.7.0 / v0.7.1 四个已发布版本此前在公开文档里没有任何记录**
(明细只存在于 gitignored 的 `.pi/memory/notes-wip.md`)。现已作为「2026-11-12(晚):v0.6.0 → v0.7.1 四连发」
写进 PROGRESS 时间线,并补进版本时间线表格。

## 3. GitHub:标签与 Release 一一对齐

审计前:22 个 tag 只有 20 个 Release;`v0.2.0 / v0.2.1 / v0.3.4 / v0.3.5 / v0.5.1 / v0.6.0 / v0.6.1 / v0.7.0 / v0.7.1`
的 Release 标题就是裸 tag 名且**正文为空**,`v0.5.5` 正文只有 1 字节;`v0.1.1 / v0.3.0 / v0.3.1 / v0.4.0 / v0.5.0 / v0.5.2 / v0.2.2` 正文为一两行。

审计后:

- **22 / 22 tag 都有 Release**,名称统一为 `轻音 MiniNCM vX.Y.Z — 一句话要点`,`Latest` 仍指向 **v0.7.1**。
- 17 个 Release 补齐正文(来源:各 tag 区间的 git log + `docs/PROGRESS.md`,不臆测未做过的改动)。
- `v0.5.3` / `v0.5.4` 原本没有 Release(CI 未出全套资产),现补建并显式标注「中间版本,由 v0.5.5 取代 / 未产出分发物」。

## 4. 资产:已精简的与待定的

已处理(删/取消追踪, 均可重建或可从 git 取回):

| 项 | 体积 | 处理 |
|---|---|---|
| `dist/`(本地打包产物, 停在 v0.3.2) | 25 MB | 删除(release 页有全套资产;`.gitignore` 已排除) |
| `legacy/android/app/build/**` | 113 个文件(含 `app-debug.apk` 等) | **从 git 取消追踪**并删除本地目录,`.gitignore` 补 `legacy/android/app/build/` |
| `.pi/artifacts/bootpad|uibatch` 截图 | 3.0 MB | 删除(一次性验证截图;`.md` 报告保留) |
| `references/` 里 4 个调研仓库(Ncrust / ML-Netease_Android / MusicFreePlugins / Netease-Music-VScode) | 30 MB | 删除,`references/README.md` 记来源 + 一行重拉命令;`api-enhanced`(vendor 上游)保留 |

待定(需要时再清, 纯缓存):

| 项 | 体积 | 说明 |
|---|---|---|
| `ui/build/rust_lib_minincm` | 18 GB | cargokit 中间产物 |
| `core/target/debug` | 19 GB | 增量编译 + 测试二进制 |
| `ui/build/{app,linux,test_cache}` | 8.2 GB | 历史三端构建与测试缓存 |
| `ui/.dart_tool` | 1.2 GB | 包配置与 kernel 缓存 |

合计约 **45 GB**,全部可由 `bash tools/build-*.sh` / `flutter test` 重建(首次重编约 5~10 分钟)。
当前磁盘余量 263 GB,不急着清;要清就跑 `rm -rf ui/build core/target ui/.dart_tool`。

## 5. 收尾门禁(本次实测)

```
cargo test --offline --workspace           271 passed / 0 failed  (不含 vendor 247 + vendor 24)
cargo clippy --workspace --all-targets     0 warning
dart analyze                               0 issue
flutter test --exclude-tags network        674 passed / 0 failed
bash tools/api-coverage.sh                 123/123 (FFI 150, 5 个无 UI 入口)
tools/check-write-guard.sh                 OK
```
