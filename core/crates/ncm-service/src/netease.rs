use std::sync::RwLock;

use ncm_api_rs::{ApiClient, NcmError, Query};
use ncm_domain::{Album, Artist, Lyric, SearchPage, Session, Song, StreamUrl, TrackId};
use ncm_provider::{
    BoxFuture, Capability, Provider, ProviderError, ProviderResult, SearchQuery, SongUrlRequest,
};
use serde_json::Value;

pub const CAPABILITIES: &[Capability] = &[
    Capability::Search,
    Capability::SongUrl,
    Capability::Lyric,
    Capability::Login,
    Capability::Profile,
];

/// 内置网易云直连 provider.
/// 协议与加解密全部委托给 vendor/ncm-api (api-enhanced 的 Rust 移植).
pub struct NeteaseProvider {
    inner: RwLock<Inner>,
}

struct Inner {
    client: ApiClient,
    session: Session,
    domain: Option<String>,
    ua: Option<String>,
}

impl Inner {
    fn new(session: Session, domain: Option<String>, ua: Option<String>) -> Self {
        let cookie = if session.cookie.is_empty() {
            None
        } else {
            Some(session.cookie.clone())
        };
        let mut client = ApiClient::new(cookie);
        if !session.device_id.is_empty() {
            client.set_device_id(session.device_id.clone());
        }
        Self { client, session, domain, ua }
    }

    fn query(&self) -> Query {
        let mut q = Query::new();
        q.domain = self.domain.clone();
        q.ua = self.ua.clone();
        q
    }
}

impl NeteaseProvider {
    /// 默认通道. NCM_DOMAIN / NCM_UA 是给风控实验用的临时旋钮(M0 spike),
    /// 正式实现应改成配置项而不是环境变量.
    pub fn new(session: Session) -> Self {
        let domain = std::env::var("NCM_DOMAIN").ok().filter(|s| !s.is_empty());
        let ua = std::env::var("NCM_UA").ok().filter(|s| !s.is_empty());
        Self { inner: RwLock::new(Inner::new(session, domain, ua)) }
    }

    /// 覆盖域名/UA (风控实验用): 例如切 interface3 + 网页 UA
    pub fn with_channel(session: Session, domain: Option<String>, ua: Option<String>) -> Self {
        Self { inner: RwLock::new(Inner::new(session, domain, ua)) }
    }

    pub fn update_session(&self, session: Session) {
        let mut guard = self.inner.write().unwrap_or_else(|e| e.into_inner());
        let domain = guard.domain.clone();
        let ua = guard.ua.clone();
        *guard = Inner::new(session, domain, ua);
    }

    /// await 之前先把要用的东西克隆出来: 避免 std RwLock guard 跨 await (破坏 Send)
    fn snapshot(&self) -> (ApiClient, Option<String>, Option<String>, String) {
        let guard = self.inner.read().unwrap_or_else(|e| e.into_inner());
        let mut q = guard.query();
        q.cookie = None;
        (guard.client.clone(), guard.domain.clone(), guard.ua.clone(), guard.session.cookie.clone())
    }
}

fn make_query(cookie: &str, domain: &Option<String>, ua: &Option<String>) -> Query {
    let mut q = Query::new();
    if !cookie.is_empty() {
        q = q.cookie(cookie);
    }
    q.domain = domain.clone();
    q.ua = ua.clone();
    q
}

fn map_error(e: NcmError) -> ProviderError {
    match e {
        NcmError::AuthRequired(msg) => ProviderError::auth(msg),
        NcmError::RateLimited(msg) => ProviderError::risk_control(msg),
        NcmError::Api { code, msg } => map_code(code, msg),
        NcmError::Timeout(msg) => ProviderError::network(format!("timeout: {msg}")),
        NcmError::Http(err) => ProviderError::network(err.to_string()),
        other => ProviderError::internal(other.to_string()),
    }
}

fn map_code(code: i64, msg: String) -> ProviderError {
    let detail = if msg.is_empty() {
        format!("code={code}")
    } else {
        format!("code={code}: {msg}")
    };
    match code {
        200 | 0 => ProviderError::internal(detail),
        301 | 401 => ProviderError::auth(detail),
        8821 | -462 => ProviderError::risk_control(detail),
        -110 | 404 => ProviderError::not_found(detail),
        _ => ProviderError::internal(detail),
    }
}

/// 业务 code 校验: 网易云常在 HTTP 200 里返回 code != 200
fn check_body(body: &Value) -> ProviderResult<()> {
    match body.get("code").and_then(Value::as_i64) {
        None => Ok(()),
        Some(200) | Some(0) => Ok(()),
        Some(code) => {
            let msg = body
                .get("message")
                .or_else(|| body.get("msg"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            Err(map_code(code, msg))
        }
    }
}

fn u64_of(v: &Value, key: &str) -> Option<u64> {
    v.get(key).and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|s| s.parse().ok())))
}

fn str_of(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

fn parse_song(v: &Value) -> Option<Song> {
    let id = u64_of(v, "id")?;
    let artists = v
        .get("ar")
        .or_else(|| v.get("artists"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|a| Artist {
                    id: u64_of(a, "id").unwrap_or(0),
                    name: str_of(a, "name").unwrap_or_default(),
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
        duration_ms: u64_of(v, "dt").or_else(|| u64_of(v, "duration")).unwrap_or(0),
        fee: v.get("fee").and_then(Value::as_i64),
    })
}

pub fn parse_search(body: &Value) -> ProviderResult<SearchPage> {
    let result = body
        .get("result")
        .ok_or_else(|| ProviderError::internal("search: missing result"))?;
    let songs = result
        .get("songs")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_song).collect())
        .unwrap_or_default();
    Ok(SearchPage {
        songs,
        total: u64_of(result, "songCount").unwrap_or(0),
        has_more: result
            .get("hasMore")
            .and_then(Value::as_bool)
            .or_else(|| result.get("more").and_then(Value::as_bool))
            .unwrap_or(false),
    })
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

impl Provider for NeteaseProvider {
    fn id(&self) -> &'static str {
        "netease"
    }

    fn name(&self) -> &str {
        "网易云音乐"
    }

    fn capabilities(&self) -> &'static [Capability] {
        CAPABILITIES
    }

    fn search<'a>(&'a self, query: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("keywords", &query.keywords)
                .param("limit", &query.limit.to_string())
                .param("offset", &query.offset.to_string())
                .param("type", "1");
            let resp = client.cloudsearch(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_search(&resp.body)
        })
    }

    fn song_url<'a>(&'a self, req: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
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

    fn lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &track.to_string());
            let resp = client.lyric(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_lyric(&resp.body)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_provider::ProviderErrorKind;
    use serde_json::json;

    #[test]
    fn search_mapping() {
        let body = json!({
            "code": 200,
            "result": {
                "songCount": 42,
                "hasMore": true,
                "songs": [{
                    "id": 186016,
                    "name": "晴天",
                    "ar": [{"id": 6452, "name": "周杰伦"}],
                    "al": {"id": 1, "name": "叶惠美", "picUrl": "http://p/1.jpg"},
                    "dt": 269000,
                    "fee": 1
                }]
            }
        });
        let page = parse_search(&body).unwrap();
        assert_eq!(page.total, 42);
        assert!(page.has_more);
        assert_eq!(page.songs.len(), 1);
        assert_eq!(page.songs[0].artist_line(), "周杰伦");
        assert_eq!(page.songs[0].album.as_ref().unwrap().name, "叶惠美");
    }

    #[test]
    fn stream_mapping_and_expiry() {
        let body = json!({
            "code": 200,
            "data": [{"id": 1, "url": "http://m/1.flac", "br": 999000, "size": 12345, "expi": 1200, "code": 200}]
        });
        let s = parse_stream(&body, "exhigh").unwrap();
        assert!(s.is_playable());
        assert_eq!(s.br, Some(999000));
        assert!(s.expire_at.unwrap() > 0);
    }

    #[test]
    fn stream_vip_without_login_has_no_url() {
        let body = json!({"code": 200, "data": [{"id": 1, "url": null, "code": 200, "expi": 1200}]});
        let s = parse_stream(&body, "exhigh").unwrap();
        assert!(!s.is_playable());
    }

    #[test]
    fn code_8821_is_risk_control() {
        let body = json!({"code": 8821, "message": "安全环境风险"});
        let err = check_body(&body).unwrap_err();
        assert_eq!(err.kind, ProviderErrorKind::RiskControl);
    }

    #[test]
    fn lyric_mapping() {
        let body = json!({"code": 200, "lrc": {"lyric": "[00:00.00]hi"}, "tlyric": {"lyric": "[00:00.00]嗨"}});
        let l = parse_lyric(&body).unwrap();
        assert_eq!(l.lrc.as_deref(), Some("[00:00.00]hi"));
        assert_eq!(l.translated.as_deref(), Some("[00:00.00]嗨"));
        assert!(l.romaji.is_none());
    }
}
