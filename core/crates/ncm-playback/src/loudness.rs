//! 响度测量: ITU-R BS.1770-4 / EBU R128 的 integrated loudness(LUFS).
//!
//! 为什么自己实现: 任务书要求 Linux(rodio/symphonia)与 Android(复用 Rust 结果)共用同一份测量,
//! 而 `ebur128` crate 不在离线 registry 里(`cargo build --offline` 拉不到), 依赖原生库也违反
//! "Linux 侧纯 Rust 无系统依赖"的约束。BS.1770 的 K 加权与门限都是公开公式, 自己算更可控。
//!
//! 已实现:
//! - K 加权: 高架预滤波(1681.97 Hz, +3.9998 dB, Q=0.7072) + RLB 高通(38.135 Hz, Q=0.5003),
//!   系数按实际采样率由模拟原型重算, 因此在 44.1k/48k 下都成立;
//! - 400 ms 测量窗、75% 重叠(hop 100 ms);
//! - 声道权重: L/R/C = 1.0, Ls/Rs = 1.41;
//! - 门限: 绝对 -70 LUFS, 相对 -10 LU;
//! - integrated loudness = -0.691 + 10*log10(加权均方)。
//!
//! **未做**: 4 倍过采样的 true peak(这里给的是样本峰值)。移动端音量归一化只需要 LUFS,
//! 峰值仅用于"是否可能削波"的提示, 因此记作 `sample_peak` 而不是 `true_peak`。

use crate::biquad::{Biquad, BiquadState};

/// 测量结果
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LoudnessMeasurement {
    /// integrated loudness(LUFS)
    pub lufs: f32,
    /// 样本峰值(线性, 0..1); 未做过采样, 与真空峰值有 <1 dB 的差
    pub sample_peak: f32,
    /// 通过门限的测量窗数量(0 表示整段接近静音)
    pub blocks: usize,
}

/// 绝对门限(BU.1770-4: -70 LKFS)
const ABSOLUTE_GATE_LUFS: f32 = -70.0;
/// 相对门限(BU.1770-4: -10 LU)
const RELATIVE_GATE_LU: f32 = -10.0;

/// 声道权重(顺序 L, R, C, Ls, Rs; 超出部分按 1.0 处理)
fn channel_weight(idx: usize) -> f32 {
    match idx {
        3 | 4 => 1.41,
        _ => 1.0,
    }
}

/// K 加权滤波器组(两节串联), 系数按采样率重算
pub struct KWeighting {
    pre: Biquad,
    rlb: Biquad,
    state_pre: BiquadState,
    state_rlb: BiquadState,
}

impl KWeighting {
    pub fn new(sample_rate: f32) -> Self {
        let fs = sample_rate.max(8_000.0);
        // 预滤波(高架): BS.1770-4 给出的固定参数
        let (f0, gain_db, q) = (1681.974_450_955_533, 3.999_843_853_973_347, 0.707_175_236_955_419_6);
        let k = (std::f32::consts::PI * f0 / fs).tan();
        let vh = 10f32.powf(gain_db / 20.0);
        let vb = vh.powf(0.499_666_774_154_541_6);
        let a0 = 1.0 + k / q + k * k;
        let pre = Biquad {
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2.0 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0,
        };
        // RLB 高通
        let (f0, q) = (38.135_470_876_024_44, 0.500_327_037_323_877_3);
        let k = (std::f32::consts::PI * f0 / fs).tan();
        let a0 = 1.0 + k / q + k * k;
        let rlb = Biquad {
            b0: 1.0 / a0,
            b1: -2.0 / a0,
            b2: 1.0 / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0,
        };
        Self { pre, rlb, state_pre: BiquadState::default(), state_rlb: BiquadState::default() }
    }

    #[inline]
    pub fn process(&mut self, x: f32) -> f32 {
        let y = self.pre.process(&mut self.state_pre, x);
        self.rlb.process(&mut self.state_rlb, y)
    }
}

/// 流式响度计: 逐帧喂 PCM, 内存占用与文件长度无关(Android 侧也要用, 不能整段解码)。
pub struct LoudnessMeter {
    channels: usize,
    hop: usize,
    hops_per_block: usize,
    filters: Vec<KWeighting>,
    sample_peak: f32,
    acc: f64,
    acc_len: usize,
    hop_energies: Vec<f32>,
    block_energies: Vec<f32>,
}

impl LoudnessMeter {
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let channels = channels.max(1);
        let fs = sample_rate.max(8_000);
        let block = (fs as f32 * 0.4) as usize;
        let hop = ((fs as f32 * 0.1) as usize).max(1);
        Self {
            channels,
            hop,
            hops_per_block: (block / hop).max(1),
            filters: (0..channels).map(|_| KWeighting::new(fs as f32)).collect(),
            sample_peak: 0.0,
            acc: 0.0,
            acc_len: 0,
            hop_energies: Vec::with_capacity((block / hop).max(1) + 1),
            block_energies: Vec::new(),
        }
    }

    /// 喂一帧(每声道一个样本)
    pub fn push_frame(&mut self, frame: &[f32]) {
        let mut frame_energy = 0f32;
        for c in 0..self.channels {
            let raw = frame.get(c).copied().unwrap_or(0.0);
            self.sample_peak = self.sample_peak.max(raw.abs());
            let y = self.filters[c].process(raw);
            frame_energy += channel_weight(c) * y * y;
        }
        self.acc += frame_energy as f64;
        self.acc_len += 1;
        if self.acc_len == self.hop {
            self.hop_energies.push((self.acc / self.hop as f64) as f32);
            self.acc = 0.0;
            self.acc_len = 0;
            if self.hop_energies.len() >= self.hops_per_block {
                let window_len = self.hops_per_block.min(self.hop_energies.len());
                let sum: f32 = self.hop_energies[self.hop_energies.len() - window_len..].iter().sum();
                self.block_energies.push(sum / window_len as f32);
            }
        }
    }

    /// 收尾: 应用绝对/相对门限并给出 integrated loudness
    pub fn finish(self) -> Option<LoudnessMeasurement> {
        let LoudnessMeter { block_energies, sample_peak, .. } = self;
        if block_energies.is_empty() {
            return None;
        }
        let abs_energy = lufs_to_energy(ABSOLUTE_GATE_LUFS);
        let above_abs: Vec<f32> =
            block_energies.iter().copied().filter(|e| *e > abs_energy).collect();
        if above_abs.is_empty() {
            return None;
        }
        let mean_abs = above_abs.iter().sum::<f32>() / above_abs.len() as f32;
        // 相对门限 = 平均能量低 10 LU(RELATIVE_GATE_LU 本身是负数: -10)
        let rel_gate = mean_abs * 10f32.powf(RELATIVE_GATE_LU / 10.0);
        let gated: Vec<f32> = above_abs.iter().copied().filter(|e| *e >= rel_gate).collect();
        if gated.is_empty() {
            return None;
        }
        let mean = gated.iter().sum::<f32>() / gated.len() as f32;
        let lufs = -0.691 + 10.0 * mean.log10();
        Some(LoudnessMeasurement { lufs, sample_peak, blocks: gated.len() })
    }
}

/// 测量一段交错 PCM 的 integrated loudness。样本不足 400 ms 时返回 `None`。
pub fn measure(
    samples: &[f32],
    channels: usize,
    sample_rate: u32,
) -> Option<LoudnessMeasurement> {
    let mut meter = LoudnessMeter::new(channels, sample_rate);
    let channels = channels.max(1);
    for frame in samples.chunks_exact(channels) {
        meter.push_frame(frame);
    }
    meter.finish()
}

/// 一次性解码整个文件并测量(Linux 走 rodio/symphonia; 供 CLI 与后台补测使用)
#[cfg(target_os = "linux")]
pub fn measure_file(path: &std::path::Path) -> Result<Option<LoudnessMeasurement>, String> {
    use rodio::{Decoder, Source};
    use std::fs::File;
    let file = File::open(path).map_err(|e| format!("open {}: {e}", path.display()))?;
    let decoder = Decoder::try_from(file).map_err(|e| format!("decode {}: {e}", path.display()))?;
    let channels = decoder.channels().get() as usize;
    let mut meter = LoudnessMeter::new(channels, decoder.sample_rate().get());
    let mut frame = vec![0f32; channels];
    let mut idx = 0usize;
    for sample in decoder {
        frame[idx] = sample;
        idx += 1;
        if idx == channels {
            meter.push_frame(&frame);
            idx = 0;
        }
    }
    Ok(meter.finish())
}

/// 无解码能力时的占位(Android 复用 Rust 结果需要先有可解码路径, 见任务书 S3)
#[cfg(not(target_os = "linux"))]
pub fn measure_file(_path: &std::path::Path) -> Result<Option<LoudnessMeasurement>, String> {
    Err("loudness measurement needs a decoder on this platform".to_string())
}

/// 给定曲线(如 "Filter 1: ON PK Fc 100 Hz Gain 6 dB Q 1")
/// 把这个增益(dB)转成 ReplayGain 2.0 语义的静态增益: target - measured
pub fn replay_gain_db(target_lufs: f32, measured_lufs: f32) -> f32 {
    (target_lufs - measured_lufs).clamp(-24.0, 24.0)
}

fn lufs_to_energy(lufs: f32) -> f32 {
    10f32.powf((lufs + 0.691) / 10.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(amp: f32, freq: f32, fs: u32, secs: f32, channels: usize) -> Vec<f32> {
        let frames = (fs as f32 * secs) as usize;
        let mut out = Vec::with_capacity(frames * channels);
        for i in 0..frames {
            let x = (std::f32::consts::TAU * freq * i as f32 / fs as f32).sin() * amp;
            for _ in 0..channels {
                out.push(x);
            }
        }
        out
    }

    #[test]
    fn stereo_sine_at_minus_20_dbfs_peak_is_about_minus_20_lufs() {
        // 双声道 1 kHz 正弦, 峰值幅度 0.1(-20 dBFS peak): 单声道约 -23.7 LUFS,
        // 双声道能量翻倍(+3 dB) => 约 -20.7 LUFS; K 加权在 1 kHz 附近约 +0.6 dB
        let samples = sine(0.1, 1000.0, 48_000, 3.0, 2);
        let m = measure(&samples, 2, 48_000).expect("应能量到响度");
        assert!((m.lufs + 20.0).abs() < 1.5, "实测 {} LUFS", m.lufs);
        assert_eq!(m.blocks, 27, "30 个 hop 应给出 27 个 400ms 窗");
    }

    #[test]
    fn mono_measurement_is_3lu_quieter_than_stereo() {
        let mono = measure(&sine(0.1, 1000.0, 48_000, 3.0, 1), 1, 48_000).unwrap();
        let stereo = measure(&sine(0.1, 1000.0, 48_000, 3.0, 2), 2, 48_000).unwrap();
        assert!((stereo.lufs - mono.lufs - 3.0).abs() < 0.4, "差 {}", stereo.lufs - mono.lufs);
    }

    #[test]
    fn louder_signal_measures_louder() {
        let quiet = measure(&sine(0.05, 1000.0, 48_000, 3.0, 2), 2, 48_000).unwrap();
        let loud = measure(&sine(0.5, 1000.0, 48_000, 3.0, 2), 2, 48_000).unwrap();
        assert!((loud.lufs - quiet.lufs - 20.0).abs() < 0.6, "差 {}", loud.lufs - quiet.lufs);
        assert!(loud.sample_peak > quiet.sample_peak);
    }

    #[test]
    fn silence_has_no_measurement() {
        let silence = vec![0f32; 48_000 * 2 * 2];
        assert!(measure(&silence, 2, 48_000).is_none());
    }

    #[test]
    fn too_short_input_has_no_measurement() {
        let short = sine(0.5, 1000.0, 48_000, 0.2, 2);
        assert!(measure(&short, 2, 48_000).is_none());
    }

    #[test]
    fn quiet_passage_does_not_drag_integrated_loudness() {
        // 前 2 s 很轻(-60 dBFS 量级), 后 2 s 正常: 门限应把轻的那段排除
        let mut samples = sine(0.001, 1000.0, 48_000, 2.0, 2);
        samples.extend(sine(0.5, 1000.0, 48_000, 2.0, 2));
        let m = measure(&samples, 2, 48_000).unwrap();
        assert!(m.lufs > -12.0, "实测 {} LUFS(应接近响的那段)", m.lufs);
    }

    #[test]
    fn k_weighting_attenuates_low_frequencies() {
        // 50 Hz 在 K 加权里应被明显衰减(RLB 高通)
        let low = measure(&sine(0.5, 50.0, 48_000, 3.0, 2), 2, 48_000).unwrap();
        let mid = measure(&sine(0.5, 1000.0, 48_000, 3.0, 2), 2, 48_000).unwrap();
        assert!(mid.lufs - low.lufs > 3.0, "低频应低于中频: {} vs {}", low.lufs, mid.lufs);
    }

    #[test]
    fn streaming_meter_matches_slice_api() {
        let samples = sine(0.2, 440.0, 48_000, 2.0, 2);
        let slice = measure(&samples, 2, 48_000).unwrap();
        let mut meter = LoudnessMeter::new(2, 48_000);
        for frame in samples.chunks_exact(2) {
            meter.push_frame(frame);
        }
        let streamed = meter.finish().unwrap();
        assert_eq!(slice, streamed);
    }

    #[test]
    fn replay_gain_follows_replaygain_2_semantics() {
        assert!((replay_gain_db(-16.0, -10.0) + 6.0).abs() < 1e-6);
        assert!((replay_gain_db(-16.0, -22.0) - 6.0).abs() < 1e-6);
        // 极端值被钳到 ±24 dB
        assert_eq!(replay_gain_db(-16.0, 20.0), -24.0);
    }
}
