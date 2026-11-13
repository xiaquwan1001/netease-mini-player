//! 动态响度(AGC)增益限速器: 防 pumping 的"每步最多变多少 dB"。
//!
//! 任务书 §5 的验收口径: 动态模式限速 **<= 3 dB/s**。
//! 静态模式(默认, ReplayGain 2.0)不用这个: 每首一个常量增益, 天然没有 pumping。
//! 动态模式把"目标响度 vs 实测响度"的差当成 setpoint, 按限速逐帧逼近, 因此不会在
//! 安静段/鼓点上突然抽一下。

/// 默认限速(dB/s)
pub const DEFAULT_MAX_SLEW_DB_PER_SEC: f32 = 3.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GainLimiter {
    /// 当前实际施加的增益(dB)
    current_db: f32,
    /// 最大变化速率(dB/s)
    max_slew_db_per_sec: f32,
}

impl Default for GainLimiter {
    fn default() -> Self {
        Self {
            current_db: 0.0,
            max_slew_db_per_sec: DEFAULT_MAX_SLEW_DB_PER_SEC,
        }
    }
}

impl GainLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_slew(max_slew_db_per_sec: f32) -> Self {
        Self {
            current_db: 0.0,
            max_slew_db_per_sec: if max_slew_db_per_sec.is_finite() && max_slew_db_per_sec > 0.0 {
                max_slew_db_per_sec
            } else {
                DEFAULT_MAX_SLEW_DB_PER_SEC
            },
        }
    }

    pub fn current_db(&self) -> f32 {
        self.current_db
    }

    /// 直接把当前值设为 target(切歌/首次应用时用, 避免从 0 慢慢爬)
    pub fn reset_to(&mut self, target_db: f32) {
        self.current_db = sanitize(target_db);
    }

    /// 推进 [dt_secs] 秒, 返回这一帧应施加的增益(dB)
    pub fn step(&mut self, target_db: f32, dt_secs: f32) -> f32 {
        let target = sanitize(target_db);
        let dt = if dt_secs.is_finite() && dt_secs > 0.0 {
            dt_secs
        } else {
            0.0
        };
        let max_step = self.max_slew_db_per_sec * dt;
        let delta = (target - self.current_db).clamp(-max_step, max_step);
        self.current_db = sanitize(self.current_db + delta);
        self.current_db
    }

    /// 增益的线性倍数(给播放器用)
    pub fn linear(&self) -> f32 {
        10f32.powf(self.current_db / 20.0)
    }
}

fn sanitize(db: f32) -> f32 {
    if db.is_finite() {
        db.clamp(-40.0, 12.0)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slews_at_three_db_per_second_by_default() {
        let mut l = GainLimiter::new();
        // 目标 +9 dB, 每 100 ms 推进一次: 一秒内最多走 3 dB
        let mut last = 0.0;
        for _ in 0..10 {
            last = l.step(9.0, 0.1);
        }
        assert!((last - 3.0).abs() < 1e-3, "一秒后应停在 3 dB, 实测 {last}");
        for _ in 0..100 {
            last = l.step(9.0, 0.1);
        }
        assert!((last - 9.0).abs() < 1e-3, "最终应到达目标, 实测 {last}");
    }

    #[test]
    fn downward_slew_is_symmetric() {
        let mut l = GainLimiter::new();
        l.reset_to(0.0);
        let v = l.step(-30.0, 0.5);
        assert!((v + 1.5).abs() < 1e-3, "0.5 秒最多降 1.5 dB, 实测 {v}");
    }

    #[test]
    fn reset_jumps_immediately() {
        let mut l = GainLimiter::new();
        l.reset_to(-7.5);
        assert_eq!(l.current_db(), -7.5);
        assert!((l.linear() - 10f32.powf(-7.5 / 20.0)).abs() < 1e-5);
    }

    #[test]
    fn non_positive_dt_does_not_move() {
        let mut l = GainLimiter::new();
        assert_eq!(l.step(6.0, 0.0), 0.0);
        assert_eq!(l.step(6.0, -1.0), 0.0);
        assert_eq!(l.step(6.0, f32::NAN), 0.0);
    }

    #[test]
    fn target_is_clamped_to_supported_range() {
        let mut l = GainLimiter::new();
        l.reset_to(99.0);
        assert_eq!(l.current_db(), 12.0);
        l.reset_to(-99.0);
        assert_eq!(l.current_db(), -40.0);
        l.reset_to(f32::NAN);
        assert_eq!(l.current_db(), 0.0);
    }

    #[test]
    fn invalid_slew_falls_back_to_default() {
        assert_eq!(
            GainLimiter::with_slew(0.0).max_slew_db_per_sec,
            DEFAULT_MAX_SLEW_DB_PER_SEC
        );
        assert_eq!(
            GainLimiter::with_slew(-5.0).max_slew_db_per_sec,
            DEFAULT_MAX_SLEW_DB_PER_SEC
        );
        assert_eq!(GainLimiter::with_slew(10.0).max_slew_db_per_sec, 10.0);
    }
}
