//! 只读接口的进程内响应缓存: TTL + 容量上限(LRU) + 同 key 单飞(in-flight dedupe).
//!
//! ## 为什么需要
//!
//! 反复搜索同一个词时, 服务端会回 `[internal] code=405 操作频繁, 请稍后再试` ——
//! 这是网易云的风控限流, 不是接口坏了。放大器在 provider 层:
//! 一次 `search_all` 并发 6 个 `cloudsearch`(单曲/歌手/专辑/歌单/播客/用户),
//! 再加「最长匹配」兜底最多 3 次/类型; 用户连点几次搜索就是每秒十几个请求。
//!
//! 缓存放在 **provider 的统一出口**(各能力方法拿到 body 的那一层), 而不是 UI/FFI 层:
//! 只要请求走到 provider, 就一定过这道闸, 不用每个调用方自己记得缓存。
//!
//! ## 纪律(测试守着, 别放宽)
//!
//! **只缓存与账号无关的只读接口**, 白名单见 [`CACHEABLE_ENDPOINTS`]。
//! 依赖登录态/凭据的结果(user_*、每日推荐、收藏、私信、喜欢状态、VIP 等)
//! 绝对不进缓存: 缓存 key 里没有 uid, 一旦缓存就可能在账号切换后把别人的数据
//! 端给当前用户。即便在白名单内, 会话变化时也会整体清空(`ReadCache::clear`),
//! 因为少数匿名接口的 body 里仍带账号相关字段(如歌单的 `subscribed`、
//! 搜索结果的 `privileges`)。
//!
//! ## 语义
//!
//! - TTL 默认 [`DEFAULT_TTL`](300s): 搜索/详情这类数据变化慢, 5 分钟内复用足够。
//! - 容量 [`DEFAULT_CAPACITY`](200 条), 满了按最近最少使用淘汰。
//! - 只缓存**成功**的结果; 错误(尤其是 405/风控)不缓存, 免得把瞬时故障钉住。
//! - 同 key 并发: 只有一个请求真打上游, 其余等它出结果后直接命中缓存
//!   (靠每 key 一把 `tokio::sync::Mutex`; 不引入额外依赖)。

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

use ncm_provider::ProviderResult;

/// 默认 TTL: 300s。
pub const DEFAULT_TTL: Duration = Duration::from_secs(300);
/// 默认容量: 200 条(key 数)。
pub const DEFAULT_CAPACITY: usize = 200;

/// 接口名常量. 名字进缓存 key, 必须与 [`CACHEABLE_ENDPOINTS`] 里的字符串一致。
pub mod endpoint {
    /// 搜索通用入口(cloudsearch, type 区分单曲/歌手/专辑/歌单/播客/用户)
    pub const CLOUDSEARCH: &str = "cloudsearch";
    /// 联想建议(/api/search/suggest)
    pub const SEARCH_SUGGEST: &str = "search_suggest";
    /// 精确实体改写(/api/search/suggest/multimatch)
    pub const SEARCH_MULTIMATCH: &str = "search_multimatch";
    /// 搜索热词榜(type=1111)
    pub const SEARCH_HOT: &str = "search_hot";
    /// 热搜榜详情(/api/hotsearchlist/get)
    pub const SEARCH_HOT_DETAIL: &str = "search_hot_detail";
    /// 歌单详情(/api/v6/playlist/detail)
    pub const PLAYLIST_DETAIL: &str = "playlist_detail";
    /// 专辑详情(/api/v1/album/:id)
    pub const ALBUM_DETAIL: &str = "album_detail";
    /// LRC 歌词(/api/song/lyric)
    pub const LYRIC: &str = "lyric";
    /// 逐字歌词(/api/song/lyric/v1, yrc)
    pub const LYRIC_NEW: &str = "lyric_new";
}

/// 允许进缓存的接口白名单 —— **本文件唯一的放行表**。
///
/// 逐个理由:
/// - cloudsearch / search_suggest / search_multimatch / search_hot / search_hot_detail:
///   搜索族匿名可用, 是 405 限流的直接来源, 参数只有关键词/分页/类型。
/// - playlist_detail: 公开歌单数据(封面/曲目/播放量), 匿名可取; 用户点开歌单再返回
///   反复触发, 缓存收益大。body 里的 `subscribed` 属账号侧字段, 由会话变更清空兜住。
/// - album_detail: 同 playlist_detail, 专辑详情是纯公开数据。
/// - lyric / lyric_new: 歌词内容几乎不变, 播放页/滚动/切歌会反复取。
///
/// **刻意不缓存**(需要账号上下文或变化太快, 缓存会串号或给过期结论):
/// user_playlist / user_detail / user_account / user_subcount / user_follows /
/// daily_recommend / personal_fm / recommend_resource / playlist_subscribe /
/// song_like_state / song_detail(body 带按账号算的 privileges) / comment* /
/// msg_* / vip* / digital_album* / default_search(登录后是「猜你想搜」个性化结果) /
/// signin* / event*。
pub const CACHEABLE_ENDPOINTS: &[&str] = &[
    endpoint::CLOUDSEARCH,
    endpoint::SEARCH_SUGGEST,
    endpoint::SEARCH_MULTIMATCH,
    endpoint::SEARCH_HOT,
    endpoint::SEARCH_HOT_DETAIL,
    endpoint::PLAYLIST_DETAIL,
    endpoint::ALBUM_DETAIL,
    endpoint::LYRIC,
    endpoint::LYRIC_NEW,
];

/// 该接口是否允许缓存(白名单命中)。
pub fn is_cacheable(endpoint: &str) -> bool {
    CACHEABLE_ENDPOINTS.contains(&endpoint)
}

/// 规范化缓存 key: `接口名 \x1f k=v \x1f k=v ...`, 参数按键名排序,
/// 这样同一个请求换个拼参数顺序也能命中(同 key 单飞才不会漏)。
pub fn cache_key(endpoint: &str, params: &[(&str, String)]) -> String {
    let mut items: Vec<(&str, &str)> = params
        .iter()
        .map(|(k, v)| (*k, v.as_str()))
        .filter(|(_, v)| !v.is_empty())
        .collect();
    items.sort_unstable();
    let mut out = String::with_capacity(endpoint.len() + 24 * (items.len() + 1));
    out.push_str(endpoint);
    for (k, v) in items {
        out.push('\u{1f}');
        out.push_str(k);
        out.push('=');
        out.push_str(v);
    }
    out
}

struct Entry {
    value: Value,
    stored: Instant,
    used: u64,
}

struct Inner {
    entries: HashMap<String, Entry>,
    /// 同 key 单飞: 正在加载的 key -> 该 key 的串行锁。
    inflight: HashMap<String, Arc<tokio::sync::Mutex<()>>>,
}

/// 进程内只读响应缓存(TTL + LRU + 单飞)。线程安全, 用 `&self` 即可。
pub struct ReadCache {
    ttl: Duration,
    capacity: usize,
    clock: AtomicU64,
    inner: Mutex<Inner>,
}

impl Default for ReadCache {
    fn default() -> Self {
        Self::new(DEFAULT_TTL, DEFAULT_CAPACITY)
    }
}

impl ReadCache {
    pub fn new(ttl: Duration, capacity: usize) -> Self {
        Self {
            ttl,
            capacity: capacity.max(1),
            clock: AtomicU64::new(0),
            inner: Mutex::new(Inner {
                entries: HashMap::new(),
                inflight: HashMap::new(),
            }),
        }
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// 当前缓存条数(含已过期但尚未淘汰的条目)。
    pub fn len(&self) -> usize {
        self.lock().entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 清空全部缓存。会话变化(登录/登出/切账号)时必须调用。
    pub fn clear(&self) {
        self.lock().entries.clear();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn next_tick(&self) -> u64 {
        self.clock.fetch_add(1, Ordering::Relaxed)
    }

    /// 取缓存(命中会刷新 LRU 时间戳)。
    pub fn get(&self, key: &str) -> Option<Value> {
        self.get_at(key, Instant::now())
    }

    fn get_at(&self, key: &str, now: Instant) -> Option<Value> {
        let tick = self.next_tick();
        let mut inner = self.lock();
        let expired = {
            let entry = inner.entries.get(key)?;
            now.saturating_duration_since(entry.stored) >= self.ttl
        };
        if expired {
            inner.entries.remove(key);
            return None;
        }
        let entry = inner.entries.get_mut(key)?;
        entry.used = tick;
        Some(entry.value.clone())
    }

    /// 写入缓存(满了先按 LRU 淘汰一条)。
    pub fn store(&self, key: &str, value: Value) {
        self.store_at(key, value, Instant::now());
    }

    fn store_at(&self, key: &str, value: Value, now: Instant) {
        let tick = self.next_tick();
        let mut inner = self.lock();
        if inner.entries.len() >= self.capacity && !inner.entries.contains_key(key) {
            if let Some(victim) = inner
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(k, _)| k.clone())
            {
                inner.entries.remove(&victim);
            }
        }
        inner.entries.insert(
            key.to_string(),
            Entry {
                value,
                stored: now,
                used: tick,
            },
        );
    }

    fn inflight_lock(&self, key: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut inner = self.lock();
        if let Some(lock) = inner.inflight.get(key) {
            return lock.clone();
        }
        let lock = Arc::new(tokio::sync::Mutex::new(()));
        inner.inflight.insert(key.to_string(), lock.clone());
        lock
    }

    fn release_inflight(&self, key: &str, lock: &Arc<tokio::sync::Mutex<()>>) {
        let mut inner = self.lock();
        if inner
            .inflight
            .get(key)
            .is_some_and(|current| Arc::ptr_eq(current, lock))
        {
            inner.inflight.remove(key);
        }
    }

    /// 缓存命中就直接回; 未命中原样调 `load` 打上游, 成功的结果写回缓存。
    ///
    /// `endpoint` 不在白名单时**完全不碰缓存**(连单飞也不做): 那些接口要么依赖
    /// 登录态, 要么有副作用, 串行化它们只会拖慢而不安全。
    pub async fn get_or_load<F, Fut>(
        &self,
        endpoint: &str,
        key: &str,
        load: F,
    ) -> ProviderResult<Value>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = ProviderResult<Value>>,
    {
        if !is_cacheable(endpoint) {
            return load().await;
        }
        if let Some(hit) = self.get(key) {
            return Ok(hit);
        }
        // 同 key 单飞: 拿到这把锁的才是 leader, 其余在这里排队;
        // leader 写回缓存后它们醒来直接命中(所以锁内要再查一次)。
        let lock = self.inflight_lock(key);
        let guard = lock.lock().await;
        if let Some(hit) = self.get(key) {
            drop(guard);
            self.release_inflight(key, &lock);
            return Ok(hit);
        }
        let result = load().await;
        if let Ok(value) = &result {
            self.store(key, value.clone());
        }
        drop(guard);
        self.release_inflight(key, &lock);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_provider::ProviderError;
    use std::sync::atomic::AtomicUsize;

    /// 可计数的假 fetcher: 返回 `{"payload": ..., "n": <第几次调用>}`。
    #[derive(Default)]
    struct Fetcher {
        calls: AtomicUsize,
    }

    impl Fetcher {
        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }

        async fn load(&self, payload: &str) -> ProviderResult<Value> {
            let n = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
            Ok(serde_json::json!({ "payload": payload, "n": n }))
        }
    }

    #[test]
    fn whitelist_covers_search_family_and_excludes_account_data() {
        for ep in [
            endpoint::CLOUDSEARCH,
            endpoint::SEARCH_SUGGEST,
            endpoint::SEARCH_MULTIMATCH,
            endpoint::SEARCH_HOT,
            endpoint::SEARCH_HOT_DETAIL,
            endpoint::PLAYLIST_DETAIL,
            endpoint::ALBUM_DETAIL,
            endpoint::LYRIC,
            endpoint::LYRIC_NEW,
        ] {
            assert!(is_cacheable(ep), "{ep} 应在白名单里");
        }
        // 纪律: 依赖登录态/凭据的结果一律不缓存
        for ep in [
            "user_playlist",
            "user_detail",
            "user_account",
            "user_subcount",
            "daily_recommend",
            "personal_fm",
            "recommend_resource",
            "playlist_subscribe",
            "song_like_state",
            "song_detail",
            "comment_music",
            "msg_private",
            "vip_info",
            "default_search",
            "signin_progress",
        ] {
            assert!(!is_cacheable(ep), "{ep} 绝不能进缓存");
        }
    }

    #[test]
    fn cache_key_is_canonical() {
        let a = cache_key(
            endpoint::CLOUDSEARCH,
            &[("keywords", "郑成河".into()), ("type", "1".into())],
        );
        let b = cache_key(
            endpoint::CLOUDSEARCH,
            &[("type", "1".into()), ("keywords", "郑成河".into())],
        );
        assert_eq!(a, b, "参数顺序不应影响 key");
        let c = cache_key(endpoint::SEARCH_SUGGEST, &[("keywords", "郑成河".into())]);
        assert_ne!(a, c, "不同接口不能撞 key");
    }

    #[tokio::test]
    async fn hit_and_miss() {
        let cache = ReadCache::default();
        let fetcher = Fetcher::default();
        let key = cache_key(endpoint::CLOUDSEARCH, &[("keywords", "郑成河".into())]);

        let first = cache
            .get_or_load(endpoint::CLOUDSEARCH, &key, || fetcher.load("a"))
            .await
            .expect("load 应成功");
        assert_eq!(fetcher.calls(), 1, "首次未命中要打上游");
        assert_eq!(first["n"], 1);

        let second = cache
            .get_or_load(endpoint::CLOUDSEARCH, &key, || fetcher.load("a"))
            .await
            .expect("命中应成功");
        assert_eq!(fetcher.calls(), 1, "第二次必须命中缓存, 不打上游");
        assert_eq!(second, first);
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn ttl_expiry() {
        let cache = ReadCache::new(Duration::from_secs(300), 8);
        let now = Instant::now();
        cache.store_at("k", serde_json::json!({ "v": 1 }), now);
        assert!(cache.get_at("k", now + Duration::from_secs(299)).is_some());
        assert!(
            cache.get_at("k", now + Duration::from_secs(300)).is_none(),
            "满 TTL 必须过期"
        );
        assert_eq!(cache.len(), 0, "过期条目取用时顺手清掉");
    }

    #[test]
    fn lru_eviction() {
        let cache = ReadCache::new(Duration::from_secs(300), 2);
        cache.store("a", serde_json::json!(1));
        cache.store("b", serde_json::json!(2));
        // 摸一下 a: a 变成最近使用, 淘汰时该走 b
        assert!(cache.get("a").is_some());
        cache.store("c", serde_json::json!(3));
        assert_eq!(cache.len(), 2, "容量上限必须守住");
        assert!(cache.get("a").is_some(), "刚用过的 a 不该被淘汰");
        assert!(cache.get("b").is_none(), "最久未用的 b 应被淘汰");
        assert!(cache.get("c").is_some());
    }

    #[tokio::test]
    async fn concurrent_same_key_hits_upstream_once() {
        let cache = Arc::new(ReadCache::default());
        let fetcher = Arc::new(Fetcher::default());
        let key = cache_key(endpoint::CLOUDSEARCH, &[("keywords", "郑成河".into())]);

        let mut handles = Vec::new();
        for _ in 0..8 {
            let cache = cache.clone();
            let fetcher = fetcher.clone();
            let key = key.clone();
            handles.push(tokio::spawn(async move {
                cache
                    .get_or_load(endpoint::CLOUDSEARCH, &key, || async {
                        // 让出执行权, 保证其它任务有机会排队
                        tokio::time::sleep(Duration::from_millis(10)).await;
                        fetcher.load("a").await
                    })
                    .await
            }));
        }
        for handle in handles {
            handle.await.expect("task 不应 panic").expect("结果应成功");
        }
        assert_eq!(fetcher.calls(), 1, "并发同 key 只允许打一次上游");
    }

    #[tokio::test]
    async fn different_keys_are_not_deduped() {
        let cache = ReadCache::default();
        let fetcher = Fetcher::default();
        let k1 = cache_key(endpoint::CLOUDSEARCH, &[("keywords", "郑成河".into())]);
        let k2 = cache_key(endpoint::CLOUDSEARCH, &[("keywords", "晴天".into())]);
        cache
            .get_or_load(endpoint::CLOUDSEARCH, &k1, || fetcher.load("a"))
            .await
            .unwrap();
        cache
            .get_or_load(endpoint::CLOUDSEARCH, &k2, || fetcher.load("b"))
            .await
            .unwrap();
        assert_eq!(fetcher.calls(), 2);
        assert_eq!(cache.len(), 2);
    }

    #[tokio::test]
    async fn non_whitelisted_endpoint_bypasses_cache() {
        let cache = ReadCache::default();
        let fetcher = Fetcher::default();
        let key = cache_key("user_playlist", &[("uid", "42".into())]);
        for _ in 0..2 {
            cache
                .get_or_load("user_playlist", &key, || fetcher.load("u"))
                .await
                .expect("应成功");
        }
        assert_eq!(fetcher.calls(), 2, "白名单外必须每次打上游");
        assert_eq!(cache.len(), 0, "白名单外不许写缓存");
    }

    #[tokio::test]
    async fn errors_are_not_cached() {
        let cache = ReadCache::default();
        let key = cache_key(endpoint::SEARCH_HOT, &[]);
        let bad = cache
            .get_or_load(endpoint::SEARCH_HOT, &key, || async {
                Err(ProviderError::risk_control("code=405 操作频繁"))
            })
            .await;
        assert!(bad.is_err());
        assert!(cache.is_empty(), "风控/错误结果不能缓存");
        let ok = cache
            .get_or_load(endpoint::SEARCH_HOT, &key, || async {
                Ok(serde_json::json!({ "code": 200 }))
            })
            .await;
        assert!(ok.is_ok(), "错误之后下一次仍应正常打上游");
        assert_eq!(cache.len(), 1);
    }

    /// 复现用户报的「反复搜索同一关键词 → 405」: 一次 `search_all` 并发 6 个
    /// cloudsearch(type 1/100/10/1000/1009/1002), 连搜 5 次。
    /// 缓存生效后上游总量必须是 6(每 type 一次), 而不是 6x5=30。
    #[tokio::test]
    async fn repeated_search_bundle_hits_upstream_once_per_type() {
        const TYPES: [u32; 6] = [1, 100, 10, 1000, 1009, 1002];
        let cache = Arc::new(ReadCache::default());
        let fetcher = Arc::new(Fetcher::default());

        for _round in 0..5 {
            let mut batch = Vec::new();
            for kind in TYPES {
                let cache = cache.clone();
                let fetcher = fetcher.clone();
                batch.push(tokio::spawn(async move {
                    let key = cache_key(
                        endpoint::CLOUDSEARCH,
                        &[
                            ("keywords", "郑成河".to_string()),
                            ("type", kind.to_string()),
                            ("limit", "30".to_string()),
                            ("offset", "0".to_string()),
                        ],
                    );
                    cache
                        .get_or_load(endpoint::CLOUDSEARCH, &key, || async {
                            tokio::time::sleep(Duration::from_millis(5)).await;
                            fetcher.load("kw").await
                        })
                        .await
                }));
            }
            for handle in batch {
                handle.await.expect("task 不应 panic").expect("结果应成功");
            }
        }

        assert_eq!(fetcher.calls(), 6, "5 轮搜索只允许 6 次上游请求");
        assert_eq!(cache.len(), 6);
    }

    #[test]
    fn clear_drops_everything() {
        let cache = ReadCache::default();
        cache.store("a", serde_json::json!(1));
        cache.store("b", serde_json::json!(2));
        cache.clear();
        assert!(cache.is_empty());
    }
}
