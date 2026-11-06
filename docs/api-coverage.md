# 网易云接口覆盖清单(vendor ncm-api ↔ 本仓库)

> 最近更新: 2026-11-06。口径与复算方式见文末, 一条命令可重跑。

## 1. 总览

| 指标 | 数值 |
|---|---|
| vendor `core/vendor/ncm-api/src/api/*.rs` 里的 endpoint 模块 | **382** |
| `ncm-service`(provider)实际调用的 | **45(11%)** |
| 未接入 | **337** |
| FFI 导出给 Dart 的函数 | 61 |
| 其中 UI 还没有入口的 | 6(`lyric` `lyric_lines` `search` `podcast_program` `podcast_radio` `ping`) |

复算:

```bash
bash tools/api-coverage.sh          # 只打统计
bash tools/api-coverage.sh --list   # 附带已接入/未接入全名单
```

结论先说: **播放链路(搜索/取链/歌词/歌单/专辑/歌手/播客/动态/排行/风格)已经够用**,
剩下的缺口集中在三块 —— ①"内容发现"类(排行榜/歌单广场/新歌新碟/相似推荐)、
②"社区互动"类(评论点赞/私信通知/转发)、③"账号周边"类(收藏专辑/关注粉丝/歌单编辑/签到)。
④ MV/视频、云盘、一起听、创作者中心这类需要额外能力(视频解码、上传分片、长连接、权限)的, 建议先不做。

## 2. 已接入(45 个 endpoint → 22 项 UI 能力)

| 能力 | vendor 接口 | UI 位置 |
|---|---|---|
| 综合搜索 | `cloudsearch` | 搜索 tab(单曲/歌手/专辑/歌单/播客) |
| 搜索联想/热词/默认词 | `search_suggest` `search_hot` `search_default` | 搜索落地页 |
| 取播放直链 | `song_url_v1` | 播放 |
| 歌词 | `lyric` | 歌词页(逐行/翻译) |
| 曲目详情/红心 | `song_detail` `like` `likelist` | 我喜欢/红心 |
| 歌单 | `user_playlist` `playlist_detail` `playlist_track_all` `playlist_subscribe` `playlist_tracks` | 我的歌单/歌单页/收藏/收藏到歌单 |
| 专辑 | `album` | 专辑预览/详情 |
| 歌手 | `artist_detail` `artist_top_song` `artist_album` | 歌手页 |
| 账号/资料 | `user_account` `user_detail` `artist_sublist` | 顶部账号/我的资料卡/关注艺人 |
| 每日推荐/私人FM/心动模式 | `recommend_songs` `recommend_resource` `personal_fm` `playmode_intelligence_list` | 推荐页/心动模式 |
| 播客/电台 | `dj_hot` `dj_detail` `dj_program` `dj_program_detail` `dj_sublist` | 推荐播客/播客详情 |
| 关注动态 | `event` `event_forward` `resource_like` | 关注 tab |
| 评论 | `comment_music` `comment_playlist` `comment_album` `comment_dj` `comment_event` | 评论区 |
| 分享 | `share_resource` | 歌曲操作菜单 |
| 最近播放 | `record_recent_song` | 我的/最近听过 |
| 听歌排行 | `user_record` | 我的/听歌排行 |
| 曲风推荐 | `style_preference` `style_list` `style_song` `style_playlist` | 推荐/风格推荐 + 曲风页 |

## 3. 未接入 · 建议优先做(P0, 都为纯 HTTP + 现有 DTO 能装下)

| # | 能力 | 接口 | 落地位置 | 备注 |
|---|---|---|---|---|
| 1 | 排行榜(热歌/新歌/飙升/原创) | `toplist` `toplist_detail` `toplist_detail_v2` `toplist_artist` | 推荐页入口 + 榜单详情(复用歌单页) | 最高性价比: 详情返回就是 songs 数组 |
| 2 | 歌单广场/分类浏览 | `playlist_catlist` `playlist_category_list` `playlist_hot` `top_playlist` `top_playlist_highquality` `playlist_highquality_tags` | 发现/推荐页"歌单分类" | 目前只能看推荐 & 自己收藏 |
| 3 | 新歌/新碟/热门单曲 | `personalized_newsong` `album_new` `album_newest` `top_song` `top_album` `top_artists` | 推荐页新增区块 | 现成 DTO(Song/AlbumBrief) |
| 4 | 相似推荐 | `simi_song` `simi_playlist` `simi_artist` `simi_user` | 歌曲操作菜单"相似歌曲"/歌手页"相似歌手" | 扩展收听路径 |
| 5 | 收藏专辑 | `album_sub` `album_sublist` | "我的"新增"收藏的专辑" + 专辑页收藏按钮 | 现在专辑只能看不能收 |
| 6 | 歌单编辑 | `playlist_create` `playlist_delete` `playlist_name_update` `playlist_desc_update` `playlist_track_add` `playlist_track_delete` `playlist_privacy` `playlist_order_update` | 歌单页/歌曲菜单 | 现在"收藏到歌单"无法新建歌单 → 体验断点 |
| 7 | 评论点赞/楼层/回复 | `comment_like` `comment_floor` `comment_reply` `comment_hot` `comment_delete` | 评论区 | 目前只能看和翻页 |
| 8 | 关注/粉丝列表 | `user_follows` `user_followeds` `user_subcount` `follow` `user_follow_mixed` | 资料卡的"关注 44·粉丝 11"点进去 | 数字现在是死的 |
| 9 | 最近播放分类 | `record_recent_album` `record_recent_playlist` `record_recent_dj` `record_recent_video` `record_recent_voice` | "我的/最近听过"加分类 tab | 现有最近听过只有单曲 |
| 10 | 不感兴趣 | `recommend_songs_dislike` `fm_trash` | 每日推荐/FM 菜单 | 调教推荐必需 |
| 11 | 历史日推 | `history_recommend_songs` `history_recommend_songs_detail` | 每日推荐页"历史推荐" | 错过当天也能补 |
| 12 | 歌词增强 | `lyric_new`(逐字) `song_lyrics_mark*`(4 个) `song_wiki_summary`(歌曲百科) | 歌词页/歌曲详情 | 现有歌词接口是逐行, 逐字要新接口 |
| 13 | 签到 | `daily_signin` `signin_progress` `vip_sign` `vip_sign_info` `sign_happy_info` | "我的"/设置 | 只读展示即可, 不碰支付 |
| 14 | 搜索增强 | `search_match` `search_multimatch` `pl_count` `search_hot_detail` `batch` | 搜索联想/结果数 | 联想现在只走 suggest |
| 15 | 听歌识别 | `audio_match` | 搜索页"听歌识曲" | 需录音权限 + 指纹采集(约 10s), 单独评估 |

## 4. 未接入 · 中价值(P1, 有额外成本)

| 能力 | 接口 | 成本/前置 |
|---|---|---|
| MV / 视频 | `mv_all` `mv_detail` `mv_url` `mv_sub` `mv_sublist` `mv_first` `mv_exclusive_rcmd` `personalized_mv` `artist_mv` `artist_video` `simi_mv` `video_*`(9) `related_allvideo` `mlog_url` | 要视频播放器(Media3 ExoPlayer/mpv 已有, 但 UI 与对象存储/防盗链需处理) |
| 私信 / 通知 | `msg_private` `msg_private_history` `msg_notices` `msg_comments` `msg_forwards` `msg_recentcontact` | 消息中心 UI + 未读同步 |
| 动态增强 | `event_del` `send_song` `send_text` `send_playlist` `send_album` `topic_detail` `topic_sublist` `topic_detail_event_hot` `hot_topic` `hug_comment` `comment_hug_list` | 发动态/话题页/抱一抱 |
| 云盘 | `user_cloud` `user_cloud_detail` `user_cloud_del` `cloud_upload_token` `cloud_upload_complete` `cloud_import` `cloud_match` `cloud_lyric_get` | 分片上传 + 文件选择 + 匹配库 |
| 声音/播客创作 | `voice_upload` `voice_delete` `voice_detail` `voice_lyric` `voicelist_*`(6) | 发布审核链路, 非听众功能 |
| 电台补充 | `dj_radio_top` `dj_radio_hot` `dj_toplist*`(5) `dj_program_toplist*`(2) `dj_catelist` `dj_category_*`(2) `dj_recommend` `dj_recommend_type` `dj_personalize_recommend` `dj_sub` `dj_subscriber` `dj_today_perfered` `dj_paygift` `dj_banner` `dj_difm_*`(6) | 电台榜单/分类; `dj_difm_*` 是"电台私人FM", 语义未验证 |
| 一起听 | `listentogether_*`(9) | 房间 + 心跳 + 指令同步, 工作量大且需双端联调 |
| 云贝 / 会员 | `yunbei_*`(11) `vip_info` `vip_info_v2` `vip_tasks` `vip_growthpoint*`(3) `vip_timemachine` | 只读展示可做; 涉及兑换/支付的别碰 |
| 数字专辑 / 已购 | `digital_album_detail` `digital_album_purchased` `digital_album_sales` `song_purchased` `song_downlist` `song_monthdownlist` `song_singledownlist` `album_songsaleboard` | `digital_album_ordering`(下单)不做; 其余只读 |
| 创作者中心 | `musician_*`(8) `fanscenter_*`(5) `creator_authinfo_get` `ugc_*`(7) | 面向音乐人, 不是听众需求 |
| 资料/账号安全 | `user_update` `avatar_upload` `nickname_check` `user_binding` `user_bindingcellphone` `user_replacephone` `rebind` `user_social_status*`(4) `setting` | 高风险, 建议跳官方网页 |
| 其它内容 | `related_playlist` `sheet_list` `sheet_preview`(乐谱) `style_detail` `style_album` `style_artist` `song_chorus`(高潮片段, 需音频切片) `song_dynamic_cover` `song_red_count` `personal_fm_mode` `personalized_privatecontent*`(2) `personalized_djprogram` `artists` `artist_songs` `artist_new_song` `artist_sub` `artist_desc` `artist_fans` `artist_follow_count` `artist_list` `artist_detail_dynamic` `artist_new_mv` `comment_info_list` `comment_new` `comment`(总入口) `recent_listen_list` `program_recommend` `mlog_music_rcmd` `mlog_to_video` `broadcast_*`(5) | 视需求挑 |

## 5. 明确不建议实现

| 类别 | 接口 | 原因 |
|---|---|---|
| 原生登录族 | `login` `login_cellphone` `login_qr_key` `login_qr_create` `login_qr_check` `login_refresh` `login_status` `logout` `captcha_sent` `captcha_verify` `register_*`(2) `verify_get_qr` `verify_qrcodestatus` `cellphone_existence_check` `countries_code_list` | 实测原生扫码/手机号必返 **8821 安全环境风险**; 官方网页登录(WebView + `MUSIC_U`)是唯一稳路径, 已在用 |
| 埋点/上报 | `listen_data_report` `listen_data_realtime_report` `listen_data_today_song` `listen_data_total` `listen_data_year_report` `scrobble` `weblog` `music_first_listen_info` | 我们不是官方客户端, 上报既无用又添风控特征 |
| 内部/协议工具 | `api` `mod` `eapi_decrypt` `inner_version` `activate_init_profile` `threshold_detail_get` `batch` `check_music` `get_userids` `playmode_song_vector` `starpick_comments_summary` `summary_annual` | 内部灰度/算法向量/年度报告, 依赖私有状态 |
| 取链变体 | `song_url` `song_url_match` `song_url_ncmget` `song_url_v1_302` `song_like` `song_like_check` `song_music_detail` `song_order_update` `song_download_url` `song_download_url_v1` | 我们已用 `song_url_v1` + 自己下载; 其余是 Web/客户端专用通道或已废弃 |
| 首页装修 | `banner` `calendar` `homepage_block_page` `homepage_dragon_ball` `aidj_content_rcmd` `playlist_detail_dynamic` `playlist_detail_rcmd_get` `playlist_update_playcount` `playlist_mylike` `playlist_subscribers` `playlist_cover_update` `playlist_tags_update` `playlist_import_*`(2) `playlist_video_recent` `user_audio` `user_dj` `user_event` `user_playlist_collect` `user_playlist_create` `user_comment_history` `user_detail_new` `user_mutualfollow_get` `user_social_status_rcmd` `personalized` | 官方首页装修/灰度位; 或与我们已有的实现重复 |

## 6. 已接后端但 UI 还缺入口(顺手能做)

- `lyric`(纯文本)/`lyric_lines`(逐行, 无翻译): 已导出, UI 只用了 `lyric_lines_i18n`(逐行+翻译)。
- `podcast_program`(单节目详情)/`podcast_radio`(电台详情): 已导出, UI 用列表数据渲染, 详情刷新没接。
- `search`(单类型搜索): 已被 `search_all` 取代, 可以直接删掉导出。

## 附录: 未接入 337 个 endpoint(按前缀分组)

| 前缀 | 数量 | 接口 |
|---|---|---|
| `dj` | 25 | `dj_banner`, `dj_category_excludehot`, `dj_category_recommend`, `dj_catelist`, `dj_difm_all_style_channel`, `dj_difm_channel_subscribe`, `dj_difm_channel_unsubscribe`, `dj_difm_playing_tracks_list`, `dj_difm_subscribe_channels_get`, `dj_paygift`, `dj_personalize_recommend`, `dj_program_toplist`, `dj_program_toplist_hours`, `dj_radio_hot`, `dj_radio_top`, `dj_recommend`, `dj_recommend_type`, `dj_sub`, `dj_subscriber`, `dj_today_perfered`, `dj_toplist`, `dj_toplist_hours`, `dj_toplist_newcomer`, `dj_toplist_pay`, `dj_toplist_popular` |
| `user` | 25 | `user_audio`, `user_binding`, `user_bindingcellphone`, `user_cloud`, `user_cloud_del`, `user_cloud_detail`, `user_comment_history`, `user_detail_new`, `user_dj`, `user_event`, `user_follow_mixed`, `user_followeds`, `user_follows`, `user_level`, `user_medal`, `user_mutualfollow_get`, `user_playlist_collect`, `user_playlist_create`, `user_replacephone`, `user_social_status`, `user_social_status_edit`, `user_social_status_rcmd`, `user_social_status_support`, `user_subcount`, `user_update` |
| `playlist` | 23 | `playlist_category_list`, `playlist_catlist`, `playlist_cover_update`, `playlist_create`, `playlist_delete`, `playlist_desc_update`, `playlist_detail_dynamic`, `playlist_detail_rcmd_get`, `playlist_highquality_tags`, `playlist_hot`, `playlist_import_name_task_create`, `playlist_import_task_status`, `playlist_mylike`, `playlist_name_update`, `playlist_order_update`, `playlist_privacy`, `playlist_subscribers`, `playlist_tags_update`, `playlist_track_add`, `playlist_track_delete`, `playlist_update`, `playlist_update_playcount`, `playlist_video_recent` |
| `song` | 22 | `song_chorus`, `song_downlist`, `song_download_url`, `song_download_url_v1`, `song_dynamic_cover`, `song_like`, `song_like_check`, `song_lyrics_mark`, `song_lyrics_mark_add`, `song_lyrics_mark_del`, `song_lyrics_mark_user_page`, `song_monthdownlist`, `song_music_detail`, `song_order_update`, `song_purchased`, `song_red_count`, `song_singledownlist`, `song_url`, `song_url_match`, `song_url_ncmget`, `song_url_v1_302`, `song_wiki_summary` |
| `artist` | 11 | `artist_desc`, `artist_detail_dynamic`, `artist_fans`, `artist_follow_count`, `artist_list`, `artist_mv`, `artist_new_mv`, `artist_new_song`, `artist_songs`, `artist_sub`, `artist_video` |
| `comment` | 11 | `comment`, `comment_delete`, `comment_floor`, `comment_hot`, `comment_hug_list`, `comment_info_list`, `comment_like`, `comment_mv`, `comment_new`, `comment_reply`, `comment_video` |
| `yunbei` | 11 | `yunbei`, `yunbei_expense`, `yunbei_info`, `yunbei_rcmd_song`, `yunbei_rcmd_song_history`, `yunbei_receipt`, `yunbei_sign`, `yunbei_task_finish`, `yunbei_tasks`, `yunbei_tasks_todo`, `yunbei_today` |
| `album` | 10 | `album_detail`, `album_detail_dynamic`, `album_list`, `album_list_style`, `album_new`, `album_newest`, `album_privilege`, `album_songsaleboard`, `album_sub`, `album_sublist` |
| `listentogether` | 9 | `listentogether_accept`, `listentogether_end`, `listentogether_heatbeat`, `listentogether_play_command`, `listentogether_room_check`, `listentogether_room_create`, `listentogether_status`, `listentogether_sync_list_command`, `listentogether_sync_playlist_get` |
| `video` | 9 | `video_category_list`, `video_detail`, `video_detail_info`, `video_group`, `video_group_list`, `video_sub`, `video_timeline_all`, `video_timeline_recommend`, `video_url` |
| `vip` | 9 | `vip_growthpoint`, `vip_growthpoint_details`, `vip_growthpoint_get`, `vip_info`, `vip_info_v2`, `vip_sign`, `vip_sign_info`, `vip_tasks`, `vip_timemachine` |
| `musician` | 8 | `musician_cloudbean`, `musician_cloudbean_obtain`, `musician_data_overview`, `musician_play_trend`, `musician_sign`, `musician_tasks`, `musician_tasks_new`, `musician_vip_tasks` |
| `mv` | 8 | `mv_all`, `mv_detail`, `mv_detail_info`, `mv_exclusive_rcmd`, `mv_first`, `mv_sub`, `mv_sublist`, `mv_url` |
| `login` | 7 | `login`, `login_cellphone`, `login_qr_check`, `login_qr_create`, `login_qr_key`, `login_refresh`, `login_status` |
| `top` | 7 | `top_album`, `top_artists`, `top_list`, `top_mv`, `top_playlist`, `top_playlist_highquality`, `top_song` |
| `ugc` | 7 | `ugc_album_get`, `ugc_artist_get`, `ugc_artist_search`, `ugc_detail`, `ugc_mv_get`, `ugc_song_get`, `ugc_user_devote` |
| `cloud` | 6 | `cloud`, `cloud_import`, `cloud_lyric_get`, `cloud_match`, `cloud_upload_complete`, `cloud_upload_token` |
| `msg` | 6 | `msg_comments`, `msg_forwards`, `msg_notices`, `msg_private`, `msg_private_history`, `msg_recentcontact` |
| `personalized` | 6 | `personalized`, `personalized_djprogram`, `personalized_mv`, `personalized_newsong`, `personalized_privatecontent`, `personalized_privatecontent_list` |
| `voicelist` | 6 | `voicelist_detail`, `voicelist_list`, `voicelist_list_search`, `voicelist_my_created`, `voicelist_search`, `voicelist_trans` |
| `broadcast` | 5 | `broadcast_category_region_get`, `broadcast_channel_collect_list`, `broadcast_channel_currentinfo`, `broadcast_channel_list`, `broadcast_sub` |
| `fanscenter` | 5 | `fanscenter_basicinfo_age_get`, `fanscenter_basicinfo_gender_get`, `fanscenter_basicinfo_province_get`, `fanscenter_overview_get`, `fanscenter_trend_list` |
| `listen` | 5 | `listen_data_realtime_report`, `listen_data_report`, `listen_data_today_song`, `listen_data_total`, `listen_data_year_report` |
| `record` | 5 | `record_recent_album`, `record_recent_dj`, `record_recent_playlist`, `record_recent_video`, `record_recent_voice` |
| `search` | 5 | `search`, `search_hot_detail`, `search_match`, `search_multimatch`, `search_suggest_pc` |
| `simi` | 5 | `simi_artist`, `simi_mv`, `simi_playlist`, `simi_song`, `simi_user` |
| `digital` | 4 | `digital_album_detail`, `digital_album_ordering`, `digital_album_purchased`, `digital_album_sales` |
| `send` | 4 | `send_album`, `send_playlist`, `send_song`, `send_text` |
| `toplist` | 4 | `toplist`, `toplist_artist`, `toplist_detail`, `toplist_detail_v2` |
| `voice` | 4 | `voice_delete`, `voice_detail`, `voice_lyric`, `voice_upload` |
| `mlog` | 3 | `mlog_music_rcmd`, `mlog_to_video`, `mlog_url` |
| `style` | 3 | `style_album`, `style_artist`, `style_detail` |
| `topic` | 3 | `topic_detail`, `topic_detail_event_hot`, `topic_sublist` |
| `captcha` | 2 | `captcha_sent`, `captcha_verify` |
| `history` | 2 | `history_recommend_songs`, `history_recommend_songs_detail` |
| `homepage` | 2 | `homepage_block_page`, `homepage_dragon_ball` |
| `register` | 2 | `register_anonimous`, `register_cellphone` |
| `related` | 2 | `related_allvideo`, `related_playlist` |
| `sheet` | 2 | `sheet_list`, `sheet_preview` |
| `verify` | 2 | `verify_get_qr`, `verify_qrcodestatus` |
| `activate` | 1 | `activate_init_profile` |
| `aidj` | 1 | `aidj_content_rcmd` |
| `api` | 1 | `api` |
| `artists` | 1 | `artists` |
| `audio` | 1 | `audio_match` |
| `avatar` | 1 | `avatar_upload` |
| `banner` | 1 | `banner` |
| `batch` | 1 | `batch` |
| `calendar` | 1 | `calendar` |
| `cellphone` | 1 | `cellphone_existence_check` |
| `check` | 1 | `check_music` |
| `countries` | 1 | `countries_code_list` |
| `creator` | 1 | `creator_authinfo_get` |
| `daily` | 1 | `daily_signin` |
| `eapi` | 1 | `eapi_decrypt` |
| `event` | 1 | `event_del` |
| `fm` | 1 | `fm_trash` |
| `follow` | 1 | `follow` |
| `get` | 1 | `get_userids` |
| `hot` | 1 | `hot_topic` |
| `hug` | 1 | `hug_comment` |
| `inner` | 1 | `inner_version` |
| `logout` | 1 | `logout` |
| `lyric` | 1 | `lyric_new` |
| `mod` | 1 | `mod` |
| `music` | 1 | `music_first_listen_info` |
| `nickname` | 1 | `nickname_check` |
| `personal` | 1 | `personal_fm_mode` |
| `pl` | 1 | `pl_count` |
| `playmode` | 1 | `playmode_song_vector` |
| `program` | 1 | `program_recommend` |
| `rebind` | 1 | `rebind` |
| `recent` | 1 | `recent_listen_list` |
| `recommend` | 1 | `recommend_songs_dislike` |
| `scrobble` | 1 | `scrobble` |
| `setting` | 1 | `setting` |
| `sign` | 1 | `sign_happy_info` |
| `signin` | 1 | `signin_progress` |
| `starpick` | 1 | `starpick_comments_summary` |
| `summary` | 1 | `summary_annual` |
| `threshold` | 1 | `threshold_detail_get` |
| `weblog` | 1 | `weblog` |

---

## 复算与维护

- 覆盖判定: `ncm-service/src/netease.rs` 中出现 `client.<method>(` 即视为"已接入"(跨行匹配);
  vendor 里有模块但我们通过 vendor 内部组合间接用到的(如 `playlist_track_all` 内部会打 `playlist_detail`+`song_detail`)按直接调用计。
- 判定"UI 有没有入口": 在 `ui/lib`(排除 `src/rust/`)里找 `rust.<camelCase>` 调用。
- 新增能力时跑一次 `bash tools/api-coverage.sh` 保持本文数字同步。
