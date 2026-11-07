# Wave 9 · §4 剩余只读 endpoint 收尾笔记(2026-11-09)

> 实测通道: weapi, 登录态(device BF448268...); 匿名与登录对下列只读接口响应形状一致。
> 命令: `source tools/env.sh && unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY`
> 后 `cargo run -q -p ncm-cli -- raw <method> k=v` / `ncm <新子命令>`。

## 1. album_newest(已接入, `ncm album-newest`, FFI `newest_albums`)

vendor `album_newest`(`/api/album/newest`)。实测顶层 `{code, albums:[...]}`,
**固定 12 张, 无 total, 不翻页**; 专辑对象与 `album_new` 同构(吃现成 `parse_album_item`)。

与已接入 `album_new`(`/api/album/new`)的差异: **不是重复接口** ——
- album_new: 带 `total=500`, limit/offset 翻页, 内容偏"分地区新碟"(与 top_album 同族);
- album_newest: 恒 12 张编辑精选, 与 album_new 前 5 的 id 集合完全不同(实测对比 404764114… vs 408291414…),
  额外字段无(awardTags/displayTags/mark 是 album_new 有、newest 没有的)。
判定: 保留两者, newest 作"最新专辑"入口(12 张), album_new 继续当新碟广场数据源。

单测: `album_newest_parses_real_shape` / `album_newest_missing_albums_is_empty`。

## 2. toplist_detail_v2(已接入, `ncm toplist-v2`, FFI `toplist_catalog`)

vendor `toplist_detail_v2`(`/api/toplist/detail/v2`)。实测顶层 `{code, data:[...], message, msg}`,
`data` 是分组数组(顺序 TOPPING(6)/OFFICIAL(7)/FEATURE(9)/MUSIC_STYLE(6)/GLOBAL(6)/LANGUAGE(7)/MORE(4)),
每项 `{categoryCode, displayType, list:[榜单卡]}`; 榜单卡关键字段:
`id, name, coverUrl, updateFrequency, targetType(实测恒 "PLAYLIST"), canPlay`。

**文档口径 vs 实测差异**:
- 计划里说 v2 给"更新 N 首"增强字段 —— 实测**没有** v1 的 `trackUpdateTime`/`trackNumberUpdateTime`
  数字字段; "更新18首/刚刚更新"只以**字符串**混在 `updateFrequency` 里(且 v1 也有同样的字符串)。
- v1(`toplist_detail`)是平铺 34 张榜的 `list`; v2 的增量是 categoryCode 分组 + canPlay。
- 个别卡片 `id=0 且 canPlay=false`(如 FEATURE 里的"实体专辑榜"), 解析器保留但 UI 不可点。

解析: `parse_toplist_catalog` → `ToplistCatalogGroup{code, items}`; data 缺失/空数组返空目录。
单测: `toplist_catalog_parses_real_shape` / `toplist_catalog_missing_data_is_empty`。

## 3. simi_user(只 dump, 不实现)

vendor `simi_user`。实测(登录态, id=32953014 / 78473939, `id` 与 `userId` 两种参数名都试过):

```json
{ "code": 200, "userprofiles": [] }
```

多次恒空 —— 该接口对当前账号/这些 uid 不再返回相似用户(疑似服务端已下线或灰度关闭)。
判定: 无可解析的真实形状, 按"实测恒空"记档不做 DTO/FFI; 相似推荐族已有
simi_song/simi_playlist/simi_artist 三兄弟, 缺口留待接口恢复。

## 4. comment_mv / comment_video(已接入, 复用 CommentPage)

vendor `comment_mv` = `/api/v1/resource/comments/R_MV_5_<id>`(weapi, rid/limit/offset/beforeTime);
`comment_video` = `R_VI_62_<id>`。响应与歌曲评论同形
(`{code, total, more, hotComments, comments, topComments, cnum, isMusician, userId}`),
**直接复用现有 `parse_comments` → `CommentPage`**, 不需要新 DTO。

落地: provider `comments()` 新增 kind `"mv"`/`"video"`(thread_id_for 本来就有 R_MV_5_/R_VI_62_ 前缀),
FFI `comments()` 的 kind 参数透传, CLI `ncm comments mv <id>` / raw 补 `comment_mv`/`comment_video` 接线。
实测: `comments mv 5436712` → total=689, 热评在前; raw comment_video id=144634 → 200 + 空 comments
(该视频 id 无评论, 形状已确认)。
单测: `mv_video_comments_share_comment_page_shape`。

## 门禁记录

- cargo test --workspace --exclude ncm-api-rs: 全绿(service 96→102)
- cargo build -p ncm_ffi / codegen 一次通过(frb_generated.* + ui/lib/src/rust/*)
- dart analyze / flutter test 见 PROGRESS 后续记录
