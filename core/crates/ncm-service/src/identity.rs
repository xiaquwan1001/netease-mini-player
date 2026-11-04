//! 身份与会话持久化.
//!
//! 两条硬规则(2026-11 实战结论):
//! - device_id 首次生成后**永久复用**: 每次随机等于每次换一台新设备, 会被风控盯上.
//! - 设备 cookie 与登录 cookie 一起落盘, 登出不清除 device_id.

pub use ncm_domain::Session;

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const IDENTITY_FILE: &str = "identity.json";

/// 平台形态: **os/appver/osver/channel 四个键必须与 UA、与网页入口的形态自洽**。
///
/// 反面教材(2026-11-04 修正): 以前 cookie 写死 `os=pc` + Win10 指纹, 而 vendor 库对
/// `eapi` 默认发 **iPhone UA**(api-enhanced 的默认值), 于是"身份说 PC、UA 说 iPhone",
/// 风控视角就是一台自相矛盾的客户端 —— 这类不一致最坏的结果是**假通过**(静默降权、
/// 取链只给试听), 比直接报错难查得多。
///
/// 取值全部对齐 vendor `util::config`(OS_ANDROID / OS_PC 与 `choose_user_agent`),
/// 不自己编版本号。
pub struct PlatformProfile {
    pub os: &'static str,
    pub appver: &'static str,
    pub osver: &'static str,
    pub channel: &'static str,
    /// 与 os 形态配套的 UA(安卓端 = 官方安卓客户端 UA, 桌面端 = 官方 PC 客户端 UA)
    pub ua: &'static str,
}

/// 安卓端: 与 vendor `OS_ANDROID` + `choose_user_agent("eapi", "android")` 一致
pub const ANDROID_PROFILE: PlatformProfile = PlatformProfile {
    os: "android",
    appver: "8.20.20.231215173437",
    osver: "14",
    channel: "xiaomi",
    ua: "NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0 (Linux; U; Android 14; 23013RK75C Build/UKQ1.230804.001)",
};

/// 桌面端: 与 vendor `OS_PC` + `choose_user_agent("eapi", "pc")` 一致
pub const DESKTOP_PROFILE: PlatformProfile = PlatformProfile {
    os: "pc",
    appver: "3.1.17.204416",
    osver: "Microsoft-Windows-10-Professional-build-19045-64bit",
    channel: "netease",
    ua: "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.0.18.203152",
};

/// 当前构建目标对应的形态(安卓 App 用安卓形态, 其它按桌面形态)
pub fn platform_profile() -> &'static PlatformProfile {
    if cfg!(target_os = "android") {
        &ANDROID_PROFILE
    } else {
        &DESKTOP_PROFILE
    }
}

/// 形态无关的默认值(缺了才补, 已有值不覆盖)
const IDENTITY_DEFAULTS: &[(&str, &str)] = &[
    ("WEVNSM", "1.0.0"),
    ("__remember_me", "true"),
    ("ntes_kaola_ad", "1"),
];

/// 只取登录凭据(与 `clear_login_cookie` 互补), 用于按账号存档
pub fn extract_login_cookie(cookie: &str) -> String {
    cookie
        .split(';')
        .map(str::trim)
        .filter(|pair| !pair.is_empty())
        .filter(|pair| {
            let key = pair.split('=').next().unwrap_or("").trim();
            LOGIN_KEYS.contains(&key)
        })
        .collect::<Vec<_>>()
        .join("; ")
}

const ACCOUNTS_FILE: &str = "accounts.json";

/// 记住的一个账号: **只存登录凭据**, 设备指纹(deviceId/_ntes_nuid/WNMCID/NMTID)在 identity.json 里共享.
/// 这样切换账号不用重新登录, 也不会让同一台设备看起来像多台设备.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct StoredAccount {
    pub user_id: u64,
    #[serde(default)]
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    /// 上次同步时的会员状态(离线也能显示标识, 不当作事实真相)
    #[serde(default)]
    pub vip: bool,
    /// 只含登录凭据的 cookie 串
    pub cookie: String,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct AccountBook {
    /// 当前正在使用的账号
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<u64>,
    #[serde(default)]
    pub accounts: Vec<StoredAccount>,
}

impl AccountBook {
    pub fn find(&self, user_id: u64) -> Option<&StoredAccount> {
        self.accounts.iter().find(|a| a.user_id == user_id)
    }

    /// 新增或更新(同一个 uid 只留一条), 并设为当前账号
    pub fn upsert(&mut self, account: StoredAccount) {
        self.active = Some(account.user_id);
        match self.accounts.iter_mut().find(|a| a.user_id == account.user_id) {
            Some(slot) => *slot = account,
            None => self.accounts.push(account),
        }
    }

    /// 切换到已保存的账号, 返回该账号(没存过则 None)
    pub fn switch(&mut self, user_id: u64) -> Option<StoredAccount> {
        let found = self.find(user_id).cloned()?;
        self.active = Some(user_id);
        Some(found)
    }

    pub fn remove(&mut self, user_id: u64) -> bool {
        let before = self.accounts.len();
        self.accounts.retain(|a| a.user_id != user_id);
        if self.active == Some(user_id) {
            self.active = None;
        }
        before != self.accounts.len()
    }

    pub fn clear_active(&mut self) {
        self.active = None;
    }
}

pub struct IdentityStore {
    dir: PathBuf,
}

impl IdentityStore {
    pub fn open(dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        Ok(Self { dir: dir.to_path_buf() })
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join(IDENTITY_FILE)
    }

    /// 读已有身份; 不存在则生成 device_id 并落盘.
    pub fn load_or_create(&self) -> io::Result<Session> {
        match fs::read(self.path()) {
            Ok(bytes) => {
                let mut session: Session = serde_json::from_slice(&bytes)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
                let mut dirty = false;
                if session.device_id.is_empty() {
                    session.device_id = new_device_id();
                    dirty = true;
                }
                let normalized = merge_device_cookie(&session.cookie, "", &session.device_id);
                if normalized != session.cookie {
                    session.cookie = normalized;
                    dirty = true;
                }
                if dirty {
                    self.save(&session)?;
                }
                Ok(session)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let device_id = new_device_id();
                let session = Session {
                    cookie: merge_device_cookie("", "", &device_id),
                    device_id,
                    profile: None,
                };
                self.save(&session)?;
                Ok(session)
            }
            Err(e) => Err(e),
        }
    }

    /// 读取已保存的账号簿(不存在则空)
    pub fn load_accounts(&self) -> io::Result<AccountBook> {
        match fs::read(self.dir.join(ACCOUNTS_FILE)) {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(AccountBook::default()),
            Err(e) => Err(e),
        }
    }

    pub fn save_accounts(&self, book: &AccountBook) -> io::Result<()> {
        let data = serde_json::to_vec_pretty(book)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.write_private(&self.dir.join(ACCOUNTS_FILE), &data)
    }

    /// 原子写 + 0600 权限(Linux). 敏感文件不进日志.
    pub fn save(&self, session: &Session) -> io::Result<()> {
        let data = serde_json::to_vec_pretty(session)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.write_private(&self.path(), &data)
    }

    fn write_private(&self, path: &Path, data: &[u8]) -> io::Result<()> {
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, data)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
        }
        fs::rename(&tmp, path)?;
        Ok(())
    }
}

/// 登录凭据键: 退出登录只清这些, 设备指纹(deviceId/_ntes_nuid/_ntes_nnid/WNMCID/NMTID)
/// 一律保留 —— **换账号不等于换设备**, 随机换指纹反而是风控特征。
const LOGIN_KEYS: &[&str] = &[
    "MUSIC_U",
    "MUSIC_A",
    "__csrf",
    "JSESSIONID-WYYY",
    "_iuqxldmzr_",
    "__remember_me",
];

/// 去掉登录态, 返回仍然可用的 cookie(纯函数)
pub fn clear_login_cookie(cookie: &str) -> String {
    cookie
        .split(';')
        .map(str::trim)
        .filter(|pair| !pair.is_empty())
        .filter(|pair| {
            let key = pair.split('=').next().unwrap_or("").trim();
            !LOGIN_KEYS.contains(&key)
        })
        .collect::<Vec<_>>()
        .join("; ")
}

/// 合并 cookie: incoming 里的登录凭据优先, 设备指纹键保持既有值, 缺失则补默认值.
///
/// 为什么必须持久化这些键: 库在缺失时会**每进程随机**生成
/// (_ntes_nuid/_ntes_nnid/NMTID/WNMCID/deviceId) —— 在风控眼里等于每次换新设备.
pub fn merge_device_cookie(existing: &str, incoming: &str, device_id: &str) -> String {
    merge_device_cookie_with(existing, incoming, device_id, platform_profile())
}

/// 同 `merge_device_cookie`, 但显式指定形态(便于单测两种形态).
///
/// 形态四键(os/appver/osver/channel)是**声明式的身份**, 一律按 profile 覆盖:
/// 老版本写过 `os=pc` 的 identity.json 在安卓上会被就地纠正, 其余指纹
/// (deviceId/_ntes_nuid/_ntes_nnid/WNMCID/NMTID) 与登录凭据原样保留。
pub fn merge_device_cookie_with(
    existing: &str,
    incoming: &str,
    device_id: &str,
    profile: &PlatformProfile,
) -> String {
    use std::collections::BTreeMap;
    let mut map: BTreeMap<String, String> = BTreeMap::new();
    let mut absorb = |raw: &str, overwrite: bool| {
        for pair in raw.split(';') {
            let pair = pair.trim();
            if pair.is_empty() {
                continue;
            }
            if let Some((k, v)) = pair.split_once('=') {
                let (k, v) = (k.trim(), v.trim());
                if !k.is_empty() && !v.is_empty() {
                    if overwrite {
                        map.insert(k.to_string(), v.to_string());
                    } else {
                        map.entry(k.to_string()).or_insert_with(|| v.to_string());
                    }
                }
            }
        }
    };
    // 设备指纹先入, 登录 cookie 后入并可覆盖(换账号时 MUSIC_U 必须更新)
    absorb(existing, false);
    absorb(incoming, true);

    for (k, v) in IDENTITY_DEFAULTS {
        map.entry(k.to_string()).or_insert_with(|| v.to_string());
    }
    for (k, v) in [
        ("os", profile.os),
        ("appver", profile.appver),
        ("osver", profile.osver),
        ("channel", profile.channel),
    ] {
        map.insert(k.to_string(), v.to_string());
    }
    map.entry("deviceId".into())
        .or_insert_with(|| device_id.to_string());

    let nuid = map
        .entry("_ntes_nuid".into())
        .or_insert_with(|| random_hex(16))
        .clone();
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    map.entry("_ntes_nnid".into())
        .or_insert_with(|| format!("{nuid},{now_ms}"));
    map.entry("WNMCID".into())
        .or_insert_with(|| format!("{}.{}.01.0", random_alpha(6), now_ms));
    map.entry("NMTID".into())
        .or_insert_with(|| random_hex(8));

    map.iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

fn random_hex(bytes: usize) -> String {
    let mut state = seed();
    (0..bytes * 2)
        .map(|_| {
            state = next(state);
            b"0123456789abcdef"[(state & 0xF) as usize] as char
        })
        .collect()
}

fn random_alpha(n: usize) -> String {
    let mut state = seed();
    (0..n)
        .map(|_| {
            state = next(state);
            b"abcdefghijklmnopqrstuvwxyz"[(state % 26) as usize] as char
        })
        .collect()
}

fn seed() -> u64 {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    t ^ ((std::process::id() as u64) << 32) ^ 0x9E37_79B9_7F4A_7C15
}

fn next(mut x: u64) -> u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    x
}

/// 52 位十六进制设备 id, 与官方客户端形态一致.
pub fn new_device_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let mut state = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
        ^ (std::process::id() as u64) << 32;
    let mut out = String::with_capacity(52);
    const HEX: &[u8] = b"0123456789ABCDEF";
    // xorshift64*, 不引入 rand 依赖
    for _ in 0..52 {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        out.push(HEX[(state & 0xF) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("ncm-test-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        p
    }

    #[test]
    fn device_cookie_is_seeded_and_preserved() {
        let merged = merge_device_cookie("", "", "ABC");
        assert!(merged.contains("deviceId=ABC"), "{merged}");
        assert!(merged.contains("os=pc"), "{merged}");
        assert!(merged.contains("_ntes_nuid="), "{merged}");
        assert!(merged.contains("WNMCID="), "{merged}");
        // 再合并一次不能换指纹
        let again = merge_device_cookie(&merged, "", "ABC");
        assert_eq!(again, merged);
        // 登录 cookie 覆盖且不破坏指纹
        let logged = merge_device_cookie(&merged, "MUSIC_U=x; os=pc", "ABC");
        assert!(logged.contains("MUSIC_U=x"));
        assert!(logged.contains("_ntes_nuid="));
    }

    #[test]
    fn extract_login_cookie_keeps_only_credentials() {
        let all = "MUSIC_U=u; __csrf=c; JSESSIONID-WYYY=j; deviceId=D; _ntes_nuid=n; os=android";
        let only = extract_login_cookie(all);
        assert_eq!(only, "MUSIC_U=u; __csrf=c; JSESSIONID-WYYY=j");
    }

    #[test]
    fn account_book_roundtrip_and_switch() {
        let dir = tmpdir("accounts");
        let store = IdentityStore::open(&dir).unwrap();
        let mut book = store.load_accounts().unwrap();
        assert!(book.accounts.is_empty());

        book.upsert(StoredAccount {
            user_id: 1,
            nickname: "A".into(),
            avatar_url: None,
            vip: false,
            cookie: extract_login_cookie("deviceId=D; MUSIC_U=a; __csrf=1; _ntes_nuid=n"),
        });
        book.upsert(StoredAccount {
            user_id: 2,
            nickname: "B".into(),
            avatar_url: Some("http://avatar".into()),
            vip: true,
            cookie: "MUSIC_U=b".into(),
        });
        // 只存登录凭据, 设备指纹不进账号簿
        assert!(book.accounts[0].cookie.contains("MUSIC_U=a"));
        assert!(!book.accounts[0].cookie.contains("deviceId"));
        store.save_accounts(&book).unwrap();

        let mut reloaded = store.load_accounts().unwrap();
        assert_eq!(reloaded.accounts.len(), 2);
        assert_eq!(reloaded.active, Some(2), "最后一次 upsert 的账号是当前账号");

        let switched = reloaded.switch(1).expect("已保存的账号应能直接切换");
        assert_eq!(switched.nickname, "A");
        assert_eq!(reloaded.active, Some(1));
        assert!(reloaded.switch(999).is_none());

        assert!(reloaded.remove(2));
        assert_eq!(reloaded.accounts.len(), 1);
        assert!(reloaded.find(2).is_none());
    }

    #[test]
    fn logout_clears_credentials_but_keeps_fingerprint() {
        let cookie = "MUSIC_U=secret; __csrf=abc; JSESSIONID-WYYY=x; deviceId=DEV;                       _ntes_nuid=aa; _ntes_nnid=aa,1; WNMCID=w; NMTID=n; os=android";
        let out = clear_login_cookie(cookie);
        for gone in ["MUSIC_U", "__csrf", "JSESSIONID-WYYY"] {
            assert!(!out.contains(gone), "{gone} 还在: {out}");
        }
        for kept in ["deviceId=DEV", "_ntes_nuid=aa", "_ntes_nnid=aa,1", "WNMCID=w", "NMTID=n", "os=android"] {
            assert!(out.contains(kept), "{kept} 丢了: {out}");
        }
        // 清完之后再合并一次(等价于 App 重启加载), 指纹不能变
        let reloaded = merge_device_cookie_with(&out, "", "DEV", &ANDROID_PROFILE);
        assert!(reloaded.contains("deviceId=DEV"));
        assert!(reloaded.contains("_ntes_nuid=aa"));
        assert!(!reloaded.contains("MUSIC_U"));
    }

    #[test]
    fn profile_declares_matching_os_fields() {
        let android =
            merge_device_cookie_with("", "MUSIC_U=x; os=web; appver=1", "DEV", &ANDROID_PROFILE);
        assert!(android.contains("os=android"), "{android}");
        assert!(android.contains("appver=8.20.20.231215173437"), "{android}");
        assert!(android.contains("channel=xiaomi"), "{android}");
        // 登录凭据与设备指纹都不能被形态覆盖冲掉
        assert!(android.contains("MUSIC_U=x"), "{android}");
        assert!(android.contains("deviceId=DEV"), "{android}");

        let desktop = merge_device_cookie_with("", "", "DEV", &DESKTOP_PROFILE);
        assert!(desktop.contains("os=pc"), "{desktop}");
        assert!(desktop.contains("appver=3.1.17.204416"), "{desktop}");
        assert!(desktop.contains("channel=netease"), "{desktop}");
    }

    #[test]
    fn stale_desktop_identity_migrates_to_android() {
        let existing = "os=pc; appver=3.0.6; osver=10.0.19045; channel=netease; deviceId=DEV;                         _ntes_nuid=aa; WNMCID=w; MUSIC_U=keepme";
        let migrated = merge_device_cookie_with(existing, "", "DEV", &ANDROID_PROFILE);
        assert!(migrated.contains("os=android"), "{migrated}");
        assert!(!migrated.contains("os=pc"), "{migrated}");
        assert!(migrated.contains("appver=8.20.20.231215173437"), "{migrated}");
        // 指纹与凭据原样保留
        assert!(migrated.contains("_ntes_nuid=aa"), "{migrated}");
        assert!(migrated.contains("WNMCID=w"), "{migrated}");
        assert!(migrated.contains("MUSIC_U=keepme"), "{migrated}");
        assert!(migrated.contains("deviceId=DEV"), "{migrated}");
    }

    #[test]
    fn platform_profile_ua_matches_os() {
        let a = platform_profile();
        if a.os == "android" {
            assert!(a.ua.contains("Android"), "{}", a.ua);
        } else {
            assert!(a.ua.contains("NeteaseMusicDesktop"), "{}", a.ua);
        }
    }

    #[test]
    fn device_id_is_stable_across_reloads() {
        let dir = tmpdir("stable");
        let store = IdentityStore::open(&dir).unwrap();
        let a = store.load_or_create().unwrap();
        let b = store.load_or_create().unwrap();
        assert_eq!(a.device_id, b.device_id);
        assert_eq!(a.device_id.len(), 52);
        assert!(!a.is_logged_in());
    }

    #[test]
    fn login_cookie_persists_and_device_id_kept() {
        let dir = tmpdir("cookie");
        let store = IdentityStore::open(&dir).unwrap();
        let mut s = store.load_or_create().unwrap();
        let id = s.device_id.clone();
        s.cookie = "MUSIC_U=deadbeef; os=pc".into();
        store.save(&s).unwrap();
        let loaded = store.load_or_create().unwrap();
        assert!(loaded.is_logged_in());
        assert_eq!(loaded.device_id, id);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(store.path()).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
    }
}
