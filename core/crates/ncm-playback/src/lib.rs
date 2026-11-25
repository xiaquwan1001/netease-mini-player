//! 播放抽象与 Linux 实现.
//!
//! 设计约束:
//! - core 只定义状态机与命令, 具体后端按平台实现
//! - Android 用 Media3(Kotlin), Linux 用 rodio/CPAL(纯 Rust, 无系统依赖)
//! - UI 轮询 PlayerState, 不订阅复杂回调(M0/M2 够用)

use serde::{Deserialize, Serialize};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub mod agc;
pub mod biquad;
pub mod loudness;

/// 播放期的可调参数(R2/R5/R7 的落点). 全部由设置页写入, 默认值 = 完全不改变现状.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaybackTuning {
    /// R2 精细音量: -40..=+12 dB, 与系统音量相乘(0 = 不变)。
    ///
    /// 上限是 +12 而不是 0: 响度均衡(R2b)对安静曲目要能给出**正增益**
    /// (ReplayGain 2.0 语义 `target - measured`), 用户自己的音量滑块仍限制在 -40..0。
    /// 正增益实际被"系统音量满格"自然封顶(乘法链钳 0..1), 所以不会引入额外削波。
    pub gain_db: f32,
    /// R5 暂停恢复的淡入: 0 / 200 / 500 / 1000 ms(切歌不淡入, 见 `INSTANT_FADE`)
    pub fade_ms: u32,
    /// R7 自定义响度曲线(AutoEQ ParametricEQ); None = 旁路
    pub eq: Option<ncm_domain::EqProfile>,
    /// 增益变化限速(dB/s): **0 = 瞬时**, >0 = 每个 tick 按该斜率逼近目标(P-03).
    ///
    /// 三端同一口径: 设置页开着"动态响度(AGC)"传 3.0(防 pump), 关着传 0.0(滑杆直感).
    /// 默认 3.0 = 限速器一直以来的行为, 老调用方(CLI/未传该参数的 FFI)不回归.
    pub gain_slew_db_per_sec: f32,
}

impl Default for PlaybackTuning {
    fn default() -> Self {
        Self {
            gain_db: 0.0,
            fade_ms: 0,
            eq: None,
            gain_slew_db_per_sec: agc::DEFAULT_MAX_SLEW_DB_PER_SEC,
        }
    }
}

impl PlaybackTuning {
    /// 收敛到合法范围(设置页与 FFI 都可能传越界值, 防御性处理)
    pub fn sanitized(self) -> Self {
        Self {
            gain_db: if self.gain_db.is_finite() {
                self.gain_db.clamp(-40.0, 12.0)
            } else {
                0.0
            },
            fade_ms: self.fade_ms.min(5_000),
            eq: self.eq,
            gain_slew_db_per_sec: if self.gain_slew_db_per_sec.is_finite()
                && self.gain_slew_db_per_sec >= 0.0
            {
                // 0 是合法值(= 瞬时), 不要在这里被"当成未设置"改成默认值
                self.gain_slew_db_per_sec
            } else {
                agc::DEFAULT_MAX_SLEW_DB_PER_SEC
            },
        }
    }

    /// 精细音量的线性倍数(0 dB => 1.0)
    pub fn gain_linear(&self) -> f32 {
        biquad::db_to_linear(self.gain_db.clamp(-40.0, 12.0))
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PlayerState {
    pub track_id: Option<u64>,
    pub playing: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
    /// 当前曲目能否响应 seek。渐进播放(边下边播)**下载完成前**为 false —— 那时
    /// 解码器是以 `with_seekable(false)` 构建的, seek 只能排队; 下载完成后立刻变 true,
    /// 第一次 seek 会重建可 seek 的解码器(P-10 方案 B)。
    #[serde(default)]
    pub seekable: bool,
    /// 最近一次 seek 失败的原因(None = 上次 seek 成功 / 从未 seek)。
    /// 以前这个错误被 `let _ = player.try_seek(..)` 丢掉, 现在既写日志也回传给调用方。
    #[serde(default)]
    pub seek_error: Option<String>,
    /// 渐进播放期用户拖到、但**暂时无法真正跳转**的位置(ms)。
    ///
    /// P-10 方案 B: 渐进期 seek 不再失败, 而是登记成这样一条待跳, 下载完成后自动
    /// 重建解码器并应用; 应用/换曲/确定失败后清空。None = 没有挂起的跳转。
    #[serde(default)]
    pub pending_seek_ms: Option<u64>,
}

#[derive(Debug, Clone)]
pub enum PlaybackError {
    NoBackend(String),
    Io(String),
    Decode(String),
    /// 当前源不支持该操作(典型: 边下边播期 seek)
    Unsupported(String),
}

impl std::fmt::Display for PlaybackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlaybackError::NoBackend(s) => write!(f, "no audio backend: {s}"),
            PlaybackError::Io(s) => write!(f, "io: {s}"),
            PlaybackError::Decode(s) => write!(f, "decode: {s}"),
            PlaybackError::Unsupported(s) => write!(f, "unsupported: {s}"),
        }
    }
}

impl std::error::Error for PlaybackError {}

impl From<std::io::Error> for PlaybackError {
    fn from(e: std::io::Error) -> Self {
        PlaybackError::Io(e.to_string())
    }
}

/// 播放数据的来源(桌面端).
#[derive(Debug, Clone)]
pub enum PlaySource {
    /// 已完整落盘的文件(可以精确 seek, 时长可靠)
    File(String),
    /// 边下边播: `.part` 文件会持续增长, [`done`] 置位后不再有新字节.
    ///
    /// 为什么不直接喂 HTTP 流: rodio 0.23 的 Decoder 要求 `Read + Seek`, 纯流没有
    /// seek 能力; 而"下完再播"要等整首歌(用户反馈切歌/开播太慢). 折中方案是下载
    /// 线程写本地文件、播放线程读同一个文件, 读到 EOF 时阻塞等下一块.
    Growing {
        path: String,
        /// 下载完成后 rename 到的正式缓存路径(P-10 方案 B: 用它重建可 seek 的解码器).
        /// None = 调用方不知道最终路径, 只能等重播后才可 seek.
        final_path: Option<String>,
        done: Arc<std::sync::atomic::AtomicBool>,
    },
}

impl PlaySource {
    /// 这个源能否精确 seek: **只有完整落盘的文件可以**。
    ///
    /// 边下边播的 `.part` 还在增长, 解码器以 `with_seekable(false)` 构建(否则 symphonia
    /// 会为了算时长/建索引扫全文件, 等于把「边下边播」退化成「下完再播」);
    /// rodio 对非 seekable 源的 `try_seek` 必然失败, 所以这里报的是**当前解码器**能不能跳。
    ///
    /// 「下载完成后用完整文件重建解码器」这条升级路径见 [`resolve_source_status`]
    /// 与 [`SeekPlanner`](P-10 方案 B)。
    pub fn seekable(&self) -> bool {
        matches!(self, PlaySource::File(_))
    }
}

/// 渐进源(P-10 方案 B)的 seek 能力分级。
///
/// [`PlaySource::seekable`] 只回答"当前这个解码器能不能跳"; 渐进下载**已完成**时
/// 真实答案是"当前不能, 但可以拿完整文件重建一个能跳的解码器", 所以要再分一档。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceStatus {
    /// 完整落盘文件: 直接 `try_seek`
    Seekable,
    /// 渐进下载进行中: 只能登记待跳
    Growing,
    /// 渐进下载已完成, 携带完整文件路径: 可重建解码器后再跳
    GrowingComplete(String),
    /// 渐进下载结束但没有完整文件(失败/被清理): 跳不了, 只能如实报错
    GrowingFailed,
}

impl SourceStatus {
    /// 现在收到 seek 能不能兑现(直接跳或重建后跳都算)
    pub fn is_seekable(&self) -> bool {
        matches!(
            self,
            SourceStatus::Seekable | SourceStatus::GrowingComplete(_)
        )
    }
}

/// 一条 seek 请求的处置方式(决策结果, 还没执行)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeekAction {
    /// 当前解码器就能跳: 直接下发
    Direct(u64),
    /// 渐进期不能跳: 登记待跳, 下载完成后自动应用
    Queue(u64),
    /// 渐进下载已完成: 用完整文件重建解码器, 再跳到该位置
    Rebuild(u64),
}

/// 一条 seek 请求的最终结果(回传给调用方的语义)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeekOutcome {
    /// 真的跳到了目标位置
    Applied,
    /// 渐进期无法立刻跳: 已登记, 下载完成后自动应用到该位置 —— **不是失败**
    Queued,
}

/// 待跳登记 + 决策(纯逻辑: 不碰音频设备、不读文件, 便于无设备单测)。
#[derive(Debug, Default)]
pub struct SeekPlanner {
    pending: Option<u64>,
}

impl SeekPlanner {
    pub fn new() -> Self {
        Self::default()
    }

    /// 当前挂着、等待下载完成后应用的跳转位置
    pub fn pending(&self) -> Option<u64> {
        self.pending
    }

    /// 清掉待跳(已应用 / 换曲 / 已确定无法应用)
    pub fn reset(&mut self) {
        self.pending = None;
    }

    /// 收到一条 seek: 决定「直接跳 / 登记 / 重建后跳」。
    pub fn request(
        &mut self,
        status: &SourceStatus,
        target_ms: u64,
    ) -> Result<SeekAction, PlaybackError> {
        match status {
            SourceStatus::Seekable => {
                self.pending = None;
                Ok(SeekAction::Direct(target_ms))
            }
            // 渐进期: 登记. 后到的 seek 覆盖先到的(UI 只关心"最终拖到哪")
            SourceStatus::Growing => {
                self.pending = Some(target_ms);
                Ok(SeekAction::Queue(target_ms))
            }
            SourceStatus::GrowingComplete(_) => {
                self.pending = None;
                Ok(SeekAction::Rebuild(target_ms))
            }
            SourceStatus::GrowingFailed => Err(PlaybackError::Unsupported(
                "边下边播的下载没有完成(或缓存文件已被清理): 解码器不可 seek, 也无法重建".into(),
            )),
        }
    }
}

/// 判定源当前处于哪一档(渐进源要看 `done` 与完整文件是否已经就位)。
pub fn resolve_source_status(source: &PlaySource) -> SourceStatus {
    match source {
        PlaySource::File(_) => SourceStatus::Seekable,
        PlaySource::Growing {
            final_path, done, ..
        } => {
            if !done.load(std::sync::atomic::Ordering::Acquire) {
                return SourceStatus::Growing;
            }
            match final_path.as_deref().and_then(complete_file) {
                Some(path) => SourceStatus::GrowingComplete(path),
                None => SourceStatus::GrowingFailed,
            }
        }
    }
}

/// 完整文件是否已经就位(下载线程**先 rename 再置 done**, 所以 done 之后一般都在)
fn complete_file(path: &str) -> Option<String> {
    match std::fs::metadata(path) {
        Ok(meta) if meta.is_file() && meta.len() > 0 => Some(path.to_string()),
        _ => None,
    }
}

enum Cmd {
    Play {
        track_id: u64,
        source: PlaySource,
        /// 接口给的预期时长(边下边播时解码器还不知道时长, 先用它撑进度条)
        expected_duration_ms: Option<u64>,
    },
    Pause,
    Resume,
    Stop,
    /// seek 的结果**回传**给调用方(P-10): 以前这里是 `let _ = player.try_seek(..)`,
    /// 失败被整个吞掉, UI 拖完进度条只会看到位置弹回原处、没有任何提示。
    ///
    /// 结果分两态: 立即跳成功(`SeekOutcome::Applied`)与渐进期登记成功
    /// (`SeekOutcome::Queued`, 下载完成后自动应用)。
    Seek {
        position_ms: u64,
        reply: Option<mpsc::SyncSender<Result<SeekOutcome, PlaybackError>>>,
    },
    Volume(f32),
    /// 更新播放参数(增益/淡入/EQ). 增益即时生效, EQ 在下一首开始时套用,
    /// 淡入作用于下一次从暂停恢复
    Configure(PlaybackTuning),
    Shutdown,
}

/// seek 回执的等待上限: 音频线程最多 200ms 醒一次处理命令, 1.5s 足够;
/// 又不会在阻塞读(边下边播等数据/设备挂死)时把 FFI 调用方一起拖住。
pub const SEEK_REPLY_TIMEOUT: Duration = Duration::from_millis(1_500);

/// 单实例播放器: 命令进 channel, 音频线程独占输出设备.
pub struct Player {
    tx: Sender<Cmd>,
    state: Arc<Mutex<PlayerState>>,
    tuning: Arc<Mutex<PlaybackTuning>>,
}

impl Player {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel::<Cmd>();
        let state = Arc::new(Mutex::new(PlayerState {
            volume: 1.0,
            ..Default::default()
        }));
        let tuning = Arc::new(Mutex::new(PlaybackTuning::default()));
        let thread_state = Arc::clone(&state);
        let thread_tuning = Arc::clone(&tuning);
        std::thread::Builder::new()
            .name("ncm-audio".into())
            .spawn(move || backend::run(rx, thread_state, thread_tuning))
            .ok();
        Self { tx, state, tuning }
    }

    /// 更新播放参数(增益/淡入/EQ): 淡入值是"暂停恢复"的斜坡时长
    pub fn configure(&self, tuning: PlaybackTuning) {
        let tuning = tuning.sanitized();
        if let Ok(mut t) = self.tuning.lock() {
            *t = tuning.clone();
        }
        let _ = self.tx.send(Cmd::Configure(tuning));
    }

    /// 当前生效的播放参数
    pub fn tuning(&self) -> PlaybackTuning {
        self.tuning.lock().map(|t| t.clone()).unwrap_or_default()
    }

    pub fn play_file(&self, track_id: u64, path: impl Into<String>) {
        let _ = self.tx.send(Cmd::Play {
            track_id,
            source: PlaySource::File(path.into()),
            expected_duration_ms: None,
        });
    }

    /// 边下边播: 立即开始解码已经到达的字节, 剩余部分由下载线程继续追加.
    ///
    /// `final_path` 是下载完成后 rename 到的正式缓存路径: 渐进期 seek 会登记成
    /// 待跳, 下载完成后据此重建可 seek 的解码器并跳到那里(P-10 方案 B)。
    /// 传 None 就退回旧行为(渐进期不可 seek, 得重播一次)。
    pub fn play_stream(
        &self,
        track_id: u64,
        path: impl Into<String>,
        final_path: Option<String>,
        done: Arc<std::sync::atomic::AtomicBool>,
        expected_duration_ms: Option<u64>,
    ) {
        let _ = self.tx.send(Cmd::Play {
            track_id,
            source: PlaySource::Growing {
                path: path.into(),
                final_path,
                done,
            },
            expected_duration_ms,
        });
    }

    pub fn pause(&self) {
        let _ = self.tx.send(Cmd::Pause);
    }

    pub fn resume(&self) {
        let _ = self.tx.send(Cmd::Resume);
    }

    pub fn stop(&self) {
        let _ = self.tx.send(Cmd::Stop);
    }

    /// seek 到 [position_ms]. **不再静默失败**, 也不再一律拒绝:
    ///
    /// - 源可 seek(完整文件 / 渐进下载已完成) ⇒ `SeekOutcome::Applied`;
    /// - 渐进下载进行中 ⇒ `SeekOutcome::Queued`(位置记进
    ///   `PlayerState::pending_seek_ms`, 下载完成后自动重建解码器并跳过去);
    /// - 下载失败等确实兑现不了的情况 ⇒ `Unsupported` 等错误, 同时由后端把原因写进
    ///   `PlayerState::seek_error` 并打一条 warn 日志。
    ///
    /// 等待是**有界**的(音频线程阻塞在读数据时不会把调用方一起拖死),
    /// 超时按要求报错而不是假装成功。
    pub fn seek(&self, position_ms: u64) -> Result<SeekOutcome, PlaybackError> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        if self
            .tx
            .send(Cmd::Seek {
                position_ms,
                reply: Some(reply_tx),
            })
            .is_err()
        {
            let e = PlaybackError::NoBackend("音频线程已退出, seek 无法送达".into());
            log::warn!("[playback] seek 未生效: {e}");
            return Err(e);
        }
        match reply_rx.recv_timeout(SEEK_REPLY_TIMEOUT) {
            Ok(result) => result,
            Err(_) => {
                let e = PlaybackError::Io(format!(
                    "seek 在 {}ms 内没有回执(音频线程忙着解码/等数据)",
                    SEEK_REPLY_TIMEOUT.as_millis()
                ));
                log::warn!("[playback] seek 未生效: {e}");
                Err(e)
            }
        }
    }

    pub fn set_volume(&self, volume: f32) {
        let _ = self.tx.send(Cmd::Volume(volume.clamp(0.0, 1.0)));
    }

    pub fn state(&self) -> PlayerState {
        self.state.lock().map(|s| s.clone()).unwrap_or_default()
    }
}

impl Default for Player {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        let _ = self.tx.send(Cmd::Shutdown);
    }
}

/// 实际输出音量 = 系统音量 × 增益(线性), 两者相乘且都钳在 0..1。
/// [gain_db] 是**当前实际施加**的增益(可能被 GainLimiter 限速后还没到目标),
/// 与 [PlaybackTuning::gain_db] 的目标值区分开。抽成 crate 级纯函数, 便于无音频设备单测。
fn effective_volume_db(user_volume: f32, gain_db: f32) -> f32 {
    (user_volume * biquad::db_to_linear(gain_db.clamp(-40.0, 12.0))).clamp(0.0, 1.0)
}

/// 一次 seek 请求是否被允许(纯函数: 不需要音频设备就能测)。
///
/// 边下边播期的解码器是非 seekable 的, rodio 的 `try_seek` 对它必然失败 ——
/// 与其把错误吞掉让进度条弹回旧位置(用户以为播放器卡死), 不如在命令入口就如实拒绝,
/// 并把原因一路回传到 UI(P-10)。
pub fn check_seek(seekable: bool, position_ms: u64) -> Result<(), PlaybackError> {
    if seekable {
        return Ok(());
    }
    Err(PlaybackError::Unsupported(format!(
        "当前曲目仍在缓存(渐进播放, 目标 {position_ms}ms): 解码器非 seekable, 暂不可跳转"
    )))
}

/// 把一次 seek 的结果落到可轮询状态里, 失败时留一条 warn 日志。
///
/// 之前这里是 `let _ = player.try_seek(..)`: 失败既没日志也没回传, 调用方拿到的
/// 只是「没动」的旧位置。现在错误同时出现在 stderr 与 `PlayerState::seek_error`,
/// UI 侧还有 `PlayerState::seekable` 可以提前把进度条禁掉。
pub fn record_seek_outcome(
    state: &Mutex<PlayerState>,
    result: &Result<SeekOutcome, PlaybackError>,
) {
    match result {
        // 立即跳到 / 已排队都算「这次请求被接受了」, 不留错误态
        Ok(_) => {
            if let Ok(mut st) = state.lock() {
                st.seek_error = None;
            }
        }
        Err(e) => {
            log::warn!("[playback] seek 未生效: {e}");
            if let Ok(mut st) = state.lock() {
                st.seek_error = Some(e.to_string());
            }
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
mod backend {
    use super::*;
    use rodio::{
        source::SeekError, ChannelCount, Decoder, DeviceSinkBuilder, Player as RodioPlayer, Sample,
        SampleRate, Source,
    };
    use std::fs::File;
    // `Seek` 供探测重试时把 `try_clone` 出来的句柄倒回文件头(见 `attempt_pending_play`)
    use std::io::Seek;
    // Instant 只被桌面后端用(GrowingFile 判死线 / 恢复淡入斜坡的计时), 放在模块内
    // 而不是文件顶部: 否则 Android 侧(非桌面 backend)会报 unused import。
    use std::time::Instant;

    /// EQ 包装源: 逐样本处理, 不缓冲(因此 span/时长与原始 decoder 完全对齐)
    struct EqSource<I> {
        input: I,
        chain: biquad::EqChain,
        channel: usize,
        channels: usize,
    }

    impl<I> EqSource<I>
    where
        I: Source<Item = Sample>,
    {
        fn new(input: I, chain: biquad::EqChain) -> Self {
            let channels = input.channels().get() as usize;
            Self {
                input,
                chain,
                channel: 0,
                channels,
            }
        }
    }

    impl<I> Iterator for EqSource<I>
    where
        I: Source<Item = Sample>,
    {
        type Item = Sample;

        fn next(&mut self) -> Option<Self::Item> {
            let x = self.input.next()?;
            let y = self.chain.process_sample(self.channel, x);
            self.channel = (self.channel + 1) % self.channels.max(1);
            Some(y)
        }

        fn size_hint(&self) -> (usize, Option<usize>) {
            self.input.size_hint()
        }
    }

    impl<I> Source for EqSource<I>
    where
        I: Source<Item = Sample>,
    {
        fn current_span_len(&self) -> Option<usize> {
            self.input.current_span_len()
        }

        fn channels(&self) -> ChannelCount {
            self.input.channels()
        }

        fn sample_rate(&self) -> SampleRate {
            self.input.sample_rate()
        }

        fn total_duration(&self) -> Option<Duration> {
            self.input.total_duration()
        }

        /// seek 必须**透传**给内层 decoder。
        ///
        /// `Source::try_seek` 的默认实现直接返回 `NotSupported`, 而我们的 EQ 包装层
        /// 以前没实现它 —— 于是连完整落盘的文件都无法跳转(错误又被 `let _ =` 吞掉,
        /// 表现就是拖进度条静默弹回)。这是 P-10 顺带查出的真实缺陷。
        fn try_seek(&mut self, pos: Duration) -> Result<(), SeekError> {
            self.input.try_seek(pos)
        }
    }

    /// 增长中的本地文件: 下载线程还在追加字节时, 读到 EOF **阻塞等待**而不是返回 0.
    ///
    /// 这是"边下边播"的关键: rodio/symphonia 只认 `Read + Seek`, 看到 EOF 就会
    /// 认为曲子播完了. 这里把"暂时没有数据"和"真的没有数据"区分开 ——
    /// 只有 `done` 置位(下载成功/失败都会置位)才返回 EOF.
    struct GrowingFile {
        file: File,
        done: Arc<std::sync::atomic::AtomicBool>,
        /// 读到"暂时没有新字节"时要不要阻塞等下载.
        ///
        /// 播放期**必须**等(否则播到已下载末尾就当播完); 建解码器期间的探测
        /// **不许**等 —— symphonia 探测是逐字节扫 marker(上限 1MiB)、mp3 还要整块读
        /// ID3, 空 `.part` 上做 `Decoder::build()` 会落进下面的等待循环(上限 90s),
        /// 而这段代码跑在音频**命令线程**上, 期间 Pause/Stop/Seek/Volume 全排队。
        /// 开关做成共享原子量是为了"探测完立刻切成等待": 解码器被移进播放器后
        /// 拿不到 `GrowingFile` 本体了(见 [`build_growing`])。
        wait_for_more: Arc<std::sync::atomic::AtomicBool>,
        /// **最近一次拿到新字节**的时刻(不是"打开文件"的时刻).
        ///
        /// T2(2026-11-18) 修的真实缺陷: 以前这个字段叫 `since` 且只在 open 时赋值,
        /// 于是"打开后 90s"就成了判死线 —— 一首在慢网上下载的 5 分钟歌曲, 只要
        /// 播放线程(比下载快)在 90s 后偶尔读空一次, 就会被当成 EOF **提前结束**。
        /// 现在每次读到字节都刷新, 判死口径变成"连续这么久没有任何新字节"。
        last_data: Instant,
        /// 无新字节的忍耐上限(可配, 见 [`stall_limit_from`])
        limit: Duration,
    }

    /// 静止判死阈值: 默认 90s, 可用 `NCM_GROWING_STALL_SECS` 覆盖(最小 5s).
    ///
    /// 为什么默认仍是 90s: 桌面下载器本身有 20s 读间隔超时(ncm-service `cache::READ_TIMEOUT`),
    /// 真的 stalled 会在那里先失败并把 `done` 置位 —— 这里的阈值只兜"下载线程整个消失"
    /// 的病态情况, 阈值太小反而会把**正常慢网**判死。
    fn stall_limit_from(raw: Option<&str>) -> Duration {
        const DEFAULT_SECS: u64 = 90;
        const MIN_SECS: u64 = 5;
        let secs = raw
            .and_then(|v| v.trim().parse::<u64>().ok())
            .filter(|s| *s >= MIN_SECS)
            .unwrap_or(DEFAULT_SECS);
        Duration::from_secs(secs)
    }

    fn stall_limit() -> Duration {
        let raw = std::env::var("NCM_GROWING_STALL_SECS").ok();
        stall_limit_from(raw.as_deref())
    }

    impl GrowingFile {
        /// 播放期的构造(wait_for_more = true). 生产路径走 [`build_growing`]
        /// (先不等待地探测, 成功后再置位), 这里只给"就该阻塞等数据"的用例用。
        #[cfg(test)]
        fn open(path: &str, done: Arc<std::sync::atomic::AtomicBool>) -> std::io::Result<Self> {
            Ok(Self::from_file(File::open(path)?, done, true))
        }

        /// `wait_for_more` = 读到"暂时没有新字节"时是不是阻塞等下载
        fn from_file(
            file: File,
            done: Arc<std::sync::atomic::AtomicBool>,
            wait_for_more: bool,
        ) -> Self {
            Self {
                file,
                done,
                wait_for_more: Arc::new(std::sync::atomic::AtomicBool::new(wait_for_more)),
                last_data: Instant::now(),
                limit: stall_limit(),
            }
        }

        /// 等待开关: 探测成功后由 [`build_growing`] 置 true
        fn wait_flag(&self) -> Arc<std::sync::atomic::AtomicBool> {
            Arc::clone(&self.wait_for_more)
        }
    }

    impl std::io::Read for GrowingFile {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            // File 的 Read 实现直接可用(方法解析走 std::fs::File 的 inherent trait 导入链)
            loop {
                let n = self.file.read(buf)?;
                if n > 0 {
                    // 有新字节 ⇒ 重新计时(见 last_data 的注释: 以前漏了这一步)
                    self.last_data = Instant::now();
                    return Ok(n);
                }
                if self.done.load(std::sync::atomic::Ordering::Acquire) {
                    return Ok(0);
                }
                if !self
                    .wait_for_more
                    .load(std::sync::atomic::Ordering::Acquire)
                {
                    // 探测期: 不等数据, 把"暂时还没字节"报成 EOF 让 symphonia 立刻失败
                    // 返回给命令线程(调用方看到有新字节了再重试, 见 `PendingPlay`)。
                    return Ok(0);
                }
                if self.last_data.elapsed() > self.limit {
                    // **明确报错而不是静默 EOF**: 以前返回 Ok(0) 等于"这首曲目正常播完了",
                    // 用户听感是"无缘无故切下一首", 日志里也没有失败痕迹。
                    eprintln!(
                        "[playback] growing file stalled > {:?}, aborting this track",
                        self.limit
                    );
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        format!(
                            "边下边播 stalled: 连续 {:?} 没有新字节(下载线程可能已挂死;                              NCM_GROWING_STALL_SECS 可调)",
                            self.limit
                        ),
                    ));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }

    impl std::io::Seek for GrowingFile {
        fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
            self.file.seek(pos)
        }
    }

    /// 建一条"边下边播"的解码器, **探测期不阻塞**(R5).
    ///
    /// 两个阶段刻意分开:
    /// 1. 探测(symphonia 扫 marker + 读头部)在 `wait_for_more = false` 下做: 读空立刻当
    ///    EOF 返回, 于是"首块数据还没到"在毫秒级失败, 而不是把音频命令线程挂到 90s 判死线;
    /// 2. 探测成功才把开关置 true —— 这之后读到"暂时没新字节"必须阻塞等下载,
    ///    否则播到已下载末尾就当整首播完(边下边播的核心性质, 见 `blocks_at_eof_until_more_bytes_arrive`)。
    ///
    /// 返回 `Err` 表示**数据还不够建解码器**(慢网起播的正常状态), 由调用方登记重试。
    fn build_growing(
        file: File,
        done: Arc<std::sync::atomic::AtomicBool>,
    ) -> Result<Decoder<GrowingFile>, String> {
        let source = GrowingFile::from_file(file, done, false);
        let wait = source.wait_flag();
        match Decoder::builder()
            .with_data(source)
            .with_seekable(false)
            .build()
        {
            Ok(decoder) => {
                wait.store(true, std::sync::atomic::Ordering::Release);
                Ok(decoder)
            }
            Err(e) => Err(e.to_string()),
        }
    }

    /// 把一条源套上 EQ 链与淡入(**纯构造**: 不碰播放器/输出设备, 因此没有声卡也能单测包络).
    ///
    /// 开播([`start_source`])与渐进下载完成后的换源([`upgrade_to_complete`])共用这一段:
    /// 两处的 EQ 链构造、淡入、声道/采样率读取必须完全一致, 否则换源后音色会变。
    fn tuned_source<I>(
        input: I,
        local: &PlaybackTuning,
        fade: Duration,
    ) -> impl Source<Item = Sample> + Send + 'static
    where
        I: Source<Item = Sample> + Send + 'static,
    {
        // EQ 链: 没有曲线时构造一条空链(纯旁路), 保持源类型固定
        let empty = ncm_domain::EqProfile::default();
        let profile = local.eq.as_ref().unwrap_or(&empty);
        let chain = biquad::EqChain::new(
            profile,
            input.sample_rate().get() as f32,
            input.channels().get() as usize,
        );
        EqSource::new(input, chain).fade_in(fade)
    }

    /// 开播/换曲**不淡入**(2026-11-23 用户口径): 新曲从头播本来就从静音开始, 再叠一个
    /// 用户设置的淡入会把歌曲开头真盖住(1s 淡入 = 前 1s 几乎听不见, 听感是"错过开头")。
    /// 用户设置的淡入只属于一个场景: 从暂停恢复(音频线程 `Cmd::Resume` 的音量斜坡);
    /// 换源防爆音另用固定的 [`SWAP_FADE`](与用户设置无关)。
    ///
    /// rodio 的 `fade_in` 会断言时长非零, 所以"立即"用 1ms 兜底; 抽成常量是为了让
    /// "开播 → 实际淡入时长"这条换算能被单测直接盯住(见 `fade_tests`)。
    const INSTANT_FADE: Duration = Duration::from_millis(1);

    /// 把一条源套上 EQ 链与淡入后追加进播放队列(**不碰状态**).
    fn append_source<I>(player: &RodioPlayer, input: I, local: &PlaybackTuning, fade: Duration)
    where
        I: Source<Item = Sample> + Send + 'static,
    {
        player.append(tuned_source(input, local, fade));
    }

    /// 两条来源(落盘文件 / 增长中文件)共用的一段: 套 EQ + 淡入后开始播, 并写回状态.
    fn start_source<I>(
        player: &RodioPlayer,
        input: I,
        local: &PlaybackTuning,
        track_id: u64,
        expected_duration_ms: Option<u64>,
        seekable: bool,
        state: &Arc<Mutex<PlayerState>>,
    ) where
        I: Source<Item = Sample> + Send + 'static,
    {
        // 边下边播时解码器还不知道总时长(非 seekable, 不扫全文件), 用接口给的时长兜底
        let duration = input
            .total_duration()
            .or_else(|| expected_duration_ms.map(Duration::from_millis));
        // 开播不淡入(见 INSTANT_FADE 的注释); 1ms 斜坡只为消除首样本阶跃
        append_source(player, input, local, INSTANT_FADE);
        player.play();
        if let Ok(mut st) = state.lock() {
            st.track_id = Some(track_id);
            st.duration_ms = duration.map(|d| d.as_millis() as u64).unwrap_or(0);
            st.position_ms = 0;
            st.playing = true;
            // 源的 seek 能力随曲目一起发布给 UI(边下边播期 = false)
            st.seekable = seekable;
            st.seek_error = None;
            st.pending_seek_ms = None;
        }
    }

    /// 当前正在播的来源(P-10 方案 B: 渐进源下载完成后要据此重建可 seek 的解码器)
    #[derive(Clone)]
    struct CurrentTrack {
        track_id: u64,
        source: PlaySource,
        /// 接口给的预期时长(渐进期解码器算不出时长, 换源时作兜底)
        expected_duration_ms: Option<u64>,
    }

    /// 当前源的分级(渐进源要看 done 与完整文件是否就位)
    fn current_status(track: &CurrentTrack) -> SourceStatus {
        resolve_source_status(&track.source)
    }

    /// 等首块数据期间暂存的起播请求(R5).
    ///
    /// 以前 `Cmd::Play` 直接在命令线程上 `Decoder::build()`, 慢网起播时那条线程被
    /// `GrowingFile` 的等待循环占住(上限 90s) ⇒ Pause/Stop/Seek/Volume 全排队、seek 的
    /// 1.5s 回执必超时。现在建不成解码器就登记在这里, 每个 tick 重试一次。
    struct PendingPlay {
        track: CurrentTrack,
        /// Play 时刻就打开的 `.part` 句柄: 下载完成会 rename 成正式缓存文件, 按路径
        /// 重开会 404, 而句柄一直指向同一个 inode(与改动前"开播即 open"的语义一致)。
        /// 重试靠 `try_clone` + `seek(0)` 复用这同一个 inode。
        file: Option<File>,
        /// 上次尝试时碰到的文件长度: 没有新字节就不重复探测(免得每个 tick 扫一遍)
        probed_len: u64,
        /// 等首块期间用户按过暂停: 首块到达后要停在暂停态, 不能自己放起来
        paused: bool,
        /// 最近一次**看到新字节**的时刻(判死口径与 `GrowingFile` 一致)
        progressed_at: Instant,
    }

    /// 一条待起播请求重试的结果
    enum PendingOutcome {
        /// 已经真的开播了
        Started,
        /// 数据还不够建解码器: 等下一块再试(正常状态, 不是错误)
        NotReady(String),
    }

    /// 尝试把"等首块"的起播请求真的开起来(**不阻塞**: 见 [`build_growing`])。
    fn attempt_pending_play(
        player: &RodioPlayer,
        pending: &mut PendingPlay,
        local: &PlaybackTuning,
        state: &Arc<Mutex<PlayerState>>,
    ) -> PendingOutcome {
        let PlaySource::Growing { path, done, .. } = &pending.track.source else {
            return PendingOutcome::NotReady("待起播的来源不是渐进源".into());
        };
        // 用 `try_clone` 而不是把句柄交出去: build 失败时句柄要留着下次再用
        let cloned = match &pending.file {
            Some(file) => file.try_clone().map_err(|e| e.to_string()),
            // 没拿到句柄(Play 时文件还没创建): 优先按 `.part` 路径开; 如果 `.part` 已经被
            // rename 成正式缓存文件(下得比起播还快), 就开那个完整文件
            None => match current_status(&pending.track) {
                SourceStatus::GrowingComplete(final_path) => {
                    File::open(&final_path).map_err(|e| format!("open {final_path} failed: {e}"))
                }
                _ => File::open(path).map_err(|e| format!("open {path} failed: {e}")),
            },
        };
        let mut file = match cloned {
            Ok(file) => file,
            Err(e) => return PendingOutcome::NotReady(e),
        };
        // 每次探测都从头开始(dup 出来的 fd 与原件共享读写位置)
        if let Err(e) = file.seek(std::io::SeekFrom::Start(0)) {
            return PendingOutcome::NotReady(format!("seek {path} failed: {e}"));
        }
        match build_growing(file, Arc::clone(done)) {
            Ok(decoder) => {
                start_source(
                    player,
                    decoder,
                    local,
                    pending.track.track_id,
                    pending.track.expected_duration_ms,
                    false,
                    state,
                );
                if pending.paused {
                    // 等首块期间用户已经按了暂停: 起播后立刻停住(状态在 tick 里会对齐)
                    player.pause();
                    if let Ok(mut st) = state.lock() {
                        st.playing = false;
                    }
                }
                PendingOutcome::Started
            }
            Err(e) => PendingOutcome::NotReady(e),
        }
    }

    /// 渐进源当前的文件长度(判"有没有新字节"用; 拿不到当 0)
    fn growing_len(track: &CurrentTrack) -> u64 {
        match &track.source {
            PlaySource::Growing { path, .. } | PlaySource::File(path) => {
                std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
            }
        }
    }

    /// 换源时的淡入时长: 足够盖住波形不连续(消爆音), 又短到听不出来
    const SWAP_FADE: Duration = Duration::from_millis(25);

    /// 恢复淡入的斜坡比例(0→1 线性, 纯函数便于单测): `None` = 无斜坡(=1.0);
    /// 已到时自动清空并返回 1.0, 中间线性过渡。盖在最终音量上(乘法),
    /// 所以对用户音量/增益限速都是透明的。
    fn ramp_scale(ramp: &mut Option<(Instant, Duration)>) -> f32 {
        let Some((start, dur)) = ramp else {
            return 1.0;
        };
        let elapsed = start.elapsed();
        if elapsed >= *dur || *dur == Duration::ZERO {
            *ramp = None;
            return 1.0;
        }
        (elapsed.as_secs_f32() / dur.as_secs_f32()).clamp(0.0, 1.0)
    }

    /// 把一次 seek 交给 rodio(错误按"不支持 / 其它"分类)
    fn try_seek_player(player: &RodioPlayer, target_ms: u64) -> Result<(), PlaybackError> {
        player
            .try_seek(Duration::from_millis(target_ms))
            .map_err(|e| {
                if matches!(&e, SeekError::NotSupported { .. }) {
                    PlaybackError::Unsupported(e.to_string())
                } else {
                    PlaybackError::Decode(e.to_string())
                }
            })
    }

    /// 渐进下载完成后换源: 用**完整文件**重建可 seek 的解码器, 并跳到 [target_ms]。
    ///
    /// 顺序是刻意的:
    /// 1. 所有可能失败的 IO(打开完整文件、seek 到目标)都在**动当前播放之前**做完 ——
    ///    失败就原地返回, 正在播的源一个字节都不动;
    /// 2. 记下播放/暂停态, `clear()`(它顺带会 pause), 追加新源并恢复;
    /// 3. 新源用 [SWAP_FADE] 短淡入, 避免切换瞬间的波形不连续变成爆音;
    /// 4. 位置/时长/音量/EQ 链沿用原来那套(音量在 rodio 的 controls 上, 不受 clear 影响)。
    ///
    /// 位置计数: 新解码器是**先 seek 再追加**的, rodio 的相对位置从 0 开始, 所以调用方
    /// 要用 `pos_base_ms = target_ms` 把基准补回来(见 `run` 的注释)。
    fn upgrade_to_complete(
        player: &RodioPlayer,
        track: &CurrentTrack,
        path: &str,
        target_ms: u64,
        local: &PlaybackTuning,
        state: &Arc<Mutex<PlayerState>>,
    ) -> Result<(), PlaybackError> {
        let target = Duration::from_millis(target_ms);
        // 1) 旁路验证: 完整文件能打开、能 seek 到目标
        let probe = Decoder::try_from(File::open(path)?)
            .map_err(|e| PlaybackError::Decode(format!("{path}: {e}")))?;
        let mut probe = probe;
        probe.try_seek(target).map_err(|e| {
            PlaybackError::Unsupported(format!("完整文件无法 seek 到 {target_ms}ms: {e}"))
        })?;
        drop(probe);
        let decoder = Decoder::try_from(File::open(path)?)
            .map_err(|e| PlaybackError::Decode(format!("{path}: {e}")))?;
        let duration = decoder
            .total_duration()
            .or_else(|| track.expected_duration_ms.map(Duration::from_millis));
        let mut source = decoder;
        source.try_seek(target).map_err(|e| {
            PlaybackError::Unsupported(format!("完整文件无法 seek 到 {target_ms}ms: {e}"))
        })?;
        // 2) 换源(从这里开始当前播放会被打断, 所以前面不能有任何会失败的步骤)
        let was_playing = !player.is_paused() && !player.empty();
        player.clear();
        append_source(player, source, local, SWAP_FADE);
        player.play();
        if !was_playing {
            player.pause();
        }
        // 3) 状态: 位置直接等于待跳位置, 播放态/时长沿用
        if let Ok(mut st) = state.lock() {
            st.track_id = Some(track.track_id);
            st.position_ms = target_ms;
            if let Some(d) = duration {
                st.duration_ms = d.as_millis() as u64;
            }
            st.playing = was_playing;
            st.seekable = true;
            st.seek_error = None;
            st.pending_seek_ms = None;
        }
        Ok(())
    }

    /// 把待跳/重建请求落成实际动作, 成功时返回新的位置基准(见 `run` 的注释)。
    ///
    /// - 完整文件: 直接 `try_seek`(基准 0, rodio 自己管位置);
    /// - 渐进下载已完成: 换源重建([`upgrade_to_complete`])并把 `current` 的来源升级成
    ///   完整文件 —— 这样后续 seek 不再重复重建, 也顺手修掉「同一首歌下载完成后还要
    ///   重播一次才能 seek」的老毛病;
    /// - 还在下载 / 下载失败: 如实报错(调用方负责清待跳)。
    fn apply_rebuild(
        player: &RodioPlayer,
        current: &mut Option<CurrentTrack>,
        target_ms: u64,
        local: &PlaybackTuning,
        state: &Arc<Mutex<PlayerState>>,
    ) -> Result<u64, PlaybackError> {
        let track = current
            .as_ref()
            .ok_or_else(|| PlaybackError::Unsupported("当前没有可跳转的曲目".into()))?;
        let path = match current_status(track) {
            SourceStatus::GrowingComplete(path) => path,
            SourceStatus::Seekable => {
                // 已经是可 seek 的源: 不用换, 直接跳
                try_seek_player(player, target_ms)?;
                return Ok(0);
            }
            SourceStatus::Growing => {
                return Err(PlaybackError::Unsupported(
                    "渐进下载还没完成: 待跳位置暂时无法应用".into(),
                ))
            }
            SourceStatus::GrowingFailed => {
                return Err(PlaybackError::Unsupported(
                    "边下边播的下载没有完成(或缓存文件已被清理): 无法重建解码器".into(),
                ))
            }
        };
        upgrade_to_complete(player, track, &path, target_ms, local, state)?;
        // 换源成功: 来源升级成完整文件, 后续 seek 直接走 try_seek
        if let Some(track) = current.as_mut() {
            track.source = PlaySource::File(path);
        }
        Ok(target_ms)
    }

    pub fn run(
        rx: mpsc::Receiver<Cmd>,
        state: Arc<Mutex<PlayerState>>,
        tuning: Arc<Mutex<PlaybackTuning>>,
    ) {
        // MixerDeviceSink 必须在整个线程生命周期内存活,否则声音立刻停
        let sink_handle = match DeviceSinkBuilder::open_default_sink() {
            Ok(h) => h,
            Err(e) => {
                eprintln!("[playback] no audio output: {e}");
                return;
            }
        };
        let player = RodioPlayer::connect_new(sink_handle.mixer());
        // user_volume 是"系统音量"(0..1), 精细音量(R2)/响度增益作为独立增益乘上去
        let mut user_volume = 1.0f32;
        let mut local = tuning.lock().map(|t| t.clone()).unwrap_or_default();
        // 增益限速器: Cmd::Configure 改的是目标增益, 每个 tick 按 GainLimiter 的斜率逼近,
        // 避免动态响度(AGC)在安静段/鼓点上突然抽一下(pump)。斜率来自 PlaybackTuning
        // (P-03: 0 = 瞬时, 3 dB/s = 动态模式), 三端同一口径。Cmd::Play 用 reset_to 立即到位,
        // Cmd::Volume(系统音量)完全不经过它, 保持瞬时。
        let mut limiter = agc::GainLimiter::with_slew(local.gain_slew_db_per_sec);
        limiter.reset_to(local.gain_db);
        let mut last_tick = Instant::now();
        // 当前曲目的来源(P-10 方案 B: 渐进源下载完成后要靠它找到完整文件并换源)
        let mut current: Option<CurrentTrack> = None;
        // 等首块数据的起播请求(R5): 建不成解码器就寄存在这里, 由 tick 分支重试,
        // 命令线程因此始终在 `rx.recv_timeout` 上, Pause/Stop/Seek/Volume 不会被阻塞
        let mut pending_play: Option<PendingPlay> = None;
        // 待跳登记: 渐进期 seek 先排队, 下载完成后自动应用
        let mut planner = SeekPlanner::new();
        // 播放位置的基准偏移: **只有换源这一条路径**会抬高它(新解码器是先 seek 再追加的,
        // rodio 的相对计数从 0 开始)。其它路径(开播 / 直接 seek)都让 rodio 自己算, 基准为 0。
        let mut pos_base_ms: u64 = 0;
        // 恢复淡入(2026-11-23 用户口径): 只有**从暂停恢复**才淡入(用户设置的 fade_ms),
        // 开播/换曲不淡入。记录 = (斜坡起点, 总时长); 音量在循环尾按 elapsed 线性爬升。
        let mut resume_ramp: Option<(Instant, Duration)> = None;
        player.set_volume(effective_volume_db(user_volume, limiter.current_db()));

        loop {
            // 淡入期间用细 tick(20ms), 让 200ms 级的斜坡也有 >=10 个台阶, 听不出阶梯;
            // 平时仍用粗 tick(200ms)省电。
            let tick = if resume_ramp.is_some() {
                Duration::from_millis(20)
            } else {
                Duration::from_millis(200)
            };
            match rx.recv_timeout(tick) {
                Ok(Cmd::Play {
                    track_id,
                    source,
                    expected_duration_ms,
                }) => {
                    // stop() 之后不可复用,换曲用 clear()
                    player.clear();
                    planner.reset();
                    pos_base_ms = 0;
                    // 新的一条 Play 取消上一条还没等到首块的起播
                    pending_play = None;
                    // 换曲: 记下来源(渐进源下载完成后要靠它换源), 能力先按当前解码器报
                    // 换曲即重置恢复淡入: 新曲目从头播, 不吃上一个暂停恢复的斜坡
                    resume_ramp = None;
                    let seekable = source.seekable();
                    let spec = CurrentTrack {
                        track_id,
                        source: source.clone(),
                        expected_duration_ms,
                    };
                    let mut started = true;
                    // 换曲: 增益立即对齐到当前目标, 不带着上一曲半截斜坡的残留、也不从 0 慢慢爬
                    limiter.reset_to(local.gain_db);
                    player.set_volume(effective_volume_db(user_volume, limiter.current_db()));
                    match source {
                        PlaySource::File(path) => match File::open(&path) {
                            Ok(file) => match Decoder::try_from(file) {
                                Ok(decoder) => start_source(
                                    &player,
                                    decoder,
                                    &local,
                                    track_id,
                                    expected_duration_ms,
                                    seekable,
                                    &state,
                                ),
                                Err(e) => {
                                    eprintln!("[playback] decode failed: {e}");
                                    started = false;
                                }
                            },
                            Err(e) => {
                                eprintln!("[playback] open {path} failed: {e}");
                                started = false;
                            }
                        },
                        // 边下边播: 文件还在增长, 报告"不可 seek"以免 symphonia 为算时长扫全文件
                        PlaySource::Growing { path, .. } => {
                            // R5: 句柄在 Play 时刻就拿在手上(数据下完 `.part` 会被 rename),
                            // 首块数据没到也不在这里等 —— 建不成解码器就登记到 tick 重试,
                            // 命令线程立刻回去收 Pause/Stop/Seek/Volume。
                            let mut pending = PendingPlay {
                                track: spec.clone(),
                                file: File::open(&path).ok(),
                                probed_len: std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0),
                                paused: false,
                                progressed_at: Instant::now(),
                            };
                            match attempt_pending_play(&player, &mut pending, &local, &state) {
                                PendingOutcome::Started => started = true,
                                PendingOutcome::NotReady(e) => {
                                    // 慢网起播的正常状态(首块还没到), 不是错误
                                    log::info!("[playback] 等首块数据: {e}");
                                    started = false;
                                    pending_play = Some(pending);
                                }
                            }
                        }
                    }
                    // 还在等首块的也算"当前曲目": 让 seek 能登记待跳而不是报"没有可跳转的曲目"
                    current = if started || pending_play.is_some() {
                        Some(spec)
                    } else {
                        None
                    };
                }
                Ok(Cmd::Pause) => {
                    player.pause();
                    // 暂停打断斜坡: 恢复时会重新起一个完整的淡入
                    resume_ramp = None;
                    // 等首块期间就按了暂停: 首块到达后也要停着(不得等首字节才响应)
                    if let Some(pending) = pending_play.as_mut() {
                        pending.paused = true;
                    }
                }
                Ok(Cmd::Resume) => {
                    player.play();
                    // 等首块期间按了播放: 首块到达后就直接响, 不要停在暂停态
                    if let Some(pending) = pending_play.as_mut() {
                        pending.paused = false;
                    }
                    // 只有从暂停恢复才淡入(用户设置的 fade_ms; 0 = 关闭淡入 → 瞬时)
                    resume_ramp = if local.fade_ms > 0 {
                        Some((
                            Instant::now(),
                            Duration::from_millis(local.fade_ms.min(5_000) as u64),
                        ))
                    } else {
                        None
                    };
                }
                Ok(Cmd::Stop) => {
                    player.clear();
                    current = None;
                    // 还在等首块的起播也一并取消: stop 不得等首字节
                    pending_play = None;
                    planner.reset();
                    pos_base_ms = 0;
                    if let Ok(mut st) = state.lock() {
                        st.playing = false;
                        st.position_ms = 0;
                        st.track_id = None;
                        st.duration_ms = 0;
                        st.seekable = false;
                        st.seek_error = None;
                        st.pending_seek_ms = None;
                    }
                }
                Ok(Cmd::Seek { position_ms, reply }) => {
                    // P-10 方案 B: 渐进期不再一律拒绝 —— 能跳就跳, 下完的源换个解码器再跳,
                    // 还在下的先登记成待跳并如实回"已排队"(下载完成后自动应用)。
                    let result: Result<SeekOutcome, PlaybackError> = match current.as_ref() {
                        None => Err(PlaybackError::Unsupported(
                            "当前没有可跳转的曲目: seek 已忽略".into(),
                        )),
                        Some(track) => {
                            // 还没起播(等首块)时一律先登记待跳: 此时播放队列是空的,
                            // 直接去重建/跳转没有意义; 起播后 tick 分支会把待跳应用上去
                            let status = if pending_play.is_some() {
                                SourceStatus::Growing
                            } else {
                                current_status(track)
                            };
                            match planner.request(&status, position_ms) {
                                Ok(SeekAction::Direct(target)) => {
                                    let r = try_seek_player(&player, target);
                                    if r.is_ok() {
                                        // rodio 自己会把位置计数挪到 target, 基准回到 0
                                        pos_base_ms = 0;
                                    }
                                    r.map(|()| SeekOutcome::Applied)
                                }
                                Ok(SeekAction::Queue(_)) => Ok(SeekOutcome::Queued),
                                Ok(SeekAction::Rebuild(target)) => {
                                    apply_rebuild(&player, &mut current, target, &local, &state)
                                        .map(|base| {
                                            pos_base_ms = base;
                                            SeekOutcome::Applied
                                        })
                                }
                                Err(e) => Err(e),
                            }
                        }
                    };
                    record_seek_outcome(&state, &result);
                    // 待跳 / 能力变化都如实落到可轮询状态(UI 据此显示"已排队")
                    if let Ok(mut st) = state.lock() {
                        st.pending_seek_ms = planner.pending();
                        if let Some(track) = current.as_ref() {
                            st.seekable = current_status(track).is_seekable();
                        }
                    }
                    if let Some(tx) = reply {
                        let _ = tx.send(result);
                    }
                }
                Ok(Cmd::Volume(v)) => {
                    user_volume = v;
                    // 系统音量瞬时生效(拧音量键必须立刻响应), 但增益部分仍用限速后的当前值;
                    // 恢复淡入期间按斜坡比例缩放
                    player.set_volume(
                        effective_volume_db(user_volume, limiter.current_db())
                            * ramp_scale(&mut resume_ramp),
                    );
                    if let Ok(mut st) = state.lock() {
                        st.volume = v;
                    }
                }
                Ok(Cmd::Configure(t)) => {
                    local = t;
                    if let Ok(mut shared) = tuning.lock() {
                        *shared = local.clone();
                    }
                    // 斜率可以运行期改(切"动态响度"): 不改当前值, 从当前位置按新斜率继续
                    limiter.set_slew(local.gain_slew_db_per_sec);
                    // 不在这里直接改音量: 目标增益已更新, 由循环尾部的 tick 按限速逐步逼近;
                    // EQ/淡入仍在下一首开始时套用(换曲时重新追加源)
                }
                Ok(Cmd::Shutdown) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }

            // 增益限速 tick: 循环最多 200ms 醒一次, 用真实流逝时间算步长(命令到达会提前醒,
            // 不能固定按 200ms 算, 否则限速不精确)。只有目标增益在变时 step 才会真的移动。
            let now = Instant::now();
            let dt = (now - last_tick).as_secs_f32();
            last_tick = now;
            let applied_gain = limiter.step(local.gain_db, dt);
            // 恢复淡入斜坡: 线性 0→1 盖在最终音量上; 斜坡结束(或不存在)时 = 1.0 无影响
            player.set_volume(
                effective_volume_db(user_volume, applied_gain) * ramp_scale(&mut resume_ramp),
            );

            // P-10 方案 B: 渐进下载完成后, 把待跳位置应用到重建的可 seek 解码器上。
            // 每条待跳只尝试一次: 失败就把原因如实写进 seek_error 并清掉待跳
            // (不每个 tick 反复重建 —— 那会变成持续的爆音源)。
            if let Some(target) = planner.pending() {
                match current.as_ref().map(current_status) {
                    Some(SourceStatus::GrowingComplete(_)) => {
                        match apply_rebuild(&player, &mut current, target, &local, &state) {
                            Ok(base) => {
                                pos_base_ms = base;
                                planner.reset();
                            }
                            Err(e) => {
                                planner.reset();
                                record_seek_outcome(&state, &Err(e));
                            }
                        }
                    }
                    Some(SourceStatus::GrowingFailed) => {
                        planner.reset();
                        let e = PlaybackError::Unsupported(
                            "边下边播的下载没有完成(或缓存文件已被清理): 待跳位置无法应用".into(),
                        );
                        record_seek_outcome(&state, &Err(e));
                    }
                    _ => {}
                }
            }

            // R5: 等首块数据的起播重试(慢网起播)。只在**有新字节**或下载结束时才重新探测:
            // 空 `.part` 不会每 200ms 被扫一遍, 而命令线程始终停在 `recv_timeout` 上 ——
            // 所以等首块期间 Pause/Stop/Seek/Volume 照常响应。
            if let Some(mut pending) = pending_play.take() {
                let len = growing_len(&pending.track);
                let done = matches!(
                    current_status(&pending.track),
                    SourceStatus::GrowingComplete(_) | SourceStatus::GrowingFailed
                );
                if done || len > pending.probed_len {
                    if len > pending.probed_len {
                        pending.probed_len = len;
                        pending.progressed_at = Instant::now();
                    }
                    match attempt_pending_play(&player, &mut pending, &local, &state) {
                        PendingOutcome::Started => {}
                        PendingOutcome::NotReady(e) => {
                            if done {
                                // 下载已结束(成功但数据不够解码 / 失败): 再等不会有新字节
                                eprintln!("[playback] stream decode failed: {e}");
                                current = None;
                            } else {
                                pending_play = Some(pending);
                            }
                        }
                    }
                } else if pending.progressed_at.elapsed() > stall_limit() {
                    // 与 `GrowingFile` 的判死口径一致: 下载线程整个消失时不无限等
                    eprintln!(
                        "[playback] growing file stalled > {:?}, aborting this track",
                        stall_limit()
                    );
                    current = None;
                } else {
                    pending_play = Some(pending);
                }
            }

            let pos = player.get_pos().as_millis() as u64;
            let empty = player.empty();
            let paused = player.is_paused();
            if let Ok(mut st) = state.lock() {
                if st.track_id.is_some() {
                    // 换源路径把解码器预先 seek 过, rodio 的相对计数要从基准补回来
                    st.position_ms = pos_base_ms.saturating_add(pos);
                    st.playing = !paused && !empty;
                    if let Some(track) = current.as_ref() {
                        if !st.seekable {
                            st.seekable = current_status(track).is_seekable();
                        }
                    }
                    st.pending_seek_ms = planner.pending();
                }
            }
        }
    }

    #[cfg(test)]
    mod growing_tests {
        use super::*;
        use std::io::{Read, Write};

        /// T2: 边下边播的"判死阈值"可配, 且不会被配成把正常慢网判死的值。
        #[test]
        fn stall_limit_is_configurable_with_a_floor() {
            // 默认 90s
            assert_eq!(stall_limit_from(None), Duration::from_secs(90));
            // 正常值生效
            assert_eq!(stall_limit_from(Some("45")), Duration::from_secs(45));
            // 前后空白可接受
            assert_eq!(stall_limit_from(Some(" 120 ")), Duration::from_secs(120));
            // 非数字/过小(小于 5s 会把正常慢网判死)⇒ 回落默认
            assert_eq!(stall_limit_from(Some("abc")), Duration::from_secs(90));
            assert_eq!(stall_limit_from(Some("1")), Duration::from_secs(90));
            assert_eq!(stall_limit_from(Some("0")), Duration::from_secs(90));
        }

        /// 造一个 16bit/mono/8kHz 的 WAV(只剩 header, data 由调用方按块追加).
        fn wav_header(samples: usize) -> Vec<u8> {
            let data_len = (samples * 2) as u32;
            let mut out = Vec::with_capacity(44);
            out.extend_from_slice(b"RIFF");
            out.extend_from_slice(&(36 + data_len).to_le_bytes());
            out.extend_from_slice(b"WAVEfmt ");
            out.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
            out.extend_from_slice(&1u16.to_le_bytes()); // PCM
            out.extend_from_slice(&1u16.to_le_bytes()); // mono
            out.extend_from_slice(&8000u32.to_le_bytes()); // sample rate
            out.extend_from_slice(&16000u32.to_le_bytes()); // byte rate
            out.extend_from_slice(&2u16.to_le_bytes()); // block align
            out.extend_from_slice(&16u16.to_le_bytes()); // bits
            out.extend_from_slice(b"data");
            out.extend_from_slice(&data_len.to_le_bytes());
            out
        }

        fn temp_wav(tag: &str) -> (std::path::PathBuf, std::path::PathBuf) {
            let dir = std::env::temp_dir().join(format!(
                "ncm-growing-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("t.wav");
            (dir, path)
        }

        /// 边下边播的核心性质: 读到 EOF 时**阻塞**等新字节, 而不是当作播放结束.
        ///
        /// 场景: 文件先只有 header + 一半样本, 解码开始; 50ms 后另一个线程追加剩余
        /// 样本并置 done。断言的样本数必须是"全部"而不是"先到的一半".
        #[test]
        fn blocks_at_eof_until_more_bytes_arrive() {
            let (dir, path) = temp_wav("grow");
            let total_samples = 4000usize;
            let half = total_samples / 2;
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(&wav_header(total_samples)).unwrap();
            f.write_all(&vec![0u8; half * 2]).unwrap();
            f.flush().unwrap();
            drop(f);

            let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let file = GrowingFile::open(path.to_str().unwrap(), Arc::clone(&done)).unwrap();
            let writer = {
                let path = path.clone();
                let done = Arc::clone(&done);
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(50));
                    let mut f = std::fs::OpenOptions::new()
                        .append(true)
                        .open(&path)
                        .unwrap();
                    f.write_all(&vec![0u8; (total_samples - half) * 2]).unwrap();
                    f.flush().unwrap();
                    done.store(true, std::sync::atomic::Ordering::Release);
                })
            };

            let mut decoder = Decoder::builder()
                .with_data(file)
                .with_seekable(false)
                .build()
                .expect("wav 应该能解");
            let mut got = 0usize;
            while decoder.next().is_some() {
                got += 1;
                assert!(got <= total_samples, "解出的样本数不应超过文件里的样本数");
            }
            writer.join().unwrap();
            assert_eq!(got, total_samples, "下载线程后来追加的半段也必须能播到");
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// done 置位后立刻返回 EOF(下载结束/失败时不能把音频线程晾住)
        #[test]
        fn returns_eof_once_done() {
            let (dir, path) = temp_wav("done");
            std::fs::write(&path, wav_header(8)).unwrap();
            let done = Arc::new(std::sync::atomic::AtomicBool::new(true));
            let mut f = GrowingFile::open(path.to_str().unwrap(), done).unwrap();
            let mut buf = [0u8; 16];
            let mut total = 0usize;
            loop {
                let n = f.read(&mut buf).unwrap();
                if n == 0 {
                    break;
                }
                total += n;
            }
            assert_eq!(total, 44, "只有 header 时读到 44 字节就该结束");
            let _ = std::fs::remove_dir_all(&dir);
        }

        // ---- R5: 建解码器不得阻塞音频命令线程 ----

        /// R5 判据: 首块数据还没到时建解码器**不得阻塞**。
        ///
        /// 改动前这里的 `Decoder::build()` 会落进 `GrowingFile::read` 的 10ms 等待循环
        /// (上限 `stall_limit` 90s), 而调用它的正是**音频命令线程** —— 那段时间
        /// Pause/Stop/Seek/Volume 全排队, seek 的 1.5s 回执必然超时。
        #[test]
        fn build_growing_does_not_block_on_empty_part() {
            let (dir, path) = temp_wav("empty-part");
            std::fs::write(&path, b"").unwrap();
            let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let started = Instant::now();
            let err = match build_growing(File::open(&path).unwrap(), Arc::clone(&done)) {
                Ok(_) => panic!("空文件不应该能建出解码器"),
                Err(e) => e,
            };
            let elapsed = started.elapsed();
            assert!(
                elapsed < Duration::from_secs(1),
                "建解码器必须立刻失败, 实测 {elapsed:?}"
            );
            assert!(!err.is_empty(), "失败原因要能传给调用方");
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// 探测期读空必须立刻报 EOF, 不能进等待循环(这是上一条的根因)。
        #[test]
        fn probe_reads_report_eof_instead_of_waiting() {
            let (dir, path) = temp_wav("no-wait");
            std::fs::write(&path, b"").unwrap();
            let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let mut file = GrowingFile::from_file(File::open(&path).unwrap(), done, false);
            let started = Instant::now();
            let mut buf = [0u8; 16];
            assert_eq!(file.read(&mut buf).unwrap(), 0, "探测期读空要立刻报 EOF");
            assert!(started.elapsed() < Duration::from_millis(500));
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// 探测成功之后必须切回"阻塞等新字节": 否则播到已下载末尾就当整首播完。
        ///
        /// 场景与 [`blocks_at_eof_until_more_bytes_arrive`] 相同, 但走生产路径
        /// [`build_growing`] (探测期不等待), 断言的样本数必须是"全部"而不是先到的一半。
        #[test]
        fn build_growing_waits_for_later_bytes_after_probe_succeeds() {
            let (dir, path) = temp_wav("probe-then-wait");
            let total_samples = 4000usize;
            let half = total_samples / 2;
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(&wav_header(total_samples)).unwrap();
            f.write_all(&vec![0u8; half * 2]).unwrap();
            f.flush().unwrap();
            drop(f);

            let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let mut decoder = build_growing(File::open(&path).unwrap(), Arc::clone(&done))
                .expect("头部到齐就该能建解码器");
            let writer = {
                let path = path.clone();
                let done = Arc::clone(&done);
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(50));
                    let mut f = std::fs::OpenOptions::new()
                        .append(true)
                        .open(&path)
                        .unwrap();
                    f.write_all(&vec![0u8; (total_samples - half) * 2]).unwrap();
                    f.flush().unwrap();
                    done.store(true, std::sync::atomic::Ordering::Release);
                })
            };
            let mut got = 0usize;
            while decoder.next().is_some() {
                got += 1;
            }
            writer.join().unwrap();
            assert_eq!(got, total_samples, "探测完之后必须继续阻塞等新字节");
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// R5: 等首块期间的起播重试 —— 首块没到不动播放队列, 到了才开播;
        /// 期间用户按的暂停不能被起播吞掉。
        #[test]
        fn pending_play_starts_on_first_bytes_and_keeps_user_pause() {
            let (dir, path) = temp_wav("pending");
            std::fs::write(&path, b"").unwrap();
            let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let (player, out) = RodioPlayer::new();
            let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let sink = Arc::new(Mutex::new(Vec::<f32>::new()));
            let drainer = spawn_drainer(out, Arc::clone(&stop), Arc::clone(&sink));
            let state = Arc::new(Mutex::new(PlayerState::default()));
            let local = PlaybackTuning::default();

            let mut pending = PendingPlay {
                track: CurrentTrack {
                    track_id: 11,
                    source: PlaySource::Growing {
                        path: path.to_string_lossy().to_string(),
                        final_path: None,
                        done: Arc::clone(&done),
                    },
                    expected_duration_ms: Some(50),
                },
                file: Some(File::open(&path).unwrap()),
                probed_len: 0,
                // 等首块期间用户按了暂停
                paused: true,
                progressed_at: Instant::now(),
            };

            // 首块还没到: 不建解码器, 也不往播放队列里塞东西
            assert!(matches!(
                attempt_pending_play(&player, &mut pending, &local, &state),
                PendingOutcome::NotReady(_)
            ));
            assert!(player.empty(), "首块没到就不能开播");
            assert!(state.lock().unwrap().track_id.is_none());

            // 首块到达(同一个 inode 被下载线程追加了整首): 重试要真的开播
            let mut bytes = wav_header(400);
            bytes.extend(std::iter::repeat_n(0u8, 800));
            std::fs::write(&path, bytes).unwrap();
            assert!(matches!(
                attempt_pending_play(&player, &mut pending, &local, &state),
                PendingOutcome::Started
            ));
            assert!(!player.empty(), "首块到达后要真的把源塞进队列");
            assert!(player.is_paused(), "等首块期间按的暂停不能被起播吞掉");
            let st = state.lock().unwrap().clone();
            assert_eq!(st.track_id, Some(11));
            assert!(!st.playing, "暂停中起播不能报在播");
            assert!(!st.seekable, "渐进期的解码器仍然不可 seek");

            stop.store(true, std::sync::atomic::Ordering::Release);
            drainer.join().unwrap();
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// 写一个完整的 16bit/mono/8kHz WAV(header + samples 个静音样本)
        fn full_wav(tag: &str, samples: usize) -> (std::path::PathBuf, std::path::PathBuf) {
            let (dir, path) = temp_wav(tag);
            let mut bytes = wav_header(samples);
            bytes.extend(std::iter::repeat_n(0u8, samples * 2));
            std::fs::write(&path, bytes).unwrap();
            (dir, path)
        }

        fn empty_chain() -> biquad::EqChain {
            biquad::EqChain::new(&ncm_domain::EqProfile::default(), 8000.0, 1)
        }

        /// EQ 包装层必须把 seek 透传给内层 decoder。
        ///
        /// `Source::try_seek` 的默认实现返回 `NotSupported`, 而 EqSource 以前没实现它,
        /// 于是**连完整落盘的文件都跳不动**(错误又被 `let _ =` 吞掉, 只是静默弹回)。
        #[test]
        fn eq_source_forwards_seek_to_seekable_decoder() {
            let (dir, path) = full_wav("eqseek", 4000);
            let decoder = Decoder::try_from(File::open(&path).unwrap()).expect("wav 应该能解");
            let mut src = EqSource::new(decoder, empty_chain());
            assert!(
                src.try_seek(Duration::from_millis(300)).is_ok(),
                "完整落盘文件必须能 seek(透传到 symphonia)"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// 对照组: 不实现 `try_seek` 的包装层只能拿到默认实现 —— 直接 NotSupported。
        ///
        /// 这就是 P-10 之前的 EqSource(以及任何自己包一层 Source 的地方):
        /// 不管内层能不能 seek, 默认实现一律报不支持。所以**透传不是可选项**。
        struct NoSeekWrapper;

        impl Iterator for NoSeekWrapper {
            type Item = Sample;

            fn next(&mut self) -> Option<Self::Item> {
                None
            }
        }

        impl Source for NoSeekWrapper {
            fn current_span_len(&self) -> Option<usize> {
                None
            }

            fn channels(&self) -> ChannelCount {
                std::num::NonZero::new(1).unwrap()
            }

            fn sample_rate(&self) -> SampleRate {
                std::num::NonZero::new(8000).unwrap()
            }

            fn total_duration(&self) -> Option<Duration> {
                None
            }
        }

        #[test]
        fn source_without_forwarding_cannot_seek() {
            let err = NoSeekWrapper
                .try_seek(Duration::from_millis(300))
                .expect_err("默认实现必然拒绝 seek");
            assert!(matches!(err, SeekError::NotSupported { .. }));
        }

        // ---- P-10 方案 B: 渐进下载完成后换源(重建可 seek 解码器) ----

        /// 造一个 16bit/mono/8kHz WAV: 前 [quiet] 个样本静音, 其余是半幅方波。
        ///
        /// 换源后"一上来就有声音"就是解码器**真的从待跳位置开始**的证据(从文件开头
        /// 开始只会有静音), 比只看 state 里的数字强得多。
        fn half_loud_wav(
            tag: &str,
            total: usize,
            quiet: usize,
        ) -> (std::path::PathBuf, std::path::PathBuf) {
            let (dir, path) = temp_wav(tag);
            let mut bytes = wav_header(total);
            for i in 0..total {
                let v: i16 = if i < quiet { 0 } else { 16_000 };
                bytes.extend_from_slice(&v.to_le_bytes());
            }
            std::fs::write(&path, bytes).unwrap();
            (dir, path)
        }

        /// 模拟声卡的混音器: 按 8kHz 的实时速率从队列抽样本。
        ///
        /// 没有声卡也能让 rodio 的暂停/位置计数/队列切换逻辑真的跑起来;
        /// 抽得比实时快会把 2s 的源瞬间播完, 就测不到"正在播的时候换源"了。
        fn spawn_drainer(
            mut out: rodio::queue::SourcesQueueOutput,
            stop: Arc<std::sync::atomic::AtomicBool>,
            sink: Arc<Mutex<Vec<f32>>>,
        ) -> std::thread::JoinHandle<()> {
            std::thread::spawn(move || {
                while !stop.load(std::sync::atomic::Ordering::Acquire) {
                    for _ in 0..160 {
                        if let Some(s) = out.next() {
                            if let Ok(mut v) = sink.lock() {
                                v.push(s);
                            }
                        }
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            })
        }

        /// ②③ 换源后位置 == 待跳位置, 且播放状态/内容都对得上。
        #[test]
        fn upgrade_applies_pending_position_and_keeps_playing() {
            // 2 秒的曲目, 前 1 秒静音: 待跳 1.2s 落在"有声音"的后半段
            let (dir, final_path) = half_loud_wav("swap", 16_000, 8_000);
            let part = dir.join("t.part");
            std::fs::copy(&final_path, &part).unwrap();
            let done = Arc::new(std::sync::atomic::AtomicBool::new(true));

            let state = Arc::new(Mutex::new(PlayerState::default()));
            let (player, out) = RodioPlayer::new();
            let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let sink = Arc::new(Mutex::new(Vec::<f32>::new()));
            let drainer = spawn_drainer(out, Arc::clone(&stop), Arc::clone(&sink));

            // 渐进期的源: 非 seekable 解码器 + 1ms 淡入(与生产路径一致)
            let growing = Decoder::builder()
                .with_data(GrowingFile::open(part.to_str().unwrap(), Arc::clone(&done)).unwrap())
                .with_seekable(false)
                .build()
                .expect("wav 应该能解");
            append_source(
                &player,
                growing,
                &PlaybackTuning::default(),
                Duration::from_millis(1),
            );
            player.play();
            let spec = CurrentTrack {
                track_id: 7,
                source: PlaySource::Growing {
                    path: part.to_string_lossy().to_string(),
                    final_path: Some(final_path.to_string_lossy().to_string()),
                    done: Arc::clone(&done),
                },
                expected_duration_ms: Some(2_000),
            };

            // 先让渐进源真的播一会儿(否则测的是"换掉一条没在播的源")
            std::thread::sleep(Duration::from_millis(120));
            let before = sink.lock().unwrap().len();
            assert!(before > 0, "渐进期的源应该在被消费");
            assert!(!player.empty(), "换源前必须还在播");

            let target_ms = 1_200;
            upgrade_to_complete(
                &player,
                &spec,
                final_path.to_str().unwrap(),
                target_ms,
                &PlaybackTuning::default(),
                &state,
            )
            .expect("完整文件应该能换源");
            std::thread::sleep(Duration::from_millis(160));

            // ② 位置 == 待跳位置(进度条不会弹回原处)
            let st = state.lock().unwrap().clone();
            assert_eq!(st.position_ms, target_ms, "换源后位置必须等于待跳位置");
            assert_eq!(st.track_id, Some(7));
            assert!(st.seekable, "换完源就是可 seek 的了");
            assert!(st.pending_seek_ms.is_none());
            assert_eq!(st.duration_ms, 2_000, "完整文件能算出真实时长");
            // rodio 的相对位置从 0 开始(基准由调用方补), 没有双重计数
            let rel = player.get_pos().as_millis();
            assert!(
                (50..600).contains(&rel),
                "相对位置应该只算了换源之后的, 实测 {rel}ms"
            );

            // ③ 播放状态不变
            assert!(!player.is_paused(), "换源不能把播放变成暂停");
            assert!(st.playing, "state 也要报在播");

            // 内容: 跳过 25ms 换源淡入后应该立刻有声音(证明从 1.2s 开始, 不是从 0)
            let samples = sink.lock().unwrap();
            let after = &samples[before.min(samples.len())..];
            assert!(
                after.iter().skip(400).take(2_400).any(|s| s.abs() > 0.1),
                "换源后必须从待跳位置(有声段)开始解码"
            );

            stop.store(true, std::sync::atomic::Ordering::Release);
            drainer.join().unwrap();
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ③ 暂停中换源不能把曲目"放"起来。
        #[test]
        fn upgrade_preserves_paused_state() {
            let (dir, final_path) = half_loud_wav("swap-paused", 16_000, 8_000);
            let part = dir.join("t.part");
            std::fs::copy(&final_path, &part).unwrap();
            let done = Arc::new(std::sync::atomic::AtomicBool::new(true));

            let state = Arc::new(Mutex::new(PlayerState::default()));
            let (player, out) = RodioPlayer::new();
            let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let sink = Arc::new(Mutex::new(Vec::<f32>::new()));
            let drainer = spawn_drainer(out, Arc::clone(&stop), Arc::clone(&sink));

            let growing = Decoder::builder()
                .with_data(GrowingFile::open(part.to_str().unwrap(), Arc::clone(&done)).unwrap())
                .with_seekable(false)
                .build()
                .expect("wav 应该能解");
            append_source(
                &player,
                growing,
                &PlaybackTuning::default(),
                Duration::from_millis(1),
            );
            player.play();
            std::thread::sleep(Duration::from_millis(60));
            player.pause();
            let spec = CurrentTrack {
                track_id: 9,
                source: PlaySource::Growing {
                    path: part.to_string_lossy().to_string(),
                    final_path: Some(final_path.to_string_lossy().to_string()),
                    done: Arc::clone(&done),
                },
                expected_duration_ms: Some(2_000),
            };

            upgrade_to_complete(
                &player,
                &spec,
                final_path.to_str().unwrap(),
                800,
                &PlaybackTuning::default(),
                &state,
            )
            .expect("完整文件应该能换源");
            std::thread::sleep(Duration::from_millis(80));

            assert!(player.is_paused(), "换源不能把暂停的曲目放起来");
            let st = state.lock().unwrap().clone();
            assert!(!st.playing);
            assert_eq!(st.position_ms, 800, "暂停时位置也要落在待跳位置上");

            stop.store(true, std::sync::atomic::Ordering::Release);
            drainer.join().unwrap();
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// 换源只在"完整文件能打开且能 seek 到目标"时才动当前播放:
        /// 文件不存在时必须原地失败, 不能把正在播的源打断。
        #[test]
        fn upgrade_keeps_current_source_when_complete_file_is_unusable() {
            let (dir, final_path) = half_loud_wav("swap-bad", 8_000, 0);
            let done = Arc::new(std::sync::atomic::AtomicBool::new(true));
            let state = Arc::new(Mutex::new(PlayerState::default()));
            let (player, out) = RodioPlayer::new();
            let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let sink = Arc::new(Mutex::new(Vec::<f32>::new()));
            let drainer = spawn_drainer(out, Arc::clone(&stop), Arc::clone(&sink));

            let growing = Decoder::builder()
                .with_data(
                    GrowingFile::open(final_path.to_str().unwrap(), Arc::clone(&done)).unwrap(),
                )
                .with_seekable(false)
                .build()
                .expect("wav 应该能解");
            append_source(
                &player,
                growing,
                &PlaybackTuning::default(),
                Duration::from_millis(1),
            );
            player.play();
            let spec = CurrentTrack {
                track_id: 3,
                source: PlaySource::File(final_path.to_string_lossy().to_string()),
                expected_duration_ms: None,
            };

            let missing = dir.join("nope.mp3");
            let err = upgrade_to_complete(
                &player,
                &spec,
                missing.to_str().unwrap(),
                500,
                &PlaybackTuning::default(),
                &state,
            )
            .expect_err("文件不存在必须报错");
            assert!(matches!(err, PlaybackError::Io(_)));
            // 当前播放没被打断: 队列里还有源, 播放态没变
            assert!(!player.empty(), "换源失败不能把正在播的源清掉");
            assert!(!player.is_paused());

            stop.store(true, std::sync::atomic::Ordering::Release);
            drainer.join().unwrap();
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// 淡入包络的单测(不需要声卡/音频设备)。
    ///
    /// 用户反馈 #3「选了淡入淡出, 听感上似乎没生效」的**可证伪判据**就在这里:
    /// 设置 fade_ms=200 时, 追加后的源前 200ms 幅度必须从 0 线性升到原值 ——
    /// 直接量样本, 不听感。桌面的淡入是**样本级**的(rodio 在源上做线性增益斜坡),
    /// 所以这段构造就是桌面真实播放的路径([`start_source`] / [`upgrade_to_complete`]
    /// 都经 [`tuned_source`])。
    #[cfg(test)]
    mod fade_tests {
        use super::*;
        use core::num::NonZero;
        use rodio::buffer::SamplesBuffer;

        const RATE: u32 = 8_000;

        /// 恒定 1.0 的源: 输出包络 = 淡入增益本身, 便于直接读幅度。
        fn const_source(samples: usize) -> SamplesBuffer {
            SamplesBuffer::new(
                NonZero::new(1u16).unwrap(),
                NonZero::new(RATE).unwrap(),
                vec![1.0 as Sample; samples],
            )
        }

        fn envelope(tuning: &PlaybackTuning, fade: Duration, samples: usize) -> Vec<Sample> {
            tuned_source(const_source(samples), tuning, fade)
                .take(samples)
                .collect()
        }

        /// 核心判据(2026-11-23 修订): **开播不淡入** —— 即使 fade_ms=200/1000,
        /// 曲目开头的包络也必须是满幅, 不能把歌曲前 1s 盖成静音。
        #[test]
        fn track_start_does_not_fade_in_even_with_long_user_fade() {
            for ms in [200u32, 1_000, 5_000] {
                let tuning = PlaybackTuning {
                    fade_ms: ms,
                    ..Default::default()
                };
                let s = envelope(&tuning, INSTANT_FADE, 64);
                // 1ms 兜底斜坡: 8kHz 下 8 个样本就得满幅, 之后全是原值
                for (i, v) in s[8..64].iter().enumerate() {
                    assert!(
                        (v - 1.0).abs() < 1e-4,
                        "fade_ms={ms} 时开播第 {i} 个样本应满幅(开播不淡入), 实测 {v}"
                    );
                }
            }
        }

        /// 用户设置的淡入真正生效的地方是**暂停恢复**: 斜坡包络由 [`ramp_scale`] 给出,
        /// 线性 0→1 over fade_ms, 结束后固化在 1.0。
        #[test]
        fn resume_ramp_goes_linearly_from_zero_to_full_over_fade_ms() {
            // 用 200ms 斜坡, 直接量比例(不依赖声卡)
            let mut ramp = Some((Instant::now(), Duration::from_millis(200)));
            assert!(ramp_scale(&mut ramp) < 0.05, "刚恢复时应接近 0");
            std::thread::sleep(Duration::from_millis(100));
            let mid = ramp_scale(&mut ramp);
            assert!(
                (mid - 0.5).abs() < 0.2,
                "半程应约 0.5, 实测 {mid}(tick 粒度允许宽松 ±0.2)"
            );
            std::thread::sleep(Duration::from_millis(130));
            assert_eq!(ramp_scale(&mut ramp), 1.0, "到时应回到满幅");
            assert!(ramp.is_none(), "斜坡结束后应被清空");
            assert_eq!(ramp_scale(&mut ramp), 1.0, "无斜坡时恒为 1.0");
        }

        /// fade_ms=0 ⇒ 恢复也不淡入(瞬时); 斜坡从未被建立。
        #[test]
        fn zero_fade_means_no_resume_ramp() {
            let mut no_ramp: Option<(Instant, Duration)> = None;
            assert_eq!(ramp_scale(&mut no_ramp), 1.0);
        }

        /// 防爆音不回归: 换源用的 [`SWAP_FADE`](25ms)即使和用户的长淡入无关, 也必须
        /// 从 0 起、25ms 内升到满幅 —— 它是"波形不连续 → 爆音"的唯一防线。
        #[test]
        fn swap_fade_still_ramps_from_silence_to_avoid_clicks() {
            let tuning = PlaybackTuning {
                fade_ms: 1_000,
                ..Default::default()
            };
            let s = envelope(&tuning, SWAP_FADE, 400);
            assert!(s[0].abs() < 1e-6, "换源后半场起点必须是 0(防爆音)");
            // 25ms = 200 个样本: 100ms 处 = 0.5, 之后满幅(换源用的是 SWAP_FADE 不是用户值)
            assert!((s[100] - 0.5).abs() < 0.01, "实测 {}", s[100]);
            for (i, v) in s[200..400].iter().enumerate() {
                assert!((v - 1.0).abs() < 1e-4, "第 {i} 个样本应满幅, 实测 {v}");
            }
        }
    }
}

// 非桌面(Android 等): 没有本地音频引擎, 播放交给平台层(Media3), 这里只保留同名 API 的桩.
// 注意必须与上面的 `any(linux, windows)` 互斥, 否则 Windows 上会同时命中两个 backend(E0428).
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
mod backend {
    use super::*;

    pub fn run(
        _rx: mpsc::Receiver<Cmd>,
        _state: Arc<Mutex<PlayerState>>,
        _tuning: Arc<Mutex<PlaybackTuning>>,
    ) {
        eprintln!("[playback] no backend for this platform (Android uses Media3)");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// P-10 方案 A 的兜底(`check_seek` / `record_seek_outcome`)仍然要**如实**工作。
    ///
    /// 方案 B 之后渐进期 seek 会先登记成待跳(见下面的 planner 测试), 只有"确定兑现
    /// 不了"的情形才走这里 —— 拒绝理由必须同时进日志与可轮询状态, 不能静默。
    #[test]
    fn check_seek_rejects_growing_source_and_records_reason() {
        // 判据来自 PlaySource 本身: File 可 seek, Growing 不可(解码器 with_seekable(false))
        assert!(PlaySource::File("/tmp/a.flac".into()).seekable());
        let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let growing = PlaySource::Growing {
            path: "/tmp/a.part".into(),
            final_path: None,
            done,
        };
        assert!(!growing.seekable());

        // 兜底拒绝: Unsupported, 且带上给用户看的原因
        let err = check_seek(growing.seekable(), 42_000).expect_err("渐进期 seek 必须被拒");
        assert!(matches!(err, PlaybackError::Unsupported(_)));
        assert!(err.to_string().contains("暂不可跳转"));

        // 失败的 seek 要在可轮询状态里留下原因(以前这里是静默的)
        let state = Mutex::new(PlayerState {
            seekable: false,
            ..Default::default()
        });
        record_seek_outcome(&state, &Err(err));
        assert!(state
            .lock()
            .unwrap()
            .seek_error
            .as_deref()
            .unwrap_or_default()
            .contains("暂不可跳转"));

        // 之后一次成功的 seek 清掉残留, 不让 UI 一直停在错误态
        record_seek_outcome(&state, &Ok(SeekOutcome::Applied));
        assert!(state.lock().unwrap().seek_error.is_none());

        // 可 seek 的源(完整落盘文件)直接放行
        assert!(check_seek(true, 42_000).is_ok());
    }

    /// P-10 方案 B ①: 渐进期 seek **先登记(『已排队』), 不是失败**; 其它档位的决策不变。
    #[test]
    fn seek_planner_queues_growing_and_directs_seekable() {
        let mut planner = SeekPlanner::new();
        assert_eq!(planner.pending(), None);

        // ① 渐进期: 登记待跳, 返回 Queue(绝不是 Err)
        let action = planner
            .request(&SourceStatus::Growing, 42_000)
            .expect("登记待跳不该失败");
        assert_eq!(action, SeekAction::Queue(42_000));
        assert_eq!(planner.pending(), Some(42_000));

        // 后到的 seek 覆盖先到的(UI 只关心"最终拖到哪")
        assert_eq!(
            planner.request(&SourceStatus::Growing, 60_000).unwrap(),
            SeekAction::Queue(60_000)
        );
        assert_eq!(planner.pending(), Some(60_000));

        // 下载完成后: 决策变成"用完整文件重建解码器, 再跳到目标"
        assert_eq!(
            planner
                .request(&SourceStatus::GrowingComplete("/tmp/a.mp3".into()), 5_000)
                .unwrap(),
            SeekAction::Rebuild(5_000)
        );
        assert_eq!(planner.pending(), None, "能立刻兑现时不留待跳");

        // ④ 没有待跳的日子一切照旧: 完整文件直接下发给 rodio
        assert_eq!(
            planner.request(&SourceStatus::Seekable, 1_000).unwrap(),
            SeekAction::Direct(1_000)
        );
        assert_eq!(planner.pending(), None);

        // 下载失败: 如实报错(不能假装排队, 否则 UI 会一直等一个永不发生的跳转)
        let err = planner
            .request(&SourceStatus::GrowingFailed, 2_000)
            .expect_err("下载失败必须报错");
        assert!(matches!(err, PlaybackError::Unsupported(_)));
        assert_eq!(planner.pending(), None);
    }

    /// 渐进源分级: 没下完 → Growing; 下完且完整文件在 → GrowingComplete;
    /// 下完但文件没了(下载失败/被清理) → GrowingFailed。
    #[test]
    fn resolve_source_status_tracks_download_completion() {
        let dir = std::env::temp_dir().join(format!(
            "ncm-status-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let part = dir.join("t.part");
        let final_path = dir.join("t.mp3");
        std::fs::write(&part, vec![0u8; 64]).unwrap();
        let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let src = PlaySource::Growing {
            path: part.to_string_lossy().to_string(),
            final_path: Some(final_path.to_string_lossy().to_string()),
            done: Arc::clone(&done),
        };

        assert_eq!(resolve_source_status(&src), SourceStatus::Growing);
        assert!(!resolve_source_status(&src).is_seekable());

        // done 已置位但完整文件还没就位(下载失败时就是这样) → 不能假装能跳
        done.store(true, std::sync::atomic::Ordering::Release);
        assert_eq!(resolve_source_status(&src), SourceStatus::GrowingFailed);

        // 完整文件就位 → 可重建
        std::fs::write(&final_path, vec![0u8; 128]).unwrap();
        assert_eq!(
            resolve_source_status(&src),
            SourceStatus::GrowingComplete(final_path.to_string_lossy().to_string())
        );
        assert!(resolve_source_status(&src).is_seekable());

        // 完整落盘文件永远是 Seekable, 行为与方案 A 之前一致
        assert_eq!(
            resolve_source_status(&PlaySource::File("/tmp/a.mp3".into())),
            SourceStatus::Seekable
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn state_starts_empty() {
        let p = Player::new();
        let s = p.state();
        assert!(!s.playing);
        assert_eq!(s.position_ms, 0);
        assert_eq!(s.volume, 1.0);
    }

    #[test]
    fn tuning_allows_loudness_boost_but_clamps_both_ends() {
        let p = Player::new();
        p.configure(PlaybackTuning {
            gain_db: 30.0,
            fade_ms: 0,
            eq: None,
            ..Default::default()
        });
        assert_eq!(p.tuning().gain_db, 12.0);
        assert!((p.tuning().gain_linear() - 3.981).abs() < 0.01);
        p.configure(PlaybackTuning {
            gain_db: -99.0,
            fade_ms: 0,
            eq: None,
            ..Default::default()
        });
        assert_eq!(p.tuning().gain_db, -40.0);
        p.configure(PlaybackTuning {
            gain_db: f32::NAN,
            fade_ms: 0,
            eq: None,
            ..Default::default()
        });
        assert_eq!(p.tuning().gain_db, 0.0);
    }

    #[test]
    fn volume_is_clamped() {
        let p = Player::new();
        p.set_volume(3.0);
        std::thread::sleep(Duration::from_millis(120));
        assert!(p.state().volume <= 1.0);
    }

    #[test]
    fn effective_volume_db_zero_gain_is_passthrough_and_clamps() {
        // 0 dB = 不变(只乘系统音量)
        assert!((effective_volume_db(0.8, 0.0) - 0.8).abs() < 1e-6);
        // -6 dB ≈ ×0.501
        assert!((effective_volume_db(1.0, -6.0) - 0.501).abs() < 0.001);
        // 正增益在系统音量满格时被钳到 1, 不引入额外削波
        assert_eq!(effective_volume_db(1.0, 12.0), 1.0);
        // 越界增益先钳再算, 与 PlaybackTuning::sanitized 口径一致
        assert_eq!(
            effective_volume_db(1.0, 99.0),
            effective_volume_db(1.0, 12.0)
        );
        assert_eq!(
            effective_volume_db(1.0, -99.0),
            effective_volume_db(1.0, -40.0)
        );
    }

    /// 后端接线的策略回归: Configure 用 step(限速逼近), Play 用 reset_to(立即到位),
    /// 系统音量(Volume)直接按限速后的当前增益算, 三者口径不打架。
    #[test]
    fn configure_slews_play_resets_and_volume_follows_applied_gain() {
        let mut limiter = agc::GainLimiter::new();
        // Configure: 目标 +9 dB, 每 200ms 一个 tick(3 dB/s ⇒ 每 tick 最多 0.6 dB)
        let mut applied = 0.0;
        for _ in 0..5 {
            applied = limiter.step(9.0, 0.2);
        }
        assert!(
            (applied - 3.0).abs() < 1e-3,
            "1 秒后只应走 3 dB, 实测 {applied}"
        );
        // Play: 换曲立即对齐目标, 不从当前值(3 dB)慢慢爬
        limiter.reset_to(9.0);
        assert_eq!(limiter.current_db(), 9.0);
        // 系统音量瞬时变化: 用限速后的当前增益直接算音量, 不触发再次逼近
        let before = effective_volume_db(0.5, limiter.current_db());
        let after = effective_volume_db(0.5, limiter.current_db());
        assert_eq!(before, after);
    }

    /// P-03: 斜率是显式配置 —— 0 = 瞬时, 3 = 按 tick 渐进, 与 Android 同口径。
    ///
    /// 桌面以前恒为 3 dB/s(没法关), Android 在静态模式下是瞬时 ⇒ 同一份设置听感不同。
    #[test]
    fn gain_slew_is_explicit_zero_instant_three_ramps() {
        // 默认值 = 老行为(3 dB/s), 未传该参数的调用方不回归
        assert_eq!(
            PlaybackTuning::default().gain_slew_db_per_sec,
            agc::DEFAULT_MAX_SLEW_DB_PER_SEC
        );

        // 静态模式: Dart 传 0 ⇒ 瞬时(滑杆拖到哪立刻生效)
        let instant = PlaybackTuning {
            gain_db: 9.0,
            gain_slew_db_per_sec: 0.0,
            ..Default::default()
        }
        .sanitized();
        assert_eq!(instant.gain_slew_db_per_sec, 0.0, "0 不能被当成未设置");
        let mut limiter = agc::GainLimiter::with_slew(instant.gain_slew_db_per_sec);
        assert_eq!(limiter.step(instant.gain_db, 0.2), 9.0);

        // 动态模式: Dart 传 3 ⇒ 每个 200ms tick 最多 0.6 dB
        let dynamic = PlaybackTuning {
            gain_db: 9.0,
            gain_slew_db_per_sec: 3.0,
            ..Default::default()
        }
        .sanitized();
        let mut limiter = agc::GainLimiter::with_slew(dynamic.gain_slew_db_per_sec);
        let mut applied = 0.0;
        for _ in 0..5 {
            applied = limiter.step(dynamic.gain_db, 0.2);
        }
        assert!(
            (applied - 3.0).abs() < 1e-3,
            "动态模式 1 秒只应走 3 dB, 实测 {applied}"
        );
        // 稳态: 慢慢逼近到目标后停住, 不来回抖
        for _ in 0..100 {
            applied = limiter.step(dynamic.gain_db, 0.2);
        }
        assert!((applied - 9.0).abs() < 1e-3);

        // 非法斜率回落默认(避免"纹丝不动的增益"这种最难查的形态)
        let bad = PlaybackTuning {
            gain_slew_db_per_sec: -1.0,
            ..Default::default()
        }
        .sanitized();
        assert_eq!(bad.gain_slew_db_per_sec, agc::DEFAULT_MAX_SLEW_DB_PER_SEC);
    }
}
