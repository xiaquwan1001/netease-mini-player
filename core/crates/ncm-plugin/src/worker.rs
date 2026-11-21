//! `ScriptProvider`: 把沙箱包装成产品既有的 `Provider` 实现(实验性, 未接入产品).
//!
//! 线程模型: 沙箱对象(`!Send`)活在一个专属 worker 线程里, 外层只留一个
//! `std::sync::mpsc::Sender`; 异步 `Provider` 方法经 `futures::channel::oneshot`
//! 把结果回传, 不阻塞调用方 executor.
//!
//! 为什么不是 tokio task: `ncm-provider` 不依赖任何 runtime, 这里也不引入;
//! `oneshot` 只是 future, 谁的 executor 都能 poll.

use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use futures::channel::oneshot;
use ncm_domain::{Lyric, SearchPage, StreamUrl, TrackId};
use ncm_provider::{
    AccountProvider, ArtistAlbumProvider, BoxFuture, Capability, CloudProvider, CommentProvider,
    CommunityProvider, LyricProvider, MessageProvider, PlaylistReadProvider, PlaylistWriteProvider,
    Provider, ProviderResult, RadioProvider, ReadProvider, RecommendProvider, SearchQuery,
    SongUrlRequest, VipProvider,
};
use serde_json::Value;

use crate::convert;
use crate::error::PluginError;
use crate::sandbox::{SandboxConfig, ScriptEngine};
use crate::storage::Storage;
use crate::transport::Transport;

/// 与 Melodia 的 `INIT_TIMEOUT_MS` 对齐.
const INIT_TIMEOUT: Duration = Duration::from_secs(8);
/// 宿主侧保留的日志条数上限(超出丢最旧的).
const MAX_RETAINED_LOGS: usize = 512;

/// 装载一个脚本插件所需的全部外部依赖(宿主注入).
pub struct PluginSpec {
    /// 插件显示名(同时是 `lx.storage` 的默认 namespace).
    pub name: String,
    /// 脚本文本(ES6+, 形态见 README「契约 v1」).
    pub source: String,
    pub config: SandboxConfig,
    pub transport: Arc<dyn Transport>,
    pub storage: Arc<dyn Storage>,
    /// 显式指定存储 namespace; 缺省用 `name`.
    pub namespace: Option<String>,
}

impl PluginSpec {
    pub fn new(
        name: impl Into<String>,
        source: impl Into<String>,
        transport: Arc<dyn Transport>,
        storage: Arc<dyn Storage>,
    ) -> Self {
        Self {
            name: name.into(),
            source: source.into(),
            config: SandboxConfig::default(),
            transport,
            storage,
            namespace: None,
        }
    }

    pub fn with_config(mut self, config: SandboxConfig) -> Self {
        self.config = config;
        self
    }

    pub fn with_namespace(mut self, namespace: impl Into<String>) -> Self {
        self.namespace = Some(namespace.into());
        self
    }
}

enum WorkerMsg {
    Invoke {
        event: String,
        args: Value,
        reply: oneshot::Sender<Result<Value, PluginError>>,
    },
    Shutdown,
}

/// 实验性音源 provider: 脚本经 QuickJS 沙箱提供 `songUrl` / `search`.
///
/// **未接入产品默认路径**(没有 FFI 导出口, 也没有注册进 `ProviderRegistry`);
/// 目的只是把"脚本能当 provider 用"这件事在 core 里跑通并锁住契约.
pub struct ScriptProvider {
    name: String,
    capabilities: &'static [Capability],
    /// 脚本经 `send('inited', {sources})` 声明的平台代号(装载期读一次, 之后不变).
    declared_sources: Vec<String>,
    tx: Sender<WorkerMsg>,
    logs: Arc<Mutex<Vec<String>>>,
}

impl ScriptProvider {
    /// 加载并初始化脚本(语法错误/初始化超时/sandbox 起不来都在这里报).
    pub fn load(spec: PluginSpec) -> Result<Self, PluginError> {
        let namespace = spec.namespace.clone().unwrap_or_else(|| spec.name.clone());
        let logs: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let logs_for_thread = logs.clone();
        type InitResult = Result<(Vec<String>, Vec<String>), PluginError>;
        let (init_tx, init_rx) = mpsc::channel::<InitResult>();
        let (tx, rx) = mpsc::channel::<WorkerMsg>();
        let thread_name = format!("ncm-plugin:{}", spec.name);

        thread::Builder::new()
            .name(thread_name)
            .spawn(move || {
                let engine = ScriptEngine::new(
                    &spec.source,
                    spec.config,
                    spec.transport,
                    spec.storage,
                    namespace,
                );
                let mut engine = match engine {
                    Ok(engine) => engine,
                    Err(err) => {
                        let _ = init_tx.send(Err(err));
                        return;
                    }
                };
                let handlers = engine.handlers().to_vec();
                let declared_sources = engine.declared_sources();
                drain_logs(&mut engine, &logs_for_thread);
                if init_tx.send(Ok((handlers, declared_sources))).is_err() {
                    return;
                }
                while let Ok(msg) = rx.recv() {
                    match msg {
                        WorkerMsg::Invoke { event, args, reply } => {
                            let result = engine.invoke(&event, args);
                            drain_logs(&mut engine, &logs_for_thread);
                            // 调用方可能已经放弃等待(超时/取消), 结果丢弃即可.
                            let _ = reply.send(result);
                        }
                        WorkerMsg::Shutdown => break,
                    }
                }
            })
            .map_err(|e| PluginError::load(format!("worker 线程创建失败: {e}")))?;

        let (handlers, declared_sources) = match init_rx.recv_timeout(INIT_TIMEOUT) {
            Ok(Ok((handlers, sources))) => (handlers, sources),
            Ok(Err(err)) => return Err(err),
            Err(_) => {
                return Err(PluginError::timeout(format!(
                    "插件初始化超过 {}s",
                    INIT_TIMEOUT.as_secs()
                )))
            }
        };

        Ok(Self {
            name: spec.name,
            capabilities: capabilities_for(&handlers),
            declared_sources,
            tx,
            logs,
        })
    }

    async fn invoke(&self, event: &str, args: Value) -> ProviderResult<Value> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send(WorkerMsg::Invoke {
                event: event.to_string(),
                args,
                reply: reply_tx,
            })
            .map_err(|_| PluginError::shutdown("插件 worker 已退出").to_provider_error())?;
        reply_rx
            .await
            .map_err(|_| PluginError::shutdown("插件 worker 未回传结果").to_provider_error())?
            .map_err(Into::into)
    }
}

fn drain_logs(engine: &mut ScriptEngine, sink: &Mutex<Vec<String>>) {
    let batch = engine.take_logs();
    if batch.is_empty() {
        return;
    }
    let mut guard = sink.lock().unwrap_or_else(|e| e.into_inner());
    guard.extend(batch);
    if guard.len() > MAX_RETAINED_LOGS {
        let overflow = guard.len() - MAX_RETAINED_LOGS;
        guard.drain(0..overflow);
    }
}

// 能力组合的静态表(返回 `&'static [Capability]`, 不每次分配).
const CAP_NONE: &[Capability] = &[];
const CAP_SONG: &[Capability] = &[Capability::SongUrl];
const CAP_SEARCH: &[Capability] = &[Capability::Search];
const CAP_LYRIC: &[Capability] = &[Capability::Lyric];
const CAP_SONG_SEARCH: &[Capability] = &[Capability::SongUrl, Capability::Search];
const CAP_SONG_LYRIC: &[Capability] = &[Capability::SongUrl, Capability::Lyric];
const CAP_SEARCH_LYRIC: &[Capability] = &[Capability::Search, Capability::Lyric];
const CAP_SONG_SEARCH_LYRIC: &[Capability] =
    &[Capability::SongUrl, Capability::Search, Capability::Lyric];

/// 能力声明完全由脚本注册了哪些事件决定(不信任脚本头部的自述).
///
/// 上游 LX 脚本只注册 `request`(单入口, action ∈ {musicUrl, lyric, pic}), prelude 会在
/// 宿主调 musicUrl / lyric 时翻译成 request 事件 —— 所以 `request` 同时声明取链与歌词能力.
/// 只注册 `request` 的脚本若对 lyric action 驳回, 路由层按 `Unsupported`/`Internal` 回落内置
/// (`route::call_routed` 的回落分支), 不会把插件失败暴露给用户.
///
/// 契约 v1 的宿主事件名(`musicUrl` / `lyric` / `search`)直接注册也算能力.
fn capabilities_for(handlers: &[String]) -> &'static [Capability] {
    let has = |name: &str| handlers.iter().any(|h| h == name);
    let request = has("request");
    let song = request || has("musicUrl");
    let lyric = request || has("lyric");
    let search = has("search");
    match (song, search, lyric) {
        (true, true, true) => CAP_SONG_SEARCH_LYRIC,
        (true, true, false) => CAP_SONG_SEARCH,
        (true, false, true) => CAP_SONG_LYRIC,
        (true, false, false) => CAP_SONG,
        (false, true, true) => CAP_SEARCH_LYRIC,
        (false, true, false) => CAP_SEARCH,
        (false, false, true) => CAP_LYRIC,
        (false, false, false) => CAP_NONE,
    }
}

/// 歌词请求的 `musicInfo`(`LyricProvider::lyric` 只有 trackId, 没有 Song 上下文).
///
/// 字段与 `songUrl` 对齐(id/name/singer/albumName/albumId/interval), 空上下文也把字段补齐,
/// 脚本不必判空; 真实 LX 歌词脚本几乎只读 `musicInfo.id`.
fn lyric_music_info(track: TrackId) -> Value {
    serde_json::json!({
        "id": track.0,
        "name": "",
        "singer": "",
        "albumName": "",
        "albumId": 0,
        "interval": 0,
    })
}

impl std::fmt::Debug for ScriptProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScriptProvider")
            .field("name", &self.name)
            .field("capabilities", &self.capabilities)
            .finish_non_exhaustive()
    }
}

impl Drop for ScriptProvider {
    fn drop(&mut self) {
        // 不 join: 若有一次调用正在跑, join 会把析构阻塞到超时预算结束.
        let _ = self.tx.send(WorkerMsg::Shutdown);
    }
}

impl Provider for ScriptProvider {
    fn id(&self) -> &'static str {
        "script"
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn capabilities(&self) -> &'static [Capability] {
        self.capabilities
    }

    fn declared_sources(&self) -> Vec<String> {
        self.declared_sources.clone()
    }

    /// 取走宿主累计的 `lx.log` / `console.*` 输出(取走语义; UI 走 `plugin_logs` 拉取).
    fn take_logs(&self) -> Vec<String> {
        let mut guard = self.logs.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *guard)
    }
}

impl ReadProvider for ScriptProvider {
    fn search<'a>(&'a self, query: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
        Box::pin(async move {
            let args = serde_json::json!([{
                "keywords": query.keywords,
                "limit": query.limit,
                "offset": query.offset,
            }]);
            let raw = self.invoke("search", args).await?;
            convert::search_page(&raw, query).map_err(Into::into)
        })
    }

    fn song_url<'a>(&'a self, req: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
        Box::pin(async move {
            let quality = convert::quality_to_lx(req.level);
            // musicInfo 的字段名对齐上游 LX 社区脚本(id 必须是数字 trackId;
            // songmid/hash 是 kw/kg/QQ 系的兼容键, 网易云曲目通常没有)。
            let meta = req.meta.as_ref();
            let mut music_info = serde_json::json!({
                "id": req.track.0,
                "name": meta.map(|m| m.name.clone()).unwrap_or_default(),
                "singer": meta.map(|m| m.singer.clone()).unwrap_or_default(),
                "albumName": meta.map(|m| m.album_name.clone()).unwrap_or_default(),
                "albumId": meta.map(|m| m.album_id).unwrap_or(0),
                "interval": meta.map(|m| m.interval).unwrap_or(0),
                "type": quality,
            });
            if let Some(song_mid) = meta.and_then(|m| m.song_mid.clone()) {
                if !song_mid.is_empty() {
                    // 上游脚本按 hash/songmid/id 依次兜底, 两个键同值即可.
                    music_info["songmid"] = serde_json::Value::String(song_mid.clone());
                    music_info["hash"] = serde_json::Value::String(song_mid);
                }
            }
            let args = serde_json::json!(["script", music_info, quality]);
            let raw = self.invoke("musicUrl", args).await?;
            convert::stream_url(&raw, req.level).map_err(Into::into)
        })
    }
}

// 其余能力域: 全部走 trait 默认实现(= unsupported). 这与产品口径一致:
// 能力声明(Capability)是路由依据, 脚本没注册的能力不该被调用.
impl AccountProvider for ScriptProvider {}
impl ArtistAlbumProvider for ScriptProvider {}
impl CloudProvider for ScriptProvider {}
impl CommentProvider for ScriptProvider {}
impl CommunityProvider for ScriptProvider {}
impl MessageProvider for ScriptProvider {}
impl PlaylistReadProvider for ScriptProvider {}
impl PlaylistWriteProvider for ScriptProvider {}
impl RadioProvider for ScriptProvider {}
impl RecommendProvider for ScriptProvider {}
impl VipProvider for ScriptProvider {}

impl LyricProvider for ScriptProvider {
    /// 歌词: 走与 `songUrl` 同一条 request 事件通路(上游形状
    /// `{source, action: 'lyric', info: {type: 'lyric', musicInfo}}`, prelude 负责拼).
    ///
    /// 失败口径: 脚本没注册 request/lyric ⇒ `Unsupported`(路由回落内置);
    /// 返回空 payload ⇒ 同样是 `Unsupported`; 脚本抛错/超时/预算 ⇒ 既有 `PluginError` 映射.
    fn lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>> {
        Box::pin(async move {
            let args = serde_json::json!(["script", lyric_music_info(track)]);
            let raw = self.invoke("lyric", args).await?;
            convert::lyric(&raw).map_err(Into::into)
        })
    }
}
