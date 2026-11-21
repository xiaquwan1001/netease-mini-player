//! 身份与账号: 个人主页资料 / 账号簿 / 扫码与短信登录 / 凭据后端 / 登录 cookie 判据.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 个人主页资料 ----------------

/// 个人主页资料: 直接镜像 domain 类型 `ProfileDetail`.
#[frb(mirror(ProfileDetail))]
pub struct _ProfileDetail {
    pub user_id: u64,
    /// 音乐人身份对应的艺人 id(普通用户为 None); Dart 侧据此决定头像点击落哪个主页
    pub artist_id: Option<u64>,
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
pub async fn profile_detail() -> Result<ProfileDetail, FfiError> {
    ffi_forward!(Capability::ProfileDetail, provider.profile_detail())
}

/// 云盘上传结果: 直接镜像 domain 类型.
#[frb(mirror(CloudUploadResult))]
pub struct _CloudUploadResult {
    /// 新歌 id(云盘列表/播放用它)
    pub song_id: u64,
    pub name: String,
    /// 是否命中秒传(没有真正上传字节)
    pub instant: bool,
}

/// 上传本地音频文件到音乐云盘(需登录).
///
/// 同步阻塞直到上传+转码+发布完成(最长约 1 分钟), 调用方要显示"上传中"。
/// 失败语义: 未登录 `[auth]`、文件读不到 `[unsupported]`、上传/转码失败 `[internal]`/`[network]`。
pub async fn cloud_upload(file_path: String) -> Result<CloudUploadResult, FfiError> {
    // 按值参数要两份(插件 + 内置回落), 所以在闭包里先克隆再交给 future.
    routed_call(Capability::Cloud, |p| {
        let file_path = file_path.clone();
        Box::pin(async move { p.cloud_upload(file_path).await })
    })
    .await
}

/// 修改个人简介(签名). 需要登录; 返回更新后的资料(服务端可能做敏感词折中).
///
/// 上游 `module/user_update.js` → `POST /api/user/profile/update`; 局部更新, 只改签名。
/// 失败语义: 未登录 `[auth]`、超过 132 字符 `[unsupported]`、风控 `[riskControl]`。
pub async fn update_signature(signature: String) -> Result<ProfileDetail, FfiError> {
    routed_call(Capability::ProfileDetail, |p| {
        let signature = signature.clone();
        Box::pin(async move { p.update_signature(signature).await })
    })
    .await
}

/// 任意用户的公开资料(他人主页; 不需要登录). 与 profile_detail 的区别: 那个只读当前账号.
pub async fn user_profile(user_id: u64) -> Result<ProfileDetail, FfiError> {
    ffi_forward!(Capability::ProfileDetail, provider.user_profile(user_id))
}

/// 任意用户的公开歌单(他人主页; 不需要登录).
/// 口径: 未登录时服务端只回公开歌单, 不含对方的"我喜欢的音乐".
pub async fn user_playlists_of(user_id: u64, limit: u32) -> Result<Vec<Playlist>, FfiError> {
    ffi_forward!(
        Capability::Playlist,
        provider.user_playlists_of(user_id, limit)
    )
}

/// 收藏曲目到指定歌单(需登录)
pub async fn add_to_playlist(playlist_id: u64, track_id: u64) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::PlaylistEdit)?;
    provider
        .add_to_playlist(playlist_id, ncm_domain::TrackId::new(track_id))
        .await
        .map_err(FfiError::from)
}

/// 取播放直链: **产品取链路径**, 走插件路由(`Core::route_decision` + `route::call_routed`).
///
/// 判定(用插件还是内置)只在 `ncm_service::plugins::route` 里做, 本层不重复判断;
/// 插件侧失败(超时/脚本错/协议错)回落内置 provider, 内置自身的失败直接上抛。
pub async fn song_url(
    track_id: u64,
    level: String,
    name: Option<String>,
    singer: Option<String>,
    album_name: Option<String>,
    interval: Option<u64>,
) -> Result<StreamUrl, FfiError> {
    let level = ncm_provider::AudioLevel::parse(&level).unwrap_or_default();
    let mut req = ncm_provider::SongUrlRequest::new(ncm_domain::TrackId::new(track_id));
    req.level = level;
    // 歌曲上下文只给**插件**用(拼上游 LX 的 musicInfo): name/singer 缺了, 靠关键词中转的
    // 脚本(咪咕 oiapi / QQ keyword 系)必然取不到链。内置 provider 不看它 ⇒ 传了也不改官方链路。
    let meta = ncm_provider::SongUrlMeta {
        name: name.unwrap_or_default(),
        singer: singer.unwrap_or_default(),
        album_name: album_name.unwrap_or_default(),
        interval: interval.unwrap_or(0),
        ..Default::default()
    };
    let has_meta = !meta.name.is_empty()
        || !meta.singer.is_empty()
        || !meta.album_name.is_empty()
        || meta.interval > 0;
    if has_meta {
        req = req.with_meta(meta);
    }
    // 闭包是 Fn(可能被调两次: 插件一次、回落内置一次), SongUrlRequest 已不是 Copy,
    // 所以先影子成引用再按引用捕获。
    let req = &req;
    let stream = routed_call(Capability::SongUrl, |provider| {
        Box::pin(async move { provider.song_url(req).await })
    })
    .await?;
    // T2(2026-11-18): 记下"这条曲子这次按什么音质取的链", 供桌面缓存键
    // (`AudioCache::path_for_level`) 打标 —— 旧键不含音质, 换档会误命中别的码率文件。
    // 走进程内旁路而不是给 `play_track` 加参数: 那个签名是 FFI 导出, 改它要动 codegen。
    ncm_service::cache::remember_level(track_id, level.as_str());
    Ok(stream)
}

pub async fn lyric(track_id: u64) -> Result<String, FfiError> {
    let lyric = routed_call(Capability::Lyric, |provider| {
        Box::pin(async move { provider.lyric(ncm_domain::TrackId::new(track_id)).await })
    })
    .await?;
    Ok(lyric.lrc.unwrap_or_default())
}

/// 退出登录: 只清登录凭据, 设备指纹(deviceId/_ntes_*/WNMCID/NMTID)保留.
/// 账号本身留在账号簿里, 下次可以一键切回(不用重新扫码).
/// 返回 true 表示现在已经不是登录态.
pub fn logout() -> Result<bool, FfiError> {
    let mut guard = core()?.lock().map_err(FfiError::from)?;
    guard.logout().map_err(FfiError::from)?;
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

/// 扫码登录: 二维码会话(Dart 侧渲染 QR + 轮询)
#[frb(mirror(QrLoginKey))]
pub struct _QrLoginKey {
    pub key: String,
    /// 二维码内容(App 直接扫)
    pub url: String,
    /// 有效期(秒)
    pub expires_in: u64,
}

/// 扫码登录状态(801 待扫 / 802 已扫 / 803 成功 / 800 过期 / 8821 需易盾验证)
#[frb(mirror(QrLoginState))]
pub enum _QrLoginState {
    Pending,
    Scanned,
    Confirmed,
    Expired,
    Failed,
    Captcha,
    Unknown,
}

/// 扫码登录: 一次轮询的结果(Confirmed 时凭据已由 Rust 落盘, UI 只看 loggedIn).
///
/// 注意: **凭据不进 Dart** —— cookie 在 ncm-provider 的 QrLoginOutcome 里,
/// 由本模块落盘后丢弃, 只回元数据。
#[frb(mirror(QrLoginCheck))]
pub struct _QrLoginCheck {
    pub state: QrLoginState,
    /// 官方原始 code(801/802/803/800/8821; 未知 code 原样保留), 排障用
    pub code: i64,
    /// Confirmed 且凭据已落盘
    pub logged_in: bool,
    pub nickname: String,
    pub avatar_url: Option<String>,
    /// 易盾验证句柄(8821 场景), 下一轮轮询原样回传
    pub secure_captcha: Option<String>,
}

#[frb(mirror(SmsCodeSent))]
pub struct _SmsCodeSent {
    /// 服务端原始 code(200 已发送 / 8821 风控 / 400 号码不合法 / 503 频率限制)
    pub code: i64,
    pub message: String,
    /// 声明有效期(秒)
    pub expires_in: u32,
}

/// 手机号+验证码登录成功后的结果(凭据已落盘, 不回传 Dart)
#[frb(mirror(PhoneLoginResult))]
pub struct _PhoneLoginResult {
    /// 校验通过且凭据已落盘
    pub logged_in: bool,
    pub nickname: String,
    pub avatar_url: Option<String>,
}

/// 凭据后端状态(设置页展示用). 不含任何凭据内容.
pub struct CredentialStatusDto {
    /// secure / plaintext_consented / plaintext_fallback
    pub kind: String,
    /// dpapi / file / none
    pub backend: String,
    /// 旧明文是否已迁移进后端
    pub migrated: bool,
    /// 面向用户的说明文案
    pub note: String,
}

fn accounts_of(guard: &Core) -> Result<Vec<AccountDto>, FfiError> {
    let book = guard.accounts().map_err(FfiError::from)?;
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

/// 扫码登录 ①(桌面端官方网页登录通道): 申请二维码.
///
/// 桌面端没有 WebView, 也就无法读浏览器里 HttpOnly 的 MUSIC_U; 官方扫码通道把凭据
/// 放在轮询响应的 Set-Cookie 里, 因此 Linux/Windows 共用这一条实现, 不需要平台代码.
pub async fn login_qr_create() -> Result<QrLoginKey, FfiError> {
    let provider = {
        let guard = core()?.lock().map_err(FfiError::from)?;
        guard.netease.clone()
    };
    use ncm_provider::AccountProvider;
    provider.login_qr_create().await.map_err(FfiError::from)
}

/// 扫码登录 ②: 轮询一次. Confirmed(803) 时顺带把凭据合并落盘, Dart 侧再同步账号资料.
pub async fn login_qr_check(
    key: String,
    secure_captcha: Option<String>,
) -> Result<QrLoginCheck, FfiError> {
    let provider = {
        let guard = core()?.lock().map_err(FfiError::from)?;
        guard.netease.clone()
    };
    use ncm_provider::AccountProvider;
    let outcome = provider
        .login_qr_check(&key, secure_captcha.as_deref())
        .await
        .map_err(FfiError::from)?;
    if let Some(cookie) = outcome.cookie.as_deref() {
        let mut guard = core()?.lock().map_err(FfiError::from)?;
        guard.apply_login_cookie(cookie).map_err(FfiError::from)?;
    }
    // 凭据到此为止: 只把元数据交给 Dart
    Ok(outcome.check)
}

fn credential_status_dto(
    status: ncm_service::credential_store::CredentialStatus,
) -> CredentialStatusDto {
    use ncm_service::credential_store::CredentialStatus as S;
    let kind = match &status {
        S::Secure { .. } => "secure",
        S::PlaintextConsented { .. } => "plaintext_consented",
        S::PlaintextFallback { .. } => "plaintext_fallback",
    };
    CredentialStatusDto {
        kind: kind.to_string(),
        backend: status.backend_name().to_string(),
        migrated: status.migrated(),
        note: status.note(),
    }
}

/// 当前凭据后端状态(设置页/排障用): 是否有安全后端、旧明文是否已迁移.
pub fn credential_status() -> Result<CredentialStatusDto, FfiError> {
    let guard = core()?.lock().map_err(FfiError::from)?;
    Ok(credential_status_dto(guard.credential_status()))
}

/// 用户明确同意/撤销"0600 明文回退". 同意后立刻重建后端并补跑迁移.
///
/// 只在没有系统钥匙串的平台(Android/Linux 的 P1/P2 未落地前)才有意义;
/// Windows 走 DPAPI, 不需要这个开关。
// UI 未用(2026-11-20 审计 7.2: 在 ui/lib + ui/test 全量 grep 零命中, 只存在于生成的 api.dart),
// 候选删除; 先 #[frb(ignore)] 从 Dart API 摘掉, 观察一个版本无回归后再删 Rust 侧。
#[frb(ignore)]
pub fn consent_plaintext_storage(consent: bool) -> Result<CredentialStatusDto, FfiError> {
    let mut guard = core()?.lock().map_err(FfiError::from)?;
    guard
        .set_plaintext_consent(consent)
        .map_err(FfiError::from)?;
    Ok(credential_status_dto(guard.credential_status()))
}

/// Android Keystore 桥(lane p1, 方案 B): Keystore 里的一条凭据.
/// key 为 CredentialKey::id() 形式("session" / "account:uid").
#[derive(Debug, Clone)]
pub struct CredentialEntryDto {
    pub key: String,
    pub value: String,
}

/// 一条待 Dart 落 Keystore 的操作: op = "put"(带 value) | "remove".
#[derive(Debug, Clone)]
pub struct CredentialOpDto {
    pub op: String,
    pub key: String,
    pub value: String,
}

/// Android 启动时、rust.init 之前调用: 用 Keystore 现存条目激活凭据桥.
/// 幂等(重复调用合并); 未激活时 open_backend 的 android 分支走既有同意门.
/// 见 docs/android-keystore-wiring-design.md.
pub fn credential_restore(entries: Vec<CredentialEntryDto>) -> Result<(), FfiError> {
    let converted: Vec<(String, String)> = entries.into_iter().map(|e| (e.key, e.value)).collect();
    ncm_service::credential_channel::activate(converted);
    Ok(())
}

/// Dart drain: 拉走(并清空)待落 Keystore 的操作. 同 key 只剩最终态.
/// 拉取失败 = 丢该条凭据(下次启动重登), 不影响本会话内存态.
pub fn credential_pending_writes() -> Result<Vec<CredentialOpDto>, FfiError> {
    use ncm_service::credential_channel::CredOp;
    Ok(ncm_service::credential_channel::take_pending()
        .into_iter()
        .map(|op| match op {
            CredOp::Put { key, value } => CredentialOpDto {
                op: "put".into(),
                key,
                value,
            },
            CredOp::Remove { key } => CredentialOpDto {
                op: "remove".into(),
                key,
                value: String::new(),
            },
        })
        .collect())
}

/// 手机号+验证码登录 ①(网页登录通道 weapi): 发短信验证码.
///
/// 与扫码同一族(网页登录), 不走 App 原生登录族; 命中交互式风控时错误带
/// `[riskControl]` 前缀(官方 code 8821), UI 应引导改用扫码.
pub async fn login_sms_send(phone: String, country_code: String) -> Result<SmsCodeSent, FfiError> {
    let provider = {
        let guard = core()?.lock().map_err(FfiError::from)?;
        guard.netease.clone()
    };
    use ncm_provider::AccountProvider;
    provider
        .login_sms_send(&phone, &country_code)
        .await
        .map_err(FfiError::from)
}

/// 手机号+验证码登录 ②: 校验验证码. 成功时顺带把凭据合并落盘, Dart 侧再同步账号资料.
pub async fn login_sms_verify(
    phone: String,
    code: String,
    country_code: String,
) -> Result<PhoneLoginResult, FfiError> {
    let provider = {
        let guard = core()?.lock().map_err(FfiError::from)?;
        guard.netease.clone()
    };
    use ncm_provider::AccountProvider;
    let outcome = provider
        .login_sms_verify(&phone, &code, &country_code)
        .await
        .map_err(FfiError::from)?;
    let mut guard = core()?.lock().map_err(FfiError::from)?;
    guard
        .apply_login_cookie(&outcome.cookie)
        .map_err(FfiError::from)?;
    Ok(outcome.result)
}

/// 当前会话是否已登录(装了 MUSIC_U)。
///
/// 给「上游对未登录和空数据都回 200 + 空列表」的场景用(如他人常听排行:
/// 匿名请求 play/record 只回 `{"code":200,"allData":[]}`), UI 靠它把
/// 「登录后可见」与「对方真的没有记录」分开, 而不是都画成空列表。
/// 纯内存判据(不联网), 因此标 sync: UI 可以在 initState/首帧直接读,
/// 不必为"要不要显示登录后可见"先转一圈异步。
#[frb(sync)]
pub fn logged_in() -> Result<bool, FfiError> {
    let guard = core()?.lock().map_err(FfiError::from)?;
    Ok(guard.session.is_logged_in())
}

/// 已记住的账号列表(只含凭据, 指纹共享)
pub fn accounts() -> Result<Vec<AccountDto>, FfiError> {
    let guard = core()?.lock().map_err(FfiError::from)?;
    accounts_of(&guard)
}

/// 登录后/启动时调用: 拉一次账号资料并记进账号簿.
/// 失败(离线/风控)不影响已登录状态, UI 只当作"没有昵称"。
pub async fn account_sync_active() -> Result<AccountDto, FfiError> {
    let logged_in = {
        let guard = core()?.lock().map_err(FfiError::from)?;
        guard.session.is_logged_in()
    };
    if !logged_in {
        return Err(FfiError::auth("未登录"));
    }
    let profile = routed_call(Capability::Profile, |provider| {
        Box::pin(async move { provider.profile().await })
    })
    .await?;
    let mut guard = core()?.lock().map_err(FfiError::from)?;
    guard.remember_account(&profile).map_err(FfiError::from)?;
    Ok(AccountDto {
        user_id: profile.user_id,
        nickname: profile.nickname,
        avatar_url: profile.avatar_url,
        active: true,
        vip: profile.vip,
    })
}

/// 切换到账号簿里的某个账号(不重新登录)
pub async fn account_switch(user_id: u64) -> Result<bool, FfiError> {
    {
        let mut guard = core()?.lock().map_err(FfiError::from)?;
        if !guard.switch_account(user_id).map_err(FfiError::from)? {
            return Ok(false);
        }
    }
    // 切完顺手同步一次昵称/头像(失败不影响切换)
    let _ = account_sync_active().await;
    Ok(true)
}

/// 从账号簿移除某个账号(不影响当前登录态, 只是忘掉它的凭据)
pub fn account_remove(user_id: u64) -> Result<bool, FfiError> {
    let mut guard = core()?.lock().map_err(FfiError::from)?;
    let before = guard.accounts().map_err(FfiError::from)?.accounts.len();
    let book = guard.forget_account(user_id).map_err(FfiError::from)?;
    Ok(book.accounts.len() < before)
}

/// 导入登录 cookie(手机端/浏览器导出), 与设备指纹合并后持久化.
///
/// **必须先在传入的 cookie 里看到 MUSIC_U 才合并**:
/// 之前无条件把 incoming 并进 existing 再问 is_logged_in —— 于是"已经有一个有效账号"
/// 时, 用户在登录页直接关闭/登录失败(传回来的是空的或只有设备指纹的 cookie),
/// 旧 MUSIC_U 仍在 session 里 ⇒ is_logged_in() 恒为 true ⇒ UI 弹「登录成功, 账号已记住」。
/// 这是用户反馈的「关闭登录页也提示登录成功」的根因。
pub fn login_with_cookie(cookie: String) -> Result<bool, FfiError> {
    let incoming = cookie.trim();
    if !cookie_has_music_u(incoming) {
        // 不合并、不改会话: 明确告诉 UI 这次没有登录态
        return Ok(false);
    }
    let mut guard = core()?.lock().map_err(FfiError::from)?;
    let merged = ncm_service::identity::merge_device_cookie(
        &guard.session.cookie,
        incoming,
        &guard.session.device_id,
    );
    let mut next = guard.session.clone();
    next.cookie = merged;
    guard.apply_session(next).map_err(FfiError::from)?;
    Ok(guard.session.is_logged_in())
}

// 登录 cookie 判据(原在 api.rs 末尾, 按域归到登录): 这次拿到的 cookie 里真有 MUSIC_U 才算登录。
/// 传入的 cookie 里是否真的有非空 MUSIC_U("MUSIC_U=xxx")。
///
/// 单独抽出来是为了有一处可单测的判据: 登录成功与否只看**这次**拿到的凭据,
/// 不看会话里之前那个账号。
fn cookie_has_music_u(cookie: &str) -> bool {
    cookie.split(';').any(|pair| {
        let pair = pair.trim();
        pair.strip_prefix("MUSIC_U=")
            .is_some_and(|v| !v.trim().is_empty())
    })
}

#[cfg(test)]
mod login_cookie_tests {
    use super::cookie_has_music_u;

    #[test]
    fn only_real_music_u_counts() {
        assert!(!cookie_has_music_u(""));
        assert!(!cookie_has_music_u("MUSIC_A=abc; NMTID=x"));
        // 空值不算登录(登录页关闭时常见: 只有设备指纹)
        assert!(!cookie_has_music_u("MUSIC_U=; __csrf=1"));
        assert!(cookie_has_music_u("MUSIC_U=abc123; __csrf=1"));
        assert!(cookie_has_music_u("a=1; MUSIC_U=abc123"));
    }
}
