//! 综合搜索 MV 分区的相关性口径(2026-11-25 用户反馈「咬合力」搜出来一条不相干的 MV).
//!
//! 两条纪律各自一组用例:
//! - [`filter_sort_mvs`]: 上游 type=1004 会返回同名不同歌/同名不同艺人的条目,
//!   归一化后 `name` 或 `artist_name` 不含关键词的一律丢弃, 相等名优先、再按播放量;
//! - 前缀截短回退: MV 分区不再因为自己空就去放宽关键词, 只有整页全空才试最长前缀一次。
//!
//! 第二条只能端到端断言: 上游的 `type` 在 eapi 密文里, 所以这里起的假服务先
//! 用 vendor 的 `eapi_req_decrypt` 把请求解开, 才能按 `(type, 关键词)` 计数。

use crate::netease::search::{filter_sort_mvs, should_fallback_for_mv};
use crate::netease::NeteaseProvider;
use ncm_domain::{MvItem, SearchBundle, Session};
use ncm_provider::SearchQuery;
use serde_json::{json, Value};
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn mv(id: u64, name: &str, artist: &str, play: u64) -> MvItem {
    MvItem {
        id,
        name: name.to_string(),
        cover_url: None,
        artist_name: artist.to_string(),
        play_count: play,
    }
}

/// 全都不匹配 ⇒ 分区为空(UI 据此隐藏 MV 分类, 而不是摆一条无关的)。
///
/// 修复前 `parse_search_mvs` 原样收上游返回 ⇒ 三条都会留下, 这条用例是红的。
#[test]
fn filter_sort_mvs_drops_rows_that_match_nothing() {
    let mut mvs = vec![
        mv(1, "咬合关系学讲座", "某大学", 900),
        mv(2, "咀嚼肌放松教程", "康复科老王", 800),
        mv(3, "今日热门 MV 合集", "站内编辑", 700),
    ];
    filter_sort_mvs("咬合力", &mut mvs);
    assert!(mvs.is_empty(), "一条都不相关就该全丢, 实际留下 {mvs:?}");
}

/// 混合(1 条匹配 + 2 条不匹配)⇒ 只留匹配那条。
///
/// 匹配算「包含」而不是「相等」: 上游标题常带 ` (Live)` / ` 官方版` 这类后缀,
/// 标题里带标点/全角/大小写差异也不能误杀; 歌手名命中同样算相关。
#[test]
fn filter_sort_mvs_keeps_only_relevant_rows() {
    let mut mvs = vec![
        mv(1, "咬合力 (Live)", "某乐队", 10),
        mv(2, "完全无关的MV", "咬合力", 20), // 歌手名命中 ⇒ 保留
        mv(3, "别的歌的MV", "别人", 9999),
    ];
    filter_sort_mvs("咬合力", &mut mvs);
    let ids: Vec<u64> = mvs.iter().map(|m| m.id).collect();
    assert_eq!(
        ids,
        vec![2, 1],
        "只该留下标题或歌手命中的两条(都是包含命中 ⇒ 按播放量降序)"
    );

    // 大小写/标点/全角/空白的差异都不算不匹配
    let mut mvs = vec![
        mv(4, "TAYLOR'S  VERSION", "Taylor Swift", 5),
        mv(5, "咬合力（官方版）", "某乐队", 5),
    ];
    filter_sort_mvs("taylors version", &mut mvs);
    let ids: Vec<u64> = mvs.iter().map(|m| m.id).collect();
    assert_eq!(ids, vec![4], "归一化后同名, 中文那条仍应被丢");

    let mut mvs = vec![mv(6, "咬合力（官方版）", "某乐队", 5)];
    filter_sort_mvs("咬 合 力", &mut mvs);
    assert_eq!(mvs.len(), 1, "关键词里的空白不算差异");

    // 关键词归一化后为空(纯标点): 没有任何可比对的文本, 按「宁可空」处理
    let mut mvs = vec![mv(7, "任意 MV", "任意人", 5)];
    filter_sort_mvs("！？", &mut mvs);
    assert!(mvs.is_empty());
}

/// 排序: 归一化后与关键词完全相等的名字最优先, 其余按播放量降序;
/// 播放量相同保持上游顺序(稳定排序)。
#[test]
fn filter_sort_mvs_prefers_exact_name_then_play_count() {
    let mut mvs = vec![
        mv(1, "咬合力 现场版", "A", 1000),
        mv(2, "咬合力", "B", 1),
        mv(3, "咬合力 官方版", "C", 500),
        mv(4, "咬合力 (Acoustic)", "D", 1000),
        mv(5, "咬合关系学", "E", 9999), // 不含关键词 ⇒ 先被丢, 不参与排序
    ];
    filter_sort_mvs("咬合力", &mut mvs);
    let ids: Vec<u64> = mvs.iter().map(|m| m.id).collect();
    assert_eq!(
        ids,
        vec![2, 1, 4, 3],
        "完全相等的第一, 其余播放量降序、同播放量保持原顺序"
    );
    // 归一化后相等(标点/大小写差异)同样算「完全相等」, 与播放量无关
    let mut mvs = vec![
        mv(6, "Hey Jude (Live)", "The Beatles", 9000),
        mv(7, "Hey, Jude", "The Beatles", 1),
    ];
    filter_sort_mvs("hey jude", &mut mvs);
    let ids: Vec<u64> = mvs.iter().map(|m| m.id).collect();
    assert_eq!(ids, vec![7, 6]);
}

/// 前缀回退的门: 只有整页全空才允许再试, 且只试最长的那个候选。
#[test]
fn mv_prefix_fallback_only_when_whole_page_empty() {
    let cands = || vec!["咬合".to_string(), "咬".to_string()];
    // MV 空但整页有结果 ⇒ 不回退(修复前正是这里放行, 才有那条不相关 MV)
    assert_eq!(should_fallback_for_mv(false, &cands()), None);
    // 整页全空 ⇒ 只试第一个(最长)候选
    assert_eq!(
        should_fallback_for_mv(true, &cands()),
        Some("咬合".to_string())
    );
    // 没有可截短的候选(两字以下的词)⇒ 不回退
    assert_eq!(should_fallback_for_mv(true, &[]), None);
}

// ---------------------------------------------------------------- 端到端计数

/// 一次 cloudsearch 请求解密后的关键信息。
#[derive(Debug, Clone, PartialEq, Eq)]
struct Call {
    kind: i64,
    keywords: String,
}

/// 假上游的内容策略。
struct Plan {
    /// 第一次直连的关键词(整页/各板块按它决定有没有内容)
    direct: &'static str,
    /// 直连关键词时各板块是否已经有结果
    sections_on_direct: bool,
    /// 前缀候选词时 MV 分区返回的行
    mv_on_prefix: Vec<Value>,
}

impl Plan {
    fn body_for(&self, kind: i64, keywords: &str) -> String {
        let rows = if keywords == self.direct {
            self.sections_on_direct
        } else {
            true
        };
        let (id, label): (u64, String) = (7000, format!("{keywords}·板块条目"));
        let mvs = if keywords == self.direct {
            Vec::new()
        } else {
            self.mv_on_prefix.clone()
        };
        let single = |row: Value| -> Vec<Value> {
            if rows {
                vec![row]
            } else {
                Vec::new()
            }
        };
        let result = match kind {
            1 => json!({
                "songCount": if rows { 1 } else { 0 },
                "songs": single(json!({"id": id, "name": label,
                                        "ar": [{"id": 1, "name": "艺人"}],
                                        "al": {"id": 1, "name": "专辑"},
                                        "dt": 1000})),
            }),
            100 => json!({"artists": single(json!({"id": id, "name": label}))}),
            10 => json!({"albums": single(json!({"id": id, "name": label}))}),
            1000 => json!({"playlists": single(json!({"id": id, "name": label}))}),
            1002 => json!({"userprofiles": single(json!({"userId": id, "nickname": label}))}),
            1004 => json!({"mvs": mvs}),
            _ => json!({}),
        };
        json!({"code": 200, "result": result}).to_string()
    }
}

/// 常驻假 cloudsearch 服务: 解密 eapi 请求 ⇒ 按 `(type, 关键词)` 回包并记账。
struct FakeSearch {
    base: String,
    calls: Arc<Mutex<Vec<Call>>>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl FakeSearch {
    fn start(plan: Plan) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定本地端口");
        let addr = listener.local_addr().expect("取本地端口");
        listener
            .set_nonblocking(true)
            .expect("假服务设为非阻塞(靠 stop 退出)");
        let calls = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (plan_tx, calls_tx, stop_tx) = (Arc::new(plan), calls.clone(), stop.clone());
        let thread = std::thread::spawn(move || {
            while !stop_tx.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        if let Err(e) = serve_one(stream, &plan_tx, &calls_tx) {
                            eprintln!("[fake-search] 连接处理失败: {e}");
                        }
                    }
                    Err(e) if e.kind() == ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(2))
                    }
                    Err(e) => panic!("假服务 accept 失败: {e}"),
                }
            }
        });
        Self {
            base: format!("http://{addr}"),
            calls,
            stop,
            thread: Some(thread),
        }
    }

    /// 某个 type 被请求了几次(= 上游真被打了几次)
    fn count_of(&self, kind: i64) -> usize {
        self.calls
            .lock()
            .expect("取请求记录")
            .iter()
            .filter(|c| c.kind == kind)
            .count()
    }

    fn keywords(&self) -> Vec<String> {
        self.calls
            .lock()
            .expect("取请求记录")
            .iter()
            .map(|c| c.keywords.clone())
            .collect()
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            t.join().expect("假服务线程未 panic");
        }
    }
}

impl Drop for FakeSearch {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 读一个请求、按 plan 回包、把解密出来的 (type, 关键词) 记进账本。
fn serve_one(
    mut stream: TcpStream,
    plan: &Plan,
    calls: &Arc<Mutex<Vec<Call>>>,
) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut raw = Vec::new();
    let mut buf = [0u8; 4096];
    let header_end = loop {
        if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
        let n = stream.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        raw.extend_from_slice(&buf[..n]);
    };
    let head = String::from_utf8_lossy(&raw[..header_end]).to_string();
    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or_default().to_string();
    let content_length = lines
        .filter_map(|l| l.split_once(':'))
        .filter(|(k, _)| k.trim().eq_ignore_ascii_case("content-length"))
        .filter_map(|(_, v)| v.trim().parse::<usize>().ok())
        .next()
        .unwrap_or(0);
    let mut body = raw[header_end..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut buf)?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&buf[..n]);
    }
    let body = String::from_utf8_lossy(&body).to_string();

    let (kind, keywords, reply) = match decrypt_cloudsearch(&body) {
        Some((kind, keywords)) => {
            let reply = plan.body_for(kind, &keywords);
            (kind, keywords, reply)
        }
        // 解不出来就如实记账并回空结果: 断言会因为 kind=-1 而失败, 比 panic 好查
        None => (
            -1,
            format!("<未解密: {request_line}>"),
            json!({"code": 200, "result": {}}).to_string(),
        ),
    };
    calls
        .lock()
        .expect("取请求记录")
        .push(Call { kind, keywords });
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
        reply.len()
    );
    stream.write_all(resp.as_bytes())?;
    stream.flush()?;
    Ok(())
}

/// eapi 请求体是 `params=<hex>`, `type`/`s` 都在密文里 —— 不解开就没法按板块计数。
fn decrypt_cloudsearch(body: &str) -> Option<(i64, String)> {
    let params = body
        .split('&')
        .find_map(|pair| pair.strip_prefix("params="))?;
    let (_url, data) = ncm_api_rs::crypto::eapi_req_decrypt(params)?;
    let kind = data.get("type")?.as_i64()?;
    let keywords = data.get("s")?.as_str()?.to_string();
    Some((kind, keywords))
}

/// 用假服务跑一次综合搜索。
async fn search_all(base: String, keywords: &str) -> SearchBundle {
    let p = NeteaseProvider::with_domain_for_test(Session::default(), base);
    let q = SearchQuery::new(keywords);
    tokio::time::timeout(Duration::from_secs(20), p.search_all(&q))
        .await
        .expect("假服务应在超时内回包")
        .expect("综合搜索不应报错")
}

/// MV 为空时**不再发第二次 type=1004**: 关键词原样, 分区空着。
///
/// 假上游故意在第二次 1004 请求(前缀词「咬合」)里塞一条同名不同歌的 MV —— 这正是
/// 用户看到的那一条。修复前: 打了 2 次 1004、分区里多出一条无关 MV ⇒ 两处都红。
#[tokio::test]
async fn search_all_never_retries_mv_with_a_shorter_keyword() {
    let mut fake = FakeSearch::start(Plan {
        direct: "咬合力",
        sections_on_direct: true,
        mv_on_prefix: vec![
            json!({"id": 555, "name": "咬合 关系｜公开课", "artistName": "某大学", "playCount": 12}),
        ],
    });
    let bundle = search_all(fake.base.clone(), "咬合力").await;
    fake.stop();

    assert_eq!(
        fake.count_of(1004),
        1,
        "MV 板块空着就空着, 不该用截短的关键词再打一次 1004"
    );
    assert!(
        bundle.mvs.is_empty(),
        "不相关的 MV 必须被丢掉, 实际留下 {:?}",
        bundle.mvs
    );
    assert_eq!(
        bundle.artists.len() + bundle.albums.len() + bundle.playlists.len(),
        3,
        "整页并不空: 三个板块各有一条(前提条件, 否则这条用例证明不了门在起作用)"
    );
    assert!(
        fake.keywords().iter().all(|k| k == "咬合力"),
        "任何板块都不该在整页不空时放宽关键词: {:?}",
        fake.keywords()
    );
}

/// 整页所有板块都空时, MV 允许跟着试一次 —— 且只试最长前缀一次。
///
/// 「大树王容容」直连什么都没有, 截一个字的「大树王容」才有结果: 各板块都补上,
/// MV 拿到一条与**候选词**相关的条目(相关性按真正发出去的那个词判)。
#[tokio::test]
async fn search_all_retries_mv_once_with_longest_prefix_when_page_empty() {
    let mut fake = FakeSearch::start(Plan {
        direct: "大树王容容",
        sections_on_direct: false,
        mv_on_prefix: vec![
            json!({"id": 556, "name": "大树王容 - MV", "artistName": "大树王荣", "playCount": 3}),
        ],
    });
    let bundle = search_all(fake.base.clone(), "大树王容容").await;
    fake.stop();

    assert_eq!(
        bundle.mvs.iter().map(|m| m.id).collect::<Vec<_>>(),
        vec![556],
        "整页全空时 MV 可以跟着回退一次"
    );
    assert_eq!(fake.count_of(1004), 2, "直连一次 + 回退一次");
    let mut kinds = fake.keywords();
    kinds.sort();
    kinds.dedup();
    assert_eq!(
        kinds,
        vec!["大树王容".to_string(), "大树王容容".to_string()],
        "只允许试最长前缀一次, 不能一路截到『大树王』『大树』"
    );
}
