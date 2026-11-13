//! 凭据存储: 抽象后端 + 策略门(2026-11-11, 基于 docs/credential-storage-options.md §3 的地基).
//!
//! 目标: 登录凭据(MUSIC_U 等登录键)不再进明文 JSON; 设备指纹 cookie 仍留在
//! identity.json(指纹不是凭据, 且按风控纪律必须持久化).
//!
//! 分阶段(本 lane 只做地基 + P0):
//! - P0 Windows: DPAPI([DpapiStore], 绑定 Windows 账户, 近零依赖)
//! - P1 Android Keystore / P2 Linux secret-service: 只需实现 [CredentialStore]
//!   trait + 在 [open_backend] 里按 target_os 分派, 不用动 identity.rs/FFI.
//! - 钥匙串不可用时: 经用户明确同意(credential_policy.json 的 plaintextConsent)
//!   才允许退回 0600 明文([FileStore]); 未同意时写入被拒, identity.rs 走旧明文
//!   兼容路径并上报状态, 不阻塞启动.
//!
//! 与调研报告 §3 草案的差异(有意微调):
//! - 保留草案的 [CredentialError], 额外给 into_io(): IdentityStore 现有方法签名
//!   全是 io::Result, 需要无损转换.
//! - FileStore 的 available() 落实为"读同意标记": "每次写前检查同意"是门禁不是约定.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// 凭据的逻辑键. Account 按 uid 隔离, 换账号不互相覆盖.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialKey {
    /// 当前会话的登录凭据(登录键 cookie 串)
    Session,
    /// 账号簿里记住的某账号凭据
    Account(u64),
}

impl CredentialKey {
    /// 落盘/内存索引用的稳定字符串形式
    pub fn id(&self) -> String {
        match self {
            CredentialKey::Session => "session".to_string(),
            CredentialKey::Account(uid) => format!("account:{uid}"),
        }
    }
}

/// 凭据后端错误.
/// - Unavailable: 后端本身不可用(无 DPAPI/无 keyring/解不开密文如换机器), 语义=当未登录
/// - AccessDenied: 后端在, 但策略门不让写(如明文未获同意)
/// - Backend: 后端内部 IO/加解密失败
#[derive(Debug, Clone)]
pub enum CredentialError {
    Unavailable(String),
    AccessDenied(String),
    Backend(String),
}

impl CredentialError {
    pub fn message(&self) -> &str {
        match self {
            CredentialError::Unavailable(s)
            | CredentialError::AccessDenied(s)
            | CredentialError::Backend(s) => s,
        }
    }

    /// IdentityStore 的现有方法签名都是 io::Result, 提供无损转换.
    pub fn into_io(self) -> io::Error {
        io::Error::other(self.message().to_string())
    }
}

impl std::fmt::Display for CredentialError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let kind = match self {
            CredentialError::Unavailable(_) => "unavailable",
            CredentialError::AccessDenied(_) => "access-denied",
            CredentialError::Backend(_) => "backend",
        };
        write!(f, "{kind}: {}", self.message())
    }
}

/// 钥匙串抽象. P1(Android Keystore)/P2(Linux secret-service) 各实现一份即可接入.
pub trait CredentialStore: Send + Sync {
    fn put(&self, key: CredentialKey, secret: &str) -> Result<(), CredentialError>;
    /// None = 没存过; 解不开(换机器/换账户)应返回 Err(Unavailable), 不要 panic
    fn get(&self, key: CredentialKey) -> Result<Option<String>, CredentialError>;
    fn remove(&self, key: CredentialKey) -> Result<(), CredentialError>;
    /// 后端是否可用; 由启动逻辑据此决定降级策略, store 不自行降级
    fn available(&self) -> Result<(), CredentialError>;
}

/// 后端名(写进策略文件, 便于以后换后端时识别旧数据是谁写的)
pub const BACKEND_FILE: &str = "file";
pub const BACKEND_DPAPI: &str = "dpapi";
/// Android Keystore 经 Dart 通道桥接(credential_channel::ChannelStore)
pub const BACKEND_KEYSTORE: &str = "android-keystore";
pub const BACKEND_SECRET_SERVICE: &str = "secret-service";

// ---------------- 策略文件(同意标记 + 迁移标记) ----------------

/// `<dataDir>/credential_policy.json` —— 不进 identity.json, 便于以后换后端.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CredentialPolicy {
    /// 用户是否明确同意"无钥匙串时退回 0600 明文". 默认 false = 未同意.
    #[serde(default)]
    pub plaintext_consent: bool,
    /// 当前/上次使用的后端: file | dpapi | (未来) keystore | secret-service
    #[serde(default)]
    pub backend: String,
    /// 旧明文 → CredentialStore 的一次性迁移是否已完成
    #[serde(default)]
    pub migrated: bool,
}

pub const POLICY_FILE: &str = "credential_policy.json";

impl CredentialPolicy {
    pub fn path(dir: &Path) -> PathBuf {
        dir.join(POLICY_FILE)
    }

    pub fn load(dir: &Path) -> Self {
        match fs::read(Self::path(dir)) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, dir: &Path) -> io::Result<()> {
        let data = serde_json::to_vec_pretty(self)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        write_private(&Self::path(dir), &data)
    }
}

// ---------------- FileStore: 0600 明文(需同意) ----------------

pub const CREDS_FILE: &str = "credentials.json";

/// 0600 明文后端. **只有**用户明确同意(策略标记)后才允许写; 每次写前重读标记.
pub struct FileStore {
    dir: PathBuf,
}

impl FileStore {
    pub fn new(dir: &Path) -> Self {
        Self { dir: dir.to_path_buf() }
    }

    fn path(&self) -> PathBuf {
        self.dir.join(CREDS_FILE)
    }

    /// BTreeMap: 落盘内容稳定可 diff, 也避免 HashMap 迭代序噪声.
    fn load_map(&self) -> io::Result<BTreeMap<String, String>> {
        match fs::read(self.path()) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(BTreeMap::new()),
            Err(e) => Err(e),
        }
    }

    fn save_map(&self, map: &BTreeMap<String, String>) -> Result<(), CredentialError> {
        let data = serde_json::to_vec_pretty(map)
            .map_err(|e| CredentialError::Backend(e.to_string()))?;
        write_private(&self.path(), &data).map_err(|e| CredentialError::Backend(e.to_string()))
    }

    /// 同意门: 未同意 = AccessDenied, 上层走旧明文兼容路径并上报.
    fn consent(&self) -> Result<(), CredentialError> {
        if CredentialPolicy::load(&self.dir).plaintext_consent {
            Ok(())
        } else {
            Err(CredentialError::AccessDenied(
                "0600 明文回退未获用户同意(credential_policy.json:plaintextConsent)".into(),
            ))
        }
    }
}

impl CredentialStore for FileStore {
    fn put(&self, key: CredentialKey, secret: &str) -> Result<(), CredentialError> {
        self.consent()?;
        let mut map = self.load_map().map_err(|e| CredentialError::Backend(e.to_string()))?;
        map.insert(key.id(), secret.to_string());
        self.save_map(&map)
    }

    fn get(&self, key: CredentialKey) -> Result<Option<String>, CredentialError> {
        self.consent()?;
        let map = self.load_map().map_err(|e| CredentialError::Backend(e.to_string()))?;
        Ok(map.get(&key.id()).cloned())
    }

    fn remove(&self, key: CredentialKey) -> Result<(), CredentialError> {
        self.consent()?;
        let mut map = self.load_map().map_err(|e| CredentialError::Backend(e.to_string()))?;
        map.remove(&key.id());
        self.save_map(&map)
    }

    fn available(&self) -> Result<(), CredentialError> {
        self.consent()
    }
}

/// 原子写 + 0600(unix). 与 identity.rs 的 write_private 同语义; FileStore 用它落
/// credentials.json, identity.rs 保留自己的实现落 identity.json 骨架.
pub(crate) fn write_private(path: &Path, data: &[u8]) -> io::Result<()> {
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

// ---------------- 启动时的后端选择与状态上报 ----------------

/// 启动时给上层(Dart 提示用)的状态, 不阻塞启动.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialStatus {
    /// 安全后端就绪, 凭据不入明文
    Secure { backend: &'static str, migrated: bool },
    /// 用户已同意, 0600 明文后端在用
    PlaintextConsented { migrated: bool },
    /// 无安全后端且未同意: 旧明文原样保留 / 新凭据走旧明文兼容路径, 可上报提示
    PlaintextFallback { reason: String },
}

impl CredentialStatus {
    pub fn backend_name(&self) -> &str {
        match self {
            CredentialStatus::Secure { backend, .. } => backend,
            CredentialStatus::PlaintextConsented { .. } => BACKEND_FILE,
            CredentialStatus::PlaintextFallback { .. } => "none",
        }
    }

    pub fn migrated(&self) -> bool {
        match self {
            CredentialStatus::Secure { migrated, .. }
            | CredentialStatus::PlaintextConsented { migrated } => *migrated,
            CredentialStatus::PlaintextFallback { .. } => false,
        }
    }

    pub fn note(&self) -> String {
        match self {
            CredentialStatus::Secure { backend, .. } => format!("凭据由 {backend} 保护"),
            CredentialStatus::PlaintextConsented { .. } => {
                "凭据以 0600 明文存放(用户已同意)".to_string()
            }
            CredentialStatus::PlaintextFallback { reason } => format!("凭据仍为明文: {reason}"),
        }
    }
}

/// 启动时选后端:
/// - Windows: DPAPI 可用即用(P0); 不可用再走同意门.
/// - 其它平台: 本 lane 没有钥匙串后端(P1 Android / P2 Linux 由后续 lane 接入),
///   走同意门 —— 同意了给 FileStore, 没同意给 None(identity.rs 走旧明文兼容路径).
pub fn open_backend(dir: &Path) -> (Option<Arc<dyn CredentialStore>>, CredentialStatus) {
    #[cfg(windows)]
    {
        let dpapi = DpapiStore::new(dir);
        match dpapi.available() {
            Ok(()) => {
                let policy = CredentialPolicy::load(dir);
                return (
                    Some(Arc::new(dpapi)),
                    CredentialStatus::Secure { backend: BACKEND_DPAPI, migrated: policy.migrated },
                );
            }
            Err(e) => {
                // DPAPI 不可用: 继续走同意门, 失败原因并进 fallback 提示
                let policy = CredentialPolicy::load(dir);
                if policy.plaintext_consent {
                    return (
                        Some(Arc::new(FileStore::new(dir))),
                        CredentialStatus::PlaintextConsented { migrated: policy.migrated },
                    );
                }
                return (
                    None,
                    CredentialStatus::PlaintextFallback {
                        reason: format!("DPAPI 不可用({e})且未同意明文回退"),
                    },
                );
            }
        }
    }
    #[cfg(target_os = "android")]
    {
        // P1: Dart 启动时已探测 Keystore 并 credential_restore 激活桥.
        // 未激活(Keystore 不可用/通道缺) → 与其它平台一样走同意门,
        // 绝不新增明文落盘路径.
        if let Some(store) = super::credential_channel::channel_backend() {
            let policy = CredentialPolicy::load(dir);
            return (
                Some(store),
                CredentialStatus::Secure {
                    backend: BACKEND_KEYSTORE,
                    migrated: policy.migrated,
                },
            );
        }
    }
    #[cfg(not(windows))]
    {
        // P2 Linux: secret-service(keyring crate) 可用即用; 不可用走同意门(语义不变).
        // 仅 Linux 探测; Windows 走上一个分支, Android 走上一个 cfg 分支(Keystore 桥).
        #[cfg(target_os = "linux")]
        {
            let store = crate::credential_keyring::SecretServiceStore::new();
            if store.available().is_ok() {
                let policy = CredentialPolicy::load(dir);
                return (
                    Some(Arc::new(store)),
                    CredentialStatus::Secure {
                        backend: BACKEND_SECRET_SERVICE,
                        migrated: policy.migrated,
                    },
                );
            }
        }
        let policy = CredentialPolicy::load(dir);
        if policy.plaintext_consent {
            (
                Some(Arc::new(FileStore::new(dir))),
                CredentialStatus::PlaintextConsented { migrated: policy.migrated },
            )
        } else {
            (
                None,
                CredentialStatus::PlaintextFallback {
                    reason: "无系统钥匙串后端(不可用)且用户未同意 0600 明文回退".into(),
                },
            )
        }
    }
}

// ---------------- P0: Windows DPAPI 后端 ----------------

/// DPAPI 后端(CryptProtectData, 绑定当前 Windows 账户).
///
/// 落盘格式(单文件 `<dataDir>/credentials.dpapi`, 二进制, 不用 base64 免依赖):
/// magic "NCMCRED1\\n" | u32 count LE | (u32 key_len LE | key | u32 blob_len LE | dpapi blob)*
///
/// 解密失败(换 Windows 账户/换机器) = Unavailable, 当未登录处理, 不 panic.
#[cfg(windows)]
pub mod dpapi {
    use super::{BACKEND_DPAPI, CredentialError, CredentialKey, CredentialStore};
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};

    pub const CREDS_FILE: &str = "credentials.dpapi";
    const MAGIC: &[u8] = b"NCMCRED1\\n";

    pub struct DpapiStore {
        dir: PathBuf,
    }

    impl DpapiStore {
        pub fn new(dir: &Path) -> Self {
            Self { dir: dir.to_path_buf() }
        }

        fn path(&self) -> PathBuf {
            self.dir.join(CREDS_FILE)
        }

        fn read_entries(&self) -> io::Result<Vec<(String, Vec<u8>)>> {
            let raw = match fs::read(self.path()) {
                Ok(b) => b,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
                Err(e) => return Err(e),
            };
            if raw.len() < MAGIC.len() || &raw[..MAGIC.len()] != MAGIC {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "bad dpapi magic"));
            }
            // 用结构体而不是两个互相捕获的闭包: 闭包版在 Windows 上 borrow 冲突(E0499,
            // 2026-11-12 首次真正在 windows-latest 编译时暴露)。
            struct Reader<'a> {
                raw: &'a [u8],
                cur: usize,
            }
            impl<'a> Reader<'a> {
                fn take(&mut self, n: usize) -> Option<&'a [u8]> {
                    if self.cur + n > self.raw.len() {
                        return None;
                    }
                    let out = &self.raw[self.cur..self.cur + n];
                    self.cur += n;
                    Some(out)
                }
                fn u32le(&mut self) -> Option<usize> {
                    let b = self.take(4)?;
                    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
                }
            }
            let mut rd = Reader { raw: &raw, cur: MAGIC.len() };
            let truncated = || io::Error::new(io::ErrorKind::InvalidData, "truncated");
            let count = rd.u32le().ok_or_else(truncated)?;
            let mut out = Vec::with_capacity(count);
            for _ in 0..count {
                let klen = rd.u32le().ok_or_else(truncated)?;
                let key = String::from_utf8(rd.take(klen).ok_or_else(truncated)?.to_vec())
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad key"))?;
                let blen = rd.u32le().ok_or_else(truncated)?;
                let blob = rd.take(blen).ok_or_else(truncated)?.to_vec();
                out.push((key, blob));
            }
            Ok(out)
        }

        fn write_entries(&self, entries: &[(String, Vec<u8>)]) -> Result<(), CredentialError> {
            let mut out = MAGIC.to_vec();
            out.extend_from_slice(&(entries.len() as u32).to_le_bytes());
            for (key, blob) in entries {
                out.extend_from_slice(&(key.len() as u32).to_le_bytes());
                out.extend_from_slice(key.as_bytes());
                out.extend_from_slice(&(blob.len() as u32).to_le_bytes());
                out.extend_from_slice(blob);
            }
            let tmp = self.path().with_extension("dpapi.tmp");
            fs::write(&tmp, &out).map_err(|e| CredentialError::Backend(e.to_string()))?;
            fs::rename(&tmp, self.path()).map_err(|e| CredentialError::Backend(e.to_string()))
        }

        fn upsert(&self, key: &str, blob: Vec<u8>) -> Result<(), CredentialError> {
            let mut entries = self
                .read_entries()
                .map_err(|e| CredentialError::Backend(e.to_string()))?;
            match entries.iter_mut().find(|(k, _)| k == key) {
                Some(slot) => slot.1 = blob,
                None => entries.push((key.to_string(), blob)),
            }
            self.write_entries(&entries)
        }
    }

    impl CredentialStore for DpapiStore {
        fn put(&self, key: CredentialKey, secret: &str) -> Result<(), CredentialError> {
            let blob = protect(secret.as_bytes())?;
            self.upsert(&key.id(), blob)
        }

        fn get(&self, key: CredentialKey) -> Result<Option<String>, CredentialError> {
            let entries = self
                .read_entries()
                .map_err(|e| CredentialError::Backend(e.to_string()))?;
            let Some((_, blob)) = entries.iter().find(|(k, _)| k == &key.id()) else {
                return Ok(None);
            };
            let plain = unprotect(blob)?;
            String::from_utf8(plain)
                .map(Some)
                .map_err(|_| CredentialError::Unavailable("DPAPI 解密结果不是合法 UTF-8".into()))
        }

        fn remove(&self, key: CredentialKey) -> Result<(), CredentialError> {
            let mut entries = self
                .read_entries()
                .map_err(|e| CredentialError::Backend(e.to_string()))?;
            entries.retain(|(k, _)| k != &key.id());
            self.write_entries(&entries)
        }

        /// DPAPI 在 Windows 上始终存在; 做一次微型 roundtrip 兜底(组策略禁用等极端
        /// 场景会在这里暴露).
        fn available(&self) -> Result<(), CredentialError> {
            const PROBE: &[u8] = b"ncm-probe";
            let blob = protect(PROBE)?;
            let back = unprotect(&blob)?;
            if back.as_slice() == PROBE {
                Ok(())
            } else {
                Err(CredentialError::Unavailable("DPAPI roundtrip 内容不符".into()))
            }
        }
    }

    pub fn policy_backend_name() -> &'static str {
        BACKEND_DPAPI
    }

    fn protect(plain: &[u8]) -> Result<Vec<u8>, CredentialError> {
        use windows_sys::Win32::Foundation::LocalFree;
        use windows_sys::Win32::Security::Cryptography::{
            CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        };
        unsafe {
            let input = CRYPT_INTEGER_BLOB {
                cbData: plain.len() as u32,
                pbData: plain.as_ptr() as *mut u8,
            };
            let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
            let ok = CryptProtectData(
                &input,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            );
            if ok == 0 {
                return Err(CredentialError::Backend("CryptProtectData 失败".into()));
            }
            let out = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
            LocalFree(output.pbData as *mut _);
            Ok(out)
        }
    }

    fn unprotect(blob: &[u8]) -> Result<Vec<u8>, CredentialError> {
        use windows_sys::Win32::Foundation::LocalFree;
        use windows_sys::Win32::Security::Cryptography::{
            CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        };
        unsafe {
            let input = CRYPT_INTEGER_BLOB {
                cbData: blob.len() as u32,
                pbData: blob.as_ptr() as *mut u8,
            };
            let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
            let ok = CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            );
            if ok == 0 {
                // 换 Windows 账户 / 换机器 / 文件损坏都走到这里: 当后端不可用
                return Err(CredentialError::Unavailable(
                    "CryptUnprotectData 失败(换账户/换机器/密文损坏?)".into(),
                ));
            }
            let out = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
            LocalFree(output.pbData as *mut _);
            Ok(out)
        }
    }

    // windows-only 单测(随 windows.yml 跑): roundtrip + 密文非明文
    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn protect_roundtrip_and_not_plaintext() {
            let secret = b"MUSIC_U=deadbeef; __csrf=x";
            let blob = protect(secret).unwrap();
            assert_ne!(&blob[..], &secret[..], "密文不能等于明文");
            assert_eq!(unprotect(&blob).unwrap(), secret);
        }

        #[test]
        fn unprotect_garbage_is_unavailable_not_panic() {
            let err = unprotect(b"garbage-not-a-blob").unwrap_err();
            assert!(matches!(err, CredentialError::Unavailable(_)));
        }
    }
}

#[cfg(windows)]
pub use dpapi::DpapiStore;

// ---------------- 单测(不联网, Linux 可跑) ----------------

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("ncm-cred-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn file_store_rejects_writes_without_consent() {
        let dir = tmpdir("no-consent");
        let store = FileStore::new(&dir);
        // 未同意: available 拒绝, put/get/remove 都被门禁挡住
        assert!(matches!(store.available(), Err(CredentialError::AccessDenied(_))));
        assert!(matches!(
            store.put(CredentialKey::Session, "MUSIC_U=x"),
            Err(CredentialError::AccessDenied(_))
        ));
        assert!(matches!(
            store.get(CredentialKey::Session),
            Err(CredentialError::AccessDenied(_))
        ));
        // credentials.json 不应被创建
        assert!(!dir.join(CREDS_FILE).exists());
    }

    #[test]
    fn file_store_roundtrip_after_consent_and_rechecks_each_write() {
        let dir = tmpdir("consent");
        let store = FileStore::new(&dir);
        let mut policy = CredentialPolicy::load(&dir);
        assert!(!policy.plaintext_consent, "默认未同意");
        policy.plaintext_consent = true;
        policy.backend = BACKEND_FILE.to_string();
        policy.save(&dir).unwrap();

        store.put(CredentialKey::Session, "MUSIC_U=a").unwrap();
        store.put(CredentialKey::Account(42), "MUSIC_U=b").unwrap();
        assert_eq!(store.get(CredentialKey::Session).unwrap().as_deref(), Some("MUSIC_U=a"));
        assert_eq!(store.get(CredentialKey::Account(42)).unwrap().as_deref(), Some("MUSIC_U=b"));
        // key 互不覆盖
        assert_eq!(store.get(CredentialKey::Account(43)).unwrap(), None);

        store.remove(CredentialKey::Session).unwrap();
        assert_eq!(store.get(CredentialKey::Session).unwrap(), None);
        assert_eq!(store.get(CredentialKey::Account(42)).unwrap().as_deref(), Some("MUSIC_U=b"));

        // 撤销同意后写入再次被拒(每次写前重读标记)
        policy.plaintext_consent = false;
        policy.save(&dir).unwrap();
        assert!(matches!(
            store.put(CredentialKey::Session, "again"),
            Err(CredentialError::AccessDenied(_))
        ));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(dir.join(CREDS_FILE)).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "credentials.json 必须 0600");
            let pm = fs::metadata(CredentialPolicy::path(&dir)).unwrap().permissions().mode() & 0o777;
            assert_eq!(pm, 0o600, "策略文件也 0600");
        }
    }

    /// 用一个"假钥匙串"mock 验证接口语义(与后端实现解耦).
    #[test]
    fn trait_mock_roundtrip() {
        struct Mem(std::sync::Mutex<BTreeMap<String, String>>);
        impl CredentialStore for Mem {
            fn put(&self, k: CredentialKey, s: &str) -> Result<(), CredentialError> {
                self.0.lock().unwrap().insert(k.id(), s.into());
                Ok(())
            }
            fn get(&self, k: CredentialKey) -> Result<Option<String>, CredentialError> {
                Ok(self.0.lock().unwrap().get(&k.id()).cloned())
            }
            fn remove(&self, k: CredentialKey) -> Result<(), CredentialError> {
                self.0.lock().unwrap().remove(&k.id());
                Ok(())
            }
            fn available(&self) -> Result<(), CredentialError> {
                Ok(())
            }
        }
        let m = Mem(Default::default());
        m.put(CredentialKey::Session, "s").unwrap();
        m.put(CredentialKey::Account(1), "a1").unwrap();
        assert_eq!(m.get(CredentialKey::Session).unwrap().as_deref(), Some("s"));
        m.remove(CredentialKey::Account(1)).unwrap();
        assert_eq!(m.get(CredentialKey::Account(1)).unwrap(), None);
    }

    #[test]
    fn policy_file_roundtrip_and_defaults() {
        let dir = tmpdir("policy");
        let p = CredentialPolicy::load(&dir);
        assert!(!p.plaintext_consent);
        assert!(!p.migrated);
        let p = CredentialPolicy { plaintext_consent: true, backend: "file".into(), migrated: true };
        p.save(&dir).unwrap();
        assert_eq!(CredentialPolicy::load(&dir), p);
        // 坏内容回落默认, 不 panic
        fs::write(CredentialPolicy::path(&dir), b"not json").unwrap();
        assert_eq!(CredentialPolicy::load(&dir), CredentialPolicy::default());
    }

    #[test]
    fn key_ids_are_stable() {
        assert_eq!(CredentialKey::Session.id(), "session");
        assert_eq!(CredentialKey::Account(7).id(), "account:7");
    }

    // 迁移语义在 identity.rs 的 tests 里与 IdentityStore 一起覆盖.
}
