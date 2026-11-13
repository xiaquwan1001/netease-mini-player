/// API 模块 - 对应 Node.js 版本的 module/ 目录
///
/// 每个 API 接口拆分为独立文件，通过 `impl ApiClient` 扩展方法
/// 所有方法统一使用 `Query` 对象传参
use crate::request::{CryptoType, RequestOption};
use std::collections::HashMap;

// ---- 歌曲相关 ----
mod like;
mod likelist;
mod lyric;
mod lyric_new;
mod song_detail;
mod song_purchased;
mod song_url_v1;
mod song_wiki_summary;

// ---- 搜索相关 ----
mod cloudsearch;
mod search_default;
mod search_hot;
mod search_hot_detail;
mod search_multimatch;
mod search_suggest;

// ---- 歌单相关 ----
mod playlist_catlist;
mod playlist_create;
mod playlist_delete;
mod playlist_desc_update;
mod playlist_detail;
mod playlist_name_update;
mod playlist_subscribe;
mod playlist_track_all;
mod playlist_track_delete;
mod playlist_tracks;
mod user_playlist;

// ---- 歌手相关 ----
mod artist_album;
mod artist_detail;
mod artist_mv;
mod artist_songs;
mod artist_sub;
mod artist_sublist;
mod artist_top_song;
mod mv_detail;
mod mv_url;

// ---- 专辑相关 ----
mod album;
mod album_new;
mod album_newest;
mod album_sub;
mod album_sublist;

// ---- 评论相关 ----
mod comment_album;
mod comment_delete;
mod comment_dj;
mod comment_event;
mod comment_floor;
mod comment_hot;
mod comment_info_list;
mod comment_like;
mod comment_music;
mod comment_mv;
mod comment_playlist;
mod comment_reply;
mod comment_video;

// ---- 推荐相关 ----
mod history_recommend_songs;
mod history_recommend_songs_detail;
mod personalized_newsong;
mod recommend_resource;
mod recommend_songs;
mod recommend_songs_dislike;

// ---- 用户相关 ----
mod follow;
mod user_account;
mod user_detail;
mod user_followeds;
mod user_follows;
mod user_level;
mod user_medal;
mod user_record;
mod user_subcount;

// ---- 私人 FM ----
mod fm_trash;
mod personal_fm;

// ---- 签到 ----
mod daily_signin;
mod signin_progress;

// ---- 电台相关 ----
mod dj_category_recommend;
mod dj_catelist;
mod dj_detail;
mod dj_hot;
mod dj_program;
mod dj_program_detail;
mod dj_program_toplist;
mod dj_recommend_type;
mod dj_sublist;
mod dj_subscriber;
mod dj_toplist;
mod dj_toplist_hours;
mod dj_toplist_newcomer;
mod dj_toplist_pay;
mod dj_toplist_popular;

// ---- 相似推荐 ----
mod simi_artist;
mod simi_playlist;
mod simi_song;

// ---- 排行榜 ----
mod top_album;
mod top_artists;
mod top_playlist;
mod top_playlist_highquality;
mod top_song;
mod toplist_detail;
mod toplist_detail_v2;

// ---- 私信 ----
mod msg_comments;
mod msg_forwards;
mod msg_notices;
mod msg_private;
mod msg_private_history;
mod msg_recentcontact;

// ---- 动态 ----
mod event;
mod event_forward;

// ---- 发送/分享 ----
mod share_resource;

// ---- 资源操作 ----
mod resource_like;

// ---- 最近播放 ----
mod record_recent_album;
mod record_recent_dj;
mod record_recent_playlist;
mod record_recent_song;

// ---- 曲风相关 ----
mod style_list;
mod style_playlist;
mod style_preference;
mod style_song;

// ---- 数字专辑相关 ----
mod digital_album_detail;
mod digital_album_purchased;
mod digital_album_sales;

// ---- VIP 相关 ----
mod vip_growthpoint;
mod vip_info_v2;
mod vip_sign_info;
mod vip_tasks;

// ---- 其他 ----
mod pl_count;
mod playmode_intelligence_list;

// ============================================================
//  通用查询参数
// ============================================================

/// 通用查询参数，用于向 API 方法传递参数
#[derive(Debug, Clone, Default)]
pub struct Query {
    pub params: HashMap<String, String>,
    pub cookie: Option<String>,
    pub proxy: Option<String>,
    pub real_ip: Option<String>,
    pub random_cn_ip: bool,
    pub ua: Option<String>,
    pub e_r: Option<bool>,
    pub domain: Option<String>,
}

impl Query {
    pub fn new() -> Self {
        Self::default()
    }

    /// 设置参数
    pub fn param(mut self, key: &str, value: &str) -> Self {
        self.params.insert(key.to_string(), value.to_string());
        self
    }

    /// 设置 cookie
    pub fn cookie(mut self, cookie: &str) -> Self {
        self.cookie = Some(cookie.to_string());
        self
    }

    /// 获取参数值
    pub fn get(&self, key: &str) -> Option<&str> {
        self.params.get(key).map(|s| s.as_str())
    }

    /// 获取参数值，若不存在则返回默认值
    pub fn get_or(&self, key: &str, default: &str) -> String {
        self.params
            .get(key)
            .cloned()
            .unwrap_or_else(|| default.to_string())
    }

    /// 获取 i64 参数，解析失败返回默认值
    ///
    /// 替代 `query.get_or("limit", "30").parse::<i64>().unwrap_or(30)` 模式
    pub fn get_i64(&self, key: &str, default: i64) -> i64 {
        match self.params.get(key) {
            Some(v) => v.parse::<i64>().unwrap_or(default),
            None => default,
        }
    }

    /// 获取 bool 参数（接受 "true"/"false"/"1"/"0"）
    ///
    /// 替代 `query.get_or("like", "true") == "true"` 模式
    pub fn get_bool(&self, key: &str, default: bool) -> bool {
        match self.params.get(key).map(|s| s.as_str()) {
            Some("true") | Some("1") => true,
            Some("false") | Some("0") => false,
            _ => default,
        }
    }

    /// 构造 RequestOption
    pub(crate) fn to_option(&self, crypto: CryptoType) -> RequestOption {
        RequestOption {
            crypto,
            cookie: self.cookie.clone(),
            ua: self.ua.clone(),
            proxy: self.proxy.clone(),
            real_ip: self.real_ip.clone(),
            random_cn_ip: self.random_cn_ip,
            e_r: self.e_r,
            domain: self.domain.clone(),
            check_token: false,
        }
    }
}
