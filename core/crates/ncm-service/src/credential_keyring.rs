//! P2: Linux secret-service 凭据后端(2026-11-12, 基于 docs/credential-storage-options.md §2a/§3).
//!
//! - `keyring` crate 3.x + `sync-secret-service`(zbus 阻塞式), service 名 `com.minincm.minincm`,
//!   account 用 `CredentialKey::id()`(与 FileStore/DpapiStore 同一套键).
//! - `available()` 轻量探测: 只构造一个不存在条目的 Entry 并读一次(D-Bus 有无/服务可达
//!   在这一步暴露), **不写探针 secret**; 结果缓存在实例里(OnceLock 语义), 避免每次 IO 打 D-Bus.
//! - 所有错误映射到 `CredentialError::{Unavailable, AccessDenied, Backend}`, 绝不 panic.
//! - 无 D-Bus / 无桌面会话时 `open_backend` 回落 FileStore(同意门语义不变), 见 credential_store.rs.

use crate::credential_store::{CredentialError, CredentialKey, CredentialStore};

/// secret-service 里的 service(collection) 标识
pub const SECRET_SERVICE: &str = "com.minincm.minincm";

pub struct SecretServiceStore {
    /// 探测结果缓存: Some(Ok) = 可用; Some(Err) = 不可用(原因). None = 还没探.
    probe: std::sync::OnceLock<Result<(), CredentialError>>,
}

impl SecretServiceStore {
    pub fn new() -> Self {
        Self {
            probe: std::sync::OnceLock::new(),
        }
    }

    /// 轻量探测(缓存): 构造一个不存在的 entry 并 get —— 只打一次 D-Bus,
    /// 不写任何探针 secret. 无 D-Bus 会话/服务未装都在这里失败.
    fn probe_once(&self) -> Result<(), CredentialError> {
        self.probe
            .get_or_init(|| {
                let entry = keyring::Entry::new(SECRET_SERVICE, &CredentialKey::Session.id())
                    .map_err(|e| {
                        CredentialError::Unavailable(format!("keyring 初始化失败: {e}"))
                    })?;
                match entry.get_password() {
                    // 不存在 = 服务在, 探测通过
                    Err(keyring::Error::NoEntry) => Ok(()),
                    // 能读到(残留)也说明服务在
                    Ok(_) => Ok(()),
                    Err(e) => Err(map_err(&e, "keyring 探测")),
                }
            })
            .clone()
    }

    fn entry(&self, key: &CredentialKey) -> Result<keyring::Entry, CredentialError> {
        self.probe_once()?;
        keyring::Entry::new(SECRET_SERVICE, &key.id())
            .map_err(|e| CredentialError::Backend(format!("keyring Entry::new 失败: {e}")))
    }
}

impl Default for SecretServiceStore {
    fn default() -> Self {
        Self::new()
    }
}

/// keyring 错误 → 三类 CredentialError. 绝不 panic.
fn map_err(e: &keyring::Error, ctx: &str) -> CredentialError {
    match e {
        keyring::Error::NoEntry => CredentialError::Unavailable(format!("{ctx}: 条目不存在")),
        // 会话锁/服务不可达/拒绝访问: 当后端不可用, 上层语义=未登录
        keyring::Error::NoStorageAccess(_) | keyring::Error::PlatformFailure(_) => {
            CredentialError::Unavailable(format!("{ctx}: secret-service 不可达({e})"))
        }
        // enum 是 #[non_exhaustive], 其余(BadEncoding/TooLong/Invalid/Ambiguous/未来变体)归 Backend
        _ => CredentialError::Backend(format!("{ctx}: {e}")),
    }
}

impl CredentialStore for SecretServiceStore {
    fn put(&self, key: CredentialKey, secret: &str) -> Result<(), CredentialError> {
        let entry = self.entry(&key)?;
        // secret-service 的 set 在旧条目存在时部分版本会报错, 先删再写(幂等)
        match entry.set_password(secret) {
            Ok(()) => Ok(()),
            Err(keyring::Error::PlatformFailure(_) | keyring::Error::BadEncoding(_)) => {
                let _ = entry.delete_credential();
                entry
                    .set_password(secret)
                    .map_err(|e| map_err(&e, "keyring 写入"))
            }
            Err(e) => Err(map_err(&e, "keyring 写入")),
        }
    }

    fn get(&self, key: CredentialKey) -> Result<Option<String>, CredentialError> {
        let entry = self.entry(&key)?;
        match entry.get_password() {
            Ok(s) => Ok(Some(s)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(map_err(&e, "keyring 读取")),
        }
    }

    fn remove(&self, key: CredentialKey) -> Result<(), CredentialError> {
        let entry = self.entry(&key)?;
        match entry.delete_credential() {
            Ok(()) => Ok(()),
            // 没存过也算删成功(幂等, 与 FileStore 对齐)
            Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(map_err(&e, "keyring 删除")),
        }
    }

    fn available(&self) -> Result<(), CredentialError> {
        self.probe_once()
    }
}

// ---------------- 单测(无 D-Bus 的 CI 也全绿; 探测失败路径可测) ----------------

#[cfg(test)]
mod tests {
    use super::*;

    /// 三个 D-Bus 相关测试会读/改进程级 DBUS_SESSION_BUS_ADDRESS, 必须互斥
    /// (cargo test 默认多线程; 非门控环境提前 return 不拿锁).
    static DBUS_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 拿锁(毒化时恢复继续): 一个测试 panic 后不能级联毒死其余测试.
    fn lock_dbus() -> std::sync::MutexGuard<'static, ()> {
        DBUS_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 真实 keyring 是跨进程持久的: 上次运行残留会污染本次, 先清掉测试 key.
    fn clean_test_entries(store: &SecretServiceStore) {
        let _ = store.remove(CredentialKey::Session);
    }

    /// 写入真实 keyring 的测试必须挂这个守卫: 无论正常结束还是 panic,
    /// Drop 都会删掉测试 key, 不把 com.minincm.* 残留留在用户真实钥匙串里.
    struct CleanupOnDrop;
    impl Drop for CleanupOnDrop {
        fn drop(&mut self) {
            let store = SecretServiceStore::new();
            let _ = store.remove(CredentialKey::Session);
        }
    }

    /// 无 D-Bus 时: available() 返回 Unavailable(而非 panic / Backend),
    /// 且 get/put 不 panic. 有 D-Bus 时: available() 为 Ok.
    #[test]
    fn available_is_cached_and_never_panics() {
        let gated = std::env::var("NCM_KEYRING_TEST").ok().as_deref() == Some("1");
        let _guard = gated.then(lock_dbus);
        let _cleanup = gated.then(|| CleanupOnDrop);
        let store = SecretServiceStore::new();
        if gated {
            clean_test_entries(&store);
        }
        let first = store.available();
        let second = store.available();
        // 缓存: 两次结果一致
        assert_eq!(format!("{first:?}"), format!("{second:?}"));
        match first {
            Ok(()) => {
                // 真有 D-Bus: 做一次真实 roundtrip(登录态 cookie 样例)
                store.put(CredentialKey::Session, "MUSIC_U=probe").unwrap();
                assert_eq!(
                    store.get(CredentialKey::Session).unwrap().as_deref(),
                    Some("MUSIC_U=probe")
                );
                store.remove(CredentialKey::Session).unwrap();
                assert_eq!(store.get(CredentialKey::Session).unwrap(), None);
            }
            Err(e) => {
                assert!(
                    matches!(e, CredentialError::Unavailable(_)),
                    "无 D-Bus 应是 Unavailable: {e:?}"
                );
                // IO 路径也不 panic, 返回 Unavailable
                assert!(matches!(
                    store.get(CredentialKey::Session),
                    Err(CredentialError::Unavailable(_))
                ));
                assert!(matches!(
                    store.put(CredentialKey::Session, "x"),
                    Err(CredentialError::Unavailable(_))
                ));
                assert!(matches!(
                    store.remove(CredentialKey::Session),
                    Err(CredentialError::Unavailable(_))
                ));
            }
        }
    }

    // 可选 spike: 仅在 dbus-run-session + gnome-keyring 下跑, 不进默认测试集.
    // 用法(必须 --unlock 空密码解锁默认 collection, 否则 gcr-prompter 在无头会话卡死):
    // dbus-run-session -- bash -c 'printf "" | gnome-keyring-daemon --unlock --replace --components=secrets; sleep 1; NCM_KEYRING_TEST=1 cargo test -p ncm-service keyring_spike'
    // 本机实测(2026-11-12): PASSED(首次探测 ~70s, daemon 启动+prompter 延迟属 dbus-run-session 环境噪声)
    #[test]
    fn keyring_spike_with_dbus() {
        if std::env::var("NCM_KEYRING_TEST").ok().as_deref() != Some("1") {
            return; // 未门控: 空过(CI 无 D-Bus 也绿)
        }
        let _guard = lock_dbus();
        let store = SecretServiceStore::new();
        clean_test_entries(&store);
        let _cleanup = CleanupOnDrop;
        store.available().expect("secret-service 应可用");
        store.put(CredentialKey::Session, "MUSIC_U=spike").unwrap();
        assert_eq!(
            store.get(CredentialKey::Session).unwrap().as_deref(),
            Some("MUSIC_U=spike")
        );
        store.remove(CredentialKey::Session).unwrap();
        assert_eq!(store.get(CredentialKey::Session).unwrap(), None);
    }

    // 真实 D-Bus 会话(本机桌面, NCM_KEYRING_TEST=1 门控): open_backend 必须报 secret-service,
    // 不能误回落 FileStore 同意门; put/get/remove 全链路真实走 secret-service.
    #[test]
    fn open_backend_reports_secret_service_when_available() {
        if std::env::var("NCM_KEYRING_TEST").ok().as_deref() != Some("1") {
            return;
        }
        let _guard = lock_dbus();
        let dir = std::env::temp_dir().join(format!("ncm-cred-ss-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let (creds, status) = crate::credential_store::open_backend(&dir);
        assert_eq!(
            status.backend_name(),
            crate::credential_store::BACKEND_SECRET_SERVICE,
            "有 D-Bus 时应选 secret-service: {:?}",
            status.note()
        );
        assert!(matches!(
            status,
            crate::credential_store::CredentialStatus::Secure { .. }
        ));
        let creds = creds.expect("Secure 状态必须带回后端");
        let _cleanup = CleanupOnDrop;
        creds.available().unwrap();
        creds
            .put(CredentialKey::Session, "MUSIC_U=real-bus")
            .unwrap();
        assert_eq!(
            creds.get(CredentialKey::Session).unwrap().as_deref(),
            Some("MUSIC_U=real-bus")
        );
        creds.remove(CredentialKey::Session).unwrap();
        assert_eq!(creds.get(CredentialKey::Session).unwrap(), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // 降级路径(无 D-Bus): open_backend 应回落同意门, 未同意时写入被拒(AccessDenied),
    // 且不会拿到 secret-service 后端. 注意 zbus 进程内缓存 session 连接, 改
    // DBUS_SESSION_BUS_ADDRESS 对本进程无效 —— 必须用子进程重执行自身来模拟"无 D-Bus".
    const FB_CHILD_ENV: &str = "NCM_KEYRING_FB_CHILD";
    fn fallback_child_logic() {
        let dir = std::env::temp_dir().join(format!("ncm-cred-fb-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let (creds, status) = crate::credential_store::open_backend(&dir);
        assert_eq!(
            status.backend_name(),
            "none",
            "无 D-Bus 未同意应为 none: {:?}",
            status.note()
        );
        assert!(matches!(
            status,
            crate::credential_store::CredentialStatus::PlaintextFallback { .. }
        ));
        assert!(creds.is_none());
        // 未同意: FileStore 同意门拒绝写入
        assert!(matches!(
            crate::credential_store::FileStore::new(&dir).put(CredentialKey::Session, "x"),
            Err(crate::credential_store::CredentialError::AccessDenied(_))
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_backend_falls_back_when_bus_missing() {
        if std::env::var("NCM_KEYRING_TEST").ok().as_deref() != Some("1") {
            return;
        }
        if std::env::var(FB_CHILD_ENV).ok().as_deref() == Some("1") {
            fallback_child_logic();
            return;
        }
        let _guard = lock_dbus();
        let exe = std::env::current_exe().expect("current_exe");
        let out = std::process::Command::new(exe)
            .args([
                "keyring",
                "--exact",
                "open_backend_falls_back_when_bus_missing",
                "--nocapture",
            ])
            .env(FB_CHILD_ENV, "1")
            .env(
                "DBUS_SESSION_BUS_ADDRESS",
                "unix:path=/nonexistent-ncm-test-bus",
            )
            .output()
            .expect("重执行测试子进程");
        assert!(
            out.status.success(),
            "降级子进程应通过(无 D-Bus 时 open_backend 必须回落):\n{}",
            String::from_utf8_lossy(&out.stdout)
        );
    }

    #[test]
    fn map_err_classifies_no_entry() {
        assert!(matches!(
            map_err(&keyring::Error::NoEntry, "t"),
            CredentialError::Unavailable(_)
        ));
        assert!(matches!(
            map_err(&keyring::Error::TooLong("k".into(), 1), "t"),
            CredentialError::Backend(_)
        ));
    }
}
