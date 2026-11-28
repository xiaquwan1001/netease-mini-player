//! 搜索域: 综合搜索/建议/精确/热词/默认搜索词.
//!
//! 搜索族是 405(操作频繁)的直接来源, 本模块所有匿名只读请求都走
//! `crate::read_cache` 的统一出口: TTL 缓存 + 同 key 单飞.

use super::*;

use crate::read_cache::{cache_key, endpoint};

impl NeteaseProvider {
    pub(super) fn search<'a>(
        &'a self,
        query: &'a SearchQuery,
    ) -> BoxFuture<'a, ProviderResult<SearchPage>> {
        Box::pin(async move {
            let body = self
                .cloudsearch_body(&query.keywords, 1, query.limit, query.offset)
                .await?;
            parse_search(&body)
        })
    }

    /// 搜索建议(输入联想). 匿名可用.
    ///
    /// 2026-11-14 用户反馈三条, 都在这里收口:
    /// - 「联想词应该结合用户关注内容」: 关注了 Chinese Football 的人搜 "Chinese"
    ///   时它该排在冷门同名艺人前面 ⇒ 按「是否与我关注的人相关」重排;
    /// - 「每类候选太少」: 服务端给几条就留几条(上限 SUGGEST_PER_KIND_MAX);
    /// - 「单曲/专辑/艺人的图片很多只有占位符」: 专辑改用专辑自己的封面 URL,
    ///   歌曲再用一次 song_detail 批量补专辑封面(按歌曲 id 缓存).
    pub(super) fn search_suggest<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<SuggestItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let key = cache_key(
                endpoint::SEARCH_SUGGEST,
                &[("keywords", keywords.to_string())],
            );
            let body = self
                .read_cache()
                .get_or_load(endpoint::SEARCH_SUGGEST, &key, || async {
                    let q = make_query(&cookie, &domain, &ua).param("keywords", keywords);
                    let resp = client.search_suggest(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            let followed = self.suggest_followed_artist_ids().await;
            let mut items = rank_suggest(parse_suggest_groups(&body), &followed);
            self.fill_suggest_song_covers(&mut items);
            Ok(items)
        })
    }

    /// 关注艺人 id(5 分钟缓存; 未登录/请求失败就是空集合, 排序退回服务端顺序).
    ///
    /// 联想是每按键一次请求, 不能每次都打 artist_sublist(风控敏感), 所以这里
    /// 自己在 provider 里缓存一份; update_session(登录/登出/切号)会清掉它.
    async fn suggest_followed_artist_ids(&self) -> std::collections::HashSet<u64> {
        const TTL: std::time::Duration = std::time::Duration::from_secs(300);
        let now = std::time::Instant::now();
        {
            let guard = self
                .followed_artists
                .read()
                .unwrap_or_else(|e| e.into_inner());
            if let Some((at, ids)) = guard.as_ref() {
                if now.duration_since(*at) < TTL {
                    return ids.iter().copied().collect();
                }
            }
        }
        let ids: Vec<u64> = match self.subscribed_artists(500).await {
            Ok(list) => list.into_iter().map(|a| a.id).collect(),
            Err(_) => Vec::new(),
        };
        *self
            .followed_artists
            .write()
            .unwrap_or_else(|e| e.into_inner()) = Some((now, ids.clone()));
        ids.into_iter().collect()
    }

    /// 给联想里缺封面的单曲补专辑封面.
    ///
    /// **一次联想 = 恒定 1 次上游**(R4, 2026-11-28): 补图**不再**在请求路径上等 ——
    /// 本次只用正向缓存里已有的封面, 缺的那些丢给后台预热(`tokio::spawn`),
    /// 下一次按键(同一个词/下一位)就补上。原因: 联想是每按键一次的高频路径,
    /// `song_detail` 又落在风控最敏感的端点上, 多打一次就是多一分 405。
    ///
    /// 失败一律静默(联想是输入路径上的可选增强, 不能因为补图失败就不出建议)。
    fn fill_suggest_song_covers(&self, items: &mut [SuggestItem]) {
        let mut missing: Vec<u64> = Vec::new();
        for item in items.iter() {
            if item.kind == "song" && item.cover_url.is_none() && !missing.contains(&item.id) {
                missing.push(item.id);
            }
        }
        if missing.is_empty() {
            return;
        }
        let resolved: std::collections::HashMap<u64, String> = {
            let cache = self
                .suggest_covers
                .read()
                .unwrap_or_else(|e| e.into_inner());
            missing
                .iter()
                .filter_map(|id| cache.get(id).map(|url| (*id, url.clone())))
                .collect()
        };
        // 缓存里没有的: 只排一次批量预热, 本次不等待
        let fetch: Vec<u64> = missing
            .iter()
            .copied()
            .filter(|id| !resolved.contains_key(id))
            .take(10)
            .collect();
        if !fetch.is_empty() {
            self.spawn_suggest_cover_warmup(fetch);
        }
        for item in items.iter_mut() {
            if item.kind == "song" && item.cover_url.is_none() {
                if let Some(url) = resolved.get(&item.id) {
                    item.cover_url = Some(url.clone());
                }
            }
        }
    }

    /// 后台预热联想补图: 拿一份快照(client/域名/UA/cookie)与缓存句柄, 不借用 `&self`.
    ///
    /// 快照是刻意的: 会话在预热期间变了(登录/切号), 写回的是**旧账号**才看得到的
    /// 公开封面 URL —— 封面与账号无关, 不影响正确性; 缓存本身也会在 `update_session` 清空,
    /// 最坏情况只是白跑一次请求。
    fn spawn_suggest_cover_warmup(&self, ids: Vec<u64>) {
        let (client, domain, ua, cookie) = self.snapshot();
        let covers = Arc::clone(&self.suggest_covers);
        tokio::spawn(async move {
            let ids = ids.iter().map(u64::to_string).collect::<Vec<_>>().join(",");
            let q = make_query(&cookie, &domain, &ua).param("ids", &ids);
            let Ok(resp) = client.song_detail(&q).await else {
                return;
            };
            if check_body(&resp.body).is_err() {
                return;
            }
            let fresh: Vec<(u64, String)> = parse_song_list(&resp.body)
                .into_iter()
                .filter_map(|song| {
                    song.album
                        .and_then(|a| a.pic_url)
                        .map(|url| (song.id.0, url))
                })
                .collect();
            if fresh.is_empty() {
                return;
            }
            let mut cache = covers.write().unwrap_or_else(|e| e.into_inner());
            if cache.len() + fresh.len() > 500 {
                cache.clear();
            }
            for (id, url) in fresh {
                cache.insert(id, url);
            }
        });
    }

    /// 联想下拉的纯关键词候选(type=mobile 分支, /api/search/suggest/keyword).
    pub(super) fn search_suggest_keywords<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<String>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            // type=mobile 与上面的 type=cloud 走同一个 endpoint, 必须把 type 拼进 key 才不撞.
            let key = cache_key(
                endpoint::SEARCH_SUGGEST,
                &[
                    ("keywords", keywords.to_string()),
                    ("type", "mobile".to_string()),
                ],
            );
            let body = self
                .read_cache()
                .get_or_load(endpoint::SEARCH_SUGGEST, &key, || async {
                    let q = make_query(&cookie, &domain, &ua)
                        .param("type", "mobile")
                        .param("keywords", keywords);
                    let resp = client.search_suggest(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            Ok(parse_suggest_keywords(&body))
        })
    }

    /// 精确实体改写(/api/search/suggest/multimatch). vendor 内部固定发 {type:1, s:<kw>}.
    pub(super) fn search_exact<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<SearchExact>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let key = cache_key(
                endpoint::SEARCH_MULTIMATCH,
                &[("keywords", keywords.to_string())],
            );
            let body = self
                .read_cache()
                .get_or_load(endpoint::SEARCH_MULTIMATCH, &key, || async {
                    let q = make_query(&cookie, &domain, &ua).param("keywords", keywords);
                    let resp = client.search_multimatch(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            Ok(parse_search_exact(&body))
        })
    }

    /// 综合搜索: 单曲/歌手/专辑/歌单/播客 五个板块并发拉取.
    /// 单曲失败直接报错(主板块); 其余板块失败只留空, 不让一个类型拖垮整页.
    pub(super) fn search_all<'a>(
        &'a self,
        query: &'a SearchQuery,
    ) -> BoxFuture<'a, ProviderResult<SearchBundle>> {
        Box::pin(async move {
            let kw = query.keywords.as_str();
            let song_limit = query.limit.max(1);
            let side_limit = 10u32;
            let (
                (song_body, artist_body, album_body, playlist_body, podcast_body),
                (user_body, mv_body),
            ) = futures::future::join(
                futures::future::join5(
                    self.cloudsearch_body(kw, 1, song_limit, query.offset),
                    self.cloudsearch_body(kw, 100, side_limit, 0),
                    self.cloudsearch_body(kw, 10, side_limit, 0),
                    self.cloudsearch_body(kw, 1000, side_limit, 0),
                    self.cloudsearch_body(kw, 1009, side_limit, 0),
                ),
                futures::future::join(
                    self.cloudsearch_body(kw, 1002, side_limit, 0),
                    // MV 只有 type=1004(视频/节目不支持), 与其它板块并发
                    self.cloudsearch_body(kw, 1004, side_limit, 0),
                ),
            )
            .await;
            let song_body = song_body?;
            let page = parse_search(&song_body)?;
            let result_of = |b: ProviderResult<Value>| -> Option<Value> {
                b.ok().and_then(|v| v.get("result").cloned())
            };
            let mut artists = result_of(artist_body)
                .map(|r| parse_search_artists(&r))
                .unwrap_or_default();
            let mut albums = result_of(album_body)
                .map(|r| parse_search_albums(&r))
                .unwrap_or_default();
            let mut playlists = result_of(playlist_body)
                .map(|r| parse_search_playlists(&r))
                .unwrap_or_default();
            let podcasts = result_of(podcast_body)
                .map(|r| parse_search_podcasts(&r))
                .unwrap_or_default();
            let mut users = result_of(user_body)
                .map(|r| parse_search_users(&r))
                .unwrap_or_default();
            // MV 板块允许为空(很多关键词本来就没有 MV), 失败也不拖垮整页
            let mut mvs = result_of(mv_body)
                .map(|r| parse_search_mvs(&r))
                .unwrap_or_default();
            debug_search_mv(kw, "cloudsearch type=1004", &mvs);

            // 七个板块**第一次直连原关键词**时是否一条都没有 —— 这是前缀回退的唯一
            // 判据(在任何回退之前算, 否则会被自己的回退结果污染)。
            let page_empty = page.songs.is_empty()
                && artists.is_empty()
                && albums.is_empty()
                && playlists.is_empty()
                && podcasts.is_empty()
                && users.is_empty()
                && mvs.is_empty();

            // 空分类兜底(2026-11 反馈): 关键词拼错一个字时 cloudsearch 对歌手/专辑
            // 直接返回 0 条, UI 于是只剩「单曲」一个分类。这里按「最长匹配」把关键词
            // 从尾部逐字截短重试(至少 2 字, 最多 3 次), 谁先出结果就用谁:
            // 搜「大树王容」→ 回退到「大树王」→ 命中歌手「大树王荣」及其专辑。
            if artists.is_empty() || albums.is_empty() || playlists.is_empty() {
                for cand in prefix_candidates(kw) {
                    if !artists.is_empty() && !albums.is_empty() && !playlists.is_empty() {
                        break;
                    }
                    if artists.is_empty() {
                        if let Some(r) = self.cloudsearch_result(&cand, 100, side_limit).await {
                            artists = parse_search_artists(&r);
                        }
                    }
                    if albums.is_empty() {
                        if let Some(r) = self.cloudsearch_result(&cand, 10, side_limit).await {
                            albums = parse_search_albums(&r);
                        }
                    }
                    if playlists.is_empty() {
                        if let Some(r) = self.cloudsearch_result(&cand, 1000, side_limit).await {
                            playlists = parse_search_playlists(&r);
                        }
                    }
                }
            }
            // 用户分类也走同一套最长匹配兜底(空结果时按前缀重试)
            if users.is_empty() {
                for cand in prefix_candidates(kw) {
                    if let Some(r) = self.cloudsearch_result(&cand, 1002, side_limit).await {
                        users = parse_search_users(&r);
                        if !users.is_empty() {
                            break;
                        }
                    }
                }
            }

            // MV 分区不再为了填一个装饰性板块而把关键词截短(用户反馈「咬合力」搜出来
            // 一条同名不同歌的 MV): 空就空着, UI 据此隐藏分区。唯一保留的回退见
            // `should_fallback_for_mv`(整页全空时试最长前缀一次)。相关性用的关键词就是
            // 这一次真正发出去的关键词, 不管是原词还是候选词。
            let mut mv_keywords = kw.to_string();
            if let Some(cand) = should_fallback_for_mv(page_empty, &prefix_candidates(kw)) {
                if let Some(r) = self.cloudsearch_result(&cand, 1004, side_limit).await {
                    mvs = parse_search_mvs(&r);
                    debug_search_mv(kw, &format!("prefix retry {cand:?}"), &mvs);
                    mv_keywords = cand;
                }
            }
            let raw_count = mvs.len();
            filter_sort_mvs(&mv_keywords, &mut mvs);
            debug_search_mv(
                kw,
                &format!(
                    "relevance filter by {mv_keywords:?}: {raw_count} → {}",
                    mvs.len()
                ),
                &mvs,
            );

            Ok(SearchBundle {
                songs: page.songs,
                song_total: page.total,
                artists,
                albums,
                playlists,
                podcasts,
                users,
                mvs,
            })
        })
    }

    /// 搜索热词榜. type=1111 返回 result.hots(按热度排序), 没有特权/登录要求.
    pub(super) fn hot_search(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchTerm>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let key = cache_key(endpoint::SEARCH_HOT, &[]);
            let body = self
                .read_cache()
                .get_or_load(endpoint::SEARCH_HOT, &key, || async {
                    let q = make_query(&cookie, &domain, &ua);
                    let resp = client.search_hot(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            Ok(parse_hot_search(&body))
        })
    }

    /// 热搜榜详情(/api/hotsearchlist/get, weapi, 无参数): 带 score + 榜位.
    pub(super) fn hot_search_detail(
        &self,
    ) -> BoxFuture<'_, ProviderResult<Vec<HotSearchDetailItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let key = cache_key(endpoint::SEARCH_HOT_DETAIL, &[]);
            let body = self
                .read_cache()
                .get_or_load(endpoint::SEARCH_HOT_DETAIL, &key, || async {
                    let q = make_query(&cookie, &domain, &ua);
                    let resp = client.search_hot_detail(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(resp.body)
                })
                .await?;
            Ok(parse_hot_search_detail(&body))
        })
    }

    /// 默认/推荐搜索词("猜你想搜")
    pub(super) fn default_search(&self) -> BoxFuture<'_, ProviderResult<Option<DefaultSearch>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.search_default(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_default_search(&resp.body))
        })
    }

    /// cloudsearch 的通用调用: type = 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1009 播客
    ///
    /// 搜索族唯一的请求出口(单类型搜索 / 综合搜索 6 个板块 / 最长匹配兜底都走这里),
    /// 所以缓存与单飞也放在这一层: 同一个 (keywords, type, limit, offset) 在 TTL 内
    /// 只会真打一次上游。
    pub(super) async fn cloudsearch_body(
        &self,
        keywords: &str,
        kind: u32,
        limit: u32,
        offset: u32,
    ) -> ProviderResult<Value> {
        let (client, domain, ua, cookie) = self.snapshot();
        let key = cache_key(
            endpoint::CLOUDSEARCH,
            &[
                ("keywords", keywords.to_string()),
                ("type", kind.to_string()),
                ("limit", limit.to_string()),
                ("offset", offset.to_string()),
            ],
        );
        self.read_cache()
            .get_or_load(endpoint::CLOUDSEARCH, &key, || async {
                let q = make_query(&cookie, &domain, &ua)
                    .param("keywords", keywords)
                    .param("limit", &limit.to_string())
                    .param("offset", &offset.to_string())
                    .param("type", &kind.to_string());
                let resp = client.cloudsearch(&q).await.map_err(map_error)?;
                check_body(&resp.body)?;
                Ok(resp.body)
            })
            .await
            // 缓存命中是 `Arc<Value>`, 这里解成 owned(调用方要的是 `Value`, 与未命中路径一致)
            .map(|body| body.as_ref().clone())
    }

    /// 取某一个 type 的 result 节点(失败/无命中都给 None, 供「最长匹配」兜底用)
    async fn cloudsearch_result(&self, keywords: &str, kind: u32, limit: u32) -> Option<Value> {
        let body = self.cloudsearch_body(keywords, kind, limit, 0).await.ok()?;
        body.get("result").cloned()
    }
}

/// MV 分区诊断开关: `NCM_DEBUG_SEARCH_MV=1` 时把 type=1004 的原始返回打到 stderr.
///
/// 默认零输出、零行为变化。只打印 MV 的 id/标题/艺人/播放量(不含 cookie/token),
/// 用来判断「MV 分区不相关」到底是上游给错了条目, 还是我们自己放宽了关键词。
fn debug_search_mv(keywords: &str, source: &str, mvs: &[MvItem]) {
    if !debug_search_mv_enabled() {
        return;
    }
    eprintln!(
        "[search-mv] kw={keywords:?} source={source} count={}",
        mvs.len()
    );
    for m in mvs.iter().take(3) {
        eprintln!(
            "[search-mv]   id={} name={:?} artist={:?} play={}",
            m.id, m.name, m.artist_name, m.play_count
        );
    }
}

fn debug_search_mv_enabled() -> bool {
    std::env::var("NCM_DEBUG_SEARCH_MV").is_ok_and(|v| v == "1")
}

/// 整页全空时, MV 分区允许用哪个前缀候选词再试一次(`None` = 不回退)。
///
/// 判据是「整页空」而不是「MV 空」: MV 是装饰性板块, 为了填它把关键词截短, 换来的
/// 往往是同名不同歌的条目(用户反馈「搜『咬合力』出来一条不相干的 MV」就是这么来的)。
/// 只有七个板块一条都没有时, 关键词才更像拼错/太长, 这时放宽一次才值得;
/// 而且只试**最长**的那个候选 —— 截得越短, 命中无关内容的概率越高。
pub(super) fn should_fallback_for_mv(page_empty: bool, candidates: &[String]) -> Option<String> {
    if page_empty {
        candidates.first().cloned()
    } else {
        None
    }
}

/// MV 分区的相关性过滤 + 排序(用户反馈「咬合力」搜出来的 MV 不相关且只有一条)。
///
/// - **保留**: 归一化后 `name` **或** `artist_name` 包含关键词的行。用包含而不是相等,
///   因为上游标题普遍带 ` (Live)` / ` 官方版` / `- MV` 这类后缀, 相等匹配会误杀。
/// - **丢弃**: 两个字段都不包含关键词的行。上游 type=1004 会按字面近似返回同名不同歌、
///   同名不同艺人的 MV, 这就是「不相关还只有一条」的直接来源。
/// - **排序**: 归一化后与关键词**完全相等**的 name 最前, 其余按 `play_count` 降序;
///   同播放量保持上游顺序(`sort_by` 是稳定排序)。
/// - 关键词归一化后为空(纯标点/空白)时全部丢弃: 没有任何可比对的文本, 按
///   「MV 分区宁可空」处理, 单曲等主板块不受影响。
pub fn filter_sort_mvs(keywords: &str, mvs: &mut Vec<MvItem>) {
    let kw = normalize_keyword(keywords);
    if kw.is_empty() {
        mvs.clear();
        return;
    }
    mvs.retain(|mv| {
        normalize_keyword(&mv.name).contains(&kw)
            || normalize_keyword(&mv.artist_name).contains(&kw)
    });
    let exact = |mv: &MvItem| normalize_keyword(&mv.name) == kw;
    mvs.sort_by(|a, b| {
        exact(b)
            .cmp(&exact(a))
            .then_with(|| b.play_count.cmp(&a.play_count))
    });
}

/// 相关性比较用的归一化: 全角→半角、丢掉空白与中英文标点、小写。
///
/// 关键词与 MV 标题/艺人名走同一套(否则「晴天(Jay Chou)」与「晴天（周杰伦）」比不上)。
/// 只在内存里比较, 不参与请求, 也不回传给 UI。
fn normalize_keyword(text: &str) -> String {
    text.chars()
        .map(fold_width)
        .filter(|c| !is_keyword_noise(*c))
        .collect::<String>()
        .to_lowercase()
}

/// 全角 ASCII(U+FF01..=U+FF5E)与全角空格折成半角, 其它字符原样。
fn fold_width(c: char) -> char {
    match c {
        '\u{3000}' => ' ',
        '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        _ => c,
    }
}

/// 归一化时要丢掉的字符: 空白 + ASCII 标点 + 常见中文/排版标点。
///
/// 只列明确的标点, 不用 `\u{3000}..=\u{303F}` 整段: 那一段里的 `々` `〇` 是日文姓名
/// 常用字, 丢掉会让「田中〇〇」这类标题比不中。
fn is_keyword_noise(c: char) -> bool {
    c.is_whitespace()
        || c.is_ascii_punctuation()
        || matches!(
            c,
            '、' | '。'
                | '〈'
                | '〉'
                | '《'
                | '》'
                | '「'
                | '」'
                | '『'
                | '』'
                | '【'
                | '】'
                | '〔'
                | '〕'
                | '～'
                | '〜'
                | '·'
                | '•'
                | '・'
                | '–'
                | '—'
                | '‘'
                | '’'
                | '“'
                | '”'
                | '…'
        )
}

/// 「最长匹配」候选词: 从尾部逐字截短(至少保留 2 字), 最多 3 个候选。
///
/// 用于空分类兜底: cloudsearch 对一字之差的拼写没有纠错, 但前缀搜索通常能命中
/// (「大树王容」→「大树王」→ 歌手「大树王荣」)。全部失败时分类仍为空, UI 显示
/// 「该分类没有匹配结果」而不是隐藏分类。
pub fn prefix_candidates(keywords: &str) -> Vec<String> {
    let chars: Vec<char> = keywords.chars().collect();
    let mut out = Vec::new();
    for drop in 1..=3usize {
        if chars.len() < drop + 2 {
            break;
        }
        out.push(chars[..chars.len() - drop].iter().collect());
    }
    out
}

pub fn parse_search(body: &Value) -> ProviderResult<SearchPage> {
    let result = body
        .get("result")
        .ok_or_else(|| ProviderError::internal("search: missing result"))?;
    let privileges = parse_privileges(body);
    let songs = result
        .get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default();
    Ok(SearchPage {
        songs,
        total: u64_of(result, "songCount").unwrap_or(0),
        has_more: result
            .get("hasMore")
            .and_then(Value::as_bool)
            .or_else(|| result.get("more").and_then(Value::as_bool))
            .unwrap_or(false),
    })
}

/// 综合搜索各板块的解析. 入参是 cloudsearch 的 `result` 对象.
pub fn parse_search_artists(result: &Value) -> Vec<SearchArtist> {
    result
        .get("artists")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    let name = str_of(a, "name").unwrap_or_default();
                    if id == 0 || name.is_empty() {
                        return None;
                    }
                    let avatar = str_of(a, "picUrl")
                        .or_else(|| str_of(a, "img1v1Url"))
                        .filter(|s| !s.is_empty());
                    let alias = a
                        .get("alias")
                        .and_then(Value::as_array)
                        .map(|x| {
                            x.iter()
                                .filter_map(Value::as_str)
                                .filter(|s| !s.is_empty())
                                .collect::<Vec<_>>()
                                .join(" / ")
                        })
                        .unwrap_or_default();
                    Some(SearchArtist {
                        id,
                        name,
                        avatar_url: avatar,
                        alias,
                        album_count: u64_of(a, "albumSize").unwrap_or(0),
                        music_count: u64_of(a, "musicSize").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_albums(result: &Value) -> Vec<SearchAlbum> {
    result
        .get("albums")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    let name = str_of(a, "name").unwrap_or_default();
                    if id == 0 || name.is_empty() {
                        return None;
                    }
                    let cover = str_of(a, "picUrl")
                        .or_else(|| str_of(a, "blurPicUrl"))
                        .filter(|s| !s.is_empty());
                    let artist = str_of(a, "artist")
                        .or_else(|| a.get("artist").and_then(|x| str_of(x, "name")))
                        .or_else(|| {
                            a.get("artists").and_then(Value::as_array).map(|x| {
                                x.iter()
                                    .filter_map(|v| str_of(v, "name"))
                                    .collect::<Vec<_>>()
                                    .join(" / ")
                            })
                        })
                        .unwrap_or_default();
                    Some(SearchAlbum {
                        id,
                        name,
                        cover_url: cover,
                        artist,
                        track_count: u64_of(a, "size").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_playlists(result: &Value) -> Vec<SearchPlaylistItem> {
    result
        .get("playlists")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|p| {
                    let id = u64_of(p, "id")?;
                    let name = str_of(p, "name").unwrap_or_default();
                    if id == 0 {
                        return None;
                    }
                    Some(SearchPlaylistItem {
                        id,
                        name,
                        cover_url: str_of(p, "coverImgUrl").filter(|s| !s.is_empty()),
                        creator_name: p
                            .get("creator")
                            .and_then(|c| str_of(c, "nickname"))
                            .unwrap_or_default(),
                        track_count: u64_of(p, "trackCount").unwrap_or(0),
                        play_count: u64_of(p, "playCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 搜索「MV」: result.mvs[{id,name,cover,artistName,artists[{name}],playCount}]
pub fn parse_search_mvs(result: &Value) -> Vec<MvItem> {
    result
        .get("mvs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let id = u64_of(m, "id")?;
                    let name = str_of(m, "name").unwrap_or_default();
                    if id == 0 || name.is_empty() {
                        return None;
                    }
                    let artist_name = str_of(m, "artistName")
                        .filter(|s| !s.is_empty())
                        .or_else(|| {
                            m.get("artists").and_then(Value::as_array).map(|x| {
                                x.iter()
                                    .filter_map(|v| str_of(v, "name"))
                                    .filter(|n| !n.is_empty())
                                    .collect::<Vec<_>>()
                                    .join(" / ")
                            })
                        })
                        .unwrap_or_default();
                    Some(MvItem {
                        id,
                        name,
                        cover_url: str_of(m, "cover")
                            .or_else(|| str_of(m, "picUrl"))
                            .or_else(|| str_of(m, "imgurl"))
                            .filter(|s| !s.is_empty()),
                        artist_name,
                        play_count: u64_of(m, "playCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 搜索「用户」: result.userprofiles[{userId,nickname,avatarUrl,signature}]
pub fn parse_search_users(result: &Value) -> Vec<UserItem> {
    result
        .get("userprofiles")
        .or_else(|| result.get("users"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|u| {
                    let id = u64_of(u, "userId").or_else(|| u64_of(u, "id"))?;
                    let name = str_of(u, "nickname")
                        .or_else(|| str_of(u, "name"))
                        .unwrap_or_default();
                    if name.is_empty() {
                        return None;
                    }
                    Some(UserItem {
                        id,
                        name,
                        avatar_url: str_of(u, "avatarUrl")
                            .or_else(|| str_of(u, "picUrl"))
                            .filter(|s| s.starts_with("http")),
                        signature: str_of(u, "signature").unwrap_or_default(),
                        followed: u.get("followed").and_then(Value::as_bool).unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_podcasts(result: &Value) -> Vec<SearchPodcast> {
    result
        .get("djRadios")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|r| {
                    let id = u64_of(r, "id")?;
                    let name = str_of(r, "name").unwrap_or_default();
                    if id == 0 {
                        return None;
                    }
                    Some(SearchPodcast {
                        id,
                        name,
                        cover_url: str_of(r, "picUrl").filter(|s| !s.is_empty()),
                        dj_name: r
                            .get("dj")
                            .and_then(|d| str_of(d, "nickname"))
                            .unwrap_or_default(),
                        program_count: u64_of(r, "programCount").unwrap_or(0),
                        play_count: u64_of(r, "playCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 联想每类最多保留多少条(服务端一般只给 2~6 条, 这里只是防异常大的响应).
const SUGGEST_PER_KIND_MAX: usize = 10;

/// 一条联想候选 + 判断「是不是我关注的人」用的艺人 id.
struct SuggestEntry {
    item: SuggestItem,
    /// 这首歌/专辑/MV 的艺人, 或艺人条目本身.
    artist_ids: Vec<u64>,
}

/// 搜索建议的响应形如
/// {code:200, result:{order:[songs,artists,albums,playlists], songs:[], artists:[], albums:[], playlists:[]}}
///
/// 解析成**按 kind 分组**的结构(组内保持服务端顺序), 交给 rank_suggest 排序后
/// 再扁平化 —— 分组信息是「相关的类提到前面」必须的, 扁平后就丢了.
fn parse_suggest_groups(body: &Value) -> Vec<(String, Vec<SuggestEntry>)> {
    let Some(result) = body.get("result") else {
        return Vec::new();
    };
    let order: Vec<String> = result
        .get("order")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_else(|| {
            vec![
                "songs".to_string(),
                "artists".to_string(),
                "albums".to_string(),
                "playlists".to_string(),
            ]
        });
    let mut groups = Vec::new();
    for key in order {
        let kind = match key.as_str() {
            "songs" => "song",
            "artists" => "artist",
            "albums" => "album",
            "playlists" => "playlist",
            // 联想响应若带 MV 分类(部分账号/版本会回 mvs), 映射成 UI 的 mv 分组.
            // 主流账号目前不带该 key, 这里只是容错, 不改变其它分类.
            "mvs" | "mv" => "mv",
            _ => continue,
        };
        let Some(arr) = result.get(&key).and_then(Value::as_array) else {
            continue;
        };
        let mut entries = Vec::new();
        for v in arr.iter().take(SUGGEST_PER_KIND_MAX) {
            let Some(id) = u64_of(v, "id") else { continue };
            let title = str_of(v, "name").unwrap_or_default();
            if title.is_empty() {
                continue;
            }
            // 封面: 建议接口的专辑对象自己带 picUrl, 歌曲只带 album.picId(没有 URL),
            // 所以歌曲这里拿不到就留 None, 由 fill_suggest_song_covers 批量补.
            let (subtitle, cover_url) = match kind {
                "song" => (
                    artists_line_of(v),
                    v.get("album")
                        .and_then(|a| str_of(a, "picUrl"))
                        .or_else(|| v.get("al").and_then(|a| str_of(a, "picUrl")))
                        .or_else(|| str_of(v, "picUrl"))
                        .filter(|s| !s.is_empty()),
                ),
                "artist" => (
                    "歌手".to_string(),
                    str_of(v, "picUrl").or_else(|| str_of(v, "img1v1Url")),
                ),
                "album" => (
                    v.get("artist")
                        .and_then(|a| str_of(a, "name"))
                        .unwrap_or_default(),
                    // 专辑封面优先用**专辑自己的** picUrl: 以前先取 artist.picUrl,
                    // 于是一整列联想专辑显示的都是歌手头像(用户反馈「图不对/像占位」).
                    str_of(v, "picUrl")
                        .or_else(|| v.get("artist").and_then(|a| str_of(a, "picUrl"))),
                ),
                "mv" => (
                    {
                        let artist = v
                            .get("artistName")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .filter(|s| !s.is_empty())
                            .unwrap_or_else(|| artists_line_of(v));
                        if artist.is_empty() {
                            "MV".to_string()
                        } else {
                            format!("MV · {artist}")
                        }
                    },
                    str_of(v, "cover")
                        .or_else(|| str_of(v, "picUrl"))
                        .or_else(|| str_of(v, "imgurl")),
                ),
                _ => (
                    format!(
                        "歌单 · {} 首",
                        u64_of(v, "trackCount")
                            .or_else(|| u64_of(v, "bookCount"))
                            .unwrap_or(0)
                    ),
                    str_of(v, "coverImgUrl").or_else(|| str_of(v, "picUrl")),
                ),
            };
            entries.push(SuggestEntry {
                artist_ids: suggest_artist_ids_of(v),
                item: SuggestItem {
                    kind: kind.to_string(),
                    id,
                    title,
                    subtitle,
                    cover_url: cover_url.filter(|s| !s.is_empty()),
                },
            });
        }
        if !entries.is_empty() {
            groups.push((kind.to_string(), entries));
        }
    }
    groups
}

/// 一条联想条目涉及的艺人 id(歌曲的每位艺人 / 专辑的艺人 / 艺人自己 / MV 的艺人).
fn suggest_artist_ids_of(v: &Value) -> Vec<u64> {
    let mut out: Vec<u64> = Vec::new();
    if let Some(id) = u64_of(v, "artistId") {
        out.push(id);
    }
    for key in ["artists", "ar"] {
        if let Some(arr) = v.get(key).and_then(Value::as_array) {
            for a in arr {
                if let Some(id) = u64_of(a, "id") {
                    out.push(id);
                }
            }
        }
    }
    if let Some(id) = v.get("artist").and_then(|a| u64_of(a, "id")) {
        out.push(id);
    }
    if let Some(id) = v.get("creator").and_then(|c| u64_of(c, "userId")) {
        out.push(id);
    }
    if let Some(id) = u64_of(v, "id") {
        out.push(id);
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// 按「与我关注的人相关」重排联想:
/// ① 相关的类比其它类整体提前(类内顺序不变);
/// ② 类内相关的条目提到组内前面(同样保持原顺序).
///
/// 用户反馈: 搜 "Chinese" 时首屏被一个冷门同名艺人占住, 而自己关注的
/// Chinese Football 排在后面 —— 关注就是最强的相关性信号, 应该先给出来.
/// UI 侧取「扁平后第一条的 kind」作为默认选中的分类, 所以类级别的提前
/// 同时决定了默认打开哪个分类页.
fn rank_suggest(
    groups: Vec<(String, Vec<SuggestEntry>)>,
    followed: &std::collections::HashSet<u64>,
) -> Vec<SuggestItem> {
    let is_related = |e: &SuggestEntry| e.artist_ids.iter().any(|id| followed.contains(id));
    let mut ranked: Vec<(bool, Vec<SuggestEntry>)> = groups
        .into_iter()
        .map(|(_, mut entries)| {
            let related = entries.iter().filter(|e| is_related(e)).count();
            // 稳定分区: related 在前, 各自保持服务端顺序
            let mut hot = Vec::with_capacity(related);
            let mut rest = Vec::with_capacity(entries.len() - related);
            for e in entries.drain(..) {
                if is_related(&e) {
                    hot.push(e);
                } else {
                    rest.push(e);
                }
            }
            hot.extend(rest);
            (related > 0, hot)
        })
        .collect();
    // 稳定排序: 相关的类在前
    ranked.sort_by_key(|(related, _)| !*related);
    ranked
        .into_iter()
        .flat_map(|(_, entries)| entries.into_iter().map(|e| e.item))
        .collect()
}

/// 公开解析入口(单测/不关心个性化的调用方): 不做关注重排.
pub fn parse_suggest(body: &Value) -> Vec<SuggestItem> {
    parse_suggest_with_followed(body, &[])
}

/// 带上「我关注的艺人 id」解析: 与 provider 生产路径同一条排序(便于单测/诊断).
pub fn parse_suggest_with_followed(body: &Value, followed: &[u64]) -> Vec<SuggestItem> {
    let followed: std::collections::HashSet<u64> = followed.iter().copied().collect();
    rank_suggest(parse_suggest_groups(body), &followed)
}

/// 搜索热词榜的响应形如
///   {code:200, result:{hots:[{first:"...", keyword:"晴天", iconType:1}, ...]}}
/// 老版本/其它通道也可能给 result.hotKeywords 或 data[] 字符串.
pub fn parse_hot_search(body: &Value) -> Vec<HotSearchTerm> {
    let arr = body
        .get("result")
        .and_then(|r| r.get("hots").or_else(|| r.get("hotKeywords")))
        .or_else(|| body.get("data"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for v in arr {
        let keyword = str_of(v, "keyword")
            .or_else(|| str_of(v, "first"))
            .or_else(|| v.as_str().map(str::to_string))
            .unwrap_or_default();
        let keyword = keyword.trim().to_string();
        if keyword.is_empty() {
            continue;
        }
        out.push(HotSearchTerm {
            rank: out.len() as u32 + 1,
            keyword,
        });
    }
    out
}

/// 联想下拉的纯关键词候选(vendor `search_suggest` 的 mobile 分支).
///
/// 请求: `client.search_suggest(&q.param("type","mobile").param("keywords", kw))`
/// → vendor 打 `/api/search/suggest/keyword`, 响应形如
///   {code:200, result:{allMatch:[{keyword:"晴天周杰伦", type:1, alg:"…", feature:"", lastKeyword:""}]}}
/// (实测固定 6 条, 无分页). 只有 `keyword` 可用, alg/feature 是埋点, 忽略.
///
/// 处理: 去掉首尾空白 + 丢弃空串 + **去重保序**(服务端可能给重复词), 最多 6 条.
pub fn parse_suggest_keywords(body: &Value) -> Vec<String> {
    const MAX: usize = 6;
    let Some(arr) = body
        .get("result")
        .and_then(|r| r.get("allMatch"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    let mut out: Vec<String> = Vec::new();
    for v in arr {
        let Some(kw) = str_of(v, "keyword") else {
            continue;
        };
        let kw = kw.trim().to_string();
        if kw.is_empty() || out.iter().any(|x| x == &kw) {
            continue;
        }
        out.push(kw);
        if out.len() >= MAX {
            break;
        }
    }
    out
}

/// 精确实体改写(vendor `search_multimatch`, POST /api/search/suggest/multimatch w/ eapi).
///
/// 响应形如(实测 2026-11-07):
///   {code:200, result:{
///      orders:["artist","playlist"],                    // 命中类型顺序, 同时是「有哪个 key」的清单
///      artist:[{id,name,picUrl,alias:[…],…}],           // 最多 1 条, picUrl 是头像(http)
///      playlist:[{id,name,coverImgUrl,trackCount,…}],   // 最多 1 条
///      voice:[{resourceId,resourceName,baseInfo:{…}}]    // 电台/播客节目, id/name 在 baseInfo 里
///   }}
///
/// **空命中伪装成功**: 无命中回 `{"code":200,"result":{"orders":[]}}`, 各类型 key 直接不存在.
/// 这里按 orders 判空 → 返回 [`SearchExact::default()`], 绝不报错.
pub fn parse_search_exact(body: &Value) -> SearchExact {
    let Some(result) = body.get("result") else {
        return SearchExact::default();
    };
    let orders: Vec<String> = result
        .get("orders")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    if orders.is_empty() {
        return SearchExact::default();
    }
    let arr_of = |key: &str| -> Vec<Value> {
        result
            .get(key)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    };
    let artists = arr_of("artist")
        .iter()
        .filter_map(|v| {
            let id = u64_of(v, "id")?;
            let name = str_of(v, "name").unwrap_or_default();
            Some(Artist {
                id,
                name,
                avatar_url: str_of(v, "picUrl").filter(|s| !s.is_empty()),
            })
        })
        .collect();
    let playlists = arr_of("playlist")
        .iter()
        .filter_map(|v| {
            let id = u64_of(v, "id")?;
            Some(Playlist {
                id,
                name: str_of(v, "name").unwrap_or_default(),
                cover_url: str_of(v, "coverImgUrl").filter(|s| !s.is_empty()),
                track_count: u64_of(v, "trackCount").unwrap_or(0),
                special: u64_of(v, "specialType").map(|t| t == 5).unwrap_or(false),
                subscribed: v
                    .get("subscribed")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect();
    let podcasts = arr_of("voice")
        .iter()
        .filter_map(parse_voice_radio)
        .collect();
    SearchExact {
        orders,
        artists,
        playlists,
        podcasts,
    }
}

/// 热搜榜详情(vendor `search_hot_detail`, POST /api/hotsearchlist/get w/ eapi, body 空).
///
/// 实测响应(2026-11-07):
///   {code:200, message:null, trp:null, data:[
///      {searchWord:"天龙八部之宿敌", score:91197, iconType:4,
///       iconUrl:"https://p1.music.126.net/….png", content:"", source:0, url:"", alg?:…}
///      … 固定 20 条 …]}
/// 注意: **服务端不给 rank 字段**, 榜位就是数组顺序(rank = 下标 + 1);
/// iconType 0 = 无图标, 2/4/5 = 不同角标; content/url/source 目前恒空.
pub fn parse_hot_search_detail(body: &Value) -> Vec<HotSearchDetailItem> {
    let Some(arr) = body.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for v in arr {
        let keyword = str_of(v, "searchWord")
            .or_else(|| str_of(v, "keyword"))
            .unwrap_or_default()
            .trim()
            .to_string();
        if keyword.is_empty() {
            continue;
        }
        out.push(HotSearchDetailItem {
            keyword,
            rank: out.len() as u32 + 1,
            score: u64_of(v, "score").unwrap_or(0),
            icon_type: u64_of(v, "iconType").unwrap_or(0) as u32,
        });
    }
    out
}

/// 默认搜索词的响应形如
/// {code:200, data:{showKeyword:"🔥The Weeknd 最近很火哦", realkeyword:"The Weeknd", imageUrl:null}}
///
/// 线上(2026-11-06 实测)只有这一条: showKeyword 是"关键词 + 推荐理由"拼成的
/// 展示文案, realkeyword 才是应该拿去搜的词。两者必须分开交给 UI,
/// 否则点一下会把"最近很火哦"也当成关键词搜出去。
pub fn parse_default_search(body: &Value) -> Option<DefaultSearch> {
    let data = body.get("data").unwrap_or(body);
    // showKeyword 只在没有 realkeyword 时兜底(它的文案里带推荐理由)
    let keyword = ["realkeyword", "defaultKeyword", "keyword", "showKeyword"]
        .iter()
        .find_map(|key| str_of(data, key))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())?;
    let show = str_of(data, "showKeyword")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| keyword.clone());
    Some(DefaultSearch {
        show_text: show,
        keyword,
        image_url: str_of(data, "imageUrl").filter(|s| !s.is_empty()),
    })
}
#[cfg(test)]
mod tests {
    use super::prefix_candidates;

    #[test]
    fn prefix_candidates_trims_tail_down_to_two_chars() {
        // 「大树王容」拼错一个字: 依次试「大树王」「大树王」再往前 —— 最长匹配优先
        assert_eq!(prefix_candidates("大树王容"), vec!["大树王", "大树"]);
        // 两字词没有可截短的候选(至少保留 2 字)
        assert!(prefix_candidates("发").is_empty());
        assert!(prefix_candidates("晴天").is_empty());
        // 英文/emoji 也按字符(不是字节)截断, 不会切坏 UTF-8
        assert_eq!(prefix_candidates("abcd"), vec!["abc", "ab"]);
    }
}
#[cfg(test)]
mod user_search_tests {
    use super::parse_search_users;
    use serde_json::json;

    #[test]
    fn parse_search_users_reads_userprofiles() {
        let body = json!({
            "userprofiles": [
                {"userId": 7, "nickname": "小明", "avatarUrl": "https://x/y.jpg", "signature": "hi"},
                {"userId": 0, "nickname": ""}
            ]
        });
        let users = parse_search_users(&body);
        assert_eq!(users.len(), 1);
        assert_eq!(users[0].id, 7);
        assert_eq!(users[0].name, "小明");
        assert_eq!(users[0].signature, "hi");
    }
}
