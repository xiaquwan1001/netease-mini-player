# 死代码清账 (H 车道 · 2026-11-18)

> 上游依据: `docs/archive/plans-2026-11/deadcode-audit-2026-11-18.md`(E 车道只读审计)。基线 `5b79e5a`。
> 本车道只动 A/B 批 7 条(**A 级中需产品决策的 `requiresPurchase`/`validateEqProfile` 按上游口径排除**),
> 外加 `cupertino_icons` 依赖 chore。**零行为改动, 只删未引用符号**。
> 未 git commit(上游编排者统一提交); 未改 `docs/PROGRESS.md`/`remaining-batches.md`/`api-coverage.md`/
> `tools/api-coverage.sh`(在飞车道在改)。

## 1. 删除清单与复核证据

复核口径统一为: `rg -n -w <符号> <范围> -g '!**/src/rust/**' -g '!**/frb_generated.rs'`,
删前每条都实测「**唯一命中 = 定义处**」。

| # | 符号 | 文件:原行 | 删行 | 复核输出 |
|---|---|---|---|---|
| 1 | `PROVIDER_NETEASE` | `core/crates/ncm-service/src/lib.rs:34` | 2 | `rg -n 'PROVIDER_NETEASE' . -g '!core/target' -g '!.git'` → `./core/crates/ncm-service/src/lib.rs:34:pub const PROVIDER_NETEASE: &str = "netease";`(唯一);`git log -S` 只有 `41daac3`(首个 core 提交), **从未被引用** |
| 2 | `NeteaseProvider::with_channel` | `core/crates/ncm-service/src/netease/mod.rs:139-147` | 10 | `rg -n -w with_channel core/crates -g '*.rs' -g '!**/frb_generated.rs'` → `mod.rs:140: pub fn with_channel(...)`(唯一);`git log -S` = 模块拆分 `9592343` + 首提交, 无调用方 |
| 3 | `Player::set_gain_db` | `core/crates/ncm-playback/src/lib.rs:433-438` | 7 | `rg -n -w set_gain_db core/crates -g '*.rs' -g '!**/frb_generated.rs'` → `lib.rs:434: pub fn set_gain_db(&self, gain_db: f32)`(唯一) |
| 4 | `DiagUploader.uploadJson` | `ui/lib/src/diag_upload.dart:52-69` | 19 | `rg -n -w uploadJson ui/lib ui/test -g '*.dart' -g '!**/src/rust/**'` → `diag_upload.dart:53: Future<DiagUploadResult> uploadJson(...)`(唯一)。删后 `jsonDecode` 仍被 `:170` 使用(`import 'dart:convert'` 不悬空) |
| 5 | `kImageHeaders` | `ui/lib/src/cover_art.dart:29-33` | 6 | `rg -n -w kImageHeaders ui/lib ui/test -g '*.dart' -g '!**/src/rust/**'` → `cover_art.dart:30: const Map<String, String> kImageHeaders = {`(唯一);实际请求头在 `_UaNetworkImage` 内自设(`kImageUserAgent` 保留, 仍被 `:45` 用) |
| 6 | `DailyPlaylistCache.purge()` | `ui/lib/src/daily_cache.dart:209-211` | 4 | `rg -n -w purge ui/lib ui/test -g '*.dart'` → `daily_cache.dart:210: Future<bool> purge() =>`(唯一);`purgeAccount`(静态)仍被 `account_actions.dart` 调用, 不受影响 |
| 7 | `cupertino_icons` 依赖 | `ui/pubspec.yaml:dependencies` | 3(+lock 8) | `rg -n 'Cupertino|cupertino' ui/lib ui/test ui/android` → **无输出(exit 1)**;连注释行一起删, 无悬空说明。`flutter pub get` → `These packages are no longer being depended on: - cupertino_icons 1.0.9 / Changed 1 dependency!` |

**合计**: 手写源 **51 行删除**(Rust 19 / Dart 29 / pubspec 3), 另有 `ui/pubspec.lock` 自动减 8 行。
全部为纯删除, `git diff --numstat` 每行都是 `0	N`, **零新增行**(未动任何逻辑/测试/文档)。

## 2. 自验(真跑, 2026-11-18)

| # | 命令 | 结果 |
|---|---|---|
| 1 | `cd core && cargo fmt --all -- --check` | `FMT_EXIT=0`(无差异 ⇒ 纯删除未误删行) |
| 2 | `cargo clippy --workspace --all-targets -- -D warnings` | `Finished dev profile`, `CLIPPY_EXIT=0`, **0 warning** |
| 3 | `cargo test --offline --workspace --exclude ncm-api-rs` | **passed=313 failed=0**(与基线一致) |
| 4 | `cd ui && dart analyze` | `No issues found!`(0 issue) |
| 5 | `flutter test --exclude-tags network` | `+1148: All tests passed!` **1148 通过 / 0 失败** |
| 6 | `dart format --set-exit-if-changed lib/src/{diag_upload,cover_art,daily_cache}.dart` | `Formatted 3 files (0 changed)`, `FMT_EXIT=0` |
| 7 | `check-tokens.sh --strict` / `check-row-padding.sh --strict` / `check-write-guard.sh` | 三条全 OK(EXIT=0) |
| 8 | `bash tools/api-coverage.sh` | `FFI 导出函数 : 161` / `其中 UI 没有入口 : 9`(与目标一致;删的是非 FFI 符号) |

## 3. 排除项(按上游口径, 本批不动)

- `requiresPurchase` / `validateEqProfile`: **未接线功能**, 需产品决策(接回或删), 不是死码。
- `Playback.setVolume` 整链(Dart/Kotlin/Rust): 0..1 音量档无 UI 入口, 需产品决策。
- C 级 4 条 FFI 真死出口(`eq_profile_normalize`/`playlist_tracks_add`/`podcast_radio`/`signin_status`): 动 FFI 需 codegen 独占窗口。
- B 级另外 3 条(`kBrandSeed`/`kPageHorizontalPadding`/`shouldShowBadges`): 要先改 3 个测试断言。

## 4. 对 E 报告的两点订正(不附和)

1. **§1「A 级: 真死, 零风险可删」的定义被自己破了**: `requiresPurchase`(A1)与 `validateEqProfile`(A2)
   在条目内就写着"若产品决定…应保留并接线 / 先确认是否要接回",却在 §5 Top-10 里仍按 A 级排队。
   这两条本质是**未接线功能**, 与"零风险可删"矛盾; 本批按用户口径排除, 建议 E 下一版把它们从 A 级移出。
2. **§5 声称的「合计 62 行」口径偏小**: 按实际 diff,仅本批 7 条就是 51 行(+lock 8), 因为每条还要连带
   删除紧随其后的空行;E 的行数只统计了"函数体+doc", 会系统性少算 1 行/条。建议行数一律用 `git diff --numstat` 复核。

其余复核结论与 E 报告一致(`PROVIDER_NETEASE` 自 `41daac3` 起零引用、`kImageHeaders` 真零调用、
`purge()` 只剩 `purgeAccount` 静态路、`uploadJson` 唯一调用方走 `upload()`), **未发现误判为死的活代码**。
