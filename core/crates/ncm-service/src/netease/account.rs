//! 账号域: 扫码/手机号登录, 资料, 签到.

use super::*;

impl NeteaseProvider {
    /// 云贝签到状态(需要登录)
    pub(super) fn signin_status(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        Box::pin(async move { self.fetch_signin_progress().await })
    }

    /// 签到(需要登录). 已签到时不重复请求(接口会回 "重复签到" 错误).
    pub(super) fn sign_in(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        Box::pin(async move {
            let before = self.fetch_signin_progress().await?;
            if before.signed_today {
                return Ok(before);
            }
            let (client, domain, ua, cookie) = self.snapshot();
            // type=0 实测回 "功能暂不支持"(安卓端通道), 只有 type=1(web) 真的签到成功.
            let q = make_query(&cookie, &domain, &ua).param("type", "1");
            let resp = client.daily_signin(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let point = resp.body.get("point").and_then(Value::as_u64).unwrap_or(0) as u32;
            let mut status = self.fetch_signin_progress().await?;
            status.signed_today = true;
            status.today_point = point;
            Ok(status)
        })
    }

    /// 个人主页资料(背景图/头像/签名/关注数). 需要登录.
    pub(super) fn profile_detail(&self) -> BoxFuture<'_, ProviderResult<ProfileDetail>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("uid", &uid.to_string());
            let resp = client.user_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_profile_detail(&resp.body))
        })
    }

    /// 任意用户的公开资料(user/detail, 不需要登录)
    pub(super) fn user_profile<'a>(
        &'a self,
        uid: u64,
    ) -> BoxFuture<'a, ProviderResult<ProfileDetail>> {
        Box::pin(async move {
            if uid == 0 {
                return Err(ProviderError::not_found("用户 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("uid", &uid.to_string());
            let resp = client.user_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_profile_detail(&resp.body))
        })
    }

    /// 当前登录账号资料(用于多账号记忆: 登录成功后记住 uid/昵称)
    pub(super) fn profile<'a>(&'a self) -> BoxFuture<'a, ProviderResult<ncm_domain::Profile>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("未登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.user_account(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_profile(&resp.body)
        })
    }

    /// 扫码登录 ①: 申请二维码 key(官方网页登录页同一通道, weapi)
    pub(super) fn login_qr_create<'a>(&'a self) -> BoxFuture<'a, ProviderResult<QrLoginKey>> {
        Box::pin(async move {
            let (client, domain, _ua, _cookie) = self.snapshot();
            let resp = client
                .request(
                    "/api/login/qrcode/unikey",
                    serde_json::json!({ "type": 1 }),
                    qr_option(domain),
                )
                .await
                .map_err(map_error)?;
            check_body(&resp.body)?;
            let key = resp
                .body
                .get("unikey")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if key.is_empty() {
                return Err(ProviderError::internal("qr login: 响应里没有 unikey"));
            }
            Ok(QrLoginKey {
                url: format!("https://music.163.com/login?codekey={key}"),
                key,
                // 官方 key 有效期约 3 分钟; 过期由服务端回 800 决定, 这里只给 UI 提示用
                expires_in: 180,
            })
        })
    }

    /// 扫码登录 ②: 轮询. 803 时的登录凭据在 Set-Cookie 里(不在 body).
    pub(super) fn login_qr_check<'a>(
        &'a self,
        key: &'a str,
    ) -> BoxFuture<'a, ProviderResult<QrLoginOutcome>> {
        Box::pin(async move {
            let (client, domain, _ua, _cookie) = self.snapshot();
            let resp = client
                .request(
                    "/api/login/qrcode/client/login",
                    serde_json::json!({ "key": key, "type": 1 }),
                    qr_option(domain),
                )
                .await
                .map_err(map_error)?;
            parse_qr_check(&resp.body, &resp.cookie)
        })
    }

    /// 手机号登录 ①: 发短信验证码(网页登录通道 weapi, 与扫码同一族).
    ///
    /// 不用 App 原生登录族(eapi): 那条路在交互式风控下回 8821, 而网页登录是已知稳路径.
    pub(super) fn login_sms_send<'a>(
        &'a self,
        phone: &'a str,
        country_code: &'a str,
    ) -> BoxFuture<'a, ProviderResult<SmsCodeSent>> {
        Box::pin(async move {
            let (client, domain, _ua, _cookie) = self.snapshot();
            let (phone, ctcode) = normalize_phone(phone, country_code)?;
            let resp = client
                .request(
                    "/api/sms/captcha/sent",
                    serde_json::json!({ "cellphone": phone, "ctcode": ctcode }),
                    qr_option(domain),
                )
                .await
                .map_err(map_error)?;
            check_body_with(&resp.body, map_login_code)?;
            Ok(parse_sms_sent(&resp.body))
        })
    }

    /// 手机号登录 ②: 校验验证码. 成功时凭据在 Set-Cookie(与扫码 803 一样不在 body).
    pub(super) fn login_sms_verify<'a>(
        &'a self,
        phone: &'a str,
        code: &'a str,
        country_code: &'a str,
    ) -> BoxFuture<'a, ProviderResult<PhoneLoginOutcome>> {
        Box::pin(async move {
            let (client, domain, _ua, _cookie) = self.snapshot();
            let (phone, countrycode) = normalize_phone(phone, country_code)?;
            let code = code.trim();
            if code.is_empty() {
                return Err(ProviderError::auth("验证码不能为空"));
            }
            let resp = client
                .request(
                    "/api/login/cellphone",
                    serde_json::json!({
                        "phone": phone,
                        "countrycode": countrycode,
                        "captcha": code,
                        "rememberLogin": "true",
                    }),
                    qr_option(domain),
                )
                .await
                .map_err(map_error)?;
            check_body_with(&resp.body, map_login_code)?;
            parse_phone_login(&resp.body, &resp.cookie)
        })
    }

    /// 签到进度原始结构 → SigninStatus
    pub(super) async fn fetch_signin_progress(&self) -> ProviderResult<SigninStatus> {
        let (client, domain, ua, cookie) = self.snapshot();
        if !cookie.contains("MUSIC_U=") {
            return Err(ProviderError::auth("签到需要登录"));
        }
        let q = make_query(&cookie, &domain, &ua);
        let resp = client.signin_progress(&q).await.map_err(map_error)?;
        check_body(&resp.body)?;
        Ok(parse_signin_progress(&resp.body))
    }
}

/// 账号资料详情: user_detail 的 `profile` 对象
pub fn parse_profile_detail(body: &Value) -> ProfileDetail {
    let p = body.get("profile").unwrap_or(body);
    ProfileDetail {
        user_id: u64_of(p, "userId").unwrap_or(0),
        nickname: str_of(p, "nickname").unwrap_or_default(),
        avatar_url: str_of(p, "avatarUrl").filter(|s| !s.is_empty()),
        background_url: str_of(p, "backgroundUrl").filter(|s| !s.is_empty()),
        signature: str_of(p, "signature").unwrap_or_default(),
        vip: p.get("vipType").and_then(Value::as_i64).unwrap_or(0) > 0,
        follows: u64_of(p, "follows").unwrap_or(0),
        followeds: u64_of(p, "followeds").unwrap_or(0),
        level: u64_of(p, "level").unwrap_or(0),
    }
}

/// 轮询响应的解析(抽出来便于单测).
///
/// 官方 code: 800 过期 / 801 待扫 / 802 已扫待确认 / 803 成功.
/// **803 的登录凭据不在 body 里, 而在响应的 Set-Cookie 中** —— 这是整个桌面端登录
/// 能绕开 WebView 的关键(见 docs 与 .pi/memory/HINDSIGHT.md).
pub(super) fn parse_qr_check(
    body: &Value,
    set_cookies: &[String],
) -> ProviderResult<QrLoginOutcome> {
    let code = body.get("code").and_then(Value::as_i64).unwrap_or(-1);
    let state = match code {
        803 => QrLoginState::Confirmed,
        802 => QrLoginState::Scanned,
        801 => QrLoginState::Pending,
        800 => QrLoginState::Expired,
        _ => QrLoginState::Failed,
    };
    let cookie = if state == QrLoginState::Confirmed {
        // 只留登录凭据键: 设备指纹(deviceId/_ntes_nuid/WNMCID...)由本地会话提供
        let raw = set_cookies
            .iter()
            .map(|c| c.split(';').next().unwrap_or("").trim())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("; ");
        let login_only = crate::identity::extract_login_cookie(&raw);
        if !login_only.contains("MUSIC_U=") {
            return Err(ProviderError::internal(
                "qr login: 已确认但没有拿到 MUSIC_U(检查 Set-Cookie)",
            ));
        }
        Some(login_only)
    } else {
        None
    };
    let nickname = body
        .get("nickname")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let avatar_url = body
        .get("avatarUrl")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let check = QrLoginCheck {
        state,
        code,
        logged_in: cookie.is_some(),
        nickname,
        avatar_url,
    };
    Ok(QrLoginOutcome { check, cookie })
}

/// 手机号规范化: 去掉空白/连字符/括号与可选的前缀 '+', 只留数字.
///
/// 返回 (手机号, 区号): 区号缺省 86; 手机号 6~15 位, 区号 1~4 位.
pub(super) fn normalize_phone(phone: &str, country_code: &str) -> ProviderResult<(String, String)> {
    let clean = |s: &str| -> String {
        s.chars()
            .filter(|c| !c.is_whitespace() && *c != '-' && *c != '(' && *c != ')' && *c != '+')
            .collect()
    };
    let phone = clean(phone);
    if !phone.chars().all(|c| c.is_ascii_digit()) || !(6..=15).contains(&phone.len()) {
        return Err(ProviderError::auth(
            "手机号看起来不对(只填号码本身, 区号另填)",
        ));
    }
    let cc = clean(country_code);
    let cc = if cc.is_empty() { "86".to_string() } else { cc };
    if !cc.chars().all(|c| c.is_ascii_digit()) || !(1..=4).contains(&cc.len()) {
        return Err(ProviderError::auth("国家/地区区号看起来不对(例如 86)"));
    }
    Ok((phone, cc))
}

/// `/api/sms/captcha/sent` 的响应(抽出来便于单测).
///
/// 成功形如 `{code:200, data:true}`; 命中风控回 8821(由 check_body 转成 RiskControl),
/// 号码/区号不合法回 400, 频率限制回 503.
pub(super) fn parse_sms_sent(body: &Value) -> SmsCodeSent {
    let code = body.get("code").and_then(Value::as_i64).unwrap_or(200);
    let message = body
        .get("message")
        .or_else(|| body.get("msg"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let expires_in = body
        .get("expiresIn")
        .or_else(|| body.get("expire"))
        .and_then(Value::as_u64)
        .filter(|v| *v > 0)
        .unwrap_or(300) as u32;
    SmsCodeSent {
        code,
        message,
        expires_in,
    }
}

/// `/api/login/cellphone` 的响应解析.
///
/// 与扫码 803 一致: **登录凭据不在 body, 而在 Set-Cookie**; body 里只有 account/profile.
pub(super) fn parse_phone_login(
    body: &Value,
    set_cookies: &[String],
) -> ProviderResult<PhoneLoginOutcome> {
    let raw = set_cookies
        .iter()
        .map(|c| c.split(';').next().unwrap_or("").trim())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("; ");
    let cookie = crate::identity::extract_login_cookie(&raw);
    if !cookie.contains("MUSIC_U=") {
        return Err(ProviderError::internal(
            "手机号登录: 校验通过但没有拿到 MUSIC_U(检查 Set-Cookie)",
        ));
    }
    let profile = body.get("profile").filter(|v| !v.is_null());
    let nickname = profile
        .and_then(|p| p.get("nickname"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let avatar_url = profile
        .and_then(|p| p.get("avatarUrl"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    Ok(PhoneLoginOutcome {
        result: PhoneLoginResult {
            logged_in: true,
            nickname,
            avatar_url,
        },
        cookie,
    })
}

/// 扫码登录走 weapi(官方网页登录页的通道).
///
/// UA 故意不传业务侧的 NeteaseMusicDesktop: weapi 由 vendor 选 PC 浏览器 UA,
/// 与"网页登录"这个动作自洽; 混用客户端 UA 反而是风控特征.
/// 评论写接口要 eapi(客户端形态), 不能沿用 weapi: 动态评论的写入走 eapi 才认。
pub(super) fn write_option(
    cookie: &str,
    domain: &Option<String>,
    ua: &Option<String>,
) -> RequestOption {
    RequestOption {
        crypto: CryptoType::Eapi,
        cookie: if cookie.is_empty() {
            None
        } else {
            Some(cookie.to_string())
        },
        ua: ua.clone(),
        domain: domain.clone(),
        ..Default::default()
    }
}

pub(super) fn qr_option(domain: Option<String>) -> RequestOption {
    RequestOption {
        crypto: CryptoType::Weapi,
        domain,
        ..Default::default()
    }
}

/// `/api/nuser/account/get` 的响应形如
/// `{code:200, account:{id,...}, profile:{userId, nickname, avatarUrl}}`
pub(super) fn parse_profile(body: &Value) -> ProviderResult<ncm_domain::Profile> {
    let profile = body.get("profile").filter(|v| !v.is_null());
    let account = body.get("account").filter(|v| !v.is_null());
    let user_id = profile
        .and_then(|p| p.get("userId").and_then(Value::as_u64))
        .or_else(|| account.and_then(|a| a.get("id").and_then(Value::as_u64)))
        .ok_or_else(|| ProviderError::auth("profile: 没有 userId(多半是未登录)"))?;
    let nickname = profile
        .and_then(|p| p.get("nickname").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    let avatar_url = profile
        .and_then(|p| p.get("avatarUrl").and_then(Value::as_str))
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    // vipType: 0 普通 / 10 音乐包 / 11 黑胶VIP; 账号与资料上都有, 任一大于 0 即会员
    let vip_type = profile
        .and_then(|p| p.get("vipType").and_then(Value::as_i64))
        .or_else(|| account.and_then(|a| a.get("vipType").and_then(Value::as_i64)))
        .unwrap_or(0);
    Ok(ncm_domain::Profile {
        user_id,
        nickname,
        avatar_url,
        vip: vip_type > 0,
    })
}

/// 签到进度: {code, data:{records:[{day,signed}], stats:[{id,currentProgress,description}],
/// today:{todaySignedIn}}}
/// stats 的 id: 6001 累计签到 / 4001 每周签到 / 5001 连续签到(28 天循环).
pub fn parse_signin_progress(body: &Value) -> SigninStatus {
    let data = body.get("data").unwrap_or(body);
    let signed_today = data
        .get("today")
        .and_then(|t| t.get("todaySignedIn"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let stats = data.get("stats").and_then(Value::as_array);
    let progress_of = |id: i64| -> u32 {
        stats
            .and_then(|arr| {
                arr.iter()
                    .find(|s| s.get("id").and_then(Value::as_i64) == Some(id))
            })
            .and_then(|s| s.get("currentProgress").and_then(Value::as_u64))
            .unwrap_or(0) as u32
    };
    let recent = data
        .get("records")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|r| {
                    let day = str_of(r, "day")?;
                    Some(SigninDay {
                        day,
                        signed: r.get("signed").and_then(Value::as_bool).unwrap_or(false),
                    })
                })
                .take(7)
                .collect()
        })
        .unwrap_or_default();
    SigninStatus {
        signed_today,
        total_days: progress_of(6001),
        continuous_days: progress_of(5001),
        week_days: progress_of(4001),
        recent,
        today_point: 0,
    }
}
