//! 沙箱 JSON <-> `ncm-domain` DTO 的转换(纯函数, 可单测).
//!
//! 契约 v1 的脚本侧形状都是**我们**定义的(除 `musicUrl` 的位置参数沿用 Melodia
//! 已验证的调用形态), 与上游 LX 官方 spec 的差异记在 README「待验证项」.

use ncm_domain::{Album, Artist, SearchPage, Song, StreamUrl, TrackId};
use ncm_provider::{AudioLevel, SearchQuery};
use serde_json::{Map, Value};

use crate::error::PluginError;

/// 宿主音质档位 -> LX 代号(与 Melodia `mapQualityToLx` 实测口径一致).
pub fn quality_to_lx(level: AudioLevel) -> &'static str {
    match level {
        AudioLevel::Lossless => "flac",
        AudioLevel::Hires => "flac24bit",
        AudioLevel::Exhigh => "320k",
        // Melodia 的映射是「exhigh 以外一律 128k」, 含 higher.
        _ => "128k",
    }
}

fn string_field(map: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        match map.get(*key) {
            Some(Value::String(s)) if !s.is_empty() => return Some(s.clone()),
            Some(Value::Number(n)) => return Some(n.to_string()),
            _ => {}
        }
    }
    None
}

fn u64_field(map: &Map<String, Value>, keys: &[&str]) -> Option<u64> {
    for key in keys {
        match map.get(*key) {
            Some(Value::Number(n)) => {
                if let Some(v) = n.as_u64() {
                    return Some(v);
                }
                if let Some(f) = n.as_f64() {
                    if f >= 0.0 {
                        return Some(f as u64);
                    }
                }
            }
            Some(Value::String(s)) => {
                if let Ok(v) = s.parse::<u64>() {
                    return Some(v);
                }
            }
            _ => {}
        }
    }
    None
}

fn format_from_url(url: &str) -> Option<String> {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    let ext = path.rsplit('.').next()?;
    if ext.len() > 5 || ext == path {
        return None;
    }
    Some(ext.to_ascii_lowercase())
}

/// `musicUrl` 的返回值 -> [`StreamUrl`].
///
/// 接受两种形态(脚本二选一):
/// - 字符串: `"https://..."`
/// - 对象: `{url, type?, br?, size?, expireAt?}`(`null`/空 url = 取不到链)
pub fn stream_url(raw: &Value, requested: AudioLevel) -> Result<StreamUrl, PluginError> {
    let quality = requested.as_str().to_string();
    match raw {
        Value::String(url) => {
            if url.trim().is_empty() {
                return Err(PluginError::no_url("脚本返回空直链"));
            }
            Ok(StreamUrl {
                url: Some(url.clone()),
                quality,
                format: format_from_url(url),
                ..StreamUrl::default()
            })
        }
        Value::Object(map) => {
            let url = string_field(map, &["url"]);
            let Some(url) = url else {
                return Err(PluginError::no_url("脚本返回对象里没有 url(或 url 为空)"));
            };
            let format = string_field(map, &["type", "format"]).or_else(|| format_from_url(&url));
            let expire_at = u64_field(map, &["expireAt", "expire_at"]).map(|v| {
                // 脚本惯例给毫秒(Date.now()+n); 大于 10^12 视为毫秒.
                if v > 1_000_000_000_000 {
                    v / 1000
                } else {
                    v
                }
            });
            Ok(StreamUrl {
                url: Some(url),
                quality,
                br: u64_field(map, &["br", "bitrate"]),
                size: u64_field(map, &["size"]),
                expire_at,
                actual_level: string_field(map, &["actualLevel", "actual_level"]),
                format,
                md5: string_field(map, &["md5"]),
                duration_ms: u64_field(map, &["durationMs", "duration_ms"]),
                is_trial: map
                    .get("isTrial")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                ..StreamUrl::default()
            })
        }
        Value::Null => Err(PluginError::no_url("脚本返回 null(取不到直链)")),
        other => Err(PluginError::protocol(format!(
            "musicUrl 返回值必须是字符串或对象, 收到 {}",
            type_name(other)
        ))),
    }
}

fn type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn artists_from(map: &Map<String, Value>) -> Vec<Artist> {
    if let Some(Value::Array(items)) = map.get("artists") {
        let mut out = Vec::with_capacity(items.len());
        for (index, item) in items.iter().enumerate() {
            match item {
                Value::String(name) if !name.is_empty() => out.push(Artist {
                    id: 0,
                    name: name.clone(),
                    avatar_url: None,
                }),
                Value::Object(obj) => {
                    let name = string_field(obj, &["name"]).unwrap_or_default();
                    if name.is_empty() {
                        continue;
                    }
                    out.push(Artist {
                        id: u64_field(obj, &["id"]).unwrap_or(index as u64),
                        name,
                        avatar_url: string_field(obj, &["avatarUrl", "avatar_url"]),
                    });
                }
                _ => {}
            }
        }
        if !out.is_empty() {
            return out;
        }
    }
    // 单串歌手: LX 系脚本常用 `singer` / `singerName`, 多歌手以 `/` 或 `、` 分隔.
    let joined = string_field(map, &["singer", "singerName", "artist"]).unwrap_or_default();
    if joined.is_empty() {
        return Vec::new();
    }
    joined
        .split(['/', '、', ',', '&'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|name| Artist {
            id: 0,
            name: name.to_string(),
            avatar_url: None,
        })
        .collect()
}

fn song_from(map: &Map<String, Value>) -> Option<Song> {
    let name = string_field(map, &["name", "title", "songname", "songName"])?;
    let id = u64_field(map, &["id", "songId", "song_id"]).unwrap_or(0);
    let album = match map.get("album") {
        Some(Value::Object(obj)) => Some(Album {
            id: u64_field(obj, &["id"]).unwrap_or(0),
            name: string_field(obj, &["name"]).unwrap_or_default(),
            pic_url: string_field(obj, &["picUrl", "pic_url"]),
        }),
        _ => string_field(map, &["albumName", "album_name", "album"]).map(|name| Album {
            id: u64_field(map, &["albumId", "album_id"]).unwrap_or(0),
            name,
            pic_url: None,
        }),
    };
    // `interval` 是秒(LX 惯例), `duration`/`durationMs` 是毫秒.
    let duration_ms = u64_field(map, &["interval"])
        .map(|sec| sec.saturating_mul(1000))
        .or_else(|| u64_field(map, &["durationMs", "duration_ms"]))
        .or_else(|| u64_field(map, &["duration"]))
        .unwrap_or(0);
    Some(Song {
        id: TrackId(id),
        name,
        artists: artists_from(map),
        album,
        duration_ms,
        fee: None,
        playable: true,
    })
}

/// `search` 的返回值 -> [`SearchPage`].
///
/// 接受两种形态: 歌曲数组, 或 `{songs: [...], total?, hasMore?}`.
/// 单曲字段名按 LX 社区脚本的常见写法宽松匹配(见 README「契约 v1 / search」).
pub fn search_page(raw: &Value, query: &SearchQuery) -> Result<SearchPage, PluginError> {
    let (items, total, has_more) = match raw {
        Value::Array(items) => (items.as_slice(), items.len() as u64, false),
        Value::Object(map) => {
            let items = map
                .get("songs")
                .or_else(|| map.get("data"))
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            let total = u64_field(map, &["total"]).unwrap_or(items.len() as u64);
            let has_more = map
                .get("hasMore")
                .or_else(|| map.get("has_more"))
                .and_then(Value::as_bool)
                .unwrap_or_else(|| (query.offset as u64 + items.len() as u64) < total);
            (items, total, has_more)
        }
        other => {
            return Err(PluginError::protocol(format!(
                "search 返回值必须是数组或对象, 收到 {}",
                type_name(other)
            )))
        }
    };

    let mut songs = Vec::new();
    for item in items {
        if let Value::Object(map) = item {
            if let Some(song) = song_from(map) {
                songs.push(song);
            }
        }
    }
    Ok(SearchPage {
        songs,
        total,
        has_more,
    })
}

/// `lyric` 未实现: 本切片只要求 1~2 个能力, 歌词留给后续切片(已在 README 列明).
pub fn lyric_unsupported() -> ncm_provider::ProviderError {
    ncm_provider::ProviderError::unsupported("脚本插件本切片不提供歌词(v2 待定)")
}
