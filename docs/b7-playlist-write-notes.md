# B7 歌单写接口 · 真实响应笔记(2026-11-10)

> 批次: 歌单写接口 + 播放队列「存为歌单」(B2④ 最后一项)。
> 抓包方式: 临时 example `core/crates/ncm-service/examples/b7_probe.rs`(跑完已删)直连 vendor `ApiClient`,
> 登录态为本地测试号(#1822714196),数据目录 `~/.local/share/ncm`。**必须清代理直连**(clash 7890 会把
> weapi TLS 握手掐成 `tls handshake eof`);Query 必须带 `platform_profile().ua`(与 cookie os 形态配套),
> 否则服务端回 `{code:500, msg:"请求异常,请稍后重试"}`。

## 1. playlist_create(/api/playlist/create, weapi)

请求参数: `name` / `privacy`(0=公开) / `type`="NORMAL"。

```json
{"code":200,"id":18580697682,"playlist":{"id":18580697682,"name":"B7抓包临时歌单 20261110-023344","privacy":0,
"trackCount":0,"userId":1822714196,"subscribedCount":0,"playCount":0,"coverImgUrl":"https://p1.music.126.net/...",
"createTime":1794278024690,"tags":[],"subscribers":[],"tracks":null,"description":null,...}}
```

- **新歌单 id 字段名: 顶层 `id`(数字)**,`playlist.id` 是同值冗余(现有 `create_playlist` 的 `u64_of(body,"id").or_else(playlist.id)` 双路提取正确)。
- `playlist.privacy` 回显 0;`trackCount`=0。

## 2. playlist_tracks(/api/playlist/manipulate/tracks, op=add)

请求参数: `op`="add" / `pid`=<歌单id> / `tracks`="186016,26305527"(vendor 内部拆逗号后 JSON 序列化成
**字符串数组** 再放 `trackIds` 字段)/ `imme`="true"。

```json
{"cloudCount":0,"code":200,"count":2,"coverImgId":"109951167894836691",
"coverImgUrl":"http://p3.music.126.net/.../109951167894836691.jpg","trackIds":"[186016,26305527]"}
```

- **响应里的 `trackIds` 是字符串**(数组 JSON 文本),不是数组——不要当数组解析。
- `count`=2 = 服务端接受的成功数;批量去重后返回的 count 可小于提交数。
- 成功时**没有** message/msg 字段。
- 判定成功只看 `code==200`。

## 3. playlist_delete(/api/playlist/delete)

```json
{"code":200,"data":null,"message":null,"msg":null}
```

## 4. 清理记录

- 抓包新建 `B7抓包临时歌单 20261110-023344`(id=18580697682)→ add 2 首(186016/26305527)→
  `playlist_delete` 返回 code=200,**已删除**(只删了本次自建的这个)。

## 5. 现状与本批落地(防复述过时结论)

- provider/FFI **已有一组**歌单写接口(v0.2.2 收藏到歌单流程接的): `create_playlist(name)` /
  `add_to_playlist(pid, 单首)` / `delete_playlist` / `rename_playlist` / `update_playlist_desc` /
  `remove_from_playlist`,能力键 `Capability::PlaylistEdit` 已在 `CAPABILITIES`。
- 本批新增: ①`create_playlist` 签名扩展 `privacy` 参数(vendor 默认 0,不传会撞上「请求异常」的
  隐式默认——显式传更稳); ②**批量** `playlist_tracks_add(pid, song_ids)`(vendor `playlist_tracks` 原生支持
  逗号分隔多 id,现有 `add_to_playlist` 只有一首); ③domain `CreatedPlaylist`/`PlaylistEditResult` + parse 单测;
  ④FFI `createPlaylist(name, privacy)` / `playlistTracksAdd(pid, songIds)`; ⑤队列面板「存为歌单」。

## 6. 落地清单(本批终稿)

- **domain** `ncm-domain/src/playlist_edit.rs`(新): `CreatedPlaylist{id,name}` / `PlaylistEditResult{code,message,count,ok}`,全字段
  `serde(default)`。**parse 函数放 `ncm-service/src/netease.rs`**(`parse_created_playlist`/`parse_playlist_edit_result`)——
  ncm-domain 是纯数据 crate 不依赖 serde_json(与 ttml.rs 手写解析同一纪律),任务书里「parse 单测在 domain」按此口径落在 service。
- **provider**: `create_playlist` 扩展 `privacy: u8` 参数(改签名,调用点: FFI + main.dart 各 1);
  新增 `playlist_tracks_add(playlist_id, &[u64])`(默认 unsupported)。`Capability::PlaylistEdit` 已在
  `CAPABILITIES` 且 `capabilities_include_new_apis` 已覆盖,无需新增能力键。
- **FFI**: `createPlaylist(name, privacy)`(Dart privacy: int)/ `playlistTracksAdd(playlistId: BigInt, songIds: Uint64List)`
  (frb 把 `Vec<u64>` 映射成 frb 自带的 `Uint64List`,**不是** `dart:typed_data` 的,import 要走
  `package:flutter_rust_bridge/flutter_rust_bridge.dart show Uint64List`)。codegen 已跑一次。
- **UI**: `PlayQueueSheet` 头部新增「存为歌单」(`Icons.playlist_add`,空队列不渲染、挂起置灰);面板只把
  **去重后**的快照经 `onSaveAsPlaylist` 回调交宿主(可脱机单测);宿主 `main.dart` `_saveQueueAsPlaylist`
  = 列我的歌单 sheet(新建行 + myPlaylists)→ 新建对话框(默认名「来自播放队列 M-D HH:mm」,
  create(privacy=0) → playlistTracksAdd)或选已有歌单直接批量加 → toast「已存入《名字》, N 首」/失败 friendlyError。
  「我喜欢的音乐」(special)也走 playlistTracksAdd(官方网页端同一接口)。
- **测试**: Rust +6(netease.rs parse 单测,真实响应片段); Dart +6(`ui/test/queue_sheet_save_test.dart`:
  空队列无按钮 / 非空出现 / 成功回调收到快照 / 去重 / 防重复点击 / 失败不崩可重试)。
- **门禁数字(2026-11-10 本批实测)**: `cargo test --offline --workspace --exclude ncm-api-rs`
  218(HEAD 基线)→ **224**(+6,零删除;vendor smoke 4 例联网项按记录在案口径 WARN 不阻塞);
  `dart analyze` **0 error/0 warning**(41 info 均为既有 lint);`flutter test --exclude-tags network`
  504 → **510**(+6);`tools/api-coverage.sh`: vendor 123/123(100%)不变,FFI 导出 139→**140**
  (`playlistTracksAdd`,有 UI 入口),无 UI 入口维持 4(`cache_stats`/`eq_profile_normalize`/`player_tuning`/`word_lyric_with_fallback`)。

## 7. 模拟器实测(emulator-5554, 2026-11-10)

- **前提修复**: 模拟器 App 登录态随快照回滚丢失 → 用宿主 CLI 测试号(#1822714196 下去玩)的 `identity.json`
  `run-as` 灌入 `files/ncm/`(重启 App 生效),全程无凭据明文操作。
- **路径**: 搜索 The Weeknd → 「下一首播放」×2(队列恰好 2 首,播放条 1/2)→ 详情页「队列 2」→ 面板头部
  「存为歌单」→ sheet(新建行 + 真实 myPlaylists)→ 新建对话框(**默认名已预填**「来自播放队列 11-10 11:52」)→ 创建。
- **结果(双重验证)**:
  - toast「已存入《来自播放队列 11-10 11:52》, 2 首」;
  - sheet 列表立即出现「来自播放队列 11-10 11:52 | 2 首」;
  - CLI `ncm playlists`:`[18580899619] 来自播放队列 11-10 11:52 (2 首)`;
  - CLI `ncm playlist 18580899619`:song_count=2,**正是队列两首**(After Hours 1424460203 + Hong Kong 3456047164)。
- **幂等**: 再走「选已有歌单」把同 2 首重复添加 → 服务端跳过已存在(本批实测与协议预期一致),歌单仍 2 首。
- **logcat**: 全流程 0 崩溃(FATAL/SIGSEGV 扫描为空)。
- **实测顺带修的缺陷**: `_saveQueueAsPlaylist` 里 `retryNetwork(myPlaylists)` 失败原本被面板 catch 静默吞掉
  → 补 try/catch + toast「存为歌单失败: ...」(任务书「失败给可读文案」口径)。
- **已知观察(非本批 bug)**: 创建成功后连续两层 sheet(选择 sheet + 队列面板)偶发渲染空白(语义树空、无异常、
  进程活),force-stop 重启即恢复;功能与数据无影响,模拟器 Impeller/OpenGLES 环境的已知类问题,后续批次观察。
- **清理**: 实测歌单「来自播放队列 11-10 11:52」与抓包孤儿「B7抓包临时歌单 20261110-023224」(后者是
  create 返回 code=500 但服务端实际入库的**孤儿**——「请求异常」也可能半成功,删号见此)均已 `playlist_delete`
  (ok=true),CLI 复核 grep=0。截图 5 张在 `.pi/artifacts/b7/`。
- **代码层落地小结**: 任务书「FFI 无歌单写接口」的口径已过时——v0.2.2 已有单首版收藏到歌单(`add_to_playlist`)
  与 `create_playlist(name)`;本批实际增量 = create 加 `privacy` 参数 + **批量** `playlist_tracks_add` +
  domain DTO/parse + UI「存为歌单」,vendor 侧零改动(mod.rs 早已注册)。
