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

    /// 原子写 + 0600 权限(Linux). 敏感文件不进日志.
    pub fn save(&self, session: &Session) -> io::Result<()> {
        let path = self.path();
        let tmp = path.with_extension("json.tmp");
        let data = serde_json::to_vec_pretty(session)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        fs::write(&tmp, &data)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
        }
        fs::rename(&tmp, &path)?;
        Ok(())
    }
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
