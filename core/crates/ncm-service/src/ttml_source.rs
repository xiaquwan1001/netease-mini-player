//! B13: 逐字歌词第二来源(AMLL TTML) + 聚合回退.
//!
//! 数据流: 网易云 yrc 优先; yrc 无逐字或逐字覆盖率 < 0.6 时改用 AMLL TTML
//! (api.amll.dev, 实测见 docs/b13-ttml-lyrics-notes.md); 都没有则回落行级 LRC.
//! TTML 原文落盘缓存 dataDir/ttml/<id>.ttml, 无数据/解析失败写 <id>.none 标记
//! 避免反复打 API.
use std::error::Error as _;
use std::path::{Path, PathBuf};

use ncm_domain::{parse_ttml, TrackId, TtmlLine, WordItem, WordLyric, WordLyricLine};
use ncm_provider::Provider;

/// AMLL 官方歌词 API(按网易云曲目 id 查).
pub const AMLL_API_BASE: &str = "https://api.amll.dev/v1/lyrics/get";

/// yrc 逐字行覆盖率阈值: 有词级时间(end > start)的行占比低于此值时认为 yrc 质量差,
/// 转投 TTML. 0.6 = 至少六成行是逐字的才算合格.
pub const YRC_WORD_COVERAGE_THRESHOLD: f64 = 0.6;

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
}

/// TTML 文档(解析结果 + 原始文本引用).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TtmlDoc {
    pub lines: Vec<TtmlLine>,
}

impl TtmlDoc {
    pub fn parse(src: &str) -> Result<Self, String> {
        Ok(Self { lines: parse_ttml(src)? })
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
    let resp = client.get(&url).send().await.map_err(|e| reqwest_chain(&e))?;
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

/// 聚合: yrc 优先 -> TTML 第二来源 -> 行级 LRC 兜底.
/// 返回值带来源标记; 全部失败时 Err(由 UI 显示"无歌词").
pub async fn word_lyric_with_fallback(
    provider: &dyn Provider,
    data_dir: &Path,
    track_id: u64,
) -> Result<WordLyricWithSource, String> {
    // 1) yrc(错误/不支持都当"没有")
    let yrc = provider.word_lyric(TrackId::new(track_id)).await.ok();
    if let Some(wl) = &yrc {
        if yrc_good_enough(wl) {
            return Ok(WordLyricWithSource { lyric: wl.clone(), source: LyricSource::Yrc });
        }
    }
    // 2) TTML 第二来源(网络错误/无数据都继续回退)
    if let Ok(Some(doc)) = fetch_ttml(data_dir, track_id).await {
        let wl = ttml_to_word_lyric(&doc);
        if !wl.is_empty() {
            return Ok(WordLyricWithSource { lyric: wl, source: LyricSource::Ttml });
        }
    }
    // 3) 兜底: yrc 差但非空就用它; 否则行级 LRC
    if let Some(wl) = yrc {
        if !wl.is_empty() {
            return Ok(WordLyricWithSource { lyric: wl, source: LyricSource::Yrc });
        }
    }
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
        let r = tokio::runtime::Runtime::new().unwrap().block_on(fetch_ttml(&dir, 1));
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
                    words: vec![WordItem { start_ms: 0, end_ms: 1000, text: "逐".into() }],
                },
                WordLyricLine {
                    start_ms: 1000,
                    end_ms: 1000,
                    words: vec![WordItem { start_ms: 0, end_ms: 0, text: "退化行".into() }],
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
            fn id(&self) -> &'static str { "dummy" }
            fn name(&self) -> &'static str { "dummy" }
            fn capabilities(&self) -> &'static [ncm_provider::Capability] { &[] }
            fn search<'a>(&'a self, _q: &'a ncm_provider::SearchQuery) -> BoxFuture<'a, ProviderResult<ncm_domain::SearchPage>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn song_url<'a>(&'a self, _r: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<ncm_domain::StreamUrl>> {
                Box::pin(async { Err(ncm_provider::ProviderError::unsupported("x")) })
            }
            fn lyric<'a>(&'a self, _t: TrackId) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
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
            .block_on(word_lyric_with_fallback(&P, &dir, 1))
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
            fn id(&self) -> &'static str { "dummy" }
            fn name(&self) -> &'static str { "dummy" }
            fn capabilities(&self) -> &'static [ncm_provider::Capability] { &[] }
            fn search<'a>(&'a self, _q: &'a ncm_provider::SearchQuery) -> BoxFuture<'a, ProviderResult<ncm_domain::SearchPage>> {
                Box::pin(async { Err(ProviderError::unsupported("x")) })
            }
            fn song_url<'a>(&'a self, _r: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<ncm_domain::StreamUrl>> {
                Box::pin(async { Err(ProviderError::unsupported("x")) })
            }
            fn lyric<'a>(&'a self, _t: TrackId) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
                Box::pin(async { Ok(ncm_domain::Lyric::default()) })
            }
        }
        let dir = tmpdir("nothing");
        let r = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(word_lyric_with_fallback(&P, &dir, 1));
        assert!(r.is_err());
    }
}
