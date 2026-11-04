//! ncm — headless 命令行: 没有 UI 也能验证协议/身份/取链全链路.
//!
//! 用法:
//!   ncm whoami
//!   ncm search "晴天" [--limit 10] [--offset 0] [--json]
//!   ncm url <id> [--level exhigh] [--download out.flac] [--json]
//!   ncm lyric <id> [--json]
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
        other => Err(format!(
            "unknown command: {other}\ncommands: whoami | login-cookie | search | url | lyric"
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
