# I 车道: 删 3 条 FFI 真死出口 + codegen 三步(2026-11-18)

基线 `c7d977e` = v0.22.0。本轮只做一件事: 删 `core/crates/ncm-ffi/src/api.rs` 里 3 个 Dart 侧零调用的导出, 走完 codegen 三步, 同步 `docs/api-coverage.md`。
provider 层方法**没删**(`ncm-cli/src/main.rs:886` `signin_status`、`:1124` `podcast_radio` 仍在用), 删的只是 FFI 出口。

## 1. 零调用核查(命令 + 输出)

```
$ rg -n 'playlistTracksAdd|podcastRadio|signinStatus|playlist_tracks_add|podcast_radio|signin_status' -g '!*.lock'
```
命中只有三类: 生成文件(`ui/lib/src/rust/**`)、文档(`docs/**`)、`ncm-cli` 的 provider 调用。再排除生成文件确认 Dart 生产/测试侧零调用:

```
$ rg -n 'playlistTracksAdd|podcastRadio|signinStatus' ui/lib ui/test --glob '!ui/lib/src/rust/**'
(exit 1, 无输出)
```

`api.dart` 里的 `podcastRadio`/`playlistTracksAdd`/`signinStatus` 全部来自 codegen; `frb_generated.web.dart`/`.io.dart` 里的 `SigninStatus`/`PodcastRadio` 是 **DTO 类型 codec**, 不是函数入口 —— 两个 DTO 仍被别的导出使用(见 §3)。

## 2. 删除清单(`core/crates/ncm-ffi/src/api.rs`, 删前行号)

| 导出 | 行号(删前) | 删除行数 | 上下文 |
|---|---|---|---|
| `pub async fn podcast_radio` | 2145–2149(含 doc `/// 播客/电台详情`) | 5 | `podcast_program` 之后、`// ---- 电台发现(只读) ----` 分节之前 |
| `pub async fn playlist_tracks_add` | 2689–2696(含 doc) | 8 | `create_playlist` 与 `delete_playlist` 之间 |
| `pub async fn signin_status` | 2918–2922(含 doc) | 5 | `_SigninStatus` mirror 之后、`sign_in` 之前 |

合计 `api.rs` **-18 行 / 0 行新增**, 三个 `// ----` 分节结构未动。

**未一并删除的 DTO/mirror(有仓内引用, 保留)**:
- `#[frb(mirror(SigninStatus))]` / `SigninDay`: `sign_in()` 返回值 + `VipOverview.dailySign`(vip 页在用)。
- `#[frb(mirror(PodcastRadio))]`: `RadioPick.radios` / `RadioExploreHome` 列表(电台广场在用), provider 侧多处。
- `Capability::PodcastDetail` 变体: `ncm-cli` + capability 表 + service CAPABILITIES 仍在用, 保留。
- `Capability::Signin` 仍被 `sign_in` 使用。

## 3. codegen 三步(严格按序)

1. `flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust`
   —— 解析阶段先报 3 条 `E0425`(`frb_generated.rs` 旧文件仍调已删函数), 属预期, 随后 `Done!` 并重写生成文件。
2. `cd core && cargo build -p ncm_ffi` ⇒ `Finished dev profile`(5.74s)。
3. `cd ui && flutter test`(全量, `--exclude-tags network`)⇒ **1148 passed / 0 failed**。

## 4. 生成文件 diff 统计(纯删减 + 序号重排)

| 文件 | 新增 | 删除 |
|---|---|---|
| `ui/lib/src/rust/api.dart` | **0** | 17 |
| `ui/lib/src/rust/frb_generated.dart` | 63 | 161 |
| `core/crates/ncm-ffi/src/frb_generated.rs` | 63 | 175 |

`frb_generated.*` 侧那 63 行新增**不是格式化抖动**, 全部是 handler 分发表尾部的 `funcId` 重编号(`97..158`, 原先 `100..161`)加两行 content hash:
`FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH` / `int get rustContentHash`。删除侧是对应的 3 个 `wire__…_impl` 分发体 + 3 个 handler 体 + 旧序号尾部。
`frb_generated.io.dart` / `frb_generated.web.dart` **未变**(它们只含 DTO 的 dco/sse codec, 两个 DTO 仍存活)。

## 5. 自验(现测)

| 门 | 命令 | 结果 |
|---|---|---|
| Rust clippy | `cargo clippy --workspace --all-targets -- -D warnings` | **0 warning / 0 error**(grep 计数 0) |
| Rust 测试 | `cargo test --offline --workspace --exclude ncm-api-rs` | **313 passed / 0 failed**(47+46+1+218+1, 与基线一致) |
| Dart analyze | `cd ui && dart analyze` | **No issues found!** |
| Flutter 测试 | `flutter test --exclude-tags network` | **1148 / 0** |
| 覆盖统计 | `bash tools/api-coverage.sh` | 导出 **158** · 无入口 **6**(`cache_stats cloud_song_url consent_plaintext_storage eq_profile_normalize player_tuning user_play_ranking`) · 未接入 **1**(`vip_sign_info`) |
| token 门 | `check-tokens.sh --strict` | OK |
| 行留白门 | `check-row-padding.sh --strict` | OK |
| 写接口门 | `check-write-guard.sh` | OK |

## 6. 与审计报告的差异 / 需要编排者知道的

1. **测试总数没变**: 3 条导出在本仓 Dart 侧全无测试调用, 所以 1148 不减少; `check-write-guard.sh` 里 `playlistTracksAdd` 是**正则名单**(检查 `ui/test/**` 不许直连写接口), 与导出是否存在无关, 仍 OK, 未改脚本。
2. **首轮全量 test 出现 3 个 "loading …" 失败**(adaptive_text_row_test / layout_metrics_test / theme_accent_test)。不是本次改动导致: 同一时刻仓库里 `ui/lib/src/{adaptive_text_row,layout,theme}.dart` 与这三个测试文件正被**并行的其他车道**改写(`git status` 可见), 加载期读到写了一半的文件; 单跑与第二轮全量都通过(1148/0)。**结论: 当时是并发写文件竞态, 与本车道无关。**
3. 文档只改了 `docs/api-coverage.md`(文首复核行 + 总览两行 + §6 的 `podcast_radio` 句子)。`docs/api-notes-snapshot-20261119.md`、`docs/archive/**` 里的旧叙述属历史记录, 未动; `docs/PROGRESS.md` 按纪律留给编排者。
4. 未提交 git;未跑 `dart format` 全仓、未跑 `flutter analyze`。
