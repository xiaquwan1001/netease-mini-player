//! Android Keystore 的 Rust 侧桥接后端（lane p1, 方案 B "写穿 + 写后缓冲"）.
//!
//! 见 docs/android-keystore-wiring-design.md: Rust 内存 BTreeMap 是**权威**,
//! Dart 经 FFI 拉走 pending 并落 Android Keystore(`ncm/keystore` 通道).
//!
//! 为什么不用 cfg(target_os = "android") 圈死: 纯内存实现无平台依赖,
//! 不圈死才能在 Linux CI 上跑同一套单测(判据④); 真正接进 `open_backend`
//! 的只有 android 分支.
//!
//! 不落任何磁盘文件 —— Keystore 密文由 Kotlin 侧写 `filesDir/cred/<key>.bin`.

use super::credential_store::{CredentialError, CredentialKey, CredentialStore};
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};

/// 一条待 Dart 落 Keystore 的操作. 同 key 只保留最新一条(drain 语义 = 最终态).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredOp {
    Put { key: String, value: String },
    Remove { key: String },
}

impl CredOp {
    pub fn key(&self) -> &str {
        match self {
            CredOp::Put { key, .. } | CredOp::Remove { key } => key,
        }
    }
}

/// 内存权威 + pending 缓冲. 不做任何降级: available 恒 Ok,
/// 激活与否由 `activate`/`channel_backend` 决定(启动逻辑据此走同意门).
pub struct ChannelStore {
    entries: Mutex<BTreeMap<String, String>>,
    pending: Mutex<VecDeque<CredOp>>,
}

impl ChannelStore {
    fn new() -> Self {
        Self {
            entries: Mutex::new(BTreeMap::new()),
            pending: Mutex::new(VecDeque::new()),
        }
    }

    /// 合并条目(幂等): 已存在的 key 以 restore 值覆盖(Keystore 是上次进程的最终态).
    fn merge(&self, entries: &[(String, String)]) {
        let mut map = self.entries.lock().unwrap();
        for (k, v) in entries {
            map.insert(k.clone(), v.clone());
        }
    }

    /// 同 key 合并: 先清掉该 key 的旧 op 再追加, drain 拿到的每 key 只有最终态.
    fn push_pending(&self, op: CredOp) {
        let mut q = self.pending.lock().unwrap();
        q.retain(|o| o.key() != op.key());
        q.push_back(op);
    }
}

impl CredentialStore for ChannelStore {
    fn put(&self, key: CredentialKey, secret: &str) -> Result<(), CredentialError> {
        let id = key.id();
        self.entries
            .lock()
            .unwrap()
            .insert(id.clone(), secret.to_string());
        self.push_pending(CredOp::Put {
            key: id,
            value: secret.to_string(),
        });
        Ok(())
    }

    fn get(&self, key: CredentialKey) -> Result<Option<String>, CredentialError> {
        Ok(self.entries.lock().unwrap().get(&key.id()).cloned())
    }

    fn remove(&self, key: CredentialKey) -> Result<(), CredentialError> {
        let id = key.id();
        self.entries.lock().unwrap().remove(&id);
        self.push_pending(CredOp::Remove { key: id });
        Ok(())
    }

    /// ChannelStore 本身没有失败模式; Keystore 侧的真实可用性由 Dart 在
    /// activate 之前用通道 available() 探测, 不可用就不会走到这里.
    fn available(&self) -> Result<(), CredentialError> {
        Ok(())
    }
}

// ---------------- 进程级桥(FFI 与 open_backend 共用) ----------------

static BRIDGE: OnceLock<Mutex<Option<Arc<ChannelStore>>>> = OnceLock::new();

fn bridge() -> &'static Mutex<Option<Arc<ChannelStore>>> {
    BRIDGE.get_or_init(|| Mutex::new(None))
}

/// Dart 在 rust.init 之前调用: 用 Keystore 现存条目激活桥(幂等, 重复调用合并).
/// 之后 `open_backend` 的 android 分支才会选用它; 不激活则走既有同意门.
pub fn activate(entries: Vec<(String, String)>) {
    let mut guard = bridge().lock().unwrap();
    match &*guard {
        Some(s) => s.merge(&entries),
        None => {
            let s = Arc::new(ChannelStore::new());
            s.merge(&entries);
            *guard = Some(s);
        }
    }
}

/// 已激活的桥(供 open_backend 接线); 未激活返回 None.
pub fn channel_backend() -> Option<Arc<dyn CredentialStore>> {
    let guard = bridge().lock().unwrap();
    guard
        .as_ref()
        .map(|s| s.clone() as Arc<dyn CredentialStore>)
}

/// Dart drain: 拉走全部 pending(清空队列). 同 key 已合并为最终态.
pub fn take_pending() -> Vec<CredOp> {
    match bridge().lock().unwrap().as_ref() {
        Some(s) => std::mem::take(&mut *s.pending.lock().unwrap()).into(),
        None => Vec::new(),
    }
}

/// 仅供测试: 拆桥, 保证用例互不串扰.
#[cfg(test)]
pub fn deactivate_for_test() {
    *bridge().lock().unwrap() = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh(entries: &[(String, String)]) -> Arc<ChannelStore> {
        let s = Arc::new(ChannelStore::new());
        s.merge(entries);
        s
    }

    #[test]
    fn put_get_remove_roundtrip() {
        let s = fresh(&[]);
        s.put(CredentialKey::Session, "MUSIC_U=abc").unwrap();
        s.put(CredentialKey::Account(7), "MUSIC_U=def").unwrap();
        assert_eq!(
            s.get(CredentialKey::Session).unwrap().as_deref(),
            Some("MUSIC_U=abc")
        );
        assert_eq!(
            s.get(CredentialKey::Account(7)).unwrap().as_deref(),
            Some("MUSIC_U=def")
        );
        assert_eq!(s.get(CredentialKey::Account(8)).unwrap(), None);
        s.remove(CredentialKey::Session).unwrap();
        assert_eq!(s.get(CredentialKey::Session).unwrap(), None);
        // remove 后账号凭据不受影响
        assert_eq!(
            s.get(CredentialKey::Account(7)).unwrap().as_deref(),
            Some("MUSIC_U=def")
        );
    }

    #[test]
    fn pending_records_ops_and_coalesces_per_key() {
        let s = fresh(&[]);
        s.put(CredentialKey::Session, "v1").unwrap();
        s.put(CredentialKey::Session, "v2").unwrap();
        s.remove(CredentialKey::Account(7)).unwrap();
        s.put(CredentialKey::Account(7), "v3").unwrap();
        // 直接对内部实现取 pending(不走全局桥)
        let q: Vec<CredOp> = std::mem::take(&mut *s.pending.lock().unwrap()).into();
        assert_eq!(
            q,
            vec![
                CredOp::Put {
                    key: "session".into(),
                    value: "v2".into()
                },
                CredOp::Put {
                    key: "account:7".into(),
                    value: "v3".into()
                },
            ]
        );
    }

    #[test]
    fn merge_is_idempotent_and_overwrites() {
        let s = fresh(&[("session".into(), "old".into())]);
        s.merge(&[
            ("session".into(), "new".into()),
            ("account:1".into(), "a".into()),
        ]);
        s.merge(&[("account:1".into(), "a".into())]);
        assert_eq!(
            s.get(CredentialKey::Session).unwrap().as_deref(),
            Some("new")
        );
        assert_eq!(
            s.get(CredentialKey::Account(1)).unwrap().as_deref(),
            Some("a")
        );
    }

    #[test]
    fn bridge_activate_take_pending_and_fallback() {
        deactivate_for_test();
        // 未激活: open_backend 应该拿不到桥, drain 也为空
        assert!(channel_backend().is_none());
        assert!(take_pending().is_empty());

        activate(vec![("session".into(), "restored".into())]);
        let backend = channel_backend().expect("激活后应有桥");
        assert!(backend.available().is_ok());
        assert_eq!(
            backend.get(CredentialKey::Session).unwrap().as_deref(),
            Some("restored")
        );

        backend.put(CredentialKey::Session, "after-login").unwrap();
        backend.remove(CredentialKey::Account(9)).unwrap();
        let ops = take_pending();
        assert_eq!(
            ops,
            vec![
                CredOp::Put {
                    key: "session".into(),
                    value: "after-login".into()
                },
                CredOp::Remove {
                    key: "account:9".into()
                },
            ]
        );
        // drain 是取走语义: 再拉为空
        assert!(take_pending().is_empty());
        // 重复 activate 合并, 不重建(内存态保留)
        activate(vec![("account:2".into(), "b".into())]);
        let backend = channel_backend().unwrap();
        assert_eq!(
            backend.get(CredentialKey::Session).unwrap().as_deref(),
            Some("after-login")
        );
        assert_eq!(
            backend.get(CredentialKey::Account(2)).unwrap().as_deref(),
            Some("b")
        );
        deactivate_for_test();
        assert!(channel_backend().is_none());
    }

    #[test]
    fn trait_object_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Arc<dyn CredentialStore>>();
    }
}
