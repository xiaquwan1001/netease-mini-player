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

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PlayerState {
    pub track_id: Option<u64>,
    pub playing: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
}

#[derive(Debug)]
pub enum PlaybackError {
    NoBackend(String),
    Io(String),
    Decode(String),
}

impl std::fmt::Display for PlaybackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlaybackError::NoBackend(s) => write!(f, "no audio backend: {s}"),
            PlaybackError::Io(s) => write!(f, "io: {s}"),
            PlaybackError::Decode(s) => write!(f, "decode: {s}"),
        }
    }
}

impl std::error::Error for PlaybackError {}

impl From<std::io::Error> for PlaybackError {
    fn from(e: std::io::Error) -> Self {
        PlaybackError::Io(e.to_string())
    }
}

enum Cmd {
    Play { track_id: u64, path: String },
    Pause,
    Resume,
    Stop,
    Seek(u64),
    Volume(f32),
    Shutdown,
}

/// 单实例播放器: 命令进 channel, 音频线程独占输出设备.
pub struct Player {
    tx: Sender<Cmd>,
    state: Arc<Mutex<PlayerState>>,
}

impl Player {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel::<Cmd>();
        let state = Arc::new(Mutex::new(PlayerState { volume: 1.0, ..Default::default() }));
        let thread_state = Arc::clone(&state);
        std::thread::Builder::new()
            .name("ncm-audio".into())
            .spawn(move || backend::run(rx, thread_state))
            .ok();
        Self { tx, state }
    }

    pub fn play_file(&self, track_id: u64, path: impl Into<String>) {
        let _ = self.tx.send(Cmd::Play { track_id, path: path.into() });
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

    pub fn seek(&self, position_ms: u64) {
        let _ = self.tx.send(Cmd::Seek(position_ms));
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

#[cfg(target_os = "linux")]
mod backend {
    use super::*;
    use rodio::{Decoder, DeviceSinkBuilder, Player as RodioPlayer, Source};
    use std::fs::File;

    pub fn run(rx: mpsc::Receiver<Cmd>, state: Arc<Mutex<PlayerState>>) {
        // MixerDeviceSink 必须在整个线程生命周期内存活,否则声音立刻停
        let sink_handle = match DeviceSinkBuilder::open_default_sink() {
            Ok(h) => h,
            Err(e) => {
                eprintln!("[playback] no audio output: {e}");
                return;
            }
        };
        let player = RodioPlayer::connect_new(&sink_handle.mixer());
        player.set_volume(1.0);

        loop {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(Cmd::Play { track_id, path }) => {
                    // stop() 之后不可复用,换曲用 clear()
                    player.clear();
                    match File::open(&path) {
                        Ok(file) => match Decoder::try_from(file) {
                            Ok(decoder) => {
                                let duration = decoder.total_duration();
                                player.append(decoder);
                                player.play();
                                if let Ok(mut st) = state.lock() {
                                    st.track_id = Some(track_id);
                                    st.duration_ms = duration.map(|d| d.as_millis() as u64).unwrap_or(0);
                                    st.position_ms = 0;
                                    st.playing = true;
                                }
                            }
                            Err(e) => eprintln!("[playback] decode failed: {e}"),
                        },
                        Err(e) => eprintln!("[playback] open {path} failed: {e}"),
                    }
                }
                Ok(Cmd::Pause) => player.pause(),
                Ok(Cmd::Resume) => player.play(),
                Ok(Cmd::Stop) => {
                    player.clear();
                    if let Ok(mut st) = state.lock() {
                        st.playing = false;
                        st.position_ms = 0;
                        st.track_id = None;
                        st.duration_ms = 0;
                    }
                }
                Ok(Cmd::Seek(ms)) => {
                    let _ = player.try_seek(Duration::from_millis(ms));
                }
                Ok(Cmd::Volume(v)) => {
                    player.set_volume(v);
                    if let Ok(mut st) = state.lock() {
                        st.volume = v;
                    }
                }
                Ok(Cmd::Shutdown) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }

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
}

#[cfg(not(target_os = "linux"))]
mod backend {
    use super::*;

    pub fn run(_rx: mpsc::Receiver<Cmd>, _state: Arc<Mutex<PlayerState>>) {
        eprintln!("[playback] no backend for this platform (Android uses Media3)");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_starts_empty() {
        let p = Player::new();
        let s = p.state();
        assert!(!s.playing);
        assert_eq!(s.position_ms, 0);
        assert_eq!(s.volume, 1.0);
    }

    #[test]
    fn volume_is_clamped() {
        let p = Player::new();
        p.set_volume(3.0);
        std::thread::sleep(Duration::from_millis(120));
        assert!(p.state().volume <= 1.0);
    }
}
