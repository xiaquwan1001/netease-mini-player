//! 暴露给 Dart 的 API. 规则:
//! - 只传可序列化 DTO, 不传引用/闭包
//! - 错误统一成 String(带 kind 前缀), UI 按前缀决定文案
//! - 全局单例 Core, 由 init() 建立

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use ncm_provider::{Capability, SearchQuery};
use ncm_service::Core;

static CORE: OnceLock<Mutex<Core>> = OnceLock::new();

fn core() -> Result<&'static Mutex<Core>, String> {
    CORE.get().ok_or_else(|| "core not initialized".to_string())
}

fn data_dir_default() -> String {
    std::env::var("NCM_DATA_DIR").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        format!("{home}/.local/share/ncm")
    })
}

/// 初始化: 建立/加载身份, 注册 provider. 幂等.
pub fn init(data_dir: Option<String>) -> Result<InitInfo, String> {
    let dir = data_dir.unwrap_or_else(data_dir_default);
    let _ = DATA_DIR.set(std::path::PathBuf::from(&dir));
    if CORE.get().is_none() {
        let core = Core::open(Path::new(&dir)).map_err(|e| e.to_string())?;
        let _ = CORE.set(Mutex::new(core));
    }
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    Ok(InitInfo {
        data_dir: dir,
        device_id: guard.session.device_id.clone(),
        logged_in: guard.session.is_logged_in(),
        vip: guard.session.profile.as_ref().map(|p| p.vip).unwrap_or(false),
        providers: guard
            .providers
            .all()
            .iter()
            .map(|p| ProviderInfo {
                id: p.id().to_string(),
                name: p.name().to_string(),
                capabilities: p.capabilities().iter().map(|c| c.as_str().to_string()).collect(),
            })
            .collect(),
    })
}

pub struct InitInfo {
    pub data_dir: String,
    pub device_id: String,
    pub logged_in: bool,
    /// 当前账号是否会员(黑胶/音乐包)
    pub vip: bool,
    pub providers: Vec<ProviderInfo>,
}

pub struct ProviderInfo {
    pub id: String,
    pub name: String,
    pub capabilities: Vec<String>,
}

pub struct SongDto {
    pub id: u64,
    pub name: String,
    pub artist: String,
    /// 第一歌手的 id(0 = 未知). 用于"歌手信息"
    pub artist_id: u64,
    pub album: String,
    /// 专辑 id(0 = 未知). 用于点封面看专辑详情
    pub album_id: u64,
    /// 专辑封面直链
    pub cover_url: Option<String>,
    pub duration_ms: u64,
    pub fee: i64,
    /// VIP 专属(高音质需会员)
    pub vip: bool,
    /// 需单独购买的数字专辑
    pub paid: bool,
    /// 有版权、可播(false = 官方灰显那种"暂无版权")
    pub playable: bool,
}

fn song_dto(s: ncm_domain::Song) -> SongDto {
    let artist = s.artist_line();
    let vip = s.is_vip();
    let paid = s.is_paid();
    let playable = s.playable;
    let album_id = s.album_id();
    let cover_url = s.cover_url();
    let artist_id = s.artists.first().map(|a| a.id).unwrap_or(0);
    SongDto {
        id: s.id.0,
        name: s.name,
        artist,
        artist_id,
        album: s.album.map(|a| a.name).unwrap_or_default(),
        album_id,
        cover_url,
        duration_ms: s.duration_ms,
        fee: s.fee.unwrap_or(0),
        vip,
        paid,
        playable,
    }
}

/// SongDto -> domain Song(本地播放历史用: 只保留展示必需字段).
fn song_from_dto(d: &SongDto) -> ncm_domain::Song {
    ncm_domain::Song {
        id: ncm_domain::TrackId::new(d.id),
        name: d.name.clone(),
        artists: if d.artist.is_empty() {
            vec![]
        } else {
            vec![ncm_domain::Artist {
                id: d.artist_id,
                name: d.artist.clone(),
                avatar_url: None,
            }]
        },
        album: Some(ncm_domain::Album {
            id: d.album_id,
            name: d.album.clone(),
            pic_url: d.cover_url.clone(),
        }),
        duration_ms: d.duration_ms,
        fee: Some(d.fee),
        playable: d.playable,
    }
}

pub struct SearchResultDto {
    pub total: u64,
    pub has_more: bool,
    pub songs: Vec<SongDto>,
}

pub struct StreamDto {
    pub url: Option<String>,
    pub quality: String,
    pub br: Option<u64>,
    pub expire_at: Option<u64>,
}

pub async fn search(keywords: String, limit: u32) -> Result<SearchResultDto, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::Search)
            .ok_or_else(|| "no provider supports search".to_string())?
    };
    let query = SearchQuery { keywords, limit, offset: 0 };
    let page = provider.search(&query).await.map_err(|e| e.to_string())?;
    Ok(SearchResultDto {
        total: page.total,
        has_more: page.has_more,
        songs: page.songs.into_iter().map(song_dto).collect(),
    })
}

// ---------------- 综合搜索(分板块) ----------------

pub struct SearchArtistDto {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    /// 别名, 已用 " / " 拼好
    pub alias: String,
    pub album_count: u64,
    pub music_count: u64,
}

pub struct SearchAlbumDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub track_count: u64,
}

pub struct SearchPlaylistDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub creator_name: String,
    pub track_count: u64,
    pub play_count: u64,
}

pub struct SearchPodcastDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub dj_name: String,
    pub program_count: u64,
    pub play_count: u64,
}

/// 综合搜索结果: 单曲/歌手/专辑/歌单/播客 各一个板块
pub struct SearchBundleDto {
    pub songs: Vec<SongDto>,
    pub song_total: u64,
    pub artists: Vec<SearchArtistDto>,
    pub albums: Vec<SearchAlbumDto>,
    pub playlists: Vec<SearchPlaylistDto>,
    pub podcasts: Vec<SearchPodcastDto>,
}

/// 综合搜索: 一次拿回所有板块(UI 分区展示).
pub async fn search_all(keywords: String, limit: u32) -> Result<SearchBundleDto, String> {
    let provider = with_provider(Capability::SearchAll)?;
    let query = SearchQuery { keywords, limit, offset: 0 };
    let bundle = provider
        .search_all(&query)
        .await
        .map_err(|e| e.to_string())?;
    Ok(SearchBundleDto {
        songs: bundle.songs.into_iter().map(song_dto).collect(),
        song_total: bundle.song_total,
        artists: bundle
            .artists
            .into_iter()
            .map(|a| SearchArtistDto {
                id: a.id,
                name: a.name,
                avatar_url: a.avatar_url,
                alias: a.alias,
                album_count: a.album_count,
                music_count: a.music_count,
            })
            .collect(),
        albums: bundle
            .albums
            .into_iter()
            .map(|a| SearchAlbumDto {
                id: a.id,
                name: a.name,
                cover_url: a.cover_url,
                artist: a.artist,
                track_count: a.track_count,
            })
            .collect(),
        playlists: bundle
            .playlists
            .into_iter()
            .map(|p| SearchPlaylistDto {
                id: p.id,
                name: p.name,
                cover_url: p.cover_url,
                creator_name: p.creator_name,
                track_count: p.track_count,
                play_count: p.play_count,
            })
            .collect(),
        podcasts: bundle
            .podcasts
            .into_iter()
            .map(|r| SearchPodcastDto {
                id: r.id,
                name: r.name,
                cover_url: r.cover_url,
                dj_name: r.dj_name,
                program_count: r.program_count,
                play_count: r.play_count,
            })
            .collect(),
    })
}

// ---------------- 歌手详情 ----------------

pub struct AlbumBriefDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub track_count: u64,
    pub publish_time: u64,
}

pub struct ArtistDetailDto {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub cover_url: Option<String>,
    pub alias: Vec<String>,
    pub brief_desc: String,
    pub album_count: u64,
    pub music_count: u64,
    pub songs: Vec<SongDto>,
    pub albums: Vec<AlbumBriefDto>,
}

/// 歌手详情(头像/简介/热门歌曲/专辑)
pub async fn artist_detail(artist_id: u64) -> Result<ArtistDetailDto, String> {
    let provider = with_provider(Capability::Artist)?;
    let a = provider
        .artist_detail(artist_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(ArtistDetailDto {
        id: a.id,
        name: a.name,
        avatar_url: a.avatar_url,
        cover_url: a.cover_url,
        alias: a.alias,
        brief_desc: a.brief_desc,
        album_count: a.album_count,
        music_count: a.music_count,
        songs: a.songs.into_iter().map(song_dto).collect(),
        albums: a
            .albums
            .into_iter()
            .map(|x| AlbumBriefDto {
                id: x.id,
                name: x.name,
                cover_url: x.cover_url,
                track_count: x.track_count,
                publish_time: x.publish_time,
            })
            .collect(),
    })
}

// ---------------- 个人主页资料 ----------------

pub struct ProfileDetailDto {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub background_url: Option<String>,
    pub signature: String,
    pub vip: bool,
    pub follows: u64,
    pub followeds: u64,
    pub level: u64,
}

/// 个人主页资料(背景图/头像/签名/关注数). 需要登录.
pub async fn profile_detail() -> Result<ProfileDetailDto, String> {
    let provider = with_provider(Capability::ProfileDetail)?;
    let p = provider
        .profile_detail()
        .await
        .map_err(|e| e.to_string())?;
    Ok(ProfileDetailDto {
        user_id: p.user_id,
        nickname: p.nickname,
        avatar_url: p.avatar_url,
        background_url: p.background_url,
        signature: p.signature,
        vip: p.vip,
        follows: p.follows,
        followeds: p.followeds,
        level: p.level,
    })
}

/// 收藏曲目到指定歌单(需登录)
pub async fn add_to_playlist(playlist_id: u64, track_id: u64) -> Result<bool, String> {
    let provider = with_provider(Capability::PlaylistEdit)?;
    provider
        .add_to_playlist(playlist_id, ncm_domain::TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())
}

pub async fn song_url(track_id: u64, level: String) -> Result<StreamDto, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::SongUrl)
            .ok_or_else(|| "no provider supports songUrl".to_string())?
    };
    let level = ncm_provider::AudioLevel::parse(&level).unwrap_or_default();
    let req = ncm_provider::SongUrlRequest { track: ncm_domain::TrackId::new(track_id), level };
    let stream = provider.song_url(&req).await.map_err(|e| e.to_string())?;
    Ok(StreamDto {
        url: stream.url,
        quality: stream.quality,
        br: stream.br,
        expire_at: stream.expire_at,
    })
}

pub async fn lyric(track_id: u64) -> Result<String, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::Lyric)
            .ok_or_else(|| "no provider supports lyric".to_string())?
    };
    let lyric = provider
        .lyric(ncm_domain::TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())?;
    Ok(lyric.lrc.unwrap_or_default())
}

/// 退出登录: 只清登录凭据, 设备指纹(deviceId/_ntes_*/WNMCID/NMTID)保留.
/// 账号本身留在账号簿里, 下次可以一键切回(不用重新扫码).
/// 返回 true 表示现在已经不是登录态.
pub fn logout() -> Result<bool, String> {
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    guard.logout().map_err(|e| e.to_string())?;
    Ok(!guard.session.is_logged_in())
}

// ---------------- 多账号(账号簿) ----------------

pub struct AccountDto {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub active: bool,
    pub vip: bool,
}

fn accounts_of(guard: &Core) -> Result<Vec<AccountDto>, String> {
    let book = guard.accounts().map_err(|e| e.to_string())?;
    Ok(book
        .accounts
        .into_iter()
        .map(|a| AccountDto {
            user_id: a.user_id,
            nickname: a.nickname,
            avatar_url: a.avatar_url,
            active: book.active == Some(a.user_id),
            vip: a.vip,
        })
        .collect())
}

/// 已记住的账号列表(只含凭据, 指纹共享)
pub fn accounts() -> Result<Vec<AccountDto>, String> {
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    accounts_of(&guard)
}

/// 登录后/启动时调用: 拉一次账号资料并记进账号簿.
/// 失败(离线/风控)不影响已登录状态, UI 只当作"没有昵称"。
pub async fn account_sync_active() -> Result<AccountDto, String> {
    let (logged_in, provider) = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        if !guard.session.is_logged_in() {
            return Err("未登录".to_string());
        }
        let provider = guard
            .providers
            .first_with(Capability::Profile)
            .ok_or_else(|| "no provider supports profile".to_string())?;
        (true, provider)
    };
    debug_assert!(logged_in);
    let profile = provider.profile().await.map_err(|e| e.to_string())?;
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    guard.remember_account(&profile).map_err(|e| e.to_string())?;
    Ok(AccountDto {
        user_id: profile.user_id,
        nickname: profile.nickname,
        avatar_url: profile.avatar_url,
        active: true,
        vip: profile.vip,
    })
}

/// 切换到账号簿里的某个账号(不重新登录)
pub async fn account_switch(user_id: u64) -> Result<bool, String> {
    {
        let mut guard = core()?.lock().map_err(|e| e.to_string())?;
        if !guard.switch_account(user_id).map_err(|e| e.to_string())? {
            return Ok(false);
        }
    }
    // 切完顺手同步一次昵称/头像(失败不影响切换)
    let _ = account_sync_active().await;
    Ok(true)
}

/// 从账号簿移除某个账号(不影响当前登录态, 只是忘掉它的凭据)
pub fn account_remove(user_id: u64) -> Result<bool, String> {
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    let before = guard.accounts().map_err(|e| e.to_string())?.accounts.len();
    let book = guard.forget_account(user_id).map_err(|e| e.to_string())?;
    Ok(book.accounts.len() < before)
}

// ---------------- 收藏(红心)与歌单 ----------------

pub struct PlaylistDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub track_count: u64,
    /// 是否"我喜欢的音乐"
    pub special: bool,
}

fn with_provider(
    cap: Capability,
) -> Result<std::sync::Arc<dyn ncm_provider::Provider>, String> {
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    guard
        .providers
        .first_with(cap)
        .ok_or_else(|| format!("no provider supports {}", cap.as_str()))
        .map(|p| p.clone())
}

/// "我喜欢的音乐"里的曲目 id(红心状态的唯一真相)
pub async fn liked_ids() -> Result<Vec<u64>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let ids = provider.liked_ids().await.map_err(|e| e.to_string())?;
    Ok(ids.into_iter().map(|t| t.0).collect())
}

/// 红心/取消红心(需登录)
pub async fn set_liked(track_id: u64, liked: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::Playlist)?;
    provider
        .set_like(ncm_domain::TrackId::new(track_id), liked)
        .await
        .map_err(|e| e.to_string())
}

/// 我的歌单(含"我喜欢的音乐")
pub async fn my_playlists() -> Result<Vec<PlaylistDto>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let list = provider.user_playlists().await.map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|p| PlaylistDto {
            id: p.id,
            name: p.name,
            cover_url: p.cover_url,
            track_count: p.track_count,
            special: p.special,
        })
        .collect())
}

/// 某个歌单的曲目
pub async fn playlist_songs(playlist_id: u64) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let songs = provider
        .playlist_songs(playlist_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// "我喜欢的音乐"曲目详情(按收藏时间从新到旧)
pub async fn liked_songs() -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::Playlist)?;
    // 优先用歌单详情的 addTime(真实收藏时间)排序; 老 provider 回落到 likelist 顺序
    match provider.liked_songs_ordered().await {
        Ok(songs) if !songs.is_empty() => return Ok(songs.into_iter().map(song_dto).collect()),
        Ok(_) => {}
        Err(_) => {}
    }
    let ids = provider.liked_ids().await.map_err(|e| e.to_string())?;
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    // 先把 id 拼成一次详情请求(vendor 的 song_detail 只认逗号分隔), 分块避免 URL 过长
    // 详情接口不保证按请求顺序返回(还可能缺曲), 用 id→Song 映射按 likelist 顺序还原
    let mut by_id: std::collections::HashMap<u64, ncm_domain::Song> =
        std::collections::HashMap::new();
    for chunk in ids.chunks(500) {
        let joined = chunk.iter().map(|t| t.0.to_string()).collect::<Vec<_>>().join(",");
        let detail = provider
            .songs_detail(&joined)
            .await
            .map_err(|e| e.to_string())?;
        for s in detail {
            by_id.insert(s.id.0, s);
        }
    }
    Ok(ids.iter().filter_map(|t| by_id.remove(&t.0)).map(song_dto).collect())
}

/// 一行歌词(已按时间排序, 翻译按时间戳对齐)
pub struct LyricLineDto {
    pub time_ms: u64,
    pub text: String,
    pub sub: Option<String>,
}

/// 解析好的歌词时间轴. UI 只需要按 position 找当前行, 不再自己啃 LRC.
pub async fn lyric_lines(track_id: u64) -> Result<Vec<LyricLineDto>, String> {
    let raw = lyric(track_id).await?;
    Ok(ncm_domain::parse_lrc_with_translation(&raw, None)
        .into_iter()
        .map(|l| LyricLineDto { time_ms: l.time_ms, text: l.text, sub: l.sub })
        .collect())
}

/// 带翻译的歌词时间轴(网易云 tlyric). 无翻译时等价于 lyric_lines.
pub async fn lyric_lines_i18n(track_id: u64) -> Result<Vec<LyricLineDto>, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::Lyric)
            .ok_or_else(|| "no provider supports lyric".to_string())?
    };
    let lyric = provider
        .lyric(ncm_domain::TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())?;
    Ok(ncm_domain::parse_lrc_with_translation(
        lyric.lrc.as_deref().unwrap_or_default(),
        lyric.translated.as_deref(),
    )
    .into_iter()
    .map(|l| LyricLineDto { time_ms: l.time_ms, text: l.text, sub: l.sub })
    .collect())
}

/// 导入登录 cookie(手机端/浏览器导出), 与设备指纹合并后持久化.
pub fn login_with_cookie(cookie: String) -> Result<bool, String> {
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    let merged = ncm_service::identity::merge_device_cookie(
        &guard.session.cookie,
        &cookie,
        &guard.session.device_id,
    );
    let mut next = guard.session.clone();
    next.cookie = merged;
    guard.apply_session(next).map_err(|e| e.to_string())?;
    Ok(guard.session.is_logged_in())
}

pub fn ping(name: String) -> String {
    format!("pong from rust: {name}")
}

// ---------------- 播放 ----------------

static PLAYER: OnceLock<ncm_playback::Player> = OnceLock::new();
static DATA_DIR: OnceLock<std::path::PathBuf> = OnceLock::new();

fn player() -> &'static ncm_playback::Player {
    PLAYER.get_or_init(ncm_playback::Player::new)
}

pub struct PlayerStateDto {
    pub track_id: Option<u64>,
    pub playing: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
}

fn state_dto() -> PlayerStateDto {
    let s = player().state();
    PlayerStateDto {
        track_id: s.track_id,
        playing: s.playing,
        position_ms: s.position_ms,
        duration_ms: s.duration_ms,
        volume: s.volume,
    }
}

/// 下载(带缓存)后交给平台播放后端. 直链有时效, 所以先落盘再播.
pub async fn play_track(track_id: u64, url: String) -> Result<PlayerStateDto, String> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?
        .join("audio");
    let cache = ncm_service::cache::AudioCache::open(&dir).map_err(|e| e.to_string())?;
    let path = cache.fetch(track_id, &url).await?;
    player().play_file(track_id, path.to_string_lossy().to_string());
    Ok(state_dto())
}

pub fn player_state() -> PlayerStateDto {
    state_dto()
}

pub fn player_pause() -> PlayerStateDto {
    player().pause();
    state_dto()
}

pub fn player_resume() -> PlayerStateDto {
    player().resume();
    state_dto()
}

pub fn player_stop() -> PlayerStateDto {
    player().stop();
    state_dto()
}

pub fn player_seek(position_ms: u64) -> PlayerStateDto {
    player().seek(position_ms);
    state_dto()
}

pub fn player_set_volume(volume: f32) -> PlayerStateDto {
    player().set_volume(volume);
    state_dto()
}

// ---------------- 每日推荐 / 心动模式 ----------------

/// 每日推荐歌曲(原版每日推荐)
pub async fn daily_recommend_songs() -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::DailyRecommend)?;
    let songs = provider
        .daily_recommend_songs()
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// 每日推荐歌单(原版推荐歌单, 需要登录)
pub async fn daily_recommend_playlists() -> Result<Vec<PlaylistDto>, String> {
    let provider = with_provider(Capability::DailyRecommend)?;
    let list = provider
        .daily_recommend_playlists()
        .await
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|p| PlaylistDto {
            id: p.id,
            name: p.name,
            cover_url: p.cover_url,
            track_count: p.track_count,
            special: p.special,
        })
        .collect())
}

/// 心动模式: 以当前曲目为种子, 在 playlist_id(0 = 不限定)里续播 count 首
pub async fn heart_mode_songs(
    song_id: u64,
    playlist_id: u64,
    count: u32,
) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::DailyRecommend)?;
    let songs = provider
        .intelligence_songs(song_id, playlist_id, count)
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

// ---------------- 搜索建议 / 历史 ----------------

pub struct SuggestItemDto {
    /// song | artist | album | playlist
    pub kind: String,
    pub id: u64,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
}

/// 搜索建议(输入联想)
pub async fn search_suggest(keywords: String) -> Result<Vec<SuggestItemDto>, String> {
    if keywords.trim().is_empty() {
        return Ok(Vec::new());
    }
    let provider = with_provider(Capability::SearchSuggest)?;
    let items = provider
        .search_suggest(keywords.trim())
        .await
        .map_err(|e| e.to_string())?;
    Ok(items
        .into_iter()
        .map(|s| SuggestItemDto {
            kind: s.kind,
            id: s.id,
            title: s.title,
            subtitle: s.subtitle,
            cover_url: s.cover_url,
        })
        .collect())
}

fn history_store() -> Result<ncm_service::HistoryStore, String> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?;
    ncm_service::HistoryStore::open(dir).map_err(|e| e.to_string())
}

/// 搜索历史(最近在前)
pub fn search_history() -> Result<Vec<String>, String> {
    Ok(history_store()?.search_history())
}

/// 记一条搜索(去重, 最近在前), 返回新的历史列表
pub fn record_search(keyword: String) -> Result<Vec<String>, String> {
    history_store()?
        .record_search(&keyword)
        .map_err(|e| e.to_string())
}

pub fn clear_search_history() -> Result<bool, String> {
    history_store()?.clear_search().map_err(|e| e.to_string())?;
    Ok(true)
}

/// 记一次播放到本地历史(未登录/离线时的"最近听过"来源)
pub fn remember_play(song: SongDto) -> Result<bool, String> {
    let domain = song_from_dto(&song);
    history_store()?
        .record_play(&domain)
        .map_err(|e| e.to_string())?;
    Ok(true)
}

/// 本地播放历史
pub fn local_recent_songs(limit: u32) -> Result<Vec<SongDto>, String> {
    let n = limit.max(1) as usize;
    Ok(history_store()?
        .played()
        .into_iter()
        .take(n)
        .map(song_dto)
        .collect())
}

/// 最近听过: 登录时优先服务端记录, 失败/未登录回落到本地历史
pub async fn recent_songs(limit: u32) -> Result<Vec<SongDto>, String> {
    let logged_in = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard.session.is_logged_in()
    };
    if logged_in {
        if let Ok(provider) = with_provider(Capability::Recent) {
            if let Ok(list) = provider.recent_songs(limit).await {
                if !list.is_empty() {
                    return Ok(list.into_iter().map(song_dto).collect());
                }
            }
        }
    }
    local_recent_songs(limit)
}

// ---------------- 专辑封面预览 ----------------

pub struct AlbumDetailDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub description: String,
    pub songs: Vec<SongDto>,
}

pub async fn album_detail(album_id: u64) -> Result<AlbumDetailDto, String> {
    let provider = with_provider(Capability::Album)?;
    let album = provider
        .album_detail(album_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(AlbumDetailDto {
        id: album.id,
        name: album.name,
        cover_url: album.cover_url,
        artist: album.artist,
        description: album.description,
        songs: album.songs.into_iter().map(song_dto).collect(),
    })
}

// ---------------- 歌单详情 / 评论 / 分享 ----------------

pub struct PlaylistDetailDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub description: String,
    /// 创建者昵称
    pub creator_name: String,
    pub track_count: u64,
    pub play_count: u64,
    /// 当前账号是否已收藏
    pub subscribed: bool,
    pub subscribed_count: u64,
    pub share_count: u64,
    pub comment_count: u64,
    pub tags: Vec<String>,
}

/// 歌单详情(歌单页头部信息)
pub async fn playlist_detail(playlist_id: u64) -> Result<PlaylistDetailDto, String> {
    let provider = with_provider(Capability::PlaylistDetail)?;
    let d = provider
        .playlist_detail(playlist_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(PlaylistDetailDto {
        id: d.id,
        name: d.name,
        cover_url: d.cover_url,
        description: d.description,
        creator_name: d.creator_name,
        track_count: d.track_count,
        play_count: d.play_count,
        subscribed: d.subscribed,
        subscribed_count: d.subscribed_count,
        share_count: d.share_count,
        comment_count: d.comment_count,
        tags: d.tags,
    })
}

/// 收藏/取消收藏歌单(需登录)
pub async fn set_playlist_subscribed(playlist_id: u64, subscribed: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::PlaylistDetail)?;
    provider
        .set_playlist_subscribed(playlist_id, subscribed)
        .await
        .map_err(|e| e.to_string())
}

pub struct CommentDto {
    pub id: u64,
    pub user_name: String,
    pub avatar_url: Option<String>,
    pub content: String,
    /// 发布时间(unix 毫秒)
    pub time_ms: u64,
    pub liked_count: u64,
    /// 当前账号是否已赞
    pub liked: bool,
}

pub struct CommentPageDto {
    /// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重
    pub comments: Vec<CommentDto>,
    pub total: u64,
    pub has_more: bool,
}

/// 评论页 → DTO(歌曲/歌单/动态共用)
fn comment_page_dto(page: ncm_domain::CommentPage) -> CommentPageDto {
    CommentPageDto {
        comments: page
            .comments
            .into_iter()
            .map(|c| CommentDto {
                id: c.id,
                user_name: c.user_name,
                avatar_url: c.avatar_url,
                content: c.content,
                time_ms: c.time_ms,
                liked_count: c.liked_count,
                liked: c.liked,
            })
            .collect(),
        total: page.total,
        has_more: page.has_more,
    }
}

/// 评论列表: kind = song | playlist | album | podcast
pub async fn comments(
    kind: String,
    resource_id: u64,
    limit: u32,
    offset: u32,
) -> Result<CommentPageDto, String> {
    let provider = with_provider(Capability::Comment)?;
    let page = provider
        .comments(&kind, resource_id, limit, offset)
        .await
        .map_err(|e| e.to_string())?;
    Ok(comment_page_dto(page))
}

/// 分享资源到动态(需登录). kind = song | playlist | album | podcast
pub async fn share_resource(kind: String, resource_id: u64, msg: String) -> Result<bool, String> {
    let provider = with_provider(Capability::Share)?;
    provider
        .share_resource(&kind, resource_id, &msg)
        .await
        .map_err(|e| e.to_string())
}

// ---------------- 播客 ----------------

pub struct PodcastRadioDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub description: String,
    pub dj_name: String,
    pub program_count: u64,
    pub play_count: u64,
}

pub struct PodcastProgramDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub duration_ms: u64,
    pub dj_name: String,
    pub radio_id: u64,
    pub radio_name: String,
    pub description: String,
    /// 节目音频本体(播放用 song.id 取直链)
    pub song: Option<SongDto>,
}

fn radio_dto(r: ncm_domain::PodcastRadio) -> PodcastRadioDto {
    PodcastRadioDto {
        id: r.id,
        name: r.name,
        cover_url: r.cover_url,
        description: r.description,
        dj_name: r.dj_name,
        program_count: r.program_count,
        play_count: r.play_count,
    }
}

fn program_dto(p: ncm_domain::PodcastProgram) -> PodcastProgramDto {
    PodcastProgramDto {
        id: p.id,
        name: p.name,
        cover_url: p.cover_url,
        duration_ms: p.duration_ms,
        dj_name: p.dj_name,
        radio_id: p.radio_id,
        radio_name: p.radio_name,
        description: p.description,
        song: p.song.map(song_dto),
    }
}

/// 热门播客/电台
pub async fn podcast_hot(limit: u32) -> Result<Vec<PodcastRadioDto>, String> {
    let provider = with_provider(Capability::Podcast)?;
    let list = provider.podcast_hot(limit).await.map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(radio_dto).collect())
}

/// 某个播客的节目列表
pub async fn podcast_programs(
    radio_id: u64,
    limit: u32,
    offset: u32,
) -> Result<Vec<PodcastProgramDto>, String> {
    let provider = with_provider(Capability::Podcast)?;
    let list = provider
        .podcast_programs(radio_id, limit, offset)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(program_dto).collect())
}

/// 单个节目详情
pub async fn podcast_program(program_id: u64) -> Result<PodcastProgramDto, String> {
    let provider = with_provider(Capability::Podcast)?;
    let p = provider
        .podcast_program(program_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(program_dto(p))
}

/// 播客/电台详情
pub async fn podcast_radio(radio_id: u64) -> Result<PodcastRadioDto, String> {
    let provider = with_provider(Capability::PodcastDetail)?;
    let r = provider
        .podcast_radio(radio_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(radio_dto(r))
}

// ---------------- 搜索页(热词/推荐词) ----------------

pub struct HotSearchTermDto {
    /// 1 开始的名次
    pub rank: u32,
    pub keyword: String,
}

/// 热门搜索榜(按热度排序)
pub async fn hot_search() -> Result<Vec<HotSearchTermDto>, String> {
    let provider = with_provider(Capability::SearchHot)?;
    let list = provider.hot_search().await.map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|t| HotSearchTermDto { rank: t.rank, keyword: t.keyword })
        .collect())
}

pub struct DefaultSearchDto {
    /// 真正要搜索的关键词(不含推荐理由)
    pub keyword: String,
    /// 官方展示文案, 形如 "🔥Mili 你的十月榜首"
    pub show_text: String,
    pub image_url: Option<String>,
}

/// 默认/推荐搜索词("猜你想搜"); 接口没有时返回 null
pub async fn default_search() -> Result<Option<DefaultSearchDto>, String> {
    let provider = with_provider(Capability::SearchHot)?;
    Ok(provider
        .default_search()
        .await
        .map_err(|e| e.to_string())?
        .map(|d| DefaultSearchDto {
            keyword: d.keyword,
            show_text: d.show_text,
            image_url: d.image_url,
        }))
}

// ---------------- 推荐页(私人 FM) / 我的(收藏播客/关注艺人/动态) ----------------

/// 私人 FM(需登录)
pub async fn personal_fm(limit: u32) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::PersonalFm)?;
    let songs = provider
        .personal_fm(limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// 已收藏/订阅的播客(需登录)
pub async fn subscribed_podcasts(limit: u32) -> Result<Vec<PodcastRadioDto>, String> {
    let provider = with_provider(Capability::Podcast)?;
    let list = provider
        .subscribed_podcasts(limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(radio_dto).collect())
}

pub struct ArtistDto {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
}

/// 关注的艺人(需登录)
pub async fn subscribed_artists(limit: u32) -> Result<Vec<ArtistDto>, String> {
    let provider = with_provider(Capability::Feed)?;
    let list = provider
        .subscribed_artists(limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|a| ArtistDto { id: a.id, name: a.name, avatar_url: a.avatar_url })
        .collect())
}

pub struct FeedEventDto {
    pub id: u64,
    /// 评论/点赞用的 threadId
    pub thread_id: String,
    /// 发布者用户 id
    pub user_id: u64,
    /// song | playlist | album | program | text | other
    pub kind: String,
    pub user_name: String,
    pub avatar_url: Option<String>,
    pub text: String,
    pub song: Option<SongDto>,
    pub cover_url: Option<String>,
    pub images: Vec<String>,
    /// 视频动态的直链
    pub video_url: Option<String>,
    /// 动态自带标题(艺人长文)
    pub title: String,
    /// unix 毫秒
    pub time_ms: u64,
    pub liked: bool,
    pub liked_count: u64,
    pub share_count: u64,
    pub comment_count: u64,
}

/// 关注动态(需登录): 关注的人/艺人发布的单曲、歌单、专辑、节目或文字动态
pub async fn feed_events(limit: u32, last_time: i64) -> Result<Vec<FeedEventDto>, String> {
    let provider = with_provider(Capability::Feed)?;
    let list = provider
        .feed_events(limit, last_time)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|e| FeedEventDto {
            id: e.id,
            thread_id: e.thread_id,
            user_id: e.user_id,
            kind: e.kind,
            user_name: e.user_name,
            avatar_url: e.avatar_url,
            text: e.text,
            song: e.song.map(song_dto),
            cover_url: e.cover_url,
            images: e.images,
            video_url: e.video_url,
            title: e.title,
            time_ms: e.time_ms,
            liked: e.liked,
            liked_count: e.liked_count,
            share_count: e.share_count,
            comment_count: e.comment_count,
        })
        .collect())
}

/// 动态评论区(threadId 来自 FeedEvent.thread_id)
pub async fn event_comments(
    thread_id: String,
    limit: u32,
    offset: u32,
) -> Result<CommentPageDto, String> {
    let provider = with_provider(Capability::Feed)?;
    let page = provider
        .event_comments(&thread_id, limit, offset)
        .await
        .map_err(|e| e.to_string())?;
    Ok(comment_page_dto(page))
}

/// 点赞/取消点赞一条动态
pub async fn like_event(thread_id: String, liked: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::Feed)?;
    provider
        .like_event(&thread_id, liked)
        .await
        .map_err(|e| e.to_string())
}

/// 转发一条动态(附转发语)
pub async fn forward_event(event_id: u64, user_id: u64, msg: String) -> Result<bool, String> {
    let provider = with_provider(Capability::Feed)?;
    provider
        .forward_event(event_id, user_id, &msg)
        .await
        .map_err(|e| e.to_string())
}
