//! `Provider` trait 的落地层: 只把 trait 方法转发到各能力域模块里的同名 `impl NeteaseProvider` 方法.
//!
//! 一个 trait 只能有一个 impl, 所以 trait impl 必须留在单个文件里; 真正的请求逻辑按域分散在
//! `song.rs` / `playlist.rs` / ... 的 `impl NeteaseProvider` 中, 这里只做零逻辑转发.

use super::*;

impl Provider for NeteaseProvider {
    fn id(&self) -> &'static str {
        "netease"
    }

    fn name(&self) -> &str {
        "网易云音乐"
    }

    fn capabilities(&self) -> &'static [Capability] {
        CAPABILITIES
    }

    fn search<'a>(&'a self, query: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
        NeteaseProvider::search(self, query)
    }

    fn song_url<'a>(&'a self, req: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
        NeteaseProvider::song_url(self, req)
    }

    fn lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>> {
        NeteaseProvider::lyric(self, track)
    }

    fn word_lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<WordLyric>> {
        NeteaseProvider::word_lyric(self, track)
    }

    /// "我喜欢的音乐"曲目 id: 红心状态的唯一真相(不用每首去查详情)
    fn liked_ids<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<TrackId>>> {
        NeteaseProvider::liked_ids(self)
    }

    /// 听歌排行(需要登录): type=0 全部时间 / type=1 最近一周.
    /// 响应形如 {code:200, allData:[{playCount,score,song:{...}}], weekData:[...]}
    fn play_ranking(
        &self,
        period: RankingPeriod,
    ) -> BoxFuture<'_, ProviderResult<Vec<PlayRankEntry>>> {
        NeteaseProvider::play_ranking(self, period)
    }

    /// 我的曲风偏好: 系统按听歌口味算出来的风格(登录才有).
    /// 未登录/接口给空时退化成通用曲风表(style_list 的二级标签), 保证推荐页总有入口.
    fn style_preference(&self) -> BoxFuture<'_, ProviderResult<Vec<StyleTag>>> {
        NeteaseProvider::style_preference(self)
    }

    /// 某个曲风下的歌曲: 响应形如 {code:200, data:{songs:[...], page:{...}}}
    fn style_songs<'a>(
        &'a self,
        tag_id: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        NeteaseProvider::style_songs(self, tag_id, limit)
    }

    /// 某个曲风下的歌单: 响应形如 {code:200, data:{playlist:[...], page:{...}}}
    fn style_playlists<'a>(
        &'a self,
        tag_id: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::style_playlists(self, tag_id, limit)
    }

    /// 排行榜列表: 榜单就是歌单, 详情直接走 playlist_songs / playlist_detail.
    /// 响应形如 {code, list:[{id,name,coverImgUrl,updateFrequency,trackCount,playCount,tracks}]}
    fn charts(&self) -> BoxFuture<'_, ProviderResult<Vec<ChartSummary>>> {
        NeteaseProvider::charts(self)
    }

    /// 榜单 v2 目录(toplist_detail_v2): 按 categoryCode 分组的榜单卡.
    /// 实测没有 v1 的 trackUpdateTime 数字字段; "更新 N 首"混在 updateFrequency 字符串里,
    /// 增强点是按 categoryCode 分组 + canPlay(个别卡 id=0 且不可播).
    fn toplist_catalog(&self) -> BoxFuture<'_, ProviderResult<Vec<ToplistCatalogGroup>>> {
        NeteaseProvider::toplist_catalog(self)
    }

    /// 歌单分类: 响应形如 {code, categories:{0:"语种",...}, sub:[{category:0,name:"华语"},...]}
    fn playlist_categories(&self) -> BoxFuture<'_, ProviderResult<Vec<PlaylistCategory>>> {
        NeteaseProvider::playlist_categories(self)
    }

    /// 分类歌单: /api/playlist/list, 响应 {code, playlists:[{id,name,coverImgUrl,trackCount}], total, more}
    fn playlists_by_category<'a>(
        &'a self,
        cat: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::playlists_by_category(self, cat, limit, offset)
    }

    /// 精品歌单: /api/playlist/highquality/list, 响应 {code, playlists:[...], more, lasttime}
    fn high_quality_playlists<'a>(
        &'a self,
        cat: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::high_quality_playlists(self, cat, limit)
    }

    /// 我收藏的专辑: 响应 {code, data:[{id,name,picUrl,artist:{name},size}], hasMore}
    fn subscribed_albums(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        NeteaseProvider::subscribed_albums(self, limit)
    }

    /// 收藏/取消收藏专辑: t=1 收藏, 0 取消
    fn set_album_subscribed(
        &self,
        album_id: u64,
        subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::set_album_subscribed(self, album_id, subscribed)
    }

    /// 新建歌单: 响应 {code, id, playlist:{id,...}}(id 在顶层, 实测样例见 docs/b7-playlist-write-notes.md)
    fn create_playlist<'a>(
        &'a self,
        name: &'a str,
        privacy: u8,
    ) -> BoxFuture<'a, ProviderResult<u64>> {
        NeteaseProvider::create_playlist(self, name, privacy)
    }

    /// 批量把曲目加入歌单(op=add). vendor 把逗号分隔 id 序列化成字符串数组进 trackIds;
    /// 响应 {"code":200,"count":N,...}, count 可小于提交数(重复曲目服务端跳过).
    fn playlist_tracks_add<'a>(
        &'a self,
        playlist_id: u64,
        song_ids: &'a [u64],
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::playlist_tracks_add(self, playlist_id, song_ids)
    }

    /// 删除歌单
    fn delete_playlist(&self, playlist_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::delete_playlist(self, playlist_id)
    }

    fn rename_playlist<'a>(
        &'a self,
        playlist_id: u64,
        name: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::rename_playlist(self, playlist_id, name)
    }

    fn update_playlist_desc<'a>(
        &'a self,
        playlist_id: u64,
        desc: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::update_playlist_desc(self, playlist_id, desc)
    }

    /// 把一首歌移出歌单
    fn remove_track(
        &self,
        playlist_id: u64,
        track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::remove_track(self, playlist_id, track)
    }

    /// 评论点赞: vendor 用 (type,id) 拼 threadId, 这里反解 threadId
    fn like_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
        liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::like_comment(self, thread_id, comment_id, liked)
    }

    /// 楼层回复: 某条评论下的回复列表
    fn comment_replies<'a>(
        &'a self,
        thread_id: &'a str,
        parent_comment_id: u64,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        NeteaseProvider::comment_replies(self, thread_id, parent_comment_id, limit)
    }

    /// 回复评论(需要登录)
    fn reply_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
        content: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::reply_comment(self, thread_id, comment_id, content)
    }

    /// 某人关注的人. 响应形如 {code, follow:[{userId,nickname,avatarUrl,signature}]}
    fn user_follows(
        &self,
        uid: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        NeteaseProvider::user_follows(self, uid, limit, offset)
    }

    /// 某人的粉丝
    fn user_followeds(
        &self,
        uid: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        NeteaseProvider::user_followeds(self, uid, limit, offset)
    }

    /// 关注/取关某人: t=1 关注, 0 取关
    fn set_follow(&self, uid: u64, follow: bool) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::set_follow(self, uid, follow)
    }

    /// 我的关注/粉丝数: {code, follow, fans, ...}
    fn follow_counts(&self) -> BoxFuture<'_, ProviderResult<FollowCount>> {
        NeteaseProvider::follow_counts(self)
    }

    /// 新歌速递: {code, result:[{id,name,picUrl,song:{完整歌曲}}]}
    fn new_songs(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        NeteaseProvider::new_songs(self, limit)
    }

    /// 新碟上架: {code, albums:[{id,name,picUrl,artist:{name},size}]}
    fn new_albums(&self, limit: u32, offset: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        NeteaseProvider::new_albums(self, limit, offset)
    }

    /// 最新专辑(album_newest): 与 album_new 不同源, 实测固定 12 张, 无 total, 不翻页.
    fn newest_albums(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        NeteaseProvider::newest_albums(self, limit)
    }

    /// 相似歌曲: {code, songs:[完整歌曲]}
    fn similar_songs(&self, song_id: u64, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        NeteaseProvider::similar_songs(self, song_id, limit)
    }

    /// 相似歌单: {code, playlists:[...]}
    fn similar_playlists(
        &self,
        song_id: u64,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::similar_playlists(self, song_id, limit)
    }

    /// 相似歌手: {code, artists:[{id,name,picUrl}]}(需要登录)
    fn similar_artists(&self, artist_id: u64) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        NeteaseProvider::similar_artists(self, artist_id)
    }

    /// 歌手全部歌曲(artist_songs): offset/limit 分页, more=还有下一页
    fn artist_songs_page<'a>(
        &'a self,
        artist_id: u64,
        offset: u32,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistSongPage>> {
        NeteaseProvider::artist_songs_page(self, artist_id, offset, limit)
    }

    /// 关注/取消关注歌手(artist_sub: t=1 sub / t=0 unsub), 需要登录.
    fn toggle_artist_sub<'a>(
        &'a self,
        artist_id: u64,
        sub: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::toggle_artist_sub(self, artist_id, sub)
    }

    /// 歌手 MV(artist_mv): offset/limit 分页, hasMore=还有下一页
    fn artist_mvs_page<'a>(
        &'a self,
        artist_id: u64,
        offset: u32,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistMvPage>> {
        NeteaseProvider::artist_mvs_page(self, artist_id, offset, limit)
    }

    /// MV 详情(mv_detail)
    fn mv_detail<'a>(&'a self, mv_id: u64) -> BoxFuture<'a, ProviderResult<MvDetail>> {
        NeteaseProvider::mv_detail(self, mv_id)
    }

    /// MV 播放链接(mv_url, r=清晰度档位如 1080)
    fn mv_url<'a>(&'a self, mv_id: u64, r: u32) -> BoxFuture<'a, ProviderResult<MvUrl>> {
        NeteaseProvider::mv_url(self, mv_id, r)
    }

    /// 每日推荐"不感兴趣": /api/v2/discovery/recommend/dislike
    fn dislike_recommend_song(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::dislike_recommend_song(self, song_id)
    }

    /// 私人 FM"不再播放": /api/radio/trash/add
    fn trash_fm_song(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::trash_fm_song(self, song_id)
    }

    /// 历史日推日期列表: {code, data:{dates:[...], noHistoryMessage, purchaseUrl}}
    /// 非 VIP 时 dates 为空并给一句提示, 当成"没有历史"处理.
    fn history_recommend_dates(&self) -> BoxFuture<'_, ProviderResult<Vec<String>>> {
        NeteaseProvider::history_recommend_dates(self)
    }

    /// 某个日期的历史日推: {code, data:{songs:[...]}}
    fn history_recommend_songs<'a>(
        &'a self,
        date: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        NeteaseProvider::history_recommend_songs(self, date)
    }

    /// 红心/取消红心. 网易云用 HTTP 200 里的 code 表达结果(200 = 成功)
    fn set_like<'a>(&'a self, track: TrackId, liked: bool) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::set_like(self, track, liked)
    }

    /// 我的歌单(含"我喜欢的音乐")
    fn user_playlists<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::user_playlists(self)
    }

    /// 歌单曲目(vendor 内部先取 trackIds 再批量取详情)
    fn playlist_songs<'a>(&'a self, playlist_id: u64) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        NeteaseProvider::playlist_songs(self, playlist_id)
    }

    /// 批量曲目详情(红心列表要靠它补全元数据)
    fn songs_detail<'a>(&'a self, ids: &'a str) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        NeteaseProvider::songs_detail(self, ids)
    }

    /// 每日推荐歌曲(原版每日推荐, 匿名也能取到; 登录后是个性化推荐)
    fn daily_recommend_songs(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        NeteaseProvider::daily_recommend_songs(self)
    }

    /// 每日推荐歌单(需要登录; 未登录时网易云返回 301)
    fn daily_recommend_playlists(&self) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::daily_recommend_playlists(self)
    }

    /// 心动模式: 以当前曲目为种子, 在指定歌单里续播.
    /// 网易云要求 pid 必须是一个**可用的歌单**(实测 pid=0 返回 400 歌单不存在);
    /// 用户从搜索/单曲直接进入时没有歌单上下文, 这里自动回落到"我喜欢的音乐".
    fn intelligence_songs(
        &self,
        song_id: u64,
        playlist_id: u64,
        count: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        NeteaseProvider::intelligence_songs(self, song_id, playlist_id, count)
    }

    /// 搜索建议(输入联想). 匿名可用.
    fn search_suggest<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<SuggestItem>>> {
        NeteaseProvider::search_suggest(self, keywords)
    }

    /// 联想下拉的纯关键词候选(type=mobile 分支, /api/search/suggest/keyword).
    fn search_suggest_keywords<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<String>>> {
        NeteaseProvider::search_suggest_keywords(self, keywords)
    }

    /// 精确实体改写(/api/search/suggest/multimatch). vendor 内部固定发 {type:1, s:<kw>}.
    fn search_exact<'a>(&'a self, keywords: &'a str) -> BoxFuture<'a, ProviderResult<SearchExact>> {
        NeteaseProvider::search_exact(self, keywords)
    }

    /// 最近播放(服务端记录, 需要登录)
    fn recent_songs(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        NeteaseProvider::recent_songs(self, limit)
    }

    /// 最近播放-专辑(服务端记录, 需要登录)
    fn recent_albums(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        NeteaseProvider::recent_albums(self, limit)
    }

    /// 最近播放-歌单(服务端记录, 需要登录)
    fn recent_playlists(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::recent_playlists(self, limit)
    }

    /// 最近播放-播客/电台(服务端记录, 需要登录)
    fn recent_podcasts(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        NeteaseProvider::recent_podcasts(self, limit)
    }

    /// 云贝签到状态(需要登录)
    fn signin_status(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        NeteaseProvider::signin_status(self)
    }

    /// 签到(需要登录). 已签到时不重复请求(接口会回 "重复签到" 错误).
    fn sign_in(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        NeteaseProvider::sign_in(self)
    }

    /// 黑胶会员总览(需要登录). 四个子接口并行, 单个失败只丢对应字段.
    fn vip_overview(&self) -> BoxFuture<'_, ProviderResult<VipOverview>> {
        NeteaseProvider::vip_overview(self)
    }

    /// 账号听歌等级(/api/user/level, weapi, body {}).
    fn user_level(&self) -> BoxFuture<'_, ProviderResult<UserLevel>> {
        NeteaseProvider::user_level(self)
    }

    /// 账号勋章墙(/api/medal/user/page, eapi, body **必须带 uid**).
    ///
    /// uid 优先取等级接口里服务端回的 data.userId(不依赖本地缓存的 profile),
    /// 拿不到再回退 session.profile.user_id。实测空 uid 时服务端回 code=499.
    fn user_medals(&self) -> BoxFuture<'_, ProviderResult<MedalWall>> {
        NeteaseProvider::user_medals(self)
    }

    /// 删除自己的评论(需要登录)
    fn delete_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::delete_comment(self, thread_id, comment_id)
    }

    /// 歌曲百科: 曲风/语种/BPM/获奖成就, 压成 label/value 对.
    ///
    /// vendor 的 song_wiki_summary 走 eapi: 桌面身份(PC UA + os=pc)实测正常,
    /// 安卓身份(官方安卓 UA + os=android)实测回 code=432 Unknown error;
    /// 同一个 path 换 weapi 通道两边都正常, 所以先用 weapi, 失败再退回 vendor 的 eapi 实现。
    fn song_wiki(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<Vec<WikiFact>>> {
        NeteaseProvider::song_wiki(self, song_id)
    }

    /// 新歌速递(按地区). area → areaId 是服务端的枚举: 0 全部 / 7 华语 / 8 日语 / 16 韩语 / 96 欧美
    fn new_songs_by_area<'a>(
        &'a self,
        area: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        NeteaseProvider::new_songs_by_area(self, area, limit)
    }

    /// 新碟上架(按地区). `top_album` 的 weekData 在部分地区为空, monthData 才有货,
    /// 所以两边合并(按 id 去重)再截断。
    fn new_albums_by_area<'a>(
        &'a self,
        area: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<AlbumItem>>> {
        NeteaseProvider::new_albums_by_area(self, area, limit)
    }

    /// 热门歌手榜
    fn hot_artists(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<HotArtist>>> {
        NeteaseProvider::hot_artists(self, limit, offset)
    }

    /// 未读消息计数(需登录)
    fn message_counts(&self) -> BoxFuture<'_, ProviderResult<MessageCounts>> {
        NeteaseProvider::message_counts(self)
    }

    /// 私信会话列表(需登录)
    fn private_sessions(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateSession>>> {
        NeteaseProvider::private_sessions(self, limit, offset)
    }

    /// 私信历史(需登录)
    fn private_history(
        &self,
        user_id: u64,
        limit: u32,
        before_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateMessage>>> {
        NeteaseProvider::private_history(self, user_id, limit, before_ms)
    }

    /// 通知(需登录)
    fn message_notices(
        &self,
        limit: u32,
        last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        NeteaseProvider::message_notices(self, limit, last_time_ms)
    }

    /// 评论/回复消息(需登录)
    fn comment_messages(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        NeteaseProvider::comment_messages(self, limit)
    }

    /// 消息中心"@我"(需登录). vendor 的 msg_forwards 只发 offset/limit, 没有
    /// lasttime 游标 → last_time_ms 保留参数形状, 当前恒取最新一页.
    fn forward_messages(
        &self,
        limit: u32,
        _last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<ForwardItem>>> {
        NeteaseProvider::forward_messages(self, limit, _last_time_ms)
    }

    /// 最近联系人(需登录). vendor 的 msg_recentcontact 发空 body, limit 只能客户端截断.
    fn recent_contacts(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<RecentContact>>> {
        NeteaseProvider::recent_contacts(self, limit)
    }

    /// 专辑详情(封面预览 + 曲目)
    fn album_detail(&self, album_id: u64) -> BoxFuture<'_, ProviderResult<AlbumDetail>> {
        NeteaseProvider::album_detail(self, album_id)
    }

    /// 热门播客/电台
    fn podcast_hot(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        NeteaseProvider::podcast_hot(self, limit)
    }

    /// 某个播客的节目列表
    fn podcast_programs(
        &self,
        radio_id: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastProgram>>> {
        NeteaseProvider::podcast_programs(self, radio_id, limit, offset)
    }

    /// 单个节目详情
    fn podcast_program(&self, program_id: u64) -> BoxFuture<'_, ProviderResult<PodcastProgram>> {
        NeteaseProvider::podcast_program(self, program_id)
    }

    /// 歌单详情(歌单页头部信息)
    fn playlist_detail(&self, playlist_id: u64) -> BoxFuture<'_, ProviderResult<PlaylistDetail>> {
        NeteaseProvider::playlist_detail(self, playlist_id)
    }

    /// 收藏/取消收藏歌单(需登录; t=1 收藏, t=2 取消)
    fn set_playlist_subscribed(
        &self,
        playlist_id: u64,
        subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::set_playlist_subscribed(self, playlist_id, subscribed)
    }

    /// 评论列表: vendor 按 kind 分派到不同资源端点(song/playlist/album/podcast)
    fn comments<'a>(
        &'a self,
        kind: &'a str,
        id: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        NeteaseProvider::comments(self, kind, id, limit, offset)
    }

    /// 精彩评论(单独接口). threadId 反解出 vendor 的 type + id, 再按资源查。
    /// 动态(A_EV_2_)的 id 段是 `eventId_userId`, 热门接口只认 eventId, 这里不支持。
    fn hot_comments<'a>(
        &'a self,
        thread_id: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        NeteaseProvider::hot_comments(self, thread_id, limit, offset)
    }

    /// 评论统计(实测: vendor comment_info_list = /api/resource/commentInfo/list, weapi).
    /// 入参是 type(资源类型数字) + ids(逗号分隔), **不是 threadId** —— 传 threadId 只会拿到空数组;
    /// 这里用 split_thread_id 把 threadId 反解成 (type, id). 动态(A_EV_2_)的 id 段是
    /// `eventId_userId`, 该接口不认, 直接 unsupported.
    fn comment_stats<'a>(
        &'a self,
        thread_id: &'a str,
    ) -> BoxFuture<'a, ProviderResult<CommentStats>> {
        NeteaseProvider::comment_stats(self, thread_id)
    }

    /// 分享资源到动态(需登录). kind 直接透传接口 type(song/playlist/album/podcast)
    fn share_resource<'a>(
        &'a self,
        kind: &'a str,
        id: u64,
        msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::share_resource(self, kind, id, msg)
    }

    /// 已购数字专辑(digitalAlbum/purchased, weapi). 实测顶层是 paidAlbums + total.
    fn digital_album_purchased<'a>(
        &'a self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<DigitalAlbumPurchased>> {
        NeteaseProvider::digital_album_purchased(self, limit, offset)
    }

    /// 已购单曲(song/purchased = /api/single/mybought/song/list, weapi).
    fn song_purchased<'a>(
        &'a self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<SongPurchasedPage>> {
        NeteaseProvider::song_purchased(self, limit, offset)
    }

    /// 数字专辑详情(vipmall/albumproduct/detail, weapi, 入参 id).
    fn digital_album_detail(
        &self,
        album_id: u64,
    ) -> BoxFuture<'_, ProviderResult<DigitalAlbumDetail>> {
        NeteaseProvider::digital_album_detail(self, album_id)
    }

    /// 数字专辑销量(vipmall/albumproduct/album/query/sales, weapi, 入参键 albumIds).
    fn digital_album_sales<'a>(
        &'a self,
        album_ids: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<DigitalAlbumSalesEntry>>> {
        NeteaseProvider::digital_album_sales(self, album_ids)
    }

    // ---- 电台发现(只读; 全部匿名可用) ----

    /// 电台发现首页: dj_catelist(分类) + dj_category_recommend(各分类精选), 并发拉取.
    fn radio_explore_home(&self) -> BoxFuture<'_, ProviderResult<RadioExploreHome>> {
        NeteaseProvider::radio_explore_home(self)
    }

    /// 某分类推荐电台(dj_recommend_type). cate_id=0 服务端返回空 djRadios, 原样透传空列表.
    fn radio_recommend<'a>(
        &'a self,
        cate_id: u64,
    ) -> BoxFuture<'a, ProviderResult<Vec<PodcastRadio>>> {
        NeteaseProvider::radio_recommend(self, cate_id)
    }

    /// 电台榜单(kind: hot/new/pay/hours/newcomer/popular/program).
    fn radio_toplist<'a>(&'a self, kind: &'a str) -> BoxFuture<'a, ProviderResult<RadioToplist>> {
        NeteaseProvider::radio_toplist(self, kind)
    }

    /// 电台订阅者列表(dj_subscriber; 游标 time=-1 表示最新一页).
    fn radio_subscribers<'a>(
        &'a self,
        radio_id: u64,
        limit: u32,
        time_ms: Option<u64>,
    ) -> BoxFuture<'a, ProviderResult<RadioSubscriberPage>> {
        NeteaseProvider::radio_subscribers(self, radio_id, limit, time_ms)
    }

    /// 播客/电台详情
    fn podcast_radio(&self, radio_id: u64) -> BoxFuture<'_, ProviderResult<PodcastRadio>> {
        NeteaseProvider::podcast_radio(self, radio_id)
    }

    /// 综合搜索: 单曲/歌手/专辑/歌单/播客 五个板块并发拉取.
    /// 单曲失败直接报错(主板块); 其余板块失败只留空, 不让一个类型拖垮整页.
    fn search_all<'a>(
        &'a self,
        query: &'a SearchQuery,
    ) -> BoxFuture<'a, ProviderResult<SearchBundle>> {
        NeteaseProvider::search_all(self, query)
    }

    /// 歌手详情: 头部资料 + 热门歌曲 + 专辑. 专辑接口失败只影响专辑板块.
    fn artist_detail(&self, artist_id: u64) -> BoxFuture<'_, ProviderResult<ArtistDetail>> {
        NeteaseProvider::artist_detail(self, artist_id)
    }

    /// 个人主页资料(背景图/头像/签名/关注数). 需要登录.
    fn profile_detail(&self) -> BoxFuture<'_, ProviderResult<ProfileDetail>> {
        NeteaseProvider::profile_detail(self)
    }

    /// 任意用户的公开资料(user/detail, 不需要登录)
    fn user_profile<'a>(&'a self, uid: u64) -> BoxFuture<'a, ProviderResult<ProfileDetail>> {
        NeteaseProvider::user_profile(self, uid)
    }

    /// 任意用户的公开歌单(user/playlist). 注意: 未登录时服务端只回公开歌单,
    /// 且**不含**该用户的"我喜欢的音乐"(它是私密歌单).
    fn user_playlists_of<'a>(
        &'a self,
        uid: u64,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        NeteaseProvider::user_playlists_of(self, uid, limit)
    }

    /// 收藏曲目到歌单(需要登录)
    fn add_to_playlist(
        &self,
        playlist_id: u64,
        track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        NeteaseProvider::add_to_playlist(self, playlist_id, track)
    }

    /// "我喜欢的音乐"曲目, 按收藏时间从新到旧.
    /// likelist 的 id 顺序不可靠(实测体感随机); 歌单详情的 trackIds[].at 才是加入时间(ms).
    fn liked_songs_ordered(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        NeteaseProvider::liked_songs_ordered(self)
    }

    /// 搜索热词榜. type=1111 返回 result.hots(按热度排序), 没有特权/登录要求.
    fn hot_search(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchTerm>>> {
        NeteaseProvider::hot_search(self)
    }

    /// 热搜榜详情(/api/hotsearchlist/get, weapi, 无参数): 带 score + 榜位.
    fn hot_search_detail(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchDetailItem>>> {
        NeteaseProvider::hot_search_detail(self)
    }

    /// 默认/推荐搜索词("猜你想搜")
    fn default_search(&self) -> BoxFuture<'_, ProviderResult<Option<DefaultSearch>>> {
        NeteaseProvider::default_search(self)
    }

    /// 私人 FM: 登录后按口味连续推歌(/api/v1/radio/get), 匿名会返回 301.
    fn personal_fm(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        NeteaseProvider::personal_fm(self, limit)
    }

    /// 已订阅的播客/电台
    fn subscribed_podcasts(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        NeteaseProvider::subscribed_podcasts(self, limit)
    }

    /// 关注的艺人
    fn subscribed_artists(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        NeteaseProvider::subscribed_artists(self, limit)
    }

    /// 关注动态: /api/v1/event/get 返回"我关注的人"的动态(含艺人发布).
    fn feed_events(
        &self,
        limit: u32,
        last_time: i64,
    ) -> BoxFuture<'_, ProviderResult<Vec<FeedEvent>>> {
        NeteaseProvider::feed_events(self, limit, last_time)
    }

    /// 动态评论: vendor 走 /api/v1/resource/comments/<threadId>.
    fn event_comments<'a>(
        &'a self,
        thread_id: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        NeteaseProvider::event_comments(self, thread_id, limit, offset)
    }

    /// 动态点赞: vendor resource_like, type=6 表示动态, 传 threadId.
    fn like_event<'a>(
        &'a self,
        thread_id: &'a str,
        liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::like_event(self, thread_id, liked)
    }

    /// 转发动态: /api/event/forward
    fn forward_event<'a>(
        &'a self,
        event_id: u64,
        user_id: u64,
        msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        NeteaseProvider::forward_event(self, event_id, user_id, msg)
    }

    /// 当前登录账号资料(用于多账号记忆: 登录成功后记住 uid/昵称)
    fn profile<'a>(&'a self) -> BoxFuture<'a, ProviderResult<ncm_domain::Profile>> {
        NeteaseProvider::profile(self)
    }

    /// 扫码登录 ①: 申请二维码 key(官方网页登录页同一通道, weapi)
    fn login_qr_create<'a>(&'a self) -> BoxFuture<'a, ProviderResult<QrLoginKey>> {
        NeteaseProvider::login_qr_create(self)
    }

    /// 扫码登录 ②: 轮询. 803 时的登录凭据在 Set-Cookie 里(不在 body).
    fn login_qr_check<'a>(&'a self, key: &'a str) -> BoxFuture<'a, ProviderResult<QrLoginOutcome>> {
        NeteaseProvider::login_qr_check(self, key)
    }

    /// 手机号登录 ①: 发短信验证码(网页登录通道 weapi, 与扫码同一族).
    ///
    /// 不用 App 原生登录族(eapi): 那条路在交互式风控下回 8821, 而网页登录是已知稳路径.
    fn login_sms_send<'a>(
        &'a self,
        phone: &'a str,
        country_code: &'a str,
    ) -> BoxFuture<'a, ProviderResult<SmsCodeSent>> {
        NeteaseProvider::login_sms_send(self, phone, country_code)
    }

    /// 手机号登录 ②: 校验验证码. 成功时凭据在 Set-Cookie(与扫码 803 一样不在 body).
    fn login_sms_verify<'a>(
        &'a self,
        phone: &'a str,
        code: &'a str,
        country_code: &'a str,
    ) -> BoxFuture<'a, ProviderResult<PhoneLoginOutcome>> {
        NeteaseProvider::login_sms_verify(self, phone, code, country_code)
    }
}
