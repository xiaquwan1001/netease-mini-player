# 后端裁剪: vendor 未用 endpoint 删除 + tokio 依赖瘦身

日期: 2026-11-07 · 范围: `core/vendor/ncm-api`(锁定 commit 的普通目录)、`tools/api-coverage.sh`、
`core/crates/ncm-cli/src/main.rs`(仅 raw 分发表) · **未 commit, 留给编排者审查**

## 1. 基线快照(裁剪前)

| 指标 | 基线值 |
| --- | --- |
| `bash tools/api-coverage.sh` | vendor endpoint 382 / service 已调用 118 / 未接入 264 |
| vendor `src/**/*.rs` | 395 个文件, 12,035 行, 1.7 MB |
| `src/api/mod.rs` | 566 行(381 条 `mod` 声明) |
| `cargo tree -p ncm-service --prefix none \| sort -u \| wc -l` | 213 |
| `cargo tree -p ncm_ffi ...` | 279 |
| `cargo tree -p ncm-cli ...` | 257 |
| `cargo build --offline -p ncm-api-rs`(先 `cargo clean -p`) | 1.40 s |
| `cargo test -p ncm-domain -p ncm-service --offline` | 119 个用例(22 + 97)全绿 |
| `libncm_ffi.so`(release, host) | 14,246,736 B; strip 后 8,971,728 B |
| 端到端延迟(search / url) | 见第 5 节 A/B(顺序无关的交替测法) |

## 2. 保留集判定(不动点)

判定口径不是「service 里出现过就算」, 而是**任一 workspace crate 真实调用**:

1. 种子: 在 `core/crates/**/*.rs` 里扫 `<recv>.<method>(`, method 命中 vendor 模块名才算
   (排除 `frb_generated.rs` 生成代码)。这里必须先排除同名误报: `p.search` / `provider.song_url` /
   `guard.logout` / `provider.album_detail` 都是**我们自己的 trait 方法**, 不是 vendor 的
   `search`/`song_url`/`logout`/`album_detail` 模块 —— 这 4 个模块随后被删。
2. 闭包: 在**已保留**模块里找 `crate::api::<mod>` 交叉引用, 迭代到不动点。
   结果: 交叉引用为 0 条追加(被引用的 `playlist_detail` / `song_detail` 等本来就在 service 已接入集里),
   即 118 个 service 接口自洽闭合。
3. `#[cfg(...)]` 门控引用: vendor `src/api` 里没有非 test 的 `cfg` 分支, 不存在隐藏依赖。

最终: 保留 **118** 个模块(= service 已接入集), 删除 **263** 个文件
(250 个未接入 endpoint + 13 个只被 `ncm-cli raw` 调试分发表引用的模块)。

### 保留清单(118)

```
like likelist lyric lyric_new song_detail song_purchased song_url_v1 song_wiki_summary cloudsearch search_default search_hot search_hot_detail search_multimatch search_suggest playlist_catlist playlist_create playlist_delete playlist_desc_update playlist_detail playlist_name_update playlist_subscribe playlist_track_all playlist_track_delete playlist_tracks user_playlist artist_album artist_detail artist_sublist artist_top_song album album_new album_newest album_sub album_sublist comment_album comment_delete comment_dj comment_event comment_floor comment_hot comment_info_list comment_like comment_music comment_mv comment_reply comment_playlist comment_video history_recommend_songs history_recommend_songs_detail personalized_newsong recommend_resource recommend_songs recommend_songs_dislike follow user_account user_detail user_followeds user_follows user_level user_medal user_record user_subcount fm_trash personal_fm daily_signin signin_progress dj_category_recommend dj_catelist dj_detail dj_hot dj_program dj_program_detail dj_program_toplist dj_recommend_type dj_sublist dj_subscriber dj_toplist dj_toplist_hours dj_toplist_newcomer dj_toplist_pay dj_toplist_popular simi_artist simi_playlist simi_song top_album top_artists top_playlist top_playlist_highquality top_song toplist_detail toplist_detail_v2 msg_comments msg_forwards msg_notices msg_private msg_private_history msg_recentcontact event event_forward share_resource resource_like record_recent_album record_recent_dj record_recent_playlist record_recent_song style_list style_playlist style_preference style_song digital_album_detail digital_album_purchased digital_album_sales vip_growthpoint vip_info_v2 vip_sign_info vip_tasks pl_count playmode_intelligence_list
```

### 删除清单分类

- **A. 264 个「service 未接入」中的 250 个**: 登录/验证族(`login*` `captcha_*` `register_*` `verify_*`)、
  云盘(`cloud*` `user_cloud*`)、音乐人/达人(`musician_*` `fanscenter_*`)、一起听(`listentogether_*`)、
  直播广播(`broadcast_*` `dj_difm_*`)、视频/MV(`mv_*` `video_*` `mlog_*`)、UGC 百科(`ugc_*`)、
  云贝(`yunbei_*`)、语音(`voice*` `voicelist_*`)、听歌足迹(`listen_data_*`)、
  以及 vendor 自带的通用代理 `api` 与 `eapi_decrypt` 工具模块。
  原生登录族本来就被判定弃用(见 `docs/api-coverage.md`: 必返 8821 安全环境风险, 走 WebView + `MUSIC_U`)。
- **B. 13 个「只被 `ncm-cli raw` 引用」**: `album_detail` `logout` `search` `song_url`(误报, 删) +
  `artist_songs` `personalized_djprogram` `playlist_category_list` `playlist_hot` `sign_happy_info`
  `simi_user` `song_lyrics_mark` `toplist` `vip_info`(真实调用, 见「偏离说明」)。

## 3. 执行步骤与验证

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 删模块 | `python3` 生成删除清单 → `git rm` | 263 个 `.rs` 删除, `git status` 可见 `D` |
| 剪清单 | 由 `git show HEAD:.../api/mod.rs` 重新生成 | 566 → **252** 行, 118 条 `mod`; 空 section 注释与孤立的 `#[allow(clippy::module_inception)]` 一并清掉, 尾部 `Query` 全部保留 |
| 修编译 | `cargo build --offline --workspace` | **0 error**(闭包判定正确, 无需回加模块) |
| 全 target | `cargo build --offline --workspace --all-targets` | 0 error(见「配套改动」对 vendor 集成测试的处理) |
| 单测 | `cargo test --offline -p ncm-domain -p ncm-service` | **119 passed, 0 failed**(22 + 97, 与基线一致) |
| 覆盖率 | `bash tools/api-coverage.sh` | vendor 118 / 已调用 118 / **未接入 0** |

## 4. P2: tokio 依赖瘦身

vendor `Cargo.toml`:

```diff
-tokio = { version = "1", features = ["full"] }
+# 仅 server 特性使用(TcpListener + sync::Mutex + #[tokio::main]), 非 server 构建不需要直接依赖
+tokio = { version = "1", features = ["rt-multi-thread", "macros", "net", "sync"], optional = true }
-server = ["axum", "tower", "tower-http", "tracing", "tracing-subscriber"]
+server = ["dep:axum", "dep:tower", "dep:tower-http", "dep:tracing", "dep:tracing-subscriber", "dep:tokio"]
```

依据: vendor 全库 `tokio::` 只出现在 `src/server/{mod,middleware}.rs`(`net` / `sync`)与
`src/bin/server.rs`(`#[tokio::main]` → `macros` + `rt-multi-thread`), 非 server 代码 0 处使用。
因此把 tokio 变 `optional` 后: `cargo tree -p ncm-api-rs --depth 1 -e normal` 里 **tokio 消失**
(直接依赖 17 → 16; 运行期 tokio 仍由 reqwest 传递引入, 不受影响)。
`dev-dependencies` 的 `tokio = { features = ["full","test-util"] }` 保持原样, `#[tokio::test]` 可用。

效果: `ncm-service` 依赖图里 tokio 的 `fs` / `process` / `signal` / `io-std` / `parking_lot` 等特性消失
(`cargo tree -p ncm-service -e features`)。

**未动**的 reqwest 特性: `socks` 保留 —— `src/request.rs` 用 `reqwest::Proxy::all(proxy_url)`,
用户可传 `socks5://` 代理, 去掉 `socks` 会**改变行为**, 按「不改行为」原则不动。

## 5. 前后对比

| 指标 | 裁剪前 | 裁剪后 | 变化 |
| --- | --- | --- | --- |
| vendor endpoint 模块 | 382 | **118** | −264 |
| service 已调用 / 未接入 | 118 / 264 | 118 / **0** | 未接入清零 |
| vendor `src` rs 文件 | 395 | **132** | −263 |
| vendor `src` 总行数 | 12,035 | **4,755** | **−60.5%** |
| vendor `src` 体积 | 1.7 MB | **604 KB** | −1.1 MB |
| `api/mod.rs` 行数 | 566 | **252** | −55% |
| 依赖数 ncm-service | 213 | **207** | −6 |
| 依赖数 ncm_ffi | 279 | **274** | −5 |
| 依赖数 ncm-cli | 257 | **252** | −5 |
| vendor 直接依赖 | 17 | **16**(少 tokio) | −1 |
| `cargo clean -p ncm-api-rs` 后重建 | 1.40 s | **0.66 s** | **−53%** |
| `libncm_ffi.so` release | 14,246,736 B | **14,165,640 B** | −81,096 B(−0.57%) |
| `libncm_ffi.so` strip 后 | 8,971,728 B | **8,919,808 B** | −51,920 B(−0.58%) |
| `ncm search 晴天 --limit 5` 中位 | 0.49 s | **0.45 s** | 不劣化 |
| `ncm url 186016` 中位 | 0.23 s | **0.21 s** | 不劣化 |
| `cargo test -p ncm-domain -p ncm-service` | 119 passed | **119 passed** | 一致 |

延迟测法: 用 `git worktree` 在 HEAD 单独编出**裁剪前**的 `ncm` 到 `/tmp/prune/base-target`,
与裁剪后二进制**交替**各跑 5 轮(每轮先 `unset` 全部 proxy 变量)取中位, 规避网络漂移。
(注: 单次延迟呈 0.11 s / 0.5 s 双峰, 是本地缓存 vs 真实请求的差异, 交替取样已抵消。)

## 6. 配套改动(超出「只删模块」必需的部分, 请审查)

1. `tools/api-coverage.sh`: 统计时排除 `mod.rs` —— 它是模块清单本身, 不是 endpoint。
   不排除时该脚本永远显示「未接入 1」(`mod` 被当成接口), 基线里的 382 也是含 `mod.rs` 的数。
2. `core/crates/ncm-cli/src/main.rs`: 删掉 `raw` 分发表里 9 个只调 vendor 的调试分支
   (`artist_songs` `personalized_djprogram` `playlist_category_list` `playlist_hot` `sign_happy_info`
   `simi_user` `song_lyrics_mark` `toplist` `vip_info`)。
   **这是「未接入 0」的必要条件**: 否则这 9 个模块只被 CLI 调试工具引用, 无法删除。
   产品路径(UI → FFI → service)完全没用到它们; 若需要恢复, `git restore` 该文件并从 `git show HEAD`
   里回加 9 个 `.rs` 即可。
3. `core/vendor/ncm-api/tests/integration.rs`: 删掉 4 个引用已删 endpoint 的联网用例
   (`test_banner` / `test_toplist` / `test_login_status_without_cookie` / `test_countries_code_list`),
   否则 `cargo build --all-targets` 与 `ci.sh` 的 `-p ncm-api-rs --test integration` 会编译失败。
   剩余 4 个用例(cloudsearch / song_detail ×2 / search_hot_detail)保持原样。

## 7. 已知偏差 / 未达标项

- **`cargo build -p ncm-api-rs --features server` 现在会失败**(E0599: `avatar_upload` / `voice_upload`):
  `src/server/upload.rs` 调用了这两个已删模块。该特性**本项目从未启用**(`ncm-api-rs` 在 workspace 里是
  `default-features = false`, 产品路径不打 axum/tower), 且 `server/` 属于禁止修改范围, 故按预期不动。
  两条修法(任选): ① 把 `avatar_upload` / `voice_upload` 加回保留集(代价: 未接入变 2);
  ② 改 `server/upload.rs` 移除这两个路由(需解禁 `server/`)。
- `api-coverage.sh` 的「FFI 125 个中 UI 没入口」从基线的 3 降到 2: 与本任务无关,
  是同期另一位子代理改了 `ui/` 造成的噪声。

## 8. 回滚预案

一条命令还原 vendor 全部改动(含删除、`mod.rs`、`Cargo.toml`):

```bash
git restore --staged --worktree core/vendor
```

其余三个文件的回滚:

```bash
git restore tools/api-coverage.sh core/crates/ncm-cli/src/main.rs
```

回滚后 `cargo build --offline --workspace` + `bash tools/api-coverage.sh` 应回到 382/118/264 基线。

---

## 9. 编排者独立复核(2026-11-09, 不信 worker 自报, 全部重跑)

| 门 | worker 自报 | 编排者重跑 | 结论 |
|---|---|---|---|
| `cargo build --offline --workspace --all-targets` | 0 error | **0 error**(1.97 s) | ✅ |
| `cargo test -p ncm-domain -p ncm-service` | 119 | **119**(domain 22 + service 97) | ✅ |
| `tools/api-coverage.sh` | 118/0 | **118/118(100%)/0**, 无 UI 入口 2 | ✅ |
| 冷编译 vendor(`cargo clean -p ncm-api-rs`) | 1.40→0.66 s | **0.65 s** | ✅ |
| 依赖数(同口径 `cargo tree --prefix none \| sort -u \| wc -l`) | 213/279/257 → 207/274/252 | **207 / 274 / 252**(一致) | ✅ |
| vendor 体量 | 12,035→4,755 行, 1.7 M→604 K | 我按 `src/*.rs + api/*.rs + util/*.rs` 计 **4,069 行 / 564 K**(含 `server/` 删除后); agent 数含 server/crypto/request 全文 | ✅ 量级一致 |
| release `libncm_ffi.so` | 14,165,640 / strip 8,919,808 | 移除死特性后 **14,157,856 / strip 8,918,104**(基线 14,246,736 / 8,971,728) | ✅ −89 KB / −54 KB |
| **Android arm64 交叉编译**(裁剪是否破坏 cargokit 链路) | 未自报 | ✅ 通过: `cargo build --release -p ncm_ffi --target aarch64-linux-android` 20.4 s, 产物 12,197,912 B → `llvm-strip` 后 **6,564,056 B** | ✅ |
| `ncm search/url` 延迟 | 0.49→0.45 / 0.23→0.21 s | 复跑遇到本机对 interface.music.163.com 的间歇 `Connection reset`(与裁剪无关, spike 同日也见), 成功样本 0.10–0.53 s | ⚠️ 未劣化, 但网络抖动使单次测量不可用 |

### 9.1 编排者追加的改动(修掉唯一未达标项)

worker 报告的唯一未达标项是 `cargo build -p ncm-api-rs --features server` E0599(`avatar_upload`/`voice_upload` 已删,
`src/server/upload.rs` 仍在用)。**处置 = 直接删除这个死特性**(而非加回模块或解禁 server):

- `core/vendor/ncm-api/src/server/`(3 文件)、`src/bin/server.rs` 已 `git rm`;
- `Cargo.toml` 删 `[features] server`、`[[bin]] ncm-server`、以及只为它存在的 `axum/tower/tower-http/tracing/tracing-subscriber` 可选依赖,
  `tokio` 从 `[dependencies]` 整体移除(库本体不用, 仅 dev-dependencies 的测试用);
- `src/lib.rs` 删 `#[cfg(feature = "server")] pub mod server;`。
- 理由: 本项目是内嵌客户端形态(FFI 直调库), 该特性从未启用; 「可选但一启用就编译失败」是被裁 endpoint 后的必然结果,
  留着只是陷阱。上游原文可由 `vendor/UPSTREAM.txt` 的锁定 commit 找回。
- 复核: `--all-targets` 0 error、119 测试全绿、coverage 118/0 不变。

### 9.2 已知取舍(非缺陷, 记录以免将来误判)

- **vendor 联网 smoke 8 → 4 例**: 删掉的 4 例(`banner`/`toplist`/`login_status`/`countries_code_list`)全部打在未接入 endpoint 上,
  保不住模块就保不住用例; 已同步 `tools/ci.sh` 注释与 `.pi/memory/FAILURES.md` 的"8 例"提法。
- **`ncm-cli raw` 少 9 个分支**: 均为已删模块的逃生口, 产品路径(UI→FFI→service)不经过; `raw recommend_songs` 等仍可用。
- **`tools/api-coverage.sh` 排除 `mod.rs`**: 它是模块清单不是 endpoint, 不排除会永远显示"未接入 1"。
