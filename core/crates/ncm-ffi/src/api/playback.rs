//! 桌面播放器: 播放控制状态机 / 播放参数(音量淡入曲线) / 音频缓存上限 / 响度测量.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

/// 播放器与取链**共用的客户端 UA**(唯一来源 = `ncm_service::identity::platform_profile().ua`).
///
/// Android 的 CDN 请求由 Kotlin(Media3)发, 拿不到 `ncm-service` 的常量, 以前手抄了
/// 一份到 `PlaybackService.USER_AGENT` —— 升级客户端版本时只改一侧就会出现
/// "取链用新 UA、播放用旧 UA", CDN/风控行为不一致, 表现为偶发 403 或偶发无声(P-21)。
/// 现在 Dart 启动时把本函数返回值经 `ncm/player#setUserAgent` 注入 PlaybackService,
/// Kotlin 侧只保留一份兜底常量(真值以这里为准)。
///
/// 同步函数: 纯常量读取, 不需要 async 运行时。
#[frb(sync)]
pub fn playback_user_agent() -> String {
    ncm_service::identity::platform_profile().ua.to_string()
}

// ---------------- 播放 ----------------

static PLAYER: OnceLock<ncm_playback::Player> = OnceLock::new();
// 注意: 这里**不能**再声明 `static DATA_DIR`。`super::*` 里的那份是 `init()` 唯一写入过的实例;
// 同名本地 `static` 会遮蔽 glob 导入(globs 优先级最低), 而没有任何代码会给它 set,
// 于是本文件所有 `DATA_DIR.get()` 永远 None ⇒ "core not initialized"
// (2026-11-23 实测: 桌面端播放/缓存全废; 拆分 api.rs 时引入的静默回归)。

fn player() -> &'static ncm_playback::Player {
    PLAYER.get_or_init(ncm_playback::Player::new)
}

pub struct PlayerStateDto {
    pub track_id: Option<u64>,
    pub playing: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
    /// 当前源能否精确 seek。桌面边下边播(渐进播放)期为 false,
    /// UI 据此禁用进度条并提示「缓存中, 暂不可跳转」(P-10)。
    /// Android 走 Media3, 不经过这里(通道 map 里没有这个键, Dart 侧默认 true)。
    pub seekable: bool,
    /// 最近一次 seek 失败的原因(None = 没失败过); 失败同时会打一条 warn 日志。
    pub seek_error: Option<String>,
    /// 渐进播放期(边下边播)登记下来、等下载完成后自动应用的跳转位置(ms)。
    /// None = 没有挂起的跳转。UI 可以据此显示「已排队, 缓存完成后自动跳转」(P-10 方案 B)。
    pub pending_seek_ms: Option<u64>,
}

fn state_dto() -> PlayerStateDto {
    let s = player().state();
    PlayerStateDto {
        track_id: s.track_id,
        playing: s.playing,
        position_ms: s.position_ms,
        duration_ms: s.duration_ms,
        volume: s.volume,
        seekable: s.seekable,
        seek_error: s.seek_error,
        pending_seek_ms: s.pending_seek_ms,
    }
}

/// 桌面播放: 已缓存直接播, 否则**边下边播**(乐观加载).
///
/// 之前的实现是 `fetch()` 等整首歌下载完再播 —— 一首 320kbps 的歌在慢网下
/// 要等好几秒才出声(用户反馈"等加载完才开始播放"). 现在:
/// 1. 命中缓存 → 直接播(秒开);
/// 2. 未命中 → 建空 `.part` → 立刻把播放句柄交给音频线程(读到 EOF 时阻塞等),
///    同时后台流式下载, 第一个数据块到达就能出声;
/// 3. 下完原子 rename 成正式缓存文件, 下次命中缓存。
///
/// 平台差异: Windows 不允许 rename 一个被打开的文件, 且 rename 失败会让缓存失效,
/// 所以 Windows 仍保留"下完再播"; Android 走 Media3(本来就是流式), 不经过这里。
/// [duration_ms] 是接口给的时长: 边下边播时解码器算不出总时长, 进度条先用它。
pub async fn play_track(
    track_id: u64,
    url: String,
    duration_ms: Option<u64>,
) -> Result<PlayerStateDto, FfiError> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| FfiError::internal("core not initialized"))?
        .join("audio");
    let cache = ncm_service::cache::AudioCache::open(&dir).map_err(FfiError::from)?;
    // 缓存键带音质: 取链时记过(见 `song_url`), 没记过就退回旧键(向后兼容)
    let level = ncm_service::cache::level_hint(track_id);
    let level = level.as_deref();
    if let Some(path) = cache.cached_with_level(track_id, &url, level) {
        player().play_file(track_id, path.to_string_lossy().to_string());
        return Ok(state_dto());
    }
    #[cfg(windows)]
    {
        let _ = duration_ms;
        // 失败时把分类原因(`ProviderError{kind,retryable,detail}`)回传 Dart 的错误通道
        let path = cache.fetch(track_id, &url, level).await?;
        player().play_file(track_id, path.to_string_lossy().to_string());
        Ok(state_dto())
    }
    #[cfg(not(windows))]
    {
        let progressive = cache.start_progressive(track_id, &url, level)?;
        let part = progressive.part_path.to_string_lossy().to_string();
        // final_path 交给播放线程: 渐进期拖进度条会登记成待跳, 下载完成后据此重建
        // 可 seek 的解码器并跳到那里(P-10 方案 B)
        let final_path = progressive.final_path.to_string_lossy().to_string();
        player().play_stream(
            track_id,
            part,
            Some(final_path),
            std::sync::Arc::clone(&progressive.done),
            duration_ms,
        );
        tokio::spawn(async move {
            // 失败时 `done` 已置位, 播放线程会立刻收尾而不是干等; 这里把分类原因
            // (`[kind] detail`, 与 ProviderError 同一文本协议)打进日志便于现场取证。
            // 注意: 渐进播放没有独立的"播放错误"字段可回传(codegen DTO 不在本车道改动面内),
            // 所以 UI 侧表现为"这一首很快结束"; 下载到文件(Win/CLI)走的是有错误通道的 fetch。
            if let Err(e) = cache.download_progressive(&url, progressive).await {
                eprintln!("[play] progressive download failed: {e}");
            }
        });
        Ok(state_dto())
    }
}

pub fn player_state() -> PlayerStateDto {
    state_dto()
}

pub fn player_pause() -> PlayerStateDto {
    player().pause();
    state_dto()
}

pub fn player_resume() -> PlayerStateDto {
    player().resume();
    state_dto()
}

pub fn player_stop() -> PlayerStateDto {
    player().stop();
    state_dto()
}

/// seek 到 [position_ms]。
///
/// 失败**不再静默**(P-10): 后端会打 warn 并把原因写进 `seek_error`,
/// 这里把状态原样带回 Dart —— 进度条拖到不可 seek 的位置时, UI 能立刻知道没生效,
/// 而不是先跳到新位置再被下一次轮询弹回原处。
pub fn player_seek(position_ms: u64) -> PlayerStateDto {
    match player().seek(position_ms) {
        // 渐进播放期无法立刻跳: 位置已登记, 下载完成后自动应用 —— 不是失败
        Ok(ncm_playback::SeekOutcome::Queued) => {
            eprintln!("[ncm-ffi] player_seek({position_ms}) 已排队: 缓存完成后自动跳转")
        }
        Ok(ncm_playback::SeekOutcome::Applied) => {}
        Err(e) => {
            // 后端已经 warn 过一次(带上下文), 这里补一层「从 FFI 调进来的」信息
            eprintln!("[ncm-ffi] player_seek({position_ms}) 未生效: {e}");
        }
    }
    state_dto()
}

pub fn player_set_volume(volume: f32) -> PlayerStateDto {
    player().set_volume(volume);
    state_dto()
}

// ---------------- 播放参数: 精细音量 / 淡入 / 自定义曲线 (R2/R5/R7) ----------------

/// 当前生效的播放参数(回显给 UI, 便于确认设置真的落地了)
pub struct PlaybackTuningDto {
    /// 精细音量增益(dB, -40..=0)
    pub gain_db: f64,
    /// 淡入时长(ms): **只在从暂停恢复时生效**(2026-11-23 口径);
    /// 切歌/首次起播不淡入(否则会把歌曲开头 1s 盖成静音)
    pub fade_ms: u32,
    /// 生效的滤波器数量(0 = 曲线旁路)
    pub eq_filters: u32,
    /// 曲线前级增益(dB)
    pub eq_preamp_db: f64,
    /// 生效的增益限速(dB/s): 0 = 瞬时, 3.0 = 动态 AGC 防 pump
    pub gain_slew_db_per_sec: f64,
}

fn tuning_dto(t: &ncm_playback::PlaybackTuning) -> PlaybackTuningDto {
    let (filters, preamp) = match &t.eq {
        Some(profile) => (
            profile.active_filters().count() as u32,
            profile.preamp_db as f64,
        ),
        None => (0, 0.0),
    };
    PlaybackTuningDto {
        gain_db: t.gain_db as f64,
        fade_ms: t.fade_ms,
        eq_filters: filters,
        eq_preamp_db: preamp,
        gain_slew_db_per_sec: t.gain_slew_db_per_sec as f64,
    }
}

/// 曲线校验结果(导入时给 UI 显示"生效了 N 个滤波器 / 前级 -6 dB / 峰值抬升 +2.5 dB")
pub struct EqValidationDto {
    /// 曲线里一共有多少个 filter(含 OFF)
    pub filters: u32,
    /// 实际参与求值的 filter(ON 且增益非 0)
    pub active_filters: u32,
    pub preamp_db: f64,
    /// 保守估计的总抬升(前级 + 各 filter 正增益之和), > 0 时可能削波
    pub max_boost_db: f64,
}

/// 校验 AutoEQ ParametricEQ.txt 文本。错误消息已是 "第 N 行: 原因" 形式, UI 直接显示。
pub fn eq_profile_validate(text: String) -> Result<EqValidationDto, FfiError> {
    let profile = ncm_domain::EqProfile::parse(&text).map_err(FfiError::from)?;
    Ok(EqValidationDto {
        filters: profile.filters.len() as u32,
        active_filters: profile
            .active_filters()
            .filter(|f| f.gain_db.abs() > f32::EPSILON)
            .count() as u32,
        preamp_db: profile.preamp_db as f64,
        max_boost_db: profile.max_boost_db() as f64,
    })
}

/// 归一化曲线文本(统一成 Rust 侧的规范格式, 便于落盘与跨端一致)
// UI 未用(2026-11-20 审计 7.2: ui/lib + ui/test 全量 grep 零命中) ⇒ `#[frb(ignore)]` 从 Dart API
// 摘掉后观察期已过, **结论: 有意保留**(2026-11-22 审计 C 收口, 分类见 docs/api-coverage.md
// 「有意保留(4)」), 不再按「候选删除」处理。
#[frb(ignore)]
pub fn eq_profile_normalize(text: String) -> Result<String, FfiError> {
    let profile = ncm_domain::EqProfile::parse(&text).map_err(FfiError::from)?;
    Ok(profile.to_text())
}

/// 应用播放参数: 精细音量立即生效; 曲线在下一首开始时套用;
/// 淡入只作用于**从暂停恢复**(2026-11-23: 切歌/首次起播不淡入)。
///
/// `eq_text` 为 None/空串 ⇒ 曲线旁路(清除曲线)。
/// `gain_slew_db_per_sec` = 增益变化限速(dB/s): **0 = 瞬时**(静态响度均衡/拖滑杆),
/// 3.0 = 动态响度(AGC)防 pump。三端同一口径(P-03); 负数/NaN 由 Rust 侧回落默认 3 dB/s。
pub fn player_configure(
    gain_db: f64,
    fade_ms: u32,
    eq_text: Option<String>,
    gain_slew_db_per_sec: f64,
) -> Result<PlaybackTuningDto, FfiError> {
    let eq = match eq_text {
        Some(text) if !text.trim().is_empty() => {
            Some(ncm_domain::EqProfile::parse(&text).map_err(FfiError::from)?)
        }
        _ => None,
    };
    let tuning = ncm_playback::PlaybackTuning {
        gain_db: gain_db as f32,
        fade_ms,
        eq,
        gain_slew_db_per_sec: gain_slew_db_per_sec as f32,
    };
    player().configure(tuning);
    Ok(tuning_dto(&player().tuning()))
}

/// 读取当前生效的播放参数
// UI 未用(2026-11-20 审计 7.2: ui/lib + ui/test 全量 grep 零命中) ⇒ `#[frb(ignore)]` 从 Dart API
// 摘掉后观察期已过, **结论: 有意保留**(2026-11-22 审计 C 收口, 分类见 docs/api-coverage.md
// 「有意保留(4)」), 不再按「候选删除」处理。
#[frb(ignore)]
pub fn player_tuning() -> PlaybackTuningDto {
    tuning_dto(&player().tuning())
}

// ---------------- 音频缓存占用上限 (R5) ----------------

fn audio_cache() -> Result<ncm_service::cache::AudioCache, FfiError> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| FfiError::internal("core not initialized"))?
        .join("audio");
    ncm_service::cache::AudioCache::open(&dir).map_err(FfiError::from)
}

/// 缓存占用(limit_mb = 0 表示不限制)
pub struct CacheStatsDto {
    pub total_bytes: u64,
    pub limit_bytes: u64,
    pub files: u32,
}

/// 只读统计, 不删任何文件
// UI 未用(2026-11-20 审计 7.2: ui/lib + ui/test 全量 grep 零命中) ⇒ `#[frb(ignore)]` 从 Dart API
// 摘掉后观察期已过, **结论: 有意保留**(2026-11-22 审计 C 收口, 分类见 docs/api-coverage.md
// 「有意保留(4)」), 不再按「候选删除」处理。
#[frb(ignore)]
pub fn cache_stats(limit_mb: u32) -> Result<CacheStatsDto, FfiError> {
    let cache = audio_cache()?;
    Ok(CacheStatsDto {
        total_bytes: cache.total_bytes(),
        limit_bytes: limit_mb as u64 * 1024 * 1024,
        files: cache.file_count() as u32,
    })
}

/// 按上限收敛缓存(最久未修改优先), 返回删了多少
pub struct CacheEvictionDto {
    pub removed: u32,
    pub freed_bytes: u64,
    pub total_bytes: u64,
    pub limit_bytes: u64,
}

pub fn cache_enforce_limit(
    limit_mb: u32,
    keep_track_id: Option<u64>,
) -> Result<CacheEvictionDto, FfiError> {
    let cache = audio_cache()?;
    let limit = limit_mb as u64 * 1024 * 1024;
    let r = cache.enforce_limit(limit, keep_track_id)?;
    Ok(CacheEvictionDto {
        removed: r.removed as u32,
        freed_bytes: r.freed_bytes,
        total_bytes: r.total_bytes,
        limit_bytes: limit,
    })
}

// ---------------- 响度测量 (R2b/R7) ----------------

/// 一次响度测量的对外形态(track_id + 测量值 + 相对目标电平的静态增益)
pub struct LoudnessDto {
    pub track_id: u64,
    pub lufs: f64,
    pub sample_peak: f64,
    /// ReplayGain 2.0 语义: target - measured(已钳到 ±24 dB)
    pub gain_db: f64,
    pub measured_at_ms: u64,
}

fn loudness_dto(track_id: u64, l: ncm_domain::TrackLoudness, target_lufs: f64) -> LoudnessDto {
    LoudnessDto {
        track_id,
        lufs: l.lufs as f64,
        sample_peak: l.sample_peak as f64,
        gain_db: ncm_playback::loudness::replay_gain_db(target_lufs as f32, l.lufs) as f64,
        measured_at_ms: l.measured_at_ms,
    }
}

fn loudness_store() -> Result<ncm_service::LoudnessStore, FfiError> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| FfiError::internal("core not initialized"))?;
    Ok(ncm_service::LoudnessStore::open(dir))
}

/// 读缓存的响度(没测过就是 None, 播放时按 0 dB 处理)
pub fn loudness_cached(track_id: u64, target_lufs: f64) -> Result<Option<LoudnessDto>, FfiError> {
    let store = loudness_store()?;
    Ok(store
        .get(track_id)
        .map(|l| loudness_dto(track_id, *l, target_lufs)))
}

/// 测量已缓存音频文件的响度并写入 `loudness.json`。未缓存该曲目时返回 None(不下载)。
pub async fn loudness_measure_cached(
    track_id: u64,
    target_lufs: f64,
) -> Result<Option<LoudnessDto>, FfiError> {
    if let Ok(store) = loudness_store() {
        if let Some(existing) = store.get(track_id) {
            return Ok(Some(loudness_dto(track_id, *existing, target_lufs)));
        }
    }
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| FfiError::internal("core not initialized"))?
        .join("audio");
    let cache = ncm_service::cache::AudioCache::open(&dir).map_err(FfiError::from)?;
    let Some(path) = cache.cached_path(track_id) else {
        return Ok(None);
    };
    let path_for_task = path.clone();
    let measured =
        tokio::task::spawn_blocking(move || ncm_playback::loudness::measure_file(&path_for_task))
            .await
            .map_err(FfiError::from)??;
    let Some(m) = measured else {
        return Ok(None);
    };
    let entry = ncm_domain::TrackLoudness {
        lufs: m.lufs,
        sample_peak: m.sample_peak,
        measured_at_ms: now_ms(),
    };
    let mut store = loudness_store()?;
    store.put(track_id, entry)?;
    Ok(Some(loudness_dto(track_id, entry, target_lufs)))
}

/// 测量任意音频文件路径的响度并写入 `loudness.json`(Android 侧 Media3 的 SimpleCache 文件用)。
pub async fn loudness_measure_path(
    track_id: u64,
    path: String,
    target_lufs: f64,
    format_hint: Option<String>,
) -> Result<Option<LoudnessDto>, FfiError> {
    let path_buf = std::path::PathBuf::from(&path);
    let measured = tokio::task::spawn_blocking(move || {
        ncm_playback::loudness::measure_file_with_hint(&path_buf, format_hint.as_deref())
    })
    .await
    .map_err(FfiError::from)??;
    let Some(m) = measured else {
        return Ok(None);
    };
    let entry = ncm_domain::TrackLoudness {
        lufs: m.lufs,
        sample_peak: m.sample_peak,
        measured_at_ms: now_ms(),
    };
    let mut store = loudness_store()?;
    store.put(track_id, entry)?;
    Ok(Some(loudness_dto(track_id, entry, target_lufs)))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
