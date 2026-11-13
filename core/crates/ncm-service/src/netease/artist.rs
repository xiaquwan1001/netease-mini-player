//! 歌手域: 歌手详情/歌曲分页/MV/相似/热门/订阅.

use super::*;

impl NeteaseProvider {
    /// 相似歌手: {code, artists:[{id,name,picUrl}]}(需要登录)
    pub(super) fn similar_artists(
        &self,
        artist_id: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("相似歌手需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &artist_id.to_string());
            let resp = client.simi_artist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_similar_artists(&resp.body))
        })
    }

    /// 歌手全部歌曲(artist_songs): offset/limit 分页, more=还有下一页
    pub(super) fn artist_songs_page<'a>(
        &'a self,
        artist_id: u64,
        offset: u32,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistSongPage>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &artist_id.to_string())
                .param("offset", &offset.to_string())
                .param("limit", &limit.to_string());
            let resp = client.artist_songs(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_artist_songs(&resp.body))
        })
    }

    /// 关注/取消关注歌手(artist_sub: t=1 sub / t=0 unsub), 需要登录.
    pub(super) fn toggle_artist_sub<'a>(
        &'a self,
        artist_id: u64,
        sub: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("关注歌手需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &artist_id.to_string())
                .param("t", if sub { "1" } else { "0" });
            let resp = client.artist_sub(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 歌手 MV(artist_mv): offset/limit 分页, hasMore=还有下一页
    pub(super) fn artist_mvs_page<'a>(
        &'a self,
        artist_id: u64,
        offset: u32,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistMvPage>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &artist_id.to_string())
                .param("offset", &offset.to_string())
                .param("limit", &limit.to_string());
            let resp = client.artist_mv(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_artist_mvs(&resp.body))
        })
    }

    /// MV 详情(mv_detail)
    pub(super) fn mv_detail<'a>(&'a self, mv_id: u64) -> BoxFuture<'a, ProviderResult<MvDetail>> {
        Box::pin(async move {
            if mv_id == 0 {
                return Err(ProviderError::not_found("mv id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("mvid", &mv_id.to_string());
            let resp = client.mv_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let detail = parse_mv_detail(&resp.body);
            if detail.id == 0 || detail.name.is_empty() {
                return Err(ProviderError::not_found("MV 不存在"));
            }
            Ok(detail)
        })
    }

    /// MV 播放链接(mv_url, r=清晰度档位如 1080)
    pub(super) fn mv_url<'a>(&'a self, mv_id: u64, r: u32) -> BoxFuture<'a, ProviderResult<MvUrl>> {
        Box::pin(async move {
            if mv_id == 0 {
                return Err(ProviderError::not_found("mv id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let r_str = if r == 0 {
                "1080".to_string()
            } else {
                r.to_string()
            };
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &mv_id.to_string())
                .param("r", &r_str);
            let resp = client.mv_url(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let u = parse_mv_url(&resp.body);
            if u.url.is_none() {
                return Err(ProviderError::unsupported(
                    "该 MV 无可播放链接(可能需要 VIP 或已下架)",
                ));
            }
            Ok(u)
        })
    }

    /// 热门歌手榜
    pub(super) fn hot_artists(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<HotArtist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.top_artists(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_hot_artists(&resp.body))
        })
    }

    /// 歌手详情: 头部资料 + 热门歌曲 + 专辑. 专辑接口失败只影响专辑板块.
    pub(super) fn artist_detail(
        &self,
        artist_id: u64,
    ) -> BoxFuture<'_, ProviderResult<ArtistDetail>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let base = || make_query(&cookie, &domain, &ua).param("id", &artist_id.to_string());
            let (detail, top, albums) = futures::future::join3(
                async { client.artist_detail(&base()).await.map_err(map_error) },
                async { client.artist_top_song(&base()).await.map_err(map_error) },
                async {
                    client
                        .artist_album(&base().param("limit", "20"))
                        .await
                        .map_err(map_error)
                },
            )
            .await;
            let detail = detail?;
            check_body(&detail.body)?;
            let top = top?;
            check_body(&top.body)?;
            // 专辑走 weapi, 匿名/风控下可能失败: 不是致命错误
            let albums_body = match albums {
                Ok(resp) if check_body(&resp.body).is_ok() => resp.body,
                _ => Value::Null,
            };
            Ok(parse_artist_detail(&detail.body, &top.body, &albums_body))
        })
    }

    /// 关注的艺人
    pub(super) fn subscribed_artists(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看关注艺人需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.max(1).to_string())
                .param("offset", "0");
            let resp = client.artist_sublist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_subscribed_artists(&resp.body))
        })
    }
}

/// 歌手详情: 头部(data.artist) + 热门歌曲(songs) + 专辑(hotAlbums)
pub fn parse_artist_detail(detail: &Value, top: &Value, albums: &Value) -> ArtistDetail {
    let info = detail
        .get("data")
        .and_then(|d| d.get("artist"))
        .or_else(|| detail.get("artist"));
    let id = info.and_then(|a| u64_of(a, "id")).unwrap_or(0);
    let name = info.and_then(|a| str_of(a, "name")).unwrap_or_default();
    let alias = info
        .and_then(|a| a.get("alias"))
        .and_then(Value::as_array)
        .map(|x| {
            x.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let privileges = parse_privileges(top);
    let songs = top
        .get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default();
    let album_list = albums
        .get("hotAlbums")
        .or_else(|| albums.get("albums"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    Some(AlbumBrief {
                        id,
                        name: str_of(a, "name").unwrap_or_default(),
                        cover_url: str_of(a, "picUrl").filter(|s| !s.is_empty()),
                        track_count: u64_of(a, "size").unwrap_or(0),
                        publish_time: u64_of(a, "publishTime").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    ArtistDetail {
        id,
        name,
        avatar_url: info
            .and_then(|a| str_of(a, "avatar"))
            .or_else(|| info.and_then(|a| str_of(a, "picUrl")))
            .filter(|s| !s.is_empty()),
        cover_url: info
            .and_then(|a| str_of(a, "cover"))
            .or_else(|| info.and_then(|a| str_of(a, "coverUrl")))
            .filter(|s| !s.is_empty()),
        alias,
        brief_desc: info
            .and_then(|a| str_of(a, "briefDesc"))
            .unwrap_or_default(),
        album_count: info.and_then(|a| u64_of(a, "albumSize")).unwrap_or(0),
        music_count: info.and_then(|a| u64_of(a, "musicSize")).unwrap_or(0),
        songs,
        albums: album_list,
    }
}

/// 关注艺人的响应形如 {code:200, data:[{id,name,picUrl,albumSize,...}]}
pub fn parse_subscribed_artists(body: &Value) -> Vec<Artist> {
    let arr = body
        .get("data")
        .or_else(|| body.get("artists"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            let name = str_of(v, "name")?;
            if name.is_empty() {
                return None;
            }
            Some(Artist {
                id: u64_of(v, "id").unwrap_or(0),
                name,
                avatar_url: str_of(v, "picUrl")
                    .or_else(|| str_of(v, "img1v1Url"))
                    .or_else(|| str_of(v, "avatar"))
                    .filter(|s| !s.is_empty()),
            })
        })
        .collect()
}

/// 歌手全部歌曲: {code, more, songs:[...]}(artist_songs, 每首歌自带 privilege)
pub fn parse_artist_songs(body: &Value) -> ArtistSongPage {
    ArtistSongPage {
        songs: parse_song_list(body),
        has_more: body.get("more").and_then(Value::as_bool).unwrap_or(false),
    }
}

/// 歌手 MV: {code, hasMore, mvs:[{id,name,duration,playCount,publishTime,imgurl16v9}]}
pub fn parse_artist_mvs(body: &Value) -> ArtistMvPage {
    let mvs = body
        .get("mvs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    let id = u64_of(v, "id")?;
                    let name = str_of(v, "name").unwrap_or_default();
                    if name.is_empty() {
                        return None;
                    }
                    Some(ArtistMv {
                        id,
                        name,
                        duration_ms: u64_of(v, "duration").unwrap_or(0),
                        play_count: u64_of(v, "playCount").unwrap_or(0),
                        publish_time: str_of(v, "publishTime").unwrap_or_default(),
                        cover_url: str_of(v, "imgurl16v9")
                            .or_else(|| str_of(v, "imgurl"))
                            .filter(|s| s.starts_with("http")),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    ArtistMvPage {
        mvs,
        has_more: body
            .get("hasMore")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}

/// MV 详情: {code, data:{id,name,artistName,duration,playCount,publishTime,cover,brs:[{br,size}],desc}}
pub fn parse_mv_detail(body: &Value) -> MvDetail {
    let d = body.get("data").cloned().unwrap_or(Value::Null);
    let mut brs: Vec<u32> = d
        .get("brs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.get("br").and_then(Value::as_u64).map(|b| b as u32))
                .collect()
        })
        .unwrap_or_default();
    brs.sort_unstable();
    brs.dedup();
    let name = str_of(&d, "name").unwrap_or_default();
    let id = u64_of(&d, "id").unwrap_or(0);
    MvDetail {
        id,
        name,
        artist_name: str_of(&d, "artistName").unwrap_or_default(),
        duration_ms: u64_of(&d, "duration").unwrap_or(0),
        play_count: u64_of(&d, "playCount").unwrap_or(0),
        publish_time: str_of(&d, "publishTime").unwrap_or_default(),
        cover_url: str_of(&d, "cover").filter(|s| s.starts_with("http")),
        max_br: brs.last().copied().unwrap_or(0),
        brs,
        desc: str_of(&d, "desc")
            .or_else(|| str_of(&d, "briefDesc"))
            .filter(|s| !s.is_empty()),
    }
}

/// MV 播放链接: {code, data:{url,r,size,expi,...}} (data 是对象, video 版才是数组)
pub fn parse_mv_url(body: &Value) -> MvUrl {
    let d = body.get("data").cloned().unwrap_or(Value::Null);
    let url = str_of(&d, "url").filter(|s| s.starts_with("http"));
    MvUrl {
        url,
        r: u64_of(&d, "r").unwrap_or(0) as u32,
        size: u64_of(&d, "size").unwrap_or(0),
    }
}

/// 相似歌手: {code, artists:[{id,name,picUrl,img1v1Url}]}
pub fn parse_similar_artists(body: &Value) -> Vec<Artist> {
    let arr = body
        .get("artists")
        .or_else(|| body.get("data"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            let name = str_of(v, "name")?;
            if name.is_empty() {
                return None;
            }
            Some(Artist {
                id: u64_of(v, "id").unwrap_or(0),
                name,
                avatar_url: str_of(v, "picUrl")
                    .or_else(|| str_of(v, "img1v1Url"))
                    .filter(|s| s.starts_with("http")),
            })
        })
        .collect()
}

/// 热门歌手榜: {artists:[{id,name,picUrl,fansCount}]}
pub fn parse_hot_artists(body: &Value) -> Vec<HotArtist> {
    body.get("artists")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    let name = str_of(a, "name")?;
                    if name.is_empty() {
                        return None;
                    }
                    Some(HotArtist {
                        id,
                        name,
                        avatar_url: str_of(a, "picUrl")
                            .or_else(|| str_of(a, "img1v1Url"))
                            .filter(|s| s.starts_with("http")),
                        fans: u64_of(a, "fansCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}
