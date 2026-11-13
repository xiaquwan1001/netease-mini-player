//! C2 真实抽样(一次性脚本, 不进测试): 对若干曲目拉 yrc + 行级 LRC + AMLL TTML,
//! 打印打分与 auto 择优结果, 统计 AMLL 被选中比例. 结果摘录进 docs/c2-lyric-source-quality.md.
//! 用法: cargo run --release -p ncm-service --example c2_sampling
use std::path::PathBuf;

use ncm_domain::TrackId;
use ncm_service::ttml_source::{
    choose_word_source, fetch_ttml, score_word_lyric, ttml_to_word_lyric, CachedTtmlProbe,
    LyricSourcePreference,
};
use ncm_service::Core;

const SAMPLES: &[(u64, &str)] = &[
    (186016, "晴天(周杰伦, 老歌)"),
    (26305527, "江南(林俊杰)"),
    (327584, "听海(张惠妹)"),
    (233931, "泡沫(邓紫棋)"),
    (1996312557, "好运来(祖海, 老歌)"),
    (29848188, "강남스타일(PSY, 韩语)"),
    (2028319804, "Dynamite(BTS Live, 韩语团)"),
    (254406, "后来 Live(刘若英)"),
    (74466, "龙驹岛(冷门)"),
    (1818568343, "柬埔寨的夜(冷门)"),
    (3396657990, "夜曲(翻唱)"),
    (1945894789, "晴天 钢琴版(纯音乐)"),
    (3440441479, "晴天 Jay(短)"),
    (186004, "将军(周杰伦, 老歌)"),
    (186008, "园游会(周杰伦, 老歌)"),
    (186009, "止战之殇(周杰伦, 老歌)"),
    (186011, "断了的弦(周杰伦, 老歌)"),
];

fn data_dir() -> PathBuf {
    if let Ok(d) = std::env::var("NCM_DATA_DIR") {
        return d.into();
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".local/share/ncm")
}

#[tokio::main]
async fn main() {
    let dir = data_dir();
    let core = Core::open(&dir).expect("open core");
    let p = core
        .providers
        .first_with(ncm_provider::Capability::Lyric)
        .expect("lyric provider");
    let mut amll_wins = 0;
    let mut yrc_wins = 0;
    let mut compared = 0;
    let mut auto_amll = 0;
    let mut auto_yrc = 0;
    for (id, name) in SAMPLES {
        let yrc = p.word_lyric(TrackId::new(*id)).await.ok();
        let line_starts: Vec<i64> = p
            .lyric(TrackId::new(*id))
            .await
            .ok()
            .map(|l| {
                ncm_domain::parse_lrc_with_translation(
                    l.lrc.as_deref().unwrap_or_default(),
                    l.translated.as_deref(),
                )
                .into_iter()
                .map(|x| x.time_ms as i64)
                .collect()
            })
            .unwrap_or_default();
        let ttml = fetch_ttml(&dir, *id).await.ok().flatten();
        let ttml_wl = ttml
            .as_ref()
            .map(ttml_to_word_lyric)
            .filter(|wl| !wl.is_empty());
        let ls = if line_starts.is_empty() {
            None
        } else {
            Some(&line_starts[..])
        };
        let sy = yrc.as_ref().map(|wl| score_word_lyric(wl, ls));
        let st = ttml_wl.as_ref().map(|wl| score_word_lyric(wl, ls));
        let choice = choose_word_source(
            yrc.as_ref().filter(|wl| !wl.is_empty()),
            ttml_wl.as_ref(),
            ls,
        );
        let (sy_f, st_f) = (
            sy.as_ref()
                .map_or("-".into(), |s| format!("{:.3}", s.score)),
            st.as_ref()
                .map_or("-".into(), |s| format!("{:.3}", s.score)),
        );
        let src = match choice.source {
            Some(ncm_service::ttml_source::LyricSource::Yrc) => "yrc",
            Some(ncm_service::ttml_source::LyricSource::Ttml) => "AMLL",
            _ => "(无逐字)",
        };
        if sy.is_some() && st.is_some() {
            compared += 1;
            match src {
                "AMLL" => amll_wins += 1,
                "yrc" => yrc_wins += 1,
                _ => {}
            }
        }
        // 真实 auto 口径: yrc 得分 >= 0.9 时短路(不探测 TTML)
        let auto_pick = match (&sy, &st) {
            (Some(sy), _) if sy.score >= 0.9 => "yrc(短路)",
            (None, Some(_)) => "AMLL",
            (Some(_), Some(_)) => src,
            (Some(_), None) => "yrc",
            _ => "(无逐字)",
        };
        if auto_pick.starts_with("AMLL") {
            auto_amll += 1;
        }
        if auto_pick.starts_with("yrc") {
            auto_yrc += 1;
        }
        println!(
            "{:<24} id={:<10} yrc={:<6} ttml={:<6} 选={} 理由={:?} (yrc行数={}, 行级参照={})",
            name,
            id,
            sy_f,
            st_f,
            src,
            choice.reason,
            yrc.map(|w| w.lines.len()).unwrap_or(0),
            line_starts.len(),
        );
    }
    println!("\n纯比较口径(两来源都在): {compared}; AMLL 胜 {amll_wins}; yrc 胜 {yrc_wins}");
    println!("真实 auto 口径(含 yrc>=0.9 短路): AMLL 被选中 {auto_amll}; yrc 被选中 {auto_yrc}(样本 {} 首)", SAMPLES.len());
    let _ = CachedTtmlProbe; // 引用防 dead_code 警告
    let _ = LyricSourcePreference::default();
}
