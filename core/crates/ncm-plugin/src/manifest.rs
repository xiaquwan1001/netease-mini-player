//! 插件清单(`manifest.json`): 最小字段集 + 校验(纯数据, 无 I/O).
//!
//! # 磁盘形状
//!
//! ```json
//! {
//!   "id": "demo",
//!   "name": "Demo 插件",
//!   "version": "1.0.0",
//!   "apiVersion": 1,
//!   "entry": "index.js",
//!   "permissions": {
//!     "lxEvents": ["musicUrl", "search"],
//!     "requestDomains": ["api.example.com", "*.example.org"]
//!   }
//! }
//! ```
//!
//! - `id`: 插件身份, **同时是目录名**(`<root>/<plugin-id>/`), 所以它必须是路径安全的名字;
//! - `entry`: 单个文件名(不是路径), 以 `.js` 结尾, 必须是插件自己目录下的一层文件;
//! - `permissions`: 可选. `lxEvents` 声明要用 `lx.on` 注册哪些事件, `requestDomains`
//!   声明出站域名白名单;
//! - `apiVersion`: 可选(缺失 = 契约 v1 时期的老清单, 按 1 处理). 与宿主支持的
//!   [`SUPPORTED_API_MIN`]..=[`SUPPORTED_API_MAX`] 协商: 不在区间内 ⇒ 装载前就拒, 文案带区间;
//!   判定是纯函数 [`check_api_version`], 边界用例见测试 `api_version_boundaries`.
//!
//! # 校验纪律
//!
//! 1. **失败必须可读**: 所有错误都是 [`ManifestError`](带字段名 + 中文原因), **绝不 panic** ——
//!    一个坏清单只让这一个插件进入错误态, 不影响其它插件, 也不该崩 App;
//! 2. **不信任清单**: 目录管理(`ncm-service` 的 `PluginManager`)会再做一遍 canonicalize 检查,
//!    这里的规则只是第一道闸(判据表见 `manager.rs` 头注释);
//! 3. **id 不许出现点号/分隔符/大写**: Windows/macOS 的文件系统大小写不敏感, `Foo` 与 `foo`
//!    会撞成同一个目录; 点号则直接开出 `..` 逃逸的口子.
//!
//! 权限**已生效**: `PluginManager` 为每个插件把宿主 transport 包进
//! [`policy::GuardedTransport`](crate::policy::GuardedTransport), `requestDomains` 之外的出站
//! **在发出去之前**就被拒(未声明 = 全拒, 见 `crate::policy`). 但白名单只到主机名粒度, 它**不是**
//! 全部安全边界 —— 另一半仍在沙箱(无 fs/无 fetch, 只有宿主注入的 `lx.request`)与
//! `PluginManager` 的路径规范化.

use std::fmt;

use serde::Deserialize;

/// 插件目录里固定使用的清单文件名.
pub const MANIFEST_FILE: &str = "manifest.json";
/// `id` 长度上限(对齐常见插件 id 习惯, 也为目录名留余量).
pub const MAX_ID_LEN: usize = 64;
/// `name` 长度上限(字符数).
pub const MAX_NAME_LEN: usize = 64;
/// `entry` 长度上限(字节).
pub const MAX_ENTRY_LEN: usize = 128;
/// 声明事件的条数上限.
pub const MAX_EVENTS: usize = 8;
/// 声明域名的条数上限.
pub const MAX_DOMAINS: usize = 16;
/// 本宿主实现的插件契约 API 版本.
pub const HOST_API_VERSION: u32 = 1;
/// 能接受的最低 `apiVersion`(低于它 = 插件太旧, 用的是本宿主已不实现的契约).
pub const SUPPORTED_API_MIN: u32 = 1;
/// 能接受的最高 `apiVersion`(高于它 = 插件太新, 用了本宿主还没有的能力).
pub const SUPPORTED_API_MAX: u32 = HOST_API_VERSION;
/// 清单里没写 `apiVersion` 时的口径: 契约 v1 时期的老清单按版本 1 处理(不是拒绝).
pub const LEGACY_API_VERSION: u32 = 1;
/// `lx.on` 认识的事件名(契约 v1, 见 `prelude.js` 的 `EVENT_NAMES`).
pub const KNOWN_EVENTS: &[&str] = &["request", "inited", "musicUrl", "lyric", "search"];

/// 一个插件的清单(已解析; 校验走 [`PluginManifest::validate`]).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PluginManifest {
    pub id: String,
    pub name: String,
    pub version: String,
    /// 契约 API 版本(可选: 缺失 = 老清单, 按 [`LEGACY_API_VERSION`] 处理).
    ///
    /// 用自定义反序列化而不是裸 `u32`: 类型不对(`"1.0"` / `1.5` / `-1`)要报出**字段名**,
    /// 而不是一句 serde 的 "invalid type". 区间判定在 [`check_api_version`].
    #[serde(default, rename = "apiVersion", deserialize_with = "de_api_version")]
    pub api_version: Option<u32>,
    /// 入口脚本文件名(单层, 以 `.js` 结尾).
    pub entry: String,
    #[serde(default)]
    pub permissions: Permissions,
}

/// 权限声明(全部可选; 空 `lxEvents` = 不注册任何事件, 空 `requestDomains` = 未声明白名单).
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Permissions {
    /// `lx.on` 事件名(必须出自 [`KNOWN_EVENTS`]).
    #[serde(default)]
    pub lx_events: Vec<String>,
    /// 出站域名白名单(形如 `api.example.com` 或 `*.example.com`).
    ///
    /// 匹配语义见 [`DomainPolicy`](crate::DomainPolicy): `*.host` 同时覆盖 `host` **自身**与其任意
    /// 层级子域, `host` 只覆盖它自己(不做后缀匹配). 空列表 = 该插件出站全拒.
    #[serde(default)]
    pub request_domains: Vec<String>,
}

/// 清单校验失败(字段名 + 可读原因, 不是 panic 也不是裸 serde 报错).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestError {
    /// 出错的字段路径(`id` / `permissions.lxEvents[1]` ...); 空串 = 整份清单.
    field: String,
    reason: String,
}

impl ManifestError {
    fn new(field: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            field: field.into(),
            reason: reason.into(),
        }
    }

    /// 整份文件的错误(JSON 语法/字段类型).
    fn whole(reason: impl Into<String>) -> Self {
        Self::new(String::new(), reason)
    }

    pub fn field(&self) -> &str {
        &self.field
    }

    pub fn reason(&self) -> &str {
        &self.reason
    }
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.field.is_empty() {
            write!(f, "插件清单无效: {}", self.reason)
        } else {
            write!(f, "插件清单字段 `{}` 无效: {}", self.field, self.reason)
        }
    }
}

impl std::error::Error for ManifestError {}

impl PluginManifest {
    /// 解析 + 校验(一次到位: 调用方拿到的 [`PluginManifest`] 一定是合法的).
    pub fn parse(text: &str) -> Result<Self, ManifestError> {
        let manifest: Self = serde_json::from_str(text).map_err(|e| {
            ManifestError::whole(format!(
                "不是合法 JSON 或字段类型不对(第 {} 行第 {} 列): {e}",
                e.line(),
                e.column()
            ))
        })?;
        manifest.validate()?;
        Ok(manifest)
    }

    /// 逐字段校验; 返回第一个错误(信息足够定位, 不必一次报全).
    pub fn validate(&self) -> Result<(), ManifestError> {
        validate_id(&self.id)?;
        validate_name(&self.name)?;
        validate_version(&self.version)?;
        // 版本协商在**装载前**做: 不兼容的清单直接是错误态, 走不到建沙箱那一步.
        check_api_version(self.api_version)?;
        validate_entry(&self.entry)?;
        validate_permissions(&self.permissions)
    }
}

impl PluginManifest {
    /// 协商后的生效 `apiVersion`([`check_api_version`] 的结构化入口).
    pub fn resolve_api_version(&self) -> Result<u32, ManifestError> {
        check_api_version(self.api_version)
    }
}

/// 版本协商(纯函数, 不碰盘): 声明的 `apiVersion` 与宿主支持的区间是否兼容.
///
/// - `None`(清单里没写) ⇒ 按 [`LEGACY_API_VERSION`] 处理, 但仍然协商一遍;
/// - 返回**生效版本**; 不在 [`SUPPORTED_API_MIN`]..=[`SUPPORTED_API_MAX`] 内 ⇒
///   `ManifestError{field: "apiVersion"}`, 文案里带出所需区间(调用方原样展示给用户).
pub fn check_api_version(declared: Option<u32>) -> Result<u32, ManifestError> {
    let version = declared.unwrap_or(LEGACY_API_VERSION);
    if version < SUPPORTED_API_MIN {
        return Err(ManifestError::new(
            "apiVersion",
            format!(
                "`{version}` 太旧: 本宿主需要的区间是 {SUPPORTED_API_MIN}..={SUPPORTED_API_MAX}。\
                 请升级插件到兼容版本"
            ),
        ));
    }
    if version > SUPPORTED_API_MAX {
        return Err(ManifestError::new(
            "apiVersion",
            format!(
                "`{version}` 太新: 本宿主需要的区间是 {SUPPORTED_API_MIN}..={SUPPORTED_API_MAX}。\
                 请升级 App(或换用兼容版本的插件)"
            ),
        ));
    }
    Ok(version)
}

/// `apiVersion` 的反序列化: 只收整数, 其它类型给出**带字段名**的可读错误.
fn de_api_version<'de, D>(deserializer: D) -> Result<Option<u32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as _;
    match Option::<serde_json::Value>::deserialize(deserializer)? {
        None => Ok(None),
        Some(serde_json::Value::Number(number)) => number
            .as_u64()
            .and_then(|value| u32::try_from(value).ok())
            .map(Some)
            .ok_or_else(|| {
                D::Error::custom(format!(
                    "字段 `apiVersion` 必须是 0..={} 的整数(如 1), 实际 `{number}`",
                    u32::MAX
                ))
            }),
        Some(other) => Err(D::Error::custom(format!(
            "字段 `apiVersion` 必须是整数(如 1), 实际 `{other}`"
        ))),
    }
}

/// `id` 规则: `[a-z0-9][a-z0-9_-]{0,MAX_ID_LEN-1}`.
///
/// 有意只收小写 ASCII(理由见模块头注释第 3 条), 也**不接受** `.` / `/` / 反斜杠 / 空格.
/// 目录管理用它做目录名校验(目录名必须等于清单 `id`).
pub fn validate_id(id: &str) -> Result<(), ManifestError> {
    if id.is_empty() {
        return Err(ManifestError::new("id", "不能为空"));
    }
    if id.len() > MAX_ID_LEN {
        return Err(ManifestError::new(
            "id",
            format!("长度 {} 超过上限 {MAX_ID_LEN}", id.len()),
        ));
    }
    for (idx, ch) in id.chars().enumerate() {
        let ok = if idx == 0 {
            ch.is_ascii_lowercase() || ch.is_ascii_digit()
        } else {
            ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' || ch == '-'
        };
        if !ok {
            return Err(ManifestError::new(
                "id",
                format!(
                    "第 {} 个字符 `{ch}` 非法(只允许小写字母/数字/下划线/短横, 且首字符必须是字母或数字)",
                    idx + 1
                ),
            ));
        }
    }
    Ok(())
}

fn validate_name(name: &str) -> Result<(), ManifestError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(ManifestError::new("name", "不能为空"));
    }
    if trimmed != name {
        return Err(ManifestError::new("name", "首尾不能有空白"));
    }
    let count = name.chars().count();
    if count > MAX_NAME_LEN {
        return Err(ManifestError::new(
            "name",
            format!("长度 {count} 个字符超过上限 {MAX_NAME_LEN}"),
        ));
    }
    if name.chars().any(|c| c.is_control()) {
        return Err(ManifestError::new("name", "不能包含控制字符"));
    }
    Ok(())
}

/// `version` 规则: `主.次.修订`(每段十进制数字, 可选 `-预发布` 尾巴).
fn validate_version(version: &str) -> Result<(), ManifestError> {
    let core_part = version.split_once('-').map_or(version, |(head, _)| head);
    let segments: Vec<&str> = core_part.split('.').collect();
    if segments.len() != 3 {
        return Err(ManifestError::new(
            "version",
            format!("`{version}` 不是 `主.次.修订` 三段式"),
        ));
    }
    for segment in &segments {
        if segment.is_empty() || !segment.bytes().all(|b| b.is_ascii_digit()) {
            return Err(ManifestError::new(
                "version",
                format!("`{version}` 的段 `{segment}` 不是十进制数字"),
            ));
        }
    }
    if let Some((_, tail)) = version.split_once('-') {
        let ok = !tail.is_empty()
            && tail
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
        if !ok {
            return Err(ManifestError::new(
                "version",
                format!("`{version}` 的预发布尾巴只允许字母/数字/点/短横"),
            ));
        }
    }
    Ok(())
}

/// 入口脚本规则: **一个文件名**, 不许带路径分隔符 / 不许以点开头 / 必须以 `.js` 结尾.
///
/// 这是"入口脚本只许读插件自己目录"的第一道闸: 名字本身就是单层文件名时, 拼接后不可能出现
/// `..` 这种段(目录管理层还会再过一遍 canonicalize, 见 `manager.rs`).
pub fn validate_entry(entry: &str) -> Result<(), ManifestError> {
    if entry.is_empty() {
        return Err(ManifestError::new("entry", "不能为空"));
    }
    if entry.len() > MAX_ENTRY_LEN {
        return Err(ManifestError::new(
            "entry",
            format!("长度 {} 字节超过上限 {MAX_ENTRY_LEN}", entry.len()),
        ));
    }
    if entry.contains('/') || entry.contains('\\') {
        return Err(ManifestError::new(
            "entry",
            format!("`{entry}` 含路径分隔符(入口必须是插件目录下的一层文件名)"),
        ));
    }
    if entry.starts_with('.') {
        return Err(ManifestError::new(
            "entry",
            format!("`{entry}` 以点开头(`.`/`..` 与隐藏文件都不接受)"),
        ));
    }
    if entry.contains(':') {
        return Err(ManifestError::new(
            "entry",
            format!("`{entry}` 含冒号(盘符风格的绝对路径不接受)"),
        ));
    }
    if !entry.ends_with(".js") {
        return Err(ManifestError::new(
            "entry",
            format!("`{entry}` 不是 `.js` 脚本"),
        ));
    }
    if let Some(ch) = entry
        .chars()
        .find(|c| !(c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')))
    {
        return Err(ManifestError::new(
            "entry",
            format!("`{entry}` 含非法字符 `{ch}`(只允许字母/数字/点/下划线/短横)"),
        ));
    }
    Ok(())
}

fn validate_permissions(perms: &Permissions) -> Result<(), ManifestError> {
    if perms.lx_events.len() > MAX_EVENTS {
        return Err(ManifestError::new(
            "permissions.lxEvents",
            format!(
                "声明了 {} 个事件, 超过上限 {MAX_EVENTS}",
                perms.lx_events.len()
            ),
        ));
    }
    let mut seen: Vec<&str> = Vec::with_capacity(perms.lx_events.len());
    for (idx, event) in perms.lx_events.iter().enumerate() {
        if !KNOWN_EVENTS.contains(&event.as_str()) {
            return Err(ManifestError::new(
                format!("permissions.lxEvents[{idx}]"),
                format!("`{event}` 不是已知事件(可用: {})", KNOWN_EVENTS.join(", ")),
            ));
        }
        if seen.contains(&event.as_str()) {
            return Err(ManifestError::new(
                format!("permissions.lxEvents[{idx}]"),
                format!("`{event}` 重复声明"),
            ));
        }
        seen.push(event.as_str());
    }

    if perms.request_domains.len() > MAX_DOMAINS {
        return Err(ManifestError::new(
            "permissions.requestDomains",
            format!(
                "声明了 {} 个域名, 超过上限 {MAX_DOMAINS}",
                perms.request_domains.len()
            ),
        ));
    }
    for (idx, domain) in perms.request_domains.iter().enumerate() {
        if let Err(reason) = validate_domain(domain) {
            return Err(ManifestError::new(
                format!("permissions.requestDomains[{idx}]"),
                format!("`{domain}`: {reason}"),
            ));
        }
    }
    Ok(())
}

/// 域名白名单项: `host` 或 `*.host`, 不带 scheme/端口/路径/空白.
fn validate_domain(domain: &str) -> Result<(), String> {
    if domain.is_empty() {
        return Err("不能为空".to_string());
    }
    if domain.len() > 253 {
        return Err("长度超过 253".to_string());
    }
    if domain.contains("://") || domain.contains('/') {
        return Err("只写主机名, 不要带 scheme 或路径".to_string());
    }
    if domain.contains(':') {
        return Err("不要带端口".to_string());
    }
    if domain.chars().any(|c| c.is_whitespace()) {
        return Err("不能含空白".to_string());
    }
    let body = domain.strip_prefix("*.").unwrap_or(domain);
    if body.is_empty() {
        return Err("通配符后面必须跟主机名".to_string());
    }
    if body
        .chars()
        .any(|c| !(c.is_ascii_alphanumeric() || c == '.' || c == '-'))
    {
        return Err("只允许字母/数字/点/短横".to_string());
    }
    if body.starts_with('.') || body.ends_with('.') || body.contains("..") {
        return Err("标签不能为空(检查首尾与连续的点)".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn good() -> String {
        r#"{
            "id": "demo-lx",
            "name": "Demo 插件",
            "version": "1.2.3",
            "apiVersion": 1,
            "entry": "index.js",
            "permissions": { "lxEvents": ["musicUrl"], "requestDomains": ["api.example.com", "*.example.org"] }
        }"#
        .to_string()
    }

    fn with_entry(entry: &str) -> String {
        format!(
            r#"{{"id":"a1","name":"A","version":"0.0.1","entry":"{}"}}"#,
            entry
        )
    }

    #[test]
    fn parses_minimal_manifest() {
        let manifest = PluginManifest::parse(&good()).expect("合法清单");
        assert_eq!(manifest.id, "demo-lx");
        assert_eq!(manifest.name, "Demo 插件");
        assert_eq!(manifest.entry, "index.js");
        assert_eq!(manifest.permissions.lx_events, vec!["musicUrl".to_string()]);
        assert_eq!(manifest.permissions.request_domains.len(), 2);
    }

    #[test]
    fn permissions_are_optional() {
        let text = r#"{"id":"a1","name":"A","version":"0.0.1","entry":"main.js"}"#;
        let manifest = PluginManifest::parse(text).expect("无 permissions 也应通过");
        assert!(manifest.permissions.lx_events.is_empty());
    }

    #[test]
    fn bad_json_reports_line_and_column() {
        let err = PluginManifest::parse("{ oops").expect_err("应报错");
        assert!(err.field().is_empty());
        assert!(err.to_string().contains("第 1 行"), "{err}");
    }

    #[test]
    fn id_rules_are_readable() {
        let mut manifest = PluginManifest::parse(&good()).expect("基线");
        for bad in ["", "Demo", "a b", "a/b", "..", "a.b", "-lead"] {
            manifest.id = bad.to_string();
            let err = manifest.validate().expect_err(bad);
            assert_eq!(err.field(), "id", "{bad}");
            assert!(!err.reason().is_empty());
        }
        manifest.id = "a".repeat(MAX_ID_LEN + 1);
        assert!(manifest.validate().is_err());
        manifest.id = "a".repeat(MAX_ID_LEN);
        assert!(manifest.validate().is_ok(), "64 字符是上限内");
    }

    #[test]
    fn entry_path_escape_is_rejected_at_manifest_level() {
        let mut manifest = PluginManifest::parse(&good()).expect("基线");
        for bad in [
            "../evil.js",
            "sub/../../evil.js",
            "sub/evil.js",
            "/abs/evil.js",
            ".hidden.js",
            "index.ts",
            "C:evil.js",
            "has space.js",
        ] {
            manifest.entry = bad.to_string();
            let err = manifest.validate().expect_err(bad);
            assert_eq!(err.field(), "entry", "{bad}");
        }
        assert!(PluginManifest::parse(&with_entry("index.js")).is_ok());
        assert!(PluginManifest::parse(&with_entry("\\..\\evil.js")).is_err());
    }

    #[test]
    fn version_rules() {
        let mut manifest = PluginManifest::parse(&good()).expect("基线");
        for bad in ["1.0", "1.0.0.0", "v1.0.0", "1.0.x", "1..0", "1.0.0-"] {
            manifest.version = bad.to_string();
            assert!(manifest.validate().is_err(), "{bad} 应被拒绝");
        }
        for ok in ["1.0.0", "10.20.30", "1.0.0-beta.1"] {
            manifest.version = ok.to_string();
            assert!(manifest.validate().is_ok(), "{ok} 应通过");
        }
    }

    #[test]
    fn api_version_boundaries() {
        // 纯函数边界: 更低 / 恰好 / 更高 / 缺失.
        assert_eq!(
            check_api_version(None).expect("缺失 = 老清单, 按 v1 兼容"),
            LEGACY_API_VERSION
        );
        assert_eq!(check_api_version(Some(1)).expect("恰好"), HOST_API_VERSION);
        let too_old = SUPPORTED_API_MIN - 1;
        let err = check_api_version(Some(too_old)).expect_err("更低应拒绝");
        assert_eq!(err.field(), "apiVersion");
        assert!(err.reason().contains("1..=1"), "文案必须带所需区间: {err}");
        assert!(err.reason().contains("太旧"), "{err}");
        for too_new in [SUPPORTED_API_MAX + 1, 99] {
            let err = check_api_version(Some(too_new)).expect_err("更高应拒绝");
            assert_eq!(err.field(), "apiVersion");
            assert!(err.reason().contains("1..=1"), "文案必须带所需区间: {err}");
            assert!(err.reason().contains("太新"), "{err}");
        }
    }

    #[test]
    fn api_version_is_parsed_and_rejected_through_manifest() {
        let with_version = |raw: &str| {
            format!(
                r#"{{"id":"a1","name":"A","version":"0.0.1","apiVersion":{raw},"entry":"main.js"}}"#
            )
        };
        // 合法: 恰好 = 1; 缺失也合法(老清单).
        let manifest = PluginManifest::parse(&with_version("1")).expect("apiVersion 1");
        assert_eq!(manifest.api_version, Some(1));
        assert_eq!(manifest.resolve_api_version().expect("兼容"), 1);
        let legacy = PluginManifest::parse(&with_version("null")).expect("显式 null = 缺失");
        assert_eq!(legacy.api_version, None);
        let legacy =
            PluginManifest::parse(r#"{"id":"a1","name":"A","version":"0.0.1","entry":"main.js"}"#)
                .expect("缺字段 = 老清单");
        assert_eq!(legacy.api_version, None);
        assert_eq!(
            legacy.resolve_api_version().expect("老清单按 v1"),
            LEGACY_API_VERSION
        );

        // 区间外: 与其它字段错误同一种形态(字段名 + 原因 + 区间).
        for raw in ["2", "0", "99"] {
            let err = PluginManifest::parse(&with_version(raw)).expect_err(raw);
            assert_eq!(err.field(), "apiVersion", "{raw}: {err}");
            assert!(err.reason().contains("1..=1"), "{raw}: {err}");
        }
        // 类型非法: 报出字段名(不是裸 serde 的 invalid type).
        for raw in [r#""1.0""#, "1.5", "-1", "true", "[]"] {
            let err = PluginManifest::parse(&with_version(raw)).expect_err(raw);
            assert!(err.to_string().contains("apiVersion"), "{raw}: {err}");
        }
    }

    #[test]
    fn unknown_event_lists_known_names() {
        let text = r#"{"id":"a1","name":"A","version":"0.0.1","entry":"main.js",
            "permissions":{"lxEvents":["bogus"]}}"#;
        let err = PluginManifest::parse(text).expect_err("未知事件应报错");
        assert_eq!(err.field(), "permissions.lxEvents[0]");
        assert!(err.reason().contains("musicUrl"), "{err}");
    }

    #[test]
    fn lyric_event_is_known() {
        // `lyric` 是宿主事件名(歌词能力), 清单里可以声明; `request` 仍是上游单入口.
        let text = r#"{"id":"a1","name":"A","version":"0.0.1","entry":"main.js",
            "permissions":{"lxEvents":["request","lyric"]}}"#;
        assert!(PluginManifest::parse(text).is_ok());
    }

    #[test]
    fn duplicate_event_is_rejected() {
        let text = r#"{"id":"a1","name":"A","version":"0.0.1","entry":"main.js",
            "permissions":{"lxEvents":["search","search"]}}"#;
        let err = PluginManifest::parse(text).expect_err("重复事件应报错");
        assert!(err.reason().contains("重复"), "{err}");
    }

    #[test]
    fn domain_rules() {
        for bad in [
            "https://a.com",
            "a.com/x",
            "a.com:443",
            "a b.com",
            "*.",
            ".a.com",
            "a..com",
            "a.com.",
        ] {
            let text = format!(
                r#"{{"id":"a1","name":"A","version":"0.0.1","entry":"main.js","permissions":{{"requestDomains":["{bad}"]}}}}"#
            );
            assert!(PluginManifest::parse(&text).is_err(), "{bad} 应被拒绝");
        }
        let text = r#"{"id":"a1","name":"A","version":"0.0.1","entry":"main.js","permissions":{"requestDomains":["api.example.com","*.example.org"]}}"#;
        assert!(PluginManifest::parse(text).is_ok());
    }

    #[test]
    fn name_rules() {
        let mut manifest = PluginManifest::parse(&good()).expect("基线");
        manifest.name = "  ".to_string();
        assert!(manifest.validate().is_err());
        manifest.name = " A".to_string();
        assert!(manifest.validate().is_err());
        manifest.name = "A\nB".to_string();
        assert!(manifest.validate().is_err());
    }
}
