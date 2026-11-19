//! 插件的 `lx.storage`: 命名空间隔离的键值存储.
//!
//! 隔离口径: 每个插件实例一个 namespace(默认取插件名), 同一份 [`Storage`]
//! 里不同 namespace 互不可见 —— 这是契约的一部分, 有专项用例.
//! 本切片只提供内存实现; 落盘(SQLite/文件)是后续切片的事.

use std::collections::BTreeMap;
use std::sync::Mutex;

/// 命名空间化的键值存储. `value` 是 JSON 文本(由脚本侧 stringify).
pub trait Storage: Send + Sync {
    fn get(&self, namespace: &str, key: &str) -> Option<String>;
    fn set(&self, namespace: &str, key: &str, value: String);
    fn remove(&self, namespace: &str, key: &str);
    /// 按 key 字典序返回该 namespace 下的全部 key.
    fn keys(&self, namespace: &str) -> Vec<String>;
}

/// 纯内存实现(进程内共享, 适合测试与后续"非持久化插件").
#[derive(Default)]
pub struct MemoryStorage {
    map: Mutex<BTreeMap<(String, String), String>>,
}

impl MemoryStorage {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<(String, String), String>> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Storage for MemoryStorage {
    fn get(&self, namespace: &str, key: &str) -> Option<String> {
        self.lock()
            .get(&(namespace.to_string(), key.to_string()))
            .cloned()
    }

    fn set(&self, namespace: &str, key: &str, value: String) {
        self.lock()
            .insert((namespace.to_string(), key.to_string()), value);
    }

    fn remove(&self, namespace: &str, key: &str) {
        self.lock()
            .remove(&(namespace.to_string(), key.to_string()));
    }

    fn keys(&self, namespace: &str) -> Vec<String> {
        self.lock()
            .range((namespace.to_string(), String::new())..)
            .take_while(|((ns, _), _)| ns == namespace)
            .map(|((_, key), _)| key.clone())
            .collect()
    }
}
