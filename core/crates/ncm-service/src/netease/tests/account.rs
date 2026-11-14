//! 登录/资料/签到/等级/勋章相关单测.

use crate::netease::*;
use ncm_provider::ProviderErrorKind;
use serde_json::json;

/// 登录类业务码归类: 400 是用户可改的输入错(Auth), 503 是「太频繁」可重试;
/// 8821 仍走全局 -> RiskControl. 实测(2026-11-11)非法号码回 400 手机号码不符合规范.
#[test]
fn login_code_mapping() {
    let e = map_login_code(400, "手机号码不符合规范".into());
    assert_eq!(e.kind, ProviderErrorKind::Auth);
    assert!(!e.retryable);
    let e = map_login_code(503, String::new());
    assert_eq!(e.kind, ProviderErrorKind::Internal);
    assert!(e.retryable);
    assert_eq!(
        map_login_code(8821, "安全环境风险".into()).kind,
        ProviderErrorKind::RiskControl
    );
    // 其它码仍按全局口径(400 以外的未知码 = internal 不可重试)
    let e = map_login_code(250, String::new());
    assert_eq!(e.kind, ProviderErrorKind::Internal);
    assert!(!e.retryable);
}

/// 手机号规范化: 容忍空白/连字符/前缀 '+', 拒绝明显不合法输入.
#[test]
fn normalize_phone_accepts_common_input() {
    assert_eq!(
        normalize_phone("138 0013 8000", "86").unwrap(),
        ("13800138000".into(), "86".into())
    );
    assert_eq!(
        normalize_phone("+8613800138000", "+86").unwrap(),
        ("8613800138000".into(), "86".into())
    );
    // 区号留空默认 86
    assert_eq!(normalize_phone("13800138000", "").unwrap().1, "86");
    // 号码里混入字母 / 太短 / 区号非数字都要报错
    assert!(normalize_phone("1380013800a", "86").is_err());
    assert!(normalize_phone("12345", "86").is_err());
    assert!(normalize_phone("13800138000", "8a").is_err());
}

/// 发验证码的响应: 成功按 data:true 处理, expire 缺省 300.
#[test]
fn parse_sms_sent_fields() {
    let r = parse_sms_sent(&json!({"code":200,"data":true}));
    assert_eq!(r.code, 200);
    assert_eq!(r.expires_in, 300);
    let r = parse_sms_sent(&json!({"code":200,"expire":60,"message":"已发送"}));
    assert_eq!(r.expires_in, 60);
    assert_eq!(r.message, "已发送");
}

/// 手机号登录成功: 凭据同样只在 Set-Cookie; 缺 MUSIC_U 必须报错而不是"假成功".
#[test]
fn parse_phone_login_requires_cookie() {
    let cookies = vec![
        "MUSIC_U=phone_u; Path=/; HttpOnly".to_string(),
        "__csrf=csrf789; Path=/".to_string(),
        "NMTID=fingerprint; Path=/".to_string(),
    ];
    let r = parse_phone_login(
        &json!({"code":200,"profile":{"nickname":"下去玩","avatarUrl":"https://x/a.jpg"}}),
        &cookies,
    )
    .unwrap();
    assert!(r.cookie.contains("MUSIC_U=phone_u"));
    assert!(r.cookie.contains("__csrf=csrf789"));
    assert!(!r.cookie.contains("NMTID"));
    assert!(r.result.logged_in);
    assert_eq!(r.result.nickname, "下去玩");
    assert_eq!(r.result.avatar_url.as_deref(), Some("https://x/a.jpg"));

    let err = parse_phone_login(
        &json!({"code":200}),
        &["JSESSIONID-WYYY=x; Path=/".to_string()],
    )
    .unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::Internal);
    assert!(err.detail.contains("MUSIC_U"));

    // 风控/验证码错误的 code 由 check_body 转成 RiskControl / Auth, 这里只验解析不 panic
    let err = parse_phone_login(&json!({"code":503}), &[]).unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::Internal);
}

/// 扫码登录轮询: 实测 code 语义 + 803 时凭据只在 Set-Cookie 里.
#[test]
fn qr_login_check_states_and_cookie() {
    // 801: 待扫
    let r = parse_qr_check(&json!({"code":801}), &[]).unwrap();
    assert_eq!(r.check.state, QrLoginState::Pending);
    assert!(r.cookie.is_none());
    assert!(!r.check.logged_in);
    // 802: 已扫待确认
    let r = parse_qr_check(&json!({"code":802}), &[]).unwrap();
    assert_eq!(r.check.state, QrLoginState::Scanned);
    // 800: 过期
    let r = parse_qr_check(&json!({"code":800}), &[]).unwrap();
    assert_eq!(r.check.state, QrLoginState::Expired);
    // 其它(如 400/风控): Failed, 不 panic
    let r = parse_qr_check(&json!({"code":400,"message":"x"}), &[]).unwrap();
    assert_eq!(r.check.state, QrLoginState::Failed);

    // 803: body 里带昵称/头像, 凭据在 Set-Cookie(只保留登录键, 设备指纹键丢掉)
    let cookies = vec![
        "MUSIC_U=abc123; Path=/; Domain=.music.163.com; HttpOnly".to_string(),
        "JSESSIONID-WYYY=xyz; Path=/".to_string(),
        "__csrf=csrf456; Path=/".to_string(),
        "NMTID=devfingerprint; Path=/".to_string(),
    ];
    let r = parse_qr_check(
        &json!({"code":803,"nickname":"下去玩","avatarUrl":"https://x/y.jpg"}),
        &cookies,
    )
    .unwrap();
    assert_eq!(r.check.state, QrLoginState::Confirmed);
    assert_eq!(r.check.code, 803);
    assert!(r.check.logged_in);
    assert_eq!(r.check.nickname, "下去玩");
    assert_eq!(r.check.avatar_url.as_deref(), Some("https://x/y.jpg"));
    let cookie = r.cookie.unwrap();
    assert!(cookie.contains("MUSIC_U=abc123"));
    assert!(cookie.contains("__csrf=csrf456"));
    // JSESSIONID-WYYY 是 weapi 会话的一部分, 保留; 设备指纹键不进账号簿
    assert!(cookie.contains("JSESSIONID-WYYY=xyz"));
    assert!(!cookie.contains("NMTID"));

    // 803 但没有 MUSIC_U: 必须报错, 不能当成登录成功
    let err = parse_qr_check(&json!({"code":803}), &[]).unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::Internal);
}

/// 签到进度: today.todaySignedIn + stats[6001/4001/5001] + records
#[test]
fn signin_progress_mapping() {
    let body = json!({
        "code": 200,
        "data": {
            "records": [
                {"day": "2026-11-06", "signed": true},
                {"day": "2026-11-05", "signed": false}
            ],
            "stats": [
                {"id": 6001, "currentProgress": 13},
                {"id": 4001, "currentProgress": 5},
                {"id": 5001, "currentProgress": 1}
            ],
            "today": {"todaySignedIn": true}
        }
    });
    let s = parse_signin_progress(&body);
    assert!(s.signed_today);
    assert_eq!(s.total_days, 13);
    assert_eq!(s.week_days, 5);
    assert_eq!(s.continuous_days, 1);
    assert_eq!(s.recent.len(), 2);
    assert!(s.recent[0].signed);
    assert_eq!(s.today_point, 0, "进度接口不给本次奖励");
}

#[test]
fn code_8821_is_risk_control() {
    let body = json!({"code": 8821, "message": "安全环境风险"});
    let err = check_body(&body).unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::RiskControl);
}

#[test]
fn user_level_mapping() {
    // 实测响应原样(2026-11-08, 已登录: 9 级, 2301/12000 首, 350/350 天)
    let body = json!({"code": 200, "full": false, "data": {
        "info": "60G音乐网盘免费容量$黑名单上限120$云音乐商城满100减12元优惠券",
        "level": 9,
        "nextLoginCount": 350,
        "nextPlayCount": 12000,
        "nowLoginCount": 350,
        "nowPlayCount": 2301,
        "progress": 0.19175,
        "userId": 1822714196u64
    }});
    let lv = parse_user_level(&body).expect("data 存在应解析成功");
    assert_eq!(lv.level, 9);
    assert_eq!(lv.now_play_count, 2301);
    assert_eq!(lv.next_play_count, 12000);
    assert_eq!(lv.now_login_count, 350);
    assert_eq!(lv.next_login_count, 350);
    // progress 实测 = nowPlayCount / nextPlayCount = 0.19175
    assert!((lv.progress - 0.19175).abs() < 1e-9);
    assert!(lv.privileges.starts_with("60G音乐网盘免费容量$"));
    assert_eq!(lv.privileges.split('$').count(), 3);
}

#[test]
fn user_level_missing_data() {
    // data 缺失 / 不是对象 / 字段缺失: 前者返回 None, 后者全 0 不 panic
    assert!(parse_user_level(&json!({"code": 200})).is_none());
    assert!(parse_user_level(&json!({"code": 200, "data": null})).is_none());
    assert!(parse_user_level(&json!({"code": 200, "data": []})).is_none());
    assert!(parse_user_level(&json!({})).is_none());
    let empty = parse_user_level(&json!({"code": 200, "data": {}})).expect("空对象也要有默认值");
    assert_eq!(empty.level, 0);
    assert_eq!(empty.now_play_count, 0);
    assert_eq!(empty.progress, 0.0);
    assert!(empty.privileges.is_empty());
    // progress 若被服务端换成字符串, 也要能吃
    let lv = parse_user_level(&json!({"code": 200, "data": {"progress": "0.5"}})).unwrap();
    assert!((lv.progress - 0.5).abs() < 1e-9);
}

#[test]
fn user_medals_empty() {
    // 空账号/空分类: 不 panic, medal_num 落 0
    assert_eq!(
        parse_user_medals(&json!({"code": 200})),
        MedalWall::default()
    );
    let wall = parse_user_medals(&json!({"code": 200, "data": {
        "medalNum": 0, "categoryMedalBlockVos": []
    }}));
    assert_eq!(wall.medal_num, 0);
    assert!(wall.medals.is_empty());
    // 分类存在但没有 medalVOS / medalVOS 不是数组
    let wall = parse_user_medals(&json!({"code": 200, "data": {
        "medalNum": 3,
        "categoryMedalBlockVos": [{"categoryTitle": "A"}, {"categoryTitle": "B", "medalVOS": "x"}]
    }}));
    assert_eq!(wall.medal_num, 3);
    assert!(wall.medals.is_empty());
}

#[test]
fn user_medals_mapping() {
    // 三项覆盖三种实测形态: 已获得(普通) / 未获得有进度(进程文字) / 乐迷徽章(等级+艺术家)
    let body = json!({"code": 200, "data": {
        "medalNum": 2,
        "obtainMedals": [{"medalCode": "忽略我", "status": "OBTAIN"}],
        "categoryMedalBlockVos": [
            {"categoryCode": "will_obtain", "categoryTitle": "即将获得", "medalVOS": [
                {"medalCode": "23811503", "medalName": "喵！优秀达人", "status": "WILL_OBTAIN",
                 "acceptCondition": "参与「笔记达人限时挑战」活动",
                 "medalPicUrl": "http://p5.music.126.net/obj/a.png",
                 "wearPic": "http://p5.music.126.net/obj/a_wear.png",
                 "obtainTime": null, "progress": null, "rankText": null,
                 "levelTitle": null, "userObtainProportion": null}
            ]},
            {"categoryCode": "genre_language", "categoryTitle": "成就徽章", "medalVOS": [
                {"medalCode": "21298503", "medalName": "听歌成就·奏鸣", "status": "NOT_OBTAIN_PROCESS",
                 "acceptCondition": "统计歌曲需满足完整播放", "medalPicUrl": "http://p5/b.png",
                 "wearPic": "", "obtainTime": null, "progress": "当前进度1897/5000",
                 "rankText": null, "levelTitle": null},
                {"medalCode": "22086503", "medalName": "汪牌认证", "status": "OBTAIN",
                 "acceptCondition": "为歌曲下你喜欢的乐评点个赞吧",
                 "medalPicUrl": "http://p5/c.png", "wearPic": "http://p5/c_wear.png",
                 "obtainTime": 1787144904304u64, "progress": null,
                 "rankText": "前0.033%获得该徽章", "levelTitle": null}
            ]},
            {"categoryTitle": "乐迷徽章", "medalVOS": [
                {"medalCode": "20170503_1081839", "medalName": "Chinese Football",
                 "status": "OBTAIN", "specialMedalType": "new_fans_level",
                 "acceptCondition": "关注99天", "artistName": "Chinese Football",
                 "medalPicUrl": "https://p5/d.png", "wearPic": "http://p5/d_wear.png",
                 "levelTitle": "Lv.4 乐迷", "levelTitleShort": "Lv.4",
                 "medalLevel": 4, "medalLevelAll": 9,
                 "obtainTime": 1721337006822u64, "rankText": "前2.839%获得该徽章"}
            ]}
        ]
    }});
    let wall = parse_user_medals(&body);
    // 只解析 categoryMedalBlockVos, obtainMedals 不重复计入
    assert_eq!(wall.medals.len(), 4);
    assert_eq!(wall.medal_num, 2); // 接口给的 medalNum

    let will = &wall.medals[0];
    assert_eq!(will.code, "23811503");
    assert_eq!(will.name, "喵！优秀达人");
    assert_eq!(will.status, "WILL_OBTAIN");
    assert!(!will.obtained);
    assert_eq!(will.obtain_time_ms, None);
    assert_eq!(
        will.pic_url.as_deref(),
        Some("http://p5.music.126.net/obj/a.png")
    );
    assert_eq!(
        will.wear_pic_url.as_deref(),
        Some("http://p5.music.126.net/obj/a_wear.png")
    );
    assert!(will.progress_text.is_none() && will.rank_text.is_none() && will.level_title.is_none());

    let busy = &wall.medals[1];
    assert_eq!(busy.code, "21298503");
    assert!(!busy.obtained);
    // progress 是字符串文案, 原样保留不拆数字
    assert_eq!(busy.progress_text.as_deref(), Some("当前进度1897/5000"));
    // 空串 wearPic 归 None
    assert!(busy.wear_pic_url.is_none());

    let got = &wall.medals[2];
    assert!(got.obtained);
    assert_eq!(got.obtain_time_ms, Some(1787144904304));
    assert_eq!(got.rank_text.as_deref(), Some("前0.033%获得该徽章"));

    let fans = &wall.medals[3];
    assert_eq!(fans.code, "20170503_1081839");
    assert_eq!(fans.name, "Chinese Football");
    assert_eq!(fans.level_title.as_deref(), Some("Lv.4 乐迷"));
    assert_eq!(fans.obtain_time_ms, Some(1721337006822));
}

#[test]
fn user_medals_num_fallback_and_skip_bad() {
    // 缺 medalNum 时按 status=OBTAIN 数; 缺 medalCode 的条目跳过
    let body = json!({"code": 200, "data": {"categoryMedalBlockVos": [
        {"medalVOS": [
            {"medalName": "无 code", "status": "OBTAIN"},
            {"medalCode": "", "medalName": "空 code", "status": "OBTAIN"},
            {"medalCode": "A1", "medalName": "x", "status": "OBTAIN", "obtainTime": 1},
            {"medalCode": "A2", "medalName": "y", "status": "NOT_OBTAIN_NO_PROCESS", "obtainTime": 0}
        ]}
    ]}});
    let wall = parse_user_medals(&body);
    assert_eq!(wall.medals.len(), 2);
    assert_eq!(wall.medal_num, 1);
    assert_eq!(wall.medals[0].code, "A1");
    assert_eq!(wall.medals[0].name, "x"); // 缺 acceptCondition → 空串
    assert_eq!(wall.medals[0].condition, "");
    // obtainTime = 0 视为未获得(null), 不能当 1970 年
    assert_eq!(wall.medals[1].obtain_time_ms, None);
}
/// 音乐人身份: user_detail 的 profile.artistId 是**艺人 id**(与 user id 不同空间),
/// 普通用户整个字段缺失。头像点击靠它决定进艺人主页还是用户主页。
///
/// 实测(2026-11-14, 匿名 /api/v1/user/detail):
///   uid=1373758224 OfficialXeuphoria → userType=2, artistId=1064078
///   uid=32953014 binaryify(普通用户) → userType=0, 无 artistId
#[test]
fn profile_detail_artist_identity() {
    let musician = json!({"code": 200, "profile": {
        "userId": 1373758224u64, "nickname": "OfficialXeuphoria", "userType": 2, "artistId": 1064078u64
    }});
    let d = parse_profile_detail(&musician);
    assert_eq!(d.artist_id, Some(1064078));
    assert_eq!(d.user_id, 1373758224);

    // 普通用户: 没有 artistId ⇒ None(UI 只能进用户主页)
    let normal = json!({"code": 200, "profile": {
        "userId": 32953014u64, "nickname": "binaryify", "userType": 0
    }});
    assert_eq!(parse_profile_detail(&normal).artist_id, None);

    // 显式 0 也归 None: 免得 UI 拿 0 去请求艺人详情
    let zero = json!({"profile": {"userId": 1, "nickname": "x", "artistId": 0}});
    assert_eq!(parse_profile_detail(&zero).artist_id, None);
}

/// 需求 12: user/detail 的等级在**响应顶层**(body.level), 不在 profile 里.
/// 之前只读 profile.level ⇒ 永远 0(UI 上恒为 "Lv.0").
#[test]
fn profile_detail_level_from_body_top() {
    let body = json!({
        "code": 200,
        "level": 8,
        "profile": {"userId": 42, "nickname": "我", "follows": 3, "followeds": 4}
    });
    let d = parse_profile_detail(&body);
    assert_eq!(d.level, 8, "顶层 level 必须落到 ProfileDetail.level");
    assert_eq!(d.user_id, 42);

    // profile 里也带 level 时以 profile 为准(两种形状都见过)
    let body = json!({
        "code": 200,
        "level": 3,
        "profile": {"userId": 7, "nickname": "x", "level": 5}
    });
    assert_eq!(parse_profile_detail(&body).level, 5);

    // 缺失(未登录/隐私) ⇒ 0, 不 panic
    let body = json!({"code": 200, "profile": {"userId": 7, "nickname": "x"}});
    assert_eq!(parse_profile_detail(&body).level, 0);
    assert_eq!(parse_profile_detail(&json!({"code": 200})).level, 0);
}

/// 简介规范化: 去空白、允许清空、超 132 字符报 unsupported.
#[test]
fn signature_normalization_rules() {
    assert_eq!(normalize_signature("  你好  ").unwrap(), "你好");
    assert_eq!(normalize_signature("").unwrap(), "");
    assert_eq!(normalize_signature("   ").unwrap(), "");
    let long: String = "字".repeat(MAX_SIGNATURE_CHARS + 1);
    let e = normalize_signature(&long).unwrap_err();
    assert_eq!(e.kind, ProviderErrorKind::Unsupported);
    // 边界: 正好 132 字符允许
    assert_eq!(
        normalize_signature(&"字".repeat(MAX_SIGNATURE_CHARS))
            .unwrap()
            .chars()
            .count(),
        MAX_SIGNATURE_CHARS
    );
}
