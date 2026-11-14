//! 专辑域: 专辑详情/新碟/订阅.

use super::*;

impl NeteaseProvider {
    /// 我收藏的专辑: 响应 {code, data:[{id,name,picUrl,artist:{name},size}], hasMore}
    pub(super) fn subscribed_albums(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看收藏的专辑需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", "0");
            let resp = client.album_sublist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_album_items(&resp.body))
        })
    }

    /// 收藏/取消收藏专辑: t=1 收藏, 0 取消
    pub(super) fn set_album_subscribed(
        &self,
        album_id: u64,
        subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏专辑需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &album_id.to_string())
                .param("t", if subscribed { "1" } else { "0" });
            let resp = client.album_sub(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 新碟上架: {code, albums:[{id,name,picUrl,artist:{name},size}]}
    pub(super) fn new_albums(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.album_new(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_album_items(&resp.body))
        })
    }

    /// 最新专辑(album_newest): 与 album_new 不同源, 实测固定 12 张, 无 total, 不翻页.
    pub(super) fn newest_albums(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.album_newest(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut out = parse_album_items(&resp.body);
            out.truncate(limit as usize);
            Ok(out)
        })
    }

    /// 新碟上架(按地区). `top_album` 的 weekData 在部分地区为空, monthData 才有货,
    /// 所以两边合并(按 id 去重)再截断。
    pub(super) fn new_albums_by_area<'a>(
        &'a self,
        area: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("area", album_area_code(area))
                .param("limit", &limit.to_string())
                .param("offset", "0");
            let resp = client.top_album(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_new_albums(&resp.body, limit))
        })
    }

    /// 专辑详情(封面预览 + 曲目)
    pub(super) fn album_detail(&self, album_id: u64) -> BoxFuture<'_, ProviderResult<AlbumDetail>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            // 纯公开数据(封面/曲目/发行信息): 走只读缓存.
            let key = crate::read_cache::cache_key(
                crate::read_cache::endpoint::ALBUM_DETAIL,
                &[("id", album_id.to_string())],
            );
            let body = self
                .read_cache()
                .get_or_load(crate::read_cache::endpoint::ALBUM_DETAIL, &key, || async {
                    let q = make_query(&cookie, &domain, &ua).param("id", &album_id.to_string());
                    let resp = client.album(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            parse_album(&body)
        })
    }
}

/// 专辑详情的响应形如 {code:200, album:{id,name,picUrl,artist,description}, songs:[...]}
pub fn parse_album(body: &Value) -> ProviderResult<AlbumDetail> {
    let album = body
        .get("album")
        .ok_or_else(|| ProviderError::not_found("album: missing album"))?;
    let artist = album
        .get("artist")
        .and_then(|a| str_of(a, "name"))
        .or_else(|| {
            album
                .get("artists")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .and_then(|a| str_of(a, "name"))
        })
        .unwrap_or_default();
    Ok(AlbumDetail {
        id: u64_of(album, "id").unwrap_or(0),
        name: str_of(album, "name").unwrap_or_default(),
        cover_url: str_of(album, "picUrl").or_else(|| str_of(album, "blurPicUrl")),
        artist,
        description: str_of(album, "description").unwrap_or_default(),
        songs: parse_song_list(body),
    })
}

/// 新碟: {code, weekData:[album], monthData:[album]} —— 两边合并去重后截断
pub fn parse_new_albums(body: &Value, limit: u32) -> Vec<AlbumItem> {
    let mut out: Vec<AlbumItem> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for key in ["weekData", "monthData"] {
        let Some(arr) = body.get(key).and_then(Value::as_array) else {
            continue;
        };
        for v in arr {
            let Some(item) = parse_album_item(v) else {
                continue;
            };
            if seen.insert(item.id) {
                out.push(item);
                if out.len() >= limit as usize {
                    return out;
                }
            }
        }
    }
    out
}
