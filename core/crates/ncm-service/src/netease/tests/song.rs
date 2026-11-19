//! 歌曲/流地址/歌词/推荐/风格/榜单相关单测.

use crate::netease::*;
use serde_json::json;

/// 歌曲百科: 只取 SONG_PLAY_ABOUT_SONG_BASIC 块, 富文本压成 "a / b"
#[test]
fn song_wiki_flattens_basic_block() {
    let body = json!({
        "code": 200,
        "data": {"blocks": [
            {"code": "SONG_PLAY_ABOUT_MUSIC_MEMORY", "creatives": []},
            {"code": "SONG_PLAY_ABOUT_SONG_BASIC", "creatives": [
                {
                    "creativeType": "songTag",
                    "uiElement": {"mainTitle": {"title": "曲风"}},
                    "resources": [
                        {"uiElement": {"mainTitle": {"title": "流行-华语流行"}}},
                        {"uiElement": {"mainTitle": {"title": "原声带-动画片原声"}}}
                    ]
                },
                {
                    "creativeType": "language",
                    "uiElement": {
                        "mainTitle": {"title": "语种"},
                        "textLinks": [{"text": "国语"}]
                    },
                    "resources": []
                },
                {
                    "creativeType": "songAward",
                    "uiElement": {"mainTitle": {"title": "获奖成就"}},
                    "resources": [
                        {"uiElement": {
                            "mainTitle": {"title": "第30届东方风云榜"},
                            "subTitles": [{"title": "获"}, {"title": "动感101年度金曲"}]
                        }}
                    ]
                },
                {"creativeType": "bpm", "uiElement": {"mainTitle": {"title": "BPM"}}, "resources": []}
            ]}
        ]}
    });
    let facts = parse_song_wiki(&body);
    assert_eq!(facts.len(), 3, "空值的 BPM 不出现; 其它三个块不算");
    assert_eq!(facts[0].label, "曲风");
    assert_eq!(facts[0].value, "流行-华语流行 / 原声带-动画片原声");
    assert_eq!(facts[1].value, "国语");
    assert_eq!(facts[2].value, "第30届东方风云榜 获 动感101年度金曲");
}

/// 无版权判定: 搜索响应把 privilege 内嵌在 song 上, 详情响应是独立 privileges[],
/// 两种都要能标出 playable=false(st=-200).
#[test]
fn unlicensed_tracks_are_marked_unplayable() {
    let search = json!({
        "code": 200,
        "result": {
            "songCount": 1,
            "hasMore": false,
            "songs": [{
                "id": 186016,
                "name": "晴天",
                "ar": [{"id": 6452, "name": "周杰伦"}],
                "al": {"id": 1, "name": "叶惠美"},
                "dt": 269000,
                "fee": 0,
                "privilege": {"id": 186016, "st": -200, "pl": 0, "dl": 0}
            }]
        }
    });
    let page = parse_search(&search).unwrap();
    assert!(!page.songs[0].playable, "st=-200 应判为不可播");

    let detail = json!({
        "code": 200,
        "songs": [
            {"id": 186016, "name": "晴天", "ar": [], "dt": 1, "fee": 0},
            {"id": 347230, "name": "海阔天空", "ar": [], "dt": 1, "fee": 1}
        ],
        "privileges": [
            {"id": 186016, "st": -200, "pl": 0, "dl": 0},
            {"id": 347230, "st": 0, "pl": 999000, "dl": 999000}
        ]
    });
    let songs = parse_song_list(&detail);
    assert_eq!(songs.len(), 2);
    assert!(!songs[0].playable);
    assert!(songs[1].playable);
}

#[test]
fn stream_mapping_and_expiry() {
    let body = json!({
        "code": 200,
        "data": [{"id": 1, "url": "http://m/1.flac", "br": 999000, "size": 12345, "expi": 1200, "code": 200}]
    });
    let s = parse_stream(&body, "exhigh").unwrap();
    assert!(s.is_playable());
    assert_eq!(s.br, Some(999000));
    assert!(s.expire_at.unwrap() > 0);
}

/// 试听片段: 实测 19292984 (Love Story, 付费专辑) 匿名取链的响应形状 ——
/// `size 721023 @128008` ≈ 45s, `freeTrialInfo{start:0,end:45}` 是关键信号。
/// 这段 fixture 是照着真实响应裁剪的, 不联网。
#[test]
fn stream_trial_fragment_is_flagged() {
    let body = json!({
        "code": 200,
        "data": [{
            "id": 19292984,
            "url": "https://m702.music.126.net/20261118/x/y.mp3",
            "br": 128008,
            "size": 721023,
            "md5": "0d5c1e4f2a7b9c0d1e2f3a4b5c6d7e8f",
            "code": 200,
            "expi": 1200,
            "type": "mp3",
            "fee": 1,
            "payed": 0,
            "flag": 4,
            "time": 297000,
            "level": "standard",
            "encodeType": "mp3",
            "freeTrialInfo": {"start": 0, "end": 45},
            "freeTrialPrivilege": {"resConsumable": false, "userConsumable": false, "listenType": 1}
        }]
    });
    let s = parse_stream(&body, "lossless").unwrap();
    assert!(s.is_playable());
    assert!(s.is_trial, "freeTrialInfo 非空 ⇒ 试听片段");
    assert_eq!(s.trial_start_ms, Some(0));
    assert_eq!(s.trial_end_ms, Some(45_000));
    assert_eq!(s.trial_len_ms(), Some(45_000));
    // 请求 lossless, 服务端如实回了 standard: quality 保请求档位, actual_level 说真话
    assert_eq!(s.quality, "lossless");
    assert_eq!(s.actual_level.as_deref(), Some("standard"));
    assert_eq!(s.effective_level(), "standard");
    assert_eq!(s.is_degraded(), Some(true));
    assert_eq!(s.format.as_deref(), Some("mp3"));
    assert_eq!(s.md5.as_deref(), Some("0d5c1e4f2a7b9c0d1e2f3a4b5c6d7e8f"));
    assert_eq!(s.duration_ms, Some(297_000));
}

/// 静默降级(不是试听): 匿名请求 lossless 被回 exhigh/320k mp3, code 仍是 200。
/// 我们不许假装无损 —— actual_level 必须是 exhigh。
#[test]
fn stream_degraded_level_is_reported() {
    let body = json!({
        "code": 200,
        "data": [{
            "id": 33894312,
            "url": "https://m8.music.126.net/20261118/a/b.mp3",
            "br": 320000,
            "size": 3000123,
            "md5": "aabbccddeeff00112233445566778899",
            "code": 200,
            "expi": 1200,
            "type": "mp3",
            "time": 50000,
            "level": "exhigh",
            "freeTrialInfo": null
        }]
    });
    let s = parse_stream(&body, "lossless").unwrap();
    assert!(!s.is_trial);
    assert_eq!(s.trial_len_ms(), None);
    assert_eq!(s.actual_level.as_deref(), Some("exhigh"));
    assert_eq!(s.is_degraded(), Some(true));
    assert_eq!(s.format.as_deref(), Some("mp3"));
}

/// 正常整曲(无免费试听, 档位与请求一致): 只有一个 is_trial=false 的普通分支。
#[test]
fn stream_full_track_not_trial() {
    let body = json!({
        "code": 200,
        "data": [{
            "id": 1,
            "url": "https://m7.music.126.net/20261118/c/d.flac",
            "br": 999000,
            "size": 30012345,
            "md5": "11223344556677889900aabbccddeeff",
            "code": 200,
            "expi": 1200,
            "type": "flac",
            "time": 240000,
            "level": "lossless"
        }]
    });
    let s = parse_stream(&body, "lossless").unwrap();
    assert!(!s.is_trial);
    assert_eq!(s.actual_level.as_deref(), Some("lossless"));
    assert_eq!(s.is_degraded(), Some(false));
    assert_eq!(s.format.as_deref(), Some("flac"));
    assert_eq!(s.duration_ms, Some(240_000));
}

/// freeTrialInfo 的毫秒形状(有的接口直接给 ms)也要落在 trial_*_ms 里,
/// 且 end <= start / 空对象都当作"不是试听"。
#[test]
fn stream_trial_unit_and_malformed() {
    let ms_shape = json!({
        "code": 200,
        "data": [{"id": 1, "url": "https://m/1.mp3", "code": 200,
                  "freeTrialInfo": {"start": 30000, "end": 75000}}]
    });
    let s = parse_stream(&ms_shape, "standard").unwrap();
    assert!(s.is_trial);
    assert_eq!(s.trial_len_ms(), Some(45_000));

    let empty = json!({
        "code": 200,
        "data": [{"id": 1, "url": "https://m/1.mp3", "code": 200, "freeTrialInfo": {}}]
    });
    assert!(!parse_stream(&empty, "standard").unwrap().is_trial);

    let reversed = json!({
        "code": 200,
        "data": [{"id": 1, "url": "https://m/1.mp3", "code": 200,
                  "freeTrialInfo": {"start": 45, "end": 0}}]
    });
    assert!(!parse_stream(&reversed, "standard").unwrap().is_trial);
}

#[test]
fn stream_vip_without_login_has_no_url() {
    let body = json!({"code": 200, "data": [{"id": 1, "url": null, "code": 200, "expi": 1200}]});
    let s = parse_stream(&body, "exhigh").unwrap();
    assert!(!s.is_playable());
}

#[test]
fn lyric_mapping() {
    let body =
        json!({"code": 200, "lrc": {"lyric": "[00:00.00]hi"}, "tlyric": {"lyric": "[00:00.00]嗨"}});
    let l = parse_lyric(&body).unwrap();
    assert_eq!(l.lrc.as_deref(), Some("[00:00.00]hi"));
    assert_eq!(l.translated.as_deref(), Some("[00:00.00]嗨"));
    assert!(l.romaji.is_none());
}

#[test]
fn word_lyric_real_shape() {
    // 实测 id=5264842 的 yrc 片段(署名 JSON 行 + 逐字行混排)
    let yrc = concat!(
            "{\"t\":0,\"c\":[{\"tx\":\"作词: \"},{\"tx\":\"席慕容\"}]}",
            "\n[21960,7590](21960,470,0)让(22430,2610,0)我(25400,280,0)与(25680,640,0)你(26320,1940,0)握(28290,750,0)别",
        );
    let body = json!({"code": 200, "yrc": {"version": 7, "lyric": yrc}});
    let wl = parse_word_lyric_body(&body).unwrap();
    assert_eq!(wl.lines.len(), 2);
    assert!(wl.has_word_timing);
    assert_eq!(wl.lines[1].words.len(), 6);
    assert_eq!(wl.lines[0].words[0].text, "作词: 席慕容");
}

#[test]
fn word_lyric_missing_yrc_is_empty() {
    // 老歌(晴天)实测: 只有 lrc/tlyric, 无 yrc
    let body = json!({"code": 200, "lrc": {"version": 70, "lyric": "[00:01.00]hi"}, "tlyric": {"lyric": ""}});
    let wl = parse_word_lyric_body(&body).unwrap();
    assert!(wl.is_empty());
}

#[test]
fn word_lyric_translation_falls_back_to_tlyric() {
    let body = json!({
        "code": 200,
        "yrc": {"version": 1, "lyric": "[1000,500](1000,500,0)hello\n[2000,500](2000,500,0)world"},
        "ytlrc": {"version": 0, "lyric": ""},
        "tlyric": {"version": 24, "lyric": "[00:01.00]你好"}
    });
    let wl = parse_word_lyric_body(&body).unwrap();
    assert_eq!(wl.translation_lines[0].as_deref(), Some("你好"));
    assert_eq!(wl.translation_lines[1], None);
}

#[test]
fn daily_recommend_mapping() {
    let body = json!({
        "code": 200,
        "data": {
            "dailySongs": [
                {"id": 1, "name": "A", "ar": [{"name": "x"}], "al": {"id": 9, "name": "al", "picUrl": "http://p/a.jpg"}, "dt": 1000, "fee": 0},
                {"id": 2, "name": "B", "ar": [{"name": "y"}], "al": {"id": 10, "name": "al2"}, "dt": 2000, "fee": 1}
            ],
            "privileges": [{"id": 2, "st": -200, "pl": 0}]
        }
    });
    let songs = parse_recommend_songs(&body);
    assert_eq!(songs.len(), 2);
    assert!(songs[0].playable);
    assert!(!songs[1].playable);
    assert_eq!(songs[0].album_id(), 9);
    assert_eq!(songs[0].cover_url().as_deref(), Some("http://p/a.jpg"));
}

#[test]
fn intelligence_mapping() {
    // 实测形态: data[].songInfo 里才是完整 song(还带内嵌 privilege)
    let body = json!({"code": 200, "data": [
        {
            "alg": "x", "id": 3, "recommended": true,
            "songInfo": {
                "id": 3, "name": "C", "ar": [{"name": "z"}],
                "al": {"id": 1, "name": "a", "picUrl": "http://p/c.jpg"}, "dt": 500,
                "privilege": {"id": 3, "st": -200, "pl": 0}
            }
        }
    ]});
    let songs = parse_intelligence(&body);
    assert_eq!(songs.len(), 1);
    assert_eq!(songs[0].name, "C");
    assert_eq!(songs[0].album_id(), 1);
    assert!(!songs[0].playable);

    // 兼容 data 直接是 song 数组
    let plain = json!({"code": 200, "data": [
        {"id": 4, "name": "D", "ar": [], "al": {"id": 1, "name": "a"}, "dt": 1}
    ]});
    assert_eq!(parse_intelligence(&plain).len(), 1);
    // 兼容 data.songs 变体
    let alt = json!({"code": 200, "data": {"songs": [
        {"id": 5, "name": "E", "ar": [], "al": {"id": 1, "name": "a"}, "dt": 1}
    ]}});
    assert_eq!(parse_intelligence(&alt).len(), 1);
}

#[test]
fn recent_mapping() {
    let body = json!({"code": 200, "data": {"list": [
        {"playCount": 3, "data": {"id": 7, "name": "R", "ar": [{"name": "q"}], "al": {"id": 2, "name": "a"}, "dt": 1000}}
    ]}});
    let songs = parse_recent(&body);
    assert_eq!(songs.len(), 1);
    assert_eq!(songs[0].id.0, 7);
}

#[test]
fn fm_songs_mapping() {
    let body = json!({"code": 200, "data": [
        {"id": 11, "name": "FM 曲", "ar": [{"name": "A"}], "al": {"id": 3, "name": "al"}, "dt": 1000, "fee": 0}
    ]});
    let songs = parse_fm_songs(&body);
    assert_eq!(songs.len(), 1);
    assert_eq!(songs[0].id.0, 11);
    assert_eq!(songs[0].artist_line(), "A");
}

#[test]
fn play_ranking_mapping() {
    // 真实响应形状(2026-11-19 实测 uid=1822714196): 接口已按播放次数从多到少
    // 排好, score 只是 floor(playCount/max*100) 的归一化分值(283→100, 152→53),
    // 不是名次, 所以客户端不再重排。
    let body = json!({
        "code": 200,
        "allData": [
            {"playCount": 283, "score": 100, "song": {"id": 1, "name": "A", "ar": [{"id": 7, "name": "x"}], "dt": 1000}},
            {"playCount": 152, "score": 53, "song": {"id": 2, "name": "B", "ar": [{"name": "y"}], "dt": 2000}},
            {"playCount": 145, "score": 51, "song": {"id": 3, "name": "C", "ar": [], "dt": 3000}}
        ]
    });
    let all = parse_play_ranking(&body, RankingPeriod::All);
    assert_eq!(all.len(), 3);
    // 顺序 = 接口顺序(1,2,3), 不按 score 重排
    let ids: Vec<u64> = all.iter().map(|e| e.song.id.0).collect();
    assert_eq!(ids, vec![1, 2, 3]);
    assert_eq!(all[0].play_count, 283);
    assert_eq!(all[0].score, 100);
    assert_eq!(all[1].play_count, 152);
    assert_eq!(all[1].score, 53);
}

#[test]
fn play_ranking_week_shapes() {
    // 上游当周只回 code + 空 weekData(2026-11-19 实测: type=1 对多个账号都是
    // {"code":200,"weekData":[]}, 且不返回 allData) ⇒ 解析成空列表, 不是错误
    let empty = json!({"code": 200, "weekData": []});
    assert!(parse_play_ranking(&empty, RankingPeriod::Week).is_empty());

    // 缺 weekData 键(异常/降级形状)时也回空, 且**不能**串到 allData 去
    let missing = json!({
        "code": 200,
        "allData": [{"playCount": 9, "score": 100, "song": {"id": 9, "name": "x", "ar": [], "dt": 1}}]
    });
    assert!(parse_play_ranking(&missing, RankingPeriod::Week).is_empty());

    // 空 body(无 code)同样只是空
    assert!(parse_play_ranking(&json!({}), RankingPeriod::Week).is_empty());

    // 有当周数据时: playCount 是**本周**次数, 原样透传
    let week = json!({"code": 200, "weekData": [
        {"playCount": 7, "score": 100, "song": {"id": 3, "name": "C", "ar": [], "dt": 3000}},
        {"playCount": 5, "score": 71, "song": {"id": 4, "name": "D", "ar": [], "dt": 4000}}
    ]});
    let list = parse_play_ranking(&week, RankingPeriod::Week);
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].play_count, 7);
    assert_eq!(list[1].song.name, "D");
}

#[test]
fn style_preference_mapping() {
    // 登录态: data 下的 tagPreferenceVos / tags 两种字段都认
    let body = json!({"code": 200, "data": {
        "tagPreferenceVos": [{"tagId": 1009, "tagName": "粤语流行"}],
        "tags": [
            {"tagId": "1020", "tagName": "华语流行", "picUrl": "http://p/a.jpg"},
            {"tagId": 1021, "tagName": "相对图", "picUrl": "yyimgs/abc==/123"}
        ]
    }});
    let tags = parse_style_preference(&body);
    assert_eq!(tags.len(), 3);
    // 相对路径(yyimgs/<hash>/<id>)要补成 CDN 绝对地址: 丢掉的话推荐页永远是占位图
    assert_eq!(
        tags[2].cover_url.as_deref(),
        Some("https://p1.music.126.net/abc==/123.jpg")
    );

    assert_eq!(tags[0].id, "1009");
    assert_eq!(tags[1].name, "华语流行");
    assert_eq!(tags[1].cover_url.as_deref(), Some("http://p/a.jpg"));

    // 空偏好(未登录)返回空, 由调用方退化到通用曲风表
    let empty = json!({"code": 200, "data": {"tagPreferenceVos": [], "tags": []}});
    assert!(parse_style_preference(&empty).is_empty());
}

#[test]
fn style_list_flattens_children() {
    let body = json!({"code": 200, "data": [
        {"tagId": 1, "tagName": "语种", "childrenTags": [
            {"tagId": 1009, "tagName": "粤语流行"},
            {"tagId": 1020, "tagName": "华语流行"}
        ]},
        {"tagId": 2, "tagName": "风格"}
    ]});
    let tags = parse_style_list(&body, 10);
    assert_eq!(tags.len(), 3);
    assert_eq!(tags[0].id, "1009");
    assert_eq!(tags[2].name, "风格");
    // limit 生效
    assert_eq!(parse_style_list(&body, 1).len(), 1);
}

#[test]
fn style_songs_and_playlists_mapping() {
    let songs_body = json!({"code": 200, "data": {
        "songs": [{"id": 11, "name": "S", "ar": [{"name": "x"}], "dt": 1000, "fee": 1}],
        "page": {"total": 1}
    }});
    let songs = parse_style_songs(&songs_body);
    assert_eq!(songs.len(), 1);
    assert_eq!(songs[0].name, "S");

    let pl_body = json!({"code": 200, "data": {
        "playlist": [{"id": 22, "name": "P", "cover": "http://p/c.jpg", "songCount": 200}],
        "page": {"total": 1}
    }});
    let lists = parse_style_playlists(&pl_body);
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].track_count, 200);
    assert_eq!(lists[0].cover_url.as_deref(), Some("http://p/c.jpg"));
}

#[test]
fn history_dates_mapping() {
    // 字符串数组
    let a = json!({"code": 200, "data": {"dates": ["2024-06-20", "2024-06-19"]}});
    assert_eq!(parse_history_dates(&a), vec!["2024-06-20", "2024-06-19"]);
    // 对象数组
    let b = json!({"code": 200, "data": {"dates": [
        {"date": "2024-06-18"}, {"day": "2024-06-17"}, {"x": 1}
    ]}});
    assert_eq!(parse_history_dates(&b), vec!["2024-06-18", "2024-06-17"]);
    // 非 VIP: 空数组
    let c = json!({"code": 200, "data": {"dates": [], "noHistoryMessage": "黑胶VIP可查看"}});
    assert!(parse_history_dates(&c).is_empty());
}

#[test]
fn capabilities_include_personal_fm() {
    // 漏掉这项时 UI 会报 "no provider supports personalFm"(模拟器实测踩过)
    assert!(CAPABILITIES.contains(&Capability::PersonalFm));
    assert!(CAPABILITIES.contains(&Capability::SearchHot));
    assert!(CAPABILITIES.contains(&Capability::Feed));
}

#[test]
fn capabilities_include_new_apis() {
    // 漏加这项时 FFI 会报 "no provider supports xxx"(项目踩过)
    assert!(CAPABILITIES.contains(&Capability::PlaylistDetail));
    assert!(CAPABILITIES.contains(&Capability::Comment));
    assert!(CAPABILITIES.contains(&Capability::Share));
    assert!(CAPABILITIES.contains(&Capability::PodcastDetail));
}

/// 喜欢总数(/api/song/like/get): 正常回包 + 字段缺失两种形状
#[test]
fn song_like_state_parsing() {
    let ok = json!({"code": 200, "liked": true, "likedCount": 352});
    let st = parse_song_like_state(&ok);
    assert!(st.liked);
    assert_eq!(st.liked_count, 352);

    // 字段缺失/类型不对: 一律按"没喜欢/0 人"兜底, 不报错
    let empty = json!({"code": 200});
    let st = parse_song_like_state(&empty);
    assert!(!st.liked);
    assert_eq!(st.liked_count, 0);

    let weird = json!({"liked": "true", "likedCount": "1.2万"});
    let st = parse_song_like_state(&weird);
    assert!(!st.liked);
    assert_eq!(st.liked_count, 0);
}

#[test]
fn capabilities_include_song_like() {
    // 漏加就会 "no provider supports songLike", 菜单里的喜欢数直接消失
    assert!(CAPABILITIES.contains(&Capability::SongLike));
    assert_eq!(Capability::SongLike.as_str(), "songLike");
}
