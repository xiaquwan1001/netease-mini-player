//! 插件的 `lx.storage`: 命名空间隔离的键值存储.
//!
//! 隔离口径: 每个插件实例一个 namespace(默认取插件名), 同一份 [`Storage`]
//! 里不同 namespace 互不可见 —— 这是契约的一部分, 有专项用例.
//!
//! 两个实现:
//! - [`MemoryStorage`]: 进程内(默认, 测试用; 也是"非持久化插件"的落点);
//! - [`FileStorage`]: 落盘实现 —— 每个 namespace 一个 JSON 文件, 权限 0600,
//!   写入走 tmp + rename 原子替换. 落盘目录由**宿主传入**([`FileStorage::open`]),
//!   本模块不读 `$HOME` 也不猜平台路径.

use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};
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

/// 落盘实现: 每个 namespace 一个 `<stem>.json` 文件.
///
/// 磁盘形状(单文件): `{"<key>": "<value 的 JSON 文本>"}` —— value 按**字符串**存,
/// 本层不解释它的内层结构(脚本侧写什么就存什么, 读回去原样交还).
///
/// 三条硬口径:
/// 1. **原子替换**: 先写同目录下的 `.tmp` 再用 `rename` 换上去 —— 任何时刻磁盘上的
///    正式文件要么是旧的完整内容, 要么是新的完整内容, 不会是半截;
/// 2. **0600**: 临时文件创建时就是属主读写(rename 不改 mode, 正式文件因此也是 0600),
///    插件存的东西可能含账号相关 token, 不留给同机其他用户;
/// 3. **坏文件当空**: JSON 损坏/不是对象/读失败一律当"这个 namespace 还没有数据",
///    绝不 panic(插件文件坏了最多丢配置, 不能把 App 带崩).
///
/// namespace 到文件名的映射见 [`FileStorage::path_for`]: 清洗非法字符 + 附 FNV-1a 短哈希,
/// 所以 `a/b` 与 `a_b` 不会撞到同一个文件, 也不存在 `../` 逃出目录的可能.
pub struct FileStorage {
    dir: PathBuf,
    /// namespace -> 已加载的键值表(写时同步落盘, 读时懒加载一次).
    ///
    /// 缓存是"加速 + 保证同一进程内 read-your-writes"的手段, 不是事实来源:
    /// 落盘失败只记 stderr, 内存视图保持可用(下同, 见 `persist`).
    cache: Mutex<HashMap<String, BTreeMap<String, String>>>,
}

impl FileStorage {
    /// 打开(必要时创建)落盘目录. 目录由宿主给 —— 本模块不认识平台路径规范.
    pub fn open(dir: impl Into<PathBuf>) -> std::io::Result<Self> {
        let dir = dir.into();
        std::fs::create_dir_all(&dir)?;
        Ok(Self {
            dir,
            cache: Mutex::new(HashMap::new()),
        })
    }

    /// 落盘目录.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// 某个 namespace 对应的文件路径(也用于测试断言"没有残留 tmp / 权限").
    pub fn path_for(&self, namespace: &str) -> PathBuf {
        self.dir.join(format!("{}.json", file_stem(namespace)))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, BTreeMap<String, String>>> {
        self.cache.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 读磁盘; 任何异常都退化成空表(见类型注释第 3 条).
    fn load(&self, namespace: &str) -> BTreeMap<String, String> {
        let path = self.path_for(namespace);
        match std::fs::read(&path) {
            Ok(bytes) => {
                serde_json::from_slice::<BTreeMap<String, String>>(&bytes).unwrap_or_default()
            }
            Err(_) => BTreeMap::new(),
        }
    }

    /// 原子落盘: tmp(0600) -> fsync -> rename.
    ///
    /// 与 `ncm-service/src/fsutil.rs` 的 `write_atomic_inner` 是**两份**独立实现(依赖方向
    /// service -> plugin, 不能反向复用): 顺序必须一致(tmp → 写 → fsync → 改权限 → rename),
    /// 那边还多一层进程内写锁 + 每写唯一的 tmp 名(`{name}.tmp.{pid}.{seq}`), 本实现靠
    /// `cache` Mutex 全程串行 + 带 pid 的 tmp 名达到同样效果.
    /// 改一侧就去看另一侧(那边有反向注释指回这里), 合并成一份要先把依赖方向理顺.
    fn persist(&self, namespace: &str, map: &BTreeMap<String, String>) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(map).map_err(std::io::Error::other)?;
        let stem = file_stem(namespace);
        let tmp = self.dir.join(format!(".{stem}.tmp.{}", std::process::id()));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        let final_path = self.dir.join(format!("{stem}.json"));
        std::fs::rename(&tmp, &final_path)?;
        // create 已给 0600; 这里再钉一次, 防的是"上一轮遗留的 tmp 用了别的 mode"这类意外.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&final_path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }

    /// 拿 namespace 的键值表并执行一次操作; `dirty` 为真时落盘.
    fn with_map<R>(
        &self,
        namespace: &str,
        op: impl FnOnce(&mut BTreeMap<String, String>) -> (R, bool),
    ) -> R {
        let mut guard = self.lock();
        let map = guard
            .entry(namespace.to_string())
            .or_insert_with(|| self.load(namespace));
        let (value, dirty) = op(map);
        if dirty {
            if let Err(err) = self.persist(namespace, map) {
                // 契约里 `Storage` 的写接口没有错误通道(脚本侧 `lx.storage.set` 是同步的),
                // 落盘失败不打断脚本, 但要留痕: 下次启动最多读回旧值.
                eprintln!("[ncm-plugin] lx.storage 落盘失败(namespace={namespace}): {err}");
            }
        }
        value
    }
}

impl Storage for FileStorage {
    fn get(&self, namespace: &str, key: &str) -> Option<String> {
        self.with_map(namespace, |map| (map.get(key).cloned(), false))
    }

    fn set(&self, namespace: &str, key: &str, value: String) {
        self.with_map(namespace, |map| {
            map.insert(key.to_string(), value);
            ((), true)
        })
    }

    fn remove(&self, namespace: &str, key: &str) {
        self.with_map(namespace, |map| {
            let existed = map.remove(key).is_some();
            ((), existed)
        })
    }

    fn keys(&self, namespace: &str) -> Vec<String> {
        self.with_map(namespace, |map| (map.keys().cloned().collect(), false))
    }
}

/// namespace -> 文件名主干: 只留 `[A-Za-z0-9_-]`, 其余(含 `.`)替换成 `_`,
/// 末尾附 16 位 FNV-1a 哈希(区分清洗后会撞名的 namespace), 长度截到 48 字符.
///
/// 连 `.` 都不留是有意的: 允许它就得逐个处理 `.` / `..` / `..\\` 这几种目录项,
/// 一旦漏一个就是路径逃逸; 插件名字用不到点号.
fn file_stem(namespace: &str) -> String {
    let mut cleaned = String::with_capacity(namespace.len());
    for ch in namespace.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-') {
            cleaned.push(ch);
        } else {
            cleaned.push('_');
        }
    }
    let cleaned = if cleaned.is_empty() {
        "ns".to_string()
    } else {
        cleaned
    };
    let stub: String = cleaned.chars().take(48).collect();
    format!("{stub}-{:016x}", fnv1a(namespace))
}

fn fnv1a(text: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}
