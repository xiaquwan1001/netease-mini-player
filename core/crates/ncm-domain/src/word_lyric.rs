//! 逐字歌词(YRC)模型与解析: 纯函数, 只做 "文本 -> 时间轴逐字行".
//!
//! 网易云 yrc 实测形状(见 docs/b5-word-lyric-notes.md):
//! - 署名/元数据行(JSON): `{"t":0,"c":[{"tx":"作词: "},{"tx":"方文山"}]}`, t 可为负;
//! - 逐字行: `[start,dur](wStart,wDur,0)字(wStart,wDur,0)字...`, 词文本可含空格。
//!
//! 退化策略: 解析不了的行保留为 "单整词" 行(start/end=0), 绝不 panic、绝不丢行。
use serde::{Deserialize, Serialize};

/// 一个词(字)的时间与文本.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct WordItem {
    #[serde(default)]
    pub start_ms: i64,
    #[serde(default)]
    pub end_ms: i64,
    #[serde(default)]
    pub text: String,
}

/// 一行逐字歌词. 词级时间缺失(署名行等)时 words 只有一个整词.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct WordLyricLine {
    /// 行首毫秒(实测可为负, 已 clamp 到 0)
    #[serde(default)]
    pub start_ms: i64,
    /// 行尾毫秒; 无时长信息(署名行)时 = start_ms
    #[serde(default)]
    pub end_ms: i64,
    #[serde(default)]
    pub words: Vec<WordItem>,
}

/// 逐字歌词整体. `raw` 保留原始 yrc 文本(UI 层自行兜底).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WordLyric {
    #[serde(default)]
    pub lines: Vec<WordLyricLine>,
    /// 翻译行(与 lines 同序对齐, 精确匹配行首时间; 匹配不到为 None)
    #[serde(default)]
    pub translation_lines: Vec<Option<String>>,
    /// 是否真的有词级时间(全退化时为 false, UI 应回落到整行滚动)
    #[serde(default)]
    pub has_word_timing: bool,
    /// 原始 yrc 文本
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw: Option<String>,
}

impl WordLyric {
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }
}

/// 解析 yrc 文本(不带翻译).
pub fn parse_word_lyric(yrc: &str) -> WordLyric {
    parse_word_lyric_with_translation(yrc, None)
}

/// 解析 yrc 并合并翻译(普通 LRC 文本, 按行首毫秒精确对齐).
pub fn parse_word_lyric_with_translation(yrc: &str, translated: Option<&str>) -> WordLyric {
    let subs = translated.map(crate::parse_lrc).unwrap_or_default();
    let mut lines: Vec<WordLyricLine> = Vec::new();
    for raw in yrc.lines() {
        let line = raw.trim_end_matches('\r');
        if line.trim().is_empty() {
            continue;
        }
        lines.push(parse_line(line));
    }
    let has_word_timing = lines
        .iter()
        .any(|l| l.words.len() > 1 || l.words.first().is_some_and(|w| w.start_ms > 0));

    let translation_lines = lines
        .iter()
        .map(|l| {
            subs.iter()
                .find(|s| s.time_ms as i64 == l.start_ms)
                .filter(|s| !s.text.is_empty())
                .map(|s| s.text.clone())
        })
        .collect();

    WordLyric {
        lines,
        translation_lines,
        has_word_timing,
        raw: Some(yrc.to_string()),
    }
}

/// 单行解析; 任何失败都退化为 "整行一个词".
fn parse_line(line: &str) -> WordLyricLine {
    if line.starts_with('{') {
        return parse_json_meta_line(line).unwrap_or_else(|| fallback_line(line, 0));
    }
    parse_timed_line(line).unwrap_or_else(|| fallback_line(line, 0))
}

/// `{"t":<i64>,"c":[{"tx":".."},..]}` -> 行文本拼接的单词行.
fn parse_json_meta_line(line: &str) -> Option<WordLyricLine> {
    // 手写提取, domain 层不依赖 serde_json
    let t = extract_json_int(line, "t")?;
    let mut text = String::new();
    let mut rest = line;
    while let Some(pos) = find_json_key(rest, "tx") {
        let (s, after) = extract_json_string(&rest[pos..])?;
        text.push_str(&s);
        rest = after;
    }
    let t = t.max(0);
    Some(WordLyricLine {
        start_ms: t,
        end_ms: t,
        words: vec![WordItem {
            start_ms: t,
            end_ms: t,
            text,
        }],
    })
}

/// 找 "key": 的下标, 返回冒号后的位置
fn find_json_key(src: &str, key: &str) -> Option<usize> {
    let needle = format!("\"{}\":", key);
    src.find(&needle).map(|p| p + needle.len())
}

/// 在 "key": 之后提取整数(简单 JSON 子集)
fn extract_json_int(src: &str, key: &str) -> Option<i64> {
    let mut rest = src;
    while let Some(pos) = find_json_key(rest, key) {
        let tail = rest[pos..].trim_start();
        let num: String = tail
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '-')
            .collect();
        if let Ok(v) = num.parse::<i64>() {
            return Some(v);
        }
        rest = &rest[pos + 1..];
    }
    None
}

/// 从当前位置提取一个 JSON 字符串(处理转义), 返回 (内容, 剩余)
fn extract_json_string(src: &str) -> Option<(String, &str)> {
    let rest = src.trim_start();
    let after_quote = rest.strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = after_quote.char_indices();
    while let Some((i, c)) = chars.next() {
        match c {
            '"' => return Some((out, &after_quote[i + 1..])),
            '\\' => match chars.next() {
                Some((_, '"')) => out.push('"'),
                Some((_, '\\')) => out.push('\\'),
                Some((_, '/')) => out.push('/'),
                Some((_, 'n')) => out.push('\n'),
                Some((_, 't')) => out.push('\t'),
                Some((_, 'r')) => out.push('\r'),
                Some((_, 'u')) => {
                    // \uXXXX: 取后续 4 个十六进制字符
                    let mut hex = String::new();
                    for _ in 0..4 {
                        let (_, h) = chars.next()?;
                        hex.push(h);
                    }
                    if let Ok(cp) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(cp) {
                            out.push(ch);
                        }
                    }
                }
                Some((_, other)) => out.push(other),
                None => return None,
            },
            other => out.push(other),
        }
    }
    None
}

/// `[start,dur](wS,wD,0)字(wS,wD,0)字...`
fn parse_timed_line(line: &str) -> Option<WordLyricLine> {
    let rest = line.strip_prefix('[')?;
    let close = rest.find(']')?;
    let head = &rest[..close];
    let (start_s, dur_s) = head.split_once(',')?;
    let start: i64 = start_s.trim().parse().ok()?;
    let dur: i64 = dur_s.trim().parse().ok()?;
    let mut rest = &rest[close + 1..];

    let mut words: Vec<WordItem> = Vec::new();
    while let Some(after_open) = rest.strip_prefix('(') {
        let close = after_open.find(')')?;
        let timing = &after_open[..close];
        let mut parts = timing.split(',');
        let ws: i64 = parts.next()?.trim().parse().ok()?;
        let wd: i64 = parts.next()?.trim().parse().ok()?;
        // 第三元(恒 0, 语义未知)可有可无
        let _third: Option<&str> = parts.next();
        let text_start = close + 1;
        let after = &after_open[text_start..];
        // 词文本: 到下一个 '(' 或行尾
        let text_end = after.find('(').unwrap_or(after.len());
        let text = &after[..text_end];
        words.push(WordItem {
            start_ms: ws.max(0),
            end_ms: (ws + wd).max(0),
            text: text.to_string(),
        });
        rest = &after[text_end..];
    }
    if words.is_empty() {
        return None;
    }
    let start = start.max(0);
    Some(WordLyricLine {
        start_ms: start,
        end_ms: (start + dur).max(start),
        words,
    })
}

/// 退化: 整行原文一个词.
fn fallback_line(text: &str, at_ms: i64) -> WordLyricLine {
    WordLyricLine {
        start_ms: at_ms,
        end_ms: at_ms,
        words: vec![WordItem {
            start_ms: at_ms,
            end_ms: at_ms,
            text: text.to_string(),
        }],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = concat!(
        "{\"t\":0,\"c\":[{\"tx\":\"作词: \"},{\"tx\":\"方文山\"}]}\n",
        "[0,21960](0,4390,0)演(4390,4390,0)唱(8780,4390,0)：(13170,4390,0)蔡(17560,4400,0)琴\n",
        "[21960,7590](21960,470,0)让(22430,2610,0)我(25400,280,0)与(25680,640,0)你(26320,1940,0)握(28290,750,0)别\n",
        "[29550,7720](29550,490,0)再(30040,1440,0)轻(31480,460,0)轻(31940,330,0)抽(32270,690,0)出(33310,270,0)我(33580,180,0)的(33760,2980,0)手\n"
    );

    #[test]
    fn parses_real_sample() {
        let wl = parse_word_lyric(SAMPLE);
        assert_eq!(wl.lines.len(), 4);
        assert!(wl.has_word_timing);
        // 署名行: 单词, 时间 0
        assert_eq!(wl.lines[0].words.len(), 1);
        assert_eq!(wl.lines[0].words[0].text, "作词: 方文山");
        // 逐字行: 一行多词
        assert_eq!(wl.lines[2].start_ms, 21960);
        assert_eq!(wl.lines[2].end_ms, 29550);
        assert_eq!(wl.lines[2].words.len(), 6);
        assert_eq!(wl.lines[2].words[0].text, "让");
        assert_eq!(wl.lines[2].words[5].end_ms, 29040);
    }

    #[test]
    fn word_text_keeps_spaces_and_punct() {
        let wl = parse_word_lyric(
            "[25120,7400](25120,1190,0)你(28180,470,0)夏 (29400,440,0)越(29840,320,0)过",
        );
        let w = &wl.lines[0].words;
        assert_eq!(w[1].text, "夏 ");
        assert_eq!(w[2].text, "越");
    }

    #[test]
    fn negative_times_clamped() {
        let wl = parse_word_lyric("{\"t\":-1000,\"c\":[{\"tx\":\"作词\"}]}\n[-500,100](  -500,0,0)x");
        assert_eq!(wl.lines[0].start_ms, 0);
        assert_eq!(wl.lines[1].start_ms, 0);
        assert_eq!(wl.lines[1].words[0].start_ms, 0);
    }

    #[test]
    fn zero_duration_words_survive() {
        let wl = parse_word_lyric("[100,0](100,0,0)哦(100,0,0)");
        let w = &wl.lines[0].words;
        assert_eq!(w.len(), 2);
        assert_eq!(w[0].end_ms, 100);
        assert_eq!(w[1].text, "");
    }

    #[test]
    fn unparsable_line_degrades_to_single_word() {
        let wl = parse_word_lyric("这不是 yrc\n[abc,def](x,y)坏行\n[100,200](100,100,0)好");
        assert_eq!(wl.lines.len(), 3);
        assert_eq!(wl.lines[0].words[0].text, "这不是 yrc");
        assert_eq!(wl.lines[1].words[0].text, "[abc,def](x,y)坏行");
        // 第三行有合法词级头, 因此整体仍算"有词级时间"
        assert!(wl.has_word_timing);
        assert_eq!(wl.lines[2].words[0].text, "好");
    }

    #[test]
    fn missing_yrc_degrades_from_lrc_shape() {
        // 只有普通 lrc 时(行首 [mm:ss] 不是 [ms,dur] 头)逐字头解析失败 → 整词退化, 不丢行
        let wl = parse_word_lyric("[00:01.00]第一行\n[00:02.00]第二行");
        assert_eq!(wl.lines.len(), 2);
        assert_eq!(wl.lines[0].words[0].text, "[00:01.00]第一行");
        assert!(!wl.has_word_timing);
    }

    #[test]
    fn empty_input() {
        let wl = parse_word_lyric("");
        assert!(wl.is_empty());
        assert!(!wl.has_word_timing);
    }

    #[test]
    fn merges_translation_by_line_start() {
        let lrc = "[1000,500](1000,500,0)hello\n[2000,500](2000,500,0)world";
        let t = "[00:01.00]你好\n[00:02.00]地球";
        let wl = parse_word_lyric_with_translation(lrc, Some(t));
        assert_eq!(wl.translation_lines[0].as_deref(), Some("你好"));
        assert_eq!(wl.translation_lines[1].as_deref(), Some("地球"));
    }

    #[test]
    fn translation_without_match_is_none() {
        let wl = parse_word_lyric_with_translation("[1000,500](1000,500,0)hi", Some("[00:09.00]没有"));
        assert_eq!(wl.translation_lines, vec![None]);
    }
}
