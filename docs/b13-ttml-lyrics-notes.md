# B13: AMLL TTML 逐字歌词第二来源（实测笔记）

日期：2026-11-10

## API 实测

- 端点：`GET https://api.amll.dev/v1/lyrics/get?ncmMusicId=<id>`
- 响应为 JSON：`{"status":200,"data":{...}}`；**内联 TTML 全文在 `data.lyrics` 字段**（字符串）。
- `data` 其他字段：id/filename/createdAt/musicNames/artistNames/albumNames/ncmMusicIds/qqMusicIds/appleMusicIds/spotifyIds/isrcs/authorIds/authorUsernames。
- 无 TTML 的曲目（如 ncmMusicId=99999999）：HTTP 404，body `{"status":404,"error":"Not Found","message":"No lyrics found for the provided query."}` ⇒ 我们映射为 `Ok(None)`。
- 未观察到 rate limit 头；客户端仍设 5s 超时 + 磁盘缓存兜底。

### curl 复现

```bash
curl -s --noproxy '*' 'https://api.amll.dev/v1/lyrics/get?ncmMusicId=186016'   # 晴天，200
curl -s --noproxy '*' 'https://api.amll.dev/v1/lyrics/get?ncmMusicId=99999999' # 404
```

## TTML schema 实测（晴天片段，截断）

```xml
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="..." xmlns:itunes="..." xmlns:amll="...">
  <head><metadata xmlns=""><ttm:agent type="person" xml:id="v1"/>
    <amll:meta key="ncmMusicId" value="186016"/> ...</metadata></head>
  <body dur="04:25.541">
    <div xmlns="" begin="00:29.231" end="04:25.541">
      <p begin="00:29.231" end="00:32.723" ttm:agent="v1" itunes:key="L1">
        <span begin="00:29.231" end="00:29.692">故</span>
        <span begin="00:29.692" end="00:30.057">事</span> ...
      </p> ...
    </div>
  </body>
</tt>
```

要点：
- 时间格式 `m:ss.mmm`（也可能出现纯秒，解析器两种都支持）。
- 逐字在 `<p>` 内联 `<span begin end>text</span>`；无文本的 span（纯计时/间奏）跳过。
- `ttm:role="x-translation"` 的 `<p>` 为行译文、`x-roman` 为罗马音（解析保存，UI 暂不用）；`x-bg` 背景声跳过。
- 缺 end 的行/span 用下一行 begin 兜底。

## 质量/回退策略

`word_lyric_with_fallback(song_id)`：yrc 优先 → yrc 无逐字或逐字 span 覆盖率 < 0.6（覆盖行数比例，阈值见代码注释）→ 试 TTML（磁盘缓存）→ 都没有回退行级歌词。

## 缓存

- 命中：`dataDir/ttml/<id>.ttml`
- 无数据/解析失败：`dataDir/ttml/<id>.none` 标记，避免反复打 API。