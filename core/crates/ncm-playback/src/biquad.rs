//! 二阶 IIR(biquad)滤波器与 EQ 链: 纯数学, 不依赖音频后端.
//!
//! 系数按 RBJ Audio EQ Cookbook 公式生成, 支持 AutoEQ 实际用到的三种类型
//! ([ncm_domain::EqFilterKind] 的 PK / LS / HS)。求值用转置直接 II 型
//! (Transposed Direct Form II), 每声道独立状态, 适合流式逐帧处理。

use ncm_domain::{EqFilter, EqFilterKind, EqProfile};

/// 归一化后的二阶节(a0 已除掉)
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Biquad {
    pub b0: f32,
    pub b1: f32,
    pub b2: f32,
    pub a1: f32,
    pub a2: f32,
}

/// 单个声道的滤波器状态(转置直接 II 型)
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct BiquadState {
    z1: f32,
    z2: f32,
}

impl Biquad {
    /// 峰值(peaking)滤波器: 在 f0 处抬升/下压 gain_db, Q 控制带宽
    pub fn peaking(sample_rate: f32, freq_hz: f32, gain_db: f32, q: f32) -> Self {
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = omega(sample_rate, freq_hz);
        let (sin_w0, cos_w0) = w0.sin_cos();
        let alpha = sin_w0 / (2.0 * q);
        let a0 = 1.0 + alpha / a;
        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cos_w0) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cos_w0) / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }

    /// 低架(low shelf): f0 以下整体抬升/下压 gain_db
    pub fn low_shelf(sample_rate: f32, freq_hz: f32, gain_db: f32, q: f32) -> Self {
        Self::shelf(sample_rate, freq_hz, gain_db, q, true)
    }

    /// 高架(high shelf): f0 以上整体抬升/下压 gain_db
    pub fn high_shelf(sample_rate: f32, freq_hz: f32, gain_db: f32, q: f32) -> Self {
        Self::shelf(sample_rate, freq_hz, gain_db, q, false)
    }

    /// RBJ shelf 公式(S = 1 的简化形式由 Q 表达)
    fn shelf(sample_rate: f32, freq_hz: f32, gain_db: f32, q: f32, low: bool) -> Self {
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = omega(sample_rate, freq_hz);
        let (sin_w0, cos_w0) = w0.sin_cos();
        // 斜率 S 固定为 1 时: alpha = sin(w0)/2 * sqrt(2)
        let alpha = sin_w0 / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;
        let (b0, b1, b2, a0, a1, a2) = if low {
            let sa = 2.0 * a.sqrt() * alpha;
            (
                a * ((a + 1.0) - (a - 1.0) * cos_w0 + sa),
                a * 2.0 * ((a - 1.0) - (a + 1.0) * cos_w0),
                a * ((a + 1.0) - (a - 1.0) * cos_w0 - sa),
                (a + 1.0) + (a - 1.0) * cos_w0 + sa,
                -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0),
                (a + 1.0) + (a - 1.0) * cos_w0 - sa,
            )
        } else {
            (
                a * ((a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha),
                -a * 2.0 * ((a - 1.0) + (a + 1.0) * cos_w0),
                a * ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha),
                (a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha,
                2.0 * ((a - 1.0) - (a + 1.0) * cos_w0),
                (a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha,
            )
        };
        Self {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0,
        }
    }

    /// 由 domain 的 filter 描述构造(采样率相关)
    pub fn from_filter(filter: &EqFilter, sample_rate: f32) -> Self {
        match filter.kind {
            EqFilterKind::Pk => {
                Self::peaking(sample_rate, filter.freq_hz, filter.gain_db, filter.q)
            }
            EqFilterKind::Ls => {
                Self::low_shelf(sample_rate, filter.freq_hz, filter.gain_db, filter.q)
            }
            EqFilterKind::Hs => {
                Self::high_shelf(sample_rate, filter.freq_hz, filter.gain_db, filter.q)
            }
        }
    }

    /// 处理一个样本, 就地更新状态
    #[inline]
    pub fn process(&self, state: &mut BiquadState, x: f32) -> f32 {
        let y = self.b0 * x + state.z1;
        state.z1 = self.b1 * x - self.a1 * y + state.z2;
        state.z2 = self.b2 * x - self.a2 * y;
        y
    }
}

impl BiquadState {
    #[inline]
    pub fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
}

/// 一条完整 EQ 链: 前级增益 + 各 filter 的级联, 每声道独立状态
#[derive(Debug, Clone)]
pub struct EqChain {
    preamp_gain: f32,
    stages: Vec<Biquad>,
    states: Vec<Vec<BiquadState>>,
    channels: usize,
}

impl EqChain {
    /// 按曲线与采样率构造链。OFF 的 filter 与 gain_db == 0 的 filter 会被跳过。
    pub fn new(profile: &EqProfile, sample_rate: f32, channels: usize) -> Self {
        let stages: Vec<Biquad> = profile
            .active_filters()
            .filter(|f| f.gain_db.abs() > f32::EPSILON)
            .map(|f| Biquad::from_filter(f, sample_rate))
            .collect();
        let channels = channels.max(1);
        Self {
            preamp_gain: db_to_linear(profile.preamp_db),
            states: vec![vec![BiquadState::default(); stages.len()]; channels],
            stages,
            channels,
        }
    }

    pub fn is_passthrough(&self) -> bool {
        self.stages.is_empty() && (self.preamp_gain - 1.0).abs() < f32::EPSILON
    }

    pub fn stages(&self) -> usize {
        self.stages.len()
    }

    /// 处理单个样本(流式逐样本路径: 调用方自己按声道轮转 channel)
    #[inline]
    pub fn process_sample(&mut self, channel: usize, x: f32) -> f32 {
        let c = if self.channels == 0 {
            0
        } else {
            channel % self.channels
        };
        let mut v = x * self.preamp_gain;
        for (i, stage) in self.stages.iter().enumerate() {
            v = stage.process(&mut self.states[c][i], v);
        }
        clamp_sample(v)
    }

    /// 处理一帧(交错排列的一个样本/声道), 就地写回
    #[inline]
    pub fn process_frame(&mut self, frame: &mut [f32]) {
        let ch = self.channels.min(frame.len()).max(1);
        for (c, sample) in frame.iter_mut().take(ch).enumerate() {
            let mut v = *sample * self.preamp_gain;
            for (i, stage) in self.stages.iter().enumerate() {
                v = stage.process(&mut self.states[c][i], v);
            }
            *sample = clamp_sample(v);
        }
    }
}

/// -40 dB ~ 0 dB 的增益(dB)转线性倍数
pub fn db_to_linear(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

/// 硬限幅到 [-1, 1]: EQ 的正增益可能把样本推出量程, 宁可削波也不要把噪声灌给设备
#[inline]
pub fn clamp_sample(v: f32) -> f32 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(-1.0, 1.0)
    }
}

#[inline]
fn omega(sample_rate: f32, freq_hz: f32) -> f32 {
    // 频率高于 Nyquist 时钳到 0.49*fs, 避免 tan() 溢出导致系数爆掉
    let fs = sample_rate.max(8_000.0);
    let f = freq_hz.clamp(1.0, fs * 0.49);
    std::f32::consts::TAU * f / fs
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_domain::EqProfile;

    fn rms(xs: &[f32]) -> f32 {
        (xs.iter().map(|x| x * x).sum::<f32>() / xs.len() as f32).sqrt()
    }

    /// 生成单声道正弦, 丢掉前 0.2 s(等滤波器收敛)
    fn sine_through(chain: &mut EqChain, freq: f32, fs: f32, secs: f32) -> (f32, f32) {
        let total = (fs * secs) as usize;
        let skip = (fs * 0.2) as usize;
        let mut input = Vec::with_capacity(total - skip);
        let mut output = Vec::with_capacity(total - skip);
        for i in 0..total {
            let x = (std::f32::consts::TAU * freq * i as f32 / fs).sin() * 0.5;
            let mut frame = [x];
            chain.process_frame(&mut frame);
            if i >= skip {
                input.push(x);
                output.push(frame[0]);
            }
        }
        (rms(&input), rms(&output))
    }

    #[test]
    fn peaking_boost_at_center_freq() {
        let profile = EqProfile::parse(
            "Filter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1.0
",
        )
        .unwrap();
        let mut chain = EqChain::new(&profile, 48_000.0, 1);
        let (i, o) = sine_through(&mut chain, 1000.0, 48_000.0, 1.0);
        let db = 20.0 * (o / i).log10();
        assert!((db - 6.0).abs() < 0.5, "实测增益 {db} dB, 期望 6 dB");
    }

    #[test]
    fn peaking_cut_at_center_freq() {
        let profile = EqProfile::parse(
            "Filter 1: ON PK Fc 1000 Hz Gain -9 dB Q 1.0
",
        )
        .unwrap();
        let mut chain = EqChain::new(&profile, 48_000.0, 1);
        let (i, o) = sine_through(&mut chain, 1000.0, 48_000.0, 1.0);
        let db = 20.0 * (o / i).log10();
        assert!((db + 9.0).abs() < 0.6, "实测增益 {db} dB, 期望 -9 dB");
    }

    #[test]
    fn off_filters_and_zero_gain_are_passthrough() {
        let profile = EqProfile::parse(
            "Filter 1: OFF PK Fc 1000 Hz Gain 12 dB Q 1
Filter 2: ON PK Fc 1000 Hz Gain 0 dB Q 1
",
        )
        .unwrap();
        let chain = EqChain::new(&profile, 48_000.0, 2);
        assert!(chain.is_passthrough());
        assert_eq!(chain.stages(), 0);
    }

    #[test]
    fn preamp_scales_output() {
        let profile = EqProfile::parse(
            "Preamp: -6 dB
",
        )
        .unwrap();
        let mut chain = EqChain::new(&profile, 48_000.0, 1);
        let mut frame = [0.5];
        chain.process_frame(&mut frame);
        assert!((frame[0] - 0.5 * db_to_linear(-6.0)).abs() < 1e-4);
    }

    #[test]
    fn low_shelf_boosts_bass_only() {
        let profile = EqProfile::parse(
            "Filter 1: ON LS Fc 200 Hz Gain 6 dB Q 0.7
",
        )
        .unwrap();
        let mut low = EqChain::new(&profile, 48_000.0, 1);
        let mut high = EqChain::new(&profile, 48_000.0, 1);
        let (li, lo) = sine_through(&mut low, 60.0, 48_000.0, 1.0);
        let (hi, ho) = sine_through(&mut high, 8000.0, 48_000.0, 1.0);
        let low_db = 20.0 * (lo / li).log10();
        let high_db = 20.0 * (ho / hi).log10();
        assert!(low_db > 3.0, "60 Hz 应被抬升, 实测 {low_db} dB");
        assert!(high_db.abs() < 0.5, "8 kHz 不应变化, 实测 {high_db} dB");
    }

    #[test]
    fn high_shelf_lifts_treble() {
        let profile = EqProfile::parse(
            "Filter 1: ON HS Fc 4000 Hz Gain -6 dB Q 0.7
",
        )
        .unwrap();
        let mut chain = EqChain::new(&profile, 48_000.0, 1);
        let (i, o) = sine_through(&mut chain, 12_000.0, 48_000.0, 1.0);
        let db = 20.0 * (o / i).log10();
        assert!(db < -3.0, "12 kHz 应被下压, 实测 {db} dB");
    }

    #[test]
    fn stereo_channels_have_independent_state() {
        let profile = EqProfile::parse(
            "Filter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1
",
        )
        .unwrap();
        let mut chain = EqChain::new(&profile, 48_000.0, 2);
        // 左声道给信号, 右声道静音: 右声道必须保持 0(状态不串)
        for _ in 0..4800 {
            let mut frame = [0.3, 0.0];
            chain.process_frame(&mut frame);
            assert_eq!(frame[1], 0.0);
        }
    }

    #[test]
    fn output_is_clamped() {
        let profile = EqProfile::parse(
            "Preamp: 20 dB
",
        )
        .unwrap();
        let mut chain = EqChain::new(&profile, 48_000.0, 1);
        let mut frame = [0.9];
        chain.process_frame(&mut frame);
        assert!(frame[0] <= 1.0 && frame[0] > 0.9);
    }

    #[test]
    fn clamp_handles_nan() {
        assert_eq!(clamp_sample(f32::NAN), 0.0);
        assert_eq!(clamp_sample(2.0), 1.0);
        assert_eq!(clamp_sample(-2.0), -1.0);
    }
}
