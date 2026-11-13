//! 歌曲域: 单曲/推荐/流地址/榜单/风格/听歌排行/最近播放, 以及它们的响应解析.

use super::*;

/// 最近播放的三种资源(专辑/歌单/电台)
#[derive(Debug, Clone, Copy)]
pub(super) enum RecentBucket {
    Album,
    Playlist,
    Podcast,
}

impl NeteaseProvider {
    pub(super) fn song_url<'a>(
        &'a self,
        req: &'a SongUrlRequest,
    ) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let level = req.level.as_str();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &req.track.to_string())
                .param("level", level);
            let resp = client.song_url_v1(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_stream(&resp.body, level)
        })
    }

    /// "我喜欢的音乐"曲目 id: 红心状态的唯一真相(不用每首去查详情)
    pub(super) fn liked_ids<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<TrackId>>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("uid", &uid.to_string());
            let resp = client.likelist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(resp
                .body
                .get("ids")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_u64)
                        .map(TrackId::new)
                        .collect()
                })
                .unwrap_or_default())
        })
    }

    /// 听歌排行(需要登录): type=0 全部时间 / type=1 最近一周.
    /// 响应形如 {code:200, allData:[{playCount,score,song:{...}}], weekData:[...]}
    pub(super) fn play_ranking(
        &self,
        period: RankingPeriod,
    ) -> BoxFuture<'_, ProviderResult<Vec<PlayRankEntry>>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("type", period.type_param());
            let resp = client.user_record(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_play_ranking(&resp.body, period))
        })
    }

    /// 我的曲风偏好: 系统按听歌口味算出来的风格(登录才有).
    /// 未登录/接口给空时退化成通用曲风表(style_list 的二级标签), 保证推荐页总有入口.
    pub(super) fn style_preference(&self) -> BoxFuture<'_, ProviderResult<Vec<StyleTag>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.style_preference(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut tags = parse_style_preference(&resp.body);
            if tags.is_empty() {
                let fallback = client.style_list(&q).await.map_err(map_error)?;
                check_body(&fallback.body)?;
                tags = parse_style_list(&fallback.body, 12);
            }
            Ok(tags)
        })
    }

    /// 某个曲风下的歌曲: 响应形如 {code:200, data:{songs:[...], page:{...}}}
    pub(super) fn style_songs<'a>(
        &'a self,
        tag_id: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            if tag_id.is_empty() {
                return Err(ProviderError::not_found("曲风 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("tagId", tag_id)
                .param("size", &limit.to_string())
                .param("cursor", "0");
            let resp = client.style_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_style_songs(&resp.body))
        })
    }

    /// 某个曲风下的歌单: 响应形如 {code:200, data:{playlist:[...], page:{...}}}
    pub(super) fn style_playlists<'a>(
        &'a self,
        tag_id: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            if tag_id.is_empty() {
                return Err(ProviderError::not_found("曲风 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("tagId", tag_id)
                .param("size", &limit.to_string())
                .param("cursor", "0");
            let resp = client.style_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_style_playlists(&resp.body))
        })
    }

    /// 排行榜列表: 榜单就是歌单, 详情直接走 playlist_songs / playlist_detail.
    /// 响应形如 {code, list:[{id,name,coverImgUrl,updateFrequency,trackCount,playCount,tracks}]}
    pub(super) fn charts(&self) -> BoxFuture<'_, ProviderResult<Vec<ChartSummary>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.toplist_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_charts(&resp.body))
        })
    }

    /// 榜单 v2 目录(toplist_detail_v2): 按 categoryCode 分组的榜单卡.
    /// 实测没有 v1 的 trackUpdateTime 数字字段; "更新 N 首"混在 updateFrequency 字符串里,
    /// 增强点是按 categoryCode 分组 + canPlay(个别卡 id=0 且不可播).
    pub(super) fn toplist_catalog(
        &self,
    ) -> BoxFuture<'_, ProviderResult<Vec<ToplistCatalogGroup>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.toplist_detail_v2(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_toplist_catalog(&resp.body))
        })
    }

    /// 新歌速递: {code, result:[{id,name,picUrl,song:{完整歌曲}}]}
    pub(super) fn new_songs(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
            let resp = client.personalized_newsong(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_new_songs(&resp.body))
        })
    }

    /// 相似歌曲: {code, songs:[完整歌曲]}
    pub(super) fn similar_songs(
        &self,
        song_id: u64,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &song_id.to_string())
                .param("limit", &limit.to_string());
            let resp = client.simi_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_bucket(&resp.body, "songs"))
        })
    }

    /// 每日推荐"不感兴趣": /api/v2/discovery/recommend/dislike
    pub(super) fn dislike_recommend_song(
        &self,
        song_id: u64,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("不感兴趣需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &song_id.to_string());
            let resp = client
                .recommend_songs_dislike(&q)
                .await
                .map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 私人 FM"不再播放": /api/radio/trash/add
    pub(super) fn trash_fm_song(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("不感兴趣需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &song_id.to_string());
            let resp = client.fm_trash(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 历史日推日期列表: {code, data:{dates:[...], noHistoryMessage, purchaseUrl}}
    /// 非 VIP 时 dates 为空并给一句提示, 当成"没有历史"处理.
    pub(super) fn history_recommend_dates(&self) -> BoxFuture<'_, ProviderResult<Vec<String>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("历史日推需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client
                .history_recommend_songs(&q)
                .await
                .map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_history_dates(&resp.body))
        })
    }

    /// 某个日期的历史日推: {code, data:{songs:[...]}}
    pub(super) fn history_recommend_songs<'a>(
        &'a self,
        date: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            if date.trim().is_empty() {
                return Err(ProviderError::not_found("日期为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("历史日推需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("date", date);
            let resp = client
                .history_recommend_songs_detail(&q)
                .await
                .map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_bucket(
                resp.body.get("data").unwrap_or(&resp.body),
                "songs",
            ))
        })
    }

    /// 红心/取消红心. 网易云用 HTTP 200 里的 code 表达结果(200 = 成功)
    pub(super) fn set_like<'a>(
        &'a self,
        track: TrackId,
        liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("未登录不能收藏"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &track.to_string())
                .param("like", if liked { "true" } else { "false" });
            let resp = client.like(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 批量曲目详情(红心列表要靠它补全元数据)
    pub(super) fn songs_detail<'a>(
        &'a self,
        ids: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("ids", ids);
            let resp = client.song_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_list(&resp.body))
        })
    }

    /// 每日推荐歌曲(原版每日推荐, 匿名也能取到; 登录后是个性化推荐)
    pub(super) fn daily_recommend_songs(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.recommend_songs(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_recommend_songs(&resp.body))
        })
    }

    /// 心动模式: 以当前曲目为种子, 在指定歌单里续播.
    /// 网易云要求 pid 必须是一个**可用的歌单**(实测 pid=0 返回 400 歌单不存在);
    /// 用户从搜索/单曲直接进入时没有歌单上下文, 这里自动回落到"我喜欢的音乐".
    pub(super) fn intelligence_songs(
        &self,
        song_id: u64,
        playlist_id: u64,
        count: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let mut pid = if playlist_id == 0 {
                self.default_playlist_id().await?
            } else {
                playlist_id
            };
            let mut retried = false;
            loop {
                let (client, domain, ua, cookie) = self.snapshot();
                let q = make_query(&cookie, &domain, &ua)
                    .param("id", &song_id.to_string())
                    .param("pid", &pid.to_string())
                    .param("sid", &song_id.to_string())
                    .param("count", &count.to_string());
                let resp = client
                    .playmode_intelligence_list(&q)
                    .await
                    .map_err(map_error)?;
                match check_body(&resp.body) {
                    Ok(()) => {
                        let mut songs = parse_intelligence(&resp.body);
                        // 接口会一次给一整队(实测 149 首), 按调用方要的条数截断
                        songs.truncate(count.max(1) as usize);
                        return Ok(songs);
                    }
                    Err(e) => {
                        // 有些自建歌单不被心动模式接受(实测 400 "不支持该歌单类型"):
                        // 第一次失败就回落到"我喜欢的音乐"再试一次.
                        let playlist_problem = e.detail.contains("歌单");
                        if !retried && playlist_problem {
                            retried = true;
                            let fallback = self.default_playlist_id().await?;
                            if fallback != pid {
                                pid = fallback;
                                continue;
                            }
                        }
                        return Err(e);
                    }
                }
            }
        })
    }

    /// 歌曲百科: 曲风/语种/BPM/获奖成就, 压成 label/value 对.
    ///
    /// vendor 的 song_wiki_summary 走 eapi: 桌面身份(PC UA + os=pc)实测正常,
    /// 安卓身份(官方安卓 UA + os=android)实测回 code=432 Unknown error;
    /// 同一个 path 换 weapi 通道两边都正常, 所以先用 weapi, 失败再退回 vendor 的 eapi 实现。
    pub(super) fn song_wiki(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<Vec<WikiFact>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let opt = ncm_api_rs::RequestOption {
                crypto: ncm_api_rs::CryptoType::Weapi,
                cookie: (!cookie.is_empty()).then(|| cookie.clone()),
                ua: ua.clone(),
                domain: domain.clone(),
                ..Default::default()
            };
            let body = serde_json::json!({ "songId": song_id.to_string() });
            let weapi = client
                .request("/api/song/play/about/block/page", body, opt)
                .await
                .map_err(map_error)
                .and_then(|r| {
                    check_body(&r.body)?;
                    Ok(r)
                });
            if let Ok(resp) = weapi {
                return Ok(parse_song_wiki(&resp.body));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &song_id.to_string());
            let resp = client.song_wiki_summary(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_wiki(&resp.body))
        })
    }

    /// 新歌速递(按地区). area → areaId 是服务端的枚举: 0 全部 / 7 华语 / 8 日语 / 16 韩语 / 96 欧美
    pub(super) fn new_songs_by_area<'a>(
        &'a self,
        area: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q =
                make_query(&cookie, &domain, &ua).param("type", &song_area_id(area).to_string());
            let resp = client.top_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut songs = parse_top_songs(&resp.body);
            songs.truncate(limit as usize);
            Ok(songs)
        })
    }

    /// 最近播放(服务端记录, 需要登录)
    pub(super) fn recent_songs(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("最近播放需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
            let resp = client.record_recent_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_recent(&resp.body))
        })
    }

    /// 最近播放-专辑(服务端记录, 需要登录)
    pub(super) fn recent_albums(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let items = self.recent_bucket(RecentBucket::Album, limit).await?;
            Ok(items.iter().filter_map(parse_album_item).collect())
        })
    }

    /// 最近播放-歌单(服务端记录, 需要登录)
    pub(super) fn recent_playlists(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let items = self.recent_bucket(RecentBucket::Playlist, limit).await?;
            Ok(items.iter().filter_map(parse_playlist).collect())
        })
    }

    /// 最近播放-播客/电台(服务端记录, 需要登录)
    pub(super) fn recent_podcasts(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let items = self.recent_bucket(RecentBucket::Podcast, limit).await?;
            Ok(items.iter().filter_map(parse_radio).collect())
        })
    }

    /// "我喜欢的音乐"曲目, 按收藏时间从新到旧.
    /// likelist 的 id 顺序不可靠(实测体感随机); 歌单详情的 trackIds[].at 才是加入时间(ms).
    pub(super) fn liked_songs_ordered(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let playlist_id = self.liked_playlist_id().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("s", "8");
            let resp = client.playlist_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut entries: Vec<(u64, i64)> = resp
                .body
                .get("playlist")
                .and_then(|p| p.get("trackIds"))
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(|t| {
                            Some((
                                u64_of(t, "id")?,
                                t.get("at").and_then(Value::as_i64).unwrap_or(0),
                            ))
                        })
                        .collect()
                })
                .unwrap_or_default();
            if entries.is_empty() {
                return Ok(Vec::new());
            }
            // at 大 = 更晚收藏; at 缺失(0) 保持服务端顺序
            entries.sort_by_key(|e| std::cmp::Reverse(e.1));
            let ids: Vec<u64> = entries.into_iter().map(|(id, _)| id).collect();
            let mut by_id: std::collections::HashMap<u64, Song> = std::collections::HashMap::new();
            for chunk in ids.chunks(500) {
                let joined = chunk
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                let q = make_query(&cookie, &domain, &ua).param("ids", &joined);
                let detail = client.song_detail(&q).await.map_err(map_error)?;
                check_body(&detail.body)?;
                for s in parse_song_list(&detail.body) {
                    by_id.insert(s.id.0, s);
                }
            }
            Ok(ids.iter().filter_map(|id| by_id.remove(id)).collect())
        })
    }

    /// 私人 FM: 登录后按口味连续推歌(/api/v1/radio/get), 匿名会返回 301.
    pub(super) fn personal_fm(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("私人 FM 需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.personal_fm(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut songs = parse_fm_songs(&resp.body);
            songs.truncate(limit.max(1) as usize);
            Ok(songs)
        })
    }

    /// 最近播放三类(专辑/歌单/电台)共用的取数: 响应都是 {code, data:{list:[{data:{...}}]}}
    pub(super) async fn recent_bucket(
        &self,
        bucket: RecentBucket,
        limit: u32,
    ) -> ProviderResult<Vec<Value>> {
        let (client, domain, ua, cookie) = self.snapshot();
        if !cookie.contains("MUSIC_U=") {
            return Err(ProviderError::auth("最近播放需要登录"));
        }
        let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
        let resp = match bucket {
            RecentBucket::Album => client.record_recent_album(&q).await,
            RecentBucket::Playlist => client.record_recent_playlist(&q).await,
            RecentBucket::Podcast => client.record_recent_dj(&q).await,
        }
        .map_err(map_error)?;
        check_body(&resp.body)?;
        Ok(recent_items(&resp.body))
    }
}

pub fn parse_stream(body: &Value, level: &str) -> ProviderResult<StreamUrl> {
    let entry = body
        .get("data")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .ok_or_else(|| ProviderError::not_found("song_url: empty data"))?;
    let code = entry.get("code").and_then(Value::as_i64).unwrap_or(200);
    if code != 200 {
        let msg = entry
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        return Err(map_code(code, msg));
    }
    let url = entry
        .get("url")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let expi = u64_of(entry, "expi").unwrap_or(1200);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    Ok(StreamUrl {
        url,
        quality: level.to_string(),
        br: u64_of(entry, "br"),
        size: u64_of(entry, "size"),
        expire_at: Some(now + expi),
    })
}

/// 每日推荐歌曲的响应形如 {code:200, data:{dailySongs:[...], privileges:[...]}}
pub fn parse_recommend_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(|d| d.get("dailySongs"))
        .or_else(|| body.get("recommend"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 心动模式/智能播放的响应.
/// 实测(2026-11-04, 登录态)形如:
///   {code:200, data:[{alg, id, recommended, songInfo:{...完整 song 对象...}}, ...]}
/// 早期/其它变体也可能直接是 song 数组, 两种都认.
pub fn parse_intelligence(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(Value::as_array)
        .or_else(|| {
            body.get("data")
                .and_then(|d| d.get("songs"))
                .and_then(Value::as_array)
        })
        .map(|arr| {
            arr.iter()
                .filter_map(|item| {
                    let song = item
                        .get("songInfo")
                        .or_else(|| item.get("song"))
                        .or_else(|| item.get("data"))
                        .unwrap_or(item);
                    parse_song_with(song, &privileges)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 最近播放的响应形如 {code:200, data:{list:[{data:{song}, playCount, ...}]}}
pub fn parse_recent(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|item| parse_song_with(item.get("data").unwrap_or(item), &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 私人 FM 的响应形如 {code:200, data:[{id,name,ar,al,dt,fee,...}, ...]}
pub fn parse_fm_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|item| {
                    let song = item
                        .get("songInfo")
                        .or_else(|| item.get("song"))
                        .unwrap_or(item);
                    parse_song_with(song, &privileges)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 历史日推日期: {code, data:{dates:["2024-06-20", ...]}}.
/// 兼容两种形态: 纯字符串数组 或 [{date: "..."}] 对象数组.
pub fn parse_history_dates(body: &Value) -> Vec<String> {
    let data = body.get("data").unwrap_or(body);
    let Some(arr) = data.get("dates").and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            v.as_str()
                .map(str::to_string)
                .or_else(|| str_of(v, "date"))
                .or_else(|| str_of(v, "day"))
        })
        .filter(|s| !s.trim().is_empty())
        .collect()
}

/// 新歌速递: {code, result:[{id,name,picUrl,song:{完整歌曲}}]} —— 曲目在 item.song 里
pub fn parse_new_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("result")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                // 只认 song 字段里的完整歌曲; 外层的 id/name 是推荐位元数据
                .filter_map(|item| parse_song_with(item.get("song")?, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 通用"songs 数组"桶: 相似歌曲/搜索结果等
pub fn parse_song_bucket(body: &Value, key: &str) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get(key)
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 排行榜列表: {code, list:[{id,name,coverImgUrl,updateFrequency,trackCount,playCount,tracks}]}.
/// 只取摘要, 曲目进榜单详情时再拉(接口本来也只给前 3 首做预览).
pub fn parse_charts(body: &Value) -> Vec<ChartSummary> {
    body.get("list")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    let id = u64_of(v, "id")?;
                    let name = str_of(v, "name")?;
                    if name.is_empty() {
                        return None;
                    }
                    Some(ChartSummary {
                        id,
                        name,
                        cover_url: str_of(v, "coverImgUrl").filter(|s| s.starts_with("http")),
                        update_frequency: str_of(v, "updateFrequency").unwrap_or_default(),
                        track_count: u64_of(v, "trackCount").unwrap_or(0),
                        play_count: u64_of(v, "playCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 榜单 v2 目录: {code, data:[{categoryCode, list:[{id,name,coverUrl,updateFrequency,
///                targetType,canPlay}]}]}. data 缺失/为空都返回空目录.
pub fn parse_toplist_catalog(body: &Value) -> Vec<ToplistCatalogGroup> {
    body.get("data")
        .and_then(Value::as_array)
        .map(|groups| {
            groups
                .iter()
                .map(|g| ToplistCatalogGroup {
                    code: str_of(g, "categoryCode").unwrap_or_default(),
                    items: g
                        .get("list")
                        .and_then(Value::as_array)
                        .map(|arr| {
                            arr.iter()
                                .filter_map(|v| {
                                    let id = u64_of(v, "id")?;
                                    let name = str_of(v, "name")?;
                                    if name.is_empty() {
                                        return None;
                                    }
                                    Some(ToplistCatalogItem {
                                        id,
                                        name,
                                        cover_url: str_of(v, "coverUrl")
                                            .filter(|s| s.starts_with("http")),
                                        update_frequency: str_of(v, "updateFrequency")
                                            .unwrap_or_default(),
                                        target_type: str_of(v, "targetType").unwrap_or_default(),
                                        can_play: v
                                            .get("canPlay")
                                            .and_then(Value::as_bool)
                                            .unwrap_or(false),
                                    })
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 新歌速递: {code, data:[完整 song 对象(ar/artists + al/album + duration + privilege)]}
pub fn parse_top_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 歌曲百科: {code, data:{blocks:[{code, creatives:[{creativeType, uiElement:{mainTitle, textLinks},
/// resources:[{uiElement:{mainTitle, subTitles}}]}]}]}}
/// 只取 "音乐百科" 那个块(其余是相似歌曲/相关歌单/回忆坐标, 我们已有等价入口).
pub fn parse_song_wiki(body: &Value) -> Vec<WikiFact> {
    let blocks = body
        .get("data")
        .and_then(|d| d.get("blocks"))
        .and_then(Value::as_array);
    let Some(blocks) = blocks else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for block in blocks {
        if str_of(block, "code").as_deref() != Some("SONG_PLAY_ABOUT_SONG_BASIC") {
            continue;
        }
        let Some(creatives) = block.get("creatives").and_then(Value::as_array) else {
            continue;
        };
        for creative in creatives {
            let ui = creative.get("uiElement");
            let label = ui
                .and_then(|u| u.get("mainTitle"))
                .and_then(|t| str_of(t, "title"))
                .unwrap_or_default();
            if label.is_empty() {
                continue;
            }
            let mut values: Vec<String> = Vec::new();
            if let Some(texts) = ui
                .and_then(|u| u.get("textLinks"))
                .and_then(Value::as_array)
            {
                for text in texts {
                    if let Some(t) = str_of(text, "text").filter(|s| !s.is_empty()) {
                        values.push(t);
                    }
                }
            }
            if let Some(resources) = creative.get("resources").and_then(Value::as_array) {
                for res in resources {
                    let rui = res.get("uiElement");
                    let title = rui
                        .and_then(|u| u.get("mainTitle"))
                        .and_then(|t| str_of(t, "title"))
                        .unwrap_or_default();
                    let mut parts: Vec<String> = Vec::new();
                    if !title.is_empty() {
                        parts.push(title);
                    }
                    if let Some(subs) = rui
                        .and_then(|u| u.get("subTitles"))
                        .and_then(Value::as_array)
                    {
                        for sub in subs {
                            if let Some(t) = str_of(sub, "title").filter(|s| !s.is_empty()) {
                                parts.push(t);
                            }
                        }
                    }
                    if !parts.is_empty() {
                        values.push(parts.join(" "));
                    }
                }
            }
            if values.is_empty() {
                continue;
            }
            out.push(WikiFact {
                label,
                value: values.join(" / "),
            });
        }
    }
    out
}

/// 听歌排行的响应: {code:200, allData:[{playCount,score,song:{...}}], weekData:[...]}.
/// 名次按 score(其次 play_count)倒序, 保证 UI 拿到的顺序稳定.
pub fn parse_play_ranking(body: &Value, period: RankingPeriod) -> Vec<PlayRankEntry> {
    let key = match period {
        RankingPeriod::All => "allData",
        RankingPeriod::Week => "weekData",
    };
    let privileges = parse_privileges(body);
    let mut out: Vec<PlayRankEntry> = body
        .get(key)
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|item| {
                    let song = parse_song_with(item.get("song")?, &privileges)?;
                    Some(PlayRankEntry {
                        song,
                        play_count: u64_of(item, "playCount").unwrap_or(0),
                        score: u64_of(item, "score").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then_with(|| b.play_count.cmp(&a.play_count))
    });
    out
}

/// 曲风偏好的响应: {code:200, data:{tagPreferenceVos:[...], tags:[...]}}.
/// 登录态下真正有内容的是这两个数组之一, 字段名各版本略有差异, 统一容错.
pub fn parse_style_preference(body: &Value) -> Vec<StyleTag> {
    let data = body.get("data").unwrap_or(body);
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for key in ["tagPreferenceVos", "tags", "preferenceTags"] {
        let Some(arr) = data.get(key).and_then(Value::as_array) else {
            continue;
        };
        for item in arr {
            if let Some(tag) = parse_style_tag(item) {
                if seen.insert(tag.id.clone()) {
                    out.push(tag);
                }
            }
        }
    }
    // 有的版本 data 直接是数组
    if out.is_empty() {
        if let Some(arr) = data.as_array() {
            for item in arr {
                if let Some(tag) = parse_style_tag(item) {
                    if seen.insert(tag.id.clone()) {
                        out.push(tag);
                    }
                }
            }
        }
    }
    out
}

/// 通用曲风表(style_list)的响应: {code:200, data:[{tagId,tagName,picUrl,childrenTags:[...]}]}.
/// 取二级标签(level 2)作为推荐页入口; 二级为空时退回一级标签本身.
/// 这是"我的曲风偏好"为空时的兜底, 也是未登录用户能看到的风格入口.
pub fn parse_style_list(body: &Value, limit: usize) -> Vec<StyleTag> {
    let Some(arr) = body.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for top in arr {
        // 有二级标签就用二级; 一级标签本身只是分组名("语种"/"风格"), 不单列
        let mut expanded = false;
        if let Some(children) = top.get("childrenTags").and_then(Value::as_array) {
            for child in children {
                if let Some(tag) = parse_style_tag(child) {
                    out.push(tag);
                    expanded = true;
                }
                if out.len() >= limit {
                    return out;
                }
            }
        }
        if !expanded {
            if let Some(tag) = parse_style_tag(top) {
                out.push(tag);
            }
        }
        if out.len() >= limit {
            return out;
        }
    }
    out
}

pub(super) fn parse_style_tag(v: &Value) -> Option<StyleTag> {
    // tagId 有时是数字有时是字符串
    let id = u64_of(v, "tagId")
        .map(|n| n.to_string())
        .or_else(|| str_of(v, "tagId"))
        .or_else(|| u64_of(v, "id").map(|n| n.to_string()))
        .or_else(|| str_of(v, "id"))?;
    let name = str_of(v, "tagName")
        .or_else(|| str_of(v, "name"))
        .unwrap_or_default();
    if id.is_empty() || name.is_empty() {
        return None;
    }
    // style_list 的 picUrl 是相对路径(yyimgs/<hash>), 没有 host, 直接用会报
    // "No host specified in URI"; 只保留绝对地址, 其余交给 UI 用默认图标.
    let cover_url = str_of(v, "picUrl")
        .or_else(|| str_of(v, "coverUrl"))
        .or_else(|| str_of(v, "imageUrl"))
        .filter(|s| s.starts_with("http"));
    Some(StyleTag {
        id,
        name,
        cover_url,
        song_count: u64_of(v, "songCount").or_else(|| u64_of(v, "songNum")),
    })
}

/// 曲风歌曲的响应: {code:200, data:{songs:[{...完整 song 对象...}], page:{...}}}
pub fn parse_style_songs(body: &Value) -> Vec<Song> {
    let data = body.get("data").unwrap_or(body);
    let privileges = parse_privileges(body);
    data.get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 曲风歌单的响应: {code:200, data:{playlist:[{id,name,cover,songCount,...}], page:{...}}}
pub fn parse_style_playlists(body: &Value) -> Vec<Playlist> {
    let data = body.get("data").unwrap_or(body);
    data.get("playlist")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_style_playlist).collect())
        .unwrap_or_default()
}

/// 曲风歌单用的字段名与用户歌单不同: cover / songCount(没有 coverImgUrl/trackCount)
pub(super) fn parse_style_playlist(v: &Value) -> Option<Playlist> {
    let id = u64_of(v, "id")?;
    Some(Playlist {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "cover")
            .or_else(|| str_of(v, "coverImgUrl"))
            .or_else(|| str_of(v, "picUrl"))
            .filter(|s| !s.is_empty()),
        track_count: u64_of(v, "songCount")
            .or_else(|| u64_of(v, "trackCount"))
            .unwrap_or(0),
        special: false,
    })
}
