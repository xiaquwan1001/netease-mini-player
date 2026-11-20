//! `AccountProvider` — 登录/账号资料/关注关系。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{
    FollowCount, PhoneLoginOutcome, Profile, ProfileDetail, QrLoginKey, QrLoginOutcome,
    SmsCodeSent, UserItem,
};
pub trait AccountProvider: Send + Sync {
    /// 当前登录账号的资料(uid/昵称/VIP). 未登录或不支持时返回 Unsupported.
    fn profile<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Profile>> {
        Box::pin(async { Err(ProviderError::unsupported("no profile")) })
    }

    /// 申请一个扫码登录二维码(官方网页登录同一套通道). 默认不支持.
    ///
    /// 桌面端用它替代 WebView: 不必读取浏览器的 HttpOnly cookie, 凭据由轮询响应下发.
    fn login_qr_create<'a>(&'a self) -> BoxFuture<'a, ProviderResult<QrLoginKey>> {
        Box::pin(async { Err(ProviderError::unsupported("no qr login")) })
    }

    /// 轮询扫码结果. 成功(Confirmed)时带登录凭据, 由调用方合并落盘.
    ///
    /// `secure_captcha`: 易盾安全验证句柄(官方 code 8821 场景). 官方 PC 客户端每轮都带
    /// (初值空串), 验证通过后回填; 没有易盾组件时传 `None` 即可, 服务端对缺省是宽容的.
    fn login_qr_check<'a>(
        &'a self,
        _key: &'a str,
        _secure_captcha: Option<&'a str>,
    ) -> BoxFuture<'a, ProviderResult<QrLoginOutcome>> {
        Box::pin(async { Err(ProviderError::unsupported("no qr login")) })
    }

    /// 手机号+验证码登录 ①: 给手机号发短信验证码. 默认不支持.
    ///
    /// 走网页登录通道(weapi /api/sms/captcha/sent); 命中交互式风控时返回
    /// `ProviderErrorKind::RiskControl`(官方 code 8821), 调用方应引导用户改用扫码登录.
    fn login_sms_send<'a>(
        &'a self,
        _phone: &'a str,
        _country_code: &'a str,
    ) -> BoxFuture<'a, ProviderResult<SmsCodeSent>> {
        Box::pin(async { Err(ProviderError::unsupported("no sms login")) })
    }

    /// 手机号+验证码登录 ②: 校验验证码. 成功时带登录凭据, 由调用方合并落盘.
    fn login_sms_verify<'a>(
        &'a self,
        _phone: &'a str,
        _code: &'a str,
        _country_code: &'a str,
    ) -> BoxFuture<'a, ProviderResult<PhoneLoginOutcome>> {
        Box::pin(async { Err(ProviderError::unsupported("no sms login")) })
    }

    /// 当前账号资料详情(个人主页背景图/头像/签名/关注数)
    fn profile_detail(&self) -> BoxFuture<'_, ProviderResult<ProfileDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no profile detail")) })
    }

    /// 修改个人简介(签名, 需登录); 返回更新后的资料. 默认不支持.
    fn update_signature(&self, _signature: String) -> BoxFuture<'_, ProviderResult<ProfileDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no update signature")) })
    }

    /// 任意用户的公开资料(不需要登录). 用于"他人主页"(听众/粉丝列表点进去).
    ///
    /// 与 [AccountProvider::profile_detail](只读当前登录账号)分开: 那个要先 `uid()`, 未登录直接报错.
    fn user_profile<'a>(&'a self, _uid: u64) -> BoxFuture<'a, ProviderResult<ProfileDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no user profile")) })
    }

    /// 某人关注的人(不传 uid 用当前账号)
    fn user_follows(
        &self,
        _uid: u64,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no user follows")) })
    }

    /// 某人的粉丝
    fn user_followeds(
        &self,
        _uid: u64,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no user followeds")) })
    }

    /// 关注/取关某人(需要登录)
    fn set_follow(&self, _uid: u64, _follow: bool) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no follow")) })
    }

    /// 我的关注/粉丝数
    fn follow_counts(&self) -> BoxFuture<'_, ProviderResult<FollowCount>> {
        Box::pin(async { Err(ProviderError::unsupported("no follow counts")) })
    }
}
