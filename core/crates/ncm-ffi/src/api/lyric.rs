//! 歌词: LRC 时间轴(含翻译) / 逐字歌词(YRC) / TTML 第二来源 / 打分与择优(纯函数).
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

/// 一行歌词(已按时间排序, 翻译按时间戳对齐)
pub struct LyricLineDto {
    pub time_ms: u64,
    pub text: String,
    pub sub: Option<String>,
}

/// 带翻译的歌词时间轴(网易云 tlyric). UI 只需要按 position 找当前行, 不再自己啃 LRC.
pub async fn lyric_lines_i18n(track_id: u64) -> Result<Vec<LyricLineDto>, FfiError> {
    let lyric = routed_call(Capability::Lyric, |provider| {
        Box::pin(async move { provider.lyric(ncm_domain::TrackId::new(track_id)).await })
    })
    .await?;
    Ok(ncm_domain::parse_lrc_with_translation(
        lyric.lrc.as_deref().unwrap_or_default(),
        lyric.translated.as_deref(),
    )
    .into_iter()
    .map(|l| LyricLineDto {
        time_ms: l.time_ms,
        text: l.text,
        sub: l.sub,
    })
    .collect())
}

/// 一个词(字)的逐字时间与文本
pub struct WordItemDto {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

/// 一行逐字歌词; words 为空或单词 = 无词级时间(退化行)
pub struct WordLyricLineDto {
    pub start_ms: i64,
    pub end_ms: i64,
    pub words: Vec<WordItemDto>,
}

/// 逐字歌词(YRC). 无逐字数据时 lines 为空, UI 应回落 lyric_lines_i18n.
pub async fn word_lyric_lines(track_id: u64) -> Result<WordLyricDto, FfiError> {
    let wl = routed_call(Capability::Lyric, |provider| {
        Box::pin(async move {
            provider
                .word_lyric(ncm_domain::TrackId::new(track_id))
                .await
        })
    })
    .await?;
    Ok(WordLyricDto {
        lines: wl
            .lines
            .iter()
            .zip(wl.translation_lines.iter())
            .map(|(l, _t)| WordLyricLineDto {
                start_ms: l.start_ms,
                end_ms: l.end_ms,
                words: l
                    .words
                    .iter()
                    .map(|w| WordItemDto {
                        start_ms: w.start_ms,
                        end_ms: w.end_ms,
                        text: w.text.clone(),
                    })
                    .collect(),
            })
            .collect(),
        translation_lines: wl.translation_lines,
        has_word_timing: wl.has_word_timing,
    })
}

/// 逐字歌词整体 DTO(frb 不直接吃 domain 类型)
pub struct WordLyricDto {
    pub lines: Vec<WordLyricLineDto>,
    pub translation_lines: Vec<Option<String>>,
    pub has_word_timing: bool,
}

/// WordLyric -> DTO(聚合导出与 TTML 单独导出共用).
fn word_lyric_dto(wl: ncm_domain::WordLyric) -> WordLyricDto {
    WordLyricDto {
        lines: wl
            .lines
            .iter()
            .zip(wl.translation_lines.iter())
            .map(|(l, _t)| WordLyricLineDto {
                start_ms: l.start_ms,
                end_ms: l.end_ms,
                words: l
                    .words
                    .iter()
                    .map(|w| WordItemDto {
                        start_ms: w.start_ms,
                        end_ms: w.end_ms,
                        text: w.text.clone(),
                    })
                    .collect(),
            })
            .collect(),
        translation_lines: wl.translation_lines,
        has_word_timing: wl.has_word_timing,
    }
}

/// B13: 只取 TTML 第二来源(带磁盘缓存: `dataDir/ttml/<id>.ttml` / `<id>.none`).
/// 无数据/解析失败返回 Ok(None), 网络错误返回 Err —— 调用方(或 Dart 侧)静默回退.
pub async fn ttml_lyric_lines(track_id: u64) -> Result<Option<WordLyricDto>, FfiError> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| FfiError::internal("core not initialized"))?
        .clone();
    match ncm_service::ttml_source::fetch_ttml(&dir, track_id).await {
        Ok(Some(doc)) => Ok(Some(word_lyric_dto(
            ncm_service::ttml_source::ttml_to_word_lyric(&doc),
        ))),
        Ok(None) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

// ---------------- 逐字歌词打分/择优(架构审计 7.3: Dart 不再有镜像) ----------------

/// 逐字歌词打分分项与总分(全部 0..1). 唯一实现 = `ncm_service::ttml_source::score_word_lyric`.
pub struct WordLyricScoreDto {
    pub coverage: f64,
    pub monotonic: f64,
    pub first_word: f64,
    pub spans: f64,
    pub consistency: f64,
    pub score: f64,
}

/// auto 择优结果: 来源短标识("yrc"/"ttml"/None) + 可解释理由(只有两来源比较后才有).
pub struct LyricChoiceDto {
    pub source: Option<String>,
    pub reason: Option<String>,
}

/// WordLyricDto -> domain `WordLyric`(打分/择优的入参; 与 `word_lyric_dto` 互逆).
fn dto_to_word_lyric(dto: WordLyricDto) -> ncm_domain::WordLyric {
    ncm_domain::WordLyric {
        lines: dto
            .lines
            .into_iter()
            .map(|l| ncm_domain::WordLyricLine {
                start_ms: l.start_ms,
                end_ms: l.end_ms,
                words: l
                    .words
                    .into_iter()
                    .map(|w| ncm_domain::WordItem {
                        start_ms: w.start_ms,
                        end_ms: w.end_ms,
                        text: w.text,
                    })
                    .collect(),
            })
            .collect(),
        translation_lines: dto.translation_lines,
        has_word_timing: dto.has_word_timing,
        raw: None,
    }
}

/// 逐字歌词质量打分(纯函数, 不联网, 同步).
///
/// 权重/容差/阈值**只有 Rust 一份**(`ncm_service::ttml_source`): 以前 Dart 侧
/// `ui/lib/src/lyric_source.dart` 手抄了一整套镜像(架构审计 7.3), 改一处要改两处。
/// `line_starts` 为行级 LRC 各行起始 ms, 空 = 无参照(一致性记中性 1).
#[frb(sync)]
pub fn lyric_score(dto: Option<WordLyricDto>, line_starts: Vec<i64>) -> WordLyricScoreDto {
    let starts = (!line_starts.is_empty()).then_some(line_starts);
    let s = match dto {
        Some(d) => {
            ncm_service::ttml_source::score_word_lyric(&dto_to_word_lyric(d), starts.as_deref())
        }
        None => ncm_service::ttml_source::WordLyricScore::default(),
    };
    WordLyricScoreDto {
        coverage: s.coverage,
        monotonic: s.monotonic,
        first_word: s.first_word,
        spans: s.spans,
        consistency: s.consistency,
        score: s.score,
    }
}

/// auto 模式纯函数择优: 比较 yrc 与 TTML 得分, 选高者并给出可解释理由.
/// 空歌词(0 行)等价于"该来源没有", 只有一方时理由为 None(不算择优).
#[frb(sync)]
pub fn lyric_choose_source(
    yrc: Option<WordLyricDto>,
    ttml: Option<WordLyricDto>,
    line_starts: Vec<i64>,
) -> LyricChoiceDto {
    let starts = (!line_starts.is_empty()).then_some(line_starts);
    let y = yrc.map(dto_to_word_lyric).filter(|wl| !wl.is_empty());
    let t = ttml.map(dto_to_word_lyric).filter(|wl| !wl.is_empty());
    let choice =
        ncm_service::ttml_source::choose_word_source(y.as_ref(), t.as_ref(), starts.as_deref());
    LyricChoiceDto {
        source: choice.source.map(|s| s.as_str().to_string()),
        reason: choice.reason,
    }
}

/// auto 模式: yrc 是否已好到不必探测 TTML(得分 >= `AUTO_SKIP_TTML_SCORE`, 省一次网络).
#[frb(sync)]
pub fn lyric_auto_skip_ttml(dto: WordLyricDto) -> bool {
    let wl = dto_to_word_lyric(dto);
    !wl.is_empty()
        && ncm_service::ttml_source::score_word_lyric(&wl, None).score
            >= ncm_service::ttml_source::AUTO_SKIP_TTML_SCORE
}

/// netease 偏好: yrc 是否"够好"(有行、有词级时间、覆盖率 >= `YRC_WORD_COVERAGE_THRESHOLD`).
#[frb(sync)]
pub fn lyric_yrc_good_enough(dto: WordLyricDto) -> bool {
    ncm_service::ttml_source::yrc_good_enough(&dto_to_word_lyric(dto))
}

/// 两来源得分是否接近(差 < `SCORE_CLOSE_WINDOW`): 只有接近时才值得再取行级 LRC
/// 做一致性加分(多一次请求), 这个判断以前写在 Dart 侧。
#[frb(sync)]
pub fn lyric_scores_close(yrc: WordLyricDto, ttml: WordLyricDto) -> bool {
    ncm_service::ttml_source::scores_close(&dto_to_word_lyric(yrc), &dto_to_word_lyric(ttml))
}

// 说明(2026-11 去重): 这里原本还有一个 `word_lyric_with_fallback` 导出, 与
// Dart 侧 main.dart 的 `resolveLyricSource` 是同一套"yrc → TTML → 行级"择优
// 策略的两份实现 —— 而 UI 实际走的是 Dart 那份(可注入 loader, 有单测覆盖),
// 这个导出从来没有人调用。已删除, 只保留原子能力:
//   word_lyric_lines / ttml_lyric_lines / lyric_lines_i18n(UI 自己组合)。
// Rust 侧 ncm_service::ttml_source::word_lyric_with_fallback 保留并由其单测覆盖,
// 供 CLI / 未来宿主使用; 若要恢复 UI 走它, 只需把 Dart 的 loaders 换成一次调用。
