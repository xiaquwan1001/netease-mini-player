//! `FileStorage` 落盘实现用例: 命名空间隔离 / 原子替换 / 0600 / 坏文件当空 / 沙箱预算不回归.
//!
//! 都不联网: transport 用 `MockTransport`, 落盘目录是 `std::env::temp_dir()` 下的临时目录
//! (每个用例自己一份, 结束时尽力清理).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ncm_plugin::{
    FileStorage, MemoryStorage, MockTransport, SandboxConfig, ScriptEngine, Storage,
    TransportResponse,
};
use serde_json::json;

static SEQ: AtomicUsize = AtomicUsize::new(0);

/// 每个用例一个独立临时目录(用完尽力删).
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let mut path = std::env::temp_dir();
        path.push(format!(
            "ncm-plugin-storage-{tag}-{}-{n}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("建临时目录");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn namespaces_stay_isolated_on_disk() {
    let dir = TempDir::new("isolation");
    let storage = FileStorage::open(dir.path()).expect("打开落盘存储");

    storage.set("ns-a", "k", "\"alpha\"".to_string());
    storage.set("ns-b", "k", "\"beta\"".to_string());
    storage.set("ns-b", "only-b", "1".to_string());

    assert_eq!(storage.get("ns-a", "k").as_deref(), Some("\"alpha\""));
    assert_eq!(storage.get("ns-b", "k").as_deref(), Some("\"beta\""));
    assert_eq!(
        storage.get("ns-a", "only-b"),
        None,
        "namespace 之间必须隔离"
    );
    assert_eq!(storage.keys("ns-a"), vec!["k".to_string()]);
    assert_eq!(
        storage.keys("ns-b"),
        vec!["k".to_string(), "only-b".to_string()],
        "keys 按字典序"
    );

    let path_a = storage.path_for("ns-a");
    let path_b = storage.path_for("ns-b");
    assert_ne!(path_a, path_b, "每个 namespace 一个文件");
    assert!(path_a.exists() && path_b.exists());

    // 重开一份(模拟"下次启动"): 内容必须从磁盘读回来.
    let reopened = FileStorage::open(dir.path()).expect("重新打开落盘存储");
    assert_eq!(reopened.get("ns-a", "k").as_deref(), Some("\"alpha\""));
    assert_eq!(reopened.get("ns-b", "only-b").as_deref(), Some("1"));

    // remove 也要落到磁盘
    storage.remove("ns-a", "k");
    let reopened = FileStorage::open(dir.path()).expect("重新打开落盘存储");
    assert_eq!(reopened.get("ns-a", "k"), None);
    assert!(reopened.keys("ns-a").is_empty());
}

#[test]
fn namespace_maps_to_safe_filename() {
    let dir = TempDir::new("paths");
    let storage = FileStorage::open(dir.path()).expect("打开落盘存储");

    // 逃逸面: namespace 来自插件名字, 不能让 `../` 把文件写到目录外
    let evil = storage.path_for("../../etc/passwd");
    assert_eq!(evil.parent(), Some(dir.path()), "文件必须留在落盘目录里");
    let name = evil.file_name().and_then(|n| n.to_str()).expect("文件名");
    assert!(!name.contains('/') && !name.contains('\\') && !name.contains(".."));

    // 清洗后会撞名的两个 namespace 必须落到不同文件(附哈希)
    assert_ne!(storage.path_for("a/b"), storage.path_for("a_b"));
    // 同一 namespace 稳定
    assert_eq!(storage.path_for("demo"), storage.path_for("demo"));

    // 中文/符号 namespace 也能用, 且读写正常
    storage.set("音源·插件 1", "k", "true".to_string());
    assert_eq!(storage.get("音源·插件 1", "k").as_deref(), Some("true"));
    assert_eq!(storage.keys("音源·插件 1"), vec!["k".to_string()]);
}

#[cfg(unix)]
#[test]
fn storage_file_is_owner_only_0600() {
    use std::os::unix::fs::PermissionsExt;

    fn mode_of(path: &Path) -> u32 {
        std::fs::metadata(path)
            .expect("取文件元数据")
            .permissions()
            .mode()
            & 0o777
    }

    let dir = TempDir::new("mode");
    let storage = FileStorage::open(dir.path()).expect("打开落盘存储");
    storage.set("demo", "token", "\"secret\"".to_string());

    let path = storage.path_for("demo");
    assert_eq!(
        mode_of(&path),
        0o600,
        "插件存储可能含账号凭据, 必须 0600: {:o}",
        mode_of(&path)
    );

    // 覆盖写(第二轮 rename)之后仍然是 0600
    storage.set("demo", "token2", "\"secret2\"".to_string());
    assert_eq!(
        mode_of(&path),
        0o600,
        "原子替换后权限不能变松: {:o}",
        mode_of(&path)
    );
}

#[test]
fn corrupt_json_reads_as_empty_and_write_recovers() {
    let dir = TempDir::new("corrupt");
    let storage = FileStorage::open(dir.path()).expect("打开落盘存储");
    let path = storage.path_for("demo");

    // ① 不是 JSON
    std::fs::write(&path, b"{not json at all").expect("写坏文件");
    assert_eq!(storage.get("demo", "k"), None, "坏文件必须当空, 不是 panic");
    assert!(storage.keys("demo").is_empty());

    // ② 是 JSON 但不是对象
    std::fs::write(&path, b"[1,2,3]").expect("写坏文件");
    let reopened = FileStorage::open(dir.path()).expect("重新打开落盘存储");
    assert_eq!(reopened.get("demo", "k"), None);

    // ③ 值不是字符串(内层格式变了)也当空
    std::fs::write(&path, br#"{"k": 1}"#).expect("写坏文件");
    let reopened = FileStorage::open(dir.path()).expect("重新打开落盘存储");
    assert_eq!(reopened.get("demo", "k"), None);

    // ④ 坏文件之后照常写, 落盘恢复成合法 JSON
    reopened.set("demo", "k", "42".to_string());
    assert_eq!(reopened.get("demo", "k").as_deref(), Some("42"));
    let bytes = std::fs::read(&path).expect("读文件");
    let parsed: BTreeMap<String, String> =
        serde_json::from_slice(&bytes).expect("落盘必须是合法 JSON");
    assert_eq!(parsed.get("k").map(String::as_str), Some("42"));
}

#[test]
fn writes_replace_atomically_without_tmp_residue() {
    let dir = TempDir::new("atomic");
    let storage = Arc::new(FileStorage::open(dir.path()).expect("打开落盘存储"));
    let path = storage.path_for("demo");
    // 足够大, 让"写一半被读到"这种非原子实现真的会暴露出来
    let big = format!("\"{}\"", "x".repeat(64 * 1024));
    storage.set("demo", "payload", big.clone());

    let stop = Arc::new(Mutex::new(false));
    let reader = {
        let stop = stop.clone();
        let path = path.clone();
        let big = big.clone();
        std::thread::spawn(move || {
            let mut reads = 0usize;
            let deadline = Instant::now() + Duration::from_secs(10);
            while !*stop.lock().unwrap_or_else(|e| e.into_inner()) {
                assert!(Instant::now() < deadline, "读线程超时(写线程没在跑?)");
                match std::fs::read(&path) {
                    Ok(bytes) => {
                        // 正式文件任何时刻都必须是完整合法的 JSON
                        let parsed: BTreeMap<String, String> = serde_json::from_slice(&bytes)
                            .unwrap_or_else(|e| {
                                panic!("读到半个文件(非原子写): {e}; 长度 {}", bytes.len())
                            });
                        assert_eq!(
                            parsed.get("payload").map(String::as_str),
                            Some(big.as_str())
                        );
                        reads += 1;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => panic!("读磁盘失败: {e}"),
                }
            }
            reads
        })
    };

    for i in 0..120u32 {
        storage.set("demo", "payload", big.clone());
        if i == 60 {
            storage.set("demo", "other", "1".to_string());
        }
    }
    *stop.lock().unwrap_or_else(|e| e.into_inner()) = true;
    let reads = reader.join().expect("读线程不应 panic");
    assert!(reads > 0, "读线程必须真的读到过正式文件");

    // 没有残留的临时文件(只有一个正式 json)
    let mut names: Vec<String> = std::fs::read_dir(dir.path())
        .expect("列目录")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    names.sort();
    assert_eq!(names.len(), 1, "不应残留 tmp 文件: {names:?}");
    assert!(names[0].ends_with(".json"), "{names:?}");
}

#[test]
fn sandbox_request_budget_still_applies_with_file_storage() {
    let dir = TempDir::new("budget");
    let storage = Arc::new(FileStorage::open(dir.path()).expect("打开落盘存储"));
    let transport = Arc::new(MockTransport::new().on(
        "example.test",
        Ok(TransportResponse {
            status: 200,
            headers: vec![],
            body: "{}".to_string(),
        }),
    ));
    let mut engine = ScriptEngine::new(
        include_str!("fixtures/storage_budget.js"),
        SandboxConfig {
            call_timeout: Duration::from_millis(500),
            ..SandboxConfig::default()
        },
        transport.clone(),
        storage.clone(),
        "demo",
    )
    .expect("engine 装载失败");

    let err = engine
        .invoke("musicUrl", json!([]))
        .expect_err("第 9 次请求必须被预算拒绝");
    assert!(err.detail.contains("上限"), "detail: {}", err.detail);
    assert_eq!(
        transport.requests().len(),
        8,
        "预算仍是 8 次, 换落盘 storage 不该放宽"
    );

    // 落盘侧证据: 新开一份能读到脚本写进去的键
    let reopened = FileStorage::open(dir.path()).expect("重新打开落盘存储");
    assert_eq!(reopened.get("demo", "hits").as_deref(), Some("1"));
}

#[test]
fn memory_storage_keeps_its_semantics() {
    // 防线: 落盘实现不改变内存实现(同名键 / namespace 隔离)
    let storage = MemoryStorage::new();
    storage.set("a", "k", "1".to_string());
    assert_eq!(storage.get("a", "k").as_deref(), Some("1"));
    assert_eq!(storage.get("b", "k"), None);
}
