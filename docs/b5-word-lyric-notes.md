# B5 逐字歌词 · 实测 notes(契约层, 2026-11-09)

## 端点与开关
- 逐字歌词走 vendor `lyric_new`(`/api/song/lyric/v1`), body 由 vendor 写死
  `cp:false, tv/lv/rv/kv/yv/ytv/yrv 全 0` + `id`。实测 yv:0 即会返回 `yrc`(有则给);
  query 里传其它参数无效(vendor 不读)。
- 对比旧 `lyric`(`/api/song/lyric`): 只有 lrc/tlyric/romalrc/klyric, **永远没有 yrc**。

## 响应形状(实测 id=1901371647 / 5264842 / 418602084 / 516076896)
顶层: `code, klyric, lrc, qfy, sfy, sgc, tlyric, romalrc, yrc, ytlrc, yromalrc,
lyricUser, transUser`。各歌词子对象是 `{version, lyric}`;`version:0 / lyric:""` = 无。
- 晴天(186016, 2004): **无 yrc**(老歌没有逐字);新歌榜歌曲基本都有。
- `ytlrc`(yrc 翻译)与 `yromalrc`: 抽样 8+ 首全部为空(实测恒空), 翻译仍只能靠
  `tlyric`(普通 LRC, 时间戳为行首 ms, 可与 yrc 行 start 对齐)。

## yrc 两种行格式(同一份文本混排)
1. 元数据/署名行(JSON): `{"t":0,"c":[{"tx":"作词: "},{"tx":"方文山","li":"...jpg","or":"orpheus://..."}]}`
   - `t` 是行首 ms, 可为负(实测 -1000/-667);无数词级时间;无行尾时长。
2. 逐字行: `[start,duration](wStart,wDur,0)字(wStart,wDur,0)字...`
   - 实测样例:
     ```
     [25120,7400](25120,1190,0)你(26380,450,0)陪(26830,340,0)我(27170,300,0)步(27470,350,0)入(27820,360,0)蝉(28180,470,0)夏 (29400,440,0)越...
     [21960,7590](21960,470,0)让(22430,2610,0)我(25400,280,0)与(25680,640,0)你(26320,1940,0)握(28290,750,0)别
     ```
   - 词文本可含空格/标点(`夏 `带尾空格);第三元恒 0(语义未知)。
   - 词 start 可与行 start 不等(前奏对齐), 词时长可为 0。

## song_lyrics_mark(只读 dump, 未接)
`/api/song/play/lyrics/mark/song`, body `{"songId": id}`;已加进 CLI `ncm raw song_lyrics_mark id=..`。
add/del(`/add` `/del`)是写操作, 本批禁接。

## 实现事实(契约层)
- domain: `WordItem{start_ms,end_ms,text}` / `WordLyricLine{start_ms,end_ms,words}` /
  `WordLyric{lines, translation_lines, has_word_timing, raw}`;全部 serde(default)。
- 解析失败退化: 逐字行头 `[..]` 解析不出 → 整行原文作为单个整词(start/end=0),
  绝不 panic、绝不丢行;JSON 署名行保留为单词行(`has_word_timing=false`)。
- 翻译: `tlyric` 按 LRC 解析后按行 start_ms 精确对齐到 `WordLyric.translation_lines`。
- provider: trait 新增 `word_lyric`, 默认 `unsupported`;netease 实现(复用 `Capability::Lyric`),
  内部调 `client.lyric_new`;CAPABILITIES 不变。
- FFI 导出 `word_lyric(track)`;CLI `ncm yrc <songId>`。
- 已知遗留: `ytlrc/yromalrc` 实测恒空;负时间戳按 clamp 0 处理;klyric 实测恒 ver0。

## CLI 验证实录
- `ncm yrc 5264842`: 24 行 / 162 词 / 逐字有 / 翻译行 0;逐字行与署名行混排均正确。
- `ncm yrc 186016`(晴天): "(no yrc: 该曲无逐字歌词)" —— 退化路径符合预期。
- `ncm raw song_lyrics_mark id=186016`: `{"code":200,"data":{"markCountList":[],"markVOList":[]}}`(本账号未标记过)。

## 门禁(2026-11-09)
- `cargo test --workspace --exclude ncm-api-rs`: 全绿(domain 22 / service 92(+3) / provider 2 / playback 1)。
- `cargo build -p ncm_ffi`: 通过(0 warning)。
- codegen 一次通过;ui/lib/src/rust/* 仅生成物。
- `cd ui && dart analyze`: **0 error**(30 info, 全部为既有 lint 风格)。
- `cd ui && flutter test`: **215 passed**(含 frb_smoke, 未复现偶发挂)。
- 未跑 tools/ci.sh / flutter build / 未 commit。

## 改动文件清单
- core/crates/ncm-domain/src/word_lyric.rs(新) + lib.rs(导出)
- core/crates/ncm-provider/src/lib.rs(trait word_lyric 默认 unsupported)
- core/crates/ncm-service/src/netease.rs(parse_word_lyric_body + 实现 + 3 单测)
- core/crates/ncm-ffi/src/api.rs(WordItemDto/WordLyricLineDto/WordLyricDto + word_lyric_lines)
- core/crates/ncm-cli/src/main.rs(`ncm yrc` + raw 补 song_lyrics_mark + 用法清单)
- ui/lib/src/rust/*(codegen)
- 本文件(新)
