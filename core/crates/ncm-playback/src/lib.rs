//! 播放抽象与 Linux 实现.
//!
//! 设计约束:
//! - core 只定义状态机与命令, 具体后端按平台实现
//! - Android 用 Media3(Kotlin), Linux 用 rodio/CPAL(纯 Rust, 无系统依赖)
//! - UI 轮询 PlayerState, 不订阅复杂回调(M0/M2 够用)

use serde::{Deserialize, Serialize};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
    /// R5 淡入: 0 / 200 / 500 / 1000 ms
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
    /// 当前源能否精确 seek。边下边播(`PlaySource::Growing`)的解码器是以
    /// `with_seekable(false)` 构建的, 这里如实报 false —— UI 据此禁用进度条并提示
    /// **缓存中, 暂不可跳转**(P-10)。
    #[serde(default)]
    pub seekable: bool,
    /// 最近一次 seek 失败的原因(None = 上次 seek 成功 / 从未 seek)。
    /// 以前这个错误被 `let _ = player.try_seek(..)` 丢掉, 现在既写日志也回传给调用方。
    #[serde(default)]
    pub seek_error: Option<String>,
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
        done: Arc<std::sync::atomic::AtomicBool>,
    },
}

impl PlaySource {
    /// 这个源能否精确 seek: **只有完整落盘的文件可以**。
    ///
    /// 边下边播的 `.part` 还在增长, 解码器以 `with_seekable(false)` 构建(否则 symphonia
    /// 会为了算时长/建索引扫全文件, 等于把「边下边播」退化成「下完再播」);
    /// rodio 对非 seekable 源的 `try_seek` 必然失败, 所以这里直接报 false,
    /// 由 `check_seek` 在命令入口如实拒绝(P-10)。
    pub fn seekable(&self) -> bool {
        matches!(self, PlaySource::File(_))
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
    Seek {
        position_ms: u64,
        reply: Option<mpsc::SyncSender<Result<(), PlaybackError>>>,
    },
    Volume(f32),
    /// 更新播放参数(增益/淡入/EQ). 增益即时生效, EQ 与淡入在下一首开始时套用
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

    /// 更新播放参数(增益/淡入/EQ)
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
    pub fn play_stream(
        &self,
        track_id: u64,
        path: impl Into<String>,
        done: Arc<std::sync::atomic::AtomicBool>,
        expected_duration_ms: Option<u64>,
    ) {
        let _ = self.tx.send(Cmd::Play {
            track_id,
            source: PlaySource::Growing {
                path: path.into(),
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

    /// seek 到 [position_ms]. **不再静默失败**: 返回 `Unsupported`(当前源不可 seek,
    /// 典型是边下边播期)或后端的其它错误, 同时由后端把原因写进
    /// `PlayerState::seek_error` 并打一条 warn 日志。
    ///
    /// 等待是**有界**的(音频线程阻塞在读数据时不会把调用方一起拖死),
    /// 超时按要求报错而不是假装成功。
    pub fn seek(&self, position_ms: u64) -> Result<(), PlaybackError> {
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

    /// 精细音量增益(dB, -40..=0), 立即作用于输出
    pub fn set_gain_db(&self, gain_db: f32) {
        let mut t = self.tuning();
        t.gain_db = gain_db;
        self.configure(t);
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
pub fn record_seek_outcome(state: &Mutex<PlayerState>, result: &Result<(), PlaybackError>) {
    match result {
        Ok(()) => {
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
        /// 无新字节的忍耐上限: 超时按结束处理, 避免下载线程挂死时把音频线程卡住
        since: Instant,
    }

    impl GrowingFile {
        fn open(path: &str, done: Arc<std::sync::atomic::AtomicBool>) -> std::io::Result<Self> {
            Ok(Self {
                file: File::open(path)?,
                done,
                since: Instant::now(),
            })
        }
    }

    impl std::io::Read for GrowingFile {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            // File 的 Read 实现直接可用(方法解析走 std::fs::File 的 inherent trait 导入链)
            loop {
                let n = self.file.read(buf)?;
                if n > 0 {
                    return Ok(n);
                }
                if self.done.load(std::sync::atomic::Ordering::Acquire) {
                    return Ok(0);
                }
                if self.since.elapsed() > Duration::from_secs(90) {
                    eprintln!("[playback] growing file stalled > 90s, stop reading");
                    return Ok(0);
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
        // EQ 链: 没有曲线时构造一条空链(纯旁路), 保持源类型固定
        let empty = ncm_domain::EqProfile::default();
        let profile = local.eq.as_ref().unwrap_or(&empty);
        let chain = biquad::EqChain::new(
            profile,
            input.sample_rate().get() as f32,
            input.channels().get() as usize,
        );
        // 淡入: 0 ms 时用 1 ms 近似"立即"(避免除零, 也顺手消除切歌爆音)
        let fade = Duration::from_millis(local.fade_ms.max(1) as u64);
        player.append(EqSource::new(input, chain).fade_in(fade));
        player.play();
        if let Ok(mut st) = state.lock() {
            st.track_id = Some(track_id);
            st.duration_ms = duration.map(|d| d.as_millis() as u64).unwrap_or(0);
            st.position_ms = 0;
            st.playing = true;
            // 源的 seek 能力随曲目一起发布给 UI(边下边播期 = false)
            st.seekable = seekable;
            st.seek_error = None;
        }
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
        // 当前曲目的 seek 能力: 由 Play 命令按 `PlaySource::seekable()` 更新,
        // Seek 命令据此在入口拒绝(不依赖 rodio 内部状态, 也不依赖演奏是否已开始)
        let mut current_seekable = false;
        player.set_volume(effective_volume_db(user_volume, limiter.current_db()));

        loop {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(Cmd::Play {
                    track_id,
                    source,
                    expected_duration_ms,
                }) => {
                    // stop() 之后不可复用,换曲用 clear()
                    player.clear();
                    current_seekable = source.seekable();
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
                                    current_seekable,
                                    &state,
                                ),
                                Err(e) => eprintln!("[playback] decode failed: {e}"),
                            },
                            Err(e) => eprintln!("[playback] open {path} failed: {e}"),
                        },
                        // 边下边播: 文件还在增长, 报告"不可 seek"以免 symphonia 为算时长扫全文件
                        PlaySource::Growing { path, done } => {
                            match GrowingFile::open(&path, done) {
                                Ok(file) => {
                                    match Decoder::builder()
                                        .with_data(file)
                                        .with_seekable(false)
                                        .build()
                                    {
                                        Ok(decoder) => start_source(
                                            &player,
                                            decoder,
                                            &local,
                                            track_id,
                                            expected_duration_ms,
                                            current_seekable,
                                            &state,
                                        ),
                                        Err(e) => {
                                            eprintln!("[playback] stream decode failed: {e}")
                                        }
                                    }
                                }
                                Err(e) => eprintln!("[playback] open {path} failed: {e}"),
                            }
                        }
                    }
                }
                Ok(Cmd::Pause) => player.pause(),
                Ok(Cmd::Resume) => player.play(),
                Ok(Cmd::Stop) => {
                    player.clear();
                    current_seekable = false;
                    if let Ok(mut st) = state.lock() {
                        st.playing = false;
                        st.position_ms = 0;
                        st.track_id = None;
                        st.duration_ms = 0;
                        st.seekable = false;
                        st.seek_error = None;
                    }
                }
                Ok(Cmd::Seek { position_ms, reply }) => {
                    // 不可 seek 的源(边下边播)在入口就拒绝: 如实返回错误而不是丢掉,
                    // 同时写进 state.seek_error / 打一条 warn 供 UI 与日志排查(P-10)。
                    let result = match check_seek(current_seekable, position_ms) {
                        Ok(()) => {
                            player
                                .try_seek(Duration::from_millis(position_ms))
                                .map_err(|e| {
                                    if matches!(&e, SeekError::NotSupported { .. }) {
                                        PlaybackError::Unsupported(e.to_string())
                                    } else {
                                        PlaybackError::Decode(e.to_string())
                                    }
                                })
                        }
                        Err(e) => Err(e),
                    };
                    record_seek_outcome(&state, &result);
                    if let Some(tx) = reply {
                        let _ = tx.send(result);
                    }
                }
                Ok(Cmd::Volume(v)) => {
                    user_volume = v;
                    // 系统音量瞬时生效(拧音量键必须立刻响应), 但增益部分仍用限速后的当前值
                    player.set_volume(effective_volume_db(user_volume, limiter.current_db()));
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
            player.set_volume(effective_volume_db(user_volume, applied_gain));

            let pos = player.get_pos().as_millis() as u64;
            let empty = player.empty();
            let paused = player.is_paused();
            if let Ok(mut st) = state.lock() {
                if st.track_id.is_some() {
                    st.position_ms = pos;
                    st.playing = !paused && !empty;
                }
            }
        }
    }

    #[cfg(test)]
    mod growing_tests {
        use super::*;
        use std::io::{Read, Write};

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

    /// P-10: 渐进播放期(Growing)的 seek 必须被**如实拒绝并记录**, 不能静默丢掉。
    #[test]
    fn check_seek_rejects_growing_source_and_records_reason() {
        // 判据来自 PlaySource 本身: File 可 seek, Growing 不可(解码器 with_seekable(false))
        assert!(PlaySource::File("/tmp/a.flac".into()).seekable());
        let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let growing = PlaySource::Growing {
            path: "/tmp/a.part".into(),
            done,
        };
        assert!(!growing.seekable());

        // 命令入口直接拒绝: Unsupported, 且带上给用户看的原因
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
        record_seek_outcome(&state, &Ok(()));
        assert!(state.lock().unwrap().seek_error.is_none());

        // 可 seek 的源(完整落盘文件)直接放行
        assert!(check_seek(true, 42_000).is_ok());
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
