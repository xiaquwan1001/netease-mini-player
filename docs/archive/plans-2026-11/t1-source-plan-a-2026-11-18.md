# T1 方案 A: 音源「信息无损」+ 试听片段识别(记录)

> 角色 T1 · 2026-11-18 · **不 commit**(工作区由编排者统一快照)。
> 依据 `docs/archive/plans-2026-11/source-acquisition-research-2026-11-18.md` §2.1 / §3.2 / §7.1 / §8(方案 A) / §9。
> 本车道边界: 方案 A 的 **Rust 侧 + 只读展示侧**; 下载鲁棒性/边下边播/缓存键(方案 A ③⑤⑥)归 T2,
> 未碰 `core/crates/ncm-service/src/cache.rs`、`core/crates/ncm-playback/**`、`ui/lib/src/playback.dart`、Kotlin。

## 0. 一句话结果

取链响应里原先被整块丢弃的 `freeTrialInfo` / `level` / `type` / `md5` / `time` 现在全部落到
`ncm-domain::StreamUrl`, 并穿过 FFI 到 Dart; 播放条第二行行首对当前曲目显示
**「试听 mm:ss · 已降级 <中文档位>」**。旧 JSON/旧缓存反序列化不炸(`serde(default)`)。
实测: Rust **325 passed / 0 failed**(基线 313, 本车道 +6)、clippy 0 warning、`cargo fmt --all --check` 干净、
`dart analyze` 0、`flutter test --exclude-tags network` **1276 passed / 1 failed**(失败项属 diag 车道, 见 §4)、
`tools/api-coverage.sh` 导出仍 **158**(本车道不改导出面)、`check-tokens --strict` OK、golden 无变化。

## 1. 域模型(`core/crates/ncm-domain/src/lib.rs`)

`StreamUrl` 新增 7 个字段, 全部 `#[serde(default)]`(向后兼容旧 JSON/旧缓存):

| 字段 | 来源(上游键) | 说明 |
|---|---|---|
| `actual_level: Option<String>` | `level` | 服务端**实际**档位; 与 `quality` 不同 = 静默降级 |
| `format: Option<String>` | `type`(serde 写读都是 `type`, 另 alias `format`) | 容器/编码 mp3/flac/m4a |
| `md5: Option<String>` | `md5` | 整文件校验(空串归 None)|
| `duration_ms: Option<u64>` | `time` | 原样透传; **试听片段的 `time` 是整曲还是片段长度未实测**, 片段起止只信 `trial_*` |
| `trial_start_ms` / `trial_end_ms` | `freeTrialInfo.start/end` | 「从第 N 秒到第 M 秒」 |
| `is_trial: bool` | `freeTrialInfo` 非空 | 旧数据默认 false |

关键决定:
- **`quality` 语义不变(请求档位)** —— UI 的预取键/缓存键依赖它, 改语义会串档位。
  判断降级统一走新方法 `is_degraded()`(None = 上游没给 level, 不猜)。
- 便捷方法: `trial_len_ms()`(end-start, 非法区间给 None)、`effective_level()`(有 actual 用 actual)。
- **单位归一**: `freeTrialInfo` 上游无文档, 社区实现按**秒**(`{"start":0,"end":45}`), 但本轮拿不到线上
  逐字样本 ⇒ `trial_to_ms()`: 值 ≤ 600 当秒 ×1000, > 600 当毫秒原样。两种形状都有单测。

## 2. 解析(`core/crates/ncm-service/src/netease/song.rs::parse_stream`)

- 新增 `text_of()`(非空字符串取值)与 `trial_to_ms()`; `freeTrialInfo` 必须是对象且 `end > start` 才算试听,
  空对象 / `end<=start` / null 一律 `is_trial=false`(避免 UI 挂个假标签)。
- 请求 lossless 却回 `level=exhigh` 时: `quality` 保 `lossless`、`actual_level=exhigh` ⇒ 不假装成功。
- `ncm-cli url` 非 `--json` 分支加打 `actual=/trial=/trial_ms=/type=/md5=/duration_ms` 与
  `degraded: 请求 X ⇒ 实际 Y`, 让「能播的 45s 片段」和整曲在 CLI 上不再长得一样。
- 顺手修了 T2 签名变更带出的两处编译断点(`cache.fetch(..., level)` / `start_progressive(..., level)` 的
  cli 侧 `play` 分支; `play_track` 侧由 T2 自己落地 `level_hint`)。

## 3. FFI + Dart 展示

- `core/crates/ncm-ffi/src/api.rs`: `#[frb(mirror(StreamUrl))]` 同步 7 个字段;
  固定三步已做完(`flutter_rust_bridge_codegen generate …` → `cargo build -p ncm_ffi` → `flutter test`)。
  **导出函数数不变(158)** —— 只改结构体字段, 没有新 API。
- 新增 `ui/lib/src/stream_note.dart`:
  - `StreamNote`(只读摘要: `isTrial`/`trialLenMs`/`actualLevel`/`requestedLevel` + `label`),
    `audioLevelLabel()` 把档位翻成中文短名(标准/较高/极高/无损/Hi-Res);
  - 全局 `currentStreamNote`(`ValueNotifier<(trackId, StreamNote)>`) + `publishStreamNote()`(幂等),
    与既有 `nowPlayingSongId` 同思路: 一处投递, 播放条自己按 trackId 命中。
- `ui/lib/src/home/playback_coordinator.dart`: 取链后发布提示; 预取记录扩一列 `note`, 预取命中不丢信息;
  取链失败(`url == null`)显式清掉(publish null)。
- `ui/lib/src/player_bar.dart`: 第二行行首前缀(与「已排队→」同位置同字体权重), `ValueListenableBuilder`
  只包这一行, 不改 `PlayerBarData` 的相等性契约(那条契约被 `player_bar_data_test.dart` 锁着)。

**为什么选播放条而不是播放详情页**: ① 三端常驻、零导航成本, 用户看到「这段播完就没了」的那一刻正是
在播放条上; ② 详情页(歌词页)结构复杂且 golden 覆盖多, 插入成本高、收益相同; ③ 窄档(<600dp)本来
不渲染文字块, 提示自动隐藏 —— 与既有「窄档只留封面」的口径一致, 不新增溢出风险。
文案: `试听 00:45  ` / `已降级 极高  ` / `试听 00:45 · 已降级 标准  `。

## 4. 自验(真跑)

| 门 | 结果 |
|---|---|
| `cargo test --offline --workspace --exclude ncm-api-rs` | **325 passed / 0 failed**(`ncm-domain 49` / `ncm-playback 47` / `ncm-provider 1` / `ncm-service 227` / `ncm-ffi 1`; 1 doc-test ignored=network)。基线 313 ⇒ +12, 其中**本车道 +6**(domain 2 + service 4), 另 6 条来自并行车道 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 warning |
| `cargo fmt --all -- --check` | 干净(exit 0) |
| `cd ui && dart analyze` | **No issues found** |
| `flutter test --exclude-tags network` | **1276 passed / 1 failed**。基线 1265 ⇒ +11(本车道 +8, 另 3 条并行车道)。唯一失败 `one_click_diag_test.dart`「端点未配置」—— diag 车道已把 `kDiagUploadEndpoint` 填上真 Worker 域名, 该用例的「端口必须为空」前提过期, **与本车道无关**(未改 `app_meta.dart`) |
| Rust 新用例 | `stream_trial_fragment_is_flagged`(19292984 实测形状 fixture) / `stream_degraded_level_is_reported` / `stream_full_track_not_trial` / `stream_trial_unit_and_malformed` / `stream_url_deserializes_legacy_json` / `stream_url_trial_roundtrip` —— 全部离线, 无网络依赖 |
| Dart 新用例 | `ui/test/stream_note_test.dart` 8 条(文案口径 ×5 + 播放条显示/不串台 ×2 + 投递幂等 ×1) |
| `bash tools/api-coverage.sh` | vendor 136 / service 135 / 未接入 1; **FFI 导出 158 不变**, UI 无入口仍 6 ⇒ `docs/api-coverage.md` 无需改 |
| `tools/check-tokens.sh --strict` | OK(集合外间距/圆角/字号 0) |
| golden(20 张) | **无变化**(默认 `currentStreamNote=null` ⇒ 渲染与基线逐像素一致; 全量跑 golden 全绿) |

## 5. 给后续车道的手柄

- 多候选/第三方校验(方案 B/C)可直接用 `md5` + `duration_ms` + `br/size` 做三向一致性;
  `StreamUrl` 已是 serde 可序列化 DTO, 不需要新类型。
- 「试听片段不许当整曲播」的真正**拦截**仍在播放控制侧(本轮只做展示): 若要做「`is_trial && !allow_trial`
  ⇒ 拒绝/提示需登录」(§7.3), 在 `playback_coordinator._resolveAndPlay` 的 `note` 上判即可。
- `freeTrialInfo` 单位仍待一次线上实测确认; 若确认恒为秒, 可把 `trial_to_ms` 的 600 阈值收成常量断言。

■ 结束
