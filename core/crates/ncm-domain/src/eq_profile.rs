//! AutoEQ `ParametricEQ.txt` 曲线的解析与序列化(事实标准格式, 不自造).
//!
//! 格式(AutoEQ / EqualizerAPO 子集):
//! ```text
//! Preamp: -6.0 dB
//! Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71
//! Filter 2: ON LS Fc 120 Hz Gain 2.5 dB Q 0.70
//! ```
//!
//! 约束(与任务书 docs/plan-2026-11-09-settings-and-player.md §2.2 一致):
//! - 只支持 PK / LS / HS 三种二阶滤波器(其余 LP/HP/NO 等明确报不支持);
//! - 最多 [MAX_FILTERS] 个 filter(EqualizerAPO 惯例 20);
//! - 增益(含 Preamp)必须落在 ±[MAX_GAIN_DB] dB, **超范围报错而不是静默裁剪**;
//! - Q 必填且 > 0; Fc 必须 > 0 且 <= 采样率相关上限(这里只做物理合理性检查 <= 48 kHz);
//! - 解析失败返回带 1 基行号的 [EqProfileError], UI 可以直接显示"第 N 行: 原因"。
//!
//! 这是**唯一权威实现**: Dart 侧(ui/lib/src/eq_profile.dart)只做导入时的即时校验与预览,
//! 真正生效的解析/求值都在 Rust。

use serde::{Deserialize, Serialize};

/// 最多允许的滤波器数量(EqualizerAPO 惯例)
pub const MAX_FILTERS: usize = 20;
/// 增益 / Preamp 的绝对值上限(dB)
pub const MAX_GAIN_DB: f32 = 24.0;
/// Fc 的物理上限(Hz)。AutoEQ 曲线最高频点一般 <= 20 kHz。
pub const MAX_FREQ_HZ: f32 = 48_000.0;

/// 二阶滤波器类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EqFilterKind {
    /// 峰值(peaking)
    Pk,
    /// 低架(low shelf)
    Ls,
    /// 高架(high shelf)
    Hs,
}

impl EqFilterKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EqFilterKind::Pk => "PK",
            EqFilterKind::Ls => "LS",
            EqFilterKind::Hs => "HS",
        }
    }
}

/// 一个 filter 行
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct EqFilter {
    pub kind: EqFilterKind,
    /// `ON`/`OFF`: OFF 保留在曲线里但不参与求值(保证导出往返一致)
    pub enabled: bool,
    pub freq_hz: f32,
    pub gain_db: f32,
    pub q: f32,
}

/// 一条完整的参数均衡曲线
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EqProfile {
    /// 前级增益(dB), 用来整体压低避免削波
    pub preamp_db: f32,
    pub filters: Vec<EqFilter>,
}

/// 解析错误: 1 基行号 + 原因(给用户看的短句)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EqProfileError {
    /// 1 基行号; 0 表示不是某一行的局部错误(如 filter 数量超限)
    pub line: usize,
    pub message: String,
}

impl std::fmt::Display for EqProfileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.line == 0 {
            write!(f, "{}", self.message)
        } else {
            write!(f, "第 {} 行: {}", self.line, self.message)
        }
    }
}

impl std::error::Error for EqProfileError {}

impl EqProfile {
    /// 生效的 filter(OFF 的不参与求值)
    pub fn active_filters(&self) -> impl Iterator<Item = &EqFilter> {
        self.filters.iter().filter(|f| f.enabled)
    }

    /// 总增益(前级 + 各 filter 在直流/高频端点上的近似), 用于判断是否需要额外衰减。
    /// 只做保守估计: 取所有 filter 的正增益之和 + preamp, 大于 0 时会建议再压。
    pub fn max_boost_db(&self) -> f32 {
        let sum: f32 = self.active_filters().map(|f| f.gain_db.max(0.0)).sum();
        self.preamp_db + sum
    }

    /// 解析 AutoEQ `ParametricEQ.txt` 文本(空行与 `#`/`//` 注释行忽略)
    pub fn parse(text: &str) -> Result<Self, EqProfileError> {
        let mut profile = EqProfile::default();
        let mut seen_preamp = false;
        for (idx, raw) in text.lines().enumerate() {
            let line_no = idx + 1;
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with("//") {
                continue;
            }
            let lower = line.to_ascii_lowercase();
            if lower.starts_with("preamp") {
                if seen_preamp {
                    return Err(err(line_no, "Preamp 出现了不止一次"));
                }
                seen_preamp = true;
                let value = line
                    .split_once(':')
                    .map(|(_, rest)| rest.trim())
                    .ok_or_else(|| err(line_no, "Preamp 行缺少冒号, 形如 Preamp: -6.0 dB"))?;
                profile.preamp_db = parse_number_db(value, line_no, "Preamp")?;
                check_gain(profile.preamp_db, line_no, "Preamp")?;
                continue;
            }
            if lower.starts_with("filter") {
                if profile.filters.len() >= MAX_FILTERS {
                    return Err(err(
                        line_no,
                        &format!("filter 数量超过上限 {MAX_FILTERS} 个"),
                    ));
                }
                profile.filters.push(parse_filter_line(line, line_no)?);
                continue;
            }
            return Err(err(
                line_no,
                "无法识别的行(只支持 Preamp 与 Filter N: 两种)",
            ));
        }
        Ok(profile)
    }

    /// 序列化回 AutoEQ `ParametricEQ.txt`(与输入等价, 保证 parse→to_text 幂等)
    pub fn to_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!("Preamp: {} dB\n", fmt_num(self.preamp_db)));
        for (i, f) in self.filters.iter().enumerate() {
            out.push_str(&format!(
                "Filter {}: {} {} Fc {} Hz Gain {} dB Q {}\n",
                i + 1,
                if f.enabled { "ON" } else { "OFF" },
                f.kind.as_str(),
                fmt_num(f.freq_hz),
                fmt_num(f.gain_db),
                fmt_num(f.q),
            ));
        }
        out
    }
}

fn err(line: usize, message: &str) -> EqProfileError {
    EqProfileError { line, message: message.to_string() }
}

fn check_gain(v: f32, line: usize, what: &str) -> Result<(), EqProfileError> {
    if !v.is_finite() {
        return Err(err(line, &format!("{what} 不是有效数字")));
    }
    if v.abs() > MAX_GAIN_DB {
        return Err(err(
            line,
            &format!("{what} 超出 ±{MAX_GAIN_DB} dB 范围(裁剪不静默, 请自行改到范围内)"),
        ));
    }
    Ok(())
}

/// 解析 `-3.2 dB` / `-3.2` / `105 Hz` 这类"数字 + 可选单位"
fn parse_number_db(token: &str, line: usize, what: &str) -> Result<f32, EqProfileError> {
    let mut parts = token.split_whitespace();
    let num = parts
        .next()
        .ok_or_else(|| err(line, &format!("{what} 缺少数值")))?;
    let value: f32 = num
        .parse()
        .map_err(|_| err(line, &format!("{what} 的数值 \"{num}\" 不是数字")))?;
    if let Some(unit) = parts.next() {
        let u = unit.to_ascii_lowercase();
        if u != "db" {
            return Err(err(line, &format!("{what} 的单位应为 dB, 实际是 \"{unit}\"")));
        }
    }
    Ok(value)
}

fn parse_filter_line(line: &str, line_no: usize) -> Result<EqFilter, EqProfileError> {
    let (head, rest) = line
        .split_once(':')
        .ok_or_else(|| err(line_no, "Filter 行缺少冒号, 形如 Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71"))?;
    // head = "Filter 1"
    let mut head_parts = head.split_whitespace();
    let keyword = head_parts.next().unwrap_or_default();
    if !keyword.eq_ignore_ascii_case("filter") {
        return Err(err(line_no, "Filter 行必须以 \"Filter\" 开头"));
    }
    let index = head_parts
        .next()
        .ok_or_else(|| err(line_no, "Filter 后面缺少序号(如 Filter 1:)"))?;
    if index.parse::<usize>().is_err() {
        return Err(err(line_no, &format!("Filter 序号 \"{index}\" 不是数字")));
    }

    let tokens: Vec<&str> = rest.split_whitespace().collect();
    let mut it = tokens.into_iter();
    let state = it
        .next()
        .ok_or_else(|| err(line_no, "缺少 ON/OFF"))?;
    let enabled = match state.to_ascii_uppercase().as_str() {
        "ON" => true,
        "OFF" => false,
        other => return Err(err(line_no, &format!("过滤开关应为 ON/OFF, 实际是 \"{other}\""))),
    };
    let kind_token = it.next().ok_or_else(|| err(line_no, "缺少滤波器类型(PK/LS/HS)"))?;
    let kind = match kind_token.to_ascii_uppercase().as_str() {
        "PK" => EqFilterKind::Pk,
        "LS" => EqFilterKind::Ls,
        "HS" => EqFilterKind::Hs,
        other => {
            return Err(err(
                line_no,
                &format!("不支持的滤波器类型 \"{other}\"(只支持 PK / LS / HS)"),
            ))
        }
    };

    let mut freq: Option<f32> = None;
    let mut gain: Option<f32> = None;
    let mut q: Option<f32> = None;
    while let Some(key) = it.next() {
        let lower = key.to_ascii_lowercase();
        let value = it
            .next()
            .ok_or_else(|| err(line_no, &format!("{key} 后面缺少数值")))?;
        let parsed: f32 = value
            .parse()
            .map_err(|_| err(line_no, &format!("{key} 的数值 \"{value}\" 不是数字")))?;
        match lower.as_str() {
            "fc" => {
                // 可选单位 Hz
                if let Some(unit) = it.clone().next() {
                    if unit.eq_ignore_ascii_case("hz") {
                        it.next();
                    }
                }
                freq = Some(parsed);
            }
            "gain" => {
                if let Some(unit) = it.clone().next() {
                    if unit.eq_ignore_ascii_case("db") {
                        it.next();
                    }
                }
                gain = Some(parsed);
            }
            "q" => q = Some(parsed),
            other => {
                return Err(err(
                    line_no,
                    &format!("无法识别的参数 \"{other}\"(只支持 Fc / Gain / Q)"),
                ))
            }
        }
    }

    let freq = freq.ok_or_else(|| err(line_no, "缺少 Fc(中心/转折频率)"))?;
    if !(freq.is_finite() && freq > 0.0 && freq <= MAX_FREQ_HZ) {
        return Err(err(line_no, &format!("Fc 必须在 0 < Fc <= {MAX_FREQ_HZ} Hz")));
    }
    let gain = gain.ok_or_else(|| err(line_no, "缺少 Gain"))?;
    check_gain(gain, line_no, "Gain")?;
    let q = q.ok_or_else(|| err(line_no, "缺少 Q(Q 必填且 > 0)"))?;
    if !(q.is_finite() && q > 0.0) {
        return Err(err(line_no, "Q 必须 > 0"));
    }

    Ok(EqFilter { kind, enabled, freq_hz: freq, gain_db: gain, q })
}

/// 数字格式化: 最多两位小数且去掉尾随 0, 保证 `parse(to_text(x)) == x`
fn fmt_num(v: f32) -> String {
    if v == v.trunc() && v.abs() < 1e7 {
        return format!("{}", v as i64);
    }
    let mut s = format!("{v:.2}");
    while s.ends_with('0') {
        s.pop();
    }
    if s.ends_with('.') {
        s.pop();
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "Preamp: -6.0 dB\nFilter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\nFilter 2: ON LS Fc 120 Hz Gain 2.5 dB Q 0.7\nFilter 3: OFF HS Fc 10000 Hz Gain 1.5 dB Q 0.7\n";

    #[test]
    fn parses_autoeq_sample() {
        let p = EqProfile::parse(SAMPLE).expect("应能解析");
        assert_eq!(p.preamp_db, -6.0);
        assert_eq!(p.filters.len(), 3);
        assert_eq!(p.filters[0].kind, EqFilterKind::Pk);
        assert!((p.filters[0].freq_hz - 105.0).abs() < 1e-3);
        assert_eq!(p.filters[2].enabled, false);
        assert_eq!(p.active_filters().count(), 2);
    }

    #[test]
    fn round_trip_is_idempotent() {
        let p = EqProfile::parse(SAMPLE).unwrap();
        let text = p.to_text();
        let again = EqProfile::parse(&text).expect("导出结果必须能被自己解析");
        assert_eq!(p, again, "导出文本: {text}");
    }

    #[test]
    fn missing_q_is_reported_with_line() {
        let e = EqProfile::parse("Filter 1: ON PK Fc 105 Hz Gain -3.2 dB\n").unwrap_err();
        assert_eq!(e.line, 1);
        assert!(e.message.contains('Q'), "{}", e.message);
    }

    #[test]
    fn gain_out_of_range_is_error_not_clamped() {
        let e = EqProfile::parse("Filter 1: ON PK Fc 105 Hz Gain -30 dB Q 0.7\n").unwrap_err();
        assert_eq!(e.line, 1);
        assert!(e.message.contains("24"));
    }

    #[test]
    fn more_than_max_filters_is_error() {
        let mut text = String::new();
        for i in 1..=MAX_FILTERS + 1 {
            text.push_str(&format!("Filter {i}: ON PK Fc 1000 Hz Gain 1 dB Q 0.7\n"));
        }
        let e = EqProfile::parse(&text).unwrap_err();
        assert!(e.message.contains("20"), "{}", e.message);
        assert_eq!(e.line, MAX_FILTERS + 1);
    }

    #[test]
    fn unknown_kind_is_error() {
        let e = EqProfile::parse("Filter 1: ON NO Fc 105 Hz Gain 1 dB Q 0.7\n").unwrap_err();
        assert_eq!(e.line, 1);
        assert!(e.message.contains("PK"));
    }

    #[test]
    fn non_numeric_value_is_error() {
        let e = EqProfile::parse("Filter 1: ON PK Fc abc Hz Gain 1 dB Q 0.7\n").unwrap_err();
        assert_eq!(e.line, 1);
        assert!(e.message.contains("不是数字"));
    }

    #[test]
    fn preamp_out_of_range_is_error() {
        let e = EqProfile::parse("Preamp: 30 dB\n").unwrap_err();
        assert_eq!(e.line, 1);
    }

    #[test]
    fn comments_and_blank_lines_are_ignored() {
        let text = "# AutoEQ\n\n// note\nFilter 1: ON PK Fc 100 Hz Gain 2 dB Q 1\n";
        let p = EqProfile::parse(text).unwrap();
        assert_eq!(p.filters.len(), 1);
        assert_eq!(p.preamp_db, 0.0);
    }

    #[test]
    fn max_boost_accounts_preamp() {
        let p = EqProfile::parse(SAMPLE).unwrap();
        // 正增益: 2.5(LS) + 0(被禁用的 HS 不算) => -6 + 2.5 = -3.5
        assert!((p.max_boost_db() - (-3.5)).abs() < 1e-3);
    }
}
