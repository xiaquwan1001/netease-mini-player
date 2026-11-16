//! 动态响度(AGC)增益限速器: 防 pumping 的"每步最多变多少 dB"。
//!
//! 任务书 §5 的验收口径: 动态模式限速 **<= 3 dB/s**。
//! 静态模式(默认, ReplayGain 2.0)不用这个: 每首一个常量增益, 天然没有 pumping。
//! 动态模式把"目标响度 vs 实测响度"的差当成 setpoint, 按限速逐帧逼近, 因此不会在
//! 安静段/鼓点上突然抽一下。
//!
//! 斜率是**显式配置**(P-03): 0 = 瞬时(静态模式/桌面滑杆直接跳), >0 = 按 dB/s 逼近。
//! 桌面(Linux/Windows)与 Android 用的是同一份口径: 设置页开着"动态响度"就传 3 dB/s,
//! 关着就传 0。默认值仍是 3 dB/s(= 限速器诞生以来的行为, 避免回归)。

/// 默认限速(dB/s)
pub const DEFAULT_MAX_SLEW_DB_PER_SEC: f32 = 3.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GainLimiter {
    /// 当前实际施加的增益(dB)
    current_db: f32,
    /// 最大变化速率(dB/s); **0 = 瞬时**(step 直接跳到目标, 不做限速)
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

    /// 带斜率的限速器。
    ///
    /// [max_slew_db_per_sec] = **0 ⇒ 瞬时**(不限速, 一次 step 就到位);
    /// 负数 / NaN / ∞ 属于非法值, 回落到默认 [DEFAULT_MAX_SLEW_DB_PER_SEC]。
    pub fn with_slew(max_slew_db_per_sec: f32) -> Self {
        Self {
            current_db: 0.0,
            max_slew_db_per_sec: normalize_slew(max_slew_db_per_sec),
        }
    }

    pub fn current_db(&self) -> f32 {
        self.current_db
    }

    /// 生效的最大变化速率(dB/s), 0 = 瞬时
    pub fn max_slew_db_per_sec(&self) -> f32 {
        self.max_slew_db_per_sec
    }

    /// 是否瞬时(不限速)
    pub fn is_instant(&self) -> bool {
        self.max_slew_db_per_sec == 0.0
    }

    /// 运行期改斜率(设置页切"动态响度"时用), 不改当前值 —— 从当前位置按新斜率继续逼近
    pub fn set_slew(&mut self, max_slew_db_per_sec: f32) {
        self.max_slew_db_per_sec = normalize_slew(max_slew_db_per_sec);
    }

    /// 直接把当前值设为 target(切歌/首次应用时用, 避免从 0 慢慢爬)
    pub fn reset_to(&mut self, target_db: f32) {
        self.current_db = sanitize(target_db);
    }

    /// 推进 [dt_secs] 秒, 返回这一帧应施加的增益(dB)
    ///
    /// 斜率 0(瞬时)时不看 [dt_secs], 直接把当前值对齐到目标。
    pub fn step(&mut self, target_db: f32, dt_secs: f32) -> f32 {
        let target = sanitize(target_db);
        if self.is_instant() {
            self.current_db = target;
            return self.current_db;
        }
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

/// 斜率归一化: 0 保留(瞬时), 非法值回落默认
fn normalize_slew(max_slew_db_per_sec: f32) -> f32 {
    if max_slew_db_per_sec.is_finite() && max_slew_db_per_sec >= 0.0 {
        max_slew_db_per_sec
    } else {
        DEFAULT_MAX_SLEW_DB_PER_SEC
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
        // 负数 / NaN / ∞ 是非法配置: 回落默认, 别变成"纹丝不动"
        assert_eq!(
            GainLimiter::with_slew(-5.0).max_slew_db_per_sec,
            DEFAULT_MAX_SLEW_DB_PER_SEC
        );
        assert_eq!(
            GainLimiter::with_slew(f32::NAN).max_slew_db_per_sec,
            DEFAULT_MAX_SLEW_DB_PER_SEC
        );
        assert_eq!(
            GainLimiter::with_slew(f32::INFINITY).max_slew_db_per_sec,
            DEFAULT_MAX_SLEW_DB_PER_SEC
        );
        assert_eq!(GainLimiter::with_slew(10.0).max_slew_db_per_sec, 10.0);
    }

    /// P-03: 斜率 0 = 瞬时(静态 RG2.0 / 用户拖滑杆的直感), 一步到位。
    #[test]
    fn zero_slew_is_instant() {
        let mut l = GainLimiter::with_slew(0.0);
        assert!(l.is_instant());
        assert_eq!(l.step(9.0, 0.0), 9.0, "0 斜率不看 dt, 立即到目标");
        assert_eq!(l.step(-12.0, 1e-6), -12.0);
        // 非法 dt 也照样到位(瞬时分支不看 dt)
        assert_eq!(l.step(3.0, f32::NAN), 3.0);
        assert!(!GainLimiter::new().is_instant(), "默认仍是斜坡");
    }

    /// P-03: 斜率 3 dB/s 时按 tick 推进, 200ms 一个 tick 最多走 0.6 dB。
    #[test]
    fn three_db_per_sec_ramps_per_tick() {
        let mut l = GainLimiter::with_slew(3.0);
        // 目标 +12 dB, 每 200ms 一 tick
        let steps: Vec<f32> = (0..5).map(|_| l.step(12.0, 0.2)).collect();
        for (i, v) in steps.iter().enumerate() {
            let expect = 0.6 * (i as f32 + 1.0);
            assert!(
                (v - expect).abs() < 1e-3,
                "第 {i} 个 tick 应为 {expect}, 实测 {v}"
            );
        }
        // 累计 5 个 tick(1s) = 3 dB, 这正是"1s 内最多 3 dB"的口径
        assert!((steps[4] - 3.0).abs() < 1e-3);
        // 再把 dt 拆细也不会偏离斜率(真实流逝时间累积)
        let mut l2 = GainLimiter::with_slew(3.0);
        let mut v = 0.0;
        for _ in 0..100 {
            v = l2.step(12.0, 0.01);
        }
        assert!((v - 3.0).abs() < 1e-2, "1s 细步进也应是 3 dB, 实测 {v}");
    }

    /// 运行期改斜率: 当前值保留, 从当前位置按新斜率继续(设置页切动态响度)
    #[test]
    fn set_slew_keeps_current_value() {
        let mut l = GainLimiter::with_slew(3.0);
        let v = l.step(12.0, 0.2);
        assert!((v - 0.6).abs() < 1e-3);
        l.set_slew(0.0);
        assert!(l.is_instant());
        assert!((l.current_db() - 0.6).abs() < 1e-3);
        assert_eq!(l.step(12.0, 0.2), 12.0);
        l.set_slew(-1.0); // 非法值: 回落默认
        assert_eq!(l.max_slew_db_per_sec(), DEFAULT_MAX_SLEW_DB_PER_SEC);
    }
}
