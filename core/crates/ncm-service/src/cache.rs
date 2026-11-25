//! 音频缓存: 直链有时效, 播完即缓存文件, 复播不再走网络.
//!
//! T2(2026-11-18) 三处加固, 都来自「香港用户卡顿」的归因矩阵(#4 #6 #7):
//! 1. **强制 https**: 明文 http 直链在校园网/运营商/跨境链路上会被中间设备换成一页
//!    HTML 重定向(本机实测). 桌面侧以前直接把上游给的 url 交给 reqwest, 这里统一
//!    升级成 https(只对网易域名族, 非网易域名不动 —— 第三方源将来可能只支持明文)。
//! 2. **下载器补全**: 以前 `reqwest::get` 没有 UA/Referer/超时, 也从不看 Content-Type;
//!    现在带官方 UA + Referer, 显式 connect/首包超时, 非 2xx 或首包是 text/html 一律
//!    判失败, 并映射成 `ProviderError{kind,retryable,detail}` 走既有错误通道。
//! 3. **失败重取一次**: 只有 `retryable` 的失败才重试, 且总共只多试一次(不无限重试)。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use ncm_provider::ProviderError;

/// 小于这个字节数的文件不可能是音频(直链被劫持成 HTML/空 body 时"下载成功"也只有几百字节).
///
/// 两处口径都靠它: ① 命中缓存(`cached_with_level`)与容量统计的门槛; ② 下载完判"够不够大".
const MIN_VALID_AUDIO_BYTES: u64 = 64 * 1024;

/// 桌面下载的 Referer: 与 Android 侧 `DefaultHttpDataSource` 的默认请求头保持一致.
pub const DOWNLOAD_REFERER: &str = "https://music.163.com/";
/// 建连上限(跨境链路上 TLS 握手可能慢, 但 10s 还没连上就是真的不通).
///
/// `pub(crate)`: 插件宿主的 `plugins::ReqwestTransport` 复用同一口径(见那里头注释).
pub(crate) const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
/// 读间隔上限(首包与后续每次读都受它约束): 20s 完全没有字节才算 stalled.
///
/// `pub(crate)`: 同上, 插件出站不另起一套超时数字.
pub(crate) const READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
/// 首包单独再压一道: 连上了但 CDN 迟迟不给 body(或被劫持成重定向页)时尽早失败
const FIRST_CHUNK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
/// 下载失败后重试的次数上限(总尝试 = 1 + 1).
///
/// `pub(crate)`: 插件出站的重试档位抄这一个数(`plugins::TRANSPORT_RETRIES`), 不另定.
pub(crate) const DOWNLOAD_RETRIES: u32 = 1;

pub struct AudioCache {
    dir: PathBuf,
}

// ---------------------------------------------------------------------------
// ① 明文 http → https(只对网易域名族)
// ---------------------------------------------------------------------------

/// 网易的域名族: 直链边缘(`m7/m701/m802.music.126.net` 等)与接口域(`*.music.163.com`).
///
/// 只认这两族是有意的: 非网易域名(将来的第三方源)不能替人家假设"一定有 https",
/// 强行改 scheme 只会把能播的源改坏。
pub fn is_netease_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    host == "126.net"
        || host.ends_with(".126.net")
        || host == "163.com"
        || host.ends_with(".163.com")
}

/// 把网易域名族的明文 http 直链升级成 https(纯函数, 可注入判定便于单测).
///
/// - 已经是 https / 非 http / 解析不了 ⇒ 原样返回;
/// - host 不被 `allow_host` 接受 ⇒ 原样返回;
/// - 显式 `:80` 端口会被去掉(https 的默认端口是 443, 留着 80 只会连错).
pub fn prefer_https_with<F>(url: &str, allow_host: F) -> String
where
    F: Fn(&str) -> bool,
{
    let Ok(mut parsed) = reqwest::Url::parse(url) else {
        return url.to_string();
    };
    if parsed.scheme() != "http" {
        return url.to_string();
    }
    let host = parsed.host_str().unwrap_or_default().to_ascii_lowercase();
    if host.is_empty() || !allow_host(&host) {
        return url.to_string();
    }
    // host 是 domain(None) 时 set_scheme 不会失败; 失败就说明这个 URL 形状我们没预料到
    if parsed.set_scheme("https").is_err() {
        return url.to_string();
    }
    if parsed.port() == Some(80) {
        let _ = parsed.set_port(None);
    }
    parsed.to_string()
}

/// 生产口径的 https 升级(只动网易域名族).
pub fn prefer_https(url: &str) -> String {
    prefer_https_with(url, is_netease_host)
}

// ---------------------------------------------------------------------------
// ② 下载失败分类(纯函数, 不联网即可单测)
// ---------------------------------------------------------------------------

/// 一次 HTTP 取流在"拿到响应头"阶段的失败。
///
/// 为什么要单独建模: 桌面以前的错误只有 `"http 403"` 或一句 reqwest 的
/// `"error sending request"`, 无从判断该重试、该重新取链、还是该报给用户。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DownloadFailure {
    /// 非 2xx
    HttpStatus(u16),
    /// 2xx 但 body 是 HTML ⇒ 明文 http 被中间设备劫持/重定向页
    Hijacked {
        content_type: String,
        server: Option<String>,
    },
    /// 下完了但字节数小到不可能是音频
    TooSmall(u64),
}

impl DownloadFailure {
    /// 值不值得再试一次(重试链只认这一个判据)
    pub fn retryable(&self) -> bool {
        match self {
            // 401/403/404 是"这个直链已经不能用了", 原样重试没有意义(要重取链, 那是上层的事)
            DownloadFailure::HttpStatus(code) => !matches!(code, 401 | 403 | 404),
            DownloadFailure::Hijacked { .. } => true,
            DownloadFailure::TooSmall(_) => false,
        }
    }

    /// 收口到既有错误模型: UI 按 `kind` 决策, `detail` 是给人看的一句话。
    pub fn to_provider_error(&self) -> ProviderError {
        match self {
            DownloadFailure::HttpStatus(code) => match code {
                401 | 403 => ProviderError::forbidden(format!(
                    "CDN 拒绝下载(http {code}): 直链可能已过期, 需要重新取链"
                )),
                404 => {
                    ProviderError::not_found("CDN 上没有这个文件(http 404), 直链已失效".to_string())
                }
                other => ProviderError::network(format!("下载失败: http {other}")),
            },
            DownloadFailure::Hijacked {
                content_type,
                server,
            } => ProviderError::network(format!(
                "下载被中间设备劫持: 首包是 {content_type}{}",
                server
                    .as_deref()
                    .map(|s| format!("(Server: {s})"))
                    .unwrap_or_default()
            )),
            DownloadFailure::TooSmall(n) => {
                ProviderError::internal(format!("音频文件异常: 只有 {n} 字节"))
            }
        }
    }
}

/// 判一次响应能不能当音频用(状态码 + Content-Type).
///
/// 注意: 只认 **2xx**; 3xx 不跟随(直链被重定向基本等于被劫持), 统一按非 2xx 处理。
pub fn classify_http(
    status: u16,
    content_type: Option<&str>,
    server: Option<&str>,
) -> Result<(), DownloadFailure> {
    if !(200..300).contains(&status) {
        return Err(DownloadFailure::HttpStatus(status));
    }
    let ct = content_type.unwrap_or_default().to_ascii_lowercase();
    if ct.starts_with("text/html") || ct.starts_with("application/xhtml") {
        return Err(DownloadFailure::Hijacked {
            content_type: content_type.unwrap_or_default().to_string(),
            server: server.map(str::to_string),
        });
    }
    Ok(())
}

/// 下载被取消的收口(见 [`AudioCache::download_progressive_cancellable`]):
/// 不可重试, `kind` 用 internal —— 这不是网络故障, 用户刚切了歌而已.
fn cancelled_error() -> (ProviderError, bool) {
    (
        ProviderError::internal("下载已取消: 已经切到别的歌曲"),
        false,
    )
}

/// 下载客户端(单例): UA 与取链共用一套身份口径, 不自己编字符串。
///
/// 只缓存**成功**值: 以前是 `OnceLock<Result<Client, String>>`, 首次构建失败会被永久
/// 钉住 —— 之后每次下载都返回同一个错误, 进程重启前不可恢复。现在失败即返回、下次再试。
fn http_client() -> Result<&'static reqwest::Client, ProviderError> {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client);
    }
    let built = reqwest::Client::builder()
        .user_agent(crate::identity::platform_profile().ua)
        .connect_timeout(CONNECT_TIMEOUT)
        .read_timeout(READ_TIMEOUT)
        .build()
        .map_err(|e| ProviderError::internal(format!("创建下载客户端失败: {e}")))?;
    // 并发首次构建: 谁先 set 谁赢, 输的那个直接丢掉(两者等价), 不需要额外锁
    let _ = CLIENT.set(built);
    CLIENT
        .get()
        .ok_or_else(|| ProviderError::internal("创建下载客户端失败: 单例未就绪"))
}

// ---------------------------------------------------------------------------
// 缓存键: 最近一次取链用的音质(进程内旁路)
// ---------------------------------------------------------------------------

/// 取链音质提示: `song_url` 成功时记一条, `play_track` 用它给缓存键打标。
///
/// 为什么用旁路而不是加参数: `play_track` 是 FFI 导出, 签名变更要动 codegen
/// (另一车道正在改 FFI), 而缓存键只需要"最近一次这条曲子按什么音质取的链"。
/// 容量有上限, 超出直接清空 —— 这只是一条提示, 丢了就退回旧键, 不影响正确性。
pub fn remember_level(track_id: u64, level: &str) {
    let map = level_hints();
    if let Ok(mut map) = map.lock() {
        if map.len() >= LEVEL_HINT_CAPACITY {
            map.clear();
        }
        map.insert(track_id, level.to_string());
    }
}

/// 取这条曲子最近一次取链用的音质(没有记录 ⇒ None, 缓存键退回旧格式)
pub fn level_hint(track_id: u64) -> Option<String> {
    level_hints()
        .lock()
        .ok()
        .and_then(|m| m.get(&track_id).cloned())
}

const LEVEL_HINT_CAPACITY: usize = 512;

fn level_hints() -> &'static std::sync::Mutex<std::collections::HashMap<u64, String>> {
    static HINTS: OnceLock<std::sync::Mutex<std::collections::HashMap<u64, String>>> =
        OnceLock::new();
    HINTS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

impl AudioCache {
    pub fn open(dir: &Path) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        Ok(Self {
            dir: dir.to_path_buf(),
        })
    }

    /// 直链的容器后缀(`.flac`/`.m4a`/`.mp3`), 只用来选扩展名.
    fn ext_for(url: &str) -> &'static str {
        if url.contains(".flac") {
            "flac"
        } else if url.contains(".m4a") {
            "m4a"
        } else {
            "mp3"
        }
    }

    /// 旧键(全局唯一, 不含音质): `{track_id}.{ext}`。
    ///
    /// 仍保留是因为**旧缓存文件必须能被命中**(不做一次性清缓存)。新写入一律走
    /// [`Self::path_for_level`], 旧文件随着淘汰/重下自然消失。
    pub fn legacy_path_for(&self, track_id: u64, url: &str) -> PathBuf {
        self.dir.join(format!("{track_id}.{}", Self::ext_for(url)))
    }

    /// 带音质的缓存键: `{track_id}.{level}.{ext}`。
    ///
    /// 为什么必须带音质: 旧键下换档(标准 → 极高 → 无损)会命中**别的码率**的文件,
    /// 表现是"改音质没变化"或"卡"(文件大小/位率与当前解码假设不符)。
    /// `level` 为 None(进程内没记录取链音质 / 旧调用点)时退回旧键。
    ///
    /// 注: 暂不含 `source`(目前只有网易一个 provider, 路由 `first_with` 取第一个);
    /// 真接入第二来源时把 source_tag 追加进这个函数即可。
    pub fn path_for_level(&self, track_id: u64, url: &str, level: Option<&str>) -> PathBuf {
        match level.map(str::trim).filter(|l| !l.is_empty()) {
            Some(level) => self
                .dir
                .join(format!("{track_id}.{level}.{}", Self::ext_for(url))),
            None => self.legacy_path_for(track_id, url),
        }
    }

    /// 旧接口: 不带音质(等价于 `path_for_level(.., None)`)
    pub fn path_for(&self, track_id: u64, url: &str) -> PathBuf {
        self.legacy_path_for(track_id, url)
    }

    /// 命中缓存: **先试新键, 再回退旧键**(向后兼容, 迁移期两者都可能存在).
    ///
    /// 回退旧键的已知代价(可接受, 写在这里避免以后当 bug 查): 旧文件不带音质,
    /// 所以迁移期**换档后第一次**仍可能命中旧的码率文件; 一旦这条曲子被淘汰/重下,
    /// 写出的就是带音质的新键, 之后就不会再串。要立刻杜绝只能一次性清缓存,
    /// 那与"不做一次性清缓存"的验收口径冲突, 所以选择兼容优先 + 打一条日志。
    pub fn cached_with_level(
        &self,
        track_id: u64,
        url: &str,
        level: Option<&str>,
    ) -> Option<PathBuf> {
        let tagged = self.path_for_level(track_id, url, level);
        let legacy = self.legacy_path_for(track_id, url);
        let tagged_hit = std::fs::metadata(&tagged)
            .ok()
            .filter(|m| m.len() >= MIN_VALID_AUDIO_BYTES)
            .map(|_| tagged.clone());
        if tagged_hit.is_some() || tagged == legacy {
            return tagged_hit;
        }
        let legacy_hit = std::fs::metadata(&legacy)
            .ok()
            .filter(|m| m.len() >= MIN_VALID_AUDIO_BYTES)
            .map(|_| legacy.clone());
        if legacy_hit.is_some() && level.is_some() {
            eprintln!(
                "[cache] hit legacy key {} (no level tag); 可能不是当前音质, 淘汰后会写成新键",
                legacy.display()
            );
        }
        legacy_hit
    }

    pub fn cached(&self, track_id: u64, url: &str) -> Option<PathBuf> {
        self.cached_with_level(track_id, url, None)
    }

    /// 建出(或清空)下载用的 `.part`.
    ///
    /// 为什么要单独一步: 真正写数据的那侧是 `write + truncate`(**不** `create`), 文件必须
    /// 由这里先建出来。边下边播由 [`Self::start_progressive`] 建, 前台下载 [`Self::fetch`]
    /// 以前**没人建** ⇒ 每次都在开文件那步 ENOENT(`os error 2`), Windows 桌面
    /// (下完再播)与 `ncm-cli play` 都走那条路。残片也要先清, 否则会从旧数据接着解码。
    fn prepare_part(part: &Path) -> Result<(), ProviderError> {
        let _ = std::fs::remove_file(part);
        std::fs::File::create(part)
            .map_err(|e| ProviderError::internal(format!("创建缓存临时文件失败: {e}")))?;
        Ok(())
    }

    /// 准备"边下边播": 清掉旧 `.part`、创建空文件, 立刻返回可读路径。
    ///
    /// 真正的字节由 [`Self::download_progressive`] 在后台写入。
    /// 先创建空文件是必须的: 播放线程可能在第一个字节到达前就 open。
    /// `level` 参与键(见 [`Self::path_for_level`]).
    ///
    /// **同 key(`final_path` 相同)单飞**: 已经有在飞下载时不再 `remove`/`create` 同一个
    /// `.part`(那会把正在写、正在读的 inode 摘掉, 第二个下载再从 0 写同一个路径 ⇒
    /// 字节交错 / rename 之一 ENOENT / 听到一半变成乱码)。后到者拿到的句柄
    /// `leader == false`, 与领跑者共享**同一个** `part_path` / `done`, 只播不下载。
    pub fn start_progressive(
        &self,
        track_id: u64,
        url: &str,
        level: Option<&str>,
    ) -> Result<ProgressiveFetch, ProviderError> {
        let final_path = self.path_for_level(track_id, url, level);
        let part_path = final_path.with_extension("part");
        let mut table = inflight_progressive()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(existing) = table.get(&final_path) {
            if !existing.done.load(Ordering::Acquire) {
                // 复用领跑者的句柄: 路径与 `done` 都是同一份, 不碰磁盘
                return Ok(ProgressiveFetch {
                    leader: false,
                    ..existing.clone()
                });
            }
            // 已收尾(成功/失败)但条目还没来得及摘 ⇒ 当没有
            table.remove(&final_path);
        }
        Self::prepare_part(&part_path)?;
        let fetch = ProgressiveFetch {
            part_path,
            final_path: final_path.clone(),
            done: Arc::new(AtomicBool::new(false)),
            leader: true,
        };
        table.insert(final_path, fetch.clone());
        Ok(fetch)
    }

    /// 流式下载到 `.part`, 完成后原子 rename 成正式缓存文件。
    ///
    /// 无论成功失败都置位 `done`(由 [`ProgressiveLeader`] 的 Drop 兑现): 失败时删掉残片,
    /// 播放线程立刻结束阻塞而不是挂死。
    pub async fn download_progressive(
        &self,
        url: &str,
        fetch: ProgressiveFetch,
    ) -> Result<PathBuf, ProviderError> {
        self.download_progressive_cancellable(url, fetch, &|| false)
            .await
    }

    /// 同 [`Self::download_progressive`], 但每写一块前问一次 `cancelled`。
    ///
    /// 取消的语义是"这次起播已经被后来的取代"(FFI 侧用下载代际实现): 立刻停下,
    /// 删残片、置 `done`、返回不可重试的错误 —— 不把已取消的下载算成网络故障。
    /// 只有**领跑者**(`fetch.leader`)能调本函数: 复用者再下一遍会二次截断同一个 `.part`。
    pub async fn download_progressive_cancellable(
        &self,
        url: &str,
        fetch: ProgressiveFetch,
        cancelled: &(dyn Fn() -> bool + Send + Sync),
    ) -> Result<PathBuf, ProviderError> {
        if !fetch.leader {
            return Err(ProviderError::internal(
                "同一首歌的下载已在进行中, 复用者不得再下载一份",
            ));
        }
        // 无论正常结束、报错还是被取消/abort, 都要置 done + 摘单飞表
        let _leader = ProgressiveLeader {
            final_path: fetch.final_path.clone(),
            done: Arc::clone(&fetch.done),
        };
        let result = Self::stream_to_part_with_retry(url, &fetch.part_path, cancelled).await;
        // 注意: 此时播放线程**正开着** .part。Linux/macOS 允许 rename 打开中的文件;
        // Windows 不允许, 所以桌面 Windows 仍走"下完再播"的旧通道(见 ncm-ffi)。
        Self::finish_part(&fetch.part_path, &fetch.final_path, result)
    }

    /// `.part` 收尾(两条下载路径共用, 口径必须一致):
    /// 够大 ⇒ rename 成正式缓存文件; 太小/失败 ⇒ 删残片并报错。
    fn finish_part(
        part: &Path,
        final_path: &Path,
        result: Result<u64, ProviderError>,
    ) -> Result<PathBuf, ProviderError> {
        match result {
            Ok(size) if size >= MIN_VALID_AUDIO_BYTES => std::fs::rename(part, final_path)
                .map(|()| final_path.to_path_buf())
                .map_err(|e| ProviderError::internal(format!("缓存落盘失败: {e}"))),
            Ok(size) => {
                let _ = std::fs::remove_file(part);
                Err(DownloadFailure::TooSmall(size).to_provider_error())
            }
            Err(e) => {
                let _ = std::fs::remove_file(part);
                Err(e)
            }
        }
    }

    /// 下载失败重试一次(只重试 `retryable` 的失败).
    ///
    /// 为什么不无限重试: 直链失效(401/403/404)重试只会多打一次上游并放大风控;
    /// 真正需要"再来一次"的是被劫持(HTML 首包)/瞬时 5xx/首包超时这类抖动。
    async fn stream_to_part_with_retry(
        url: &str,
        part: &Path,
        cancelled: &(dyn Fn() -> bool + Send + Sync),
    ) -> Result<u64, ProviderError> {
        let mut last: Option<ProviderError> = None;
        for attempt in 0..=DOWNLOAD_RETRIES {
            match Self::stream_to_part(url, part, cancelled).await {
                Ok(size) => return Ok(size),
                Err((err, retryable)) => {
                    // 取消不是故障, 不重试
                    if attempt < DOWNLOAD_RETRIES && retryable && !cancelled() {
                        eprintln!(
                            "[cache] download attempt {} failed, retrying: {err}",
                            attempt + 1
                        );
                        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                        last = Some(err);
                        continue;
                    }
                    return Err(err);
                }
            }
        }
        Err(last.unwrap_or_else(|| ProviderError::network("下载失败: 未知原因")))
    }

    /// 按块把响应体写进本地文件(每块都 flush: 播放线程按文件长度感知"有新数据")).
    ///
    /// 返回 `(错误, 是否可重试)`: 可重试与否在 [`DownloadFailure::retryable`] 里定,
    /// 传输层错误(reqwest)一律视为可重试 —— 它们几乎都是瞬时抖动。
    /// `cancelled` 每块之前问一次(见 [`AudioCache::download_progressive_cancellable`]).
    #[allow(clippy::type_complexity)]
    async fn stream_to_part(
        url: &str,
        part: &Path,
        cancelled: &(dyn Fn() -> bool + Send + Sync),
    ) -> Result<u64, (ProviderError, bool)> {
        use futures::StreamExt;
        use std::io::Write;
        // 建连之前先看一眼: 已经过期就别握手(连点 10 首不该是 10 次 TLS)
        if cancelled() {
            return Err(cancelled_error());
        }
        let client = http_client().map_err(|e| (e, false))?;
        // 兜底再升一次 https: 调用方可能直接传了上游给的明文直链(桌面旧路径)
        let url = prefer_https(url);
        let resp = client
            .get(&url)
            .header(reqwest::header::REFERER, DOWNLOAD_REFERER)
            .send()
            .await
            .map_err(|e| (ProviderError::network(format!("下载请求失败: {e}")), true))?;
        let status = resp.status().as_u16();
        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let server = resp
            .headers()
            .get("server")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        if let Err(failure) = classify_http(status, content_type.as_deref(), server.as_deref()) {
            return Err((failure.to_provider_error(), failure.retryable()));
        }
        // 每块之前问一次取消: 响应头到手后到首包之间也可能已经过期
        if cancelled() {
            return Err(cancelled_error());
        }
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(part)
            .map_err(|e| {
                (
                    ProviderError::internal(format!("缓存文件写入失败: {e}")),
                    false,
                )
            })?;
        let mut stream = resp.bytes_stream();
        // 首包单独限时: 连上了但 CDN 迟迟不给 body(或被劫持成"等跳转"页)时尽早失败
        let first = match tokio::time::timeout(FIRST_CHUNK_TIMEOUT, stream.next()).await {
            Err(_) => {
                return Err((
                    ProviderError::network(format!(
                        "首包超时({}s 没有收到任何音频字节): 直链无响应或被劫持",
                        FIRST_CHUNK_TIMEOUT.as_secs()
                    )),
                    true,
                ))
            }
            Ok(None) => None,
            Ok(Some(chunk)) => match chunk {
                Ok(chunk) => Some(chunk),
                Err(e) => return Err((ProviderError::network(format!("读取首包失败: {e}")), true)),
            },
        };
        let mut total = 0u64;
        if let Some(chunk) = first {
            file.write_all(&chunk).map_err(|e| {
                (
                    ProviderError::internal(format!("缓存文件写入失败: {e}")),
                    false,
                )
            })?;
            file.flush().map_err(|e| {
                (
                    ProviderError::internal(format!("缓存文件写入失败: {e}")),
                    false,
                )
            })?;
            total += chunk.len() as u64;
        }
        while let Some(chunk) = stream.next().await {
            if cancelled() {
                return Err(cancelled_error());
            }
            let chunk = chunk.map_err(|e| {
                (
                    ProviderError::network(format!(
                        "下载中断(超过 {READ_TIMEOUT:?} 没有新字节): {e}"
                    )),
                    true,
                )
            })?;
            file.write_all(&chunk).map_err(|e| {
                (
                    ProviderError::internal(format!("缓存文件写入失败: {e}")),
                    false,
                )
            })?;
            file.flush().map_err(|e| {
                (
                    ProviderError::internal(format!("缓存文件写入失败: {e}")),
                    false,
                )
            })?;
            total += chunk.len() as u64;
        }
        Ok(total)
    }

    /// 下载到临时文件后原子改名; 已存在则直接返回.
    ///
    /// 失败原因按 `ProviderError{kind,retryable,detail}` 回传(FFI 侧直接转 `FfiError`),
    /// 不再是一句 `"http 403"`。`level` 参与缓存键(见 [`Self::path_for_level`])。
    ///
    /// 重试/收尾与边下边播走同一条链(`stream_to_part_with_retry` + `finish_part`):
    /// 以前这里是内联的重试循环, 且**失败路径不删 `.part`** ⇒ 下次播放会从一个
    /// 残缺文件接着解码(听起来是一上来就没声音/杂音), 且它会被当成缓存残片一直占着磁盘.
    pub async fn fetch(
        &self,
        track_id: u64,
        url: &str,
        level: Option<&str>,
    ) -> Result<PathBuf, ProviderError> {
        if let Some(p) = self.cached_with_level(track_id, url, level) {
            return Ok(p);
        }
        let final_path = self.path_for_level(track_id, url, level);
        let part = final_path.with_extension("part");
        // `.part` 必须先建出来: 写数据那侧是 `write + truncate`(不 create), 见 [`Self::prepare_part`]
        Self::prepare_part(&part)?;
        // 前台路径(等下载完才播)没有取消语义: Windows 侧本次播放就在等它
        let result = Self::stream_to_part_with_retry(url, &part, &|| false).await;
        Self::finish_part(&part, &final_path, result)
    }
}

/// 边下边播的句柄.
///
/// [`Self::part_path`] 是**会持续增长的临时文件**: 播放器一开始就 open 它,
/// 读到"暂时没有新字节"时阻塞等待; 下载结束后 [`Self::done`] 置位, 读取才返回 EOF。
/// 全部下完再原子 rename 成正式缓存文件(下次直接命中 [`AudioCache::cached_path`])。
#[derive(Clone)]
pub struct ProgressiveFetch {
    /// 播放器读取的临时文件(增长中)
    pub part_path: PathBuf,
    /// 下载完成后的正式缓存路径
    pub final_path: PathBuf,
    /// 不会再产生新字节了(成功/失败都会置位, 否则播放线程永远阻塞)
    pub done: Arc<AtomicBool>,
    /// 本次调用是否是**领跑者**: true 才由调用方送去 [`AudioCache::download_progressive`];
    /// false = 复用了同一个 `.part` 在飞下载(只播不下载, 否则会把同一个文件截断重写)
    pub leader: bool,
}

/// 同 key(同一个 `final_path`: 同 track + 同音质)在飞下载的单飞表.
///
/// 为什么必须单飞: 第二个 `play_track` 若再 `remove_file(.part)` + `create`, 就会把第一个
/// 下载正在写、播放线程正在读的 inode 摘掉, 然后两个下载各自 `truncate(true)` 同一个路径
/// 从 0 写 —— 字节交错、rename 之一 ENOENT、听感上"播到一半变成乱码"。
///
/// 条目只在**下载期间**存在: 领跑者收尾时摘掉(见 [`ProgressiveLeader`]).
fn inflight_progressive() -> &'static Mutex<HashMap<PathBuf, ProgressiveFetch>> {
    static TABLE: OnceLock<Mutex<HashMap<PathBuf, ProgressiveFetch>>> = OnceLock::new();
    TABLE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 领跑下载的收尾守卫: 正常结束、报错、以及被取消/drop 三种路径都必须
/// ① 置位 `done`(否则播放线程会一直阻塞等新字节, 直到 stall 上限才收尾),
/// ② 摘掉单飞表里这条(否则同 key 后来的调用会复用一个已经死掉的"在飞下载").
struct ProgressiveLeader {
    final_path: PathBuf,
    done: Arc<AtomicBool>,
}

impl Drop for ProgressiveLeader {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Release);
        let mut table = inflight_progressive()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        table.remove(&self.final_path);
    }
}

/// 一次容量收敛的结果(R5: 缓存占用上限)
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CacheEviction {
    /// 删掉的文件数
    pub removed: usize,
    /// 释放的字节数
    pub freed_bytes: u64,
    /// 收敛后的总占用
    pub total_bytes: u64,
}

impl AudioCache {
    /// 缓存目录里的一次扫描: (路径, 大小, 修改时间).
    ///
    /// - `include_partial == false`(命中/统计口径): 只算已完成文件, 下载中的 `.part` 与
    ///   小于 [`MIN_VALID_AUDIO_BYTES`] 的残片不算 —— 它们不可能是能播的完整音频。
    /// - `include_partial == true`(配额口径): `.part` 也算。下载中的数据同样是磁盘占用,
    ///   以前把它们全部豁免, 连点切歌时几百 MB 在飞下载等于完全不进配额。
    fn entries(&self, include_partial: bool) -> Vec<(PathBuf, u64, std::time::SystemTime)> {
        let mut out = Vec::new();
        let Ok(dir) = std::fs::read_dir(&self.dir) else {
            return out;
        };
        for entry in dir.flatten() {
            let path = entry.path();
            let partial = path.extension().and_then(|e| e.to_str()) == Some("part");
            if partial && !include_partial {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            if !meta.is_file() || (!partial && meta.len() < MIN_VALID_AUDIO_BYTES) {
                continue;
            }
            let mtime = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
            out.push((path, meta.len(), mtime));
        }
        out
    }

    /// 不看直链, 直接按曲目 id 找已缓存文件(响度测量等后台任务用)
    pub fn cached_path(&self, track_id: u64) -> Option<PathBuf> {
        let prefix = format!("{track_id}.");
        self.entries(false)
            .into_iter()
            .find(|(p, _, _)| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.starts_with(prefix.as_str()))
                    .unwrap_or(false)
            })
            .map(|(p, _, _)| p)
    }

    /// 已完成缓存文件的数量(不含 .part)
    pub fn file_count(&self) -> usize {
        self.entries(false).len()
    }

    /// 当前缓存总占用(字节, 不含 .part)
    pub fn total_bytes(&self) -> u64 {
        self.entries(false).iter().map(|(_, size, _)| *size).sum()
    }

    /// 按「最久未修改优先」淘汰, 直到总占用 <= limit_bytes。
    ///
    /// - `limit_bytes == 0` 表示不限制(直接返回当前占用)。
    /// - `keep_track_id`: 正在播放的曲目对应的文件**永不删除**(R5 的验收口径)。
    /// - 统计口径含 `.part`(下载中的字节也是磁盘占用); 小于 [`MIN_VALID_AUDIO_BYTES`]
    ///   的已完成残片不参与统计/删除。
    /// - 淘汰一条正在写的 `.part` 会让那次下载最后的 rename 报 ENOENT(错误会回给调用方,
    ///   不会变成半个正式文件) —— 这是有意的: 磁盘满了优先保旧的可播文件。
    pub fn enforce_limit(
        &self,
        limit_bytes: u64,
        keep_track_id: Option<u64>,
    ) -> Result<CacheEviction, String> {
        let mut entries = self.entries(true);
        let mut total: u64 = entries.iter().map(|(_, size, _)| *size).sum();
        if limit_bytes == 0 || total <= limit_bytes {
            return Ok(CacheEviction {
                removed: 0,
                freed_bytes: 0,
                total_bytes: total,
            });
        }
        entries.sort_by_key(|(_, _, mtime)| *mtime);

        let keep_prefix = keep_track_id.map(|id| format!("{id}."));
        let mut removed = 0usize;
        let mut freed = 0u64;
        for (path, size, _) in entries {
            if total <= limit_bytes {
                break;
            }
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if let Some(prefix) = &keep_prefix {
                if name.starts_with(prefix.as_str()) {
                    continue; // 正在播放的文件不动
                }
            }
            match std::fs::remove_file(&path) {
                Ok(()) => {
                    removed += 1;
                    freed += size;
                    total = total.saturating_sub(size);
                }
                // 删不掉(被占用/权限)就跳过, 不要把整个流程打断
                Err(e) => eprintln!("[cache] evict {} failed: {e}", path.display()),
            }
        }
        Ok(CacheEviction {
            removed,
            freed_bytes: freed,
            total_bytes: total,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "ncm-cache-test-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    const KIB: usize = 1024;
    /// 让文件大于 64 KiB 的门槛
    fn write_track(dir: &Path, name: &str, kib: usize) {
        std::fs::write(dir.join(name), vec![0u8; kib * KIB]).unwrap();
    }

    /// 逐个文件设置 mtime, 用相对顺序模拟"最久未使用"
    fn touch(dir: &Path, name: &str, secs_ago: u64) {
        let path = dir.join(name);
        let t = std::time::SystemTime::now() - std::time::Duration::from_secs(secs_ago);
        let f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
        f.set_modified(t).unwrap();
    }

    #[test]
    fn total_bytes_ignores_partial_files() {
        let tmp = TempDir::new("total");
        write_track(&tmp.0, "1.mp3", 100);
        write_track(&tmp.0, "2.mp3.part", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();
        assert_eq!(cache.total_bytes(), 100 * 1024);
    }

    #[test]
    fn enforce_limit_evicts_oldest_first() {
        let tmp = TempDir::new("evict");
        write_track(&tmp.0, "1.mp3", 100);
        write_track(&tmp.0, "2.mp3", 100);
        write_track(&tmp.0, "3.mp3", 100);
        touch(&tmp.0, "1.mp3", 300);
        touch(&tmp.0, "2.mp3", 200);
        touch(&tmp.0, "3.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();

        // 上限 250 KiB: 必须删掉最老的 1.mp3, 剩 200 KiB
        let r = cache.enforce_limit(250 * 1024, None).unwrap();
        assert_eq!(r.removed, 1);
        assert_eq!(r.total_bytes, 200 * 1024);
        assert!(!tmp.0.join("1.mp3").exists());
        assert!(tmp.0.join("2.mp3").exists() && tmp.0.join("3.mp3").exists());
    }

    #[test]
    fn enforce_limit_never_deletes_currently_playing_track() {
        let tmp = TempDir::new("keep");
        write_track(&tmp.0, "7.mp3", 100);
        write_track(&tmp.0, "8.mp3", 100);
        touch(&tmp.0, "7.mp3", 500); // 7 最老, 但它正在播
        touch(&tmp.0, "8.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();

        let r = cache.enforce_limit(150 * 1024, Some(7)).unwrap();
        assert!(tmp.0.join("7.mp3").exists(), "正在播放的文件不能被淘汰");
        assert!(!tmp.0.join("8.mp3").exists());
        assert_eq!(r.removed, 1);
        assert_eq!(r.total_bytes, 100 * 1024);
    }

    #[test]
    fn under_limit_is_noop() {
        let tmp = TempDir::new("noop");
        write_track(&tmp.0, "1.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();
        let r = cache.enforce_limit(10 * 1024 * 1024, None).unwrap();
        assert_eq!(r.removed, 0);
        assert_eq!(r.freed_bytes, 0);
    }

    #[test]
    fn zero_limit_means_unlimited() {
        let tmp = TempDir::new("zero");
        write_track(&tmp.0, "1.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();
        let r = cache.enforce_limit(0, None).unwrap();
        assert_eq!(r.removed, 0);
        assert!(tmp.0.join("1.mp3").exists());
    }

    // ---------------- T2: 强制 https ----------------

    #[test]
    fn prefer_https_upgrades_netease_http_only() {
        // http → https, 保留 host/path/query
        assert_eq!(
            prefer_https("http://m701.music.126.net/2026/x/a.mp3?vuutv=abc+def/ghi="),
            "https://m701.music.126.net/2026/x/a.mp3?vuutv=abc+def/ghi="
        );
        // 已经是 https 不动
        let https = "https://m801.music.126.net/1/a.flac?x=1";
        assert_eq!(prefer_https(https), https);
        // 显式 :80 要去掉(https 不该连 80)
        assert_eq!(
            prefer_https("http://m7.music.126.net:80/a.mp3"),
            "https://m7.music.126.net/a.mp3"
        );
        // 非 163/126 域不强行改(第三方源可能只有明文)
        let third = "http://cdn.example.com/a.mp3";
        assert_eq!(prefer_https(third), third);
        // 不可解析/非 http 原样返回
        assert_eq!(prefer_https("not a url"), "not a url");
        assert_eq!(
            prefer_https("ftp://m7.music.126.net/a.mp3"),
            "ftp://m7.music.126.net/a.mp3"
        );
    }

    #[test]
    fn prefer_https_host_predicate_is_injectable() {
        // 注入"只认 example.com"的判定: 网易域不动, example.com 会被升级
        let allow = |h: &str| h.ends_with("example.com");
        assert_eq!(
            prefer_https_with("http://m7.music.126.net/a.mp3", allow),
            "http://m7.music.126.net/a.mp3"
        );
        let allow2 = |h: &str| h.ends_with("example.com");
        assert_eq!(
            prefer_https_with("http://cdn.example.com/a.mp3", allow2),
            "https://cdn.example.com/a.mp3"
        );
    }

    // ---------------- T2: 下载失败分类(不联网) ----------------

    #[test]
    fn classify_http_rejects_bad_status_and_html_first_packet() {
        // 正常音频
        assert!(classify_http(200, Some("audio/mpeg"), None).is_ok());
        // 明文 http 被劫持: 2xx 但首包是 HTML ⇒ 可重试(换个协议/再试一次)
        let hijack =
            classify_http(200, Some("text/html; charset=utf-8"), Some("redir_url")).unwrap_err();
        assert_eq!(
            hijack,
            DownloadFailure::Hijacked {
                content_type: "text/html; charset=utf-8".into(),
                server: Some("redir_url".into()),
            }
        );
        assert!(hijack.retryable());
        let err = hijack.to_provider_error();
        assert_eq!(err.kind, ncm_provider::ProviderErrorKind::Network);
        assert!(err.retryable, "被劫持要可重试");
        assert!(
            err.detail.contains("text/html"),
            "detail 要能指向真原因: {}",
            err.detail
        );

        // 非 2xx: 403/404 是"直链失效", 原样重试没意义
        let forbidden = classify_http(403, Some("text/html"), None).unwrap_err();
        assert_eq!(forbidden, DownloadFailure::HttpStatus(403));
        assert!(!forbidden.retryable());
        let err = forbidden.to_provider_error();
        assert_eq!(err.kind, ncm_provider::ProviderErrorKind::Forbidden);
        assert!(!err.retryable);

        let not_found = classify_http(404, None, None).unwrap_err();
        assert_eq!(
            not_found.to_provider_error().kind,
            ncm_provider::ProviderErrorKind::NotFound
        );

        // 5xx / 429 是抖动, 可重试
        let busy = classify_http(503, None, None).unwrap_err();
        assert!(busy.retryable());
        assert_eq!(
            busy.to_provider_error().kind,
            ncm_provider::ProviderErrorKind::Network
        );

        // 小到不可能是音频: 不可重试
        let tiny = DownloadFailure::TooSmall(1024);
        assert!(!tiny.retryable());
        assert_eq!(
            tiny.to_provider_error().kind,
            ncm_provider::ProviderErrorKind::Internal
        );
    }

    // ---------------- T2: 缓存键(带音质 + 旧键兼容) ----------------

    #[test]
    fn cache_key_carries_level_and_falls_back_to_legacy() {
        let tmp = TempDir::new("key");
        let cache = AudioCache::open(&tmp.0).unwrap();
        let url = "https://m701.music.126.net/2026/x/a.mp3?x=1";

        // 带音质的键
        assert_eq!(
            cache
                .path_for_level(42, url, Some("exhigh"))
                .file_name()
                .unwrap(),
            "42.exhigh.mp3"
        );
        // 没有音质 ⇒ 旧键
        assert_eq!(
            cache.path_for_level(42, url, None).file_name().unwrap(),
            "42.mp3"
        );
        assert_eq!(cache.path_for(42, url).file_name().unwrap(), "42.mp3");
        // 容器后缀仍然按 url 判
        assert_eq!(
            cache
                .path_for_level(42, "https://m8.music.126.net/a.flac", Some("lossless"))
                .file_name()
                .unwrap(),
            "42.lossless.flac"
        );

        // 旧键文件存在 ⇒ 新键未命中也要能命中(不做一次性清缓存)
        write_track(&tmp.0, "42.mp3", 100);
        assert_eq!(
            cache.cached_with_level(42, url, Some("exhigh")).as_deref(),
            Some(tmp.0.join("42.mp3").as_path()),
            "迁移期必须回退旧键"
        );

        // 新键文件优先
        write_track(&tmp.0, "42.exhigh.mp3", 120);
        assert_eq!(
            cache.cached_with_level(42, url, Some("exhigh")).as_deref(),
            Some(tmp.0.join("42.exhigh.mp3").as_path())
        );

        // 迁移期"换档第一次"仍可能命中旧键(旧文件没有音质信息) —— 这是兼容优先的
        // 已知代价(见 cached_with_level 的注释), 这里如实锁住行为而不是假装没有。
        assert_eq!(
            cache
                .cached_with_level(42, url, Some("lossless"))
                .as_deref(),
            Some(tmp.0.join("42.mp3").as_path()),
            "旧键文件在迁移期仍然可命中"
        );

        // "正在播放的不淘汰"前缀逻辑对新键同样有效(新键也是 {id}. 开头)
        write_track(&tmp.0, "42.lossless.mp3", 100);
        write_track(&tmp.0, "99.mp3", 100);
        touch(&tmp.0, "42.lossless.mp3", 900);
        touch(&tmp.0, "99.mp3", 1000);
        let r = cache.enforce_limit(150 * 1024, Some(42)).unwrap();
        assert_eq!(r.removed, 1, "只淘汰别的曲子");
        assert!(!tmp.0.join("99.mp3").exists());
        assert!(
            tmp.0.join("42.lossless.mp3").exists(),
            "正在播放的曲子的新键文件不能删"
        );
        assert!(tmp.0.join("42.exhigh.mp3").exists());
    }

    /// 没有历史遗留(全新目录)时, 键里的音质必须真的隔离: 换档不会命中别的码率。
    #[test]
    fn cache_key_isolates_levels_when_no_legacy_file() {
        let tmp = TempDir::new("key-iso");
        let cache = AudioCache::open(&tmp.0).unwrap();
        let url = "https://m701.music.126.net/2026/x/a.mp3";
        write_track(&tmp.0, "42.exhigh.mp3", 100);
        assert!(
            cache.cached_with_level(42, url, Some("lossless")).is_none(),
            "换档不能命中别的码率"
        );
        assert!(
            cache.cached_with_level(42, url, None).is_none(),
            "无音质的查询也不该乱命中新键"
        );
        assert!(cache.cached_with_level(42, url, Some("exhigh")).is_some());
    }

    // ---------------- R3/R4: 同 key 单飞 + 收尾 ----------------

    /// R3 判据: 同 track + 同音质的并发起播**只能有一个下载**。
    /// 后到者拿到的必须是领跑者的同一份 `.part` / `done`, 不能把已写的字节 remove 掉重来。
    #[test]
    fn start_progressive_reuses_inflight_download_for_same_key() {
        let tmp = TempDir::new("single-flight");
        let cache = AudioCache::open(&tmp.0).unwrap();
        let url = "https://m701.music.126.net/2026/x/a.mp3";

        let leader = cache.start_progressive(7, url, Some("exhigh")).unwrap();
        assert!(leader.leader, "第一个起播的是领跑者");
        // 模拟领跑者已经写进去的字节(下载进行中)
        std::fs::write(&leader.part_path, vec![7u8; 4096]).unwrap();

        let reuse = cache.start_progressive(7, url, Some("exhigh")).unwrap();
        assert!(!reuse.leader, "同 key 的后到者必须是复用者, 不得再下一次");
        assert_eq!(reuse.part_path, leader.part_path, "必须是同一个 .part");
        assert_eq!(reuse.final_path, leader.final_path);
        assert!(
            Arc::ptr_eq(&reuse.done, &leader.done),
            "done 必须是同一个, 否则播放线程看不到下载完成"
        );
        assert_eq!(
            std::fs::read(&reuse.part_path).unwrap().len(),
            4096,
            "复用者不得 remove/create 掉领跑者已经写进去的字节"
        );

        // 不同 key(换音质)是另一个下载, 互不影响
        let other = cache.start_progressive(7, url, Some("lossless")).unwrap();
        assert!(other.leader);
        assert_ne!(other.part_path, leader.part_path);
    }

    /// R3 判据(收尾): 下载失败后单飞条目要摘掉、`done` 要置位、`.part` 要删。
    /// 否则同 key 永远命中一个已经死掉的"在飞下载", 残片还会被下次起播接着解码。
    /// 用 127.0.0.1:9(本机拒绝连接)而不碰真直链, 测试不联网。
    #[tokio::test]
    async fn failed_progressive_download_cleans_up() {
        let tmp = TempDir::new("progressive-fail");
        let cache = AudioCache::open(&tmp.0).unwrap();
        let url = "http://127.0.0.1:9/a.mp3";
        let fetch = cache.start_progressive(11, url, None).unwrap();
        let part = fetch.part_path.clone();
        let done = Arc::clone(&fetch.done);

        assert!(cache.download_progressive(url, fetch).await.is_err());
        assert!(
            done.load(Ordering::Acquire),
            "失败也要置 done, 否则播放线程会干等到 stall 上限"
        );
        assert!(!part.exists(), "失败路径必须删掉 .part(D03)");
        // 条目已摘 ⇒ 同 key 再起播是新的领跑者(而不是复用一个死掉的下载)
        assert!(cache.start_progressive(11, url, None).unwrap().leader);
    }

    /// 复用者不允许自己再下一份(会二次截断同一个 `.part`)。
    #[tokio::test]
    async fn follower_must_not_download() {
        let tmp = TempDir::new("follower");
        let cache = AudioCache::open(&tmp.0).unwrap();
        let url = "https://m701.music.126.net/2026/x/a.mp3";
        let _leader = cache.start_progressive(12, url, None).unwrap();
        let follower = cache.start_progressive(12, url, None).unwrap();
        assert!(cache.download_progressive(url, follower).await.is_err());
        assert!(tmp.0.join("12.part").exists(), "领跑者的 .part 不能被卸尸");
    }

    /// `fetch` 与边下边播共用同一套 `.part` 准备: 不存在要建出来(前台下载以前缺这一步,
    /// 每次都在 `open` 那步 ENOENT), 有残片要清掉。
    #[test]
    fn prepare_part_creates_missing_file_and_clears_stale_bytes() {
        let tmp = TempDir::new("prepare-part");
        let stale = tmp.0.join("9.mp3.part");
        std::fs::write(&stale, vec![1u8; 4096]).unwrap();
        AudioCache::prepare_part(&stale).unwrap();
        assert_eq!(
            std::fs::metadata(&stale).unwrap().len(),
            0,
            "残片必须被清空"
        );
        let fresh = tmp.0.join("10.mp3.part");
        AudioCache::prepare_part(&fresh).unwrap();
        assert!(
            fresh.exists(),
            "不存在时必须建出来(否则下载在 open 那步就失败)"
        );
    }

    /// D03 判据: `fetch`(下完再播/Windows 走这条)失败后同样不留 `.part`。
    #[tokio::test]
    async fn failed_fetch_deletes_part() {
        let tmp = TempDir::new("fetch-fail");
        let cache = AudioCache::open(&tmp.0).unwrap();
        let url = "http://127.0.0.1:9/a.mp3";
        assert!(cache.fetch(13, url, None).await.is_err());
        assert!(
            !tmp.0.join("13.part").exists(),
            "失败后残片必须删掉(以前会留下, 下次从残缺文件接着解码)"
        );
    }

    // ---------------- R4: `.part` 计入配额 ----------------

    /// 下载中的字节也是磁盘占用: 以前 `extension == "part"` 直接 continue, 配额形同虚设。
    #[test]
    fn enforce_limit_counts_partial_downloads() {
        let tmp = TempDir::new("quota-part");
        write_track(&tmp.0, "1.mp3", 100);
        write_track(&tmp.0, "2.mp3.part", 100);
        touch(&tmp.0, "1.mp3", 300);
        touch(&tmp.0, "2.mp3.part", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();

        // 只看已完成文件是 100 KiB(不超), 含 `.part` 才是 200 KiB
        let r = cache.enforce_limit(150 * 1024, None).unwrap();
        assert_eq!(r.removed, 1, "必须把下载中的占用算进去才会开始淘汰");
        assert!(!tmp.0.join("1.mp3").exists(), "最久未修改的先淘汰");
        assert_eq!(r.total_bytes, 100 * 1024);
    }

    /// 正在播放那一首的 `.part` 绝不能删: 删了就是当场没声音(keep_track_id 的验收口径).
    #[test]
    fn enforce_limit_never_evicts_playing_part() {
        let tmp = TempDir::new("quota-part-keep");
        write_track(&tmp.0, "5.mp3.part", 100);
        write_track(&tmp.0, "6.mp3", 100);
        touch(&tmp.0, "5.mp3.part", 500); // 5 最老, 但正在播
        touch(&tmp.0, "6.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();

        let r = cache.enforce_limit(100 * 1024, Some(5)).unwrap();
        assert!(tmp.0.join("5.mp3.part").exists(), "正在播放的 .part 不能删");
        assert!(!tmp.0.join("6.mp3").exists());
        assert_eq!(r.removed, 1);
    }
}
