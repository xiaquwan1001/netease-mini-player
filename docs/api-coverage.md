# 网易云接口覆盖清单(vendor ncm-api ↔ 本仓库)

> 最近更新: 2026-11-14(三) 复核(`bash tools/api-coverage.sh` 实测): vendor endpoint 模块 **136** / service 已调用 **136**(100%) / 未接入 **0**(本轮 +2: `user_event`、`artist_follow_count`); FFI 导出 **160** 个里 6 个无 UI 入口 —— `cache_stats`/`eq_profile_normalize`/`player_tuning`(给未来设置项留的宿主口)、`consent_plaintext_storage`(凭据回退同意门)、`cloud_song_url`(云盘行播放走 `song_url_v1`, 直链接口备用)、`user_play_ranking`(他人常听排行, 暂无入口)。口径与复算方式见文末, 一条命令可重跑。
> 剩余待办怎么分批、哪些能并行、怎么派工: 见 [`docs/remaining-batches.md`](remaining-batches.md)。

## 1. 总览

| 指标 | 数值 |
|---|---|
| vendor `core/vendor/ncm-api/src/api/*.rs` 里的 endpoint 模块 | **134**(2026-11-14: + 云盘上传 5 + 资料更新 1 + MV 搜索复用 cloudsearch) |
| `ncm-service`(provider)实际调用的 | **134(100%)** |
| 未接入 | **0** |
| FFI 导出给 Dart 的函数 | **160**(+ 云盘上传/云盘列表/删除/直链/资料更新) |
| 其中 UI 还没有入口的 | 6(`cache_stats` `cloud_song_url` `consent_plaintext_storage` `eq_profile_normalize` `player_tuning` `user_play_ranking`) |

> 表内数字以 `bash tools/api-coverage.sh` 的实时输出为准(上面这行是 2026-11-10 收尾版实测)。

复算:

```bash
bash tools/api-coverage.sh          # 只打统计
bash tools/api-coverage.sh --list   # 附带已接入/未接入全名单
```

结论先说: **播放链路(搜索/取链/歌词/歌单/专辑/歌手/播客/动态/听歌排行/风格/榜单/歌单广场/收藏专辑/歌单编辑)已经够用**,
剩下的缺口集中在三块 —— ①"内容发现"类(排行榜/歌单广场/新歌新碟/相似推荐)、
②"社区互动"类(评论点赞/私信通知/转发)、③"账号周边"类(收藏专辑/关注粉丝/歌单编辑/签到)。
④ MV/视频(评论已接)、一起听、创作者中心这类需要额外能力(视频解码、长连接、权限)的, 建议先不做;
云盘已在 2026-11-14 接入(列表/删除/取链/上传, 上传走单请求 `complete=true`, 分片未做)。

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
| 排行榜 | `toplist_detail` | 推荐页"排行榜"横排 → 榜单详情(榜单即歌单) |
| 歌单广场 | `playlist_catlist` `top_playlist` `top_playlist_highquality` | 推荐页"歌单广场": 分类筛选/热门/精品/分页 |
| 收藏专辑 | `album_sub` `album_sublist` | "我的/收藏的专辑" + 专辑弹窗收藏按钮 |
| 歌单编辑 | `playlist_create` `playlist_delete` `playlist_name_update` `playlist_desc_update` `playlist_track_delete` | 收藏到歌单时新建；自己歌单的编辑信息/移出曲目/删除 |
| 评论互动 | `comment_like` `comment_floor` `comment_reply` | 评论区: 点赞(乐观更新) + 楼层回复列表 + 发回复; 歌曲/歌单/专辑/播客/动态共用一套 `comment_thread.dart` |
| 关注/粉丝 | `user_follows` `user_followeds` `follow` `user_subcount` | 资料卡"关注 N/粉丝 N"点进去: 两 tab 列表 + 行内关注/取关 |
| 新歌/新碟 | `personalized_newsong` `album_new` | 推荐页"新歌速递"(6 首预览, 整批起播) + "新碟上架"(封面横排, 点开专辑弹窗) |
| 新歌/新碟分地区 + 歌手榜 | `top_song` `top_album` `top_artists` | 推荐页两个板块的"更多"→"新歌·新碟·歌手"页: 新歌(全部/华语/欧美/日本/韩国)、新碟(同地区维度)、歌手榜(粉丝数格式化, 点开歌手页) |
| 相似推荐 | `simi_song` `simi_playlist` `simi_artist` | 歌曲菜单"相似歌曲"(面板: 相似歌曲 + 相似歌单); 歌手页"相似歌手"胶囊(需登录) |
| 不感兴趣 | `recommend_songs_dislike` `fm_trash` | 每日推荐每行 ⊖ 按钮; 歌曲菜单"不感兴趣"(FM 队列走 fm_trash, 其余走日推 dislike) |
| 历史日推 | `history_recommend_songs` `history_recommend_songs_detail` | 每日推荐面板第三个页签: 日期列表 → 某天的歌单(黑胶 VIP 专属) |
| 最近播放分类 | `record_recent_album` `record_recent_playlist` `record_recent_dj` | "我的/最近听过" 四个页签: 单曲/专辑/歌单/播客(点专辑→封面预览, 点歌单/播客→对应详情) |
| 云贝签到 | `daily_signin` `signin_progress` | "我的"顶部签到卡: 今日状态 + 累计/连续/本周天数 + 一键签到(实测确认只有 `type=1` 真的签上, `type=0` 回"功能暂不支持") |
| 评论删除 | `comment_delete` | 评论区: 只有自己发的评论显示"删除", 二次确认后本地移除 |
| 歌曲百科 | `song_wiki_summary` | 歌曲菜单"歌曲百科": 曲风/语种/BPM/获奖成就(接口是装修块富文本, Rust 侧压成 label/value) |
| 消息中心 | `pl_count` `msg_private` `msg_private_history` `msg_notices` `msg_comments` | "我的"/消息中心: 未读角标 + 三页签(私信会话→只读聊天记录 / 通知 / 评论消息); 实测私信 18 未读、通知含点赞/系统通知、评论含被评资源名 |
| 数字专辑只读 | `digital_album_detail` `digital_album_purchased` `digital_album_sales` `song_purchased` | "我的"→数字专辑(只读): 已购数字专辑列表(封面/歌手/购买时间/份数) + BottomSheet 详情(价格/标签/销量/简介); 未登录不显示入口; 下单(`digital_album_ordering`)不做 |
| 最新专辑 | `album_newest` | 新碟上架「更多」→「精选新碟」页签(12 张网格) + FFI `newest_albums` + CLI `ncm album-newest`; 与 `album_new` 不同: 固定 12 张编辑精选、无分页 |
| 榜单 v2 | `toplist_detail_v2` | 推荐页「排行榜 → 全部」→ 全部榜单页(7 组 45 榜, 不可播灰显) + FFI `toplist_catalog` + CLI `ncm toplist-v2` |
| MV/视频评论 | `comment_mv` `comment_video` | 与歌曲评论同形, 直接复用 `CommentPage`; provider `comments(kind: mv/video)` |
| 逐字歌词 | `lyric_new` | domain `WordLyric` 契约 + FFI `word_lyric_lines` + CLI `ncm yrc <id>`；UI 侧 `word_lyric_view.dart` 做逐字(karaoke)着色 + 行级自动滚动，**无 yrc 时回落行级/纯文本**（老歌如 晴天 186016 无 yrc） |
| 电台广场(只读) | `dj_catelist` `dj_category_recommend` `dj_recommend_type` `dj_toplist` `dj_toplist_hours` `dj_toplist_newcomer` `dj_toplist_pay` `dj_toplist_popular` `dj_program_toplist` `dj_subscriber` | 推荐页「推荐播客 → 更多」: 分类胶囊 → 精选分组/推荐电台 → 热门/新晋/付费/主播榜; 点行复用 `showPodcastDetail`。**订阅(`dj_sub`)与 `dj_difm_*` 不做** |
| 通道自检 | (FFI `ping`) | 设置页「诊断 → Rust 通道自检」: 点击显示耗时与返回值, 失败给 `friendlyError` 并允许重试(防重入) |
| 评论统计 | `comment_info_list` | 评论区标题下统计条「评论 N · 分享 N · 点赞 N」(空/失败不显示); 歌曲/歌单/专辑/播客/视频共用, **动态评论接口不认**, 且**没有收藏数/热评数**(官方文档有但不回) |
| 评论热门/IP 归属 | `comment_hot` | 评论区"全部/热门"页签(热门单独翻页, 计数 9405 而非 31 万); 普通评论显示 IP 归属地, 精彩评论带"热门"角标; 顺手修掉"全部"页 offset 把热评算进去导致的重复拉取 |
| 音乐云盘 | `user_cloud` `user_cloud_del` `cloud_upload_check` `cloud_nos_token` `cloud_upload_info` `cloud_pub` `cloud_music_status` `song_cloud_download` | 「我的」→音乐云盘: 列表(容量/大小)、播放、删除、下拉/翻页; 右上角上传(选文件 → md5 查重/秒传 → NOS 上传 → 转码轮询 → 发布)。**分片上传未做**, 单请求路径与上游前端一致 |
| 编辑资料 | `user_profile_update` | 「我的」→简介区块「编辑简介」: 保存签名(局部更新, 132 字符上限), 保存后回读资料; 头像上传(`avatar_upload`)未做 |
| 消息增强 | `msg_forwards` `msg_recentcontact` | 消息中心第四页签"@我"(空账号, 防御式解析) + 私信页顶部"最近联系人"横滑条(data.follow, 服务端顺序) + 私信会话/聊天记录分页(触底预取/按钮, 返回 < limit 到底, 聊天用最早一条 time_ms 当游标) |

## 3. 未接入 · 建议优先做(P0, 都为纯 HTTP + 现有 DTO 能装下)

| # | 能力 | 接口 | 落地位置 | 备注 |
|---|---|---|---|---|
| 1 | 新碟/新歌剩余入口 | `album_newest` `simi_user` | 推荐页分类页 | `top_song`/`top_album`/`top_artists` 已接入; `album_newest`(最新专辑)与已接入的新碟基本重复, `simi_user`(相似用户)价值低 |
| 2 | ~~评论补充~~ ✅已做 | `comment_info_list` | 评论区 | 统计条已接入(B2); 同族只剩 `comment_mv`/`comment_video`(MV/视频评论区, 等视频能力落地) |
| 3 | 最近播放更多类型 | `record_recent_video` `record_recent_voice` | "最近听过"再加页签 | 专辑/歌单/播客已接入; 视频要有播放器, 声音是创作者内容 |
| 4 | 歌词增强 | `lyric_new`(逐字) `song_lyrics_mark*`(4 个) | 歌词页 | 歌曲百科已接入(`song_wiki_summary`); 逐字歌词要换接口并改滚动实现 |
| 5 | 会员签到/任务 | `vip_sign` `vip_sign_info` `sign_happy_info` `vip_tasks` | "我的"/设置 | 云贝签到已接入(`daily_signin`+`signin_progress`); 这几个是黑胶专属任务, 只读展示即可, 不碰支付 |
| 6 | 搜索增强 | `search_match` `search_multimatch` `pl_count` `search_hot_detail` `batch` | 搜索联想/结果数 | 联想现在只走 suggest |
| 7 | 听歌识别 | `audio_match` | 搜索页"听歌识曲" | 需录音权限 + 指纹采集(约 10s), 单独评估 |
| 8 | 榜单 v2 / 歌手榜 | `toplist` `toplist_detail_v2` `toplist_artist` | 排行榜页细分 | v2 给"更新几首", 现在用 detail 版够用 |
| 9 | 歌单细分编辑 | `playlist_privacy` `playlist_order_update` `playlist_cover_update` `playlist_tags_update` | 歌单管理菜单 | **vendor 限制**: `playlist_privacy` 的 `privacy` 写死为 0(只能"取消私密"), 改私密需自己拼请求; 排序/换封面/改标签同理 |

## 4. 未接入 · 中价值(P1, 有额外成本)

| 能力 | 接口 | 成本/前置 |
|---|---|---|
| MV / 视频 | `mv_all` `mv_detail` `mv_url` `mv_sub` `mv_sublist` `mv_first` `mv_exclusive_rcmd` `personalized_mv` `artist_mv` `artist_video` `simi_mv` `video_*`(9) `related_allvideo` `mlog_url` | 要视频播放器(Media3 ExoPlayer/mpv 已有, 但 UI 与对象存储/防盗链需处理) |
| 动态增强 | `event_del` `send_song` `send_text` `send_playlist` `send_album` `topic_detail` `topic_sublist` `topic_detail_event_hot` `hot_topic` `hug_comment` `comment_hug_list` | 发动态/话题页/抱一抱 |
| 云盘补充 | `cloud_import` `cloud_match` `cloud_lyric_get` | 云盘主体已接入(见 §2); 剩下是"导入外部歌曲/匹配/歌词关联", 非播放必需 |
| 声音/播客创作 | `voice_upload` `voice_delete` `voice_detail` `voice_lyric` `voicelist_*`(6) | 发布审核链路, 非听众功能 |
| 电台补充 | `dj_radio_top` `dj_radio_hot` `dj_toplist*`(5) `dj_program_toplist*`(2) `dj_catelist` `dj_category_*`(2) `dj_recommend` `dj_recommend_type` `dj_personalize_recommend` `dj_sub` `dj_subscriber` `dj_today_perfered` `dj_paygift` `dj_banner` `dj_difm_*`(6) | 电台榜单/分类; `dj_difm_*` 是"电台私人FM", 语义未验证 |
| 一起听 | `listentogether_*`(9) | 房间 + 心跳 + 指令同步, 工作量大且需双端联调 |
| 云贝 / 会员 | `yunbei_*`(11) `vip_info` `vip_info_v2` `vip_tasks` `vip_growthpoint*`(3) `vip_timemachine` | 只读展示可做; 涉及兑换/支付的别碰 |
| 数字专辑 / 已购 | `digital_album_detail` `digital_album_purchased` `digital_album_sales` `song_purchased` `song_downlist` `song_monthdownlist` `song_singledownlist` `album_songsaleboard` | `digital_album_ordering`(下单)不做; 其余只读 |
| 创作者中心 | `musician_*`(8) `fanscenter_*`(5) `creator_authinfo_get` `ugc_*`(7) | 面向音乐人, 不是听众需求 |
| 资料/账号安全 | `avatar_upload` `nickname_check` `user_binding` `user_bindingcellphone` `user_replacephone` `rebind` `user_social_status*`(4) `setting` | 签名编辑已接入(`user_profile_update`); 头像/昵称/换绑等高风险项建议跳官方网页 |
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
- `follow_counts`(关注/粉丝数): 已导出, 但资料卡的数字来自 `profile_detail`; 关注/取关后卡片数字会稍滞后,
  后续可在这里补一次刷新。

## 附录: 未接入 294 个 endpoint(按前缀分组)

> 名单是 2026-11-07 的快照; 每批接入后请用 `bash tools/api-coverage.sh --list` 重算, 以脚本输出为准.

| 前缀 | 数量 | 接口 |
|---|---|---|
| `dj` | 25 | `dj_banner`, `dj_category_excludehot`, `dj_category_recommend`, `dj_catelist`, `dj_difm_all_style_channel`, `dj_difm_channel_subscribe`, `dj_difm_channel_unsubscribe`, `dj_difm_playing_tracks_list`, `dj_difm_subscribe_channels_get`, `dj_paygift`, `dj_personalize_recommend`, `dj_program_toplist`, `dj_program_toplist_hours`, `dj_radio_hot`, `dj_radio_top`, `dj_recommend`, `dj_recommend_type`, `dj_sub`, `dj_subscriber`, `dj_today_perfered`, `dj_toplist`, `dj_toplist_hours`, `dj_toplist_newcomer`, `dj_toplist_pay`, `dj_toplist_popular` |
| `user` | 22 | `user_audio`, `user_binding`, `user_bindingcellphone`, `user_cloud`, `user_cloud_del`, `user_cloud_detail`, `user_comment_history`, `user_detail_new`, `user_dj`, `user_event`, `user_follow_mixed`, `user_level`, `user_medal`, `user_mutualfollow_get`, `user_playlist_collect`, `user_playlist_create`, `user_replacephone`, `user_social_status`, `user_social_status_edit`, `user_social_status_rcmd`, `user_social_status_support`, `user_update` |
| `song` | 21 | `song_chorus`, `song_downlist`, `song_download_url`, `song_download_url_v1`, `song_dynamic_cover`, `song_like`, `song_like_check`, `song_lyrics_mark`, `song_lyrics_mark_add`, `song_lyrics_mark_del`, `song_lyrics_mark_user_page`, `song_monthdownlist`, `song_music_detail`, `song_order_update`, `song_purchased`, `song_red_count`, `song_singledownlist`, `song_url`, `song_url_match`, `song_url_ncmget`, `song_url_v1_302` |
| `playlist` | 17 | `playlist_category_list`, `playlist_cover_update`, `playlist_detail_dynamic`, `playlist_detail_rcmd_get`, `playlist_highquality_tags`, `playlist_hot`, `playlist_import_name_task_create`, `playlist_import_task_status`, `playlist_mylike`, `playlist_order_update`, `playlist_privacy`, `playlist_subscribers`, `playlist_tags_update`, `playlist_track_add`, `playlist_update`, `playlist_update_playcount`, `playlist_video_recent` |
| `artist` | 11 | `artist_desc`, `artist_detail_dynamic`, `artist_fans`, `artist_follow_count`, `artist_list`, `artist_mv`, `artist_new_mv`, `artist_new_song`, `artist_songs`, `artist_sub`, `artist_video` |
| `yunbei` | 11 | `yunbei`, `yunbei_expense`, `yunbei_info`, `yunbei_rcmd_song`, `yunbei_rcmd_song_history`, `yunbei_receipt`, `yunbei_sign`, `yunbei_task_finish`, `yunbei_tasks`, `yunbei_tasks_todo`, `yunbei_today` |
| `listentogether` | 9 | `listentogether_accept`, `listentogether_end`, `listentogether_heatbeat`, `listentogether_play_command`, `listentogether_room_check`, `listentogether_room_create`, `listentogether_status`, `listentogether_sync_list_command`, `listentogether_sync_playlist_get` |
| `video` | 9 | `video_category_list`, `video_detail`, `video_detail_info`, `video_group`, `video_group_list`, `video_sub`, `video_timeline_all`, `video_timeline_recommend`, `video_url` |
| `vip` | 9 | `vip_growthpoint`, `vip_growthpoint_details`, `vip_growthpoint_get`, `vip_info`, `vip_info_v2`, `vip_sign`, `vip_sign_info`, `vip_tasks`, `vip_timemachine` |
| `musician` | 8 | `musician_cloudbean`, `musician_cloudbean_obtain`, `musician_data_overview`, `musician_play_trend`, `musician_sign`, `musician_tasks`, `musician_tasks_new`, `musician_vip_tasks` |
| `mv` | 8 | `mv_all`, `mv_detail`, `mv_detail_info`, `mv_exclusive_rcmd`, `mv_first`, `mv_sub`, `mv_sublist`, `mv_url` |
| `album` | 7 | `album_detail`, `album_detail_dynamic`, `album_list`, `album_list_style`, `album_newest`, `album_privilege`, `album_songsaleboard` |
| `login` | 7 | `login`, `login_cellphone`, `login_qr_check`, `login_qr_create`, `login_qr_key`, `login_refresh`, `login_status` |
| `ugc` | 7 | `ugc_album_get`, `ugc_artist_get`, `ugc_artist_search`, `ugc_detail`, `ugc_mv_get`, `ugc_song_get`, `ugc_user_devote` |
| `cloud` | 6 | `cloud`, `cloud_import`, `cloud_lyric_get`, `cloud_match`, `cloud_upload_complete`, `cloud_upload_token` |
| `comment` | 6 | `comment`, `comment_hug_list`, `comment_info_list`, `comment_mv`, `comment_new`, `comment_video` |
| `voicelist` | 6 | `voicelist_detail`, `voicelist_list`, `voicelist_list_search`, `voicelist_my_created`, `voicelist_search`, `voicelist_trans` |
| `broadcast` | 5 | `broadcast_category_region_get`, `broadcast_channel_collect_list`, `broadcast_channel_currentinfo`, `broadcast_channel_list`, `broadcast_sub` |
| `fanscenter` | 5 | `fanscenter_basicinfo_age_get`, `fanscenter_basicinfo_gender_get`, `fanscenter_basicinfo_province_get`, `fanscenter_overview_get`, `fanscenter_trend_list` |
| `listen` | 5 | `listen_data_realtime_report`, `listen_data_report`, `listen_data_today_song`, `listen_data_total`, `listen_data_year_report` |
| `personalized` | 5 | `personalized`, `personalized_djprogram`, `personalized_mv`, `personalized_privatecontent`, `personalized_privatecontent_list` |
| `search` | 5 | `search`, `search_hot_detail`, `search_match`, `search_multimatch`, `search_suggest_pc` |
| `digital` | 4 | `digital_album_detail`, `digital_album_ordering`, `digital_album_purchased`, `digital_album_sales` |
| `send` | 4 | `send_album`, `send_playlist`, `send_song`, `send_text` |
| `voice` | 4 | `voice_delete`, `voice_detail`, `voice_lyric`, `voice_upload` |
| `mlog` | 3 | `mlog_music_rcmd`, `mlog_to_video`, `mlog_url` |
| `style` | 3 | `style_album`, `style_artist`, `style_detail` |
| `topic` | 3 | `topic_detail`, `topic_detail_event_hot`, `topic_sublist` |
| `toplist` | 3 | `toplist`, `toplist_artist`, `toplist_detail_v2` |
| `captcha` | 2 | `captcha_sent`, `captcha_verify` |
| `homepage` | 2 | `homepage_block_page`, `homepage_dragon_ball` |
| `msg` | 0 | |
| `record` | 2 | `record_recent_video`, `record_recent_voice` |
| `register` | 2 | `register_anonimous`, `register_cellphone` |
| `related` | 2 | `related_allvideo`, `related_playlist` |
| `sheet` | 2 | `sheet_list`, `sheet_preview` |
| `simi` | 2 | `simi_mv`, `simi_user` |
| `top` | 2 | `top_list`, `top_mv` |
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
| `eapi` | 1 | `eapi_decrypt` |
| `event` | 1 | `event_del` |
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
| `playmode` | 1 | `playmode_song_vector` |
| `program` | 1 | `program_recommend` |
| `rebind` | 1 | `rebind` |
| `recent` | 1 | `recent_listen_list` |
| `scrobble` | 1 | `scrobble` |
| `setting` | 1 | `setting` |
| `sign` | 1 | `sign_happy_info` |
| `starpick` | 1 | `starpick_comments_summary` |
| `summary` | 1 | `summary_annual` |
| `threshold` | 1 | `threshold_detail_get` |
| `weblog` | 1 | `weblog` |

---

## 复算与维护

- 覆盖判定: `ncm-service/src/netease.rs` 中出现 `client.<method>(` 即视为"已接入"(跨行匹配);
  vendor 里有模块但我们通过 vendor 内部组合间接用到的(如 `playlist_track_all` 内部会打 `playlist_detail`+`song_detail`)按直接调用计。
- 判定"UI 有没有入口": 在 `ui/lib`(排除 `src/rust/`)里找 `rust.<camelCase>` 调用。
  **匹配必须大小写不敏感**(2026-11-09 修正): frb 生成名不总是严格 camelCase, 实测
  `lyric_lines_i18n` → `lyricLinesI18N`(大写 N), 旧的 camel 精确匹配把它误判成"无 UI 入口"(3 个);
  放宽后真实数字是 **2 个**: `search` / `lyric_lines`(见 `docs/api-overlap-audit.md` D1/D2)。
- 新增能力时跑一次 `bash tools/api-coverage.sh` 保持本文数字同步。

---

## B13: AMLL TTML 逐字歌词第二来源(2026-11-10)

- **外部 API(非网易云)**: `GET https://api.amll.dev/v1/lyrics/get?ncmMusicId=<id>`
  (AMLL 社区库; 200 → `data.lyrics` 内联 TTML, 404 → JSON error; 实测见 docs/b13-ttml-lyrics-notes.md)。
- Rust: `ncm-service/src/ttml_source.rs` — `fetch_ttml`(5s 超时 + 磁盘缓存
  `dataDir/ttml/<id>.ttml` / 无数据标记 `<id>.none`)、`word_lyric_with_fallback`
  (yrc → 覆盖率 < 0.6 或缺失时 TTML → 行级 LRC)、`TtmlDoc`。
- Domain: `ncm-domain/src/ttml.rs` — 手写轻量 TTML 解析器 `parse_ttml`
  (x-translation 行译文 / x-roman 罗马音保存, x-bg 跳过, 缺 end 用下一行 begin 兜底, 错误带行号)。
- FFI: `word_lyric_with_fallback`、`ttml_lyric_lines`(codegen 已跑)。
- UI: `main.dart` 顶部 `resolveLyricSource`(三来源可注入 loader) + 歌词页左下角来源小字。
