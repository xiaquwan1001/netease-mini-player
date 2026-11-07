//! ncm — headless 命令行: 没有 UI 也能验证协议/身份/取链全链路.
//!
//! 用法:
//!   ncm whoami
//!   ncm search "晴天" [--limit 10] [--offset 0] [--json]
//!   ncm url <id> [--level exhigh] [--download out.flac] [--json]
//!   ncm lyric <id> [--json]
//!   ncm yrc <songId>               逐字歌词(前 10 行 + 统计)
//!   ncm detail <id[,id...]>        打印曲目详情 + privilege(版权/可播性), 排障用
//!   ncm playlist-detail <id>       歌单详情(标题/创建者/曲目数/评论数)
//!   ncm comments <song|playlist|album|podcast> <id> [limit]   评论列表(展示前 3 条)
//!   ncm comment-info <song|playlist|album|podcast|mv|video> <id>  评论统计(评论数/分享数/点赞数)
//!   ncm podcast-radio <id>         播客/电台详情(标题/主播/节目数)
//!   ncm login-cookie "MUSIC_U=...; __csrf=..."
//!   ncm digital <albumId>            数字专辑详情(价格/标签/是否已购)
//!   ncm digital-purchased [limit] [offset]   我的已购数字专辑(需登录)
//!   ncm purchased-songs [limit] [offset]     我的已购单曲(需登录)
//!   ncm digital-sales <id[,id...]>   数字专辑销量
//!   ncm radio-cats                 电台分类 + 各分类精选(匿名可用)
//!   ncm radio-rec <cateId>         某分类推荐电台
//!   ncm radio-top <hot|new|pay|hours|newcomer|popular|program>  电台榜单
//!   ncm radio-sub <radioId> [limit]  电台订阅者列表(只读)
//!
//! 数据目录: $NCM_DATA_DIR 或 $HOME/.local/share/ncm

use std::path::PathBuf;
use std::process::ExitCode;

use ncm_domain::TrackId;
use ncm_provider::{AudioLevel, Capability, Provider, SearchQuery, SongUrlRequest};
use ncm_service::identity::merge_device_cookie;
use ncm_service::Core;

type BoxErr = Box<dyn std::error::Error>;

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

fn data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("NCM_DATA_DIR") {
        return PathBuf::from(dir);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".local/share/ncm")
}

struct Args {
    cmd: String,
    positional: Vec<String>,
    flags: Vec<String>,
}

impl Args {
    fn parse() -> Self {
        let mut it = std::env::args().skip(1);
        let cmd = it.next().unwrap_or_default();
        let mut positional = Vec::new();
        let mut flags = Vec::new();
        let rest: Vec<String> = it.collect();
        let mut i = 0;
        while i < rest.len() {
            let a = &rest[i];
            if let Some(name) = a.strip_prefix("--") {
                if name.contains('=') {
                    flags.push(a.clone());
                } else if let Some(next) = rest.get(i + 1).filter(|n| !n.starts_with("--")) {
                    flags.push(format!("{a}={next}"));
                    i += 1;
                } else {
                    flags.push(a.clone());
                }
            } else {
                positional.push(a.clone());
            }
            i += 1;
        }
        Self { cmd, positional, flags }
    }

    fn has(&self, name: &str) -> bool {
        self.flags.iter().any(|f| f == name)
    }

    fn value(&self, name: &str) -> Option<String> {
        let p = format!("{name}=");
        self.flags.iter().find_map(|f| f.strip_prefix(&p).map(str::to_string))
    }
}

async fn run() -> Result<(), BoxErr> {
    let args = Args::parse();
    let mut core = Core::open(&data_dir())?;

    match args.cmd.as_str() {
        "whoami" => whoami(&core),
        "login-cookie" => {
            let incoming = args
                .positional
                .first()
                .ok_or("usage: ncm login-cookie \"MUSIC_U=...\"")?;
            let cookie = merge_device_cookie(&core.session.cookie, incoming, &core.session.device_id);
            let mut next = core.session.clone();
            next.cookie = cookie;
            core.apply_session(next)?;
            println!("cookie saved -> {}", core.store.path().display());
            println!("logged_in = {}", core.session.is_logged_in());
            Ok(())
        }
        "search" => {
            let kw = args
                .positional
                .first()
                .ok_or("usage: ncm search <keywords>")?;
            let mut q = SearchQuery::new(kw.clone());
            if let Some(l) = args.value("--limit") {
                q.limit = l.parse()?;
            }
            if let Some(o) = args.value("--offset") {
                q.offset = o.parse()?;
            }
            let p = provider(&core, Capability::Search)?;
            announce(&core);
            let page = p.search(&q).await?;
            if args.has("--json") {
                println!("{}", serde_json::to_string_pretty(&page)?);
            } else {
                println!("total={} has_more={}", page.total, page.has_more);
                for (i, s) in page.songs.iter().enumerate() {
                    println!(
                        "{:>3}. [{}] {} — {} ({:.0}s) fee={:?} vip={}",
                        i + 1,
                        s.id,
                        s.name,
                        s.artist_line(),
                        s.duration_ms as f64 / 1000.0,
                        s.fee,
                        if s.is_vip() { "Y" } else { "N" }
                    );
                }
            }
            Ok(())
        }
        "searchall" => {
            let kw = args.positional.first().ok_or("usage: ncm searchall <keywords>")?;
            let p = provider(&core, Capability::SearchAll)?;
            announce(&core);
            let mut q = SearchQuery::new(kw.clone());
            if let Some(l) = args.value("--limit") {
                q.limit = l.parse()?;
            }
            let b = p.search_all(&q).await?;
            if args.has("--json") {
                println!("{}", serde_json::to_string_pretty(&b)?);
            } else {
                println!("songs={} (total {}) artists={} albums={} playlists={} podcasts={}",
                    b.songs.len(), b.song_total, b.artists.len(), b.albums.len(), b.playlists.len(), b.podcasts.len());
                for a in b.artists.iter().take(5) {
                    println!("  artist [{}] {} {}", a.id, a.name, a.alias);
                }
                for a in b.albums.iter().take(5) {
                    println!("  album  [{}] {} — {} ({} 首) {}", a.id, a.name, a.artist, a.track_count, a.cover_url.clone().unwrap_or_default());
                }
                for a in b.playlists.iter().take(5) {
                    println!("  list   [{}] {} — {} ({} 首)", a.id, a.name, a.creator_name, a.track_count);
                }
                for a in b.podcasts.iter().take(5) {
                    println!("  podcast[{}] {} — {} ({} 集)", a.id, a.name, a.dj_name, a.program_count);
                }
            }
            Ok(())
        }
        "artist" => {
            let id: u64 = args.positional.first().ok_or("usage: ncm artist <artistId>")?.parse()?;
            let p = provider(&core, Capability::Artist)?;
            announce(&core);
            let a = p.artist_detail(id).await?;
            if args.has("--json") {
                println!("{}", serde_json::to_string_pretty(&a)?);
            } else {
                println!("[{}] {} alias={:?} avatar={:?}", a.id, a.name, a.alias, a.avatar_url);
                println!("  albums={} songs={} desc={} chars", a.album_count, a.music_count, a.brief_desc.chars().count());
                for s in a.songs.iter().take(10) {
                    println!("  song [{}] {} — {}", s.id, s.name, s.artist_line());
                }
                for al in a.albums.iter().take(10) {
                    println!("  album[{}] {} ({} 首) {}", al.id, al.name, al.track_count, al.cover_url.clone().unwrap_or_default());
                }
            }
            Ok(())
        }
        "likedorder" => {
            let p = provider(&core, Capability::Playlist)?;
            announce(&core);
            let songs = p.liked_songs_ordered().await?;
            println!("count = {}", songs.len());
            for (i, s) in songs.iter().take(20).enumerate() {
                println!("{:>3}. [{}] {} — {}", i + 1, s.id, s.name, s.artist_line());
            }
            Ok(())
        }
        "profile" => {
            let p = provider(&core, Capability::ProfileDetail)?;
            announce(&core);
            let d = p.profile_detail().await?;
            println!("{}", serde_json::to_string_pretty(&d)?);
            Ok(())
        }
        "liked" => {
            let p = provider(&core, Capability::Playlist)?;
            announce(&core);
            let ids = p.liked_ids().await?;
            println!("liked_count = {}", ids.len());
            if args.has("--ids") {
                println!("{}", ids.iter().map(|t| t.0.to_string()).collect::<Vec<_>>().join(","));
            }
            if !args.has("--quiet") {
                let mut printed = 0;
                for chunk in ids.chunks(50) {
                    if printed >= 50 {
                        break;
                    }
                    let ids: Vec<String> = chunk.iter().map(|t| t.0.to_string()).collect();
                    let joined = ids.join(",");
                    for s in p.songs_detail(&joined).await? {
                        println!(
                            "  [{}] {} — {} (fee={:?} vip={})",
                            s.id,
                            s.name,
                            s.artist_line(),
                            s.fee,
                            s.is_vip()
                        );
                        printed += 1;
                    }
                }
            }
            Ok(())
        }
        "like" => {
            let id: u64 = args.positional.first().ok_or("usage: ncm like <id> [--off]")?.parse()?;
            let liked = !args.has("--off");
            let p = provider(&core, Capability::Playlist)?;
            announce(&core);
            let ok = p.set_like(TrackId::new(id), liked).await?;
            println!("set_like id={id} liked={liked} ok={ok}");
            let ids = p.liked_ids().await?;
            println!("now_in_likelist = {}", ids.iter().any(|t| t.0 == id));
            Ok(())
        }
        "playlists" => {
            let p = provider(&core, Capability::Playlist)?;
            announce(&core);
            let list = p.user_playlists().await?;
            println!("playlist_count = {}", list.len());
            for pl in &list {
                println!(
                    "  [{}] {} ({} 首){}",
                    pl.id,
                    pl.name,
                    pl.track_count,
                    if pl.special { "  <= 我喜欢的音乐" } else { "" }
                );
            }
            Ok(())
        }
        "playlist" => {
            let id: u64 = args.positional.first().ok_or("usage: ncm playlist <id>")?.parse()?;
            let p = provider(&core, Capability::Playlist)?;
            announce(&core);
            let songs = p.playlist_songs(id).await?;
            println!("song_count = {}", songs.len());
            for (i, s) in songs.iter().take(30).enumerate() {
                println!(
                    "{:>3}. [{}] {} — {} (fee={:?} vip={})",
                    i + 1,
                    s.id,
                    s.name,
                    s.artist_line(),
                    s.fee,
                    s.is_vip()
                );
            }
            Ok(())
        }
        "playlist-detail" => {
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm playlist-detail <id>")?
                .parse()?;
            let p = provider(&core, Capability::PlaylistDetail)?;
            announce(&core);
            let d = p.playlist_detail(id).await?;
            println!("[{}] {}", d.id, d.name);
            println!("creator     = {}", d.creator_name);
            println!("tracks      = {}  plays = {}", d.track_count, d.play_count);
            println!(
                "subscribed  = {} ({} 人收藏, {} 分享, {} 评论)",
                d.subscribed, d.subscribed_count, d.share_count, d.comment_count
            );
            if !d.tags.is_empty() {
                println!("tags        = {}", d.tags.join(", "));
            }
            if !d.description.is_empty() {
                println!("desc        = {}", d.description.lines().next().unwrap_or(""));
            }
            Ok(())
        }
        "comments" => {
            let kind = args
                .positional
                .first()
                .ok_or("usage: ncm comments <song|playlist|album|podcast> <id> [limit]")?
                .clone();
            let id: u64 = args
                .positional
                .get(1)
                .ok_or("usage: ncm comments <song|playlist|album|podcast> <id> [limit]")?
                .parse()?;
            let limit: u32 = args
                .positional
                .get(2)
                .map(|s| s.parse())
                .transpose()?
                .unwrap_or(20);
            let p = provider(&core, Capability::Comment)?;
            announce(&core);
            let page = p.comments(&kind, id, limit, 0).await?;
            println!(
                "total = {} has_more = {} shown = {}",
                page.total,
                page.has_more,
                page.comments.len()
            );
            for (i, c) in page.comments.iter().take(3).enumerate() {
                let first_line = c.content.lines().next().unwrap_or("");
                let short: String = if first_line.chars().count() > 40 {
                    let mut s: String = first_line.chars().take(40).collect();
                    s.push('…');
                    s
                } else {
                    first_line.to_string()
                };
                println!(
                    "{:>2}. {}({}): {} [赞 {}{}]",
                    i + 1,
                    c.user_name,
                    c.id,
                    short,
                    c.liked_count,
                    if c.liked { ", 已赞" } else { "" }
                );
            }
            Ok(())
        }
        "comment-info" => {
            let kind = args
                .positional
                .first()
                .ok_or("usage: ncm comment-info <song|playlist|album|podcast|mv|video> <id>")?
                .clone();
            let id: u64 = args
                .positional
                .get(1)
                .ok_or("usage: ncm comment-info <song|playlist|album|podcast|mv|video> <id>")?
                .parse()?;
            let thread_id = ncm_service::thread_id_for(&kind, id)
                .ok_or_else(|| format!("unknown kind {kind}"))?;
            let p = provider(&core, Capability::Comment)?;
            announce(&core);
            let s = p.comment_stats(&thread_id).await?;
            println!(
                "{} 评论 {} ({}) · 分享 {} · 点赞 {} · 作者评论 {}",
                s.thread_id,
                s.comment_count,
                if s.comment_count_desc.is_empty() { "-" } else { &s.comment_count_desc },
                s.share_count,
                s.liked_count,
                s.musician_said_count
            );
            Ok(())
        }
        "hotcomments" => {
            let kind = args
                .positional
                .first()
                .ok_or("usage: ncm hotcomments <song|playlist|album|podcast> <id> [limit]")?
                .clone();
            let id: u64 = args
                .positional
                .get(1)
                .ok_or("usage: ncm hotcomments <song|playlist|album|podcast> <id> [limit]")?
                .parse()?;
            let limit: u32 = args
                .positional
                .get(2)
                .map(|s| s.parse())
                .transpose()?
                .unwrap_or(20);
            let thread_id = ncm_service::thread_id_for(&kind, id)
                .ok_or_else(|| format!("unknown kind {kind}"))?;
            let p = provider(&core, Capability::Comment)?;
            announce(&core);
            let page = p.hot_comments(&thread_id, limit, 0).await?;
            println!(
                "hot total = {} has_more = {} shown = {}",
                page.total,
                page.has_more,
                page.comments.len()
            );
            for (i, c) in page.comments.iter().take(5).enumerate() {
                let first_line = c.content.lines().next().unwrap_or("");
                let short: String = first_line.chars().take(40).collect();
                println!(
                    "{:>2}. {}({}) @{}: {} [赞 {}]",
                    i + 1,
                    c.user_name,
                    c.id,
                    if c.ip_location.is_empty() { "-" } else { &c.ip_location },
                    short,
                    c.liked_count
                );
            }
            Ok(())
        }
        "recent-albums" | "recent-playlists" | "recent-podcasts" => {
            let bucket = args.cmd.clone();
            // 最近播放的三个分类(服务端记录, 需登录)
            let limit: u32 = args.value("--limit").and_then(|v| v.parse().ok()).unwrap_or(20);
            announce(&core);
            let p = provider(&core, Capability::Recent)?;
            match bucket.as_str() {
                "recent-albums" => {
                    let list = p.recent_albums(limit).await?;
                    println!("count = {}", list.len());
                    for (i, a) in list.iter().enumerate() {
                        println!(
                            "{:>3}. [{}] {} — {} ({} 首) {}",
                            i + 1,
                            a.id,
                            a.name,
                            a.artist,
                            a.track_count,
                            a.cover_url.clone().unwrap_or_default()
                        );
                    }
                }
                "recent-playlists" => {
                    let list = p.recent_playlists(limit).await?;
                    println!("count = {}", list.len());
                    for (i, pl) in list.iter().enumerate() {
                        println!(
                            "{:>3}. [{}] {} ({} 首) {}",
                            i + 1,
                            pl.id,
                            pl.name,
                            pl.track_count,
                            pl.cover_url.clone().unwrap_or_default()
                        );
                    }
                }
                _ => {
                    let list = p.recent_podcasts(limit).await?;
                    println!("count = {}", list.len());
                    for (i, r) in list.iter().enumerate() {
                        println!(
                            "{:>3}. [{}] {} — {} ({} 集) {}",
                            i + 1,
                            r.id,
                            r.name,
                            r.dj_name,
                            r.program_count,
                            r.cover_url.clone().unwrap_or_default()
                        );
                    }
                }
            }
            Ok(())
        }
        "vip" => {
            // 黑胶会员只读总览: 等级/成长值/本周签到/任务
            announce(&core);
            let p = provider(&core, Capability::Vip)?;
            let o = p.vip_overview().await?;
            if !o.logged_in {
                println!("未登录: 会员只读页会给登录入口");
                return Ok(());
            }
            match &o.membership {
                Some(m) => println!(
                    "黑胶: is_vip={} level={} red_level={} 到期={}",
                    m.is_vip,
                    m.level,
                    m.red_vip_level,
                    fmt_date(m.expire_time_ms)
                ),
                None => println!("黑胶: (vip_info 拉取失败)"),
            }
            if let Some(g) = &o.growth {
                println!(
                    "成长值: {} 今日 +{} 等级={} ({})",
                    g.growth_point, g.today_score, g.level, g.level_name
                );
            }
            if let Some(s) = &o.sign {
                println!(
                    "签到: 本周 {}/{} 天 今日已签={}",
                    s.week_signed,
                    s.days.len(),
                    s.signed_today
                );
                for d in &s.days {
                    println!(
                        "  {} {}{}",
                        d.date,
                        if d.signed { "已签" } else { "-" },
                        if d.today { " (今天)" } else { "" }
                    );
                }
            }
            println!("任务: {} 项 任务分={}", o.tasks.len(), o.task_score);
            for t in &o.tasks {
                println!(
                    "  [{}] {} {}",
                    if t.done { "x" } else { " " },
                    t.title,
                    if t.target > 0 {
                        format!("{}/{}", t.progress, t.target)
                    } else {
                        t.reward.clone()
                    }
                );
            }
            Ok(())
        }
        "level" => {
            // 账号听歌等级(user_level): 等级/听歌数进度/登录天数/权益
            announce(&core);
            let p = provider(&core, Capability::ProfileDetail)?;
            let l = p.user_level().await?;
            println!(
                "等级 Lv.{} 听歌 {}/{} 登录 {}/{} 进度 {:.2}%",
                l.level,
                l.now_play_count,
                l.next_play_count,
                l.now_login_count,
                l.next_login_count,
                l.progress * 100.0
            );
            for line in l.privileges.split('$').filter(|s| !s.trim().is_empty()) {
                println!("  权益: {line}");
            }
            Ok(())
        }
        "medals" => {
            // 勋章墙(user_medal): 已获得/进行中/未开始/即将获得
            announce(&core);
            let p = provider(&core, Capability::ProfileDetail)?;
            let wall = p.user_medals().await?;
            let got = wall.medals.iter().filter(|m| m.obtained).count();
            println!("勋章: 已获得 {}/{}(接口 medalNum={})", got, wall.medals.len(), wall.medal_num);
            for m in wall.medals.iter().filter(|m| !m.obtained).take(10) {
                println!(
                    "  [{}] {} {}",
                    m.status,
                    m.name,
                    m.progress_text.clone().unwrap_or_default()
                );
            }
            for m in wall.medals.iter().filter(|m| m.obtained).take(5) {
                println!(
                    "  [取得] {} {} {}",
                    m.name,
                    m.level_title.clone().unwrap_or_default(),
                    fmt_date(m.obtain_time_ms.unwrap_or(0))
                );
            }
            Ok(())
        }
        "exact" => {
            // 精确实体命中(search_multimatch): orders 为空 = 无命中(空命中是 200, 不是错误)
            let kw = args
                .positional
                .first()
                .ok_or("usage: ncm exact <keywords>")?
                .clone();
            announce(&core);
            let p = provider(&core, Capability::SearchSuggest)?;
            let o = p.search_exact(&kw).await?;
            println!(
                "orders = {:?} artists = {} playlists = {} podcasts = {}",
                o.orders,
                o.artists.len(),
                o.playlists.len(),
                o.podcasts.len()
            );
            for a in &o.artists {
                println!("  [artist] {} ({})", a.name, a.id);
            }
            for pl in &o.playlists {
                println!("  [playlist] {} ({} 首)", pl.name, pl.track_count);
            }
            for r in &o.podcasts {
                println!("  [voice] {} ({} 期)", r.name, r.program_count);
            }
            Ok(())
        }
        "suggestkw" => {
            // pure keyword suggestions (mobile search_suggest)
            let kw = args
                .positional
                .first()
                .ok_or("usage: ncm suggestkw <keywords>")?
                .clone();
            announce(&core);
            let p = provider(&core, Capability::SearchSuggest)?;
            let list = p.search_suggest_keywords(&kw).await?;
            println!("keywords = {}", list.len());
            for k in list {
                println!("  {k}");
            }
            Ok(())
        }
        "hotdetail" => {
            // hot search detail (rank by array index; server gives no rank field)
            announce(&core);
            let p = provider(&core, Capability::SearchHot)?;
            let list = p.hot_search_detail().await?;
            println!("hot = {}", list.len());
            for it in list.iter().take(10) {
                println!("  #{:02} {} score={}", it.rank, it.keyword, it.score);
            }
            Ok(())
        }
        "signin" => {
            // ncm signin          -> 只看状态
            // ncm signin --do     -> 真签到
            announce(&core);
            let p = provider(&core, Capability::Signin)?;
            let s = if args.has("--do") {
                p.sign_in().await?
            } else {
                p.signin_status().await?
            };
            println!(
                "signed_today = {} point = {}",
                s.signed_today, s.today_point
            );
            println!(
                "total = {} 连续 = {} 本周 = {}",
                s.total_days, s.continuous_days, s.week_days
            );
            for d in &s.recent {
                println!("  {} {}", d.day, if d.signed { "已签" } else { "-" });
            }
            Ok(())
        }
        "wiki" => {
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm wiki <songId>")?
                .parse()?;
            announce(&core);
            let p = provider(&core, Capability::Wiki)?;
            let facts = p.song_wiki(id).await?;
            println!("facts = {}", facts.len());
            for f in facts {
                println!("  {}: {}", f.label, f.value);
            }
            Ok(())
        }
        "comment-delete" => {
            let thread = args
                .positional
                .first()
                .ok_or("usage: ncm comment-delete <threadId> <commentId>")?
                .clone();
            let cid: u64 = args
                .positional
                .get(1)
                .ok_or("usage: ncm comment-delete <threadId> <commentId>")?
                .parse()?;
            announce(&core);
            let p = provider(&core, Capability::Comment)?;
            println!("deleted = {}", p.delete_comment(&thread, cid).await?);
            Ok(())
        }
        "newsongs" | "newalbums" | "topartists" => {
            // ncm newsongs [all|zh|ea|jp|kr] [--limit 20]
            // ncm newalbums [all|zh|ea|jp|kr] [--limit 20]
            // ncm topartists [--limit 20]
            let area = args.positional.first().cloned().unwrap_or_else(|| "all".into());
            let limit: u32 = args
                .value("--limit")
                .and_then(|v| v.parse().ok())
                .unwrap_or(20);
            announce(&core);
            let p = provider(&core, Capability::NewRelease)?;
            match args.cmd.as_str() {
                "newsongs" => {
                    let list = p.new_songs_by_area(&area, limit).await?;
                    println!("count = {}", list.len());
                    for (i, s) in list.iter().enumerate() {
                        println!(
                            "{:>3}. [{}] {} — {} ({:.0}s) vip={}",
                            i + 1,
                            s.id,
                            s.name,
                            s.artist_line(),
                            s.duration_ms as f64 / 1000.0,
                            s.is_vip()
                        );
                    }
                }
                "newalbums" => {
                    let list = p.new_albums_by_area(&area, limit).await?;
                    println!("count = {}", list.len());
                    for (i, a) in list.iter().enumerate() {
                        println!(
                            "{:>3}. [{}] {} — {} ({} 首)",
                            i + 1,
                            a.id,
                            a.name,
                            a.artist,
                            a.track_count
                        );
                    }
                }
                _ => {
                    let list = p.hot_artists(limit, 0).await?;
                    println!("count = {}", list.len());
                    for (i, a) in list.iter().enumerate() {
                        println!(
                            "{:>3}. [{}] {} 粉丝 {}",
                            i + 1,
                            a.id,
                            a.name,
                            a.fans
                        );
                    }
                }
            }
            Ok(())
        }

        "messages" => {
            // 未读数 / 私信会话 / 通知 / 评论消息
            //   ncm messages            未读数
            //   ncm messages dm         私信会话列表
            //   ncm messages dm <uid>   与某人的私信历史
            //   ncm messages notice     通知
            //   ncm messages comment    评论/回复
            announce(&core);
            let p = provider(&core, Capability::Message)?;
            match args.positional.first().map(String::as_str) {
                None => {
                    let c = p.message_counts().await?;
                    println!(
                        "private={} notice={} comment={} forward={} total={}",
                        c.private,
                        c.notices,
                        c.comments,
                        c.forwards,
                        c.total()
                    );
                }
                Some("dm") => match args.positional.get(1) {
                    Some(uid) => {
                        let uid: u64 = uid.parse()?;
                        let limit: u32 = args
                            .value("--limit")
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(30);
                        let list = p.private_history(uid, limit, 0).await?;
                        println!("count = {}", list.len());
                        for m in list.iter() {
                            println!(
                                "[{}] {}: {}",
                                if m.from_me { "我" } else { m.nickname.as_str() },
                                m.time_ms,
                                m.content
                            );
                        }
                    }
                    None => {
                        let limit: u32 = args
                            .value("--limit")
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(20);
                        let list = p.private_sessions(limit, 0).await?;
                        println!("count = {}", list.len());
                        for s in list.iter() {
                            println!(
                                "[{}] {} (未读 {}) {} <- {}",
                                s.user_id,
                                s.nickname,
                                s.unread,
                                s.last_time_ms,
                                short_line(&s.last_message, 60)
                            );
                        }
                    }
                },
                Some("notice") => {
                    let limit: u32 = args
                        .value("--limit")
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(20);
                    let list = p.message_notices(limit, 0).await?;
                    println!("count = {}", list.len());
                    for i in list.iter() {
                        println!(
                            "[{}] {} {} {}",
                            i.time_ms,
                            i.actor,
                            i.text,
                            short_line(&i.detail, 40)
                        );
                    }
                }
                Some("comment") => {
                    let limit: u32 = args
                        .value("--limit")
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(20);
                    let list = p.comment_messages(limit).await?;
                    println!("count = {}", list.len());
                    for i in list.iter() {
                        println!(
                            "[{}] {}: {} ({})",
                            i.time_ms,
                            i.actor,
                            short_line(&i.text, 50),
                            short_line(&i.detail, 30)
                        );
                    }
                }
                Some(other) => return Err(format!("unknown messages kind: {other}").into()),
            }
            Ok(())
        }

        "podcast-radio" => {
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm podcast-radio <id>")?
                .parse()?;
            let p = provider(&core, Capability::PodcastDetail)?;
            announce(&core);
            let r = p.podcast_radio(id).await?;
            println!("[{}] {}", r.id, r.name);
            println!("dj          = {}", r.dj_name);
            println!("programs    = {}  plays = {}", r.program_count, r.play_count);
            if !r.description.is_empty() {
                println!("desc        = {}", r.description.lines().next().unwrap_or(""));
            }
            Ok(())
        }
        "radio-cats" => {
            let p = provider(&core, Capability::RadioExplore)?;
            announce(&core);
            let home = p.radio_explore_home().await?;
            println!("categories = {}", home.categories.len());
            for c in home.categories.iter().take(40) {
                println!("  [{}] {}", c.id, c.name);
            }
            println!("picks = {} 组", home.picks.len());
            for g in &home.picks {
                println!("  -- {} [{}]", g.category_name, g.category_id);
                for r in g.radios.iter().take(3) {
                    println!("     [{}] {} — {} ({} 集, {} 播放)", r.id, r.name, r.dj_name, r.program_count, r.play_count);
                }
            }
            Ok(())
        }
        "radio-rec" => {
            let cate: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm radio-rec <cateId>")?
                .parse()?;
            let p = provider(&core, Capability::RadioExplore)?;
            announce(&core);
            let list = p.radio_recommend(cate).await?;
            println!("count = {}", list.len());
            for (i, r) in list.iter().take(30).enumerate() {
                println!(
                    "{:>3}. [{}] {} — {} ({} 集) {}",
                    i + 1, r.id, r.name, r.dj_name, r.program_count,
                    r.cover_url.clone().unwrap_or_default()
                );
            }
            Ok(())
        }
        "radio-top" => {
            let kind = args
                .positional
                .first()
                .ok_or("usage: ncm radio-top <hot|new|pay|hours|newcomer|popular|program>")?
                .clone();
            let p = provider(&core, Capability::RadioExplore)?;
            announce(&core);
            let t = p.radio_toplist(&kind).await?;
            if !t.radios.is_empty() {
                println!("电台榜 {} ({} 条)", kind, t.radios.len());
                for r in t.radios.iter().take(20) {
                    println!(
                        "{:>3}. [{}] {} — {} 得分={} 播放={} (上期 {})",
                        r.rank, r.radio_id, r.name, r.dj_name, r.score, r.play_count, r.last_rank
                    );
                }
            }
            if !t.djs.is_empty() {
                println!("主播榜 {} ({} 条)", kind, t.djs.len());
                for d in t.djs.iter().take(20) {
                    println!(
                        "{:>3}. [{}] {} 得分={} 粉丝={} (上期 {})",
                        d.rank, d.user_id, d.nickname, d.score, d.followed_count, d.last_rank
                    );
                }
            }
            if !t.programs.is_empty() {
                println!("节目榜 {} ({} 条)", kind, t.programs.len());
                for e in t.programs.iter().take(20) {
                    println!(
                        "{:>3}. [{}] {} — {} ({}ms)",
                        e.rank, e.program.id, e.program.name, e.program.dj_name, e.program.duration_ms
                    );
                }
            }
            if t.radios.is_empty() && t.djs.is_empty() && t.programs.is_empty() {
                println!("榜单 {} 为空", kind);
            }
            Ok(())
        }
        "radio-sub" => {
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm radio-sub <radioId> [limit]")?
                .parse()?;
            let limit: u32 = args.positional.get(1).and_then(|s| s.parse().ok()).unwrap_or(10);
            let p = provider(&core, Capability::RadioExplore)?;
            announce(&core);
            let page = p.radio_subscribers(id, limit).await?;
            println!("has_more = {}  count = {}", page.has_more, page.subscribers.len());
            for s in &page.subscribers {
                println!("  [{}] {} {}", s.user_id, s.nickname, s.signature);
            }
            Ok(())
        }
        "url" => {
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm url <id>")?
                .parse()?;
            let level = args
                .value("--level")
                .as_deref()
                .and_then(AudioLevel::parse)
                .unwrap_or_default();
            let p = provider(&core, Capability::SongUrl)?;
            announce(&core);
            let stream = p
                .song_url(&SongUrlRequest { track: TrackId::new(id), level })
                .await?;
            if args.has("--json") {
                println!("{}", serde_json::to_string_pretty(&stream)?);
            } else {
                println!("playable={} quality={} br={:?}", stream.is_playable(), stream.quality, stream.br);
                println!("url={:?}", stream.url);
            }
            if let Some(path) = args.value("--download") {
                let url = stream.url.ok_or("no url to download")?;
                download(&url, &path).await?;
                println!("saved -> {path}");
            }
            Ok(())
        }

        "play" => {
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm play <id> [--level exhigh] [--seconds 8]")?
                .parse()?;
            let level = args
                .value("--level")
                .as_deref()
                .and_then(AudioLevel::parse)
                .unwrap_or_default();
            let seconds: u64 = args.value("--seconds").as_deref().unwrap_or("8").parse()?;
            let p = provider(&core, Capability::SongUrl)?;
            announce(&core);
            let stream = p
                .song_url(&SongUrlRequest { track: TrackId::new(id), level })
                .await?;
            let url = stream.url.ok_or("no url (VIP 曲目需要登录 cookie)")?;
            let cache = ncm_service::cache::AudioCache::open(&data_dir().join("audio"))?;
            let path = cache.fetch(id, &url).await?;
            eprintln!("cached -> {}", path.display());
            let player = ncm_playback::Player::new();
            player.play_file(id, path.to_string_lossy().to_string());
            std::thread::sleep(std::time::Duration::from_millis(600));
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
            while std::time::Instant::now() < deadline {
                let s = player.state();
                println!(
                    "playing={} pos={}ms dur={}ms volume={}",
                    s.playing, s.position_ms, s.duration_ms, s.volume
                );
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
            player.stop();
            Ok(())
        }
        "lyric" => {
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm lyric <id>")?
                .parse()?;
            let p = provider(&core, Capability::Lyric)?;
            let lyric = p.lyric(TrackId::new(id)).await?;
            if args.has("--json") {
                println!("{}", serde_json::to_string_pretty(&lyric)?);
            } else {
                println!("{}", lyric.lrc.unwrap_or_else(|| "(no lyric)".into()));
            }
            Ok(())
        }
        "yrc" => {
            // 逐字歌词: 前 10 行(行时间 + 每词时间/文本) + 统计
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm yrc <songId>")?
                .parse()?;
            announce(&core);
            let p = provider(&core, Capability::Lyric)?;
            let wl = p.word_lyric(TrackId::new(id)).await?;
            if wl.is_empty() {
                println!("(no yrc: 该曲无逐字歌词, 请用 ncm lyric)");
                return Ok(());
            }
            let word_count: usize = wl.lines.iter().map(|l| l.words.len()).sum();
            for line in wl.lines.iter().take(10) {
                println!(
                    "[{:>6} -> {:>6}] {}",
                    line.start_ms,
                    line.end_ms,
                    line
                        .words
                        .iter()
                        .map(|w| format!("({},{}){}", w.start_ms, w.end_ms, w.text))
                        .collect::<Vec<_>>()
                        .join(" "),
                );
            }
            println!(
                "-- 统计: 行数 {} / 词数 {} / 逐字 {} / 翻译行 {}",
                wl.lines.len(),
                word_count,
                if wl.has_word_timing { "有" } else { "无(已退化)" },
                wl.translation_lines.iter().filter(|t| t.is_some()).count(),
            );
            Ok(())
        }
        "searchraw" => {
            // 排障用: 搜索接口的原始返回(看 songs[].privilege 与 st, 判断无版权曲目被过滤/灰显)
            let kw = args.positional.first().ok_or("usage: ncm searchraw <keywords> [--limit 10]")?;
            let limit = args.value("--limit").unwrap_or_else(|| "10".into());
            announce(&core);
            let cookie = core.session.cookie.clone();
            let mut client = ncm_api_rs::ApiClient::new(if cookie.is_empty() {
                None
            } else {
                Some(cookie.clone())
            });
            if !core.session.device_id.is_empty() {
                client.set_device_id(core.session.device_id.clone());
            }
            let mut q = ncm_api_rs::Query::new()
                .cookie(&cookie)
                .param("keywords", kw)
                .param("limit", &limit)
                .param("offset", "0")
                .param("type", "1");
            q.ua = Some(ncm_service::identity::platform_profile().ua.to_string());
            let resp = client.cloudsearch(&q).await?;
            let body = resp.body;
            if args.has("--json") {
                println!("{}", serde_json::to_string_pretty(&body)?);
            } else {
                let songs = body
                    .get("result")
                    .and_then(|r| r.get("songs"))
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                for s in songs {
                    let id = s.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
                    let name = s.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    let fee = s.get("fee").and_then(|v| v.as_i64()).unwrap_or(-1);
                    let artist = s
                        .get("ar")
                        .and_then(|v| v.as_array())
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                                .collect::<Vec<_>>()
                                .join("/")
                        })
                        .unwrap_or_default();
                    let priv_st = s
                        .get("privilege")
                        .and_then(|p| p.get("st"))
                        .map(|v| v.to_string())
                        .unwrap_or_else(|| "-".into());
                    let priv_pl = s
                        .get("privilege")
                        .and_then(|p| p.get("pl"))
                        .map(|v| v.to_string())
                        .unwrap_or_else(|| "-".into());
                    println!(
                        "[{id}] {name} — {artist} fee={fee} privilege.st={priv_st} pl={priv_pl}"
                    );
                }
            }
            Ok(())
        }
        "detail" => {
            // 排障用: 直接看 vendor 的原始 privileges(st/pl/dl/fee/cp), 判断曲目是否无版权
            let ids = args
                .positional
                .first()
                .ok_or("usage: ncm detail <id[,id...]>")?;
            announce(&core);
            let cookie = core.session.cookie.clone();
            let mut client = ncm_api_rs::ApiClient::new(if cookie.is_empty() {
                None
            } else {
                Some(cookie.clone())
            });
            if !core.session.device_id.is_empty() {
                client.set_device_id(core.session.device_id.clone());
            }
            let mut q = ncm_api_rs::Query::new().cookie(&cookie).param("ids", ids);
            q.ua = Some(ncm_service::identity::platform_profile().ua.to_string());
            let resp = client.song_detail(&q).await?;
            let body = resp.body;
            if args.has("--json") {
                println!("{}", serde_json::to_string_pretty(&body)?);
            } else {
                let privileges = body
                    .get("privileges")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                for s in body.get("songs").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
                    let id = s.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
                    let name = s.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    let fee = s.get("fee").and_then(|v| v.as_i64()).unwrap_or(-1);
                    let st = s.get("st").and_then(|v| v.as_i64());
                    let p = privileges
                        .iter()
                        .find(|p| p.get("id").and_then(|v| v.as_i64()) == Some(id));
                    println!("[{id}] {name} fee={fee} st={st:?}");
                    if let Some(p) = p {
                        println!(
                            "     privilege: st={:?} pl={:?} dl={:?} fl={:?} fee={:?} cp={:?} maxbr={:?}",
                            p.get("st"),
                            p.get("pl"),
                            p.get("dl"),
                            p.get("fl"),
                            p.get("fee"),
                            p.get("cp"),
                            p.get("maxBr")
                        );
                    }
                }
            }
            Ok(())
        }
        "heart" => {
            // 心动模式: 默认歌单 = 我喜欢的音乐(pid=0 时由 provider 自动回落)
            let id: u64 = args
                .positional
                .first()
                .ok_or("usage: ncm heart <songId> [--pid <playlistId>] [--count 30]")?
                .parse()?;
            let pid: u64 = args.value("--pid").map(|s| s.parse()).transpose()?.unwrap_or(0);
            let count: u32 = args
                .value("--count")
                .map(|s| s.parse())
                .transpose()?
                .unwrap_or(30);
            let p = provider(&core, Capability::DailyRecommend)?;
            announce(&core);
            let songs = p.intelligence_songs(id, pid, count).await?;
            println!("count = {}", songs.len());
            for (i, s) in songs.iter().take(30).enumerate() {
                println!(
                    "{:>3}. [{}] {} — {} (fee={:?} playable={})",
                    i + 1,
                    s.id,
                    s.name,
                    s.artist_line(),
                    s.fee,
                    s.playable
                );
            }
            Ok(())
        }
        "digital" => {
            // 数字专辑详情: ncm digital <albumId>
            let id: u64 = args.positional.first().ok_or("usage: ncm digital <albumId>")?.parse()?;
            announce(&core);
            let p = provider(&core, Capability::DigitalAlbum)?;
            let d = p.digital_album_detail(id).await?;
            println!(
                "{} — {}\n价格: {} 元 上架: {} 销量(product.saleNum): {}\n标签: {} 已购: {}",
                d.name,
                d.artist_name,
                d.price,
                fmt_date(d.pub_time_ms),
                d.sale_num,
                if d.tags.is_empty() { "-".to_string() } else { d.tags.join(" / ") },
                d.has_album
            );
            if !d.description.is_empty() {
                println!("简介: {}", short_line(&d.description, 120));
            }
            Ok(())
        }
        "digital-purchased" => {
            // 我的已购数字专辑: ncm digital-purchased [limit] [offset]
            let limit: u32 = args.positional.first().and_then(|s| s.parse().ok()).unwrap_or(30);
            let offset: u32 = args.positional.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
            announce(&core);
            let p = provider(&core, Capability::DigitalAlbum)?;
            let r = p.digital_album_purchased(limit, offset).await?;
            println!("已购数字专辑: {} 张(服务端 total={})", r.albums.len(), r.total);
            for a in &r.albums {
                println!(
                    "  {} — {} · {}x · 购于 {}",
                    a.album_name,
                    a.artist_name,
                    a.bought_count,
                    fmt_date(a.paid_time_ms)
                );
            }
            Ok(())
        }
        "purchased-songs" => {
            // 我的已购单曲: ncm purchased-songs [limit] [offset]
            let limit: u32 = args.positional.first().and_then(|s| s.parse().ok()).unwrap_or(20);
            let offset: u32 = args.positional.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
            announce(&core);
            let p = provider(&core, Capability::DigitalAlbum)?;
            let r = p.song_purchased(limit, offset).await?;
            println!("已购单曲: {} 首 hasMore={}", r.songs.len(), r.has_more);
            for s in &r.songs {
                println!("  {} — {} ({})", s.name, s.artist_name, fmt_date(s.paid_time_ms));
            }
            Ok(())
        }
        "digital-sales" => {
            // 数字专辑销量: ncm digital-sales <id[,id...]>
            let ids = args.positional.first().ok_or("usage: ncm digital-sales <id[,id...]>")?;
            announce(&core);
            let p = provider(&core, Capability::DigitalAlbum)?;
            for e in p.digital_album_sales(ids).await? {
                println!("专辑 {}: 销量 {}", e.album_id, e.sales);
            }
            Ok(())
        }
        "raw" => {
            // 排障/建模用: 直接打任意 vendor 端点并打印原始 JSON.
            // 用法: ncm raw <method> [key=value ...]
            // methods: recommend_songs | recommend_resource | playmode | search_suggest |
            //          recent | dj_detail | dj_program | dj_program_detail | album | fm |
            //          search_hot | search_default | dj_sublist | artist_sublist | event
            let method = args
                .positional
                .first()
                .ok_or("usage: ncm raw <method> [key=value ...]")?
                .clone();
            announce(&core);
            let cookie = core.session.cookie.clone();
            let mut client = ncm_api_rs::ApiClient::new(if cookie.is_empty() {
                None
            } else {
                Some(cookie.clone())
            });
            if !core.session.device_id.is_empty() {
                client.set_device_id(core.session.device_id.clone());
            }
            let mut q = ncm_api_rs::Query::new().cookie(&cookie);
            q.ua = Some(ncm_service::identity::platform_profile().ua.to_string());
            for p in args.positional.iter().skip(1) {
                if let Some((k, v)) = p.split_once('=') {
                    q = q.param(k, v);
                }
            }
            let resp = match method.as_str() {
                "cloudsearch" => client.cloudsearch(&q).await?,
                "artist_detail" => client.artist_detail(&q).await?,
                "artist_songs" => client.artist_songs(&q).await?,
                "artist_album" => client.artist_album(&q).await?,
                "artist_top_song" => client.artist_top_song(&q).await?,
                "recommend_songs" => client.recommend_songs(&q).await?,
                "recommend_resource" => client.recommend_resource(&q).await?,
                "playmode" => client.playmode_intelligence_list(&q).await?,
                "search_suggest" => client.search_suggest(&q).await?,
                "recent" => client.record_recent_song(&q).await?,
                "dj_detail" => client.dj_detail(&q).await?,
                "dj_program" => client.dj_program(&q).await?,
                "dj_program_detail" => client.dj_program_detail(&q).await?,
                "album" => client.album(&q).await?,
                "fm" => client.personal_fm(&q).await?,
                "search_hot" => client.search_hot(&q).await?,
                "search_default" => client.search_default(&q).await?,
                "dj_sublist" => client.dj_sublist(&q).await?,
                "artist_sublist" => client.artist_sublist(&q).await?,
                "event" => client.event(&q).await?,
                "dj_hot" => client.dj_hot(&q).await?,
                "dj_rcmd" => client.personalized_djprogram(&q).await?,
                "style_preference" => client.style_preference(&q).await?,
                "style_song" => client.style_song(&q).await?,
                "style_playlist" => client.style_playlist(&q).await?,
                "style_list" => client.style_list(&q).await?,
                "user_record" => client.user_record(&q).await?,
                "history_recommend_songs" => client.history_recommend_songs(&q).await?,
                "history_recommend_songs_detail" => client.history_recommend_songs_detail(&q).await?,
                "personalized_newsong" => client.personalized_newsong(&q).await?,
                "album_new" => client.album_new(&q).await?,
                "top_album" => client.top_album(&q).await?,
                "simi_song" => client.simi_song(&q).await?,
                "simi_playlist" => client.simi_playlist(&q).await?,
                "simi_artist" => client.simi_artist(&q).await?,
                "simi_user" => client.simi_user(&q).await?,
                "toplist" => client.toplist(&q).await?,
                "toplist_detail" => client.toplist_detail(&q).await?,
                "toplist_detail_v2" => client.toplist_detail_v2(&q).await?,
                "playlist_catlist" => client.playlist_catlist(&q).await?,
                "playlist_category_list" => client.playlist_category_list(&q).await?,
                "top_playlist" => client.top_playlist(&q).await?,
                "top_playlist_highquality" => client.top_playlist_highquality(&q).await?,
                "playlist_hot" => client.playlist_hot(&q).await?,
                "album_sublist" => client.album_sublist(&q).await?,
                "record_recent_album" => client.record_recent_album(&q).await?,
                "record_recent_playlist" => client.record_recent_playlist(&q).await?,
                "record_recent_dj" => client.record_recent_dj(&q).await?,
                "daily_signin" => client.daily_signin(&q).await?,
                "signin_progress" => client.signin_progress(&q).await?,
                "comment_delete" => client.comment_delete(&q).await?,
                "song_wiki_summary" => client.song_wiki_summary(&q).await?,
                "user_level" => client.user_level(&q).await?,
                "user_medal" => client.user_medal(&q).await?,
                "top_song" => client.top_song(&q).await?,
                "top_artists" => client.top_artists(&q).await?,
                "album_newest" => client.album_newest(&q).await?,
                "search_multimatch" => client.search_multimatch(&q).await?,
                "pl_count" => client.pl_count(&q).await?,
                "comment_hot" => client.comment_hot(&q).await?,
                "comment_info_list" => client.comment_info_list(&q).await?,
                "lyric_new" => client.lyric_new(&q).await?,
                "song_lyrics_mark" => client.song_lyrics_mark(&q).await?,
                "vip_sign_info" => client.vip_sign_info(&q).await?,
                "vip_info_v2" => client.vip_info_v2(&q).await?,
                "digital_album_detail" => client.digital_album_detail(&q).await?,
                "digital_album_purchased" => client.digital_album_purchased(&q).await?,
                "digital_album_sales" => client.digital_album_sales(&q).await?,
                "song_purchased" => client.song_purchased(&q).await?,
                "vip_info" => client.vip_info(&q).await?,
                "vip_tasks" => client.vip_tasks(&q).await?,
                "sign_happy_info" => client.sign_happy_info(&q).await?,
                "vip_growthpoint" => client.vip_growthpoint(&q).await?,
                "msg_private" => client.msg_private(&q).await?,
                "msg_private_history" => client.msg_private_history(&q).await?,
                "msg_notices" => client.msg_notices(&q).await?,
                "msg_comments" => client.msg_comments(&q).await?,
                "msg_forwards" => client.msg_forwards(&q).await?,
                "msg_recentcontact" => client.msg_recentcontact(&q).await?,
                "search_hot_detail" => client.search_hot_detail(&q).await?,
                "dj_catelist" => client.dj_catelist(&q).await?,
                "dj_category_recommend" => client.dj_category_recommend(&q).await?,
                "dj_recommend_type" => client.dj_recommend_type(&q).await?,
                "dj_toplist" => client.dj_toplist(&q).await?,
                "dj_toplist_hours" => client.dj_toplist_hours(&q).await?,
                "dj_toplist_newcomer" => client.dj_toplist_newcomer(&q).await?,
                "dj_toplist_pay" => client.dj_toplist_pay(&q).await?,
                "dj_toplist_popular" => client.dj_toplist_popular(&q).await?,
                "dj_program_toplist" => client.dj_program_toplist(&q).await?,
                "dj_subscriber" => client.dj_subscriber(&q).await?,
                other => return Err(format!("unknown raw method: {other}").into()),
            };
            println!("{}", serde_json::to_string_pretty(&resp.body)?);
            Ok(())
        }
        other => Err(format!(
            "unknown command: {other}\ncommands: whoami | login-cookie | search | url | play | lyric | liked | like | playlists | playlist | playlist-detail | comments | podcast-radio | detail | vip | exact | suggestkw | hotdetail | raw"
        )
        .into()),
    }
}

/// 毫秒时间戳 -> yyyy-MM-dd(本地时区, 简易 civil_from_days; 0 显示 "-")
fn fmt_date(ms: u64) -> String {
    if ms == 0 {
        return "-".to_string();
    }
    let days = (ms / 1000) as i64 / 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

fn whoami(core: &Core) -> Result<(), BoxErr> {
    println!("data_dir   = {}", core.store.path().display());
    println!("device_id  = {}", core.session.device_id);
    println!("logged_in  = {}", core.session.is_logged_in());
    match core.session.profile.as_ref() {
        Some(p) => println!("account    = #{} {} vip={}", p.user_id, p.nickname, p.vip),
        None => println!("account    = (尚未同步资料)"),
    }
    println!("cookie_keys= {}",
        core.session
            .cookie
            .split(';')
            .filter_map(|p| p.split_once('=').map(|(k, _)| k.trim()))
            .collect::<Vec<_>>()
            .join(",")
    );
    for p in core.providers.all() {
        println!("provider   = {} ({}) caps={:?}", p.id(), p.name(), p.capabilities());
    }
    Ok(())
}

fn provider(core: &Core, cap: Capability) -> Result<std::sync::Arc<dyn Provider>, BoxErr> {
    core.providers
        .first_with(cap)
        .ok_or_else(|| format!("no provider supports {}", cap.as_str()).into())
}

/// 单行摘要(去掉换行, 超长截断): CLI 打印长文本用
fn short_line(s: &str, max_chars: usize) -> String {
    let one_line: String = s.chars().map(|c| if c == '\n' { ' ' } else { c }).collect();
    let trimmed = one_line.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(max_chars).collect();
    format!("{head}…")
}

fn announce(core: &Core) {
    let state = if core.session.is_logged_in() { "logged-in" } else { "anonymous" };
    eprintln!("[{state}] device={}", &core.session.device_id[..8]);
}

async fn download(url: &str, path: &str) -> Result<(), BoxErr> {
    use std::io::Write;
    let resp = reqwest::Client::builder().build()?.get(url).send().await?;
    let status = resp.status();
    if !status.is_success() {
        return Err(format!("download failed: http {status}").into());
    }
    let bytes = resp.bytes().await?;
    let mut f = std::fs::File::create(path)?;
    f.write_all(&bytes)?;
    eprintln!("downloaded {} bytes", bytes.len());
    Ok(())
}
