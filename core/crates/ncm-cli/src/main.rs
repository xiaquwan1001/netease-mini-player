//! ncm — headless 命令行: 没有 UI 也能验证协议/身份/取链全链路.
//!
//! 用法:
//!   ncm whoami
//!   ncm search "晴天" [--limit 10] [--offset 0] [--json]
//!   ncm url <id> [--level exhigh] [--download out.flac] [--json]
//!   ncm lyric <id> [--json]
//!   ncm detail <id[,id...]>        打印曲目详情 + privilege(版权/可播性), 排障用
//!   ncm playlist-detail <id>       歌单详情(标题/创建者/曲目数/评论数)
//!   ncm comments <song|playlist|album|podcast> <id> [limit]   评论列表(展示前 3 条)
//!   ncm podcast-radio <id>         播客/电台详情(标题/主播/节目数)
//!   ncm login-cookie "MUSIC_U=...; __csrf=..."
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
                other => return Err(format!("unknown raw method: {other}").into()),
            };
            println!("{}", serde_json::to_string_pretty(&resp.body)?);
            Ok(())
        }
        other => Err(format!(
            "unknown command: {other}\ncommands: whoami | login-cookie | search | url | play | lyric | liked | like | playlists | playlist | playlist-detail | comments | podcast-radio | detail | raw"
        )
        .into()),
    }
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
