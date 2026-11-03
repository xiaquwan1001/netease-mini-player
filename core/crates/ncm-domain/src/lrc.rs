//! LRC 歌词解析: 纯函数, 只做"文本 -> 时间轴行".
//!
//! 支持的写法(网易云实际返回的都在里面):
//! - `[mm:ss.xx]文本` / `[mm:ss.xxx]` / `[mm:ss]` / `[mm:ss:xx]`
//! - 一行多个时间标签: `[00:01.00][00:05.00]文本`
//! - 头部元信息 `[ar:]` `[ti:]` `[by:]` `[offset:±ms]` 不进入歌词行;
//!   `offset` 会整体位移时间轴(正数 = 歌词提前)。
//! 解析不了的行直接丢弃, 不报错: 歌词是"有则更好"的数据。

/// 一行歌词. `sub` 是翻译(网易云 `tlyric`), 按时间戳对齐。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LyricLine {
    pub time_ms: u64,
    pub text: String,
    pub sub: Option<String>,
}

impl LyricLine {
    pub fn new(time_ms: u64, text: impl Into<String>) -> Self {
        Self { time_ms, text: text.into(), sub: None }
    }
}

/// 解析 LRC 文本(不带翻译)
pub fn parse_lrc(src: &str) -> Vec<LyricLine> {
    parse_lrc_with_translation(src, None)
}

/// 解析 LRC 并合并翻译: 按 `time_ms` 精确匹配, 匹配不到就留 `None`。
pub fn parse_lrc_with_translation(src: &str, translated: Option<&str>) -> Vec<LyricLine> {
    let mut lines = parse_single(src);
    if let Some(translated) = translated {
        let subs = parse_single(translated);
        if !subs.is_empty() {
            for line in lines.iter_mut() {
                if let Some(found) = subs.iter().find(|s| s.time_ms == line.time_ms) {
                    let text = found.text.trim();
                    if !text.is_empty() && text != line.text {
                        line.sub = Some(text.to_string());
                    }
                }
            }
        }
    }
    lines
}

fn parse_single(src: &str) -> Vec<LyricLine> {
    let mut offset_ms: i64 = 0;
    let mut out: Vec<LyricLine> = Vec::new();

    for raw in src.lines() {
        let line = raw.trim_end_matches('\r');
        let mut rest = line.trim_start();
        let mut stamps: Vec<u64> = Vec::new();

        // 逐个吃掉开头的 [..] 标签
        while let Some(after_open) = rest.strip_prefix('[') {
            let Some(close) = after_open.find(']') else { break };
            let tag = &after_open[..close];
            rest = &after_open[close + 1..];
            if let Some(ms) = parse_time_tag(tag) {
                stamps.push(ms);
            } else if let Some(v) = tag.strip_prefix("offset:") {
                if let Ok(parsed) = v.trim().parse::<i64>() {
                    offset_ms = parsed;
                }
            }
            // 其余标签(ar/ti/by/al/...)忽略
        }

        if stamps.is_empty() {
            continue;
        }
        let text = rest.trim();
        for ms in stamps {
            out.push(LyricLine::new(ms, text));
        }
    }

    if offset_ms != 0 {
        for line in out.iter_mut() {
            // 正 offset = 歌词提前出现
            line.time_ms = (line.time_ms as i64 - offset_ms).max(0) as u64;
        }
    }

    out.sort_by_key(|l| l.time_ms);
    out.dedup_by(|a, b| a.time_ms == b.time_ms && a.text == b.text);
    out
}

/// `mm:ss` / `mm:ss.xx` / `mm:ss:xx` -> 毫秒; 不是时间标签返回 None
fn parse_time_tag(tag: &str) -> Option<u64> {
    let (mm, rest) = tag.split_once(':')?;
    let minutes: u64 = mm.trim().parse().ok()?;
    // 秒与小数部分: 兼容 "." 与 ":" 两种分隔
    let (sec_str, frac_str) = match rest.split_once(['.', ':']) {
        Some((s, f)) => (s, Some(f)),
        None => (rest, None),
    };
    let seconds: u64 = sec_str.trim().parse().ok()?;
    if seconds >= 60 {
        return None;
    }
    let frac_ms = match frac_str {
        None => 0,
        Some(f) => {
            let digits: String = f.chars().filter(|c| c.is_ascii_digit()).collect();
            if digits.is_empty() {
                0
            } else {
                let take = digits.len().min(3);
                let v: u64 = digits[..take].parse().ok()?;
                match take {
                    1 => v * 100,
                    2 => v * 10,
                    _ => v,
                }
            }
        }
    };
    Some(minutes * 60_000 + seconds * 1_000 + frac_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_line() {
        let lines = parse_lrc("[00:12.34]第一句\n[00:15.6]第二句");
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].time_ms, 12_340);
        assert_eq!(lines[0].text, "第一句");
        assert_eq!(lines[1].time_ms, 15_600);
    }

    #[test]
    fn supports_multiple_stamps_and_sorts() {
        let src = "[00:20.00][00:10.50]副歌\n[00:05.00]开头";
        let lines = parse_lrc(src);
        assert_eq!(lines.iter().map(|l| l.time_ms).collect::<Vec<_>>(), vec![5_000, 10_500, 20_000]);
        assert_eq!(lines[2].text, "副歌");
    }

    #[test]
    fn ignores_metadata_and_applies_offset() {
        let src = "[ti:歌名]\n[ar:歌手]\n[offset:500]\n[00:01.00]甲\n[00:02.00]乙";
        let lines = parse_lrc(src);
        assert_eq!(lines.len(), 2);
        // 正 offset = 提前 500ms
        assert_eq!(lines[0].time_ms, 500);
        assert_eq!(lines[1].time_ms, 1_500);
    }

    #[test]
    fn fractional_precision_variants() {
        assert_eq!(parse_lrc("[00:01.5]x")[0].time_ms, 1_500);
        assert_eq!(parse_lrc("[00:01.25]x")[0].time_ms, 1_250);
        assert_eq!(parse_lrc("[00:01.125]x")[0].time_ms, 1_125);
        assert_eq!(parse_lrc("[00:01]x")[0].time_ms, 1_000);
        assert_eq!(parse_lrc("[00:01:50]x")[0].time_ms, 1_500);
    }

    #[test]
    fn drops_unparsable_lines() {
        let src = "[00:01.00]保留\n没有时间戳\n[99:99.99]非法\n[abc]混进来";
        let lines = parse_lrc(src);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "保留");
    }

    #[test]
    fn empty_and_blank_lines_survive_as_empty_text() {
        let lines = parse_lrc("[00:03.00]\n[00:04.00]词");
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text, "");
    }

    #[test]
    fn merges_translation_by_timestamp() {
        let lrc = "[00:01.00]hello\n[00:02.00]world";
        let tlyric = "[00:01.00]你好";
        let lines = parse_lrc_with_translation(lrc, Some(tlyric));
        assert_eq!(lines[0].sub.as_deref(), Some("你好"));
        assert_eq!(lines[1].sub, None);
    }

    #[test]
    fn translation_equal_to_original_is_dropped() {
        let lines = parse_lrc_with_translation("[00:01.00]同", Some("[00:01.00]同"));
        assert_eq!(lines[0].sub, None);
    }

    #[test]
    fn empty_input() {
        assert!(parse_lrc("").is_empty());
        assert!(parse_lrc_with_translation("", Some("")).is_empty());
    }
}
