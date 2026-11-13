//! 响应 JSON -> domain 类型的共享 parse 辅助(字段提取/歌曲/歌单/专辑/权益).

use super::*;

pub(super) fn u64_of(v: &Value, key: &str) -> Option<u64> {
    v.get(key).and_then(|x| {
        x.as_u64()
            .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
    })
}

pub(super) fn str_of(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

pub(super) fn u32_of(v: &Value, key: &str) -> Option<u32> {
    u64_of(v, key).and_then(|n| u32::try_from(n).ok())
}

/// lastRank 是 i32(服务器用 -1 表示新上榜), 与其它计数不同
pub(super) fn i32_of(v: &Value, key: &str) -> Option<i32> {
    v.get(key)
        .and_then(|x| {
            x.as_i64()
                .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
        })
        .and_then(|n| i32::try_from(n).ok())
}

/// 从响应里收集 `privileges[]`(key=曲目 id). 搜索/详情/歌单各接口给的位置不同,
/// 有的直接内嵌在 song 上(`privilege`), 两种都认。
pub(super) fn parse_privileges(body: &Value) -> std::collections::HashMap<u64, bool> {
    let mut map = std::collections::HashMap::new();
    let arrays = [
        body.get("privileges").and_then(Value::as_array),
        body.get("result")
            .and_then(|r| r.get("privileges"))
            .and_then(Value::as_array),
        body.get("data")
            .and_then(|d| d.get("privileges"))
            .and_then(Value::as_array),
    ];
    for arr in arrays.into_iter().flatten() {
        for p in arr {
            if let Some(id) = u64_of(p, "id") {
                map.insert(id, privilege_playable(p));
            }
        }
    }
    map
}

/// st < 0 就是"这首在你这儿没版权/已下架"(实测 -200 最常见), pl=0 表示不可播。
pub(super) fn privilege_playable(p: &Value) -> bool {
    let st = p.get("st").and_then(Value::as_i64).unwrap_or(0);
    if st < 0 {
        return false;
    }
    match p.get("pl").and_then(Value::as_i64) {
        // 匿名/未登录时 VIP 曲目 pl=0, 但那只是"要会员", 仍属可播范畴
        Some(_) => true,
        None => true,
    }
}

pub(super) fn parse_song_with(
    v: &Value,
    privileges: &std::collections::HashMap<u64, bool>,
) -> Option<Song> {
    let id = u64_of(v, "id")?;
    // 优先级: song 自带的 privilege > 响应级 privileges[] > 默认可播
    let playable = v
        .get("privilege")
        .map(privilege_playable)
        .or_else(|| privileges.get(&id).copied())
        .unwrap_or(true);
    let artists = v
        .get("ar")
        .or_else(|| v.get("artists"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|a| Artist {
                    id: u64_of(a, "id").unwrap_or(0),
                    name: str_of(a, "name").unwrap_or_default(),
                    avatar_url: str_of(a, "picUrl")
                        .or_else(|| str_of(a, "img1v1Url"))
                        .filter(|s| !s.is_empty()),
                })
                .collect()
        })
        .unwrap_or_default();
    let album = v.get("al").or_else(|| v.get("album")).map(|a| Album {
        id: u64_of(a, "id").unwrap_or(0),
        name: str_of(a, "name").unwrap_or_default(),
        pic_url: str_of(a, "picUrl").or_else(|| str_of(a, "pic_url")),
    });
    Some(Song {
        id: TrackId::new(id),
        name: str_of(v, "name").unwrap_or_default(),
        artists,
        album,
        duration_ms: u64_of(v, "dt")
            .or_else(|| u64_of(v, "duration"))
            .unwrap_or(0),
        fee: v.get("fee").and_then(Value::as_i64),
        playable,
    })
}

/// 详情类接口(body 里 songs[] + privileges[])统一走这个
pub(super) fn parse_song_list(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 用户歌单列表里的一项. specialType=5 是"我喜欢的音乐"。
pub(super) fn parse_playlist(v: &Value) -> Option<Playlist> {
    let id = u64_of(v, "id")?;
    Some(Playlist {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "coverImgUrl")
            .or_else(|| str_of(v, "coverUrl"))
            .or_else(|| str_of(v, "picUrl")),
        track_count: u64_of(v, "trackCount").unwrap_or(0),
        special: v.get("specialType").and_then(Value::as_i64) == Some(5),
    })
}

pub(super) fn artists_line_of(v: &Value) -> String {
    v.get("artists")
        .or_else(|| v.get("ar"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| a.get("name").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(" / ")
        })
        .unwrap_or_default()
}

/// 地区简写 → 新歌接口的 areaId(服务端枚举, 实测只有这五个有货)
pub(super) fn song_area_id(area: &str) -> i64 {
    match area {
        "zh" => 7,
        "jp" => 8,
        "kr" => 16,
        "ea" => 96,
        _ => 0,
    }
}

/// 地区简写 → 新碟接口的 area 参数
pub(super) fn album_area_code(area: &str) -> &'static str {
    match area {
        "zh" => "ZH",
        "jp" => "JP",
        "kr" => "KR",
        "ea" => "EA",
        _ => "ALL",
    }
}

/// 转发/动态载荷里的首图: pics[].picUrl|urlCommon
pub(super) fn pics_of(v: &Value) -> Option<String> {
    v.get("pics")
        .and_then(Value::as_array)
        .and_then(|p| p.first())
        .and_then(|p| str_of(p, "picUrl").or_else(|| str_of(p, "urlCommon")))
}

/// 网易部分接口给秒级时间戳(10 位), 统一归一成毫秒.
/// 阈值 1e11(约 5138 年的秒数 / 1973 年的毫秒数), 两侧都不会误伤.
pub(super) fn normalize_ms(t: u64) -> u64 {
    if t > 0 && t < 100_000_000_000 {
        t * 1000
    } else {
        t
    }
}

/// 收藏的专辑: {code, data:[{id,name,picUrl,artist:{name},size,subTime}], hasMore}
pub fn parse_album_items(body: &Value) -> Vec<AlbumItem> {
    body.get("data")
        .or_else(|| body.get("albums"))
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_album_item).collect())
        .unwrap_or_default()
}

/// 单个专辑对象(收藏专辑/最近播放专辑/新碟共用)
pub fn parse_album_item(v: &Value) -> Option<AlbumItem> {
    let id = u64_of(v, "id")?;
    let name = str_of(v, "name")?;
    if name.is_empty() {
        return None;
    }
    Some(AlbumItem {
        id,
        name,
        cover_url: str_of(v, "picUrl")
            .or_else(|| str_of(v, "coverImgUrl"))
            .filter(|s| s.starts_with("http")),
        artist: v
            .get("artist")
            .and_then(|a| str_of(a, "name"))
            .or_else(|| {
                v.get("artists").and_then(|a| {
                    a.as_array()
                        .and_then(|arr| arr.first())
                        .and_then(|x| str_of(x, "name"))
                })
            })
            .unwrap_or_default(),
        track_count: u64_of(v, "size")
            .or_else(|| u64_of(v, "trackCount"))
            .unwrap_or(0),
    })
}

/// 最近播放(专辑/歌单/电台)的响应形状: {code, data:{list:[{data:{...}}]}}
/// 只留下每条记录的 data 对象, 由各类型的解析器处理.
pub fn recent_items(body: &Value) -> Vec<Value> {
    body.get("data")
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|it| it.get("data").cloned().filter(|d| d.is_object()))
                .collect()
        })
        .unwrap_or_default()
}
