//! 歌词域: LRC 与逐字(YRC)歌词.

use super::*;

impl NeteaseProvider {
    pub(super) fn lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            // 歌词内容几乎不变, 播放页/滚动/切歌会反复取: 走只读缓存.
            let key = crate::read_cache::cache_key(
                crate::read_cache::endpoint::LYRIC,
                &[("id", track.to_string())],
            );
            let body = self
                .read_cache()
                .get_or_load(crate::read_cache::endpoint::LYRIC, &key, || async {
                    let q = make_query(&cookie, &domain, &ua).param("id", &track.to_string());
                    let resp = client.lyric(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            parse_lyric(&body)
        })
    }

    pub(super) fn word_lyric<'a>(
        &'a self,
        track: TrackId,
    ) -> BoxFuture<'a, ProviderResult<WordLyric>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            // 同上(逐字歌词 yrc).
            let key = crate::read_cache::cache_key(
                crate::read_cache::endpoint::LYRIC_NEW,
                &[("id", track.to_string())],
            );
            let body = self
                .read_cache()
                .get_or_load(crate::read_cache::endpoint::LYRIC_NEW, &key, || async {
                    let q = make_query(&cookie, &domain, &ua).param("id", &track.to_string());
                    let resp = client.lyric_new(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            parse_word_lyric_body(&body)
        })
    }
}

pub fn parse_lyric(body: &Value) -> ProviderResult<Lyric> {
    let part = |key: &str| {
        body.get(key)
            .and_then(|x| x.get("lyric"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    Ok(Lyric {
        lrc: part("lrc"),
        translated: part("tlyric"),
        romaji: part("romalrc"),
    })
}

/// 从 lyric_new 响应解析逐字歌词; 无 yrc 时返回空 WordLyric(不报错, 由调用方退化).
pub fn parse_word_lyric_body(body: &Value) -> ProviderResult<WordLyric> {
    let yrc = body
        .get("yrc")
        .and_then(|x| x.get("lyric"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let Some(yrc) = yrc else {
        return Ok(WordLyric::default());
    };
    // ytlrc 实测恒空; 翻译兜底用 tlyric(行级 LRC, 按行首对齐)
    let translated = body
        .get("ytlrc")
        .and_then(|x| x.get("lyric"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            body.get("tlyric")
                .and_then(|x| x.get("lyric"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        });
    Ok(ncm_domain::parse_word_lyric_with_translation(
        &yrc, translated,
    ))
}
