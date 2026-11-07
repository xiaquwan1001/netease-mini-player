# FFI 清理 D1+D2+D5 执行记录

> 车道日期 2026-11-07。只删 FFI 导出与收敛样板，不动 provider/service 层。未 git commit。

## 前置核实（grep 证据）

- `rg 'rust\.search\b|rust\.lyricLines\b' ui/lib` → **0 命中**（UI 无入口确认）。
- provider 层 `search` 仍被 CLI 使用：`ncm-cli/src/main.rs:133 p.search(&q)`、`ncm-provider/src/lib.rs:281` —— 只删 FFI 导出，provider/service 未动。
- `SearchResultDto` 除 api.rs 定义 + `search` fn + frb 生成物外无其他引用 → 连同删除。

## D1：删 FFI `search`（原 api.rs:160）

删除 `pub async fn search`（18 行）与 `pub struct SearchResultDto`（6 行）。UI 的搜索全走 `rust.searchAll`。

## D2：删 FFI `lyric_lines`（原 api.rs:607）

删除 `pub async fn lyric_lines`（8 行含 doc）。保留 `lyric` / `word_lyric_lines` / `lyric_lines_i18n`（`main.dart:875 rust.lyricLinesI18N` 在用，已确认未动）。

## D5：纯转发型封装收敛为 `ffi_forward!` 宏

宏定义在 `with_provider` 之后，三种形态（frb 只解析函数签名，宏只生成函数体，故签名仍手写可见，codegen 安全）：

- `ffi_forward!(Capability::X, provider.method(args))` —— 直接透传
- `ffi_forward!(Capability::X, provider.method(args), map conv)` —— 末步 Dto 转换（conv 可为 fn 或带类型标注的闭包）
- `ffi_forward!(Capability::X, provider.method(args), map_each conv)` —— `Vec<T> → Vec<Dto>`（conv 为普通 fn path；用闭包 + collect 会触发 E0282 推断失败，故单列形态）

收敛 **22 个**函数（审计 §3.5 列的 20 个 + 同形态的 `forward_event`、`delete_comment`）：
set_liked / like_event / forward_event / delete_comment / set_album_subscribed / create_playlist / delete_playlist / rename_playlist / update_playlist_desc / remove_from_playlist / dislike_recommend_song / trash_fm_song / history_recommend_dates / new_songs / history_recommend_songs / follow_counts / signin_status / sign_in / user_level / style_preference / podcast_hot / radio_recommend / search_suggest_keywords。

错误映射统一为宏内 `map_err(|e| e.to_string())`，与手写导出一致。

**行数**：api.rs `-124 / +46`（宏定义 15 行 + 22 处调用），净省 **78 行**；每处 4–6 行函数体压成 1 行调用。

## codegen

`flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust` → `Done!`。
重写：`core/crates/ncm-ffi/src/frb_generated.rs`、`ui/lib/src/rust/{api,frb_generated,frb_generated.io,frb_generated.web}.dart`。未手改生成物。

## 门禁实测

| 门禁 | 结果 |
|---|---|
| `cargo build --offline --workspace --all-targets` | **0 error**（Finished dev） |
| `cargo test -p ncm-domain -p ncm-service` | 22+97 = **119 全绿** |
| `bash tools/api-coverage.sh` | 已调用 **118** / 未接入 **0** / FFI 导出 **123**（125→123，-2）/ UI 没有入口 **0** |
| `dart analyze` | **0 error**（32 info 均为既有 lint 提示） |
| `flutter test` 全量 | 见下「并行车道说明」；排除在途文件后 **+207 ~1 全绿** |
| libncm_ffi.so release | 14,157,856 → **14,068,144**（-89,712） |
| strip 后 | 8,918,104 → **8,880,312**（-37,792） |

### 并行车道说明（非本车道失败）

全量 flutter test 有 9 个用例文件编译失败，全部指向 **D6 车道在途文件**：`ui/lib/src/paged_list_view.dart`（新文件，git status `??`，:141 类型错误）与 `ui/lib/src/user_list_page.dart`（:134 `_reload` 未定义）。本车道改动仅 `core/crates/ncm-ffi/src/api.rs` + codegen 生成物 + smoke 测试适配，不触及上述文件。排除这 8 个在途文件后：`+207 ~1: All tests passed!`（`~1` 为需音频设备的 skip）。

### 用例数变化

基线 235 → 排除并行车道后 207+1skip 全绿。本车道唯一测试改动：`test/frb_smoke_test.dart` 中 4 处 `rust.search` 改为 `rust.searchAll`（`search returns typed songs` 更名 `searchAll returns typed songs`），**用例数不变**（13 条，1 条 audio skip）。smoke 单跑实测 `+13 ~1: All tests passed!`。

## 交付摘要

- FFI 导出 **125 → 123**（D1 `search`、D2 `lyric_lines`）
- 覆盖脚本「UI 没有入口」**3 → 0**
- cargo 测试 **119 全绿**；flutter 测试（排除并行车道在途文件）**207+1skip 全绿**
- api.rs 净省 **78 行**（-124/+46，含 22 处转发收敛与 24 行删除的死导出）
