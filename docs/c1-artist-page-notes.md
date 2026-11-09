# C1 歌手详情页重构 — 接口实测笔记

日期: 2026-11-22。探测方式: 临时 example `core/crates/ncm-service/examples/probe_artist.rs`
(复跑: `cargo run --offline --manifest-path core/Cargo.toml -p ncm-service --example probe_artist`),
账号为本地已登录 session(`~/.local/share/ncm`)。样例歌手: 周杰伦 id=6452。

## 模块恢复

从 `git show 5cfc301^:core/vendor/ncm-api/src/api/<module>.rs` 恢复:

- `artist_songs`(全部歌曲, weapi `/api/v1/artist/songs`)
- `artist_mv`(MV, `/api/artist/mvs`)
- **动态: 未实现**。vendor(含 5cfc301^ 裁剪前全量)只有用户动态 `event`(/api/v1/event/get, 走登录用户自己)与
  `user_event`(/api/event/get/{uid}); **不存在“歌手动态”接口**, 不能用用户动态接口按歌手过滤。
  故 UI 不出现“动态”Tab, provider trait 也不加 artist_events 方法。

## artist_songs 实测响应(截断)

请求: `{"id":"6452","private_cloud":"true","work_type":1,"order":"hot","offset":0,"limit":5}`

```json
{
  "code": 200,
  "more": true,
  "songs": [
    {
      "id": 298317, "name": "屋顶", "dt": 319039, "fee": 0, "mv": 0, "pop": 100.0,
      "ar": [{"id":9612,"name":"温岚"},{"id":6452,"name":"周杰伦"}],
      "al": {"id":29597,"name":"有点野","picUrl":"https://p4.music.126.net/....jpg"},
      "privilege": {"st":-53918, "dl":999000, "dlLevel":"jyeffect"}
    }
  ]
}
```

我们真正用的字段: `songs[]`(id/name/ar/al/dt/fee + 每首歌自带 privilege 判 playable — 直接复用
`parse_song_list`)、`more`(hasMore)。`order` 默认 hot。

## artist_mv 实测响应(截断)

请求: `{"artistId":"6452","limit":3,"offset":0,"total":true}`(weapi)

```json
{
  "code": 200,
  "hasMore": true,
  "mvs": [
    {
      "id": 22695250, "name": "任性 (5525 Live版)",
      "artistName": "周杰伦", "duration": 266000,
      "playCount": 106722, "publishTime": "2025-02-23",
      "imgurl": "http://p3.music.126.net/....jpg",
      "imgurl16v9": "http://p4.music.126.net/....jpg",
      "status": 0, "subed": false
    }
  ],
  "time": 1469116800007
}
```

我们用的字段: `mvs[]`(id/name/duration/playCount/publishTime/imgurl16v9)、`hasMore`。offset/limit 分页。
MV 播放首期不在范围(只展示)。

## 分页语义(实测确认 page1/page2 不重叠)

- artist_songs: offset/limit, `more`=true 还有下一页。
- artist_mv: offset/limit, `hasMore`=true 还有下一页。

## UI 决策

- Tab: 热门歌曲 / 全部歌曲 / 专辑 / MV(无 MV 或失败时不显示); 动态 tab 不存在(见上)。
- 页内搜索: 仅过滤 热门歌曲 + 全部歌曲 两个 tab(就地过滤, 不发请求)。
- 相似歌手保留在头部之下(非 tab), 用 Wrap 防溢出。
