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
//! - 容量 [`DEFAULT_CAPACITY`](200 条) + **字节上限** [`DEFAULT_MAX_BYTES`](24MB),
//!   满了按最近最少使用淘汰; 单条超过 [`DEFAULT_MAX_ENTRY_BYTES`](4MB) 的不入池。
//! - body 以 `Arc<Value>` 存放与返回: 命中只 `Arc::clone`, 不深拷贝(审计 R1)。
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
/// 默认**字节**上限: 24MB。
///
/// 只按条数限容在"body 大小差三个数量级"时失控: 搜索结果是几 KB, 而 1000 首歌单
/// (`playlist_track_all` / `liked` 的 `s=8` detail) 的 body 是 1–3MB, 200 条上界
/// 就是数百 MB(2026-11-28 Rust 审计 R1)。
pub const DEFAULT_MAX_BYTES: usize = 24 << 20;
/// 单条上限: 4MB。超过就不入缓存(宁可每次重取, 也不让一条大 body 把整池挤空)。
pub const DEFAULT_MAX_ENTRY_BYTES: usize = 4 << 20;

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
    /// 歌单全量曲目(/api/v6/playlist/track/all)
    pub const PLAYLIST_TRACK_ALL: &str = "playlist_track_all";
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
/// - playlist_track_all: 歌单曲目列表(点开歌单/回到列表/「我喜欢的音乐」
///   都会重取)。曲目本身的增删走用户主动操作, 5 分钟 TTL 不会让用户看到
///   "刚删掉的歌还在"(会话变更/主动刷新都会清)。
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
    endpoint::PLAYLIST_TRACK_ALL,
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

/// body 的字节估算: 递归数标量 + 键名 + 容器开销。
///
/// 不序列化(那本身就要一次全量拷贝): 只要量级正确就能让字节淘汰生效。
fn approx_json_bytes(value: &Value) -> usize {
    match value {
        Value::Null | Value::Bool(_) => 8,
        Value::Number(n) => n.to_string().len().max(8),
        Value::String(s) => s.len() + 16,
        Value::Array(items) => 16 + items.iter().map(approx_json_bytes).sum::<usize>(),
        Value::Object(map) => {
            16 + map
                .iter()
                .map(|(k, v)| k.len() + 8 + approx_json_bytes(v))
                .sum::<usize>()
        }
    }
}

struct Entry {
    /// 命中时只是 `Arc::clone`(旧实现是 `Value::clone` —— 每次命中都深拷贝整个
    /// body, 1000 首歌单命中一次就是一次 MB 级 alloc, 2026-11-28 Rust 审计 R1)
    value: Arc<Value>,
    /// 该条占多少字节(`Arc::strong_count` 不参与, 按 body 序列化后的近似值算)
    bytes: usize,
    stored: Instant,
    used: u64,
}

struct Inner {
    entries: HashMap<String, Entry>,
    /// 当前所有条目的字节总和(淘汰按它判)
    bytes: usize,
    /// 同 key 单飞: 正在加载的 key -> 该 key 的串行锁。
    inflight: HashMap<String, Arc<tokio::sync::Mutex<()>>>,
}

/// 进程内只读响应缓存(TTL + LRU + 单飞)。线程安全, 用 `&self` 即可。
pub struct ReadCache {
    ttl: Duration,
    capacity: usize,
    max_bytes: usize,
    max_entry_bytes: usize,
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
        Self::with_byte_budget(ttl, capacity, DEFAULT_MAX_BYTES, DEFAULT_MAX_ENTRY_BYTES)
    }

    /// 带上字节预算的构造(测试用得到小额度)。
    pub fn with_byte_budget(
        ttl: Duration,
        capacity: usize,
        max_bytes: usize,
        max_entry_bytes: usize,
    ) -> Self {
        Self {
            ttl,
            capacity: capacity.max(1),
            max_bytes: max_bytes.max(1),
            max_entry_bytes: max_entry_bytes.max(1),
            clock: AtomicU64::new(0),
            inner: Mutex::new(Inner {
                entries: HashMap::new(),
                bytes: 0,
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

    /// 当前累计字节(近似: 各条目 body 的估算大小之和)。
    pub fn bytes(&self) -> usize {
        self.lock().bytes
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
        let mut inner = self.lock();
        inner.entries.clear();
        inner.bytes = 0;
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn next_tick(&self) -> u64 {
        self.clock.fetch_add(1, Ordering::Relaxed)
    }

    /// 取缓存(命中会刷新 LRU 时间戳)。命中只 `Arc::clone`, **不深拷贝 body**。
    pub fn get(&self, key: &str) -> Option<Arc<Value>> {
        self.get_at(key, Instant::now())
    }

    fn get_at(&self, key: &str, now: Instant) -> Option<Arc<Value>> {
        let tick = self.next_tick();
        let mut inner = self.lock();
        let expired = {
            let entry = inner.entries.get(key)?;
            now.saturating_duration_since(entry.stored) >= self.ttl
        };
        if expired {
            if let Some(entry) = inner.entries.remove(key) {
                inner.bytes = inner.bytes.saturating_sub(entry.bytes);
            }
            return None;
        }
        let entry = inner.entries.get_mut(key)?;
        entry.used = tick;
        Some(Arc::clone(&entry.value))
    }

    /// 写入缓存(满了先按 LRU 淘汰)。
    pub fn store(&self, key: &str, value: Arc<Value>) {
        self.store_at(key, value, Instant::now());
    }

    fn store_at(&self, key: &str, value: Arc<Value>, now: Instant) {
        let bytes = approx_json_bytes(&value);
        // 单条就超预算: 不入缓存(否则一条大 body 会把整池挤空)
        if bytes > self.max_entry_bytes {
            return;
        }
        let tick = self.next_tick();
        let mut inner = self.lock();
        if let Some(old) = inner.entries.remove(key) {
            inner.bytes = inner.bytes.saturating_sub(old.bytes);
        }
        // 条数与字节都可能有压力: 一直淘汰到"再加进去也不超"
        while !inner.entries.is_empty()
            && (inner.entries.len() >= self.capacity || inner.bytes + bytes > self.max_bytes)
        {
            let Some(victim) = inner
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            if let Some(entry) = inner.entries.remove(&victim) {
                inner.bytes = inner.bytes.saturating_sub(entry.bytes);
            }
        }
        inner.bytes += bytes;
        inner.entries.insert(
            key.to_string(),
            Entry {
                value,
                bytes,
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
    ) -> ProviderResult<Arc<Value>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = ProviderResult<Value>>,
    {
        if !is_cacheable(endpoint) {
            // 不入缓存的接口: 照样要回 `Arc`(调用点只读 body), 只是不进池
            return load().await.map(Arc::new);
        }
        if let Some(hit) = self.get(key) {
            return Ok(hit);
        }
        // 同 key 单飞: 拿到这把锁的才是 leader, 其余在这里排队;
        // leader 写回缓存后它们醒来直接命中(所以锁内要再查一次)。
        let lock = self.inflight_lock(key);
        // 登记条目的摘除靠 Drop: leader 在 `load().await` 处被取消(Dart 侧 future 丢弃 /
        // 组件 dispose)时也会走到这里 —— 以前是语句式的 `release_inflight`, 取消路径直接跳过,
        // `inflight` 里留下永久条目且该 key 的单飞语义失效。
        let _inflight = InflightGuard {
            cache: self,
            key,
            lock: lock.clone(),
        };
        let guard = lock.lock().await;
        if let Some(hit) = self.get(key) {
            return Ok(hit);
        }
        let result = load().await;
        // 先放锁(_inflight 随函数结束才 drop), 后来者不会拿到一把已无人等的锁去排队
        drop(guard);
        match result {
            Ok(value) => {
                // 池里与返回值共用一个 `Arc`: 一次请求只搬一份 body(旧实现先 clone 存、
                // 再 clone 返回, 命中时又一次 clone —— 三次 MB 级复制, 审计 R1)
                let value = Arc::new(value);
                self.store(key, Arc::clone(&value));
                Ok(value)
            }
            Err(err) => Err(err),
        }
    }
}

/// 在飞登记条目的 RAII 守卫: 无论 leader 正常结束、报错还是被取消, 都摘掉 `inflight` 条目。
///
/// 对应 `ncm-plugin` 的 `CoalesceLeader`: 那个还多了"把等待者唤醒成可重试", 而本缓存
/// 的等待者只是排队拿同一把锁, leader 消失后它们会依次拿到锁并在锁内重查缓存(未命中就自己
/// 变 leader), 所以这里只需要收尾条目。
struct InflightGuard<'a> {
    cache: &'a ReadCache,
    key: &'a str,
    lock: Arc<tokio::sync::Mutex<()>>,
}

impl Drop for InflightGuard<'_> {
    fn drop(&mut self) {
        self.cache.release_inflight(self.key, &self.lock);
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
            endpoint::PLAYLIST_TRACK_ALL,
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
        cache.store_at("k", Arc::new(serde_json::json!({ "v": 1 })), now);
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
        cache.store("a", Arc::new(serde_json::json!(1)));
        cache.store("b", Arc::new(serde_json::json!(2)));
        // 摸一下 a: a 变成最近使用, 淘汰时该走 b
        assert!(cache.get("a").is_some());
        cache.store("c", Arc::new(serde_json::json!(3)));
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
        cache.store("a", Arc::new(serde_json::json!(1)));
        cache.store("b", Arc::new(serde_json::json!(2)));
        cache.clear();
        assert!(cache.is_empty());
    }

    /// R6 判据: leader 的 future 被取消(超时/drop)时, `inflight` 里的登记必须一起消失。
    /// 修复前是语句式清理(`release_inflight` 在 `load().await` 之后), 取消路径直接跳过。
    #[tokio::test]
    async fn cancelled_leader_releases_inflight_entry() {
        let cache = ReadCache::default();
        let key = cache_key(endpoint::CLOUDSEARCH, &[("keywords", "郑成河".into())]);
        let fut = cache.get_or_load(endpoint::CLOUDSEARCH, &key, || async {
            // 永不返回: 只能靠外部取消结束
            std::future::pending::<()>().await;
            Ok(serde_json::json!({}))
        });
        let timed_out = tokio::time::timeout(Duration::from_millis(50), fut).await;
        assert!(timed_out.is_err(), "load 不该在 50ms 内返回");
        assert!(
            cache.lock().inflight.is_empty(),
            "leader 被取消后 in-flight 登记必须摘掉(否则这个 key 的单飞永久失效)"
        );

        // 取消之后同 key 仍能正常走完(没被写坏的条目卡住)
        let ok = cache
            .get_or_load(endpoint::CLOUDSEARCH, &key, || async {
                Ok(serde_json::json!({ "n": 1 }))
            })
            .await
            .expect("取消后该 key 仍应可用");
        assert_eq!(ok["n"], 1);
        assert!(cache.lock().inflight.is_empty(), "正常结束后同样不留条目");
    }

    #[tokio::test]
    async fn hit_shares_the_body_arc_instead_of_deep_copying() {
        // 1000 首歌单的 body 是 1–3MB: 每次命中深拷贝一次是白白的 MB 级 alloc(审计 R1)
        let cache = ReadCache::default();
        let fetcher = Fetcher::default();
        let key = cache_key(endpoint::PLAYLIST_TRACK_ALL, &[("id", "1".into())]);
        let first = cache
            .get_or_load(endpoint::PLAYLIST_TRACK_ALL, &key, || fetcher.load("big"))
            .await
            .expect("load 应成功");
        let second = cache
            .get_or_load(endpoint::PLAYLIST_TRACK_ALL, &key, || fetcher.load("big"))
            .await
            .expect("命中应成功");
        assert_eq!(fetcher.calls(), 1);
        assert!(
            Arc::ptr_eq(&first, &second),
            "命中必须复用同一个 Arc, 不能深拷贝 body"
        );
    }

    #[test]
    fn byte_budget_evicts_lru_and_skips_oversized_entry() {
        let cache = ReadCache::with_byte_budget(Duration::from_secs(300), 100, 200, 150);
        let small = || Arc::new(serde_json::json!({ "k": "0123456789abcdef" }));
        cache.store("a", small());
        cache.store("b", small());
        let used = cache.bytes();
        assert!(used > 0, "字节账要真的记");

        // 继续塞, 直到超预算: 淘汰最久未用的 a
        for i in 0..40 {
            cache.store(&format!("n{i}"), small());
        }
        assert!(
            cache.bytes() <= 200,
            "总字节必须守住预算, 实际 {}",
            cache.bytes()
        );
        assert!(cache.get("a").is_none() || cache.len() < 40);

        // 单条超上限(>150 字节)不入池
        let huge = Arc::new(serde_json::json!({ "k": "x".repeat(400) }));
        let before = cache.len();
        cache.store("huge", huge);
        assert_eq!(cache.len(), before, "超大单条不该进缓存");
        assert!(cache.get("huge").is_none());
    }
}
