//! TTML(AMLL) 逐字歌词模型与解析: 纯函数, 手写轻量 XML 扫描(domain 层零第三方依赖).
//!
//! 实测 schema 见 docs/b13-ttml-lyrics-notes.md: 逐字在 <p begin end> 内联
//! <span begin end>text</span>; ttm:role="x-translation" 行译文 / "x-roman" 罗马音
//! (存起来, UI 暂不用); "x-bg" 背景声跳过. 时间支持纯秒("31.5")与 m:ss.mmm("00:29.231").
use serde::{Deserialize, Serialize};

/// 一个逐字词(字)的时间与文本.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct TtmlWord {
    #[serde(default)]
    pub start_ms: i64,
    #[serde(default)]
    pub end_ms: i64,
    #[serde(default)]
    pub text: String,
}

/// 一行 TTML 逐字歌词.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct TtmlLine {
    #[serde(default)]
    pub start_ms: i64,
    #[serde(default)]
    pub end_ms: i64,
    #[serde(default)]
    pub words: Vec<TtmlWord>,
    /// ttm:role="x-translation" 行(按行首毫秒对齐后挂到主行)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub translation: Option<String>,
    /// ttm:role="x-roman" 行(罗马音, UI 暂不用)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roman: Option<String>,
}

/// 解析 TTML 文本 -> 逐字行(按 start_ms 升序).
///
/// 错误信息带行号(1-based, 指向出问题的标签所在行). 空 body/无有效行返回空 Vec.
pub fn parse_ttml(src: &str) -> Result<Vec<TtmlLine>, String> {
    let src = strip_comments(src);
    let body_start = src
        .find("<body")
        .ok_or_else(|| err_at(&src, 0, "missing <body>"))?;
    let body_end = src
        .rfind("</body>")
        .map(|p| p + "</body>".len())
        .unwrap_or(src.len());
    let body = &src[body_start..body_end];

    let mut lines: Vec<TtmlLine> = Vec::new();
    let mut translations: Vec<(i64, String)> = Vec::new();
    let mut romans: Vec<(i64, String)> = Vec::new();

    let mut cursor = 0usize;
    while let Some(open) = find_tag(body, cursor, "p") {
        let tag_end = match body[open..].find('>') {
            Some(p) => open + p,
            None => return Err(err_at(body, open, "unclosed <p> tag")),
        };
        let attrs = &body[open..tag_end];
        if attrs.ends_with('/') {
            // 自闭合 <p .../> 空行, 跳过
            cursor = tag_end + 1;
            continue;
        }
        let role_owned = attr_value(attrs, "ttm:role").unwrap_or_default();
        let role = role_owned.as_str();
        let content_end = match body[tag_end..].find("</p>") {
            Some(p) => tag_end + p,
            None => return Err(err_at(body, open, "missing </p> closing tag")),
        };
        let content = &body[tag_end + 1..content_end];
        cursor = content_end + "</p>".len();

        let begin_ms = match attr_value(attrs, "begin").as_deref() {
            Some(t) => parse_ttml_time(t)
                .ok_or_else(|| err_at(body, open, &format!("bad begin time {t:?}")))?,
            None => return Err(err_at(body, open, "missing begin attribute")),
        };
        let end_ms = attr_value(attrs, "end")
            .and_then(|t| parse_ttml_time(&t))
            .unwrap_or(i64::MIN); // 缺 end 用下一行 begin 兜底(见收尾 pass)

        match role {
            "x-bg" => continue, // 背景声跳过
            "x-translation" | "x-roman" => {
                let text = strip_tags(content);
                if text.is_empty() {
                    continue;
                }
                let slot = if role == "x-translation" {
                    &mut translations
                } else {
                    &mut romans
                };
                slot.push((begin_ms, text));
                continue;
            }
            _ => {}
        }

        // 主行: 抽内联 <span>
        let mut words: Vec<TtmlWord> = Vec::new();
        let mut sc = 0usize;
        let mut next_begin: Option<i64> = None;
        while let Some(sopen) = find_tag(content, sc, "span") {
            let stag_end = match content[sopen..].find('>') {
                Some(p) => sopen + p,
                None => return Err(err_at(body, open, "unclosed <span> tag")),
            };
            let sattrs = &content[sopen..stag_end];
            if sattrs.ends_with('/') {
                sc = stag_end + 1;
                continue;
            }
            let send = match content[stag_end..].find("</span>") {
                Some(p) => stag_end + p,
                None => return Err(err_at(body, open, "missing </span> closing tag")),
            };
            let text = &content[stag_end + 1..send];
            sc = send + "</span>".len();
            let ws = match attr_value(sattrs, "begin").as_deref() {
                Some(t) => parse_ttml_time(t)
                    .ok_or_else(|| err_at(body, open, &format!("bad span begin time {t:?}")))?,
                None => return Err(err_at(body, open, "span missing begin attribute")),
            };
            let we = attr_value(sattrs, "end")
                .and_then(|t| parse_ttml_time(&t))
                .unwrap_or(i64::MIN);
            if !text.trim().is_empty() {
                words.push(TtmlWord {
                    start_ms: ws,
                    end_ms: we,
                    text: decode_entities(text.trim()),
                });
            }
            // 记录 span begin 供行尾兜底
            if next_begin.is_none() {
                next_begin = Some(ws);
            }
        }
        if words.is_empty() {
            continue; // 间奏/空行
        }
        lines.push(TtmlLine {
            start_ms: begin_ms,
            end_ms,
            words,
            translation: None,
            roman: None,
        });
    }

    // 收尾: 缺 end 的行/词用"下一个已知 begin"兜底(行内取下一 span begin 或行 begin)
    for i in 0..lines.len() {
        let next_begin = lines.get(i + 1).map(|l| l.start_ms).unwrap_or(
            lines[i].start_ms
                + lines[i]
                    .words
                    .iter()
                    .map(|w| w.text.chars().count() as i64 * 200)
                    .max()
                    .unwrap_or(0),
        );
        if lines[i].end_ms == i64::MIN || lines[i].end_ms < lines[i].start_ms {
            lines[i].end_ms = next_begin.max(lines[i].start_ms);
        }
        let starts: Vec<i64> = lines[i].words.iter().map(|w| w.start_ms).collect();
        for (j, w) in lines[i].words.iter_mut().enumerate() {
            if w.end_ms == i64::MIN || w.end_ms < w.start_ms {
                // 词 end 缺: 先用行内下一个词的 begin, 最后一个词用下一行 begin
                let nb = starts.get(j + 1).copied().unwrap_or(next_begin);
                w.end_ms = nb.max(w.start_ms);
            }
        }
    }

    // 挂翻译/罗马音(按行首毫秒精确对齐, 未命中丢弃)
    for (t, text) in translations {
        if let Some(line) = lines.iter_mut().find(|l| l.start_ms == t) {
            line.translation = Some(text);
        }
    }
    for (t, text) in romans {
        if let Some(line) = lines.iter_mut().find(|l| l.start_ms == t) {
            line.roman = Some(text);
        }
    }
    lines.sort_by_key(|l| l.start_ms);
    Ok(lines)
}

/// 纯秒("12.345")或 m:ss.mmm("00:29.231") -> 毫秒.
pub fn parse_ttml_time(s: &str) -> Option<i64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let (mins, rest) = match s.split_once(':') {
        Some((m, r)) => (m.parse::<i64>().ok()?, r),
        None => (0, s),
    };
    let (secs, ms) = match rest.split_once('.') {
        Some((sec, frac)) => {
            // 小数部分右补零到毫秒: "5"->500, "54"->540, "541"->541
            let mut digits = frac
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect::<String>();
            let negative_ok = digits.len() <= 3;
            if !negative_ok {
                digits.truncate(3);
            }
            while digits.len() < 3 {
                digits.push('0');
            }
            let ms_val: i64 = digits.parse().ok()?;
            (sec.parse::<i64>().ok()?, ms_val)
        }
        None => (rest.parse::<i64>().ok()?, 0),
    };
    Some((mins * 60 + secs) * 1000 + ms)
}

fn find_tag(src: &str, from: usize, name: &str) -> Option<usize> {
    let needle = format!("<{name}");
    let mut pos = from;
    loop {
        let idx = src[pos..].find(&needle)? + pos;
        // 排除 <pfoo> 之类: 后一个字符必须是空白/'>'/'/'
        let after = src[idx + needle.len()..].chars().next();
        if matches!(
            after,
            Some(' ') | Some('\t') | Some('\n') | Some('\r') | Some('>') | Some('/')
        ) {
            return Some(idx);
        }
        pos = idx + needle.len();
    }
}

/// 从开标签属性串中取 attr 的值(支持双/单引号).
fn attr_value(tag: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=");
    let idx = tag.find(&needle)? + needle.len();
    let quote = tag[idx..].chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let rest = &tag[idx + 1..];
    let end = rest.find(quote)?;
    Some(rest[..end].to_string())
}

/// 去掉所有标签取纯文本(翻译/罗马音行用).
fn strip_tags(src: &str) -> String {
    let mut out = String::new();
    let mut depth = 0usize;
    for c in src.chars() {
        match c {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    decode_entities(out.trim())
}

fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

fn strip_comments(src: &str) -> String {
    if !src.contains("<!--") {
        return src.to_string();
    }
    let mut out = String::with_capacity(src.len());
    let mut rest = src;
    while let Some(start) = rest.find("<!--") {
        out.push_str(&rest[..start]);
        match rest[start..].find("-->") {
            Some(end) => rest = &rest[start + end + 3..],
            None => return out, // 未闭合注释: 丢弃剩余(畸形但可容忍)
        }
    }
    out.push_str(rest);
    out
}

/// 错误信息带 1-based 行号.
fn err_at(src: &str, pos: usize, msg: &str) -> String {
    let line = src[..pos.min(src.len())].matches('\n').count() + 1;
    format!("ttml parse error at line {line}: {msg}")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<tt xmlns="http://www.w3.org/ns/ttml">
<head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head>
<body dur="04:25.541">
<div begin="00:29.231" end="04:25.541">
<p begin="00:29.231" end="00:32.723" ttm:agent="v1"><span begin="00:29.231" end="00:29.692">故</span><span begin="00:29.692" end="00:30.057">事</span><span begin="00:30.057" end="00:31.799">小黄花</span></p>
<p begin="00:32.723" end="00:36.238"><span begin="00:32.723" end="00:33.132">从</span><span begin="00:33.132" end="00:34.446">出生那年</span></p>
</div>
</body>
</tt>"#;

    #[test]
    fn parses_real_sample() {
        let lines = parse_ttml(SAMPLE).unwrap();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].start_ms, 29231);
        assert_eq!(lines[0].end_ms, 32723);
        assert_eq!(lines[0].words.len(), 3);
        assert_eq!(lines[0].words[0].text, "故");
        assert_eq!(lines[0].words[2].text, "小黄花");
        assert_eq!(lines[0].words[2].end_ms, 31799);
    }

    #[test]
    fn parses_pure_seconds_time() {
        assert_eq!(parse_ttml_time("31.5"), Some(31500));
        assert_eq!(parse_ttml_time("31.54"), Some(31540));
        assert_eq!(parse_ttml_time("31.541"), Some(31541));
        assert_eq!(parse_ttml_time("00:29.231"), Some(29231));
        assert_eq!(parse_ttml_time("4:25.541"), Some(265541));
        assert_eq!(parse_ttml_time("12"), Some(12000));
        assert_eq!(parse_ttml_time(""), None);
        assert_eq!(parse_ttml_time("abc"), None);
    }

    #[test]
    fn translation_and_roman_attached() {
        let t = r#"<tt><body>
<p begin="1.0" end="2.0"><span begin="1.0" end="2.0">hello</span></p>
<p begin="1.0" end="2.0" ttm:role="x-translation">你好</p>
<p begin="1.0" end="2.0" ttm:role="x-roman">ha luo</p>
</body></tt>"#;
        let lines = parse_ttml(t).unwrap();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].translation.as_deref(), Some("你好"));
        assert_eq!(lines[0].roman.as_deref(), Some("ha luo"));
    }

    #[test]
    fn xbg_skipped() {
        let t = r#"<tt><body>
<p begin="1.0" end="2.0"><span begin="1.0" end="2.0">主</span></p>
<p begin="1.0" end="2.0" ttm:role="x-bg"><span begin="1.0" end="2.0">和声</span></p>
</body></tt>"#;
        let lines = parse_ttml(t).unwrap();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].words[0].text, "主");
    }

    #[test]
    fn empty_spans_interlude_skipped() {
        let t = r#"<tt><body>
<p begin="0" end="5.0"><span begin="0" end="5.0"></span><span begin="5.0" end="6.0">词</span></p>
</body></tt>"#;
        let lines = parse_ttml(t).unwrap();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].words.len(), 1);
        assert_eq!(lines[0].words[0].text, "词");
        assert_eq!(lines[0].words[0].start_ms, 5000);
    }

    #[test]
    fn missing_end_falls_back_to_next_line_begin() {
        let t = r#"<tt><body>
<p begin="1.0"><span begin="1.0">A</span><span begin="1.5">B</span></p>
<p begin="3.0" end="4.0"><span begin="3.0" end="4.0">C</span></p>
</body></tt>"#;
        let lines = parse_ttml(t).unwrap();
        assert_eq!(lines[0].end_ms, 3000); // 行 end 缺 -> 下一行 begin
        assert_eq!(lines[0].words[0].end_ms, 1500); // span end 缺 -> 下一 span begin
        assert_eq!(lines[0].words[1].end_ms, 3000);
    }

    #[test]
    fn out_of_order_lines_sorted() {
        let t = r#"<tt><body>
<p begin="5.0" end="6.0"><span begin="5.0" end="6.0">晚</span></p>
<p begin="1.0" end="2.0"><span begin="1.0" end="2.0">早</span></p>
</body></tt>"#;
        let lines = parse_ttml(t).unwrap();
        assert_eq!(lines[0].words[0].text, "早");
        assert_eq!(lines[1].words[0].text, "晚");
    }

    #[test]
    fn empty_body_ok() {
        assert!(parse_ttml(r#"<tt><body></body></tt>"#).unwrap().is_empty());
        assert!(
            parse_ttml(r#"<tt><body><p begin="1" end="2"/></body></tt>"#)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn missing_body_errors_with_line_number() {
        let e = parse_ttml("<tt>\n<head></head>\n</tt>").unwrap_err();
        assert!(e.contains("line"), "got: {e}");
    }

    #[test]
    fn missing_begin_attribute_errors() {
        let e = parse_ttml("<tt><body>\n<p end=\"2.0\"><span end=\"2\">x</span></p>\n</body></tt>")
            .unwrap_err();
        assert!(e.contains("missing begin"), "got: {e}");
        assert!(e.contains("line"), "got: {e}");
    }

    #[test]
    fn bad_time_value_errors() {
        let e =
            parse_ttml("<tt><body>\n<p begin=\"xx\" end=\"2.0\"><span>x</span></p>\n</body></tt>")
                .unwrap_err();
        assert!(e.contains("bad begin time"), "got: {e}");
    }

    #[test]
    fn unclosed_p_errors() {
        let e = parse_ttml("<tt><body>\n<p begin=\"1.0\" end=\"2.0\"><span>x</span>\n</body></tt>")
            .unwrap_err();
        assert!(e.contains("missing </p>"), "got: {e}");
    }

    #[test]
    fn malformed_html_like_degrades() {
        // 实体/嵌套 span/注释 都不 panic
        let t = r#"<tt><body><!-- comment --><p begin="1.0" end="2.0"><span begin="1.0" end="2.0">a &amp; b &lt;x&gt;</span></p></body></tt>"#;
        let lines = parse_ttml(t).unwrap();
        assert_eq!(lines[0].words[0].text, "a & b <x>");
    }

    #[test]
    fn serde_roundtrip() {
        let lines = parse_ttml(SAMPLE).unwrap();
        let json = serde_json::to_string(&lines).unwrap();
        let back: Vec<TtmlLine> = serde_json::from_str(&json).unwrap();
        assert_eq!(back, lines);
    }
}
