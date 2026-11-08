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

/// 一次性解码整个文件并测量。
///
/// 用 **symphonia 直接解码**(而不是 rodio 的 Decoder): 纯 Rust、无系统依赖, Linux 桌面与
/// Android 走同一份代码 —— 响度均衡(R2b)的手机端也要能出结果, 不能只依赖 Linux 后端。
/// 流式喂给 [LoudnessMeter], 内存占用与文件长度无关。
///
/// 支持的封装/编码由 ncm-playback 的 symphonia features 决定(mp3/flac/mp4-aac/wav/ogg)。
pub fn measure_file(path: &std::path::Path) -> Result<Option<LoudnessMeasurement>, String> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
    use symphonia::core::errors::Error as SymError;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let file = std::fs::File::open(path).map_err(|e| format!("open {}: {e}", path.display()))?;
    let stream = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, stream, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("probe {}: {e}", path.display()))?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| format!("no decodable track in {}", path.display()))?;
    let track_id = track.id;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("codec {}: {e}", path.display()))?;

    let mut meter: Option<LoudnessMeter> = None;
    let mut buffer: Option<SampleBuffer<f32>> = None;
    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            // 正常结束(EOF)与损坏尾部都按"测到哪算哪"处理
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymError::DecodeError(_)) => continue,
            Err(_) => break,
        };
        let spec = *decoded.spec();
        let channels = spec.channels.count();
        if channels == 0 {
            continue;
        }
        let meter = meter.get_or_insert_with(|| LoudnessMeter::new(channels, spec.rate));
        let buf = buffer.get_or_insert_with(|| {
            SampleBuffer::<f32>::new(decoded.capacity() as u64, spec)
        });
        if buf.capacity() < decoded.frames() as usize * channels {
            *buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
        }
        buf.copy_interleaved_ref(decoded);
        for frame in buf.samples().chunks_exact(channels) {
            meter.push_frame(frame);
        }
    }
    Ok(meter.and_then(|m| m.finish()))
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

    /// 写一个 16-bit PCM WAV(单声道/双声道), 用来验证 `measure_file` 的解码链路
    #[cfg(target_os = "linux")]
    fn write_wav(path: &std::path::Path, amp: f32, freq: f32, fs: u32, secs: f32, channels: u16) {
        let frames = (fs as f32 * secs) as usize;
        let data_len = frames * channels as usize * 2;
        let mut buf = Vec::with_capacity(44 + data_len);
        buf.extend_from_slice(b"RIFF");
        buf.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
        buf.extend_from_slice(b"WAVEfmt ");
        buf.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
        buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
        buf.extend_from_slice(&channels.to_le_bytes());
        buf.extend_from_slice(&fs.to_le_bytes());
        buf.extend_from_slice(&(fs * channels as u32 * 2).to_le_bytes()); // byte rate
        buf.extend_from_slice(&(channels * 2).to_le_bytes()); // block align
        buf.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
        buf.extend_from_slice(b"data");
        buf.extend_from_slice(&(data_len as u32).to_le_bytes());
        for i in 0..frames {
            let x = (std::f32::consts::TAU * freq * i as f32 / fs as f32).sin() * amp;
            let v = (x.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
            for _ in 0..channels {
                buf.extend_from_slice(&v.to_le_bytes());
            }
        }
        std::fs::write(path, buf).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn measure_file_decodes_wav_and_matches_slice_measurement() {
        let path = std::env::temp_dir().join(format!(
            "ncm-loud-wav-{}-{}.wav",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        write_wav(&path, 0.1, 1000.0, 48_000, 3.0, 2);
        let m = measure_file(&path).expect("解码+测量应成功").expect("应有测量结果");
        assert!((m.lufs + 20.0).abs() < 1.5, "实测 {} LUFS", m.lufs);
        assert!(m.sample_peak > 0.09 && m.sample_peak < 0.11);
        // 与等价的浮点切片测量结果一致(差异只来自 16-bit 量化)
        let reference = measure(&sine(0.1, 1000.0, 48_000, 3.0, 2), 2, 48_000).unwrap();
        assert!((m.lufs - reference.lufs).abs() < 0.2, "{} vs {}", m.lufs, reference.lufs);
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn measure_file_reports_missing_file() {
        assert!(measure_file(std::path::Path::new("/nonexistent/ncm.wav")).is_err());
    }

    #[test]
    fn replay_gain_follows_replaygain_2_semantics() {
        assert!((replay_gain_db(-16.0, -10.0) + 6.0).abs() < 1e-6);
        assert!((replay_gain_db(-16.0, -22.0) - 6.0).abs() < 1e-6);
        // 极端值被钳到 ±24 dB
        assert_eq!(replay_gain_db(-16.0, 20.0), -24.0);
    }
}
