//! B13: 逐字歌词第二来源(AMLL TTML) + 聚合回退.
//!
//! 数据流(由 LyricSourcePreference 决定):
//! - auto(默认): 给 yrc 与 TTML 打分(score_word_lyric, 纯函数), 择优并记录理由;
//!   yrc 得分 >= AUTO_SKIP_TTML_SCORE 时直接用 yrc, 不发 TTML 探测请求(省网络).
//! - netease: 只用 yrc, 缺失/退化(覆盖率 < 0.6)才 TTML.
//! - amll: 优先 TTML, 失败再 yrc.
//! - 落盘缓存: TTML 原文 dataDir/ttml/<id>.ttml, 无数据/解析失败写 <id>.none 标记,
//!   避免反复打 API; 探测经 TtmlProbe trait 走, 测试可注入假实现(不联网).
use std::error::Error as _;
use std::path::{Path, PathBuf};

use ncm_domain::{parse_ttml, TrackId, TtmlLine, WordItem, WordLyric, WordLyricLine};
use ncm_provider::{BoxFuture, Provider};

/// AMLL 官方歌词 API(按网易云曲目 id 查).
pub const AMLL_API_BASE: &str = "https://api.amll.dev/v1/lyrics/get";

/// yrc 逐字行覆盖率阈值: 有词级时间(end > start)的行占比低于此值时认为 yrc 质量差,
/// 转投 TTML. 0.6 = 至少六成行是逐字的才算合格.
pub const YRC_WORD_COVERAGE_THRESHOLD: f64 = 0.6;

/// auto 模式下 yrc 得分达到此值即直接采用, 不再探测 TTML(省一次网络请求).
pub const AUTO_SKIP_TTML_SCORE: f64 = 0.9;

/// 打分权重: 覆盖率 / 时间单调 / 首字贴行首 / 每行粒度 / 与行级 LRC 一致性.
pub const SCORE_WEIGHTS: (f64, f64, f64, f64, f64) = (0.3, 0.2, 0.15, 0.15, 0.2);

/// 时间单调判定容差(后一行允许比前一行早多少 ms 仍算单调).
pub const MONOTONIC_TOLERANCE_MS: i64 = 50;
/// 首字延迟容差: 词首与行首偏差 <= 此值算"贴行首".
pub const FIRST_WORD_TOLERANCE_MS: i64 = 80;
/// 与行级 LRC 的同句起始偏差阈值.
pub const LINE_CONSISTENCY_MS: i64 = 250;

/// 逐字歌词来源偏好.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LyricSourcePreference {
    /// 打分择优 yrc 与 TTML(默认)
    #[default]
    Auto,
    /// 只用 yrc, 缺失才 TTML
    Netease,
    /// 优先 TTML, 失败再 yrc
    Amll,
}

impl LyricSourcePreference {
    pub fn parse(s: &str) -> Self {
        match s {
            "netease" => Self::Netease,
            "amll" => Self::Amll,
            _ => Self::Auto,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Netease => "netease",
            Self::Amll => "amll",
        }
    }
}

/// HTTP 超时(AMLL 是社区公益 API, 不宜久等).
pub const FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// 逐字歌词 + 来源标记(UI 用小字展示来源, 不打扰).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LyricSource {
    /// 网易云 yrc(第一来源)
    Yrc,
    /// AMLL TTML(第二来源)
    Ttml,
    /// 行级 LRC 兜底
    LineLevel,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WordLyricWithSource {
    pub lyric: WordLyric,
    pub source: LyricSource,
    /// auto 择优时给出选择理由(短文案, 如 "yrc 时间错乱"); 其它路径为 None.
    pub reason: Option<String>,
}

/// TTML 探测接口: 生产 = 磁盘缓存 + AMLL API(CachedTtmlProbe); 测试注入假实现(不联网).
pub trait TtmlProbe: Send + Sync {
    fn probe<'a>(
        &'a self,
        data_dir: &'a Path,
        ncm_music_id: u64,
    ) -> BoxFuture<'a, Result<Option<TtmlDoc>, String>>;
}

/// 生产探测: 带磁盘缓存的 AMLL API 请求(即 fetch_ttml).
pub struct CachedTtmlProbe;

impl TtmlProbe for CachedTtmlProbe {
    fn probe<'a>(
        &'a self,
        data_dir: &'a Path,
        ncm_music_id: u64,
    ) -> BoxFuture<'a, Result<Option<TtmlDoc>, String>> {
        Box::pin(fetch_ttml(data_dir, ncm_music_id))
    }
}

/// score_word_lyric 的分项结果与总分(全部 0..1, 总分 = 加权和).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct WordLyricScore {
    /// 有词级时间的行占比
    pub coverage: f64,
    /// 相邻行首时间单调性(允许 50ms 容差)
    pub monotonic: f64,
    /// 词首与行首偏差 <= 80ms 的行占比
    pub first_word: f64,
    /// 平均每行 span(词)数 / 2, 封顶 1(过少 = 粒度差)
    pub spans: f64,
    /// 与行级 LRC 同句起始偏差 < 250ms 记 1 分的行占比; 无行级参照时记 1(中性)
    pub consistency: f64,
    /// 加权总分
    pub score: f64,
}

/// 逐字歌词质量打分(纯函数, 不联网). line_starts 为行级 LRC 各行起始 ms, 可为 None.
pub fn score_word_lyric(wl: &WordLyric, line_starts: Option<&[i64]>) -> WordLyricScore {
    let (w_cov, w_mono, w_first, w_spans, w_cons) = SCORE_WEIGHTS;
    if wl.lines.is_empty() {
        return WordLyricScore::default();
    }
    let timed: Vec<&WordLyricLine> = wl
        .lines
        .iter()
        .filter(|l| l.words.iter().any(|w| w.end_ms > w.start_ms))
        .collect();
    let coverage = timed.len() as f64 / wl.lines.len() as f64;

    let monotonic = if timed.len() <= 1 {
        1.0
    } else {
        let mut ok = 0usize;
        for pair in timed.windows(2) {
            if pair[1].start_ms >= pair[0].start_ms - MONOTONIC_TOLERANCE_MS {
                ok += 1;
            }
        }
        ok as f64 / (timed.len() - 1) as f64
    };

    let first_word = if timed.is_empty() {
        0.0
    } else {
        timed
            .iter()
            .filter(|l| (l.words[0].start_ms - l.start_ms).abs() <= FIRST_WORD_TOLERANCE_MS)
            .count() as f64
            / timed.len() as f64
    };

    let spans = if timed.is_empty() {
        0.0
    } else {
        let avg = timed.iter().map(|l| l.words.len()).sum::<usize>() as f64 / timed.len() as f64;
        (avg / 2.0).min(1.0)
    };

    let consistency = match line_starts {
        None => 1.0, // 无参照 = 中性, 不奖不罚
        Some([]) => 1.0,
        Some(starts) => {
            let hits = wl
                .lines
                .iter()
                .filter(|l| {
                    starts
                        .iter()
                        .any(|s| (l.start_ms - *s).abs() < LINE_CONSISTENCY_MS)
                })
                .count();
            hits as f64 / wl.lines.len() as f64
        }
    };

    let score = w_cov * coverage
        + w_mono * monotonic
        + w_first * first_word
        + w_spans * spans
        + w_cons * consistency;
    WordLyricScore {
        coverage,
        monotonic,
        first_word,
        spans,
        consistency,
        score,
    }
}

/// auto 择优结果: 选中来源 + 短理由(只有两来源比较后才给出).
#[derive(Debug, Clone, PartialEq)]
pub struct SourceChoice {
    pub source: Option<LyricSource>,
    pub reason: Option<String>,
}

/// auto 模式纯函数择优: 比较 yrc 与 TTML 得分, 选高者并给出可解释理由.
/// 只有一方存在时直接选它, 理由为 None(不算"择优").
pub fn choose_word_source(
    yrc: Option<&WordLyric>,
    ttml: Option<&WordLyric>,
    line_starts: Option<&[i64]>,
) -> SourceChoice {
    match (yrc, ttml) {
        (None, None) => SourceChoice {
            source: None,
            reason: None,
        },
        (Some(y), None) => SourceChoice {
            source: if y.is_empty() {
                None
            } else {
                Some(LyricSource::Yrc)
            },
            reason: None,
        },
        (None, Some(t)) => SourceChoice {
            source: if t.is_empty() {
                None
            } else {
                Some(LyricSource::Ttml)
            },
            reason: None,
        },
        (Some(y), Some(t)) => {
            let sy = score_word_lyric(y, line_starts);
            let st = score_word_lyric(t, line_starts);
            if sy.score >= st.score {
                SourceChoice {
                    source: Some(LyricSource::Yrc),
                    reason: Some("yrc 质量更优".into()),
                }
            } else {
                let reason = if sy.monotonic < 0.5 {
                    "yrc 时间错乱"
                } else if sy.coverage < YRC_WORD_COVERAGE_THRESHOLD {
                    "yrc 覆盖低"
                } else if sy.first_word < 0.5 {
                    "yrc 首字偏移"
                } else if sy.spans < st.spans {
                    "yrc 粒度差"
                } else {
                    "TTML 得分更高"
                };
                SourceChoice {
                    source: Some(LyricSource::Ttml),
                    reason: Some(reason.into()),
                }
            }
        }
    }
}

/// TTML 文档(解析结果 + 原始文本引用).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TtmlDoc {
    pub lines: Vec<TtmlLine>,
}

impl TtmlDoc {
    pub fn parse(src: &str) -> Result<Self, String> {
        Ok(Self {
            lines: parse_ttml(src)?,
        })
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }
}

/// ttml 缓存目录.
fn ttml_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("ttml")
}

fn ttml_cache_path(data_dir: &Path, id: u64) -> PathBuf {
    ttml_dir(data_dir).join(format!("{id}.ttml"))
}

fn ttml_none_path(data_dir: &Path, id: u64) -> PathBuf {
    ttml_dir(data_dir).join(format!("{id}.none"))
}

/// 逐字行覆盖率: 有词级时间(任一词 end > start)的行 / 总行数. 无行时 0.
pub fn yrc_word_coverage(wl: &WordLyric) -> f64 {
    if wl.lines.is_empty() {
        return 0.0;
    }
    let covered = wl
        .lines
        .iter()
        .filter(|l| l.words.iter().any(|w| w.end_ms > w.start_ms))
        .count();
    covered as f64 / wl.lines.len() as f64
}

/// yrc 是否"足够好"(有行、有词级时间、覆盖率达标).
fn yrc_good_enough(wl: &WordLyric) -> bool {
    !wl.is_empty() && wl.has_word_timing && yrc_word_coverage(wl) >= YRC_WORD_COVERAGE_THRESHOLD
}

/// 抓取 AMLL TTML(带磁盘缓存). 404/空/解析失败/网络错误一律不致命:
/// 404 与解析失败写 .none 标记并返回 Ok(None); 网络错误返回 Err(由调用方回退).
pub async fn fetch_ttml(data_dir: &Path, ncm_music_id: u64) -> Result<Option<TtmlDoc>, String> {
    let cache = ttml_cache_path(data_dir, ncm_music_id);
    if let Ok(text) = std::fs::read_to_string(&cache) {
        return match TtmlDoc::parse(&text) {
            Ok(doc) if !doc.is_empty() => Ok(Some(doc)),
            _ => {
                let _ = std::fs::write(ttml_none_path(data_dir, ncm_music_id), "");
                Ok(None)
            }
        };
    }
    if ttml_none_path(data_dir, ncm_music_id).exists() {
        return Ok(None); // 已知无数据, 不再打 API
    }

    let url = format!("{AMLL_API_BASE}?ncmMusicId={ncm_music_id}");
    let client = reqwest::Client::builder()
        .timeout(FETCH_TIMEOUT)
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .get(&url)
        .send()
        .await
        .map_err(|e| reqwest_chain(&e))?;
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        let _ = std::fs::write(ttml_none_path(data_dir, ncm_music_id), "");
        return Ok(None);
    }
    if !resp.status().is_success() {
        return Err(format!("amll http {}", resp.status()));
    }
    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    let ttml_text = body
        .get("data")
        .and_then(|d| d.get("lyrics"))
        .and_then(|l| l.as_str())
        .unwrap_or("");
    if ttml_text.trim().is_empty() {
        let _ = std::fs::write(ttml_none_path(data_dir, ncm_music_id), "");
        return Ok(None);
    }
    let doc = match TtmlDoc::parse(ttml_text) {
        Ok(doc) if !doc.is_empty() => doc,
        _ => {
            // 解析失败也缓存"无数据", 避免每次播放都重打 API
            let _ = std::fs::write(ttml_none_path(data_dir, ncm_music_id), "");
            return Ok(None);
        }
    };
    // 落盘缓存(原子改名, 部分写入不可见)
    let dir = ttml_dir(data_dir);
    let _ = std::fs::create_dir_all(&dir);
    let tmp = dir.join(format!("{ncm_music_id}.part"));
    if std::fs::write(&tmp, ttml_text).is_ok() {
        let _ = std::fs::rename(&tmp, &cache);
    }
    Ok(Some(doc))
}

/// reqwest 报错信息只有一句 "error sending request", 真正原因在 source 链里.
fn reqwest_chain(e: &reqwest::Error) -> String {
    let mut msg = e.to_string();
    let mut src: Option<&dyn std::error::Error> = e.source();
    while let Some(s) = src {
        msg.push_str(&format!(" <- {s}"));
        src = s.source();
    }
    msg
}

/// TtmlLine -> 逐字行(WordLyricLine).
pub fn ttml_to_word_lyric(doc: &TtmlDoc) -> WordLyric {
    let lines: Vec<WordLyricLine> = doc
        .lines
        .iter()
        .map(|l| WordLyricLine {
            start_ms: l.start_ms,
            end_ms: l.end_ms,
            words: l
                .words
                .iter()
                .map(|w| WordItem {
                    start_ms: w.start_ms,
                    end_ms: w.end_ms,
                    text: w.text.clone(),
                })
                .collect(),
        })
        .collect();
    let translation_lines = doc.lines.iter().map(|l| l.translation.clone()).collect();
    WordLyric {
        has_word_timing: !lines.is_empty(),
        lines,
        translation_lines,
        raw: None,
    }
}

/// 聚合: 按偏好解析逐字歌词(auto 打分择优 / netease yrc 优先 / amll TTML 优先),
/// 都没有则回落行级 LRC. 返回值带来源标记与择优理由; 全部失败时 Err.
/// TTML 探测经 probe 走, 测试可注入假实现(不联网).
pub async fn word_lyric_with_fallback(
    provider: &dyn Provider,
    probe: &dyn TtmlProbe,
    data_dir: &Path,
    track_id: u64,
    preference: LyricSourcePreference,
) -> Result<WordLyricWithSource, String> {
    match preference {
        LyricSourcePreference::Amll => {
            return amll_first(provider, probe, data_dir, track_id).await
        }
        LyricSourcePreference::Netease => {
            return netease_first(provider, probe, data_dir, track_id).await
        }
        LyricSourcePreference::Auto => {}
    }

    // ---- auto: 打分择优 ----
    // 1) yrc(错误/不支持都当"没有"); 得分已很高就不必请求 TTML(避免无谓网络)
    let yrc = provider.word_lyric(TrackId::new(track_id)).await.ok();
    if let Some(wl) = &yrc {
        if !wl.is_empty() && score_word_lyric(wl, None).score >= AUTO_SKIP_TTML_SCORE {
            return Ok(WordLyricWithSource {
                lyric: wl.clone(),
                source: LyricSource::Yrc,
                reason: None,
            });
        }
    }
    // 2) TTML 探测(缓存命中不联网; 网络错误/无数据都继续回退)
    let ttml = match probe.probe(data_dir, track_id).await {
        Ok(Some(doc)) => {
            let wl = ttml_to_word_lyric(&doc);
            if wl.is_empty() {
                None
            } else {
                Some(wl)
            }
        }
        _ => None,
    };
    if yrc.is_some() || ttml.is_some() {
        let choice = choose_word_source(
            yrc.as_ref().filter(|wl| !wl.is_empty()),
            ttml.as_ref(),
            None,
        );
        if let Some(source) = choice.source {
            let lyric = match source {
                LyricSource::Yrc => yrc.clone(),
                LyricSource::Ttml => ttml.clone(),
                LyricSource::LineLevel => None,
            };
            if let Some(lyric) = lyric {
                return Ok(WordLyricWithSource {
                    lyric,
                    source,
                    reason: choice.reason,
                });
            }
        }
    }
    // 3) 兜底: yrc 差但非空就用它; 否则行级 LRC
    if let Some(wl) = yrc {
        if !wl.is_empty() {
            return Ok(WordLyricWithSource {
                lyric: wl,
                source: LyricSource::Yrc,
                reason: None,
            });
        }
    }
    line_level_fallback(provider, track_id).await
}

/// netease 偏好: yrc 够好(0.6 阈值口径)直接用; 否则 TTML, 再退化 yrc, 最后行级.
async fn netease_first(
    provider: &dyn Provider,
    probe: &dyn TtmlProbe,
    data_dir: &Path,
    track_id: u64,
) -> Result<WordLyricWithSource, String> {
    let yrc = provider.word_lyric(TrackId::new(track_id)).await.ok();
    if let Some(wl) = &yrc {
        if yrc_good_enough(wl) {
            return Ok(WordLyricWithSource {
                lyric: wl.clone(),
                source: LyricSource::Yrc,
                reason: None,
            });
        }
    }
    if let Some(wl) = ttml_word_lyric(probe, data_dir, track_id).await {
        return Ok(WordLyricWithSource {
            lyric: wl,
            source: LyricSource::Ttml,
            reason: None,
        });
    }
    if let Some(wl) = yrc {
        if !wl.is_empty() {
            return Ok(WordLyricWithSource {
                lyric: wl,
                source: LyricSource::Yrc,
                reason: None,
            });
        }
    }
    line_level_fallback(provider, track_id).await
}

/// amll 偏好: TTML 优先, 失败再 yrc, 最后行级.
async fn amll_first(
    provider: &dyn Provider,
    probe: &dyn TtmlProbe,
    data_dir: &Path,
    track_id: u64,
) -> Result<WordLyricWithSource, String> {
    if let Some(wl) = ttml_word_lyric(probe, data_dir, track_id).await {
        return Ok(WordLyricWithSource {
            lyric: wl,
            source: LyricSource::Ttml,
            reason: None,
        });
    }
    if let Ok(wl) = provider.word_lyric(TrackId::new(track_id)).await {
        if !wl.is_empty() {
            return Ok(WordLyricWithSource {
                lyric: wl,
                source: LyricSource::Yrc,
                reason: None,
            });
        }
    }
    line_level_fallback(provider, track_id).await
}

/// 探测 TTML 并转成 WordLyric(空/失败 -> None).
async fn ttml_word_lyric(
    probe: &dyn TtmlProbe,
    data_dir: &Path,
    track_id: u64,
) -> Option<WordLyric> {
    let doc = probe.probe(data_dir, track_id).await.ok()??;
    let wl = ttml_to_word_lyric(&doc);
    if wl.is_empty() {
        None
    } else {
        Some(wl)
    }
}

/// 行级 LRC 兜底(与原实现一致).
async fn line_level_fallback(
    provider: &dyn Provider,
    track_id: u64,
) -> Result<WordLyricWithSource, String> {
    let lyric = provider
        .lyric(TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())?;
    if lyric.is_empty() {
        return Err("no lyrics available".to_string());
    }
    let lines = ncm_domain::parse_lrc_with_translation(
        lyric.lrc.as_deref().unwrap_or_default(),
        lyric.translated.as_deref(),
    );
    let word_lines: Vec<WordLyricLine> = lines
        .iter()
        .map(|l| WordLyricLine {
            start_ms: l.time_ms as i64,
            end_ms: l.time_ms as i64,
            words: vec![WordItem {
                start_ms: l.time_ms as i64,
                end_ms: l.time_ms as i64,
                text: l.text.clone(),
            }],
        })
        .collect();
    let translation_lines: Vec<Option<String>> = lines.into_iter().map(|l| l.sub).collect();
    Ok(WordLyricWithSource {
        lyric: WordLyric {
            lines: word_lines,
            translation_lines,
            has_word_timing: false,
            raw: None,
        },
        source: LyricSource::LineLevel,
        reason: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_domain::WordLyricLine;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("b13-ttml-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    const TTML: &str = r#"<tt><body><p begin="1.0" end="2.0"><span begin="1.0" end="1.5">你</span><span begin="1.5" end="2.0">好</span></p></body></tt>"#;

    #[test]
    fn cache_hit_reads_disk_without_network() {
        let dir = tmpdir("hit");
        std::fs::create_dir_all(dir.join("ttml")).unwrap();
        std::fs::write(dir.join("ttml/42.ttml"), TTML).unwrap();
        let doc = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(fetch_ttml(&dir, 42))
            .unwrap()
            .unwrap();
        assert_eq!(doc.lines.len(), 1);
        assert_eq!(doc.lines[0].words[0].text, "你");
        assert_eq!(doc.lines[0].words[1].text, "好");
    }

    #[test]
    fn none_marker_short_circuits() {
        let dir = tmpdir("none");
        std::fs::create_dir_all(dir.join("ttml")).unwrap();
        std::fs::write(dir.join("ttml/7.none"), "").unwrap();
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(fetch_ttml(&dir, 7))
            .unwrap();
        assert!(r.is_none());
    }

    #[test]
    fn parse_failure_of_cached_file_marks_none() {
        let dir = tmpdir("badcache");
        std::fs::create_dir_all(dir.join("ttml")).unwrap();
        std::fs::write(dir.join("ttml/9.ttml"), "<body>没有 p 标签的垃圾").unwrap();
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(fetch_ttml(&dir, 9))
            .unwrap();
        assert!(r.is_none());
        assert!(dir.join("ttml/9.none").exists());
    }

    #[test]
    fn unreachable_host_never_panics() {
        // 端口 1 必然不可达(离线安全). 走系统代理时可能被代理转成响应,
        // 所以只要求: 不 panic, 且没有数据(Ok(None) 或 Err 都算回退路径)
        let dir = tmpdir("neterr");
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(fetch_ttml(&dir, 1));
        assert!(matches!(r, Ok(None) | Err(_)), "got: {r:?}");
    }

    #[test]
    fn coverage_threshold() {
        // 2 行, 1 行有词级时间 => 0.5 < 0.6
        let wl = WordLyric {
            lines: vec![
                WordLyricLine {
                    start_ms: 0,
                    end_ms: 1000,
                    words: vec![WordItem {
                        start_ms: 0,
                        end_ms: 1000,
                        text: "逐".into(),
                    }],
                },
                WordLyricLine {
                    start_ms: 1000,
                    end_ms: 1000,
                    words: vec![WordItem {
                        start_ms: 0,
                        end_ms: 0,
                        text: "退化行".into(),
                    }],
                },
            ],
            translation_lines: vec![],
            has_word_timing: true,
            raw: None,
        };
        assert!((yrc_word_coverage(&wl) - 0.5).abs() < 1e-9);
        assert!(!yrc_good_enough(&wl));
        assert!(WordLyric::default().is_empty());
        assert!(!yrc_good_enough(&WordLyric::default()));
    }

    #[test]
    fn ttml_converts_to_word_lyric() {
        let doc = TtmlDoc::parse(TTML).unwrap();
        let wl = ttml_to_word_lyric(&doc);
        assert_eq!(wl.lines.len(), 1);
        assert_eq!(wl.lines[0].words.len(), 2);
        assert_eq!(wl.lines[0].start_ms, 1000);
        assert!(wl.has_word_timing);
    }

    #[test]
    fn fallback_to_line_level_lrc() {
        use ncm_provider::{BoxFuture, ProviderResult, SongUrlRequest};
        struct P;
        impl Provider for P {
            fn id(&self) -> &'static str {
                "dummy"
            }
            fn name(&self) -> &'static str {
                "dummy"
            }
            fn capabilities(&self) -> &'static [ncm_provider::Capability] {
                &[]
            }
            fn search<'a>(
                &'a self,
                _q: &'a ncm_provider::SearchQuery,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::SearchPage>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn song_url<'a>(
                &'a self,
                _r: &'a SongUrlRequest,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::StreamUrl>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn lyric<'a>(
                &'a self,
                _t: TrackId,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
                Box::pin(async {
                    Ok(ncm_domain::Lyric {
                        lrc: Some("[00:01.00]第一行\n[00:02.00]第二行".into()),
                        translated: None,
                        romaji: None,
                    })
                })
            }
        }
        let dir = tmpdir("linelevel");
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(word_lyric_with_fallback(
                &P,
                &CachedTtmlProbe,
                &dir,
                1,
                LyricSourcePreference::Netease,
            ))
            .unwrap();
        assert_eq!(r.source, LyricSource::LineLevel);
        assert_eq!(r.lyric.lines.len(), 2);
        assert!(!r.lyric.has_word_timing);
    }

    #[test]
    fn no_lyrics_anywhere_is_err() {
        use ncm_provider::{BoxFuture, ProviderError, ProviderResult, SongUrlRequest};
        struct P;
        impl Provider for P {
            fn id(&self) -> &'static str {
                "dummy"
            }
            fn name(&self) -> &'static str {
                "dummy"
            }
            fn capabilities(&self) -> &'static [ncm_provider::Capability] {
                &[]
            }
            fn search<'a>(
                &'a self,
                _q: &'a ncm_provider::SearchQuery,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::SearchPage>> {
                Box::pin(async { Err(ProviderError::unsupported("x")) })
            }
            fn song_url<'a>(
                &'a self,
                _r: &'a SongUrlRequest,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::StreamUrl>> {
                Box::pin(async { Err(ProviderError::unsupported("x")) })
            }
            fn lyric<'a>(
                &'a self,
                _t: TrackId,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
                Box::pin(async { Ok(ncm_domain::Lyric::default()) })
            }
        }
        let dir = tmpdir("nothing");
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(word_lyric_with_fallback(
                &P,
                &CachedTtmlProbe,
                &dir,
                1,
                LyricSourcePreference::Auto,
            ));
        assert!(r.is_err());
    }

    // ---------------- C2: 打分与择优单测 ----------------

    fn good_word_lyric(n: usize) -> WordLyric {
        WordLyric {
            lines: (0..n)
                .map(|i| WordLyricLine {
                    start_ms: (i * 1000) as i64,
                    end_ms: (i * 1000 + 900) as i64,
                    words: vec![
                        WordItem {
                            start_ms: (i * 1000) as i64,
                            end_ms: (i * 1000 + 400) as i64,
                            text: "你".into(),
                        },
                        WordItem {
                            start_ms: (i * 1000 + 400) as i64,
                            end_ms: (i * 1000 + 900) as i64,
                            text: "好".into(),
                        },
                    ],
                })
                .collect(),
            translation_lines: vec![],
            has_word_timing: true,
            raw: None,
        }
    }

    fn degenerate_word_lyric(n: usize) -> WordLyric {
        WordLyric {
            lines: (0..n)
                .map(|i| WordLyricLine {
                    start_ms: (i * 1000) as i64,
                    end_ms: (i * 1000) as i64,
                    words: vec![WordItem {
                        start_ms: 0,
                        end_ms: 0,
                        text: format!("整行{i}"),
                    }],
                })
                .collect(),
            translation_lines: vec![],
            has_word_timing: false,
            raw: None,
        }
    }

    #[test]
    fn score_full_quality_yrc_is_perfect() {
        let s = score_word_lyric(&good_word_lyric(3), None);
        assert!(s.coverage >= 0.99);
        assert!((s.monotonic - 1.0).abs() < 1e-9);
        assert!((s.score - 1.0).abs() < 1e-9, "score={}", s.score);
    }

    #[test]
    fn score_degenerate_no_word_timing_is_low() {
        let s = score_word_lyric(&degenerate_word_lyric(3), None);
        assert!(s.coverage < 0.01);
        assert!(s.first_word < 0.01);
        assert!(s.spans < 0.01);
        assert!(s.score < 0.6);
    }

    #[test]
    fn score_empty_lyric_is_zero() {
        let s = score_word_lyric(&WordLyric::default(), None);
        assert!((s.score).abs() < 1e-9);
    }

    #[test]
    fn score_yrc_coverage_high_but_times_scrambled_loses_to_ttml() {
        // 对抗样例: yrc 覆盖率高但行首时间错乱 => 单调性塌了, 应输给干净的 TTML
        let mut yrc = good_word_lyric(4);
        yrc.lines[0].start_ms = 9000;
        yrc.lines[1].start_ms = 2000;
        yrc.lines[2].start_ms = 7000;
        yrc.lines[3].start_ms = 4000;
        let ttml = good_word_lyric(4);
        let sy = score_word_lyric(&yrc, None);
        let st = score_word_lyric(&ttml, None);
        assert!(sy.monotonic < 0.5, "mono={}", sy.monotonic);
        assert!(st.score > sy.score);
        let choice = choose_word_source(Some(&yrc), Some(&ttml), None);
        assert_eq!(choice.source, Some(LyricSource::Ttml));
        assert_eq!(choice.reason.as_deref(), Some("yrc 时间错乱"));
    }

    #[test]
    fn score_yrc_low_coverage_loses_to_ttml() {
        let mut yrc = good_word_lyric(4);
        // 2/4 行退化 => 覆盖率 0.5 < 0.6
        yrc.lines[2] = WordLyricLine {
            start_ms: 2000,
            end_ms: 2000,
            words: vec![WordItem {
                start_ms: 0,
                end_ms: 0,
                text: "退化2".into(),
            }],
        };
        yrc.lines[3] = WordLyricLine {
            start_ms: 3000,
            end_ms: 3000,
            words: vec![WordItem {
                start_ms: 0,
                end_ms: 0,
                text: "退化".into(),
            }],
        };
        let ttml = good_word_lyric(4);
        let choice = choose_word_source(Some(&yrc), Some(&ttml), None);
        assert_eq!(choice.source, Some(LyricSource::Ttml));
        assert_eq!(choice.reason.as_deref(), Some("yrc 覆盖低"));
    }

    #[test]
    fn choose_keeps_yrc_when_it_scores_higher() {
        let yrc = good_word_lyric(4);
        let mut ttml = good_word_lyric(4);
        // TTML 首字全部偏离行首 500ms
        for l in ttml.lines.iter_mut() {
            l.words[0].start_ms = l.start_ms + 500;
        }
        let choice = choose_word_source(Some(&yrc), Some(&ttml), None);
        assert_eq!(choice.source, Some(LyricSource::Yrc));
        assert_eq!(choice.reason.as_deref(), Some("yrc 质量更优"));
    }

    #[test]
    fn choose_single_or_empty_source_has_no_reason() {
        let yrc = good_word_lyric(2);
        let c1 = choose_word_source(Some(&yrc), None, None);
        assert_eq!(c1.source, Some(LyricSource::Yrc));
        assert!(c1.reason.is_none());
        assert_eq!(choose_word_source(None, None, None).source, None);
        // 空的 yrc 不该被选中
        assert_eq!(
            choose_word_source(Some(&WordLyric::default()), None, None).source,
            None
        );
    }

    #[test]
    fn score_line_consistency_uses_250ms_window() {
        let yrc = good_word_lyric(2);
        let s = score_word_lyric(&yrc, Some(&[0, 1000]));
        assert!((s.consistency - 1.0).abs() < 1e-9);
        // 全部偏差 >= 400ms => 一致性 0, 总分被拉低
        let s2 = score_word_lyric(&yrc, Some(&[400, 1400]));
        assert!(s2.consistency < 0.01);
        assert!(s2.score < s.score);
    }

    #[test]
    fn auto_skips_ttml_probe_when_yrc_score_high() {
        use ncm_provider::{ProviderResult, SongUrlRequest};
        struct P;
        impl Provider for P {
            fn id(&self) -> &'static str {
                "dummy"
            }
            fn name(&self) -> &'static str {
                "dummy"
            }
            fn capabilities(&self) -> &'static [ncm_provider::Capability] {
                &[]
            }
            fn search<'a>(
                &'a self,
                _q: &'a ncm_provider::SearchQuery,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::SearchPage>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn song_url<'a>(
                &'a self,
                _r: &'a SongUrlRequest,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::StreamUrl>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn lyric<'a>(
                &'a self,
                _t: TrackId,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
                Box::pin(async { Ok(ncm_domain::Lyric::default()) })
            }
            fn word_lyric<'a>(&'a self, _t: TrackId) -> BoxFuture<'a, ProviderResult<WordLyric>> {
                Box::pin(async { Ok(good_word_lyric(3)) })
            }
        }
        struct NoProbe;
        impl TtmlProbe for NoProbe {
            fn probe<'a>(
                &'a self,
                _: &'a Path,
                _: u64,
            ) -> BoxFuture<'a, Result<Option<TtmlDoc>, String>> {
                Box::pin(async { panic!("不应探测 TTML") })
            }
        }
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(word_lyric_with_fallback(
                &P,
                &NoProbe,
                Path::new("/tmp"),
                1,
                LyricSourcePreference::Auto,
            ))
            .unwrap();
        assert_eq!(r.source, LyricSource::Yrc);
        assert!(r.reason.is_none());
    }

    #[test]
    fn preference_parse_and_netease_path() {
        assert_eq!(
            LyricSourcePreference::parse("netease"),
            LyricSourcePreference::Netease
        );
        assert_eq!(
            LyricSourcePreference::parse("amll"),
            LyricSourcePreference::Amll
        );
        assert_eq!(
            LyricSourcePreference::parse("bogus"),
            LyricSourcePreference::Auto
        );
        assert_eq!(
            LyricSourcePreference::default(),
            LyricSourcePreference::Auto
        );

        use ncm_provider::{ProviderResult, SongUrlRequest};
        struct P;
        impl Provider for P {
            fn id(&self) -> &'static str {
                "dummy"
            }
            fn name(&self) -> &'static str {
                "dummy"
            }
            fn capabilities(&self) -> &'static [ncm_provider::Capability] {
                &[]
            }
            fn search<'a>(
                &'a self,
                _q: &'a ncm_provider::SearchQuery,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::SearchPage>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn song_url<'a>(
                &'a self,
                _r: &'a SongUrlRequest,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::StreamUrl>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn lyric<'a>(
                &'a self,
                _t: TrackId,
            ) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
                Box::pin(async { Ok(ncm_domain::Lyric::default()) })
            }
        }
        // 探测返回空 doc(等价无数据); yrc 完好 => netease 直接用 yrc, 不回退行级
        struct EmptyProbe;
        impl TtmlProbe for EmptyProbe {
            fn probe<'a>(
                &'a self,
                _: &'a Path,
                _: u64,
            ) -> BoxFuture<'a, Result<Option<TtmlDoc>, String>> {
                Box::pin(async { Ok(Some(TtmlDoc { lines: vec![] })) })
            }
        }
        let dir = tmpdir("pref");
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(word_lyric_with_fallback(
                &P,
                &EmptyProbe,
                &dir,
                1,
                LyricSourcePreference::Netease,
            ));
        assert!(r.is_err(), "无 yrc 无 ttmL 无行级 => Err");
    }
}
