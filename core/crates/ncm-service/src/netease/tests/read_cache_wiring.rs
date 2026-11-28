//! R5(2026-11-28): 只读缓存白名单扩容的**接线**判据.
//!
//! 为什么单独成文件: 白名单本身有 `read_cache` 的单测守着, 但"某个端点到底有没有走缓存"
//! 只能在 provider 层断言 —— 少接一行 `cached_body`, 白名单再全也白搭。
//! 判据统一是「同一 key 两次调用 = **1** 次上游」, 用计数版假 HTTP 数请求(多出来的那一个
//! 正是要抓的回归)。

use crate::netease::tests::cloud::CountingHttp;
use crate::netease::*;
use crate::read_cache::endpoint;
use ncm_domain::Session;

/// 直连假服务发一个 GET: load 闭包里只需要"打一次上游"这件事本身,
/// 不需要 provider 的签名/加密路径(那部分另有端到端用例覆盖)。
fn hit(base: &str) -> ProviderResult<serde_json::Value> {
    use std::io::{Read, Write};
    let addr = base.trim_start_matches("http://");
    let mut stream = std::net::TcpStream::connect(addr)
        .map_err(|e| ProviderError::network(format!("connect {addr}: {e}")))?;
    stream
        .write_all(b"GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n")
        .map_err(|e| ProviderError::network(e.to_string()))?;
    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .map_err(|e| ProviderError::network(e.to_string()))?;
    Ok(serde_json::json!({"code": 200, "raw_len": raw.len()}))
}

async fn once(
    p: &NeteaseProvider,
    base: &str,
    ep: &str,
    params: &[(&str, String)],
) -> ProviderResult<()> {
    let base = base.to_string();
    p.cached_body(ep, params, move || async move {
        tokio::task::spawn_blocking(move || hit(&base))
            .await
            .map_err(|e| ProviderError::internal(format!("join: {e}")))?
    })
    .await
    .map(|_| ())
}

/// R5 新增端点逐个过闸: 同 key 两次 ⇒ 1 次上游; 换参数 ⇒ 新 key(再来 1 次)。
#[tokio::test]
async fn every_new_readonly_endpoint_hits_upstream_once_per_key() {
    let http = CountingHttp::start(200, r#"{"code":200,"data":[]}"#);
    let base = http.base();
    let p = NeteaseProvider::with_domain_for_test(Session::default(), base.clone());
    let endpoints = [
        endpoint::ARTIST_SONGS,
        endpoint::ARTIST_ALBUMS,
        endpoint::ARTIST_MVS,
        endpoint::ARTIST_DETAIL,
        endpoint::ARTIST_TOP_SONG,
        endpoint::HOT_ARTISTS,
        endpoint::SIMILAR_ARTISTS,
        endpoint::MV_DETAIL,
        endpoint::RADIO_DETAIL,
        endpoint::RADIO_PROGRAMS,
        endpoint::RADIO_PROGRAM_DETAIL,
        endpoint::RADIO_HOT,
        endpoint::CHARTS,
        endpoint::TOPLIST_CATALOG,
        endpoint::NEW_SONGS,
        endpoint::NEW_ALBUMS,
        endpoint::NEWEST_ALBUMS,
        endpoint::TOP_ALBUMS,
        endpoint::PLAYLIST_CATEGORIES,
        endpoint::CATEGORY_PLAYLISTS,
        endpoint::HIGH_QUALITY_PLAYLISTS,
    ];
    let key = [("id", "7".to_string())];
    for ep in endpoints {
        once(&p, &base, ep, &key)
            .await
            .unwrap_or_else(|e| panic!("{ep} 第一次应成功: {e:?}"));
        once(&p, &base, ep, &key)
            .await
            .unwrap_or_else(|e| panic!("{ep} 第二次应命中缓存: {e:?}"));
        assert_eq!(
            http.hits(),
            1,
            "{ep} 的第二次调用必须命中缓存, 不能重打上游"
        );
        http.reset_hits();
        // 换参数 = 换 key ⇒ 必须真的再打一次(否则说明 key 把参数吞了, 会串数据)
        let other = [("id", "8".to_string())];
        once(&p, &base, ep, &other).await.expect("不同 key 应成功");
        assert_eq!(http.hits(), 1, "{ep} 换了参数就必须重取(不能共用一个 key)");
        http.reset_hits();
    }
    assert_eq!(
        http.finish(),
        0,
        "循环里已经逐次对过账, 收工时应无未结账请求"
    );
}

/// 端到端(真走 provider 方法 + 真解析): 歌手歌曲分页两次 = 1 次上游。
#[tokio::test]
async fn artist_songs_page_is_cached_end_to_end() {
    let http = CountingHttp::start(200, r#"{"code":200,"more":false,"songs":[]}"#);
    let base = http.base();
    let p = NeteaseProvider::with_domain_for_test(Session::default(), base);

    for i in 0..2 {
        let page = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            p.artist_songs_page(6452, 0, 50),
        )
        .await
        .expect("假服务应在超时内回包")
        .unwrap_or_else(|e| panic!("第 {i} 次应成功: {e:?}"));
        assert!(page.songs.is_empty());
        assert!(!page.has_more);
    }
    assert_eq!(http.hits(), 1, "同参两次调用只能打 1 次上游");
    assert_eq!(http.finish(), 1);
}
