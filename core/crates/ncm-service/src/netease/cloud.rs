//! 音乐云盘: 列表 / 删除 / 下载直链. 上传(NOS 分片)本轮不做.

use super::*;

impl NeteaseProvider {
    /// 云盘歌曲列表(分页). 需要登录.
    pub(super) fn user_cloud(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<CloudPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("音乐云盘需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.max(1).to_string())
                .param("offset", &offset.to_string());
            let resp = client.user_cloud(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_cloud_page(&resp.body))
        })
    }

    /// 删除云盘歌曲. 入参是**云盘条目 id**(CloudSong::id), 不是 songId.
    pub(super) fn cloud_delete(&self, ids: &[u64]) -> BoxFuture<'_, ProviderResult<bool>> {
        let ids = ids.to_vec();
        Box::pin(async move {
            if ids.is_empty() {
                return Err(ProviderError::internal("cloud_delete: 没有要删除的条目"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("删除云盘歌曲需要登录"));
            }
            let joined = ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            let q = make_query(&cookie, &domain, &ua).param("songIds", &joined);
            let resp = client.user_cloud_del(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 云盘歌曲的下载直链(eapi /api/cloud/dowonload). 需要登录.
    pub(super) fn cloud_song_url(
        &self,
        song_id: u64,
    ) -> BoxFuture<'_, ProviderResult<Option<String>>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("歌曲 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("云盘下载需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("songId", &song_id.to_string());
            let resp = client.song_cloud_download(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_cloud_song_url(&resp.body))
        })
    }
}

/// user_cloud 响应: {code, count, size, maxSize, hasMore?, more?, data:[...]}.
///
/// data[] 里既有云盘文件字段(id/fileSize/bitrate/addTime), 也有内嵌的
/// simpleSong(歌曲元信息: 名字/歌手/专辑封面). 老数据可能没有 simpleSong,
/// 这时退回 fileName 当歌名.
pub fn parse_cloud_page(body: &Value) -> CloudPage {
    let songs = body
        .get("data")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_cloud_song).collect::<Vec<_>>())
        .unwrap_or_default();
    CloudPage {
        songs,
        count: u64_of(body, "count").unwrap_or(0),
        size: u64_of(body, "size").unwrap_or(0),
        max_size: u64_of(body, "maxSize").unwrap_or(0),
        more: body
            .get("more")
            .or_else(|| body.get("hasMore"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}

pub fn parse_cloud_song(v: &Value) -> Option<CloudSong> {
    let simple = v.get("simpleSong");
    let song_id = u64_of(v, "songId")
        .or_else(|| simple.and_then(|s| u64_of(s, "id")))
        .unwrap_or(0);
    // 云盘条目 id 缺失时退回 songId: 至少还能删(同一首歌只上传一份是常态)
    let id = u64_of(v, "id").or_else(|| u64_of(v, "songId")).unwrap_or(0);
    let name = simple
        .and_then(|s| str_of(s, "name"))
        .or_else(|| str_of(v, "fileName"))
        .unwrap_or_default();
    if id == 0 && song_id == 0 {
        return None;
    }
    let artist = simple
        .and_then(|s| s.get("ar").or_else(|| s.get("artists")))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| str_of(a, "name"))
                .filter(|n| !n.is_empty())
                .collect::<Vec<_>>()
                .join(" / ")
        })
        .unwrap_or_default();
    let album_obj = simple.and_then(|s| s.get("al").or_else(|| s.get("album")));
    let album = album_obj
        .and_then(|a| str_of(a, "name"))
        .unwrap_or_default();
    let cover_url = album_obj
        .and_then(|a| str_of(a, "picUrl").or_else(|| str_of(a, "blurPicUrl")))
        .or_else(|| str_of(v, "coverUrl"))
        .filter(|s| !s.is_empty());
    Some(CloudSong {
        id,
        song_id: if song_id != 0 { song_id } else { id },
        name,
        artist,
        album,
        cover_url,
        size: u64_of(v, "fileSize")
            .or_else(|| u64_of(v, "size"))
            .unwrap_or(0),
        bitrate: u64_of(v, "bitrate").unwrap_or(0),
        add_time: u64_of(v, "addTime").unwrap_or(0),
    })
}

/// /api/cloud/dowonload 的响应: 直链可能在 data.url, 也可能在 data[0].url.
pub fn parse_cloud_song_url(body: &Value) -> Option<String> {
    let data = body.get("data");
    let url = data
        .and_then(|d| str_of(d, "url"))
        .or_else(|| {
            data.and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(|first| str_of(first, "url"))
        })
        .or_else(|| str_of(body, "url"))
        .filter(|s| !s.is_empty());
    url
}
