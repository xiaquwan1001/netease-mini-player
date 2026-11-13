//! 歌单域: 歌单读写/分类/详情/订阅.

use super::*;

impl NeteaseProvider {
    /// 歌单分类: 响应形如 {code, categories:{0:"语种",...}, sub:[{category:0,name:"华语"},...]}
    pub(super) fn playlist_categories(
        &self,
    ) -> BoxFuture<'_, ProviderResult<Vec<PlaylistCategory>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.playlist_catlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_categories(&resp.body))
        })
    }

    /// 分类歌单: /api/playlist/list, 响应 {code, playlists:[{id,name,coverImgUrl,trackCount}], total, more}
    pub(super) fn playlists_by_category<'a>(
        &'a self,
        cat: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("cat", if cat.is_empty() { "全部" } else { cat })
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string())
                .param("order", "hot");
            let resp = client.top_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_bucket(&resp.body, "playlists"))
        })
    }

    /// 精品歌单: /api/playlist/highquality/list, 响应 {code, playlists:[...], more, lasttime}
    pub(super) fn high_quality_playlists<'a>(
        &'a self,
        cat: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("cat", if cat.is_empty() { "全部" } else { cat })
                .param("limit", &limit.to_string());
            let resp = client
                .top_playlist_highquality(&q)
                .await
                .map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_bucket(&resp.body, "playlists"))
        })
    }

    /// 新建歌单: 响应 {code, id, playlist:{id,...}}(id 在顶层, 实测样例见 docs/b7-playlist-write-notes.md)
    pub(super) fn create_playlist<'a>(
        &'a self,
        name: &'a str,
        privacy: u8,
    ) -> BoxFuture<'a, ProviderResult<u64>> {
        Box::pin(async move {
            let name = name.trim();
            if name.is_empty() {
                return Err(ProviderError::internal("歌单名不能为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("新建歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("name", name)
                .param("privacy", &privacy.to_string());
            let resp = client.playlist_create(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_created_playlist(&resp.body)
                .map(|created| created.id)
                .ok_or_else(|| ProviderError::internal("新建歌单: 响应里没有 id"))
        })
    }

    /// 批量把曲目加入歌单(op=add). vendor 把逗号分隔 id 序列化成字符串数组进 trackIds;
    /// 响应 {"code":200,"count":N,...}, count 可小于提交数(重复曲目服务端跳过).
    pub(super) fn playlist_tracks_add<'a>(
        &'a self,
        playlist_id: u64,
        song_ids: &'a [u64],
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            if song_ids.is_empty() {
                return Err(ProviderError::internal("没有可加入的曲目"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏到歌单需要登录"));
            }
            let tracks = song_ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            let q = make_query(&cookie, &domain, &ua)
                .param("op", "add")
                .param("pid", &playlist_id.to_string())
                .param("tracks", &tracks)
                .param("imme", "true");
            let resp = client.playlist_tracks(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_edit_result(&resp.body).ok)
        })
    }

    /// 删除歌单
    pub(super) fn delete_playlist(&self, playlist_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("删除歌单需要登录"));
            }
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &playlist_id.to_string());
            let resp = client.playlist_delete(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    pub(super) fn rename_playlist<'a>(
        &'a self,
        playlist_id: u64,
        name: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let name = name.trim();
            if name.is_empty() {
                return Err(ProviderError::internal("歌单名不能为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("修改歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("name", name);
            let resp = client.playlist_name_update(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    pub(super) fn update_playlist_desc<'a>(
        &'a self,
        playlist_id: u64,
        desc: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("修改歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("desc", desc);
            let resp = client.playlist_desc_update(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 把一首歌移出歌单
    pub(super) fn remove_track(
        &self,
        playlist_id: u64,
        track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("修改歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("ids", &track.to_string());
            let resp = client.playlist_track_delete(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 相似歌单: {code, playlists:[...]}
    pub(super) fn similar_playlists(
        &self,
        song_id: u64,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &song_id.to_string())
                .param("limit", &limit.to_string());
            let resp = client.simi_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_bucket(&resp.body, "playlists"))
        })
    }

    /// 我的歌单(含"我喜欢的音乐")
    pub(super) fn user_playlists<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", "200");
            let resp = client.user_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let list = resp
                .body
                .get("playlist")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            Ok(list.iter().filter_map(parse_playlist).collect())
        })
    }

    /// 歌单曲目(vendor 内部先取 trackIds 再批量取详情)
    pub(super) fn playlist_songs<'a>(
        &'a self,
        playlist_id: u64,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &playlist_id.to_string());
            let resp = client.playlist_track_all(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_list(&resp.body))
        })
    }

    /// 每日推荐歌单(需要登录; 未登录时网易云返回 301)
    pub(super) fn daily_recommend_playlists(&self) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.recommend_resource(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_recommend_playlists(&resp.body))
        })
    }

    /// 歌单详情(歌单页头部信息)
    pub(super) fn playlist_detail(
        &self,
        playlist_id: u64,
    ) -> BoxFuture<'_, ProviderResult<PlaylistDetail>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &playlist_id.to_string());
            let resp = client.playlist_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_playlist_detail(&resp.body)
        })
    }

    /// 收藏/取消收藏歌单(需登录; t=1 收藏, t=2 取消)
    pub(super) fn set_playlist_subscribed(
        &self,
        playlist_id: u64,
        subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("t", if subscribed { "1" } else { "2" });
            let resp = client.playlist_subscribe(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 任意用户的公开歌单(user/playlist). 注意: 未登录时服务端只回公开歌单,
    /// 且**不含**该用户的"我喜欢的音乐"(它是私密歌单).
    pub(super) fn user_playlists_of<'a>(
        &'a self,
        uid: u64,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            if uid == 0 {
                return Err(ProviderError::not_found("用户 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", &limit.max(1).to_string());
            let resp = client.user_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let list = resp
                .body
                .get("playlist")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            Ok(list.iter().filter_map(parse_playlist).collect())
        })
    }

    /// 收藏曲目到歌单(需要登录)
    pub(super) fn add_to_playlist(
        &self,
        playlist_id: u64,
        track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏到歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("op", "add")
                .param("pid", &playlist_id.to_string())
                .param("tracks", &track.to_string());
            let resp = client.playlist_tracks(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 心动模式没有歌单上下文时的默认歌单: "我喜欢的音乐"(specialType=5).
    /// 用户至少要有这个歌单(登录后一定有), 否则给一条能看懂的错.
    pub(super) async fn default_playlist_id(&self) -> ProviderResult<u64> {
        let uid = self.uid().await?;
        let (client, domain, ua, cookie) = self.snapshot();
        let q = make_query(&cookie, &domain, &ua)
            .param("uid", &uid.to_string())
            .param("limit", "200");
        let resp = client.user_playlist(&q).await.map_err(map_error)?;
        check_body(&resp.body)?;
        let list = resp
            .body
            .get("playlist")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        list.iter()
            .filter_map(parse_playlist)
            .find(|p| p.special)
            .map(|p| p.id)
            .ok_or_else(|| ProviderError::not_found("心动模式需要登录并至少有一个歌单"))
    }

    /// "我喜欢的音乐"歌单 id(specialType=5). 未登录时给能看懂的错.
    pub(super) async fn liked_playlist_id(&self) -> ProviderResult<u64> {
        let uid = self.uid().await?;
        let (client, domain, ua, cookie) = self.snapshot();
        let q = make_query(&cookie, &domain, &ua)
            .param("uid", &uid.to_string())
            .param("limit", "200");
        let resp = client.user_playlist(&q).await.map_err(map_error)?;
        check_body(&resp.body)?;
        let list = resp
            .body
            .get("playlist")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        list.iter()
            .filter_map(parse_playlist)
            .find(|p| p.special)
            .map(|p| p.id)
            .ok_or_else(|| ProviderError::not_found("登录后才能读取我喜欢的音乐"))
    }
}

/// 新建歌单响应 → (id, name). id 在顶层, 老形态回退 playlist.id(2026-11-10 实测,
/// 样例见 docs/b7-playlist-write-notes.md). 拿不到 id 视为解析失败.
pub fn parse_created_playlist(body: &Value) -> Option<ncm_domain::CreatedPlaylist> {
    let playlist = body.get("playlist");
    let id = body
        .get("id")
        .and_then(Value::as_u64)
        .or_else(|| playlist.and_then(|p| p.get("id")).and_then(Value::as_u64))
        .unwrap_or(0);
    if id == 0 {
        return None;
    }
    let name = playlist
        .and_then(|p| p.get("name"))
        .and_then(Value::as_str)
        .or_else(|| body.get("name").and_then(Value::as_str))
        .unwrap_or_default()
        .to_string();
    Some(ncm_domain::CreatedPlaylist { id, name })
}

/// 歌单写操作(tracks add / delete)通用结果. 成功判定 = code==200;
/// add 成功时 count=接受数, 无 message; 失败给 msg/message.
pub fn parse_playlist_edit_result(body: &Value) -> ncm_domain::PlaylistEditResult {
    let code = body.get("code").and_then(Value::as_i64).unwrap_or(0);
    let message = ["message", "msg"]
        .iter()
        .find_map(|k| body.get(*k).and_then(Value::as_str))
        .map(str::to_string);
    let count = body.get("count").and_then(Value::as_u64);
    ncm_domain::PlaylistEditResult {
        code,
        message,
        count,
        ok: code == 200,
    }
}

/// 每日推荐歌单的响应形如 {code:200, recommend:[{id,name,picUrl,trackCount,...}]}
pub fn parse_recommend_playlists(body: &Value) -> Vec<Playlist> {
    body.get("recommend")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_playlist).collect())
        .unwrap_or_default()
}

/// 歌单详情的响应形如 {code:200, playlist:{id,name,coverImgUrl,description,creator:{nickname},
/// trackCount,playCount,subscribed,subscribedCount,shareCount,commentCount,tags:[]}}
pub fn parse_playlist_detail(body: &Value) -> ProviderResult<PlaylistDetail> {
    let pl = body
        .get("playlist")
        .ok_or_else(|| ProviderError::not_found("playlist_detail: missing playlist"))?;
    Ok(PlaylistDetail {
        id: u64_of(pl, "id").unwrap_or(0),
        name: str_of(pl, "name").unwrap_or_default(),
        cover_url: str_of(pl, "coverImgUrl").or_else(|| str_of(pl, "picUrl")),
        description: str_of(pl, "description").unwrap_or_default(),
        creator_name: pl
            .get("creator")
            .and_then(|c| str_of(c, "nickname"))
            .unwrap_or_default(),
        creator_id: pl
            .get("creator")
            .and_then(|c| u64_of(c, "userId"))
            .or_else(|| u64_of(pl, "userId"))
            .unwrap_or(0),
        track_count: u64_of(pl, "trackCount").unwrap_or(0),
        play_count: u64_of(pl, "playCount").unwrap_or(0),
        subscribed: pl
            .get("subscribed")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        subscribed_count: u64_of(pl, "subscribedCount").unwrap_or(0),
        share_count: u64_of(pl, "shareCount").unwrap_or(0),
        comment_count: u64_of(pl, "commentCount").unwrap_or(0),
        tags: pl
            .get("tags")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
    })
}

/// 歌单分类: {code, categories:{0:"语种",1:"风格",...}, sub:[{category:0,name:"华语"},...]}
/// 结果按 categories 的 key 顺序给出, 同一一级分类下的子分类按接口顺序.
pub fn parse_playlist_categories(body: &Value) -> Vec<PlaylistCategory> {
    let mut groups: Vec<(String, Vec<String>)> = Vec::new();
    let mut index_of = std::collections::HashMap::new();
    let categories = body.get("categories").and_then(Value::as_object);
    if let Some(cats) = categories {
        let mut keys: Vec<(&String, &Value)> = cats.iter().collect();
        // key 是 "0".."4" 的数字字符串, 按数值排才和图上的顺序一致
        keys.sort_by_key(|(k, _)| k.parse::<u32>().unwrap_or(u32::MAX));
        for (k, v) in keys {
            let name = v.as_str().unwrap_or(k).to_string();
            index_of.insert(k.clone(), groups.len());
            groups.push((name, Vec::new()));
        }
    }
    if let Some(subs) = body.get("sub").and_then(Value::as_array) {
        for sub in subs {
            let name = str_of(sub, "name").unwrap_or_default();
            if name.is_empty() {
                continue;
            }
            let key = sub
                .get("category")
                .map(|c| c.to_string().trim_matches('"').to_string())
                .unwrap_or_default();
            match index_of.get(&key) {
                Some(&i) => groups[i].1.push(name),
                None => groups.push((String::new(), vec![name])),
            }
        }
    }
    groups
        .into_iter()
        .filter(|(group, subs)| !group.is_empty() && !subs.is_empty())
        .map(|(group, subs)| PlaylistCategory { group, subs })
        .collect()
}

/// 歌单桶: {code, playlists:[{id,name,coverImgUrl,trackCount}]}
pub fn parse_playlist_bucket(body: &Value, key: &str) -> Vec<Playlist> {
    body.get(key)
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_playlist).collect())
        .unwrap_or_default()
}
