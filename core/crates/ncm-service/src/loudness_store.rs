//! 响度测量结果缓存(`loudness.json`): 每曲只测一次, 未测曲目先按 0 dB 播放.
//!
//! 语义(任务书 §2.1): key = trackId, value = {lufs, sample_peak, measured_at_ms}.
//! 文件与 settings.json 同目录(数据目录), 原子写(先 .tmp 再 rename)避免断电写坏.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use ncm_domain::TrackLoudness;

/// 文件名: 与 `fsutil` 的目录归属表一致(见 [crate::fsutil]).
const FILE: &str = "loudness.json";

/// 进程内写锁: 把 `open → 改一条 → 整表写回` 圈成一个原子段.
///
/// 为什么必须在 store 内部而不是调用方: FFI 的形态是**每次调用都新建一个 store**
/// (读全表) → 改一条 → 整表写回, 两个测量任务并发时后落盘的那份是过期快照,
/// 会把对方那条整表盖掉(丢更新). 对外签名不变, 调用方不感知.
///
/// 只在写入体内持锁还不够: 快照是 `open` 时读的, 所以 [`LoudnessStore::put`] /
/// [`LoudnessStore::remove`] 落盘前**在锁内重新读一遍磁盘**再合并 —— 这样"别人在我
/// open 之后写的"也能被捞回来.
///
/// 跨进程(两开同一个数据目录)仍会丢更新: 那是真正的多进程锁问题, 不在本轮范围.
static WRITE_LOCK: Mutex<()> = Mutex::new(());

fn write_lock() -> std::sync::MutexGuard<'static, ()> {
    // poison 只意味着上一个持锁者 panic 了; 磁盘上仍是上一份完整文件, 继续用是安全的
    WRITE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// 一条测量记录的来源标记: 未测曲目不需要读它, 但需要知道"测过且失败"(避免每首重测).
#[derive(Debug, Clone, PartialEq)]
pub struct LoudnessStore {
    path: PathBuf,
    entries: BTreeMap<u64, TrackLoudness>,
}

impl LoudnessStore {
    /// 打开(不存在则视为空表). 读不出来就当空表, 不要因为缓存损坏让播放失败.
    pub fn open(dir: &Path) -> Self {
        let path = dir.join(FILE);
        let entries = Self::load(&path);
        Self { path, entries }
    }

    /// 从磁盘读全表(损坏/不存在 ⇒ 空表, 同 [`Self::open`] 的口径).
    fn load(path: &Path) -> BTreeMap<u64, TrackLoudness> {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str::<BTreeMap<String, TrackLoudness>>(&text).ok())
            .map(|raw| {
                raw.into_iter()
                    .filter_map(|(k, v)| k.parse::<u64>().ok().map(|id| (id, v)))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn get(&self, track_id: u64) -> Option<&TrackLoudness> {
        self.entries.get(&track_id)
    }

    /// 记录一次测量(覆盖旧值)并落盘.
    ///
    /// 落盘前在 [`WRITE_LOCK`] 内重读磁盘再合并: 调用方的快照(`open`)可能已经过期,
    /// 直接用旧快照整表写回会把别人刚写的那条抹掉. `_guard` 必须绑成变量 ——
    /// 后面每一步都用 `?` 提前返回, 靠 Drop 解锁而不是手工 unlock.
    pub fn put(&mut self, track_id: u64, entry: TrackLoudness) -> Result<(), String> {
        let _guard = write_lock();
        self.entries = Self::load(&self.path);
        self.entries.insert(track_id, entry);
        self.save()
    }

    /// 删除一条(曲目被替换/纠正时用). 同 [`Self::put`]: 锁内重读再改.
    pub fn remove(&mut self, track_id: u64) -> Result<(), String> {
        let _guard = write_lock();
        self.entries = Self::load(&self.path);
        if self.entries.remove(&track_id).is_none() {
            return Ok(());
        }
        self.save()
    }

    /// 整表写盘. **调用方必须已持 [`WRITE_LOCK`]**(唯一调用点是 put/remove).
    fn save(&self) -> Result<(), String> {
        let raw: BTreeMap<String, &TrackLoudness> = self
            .entries
            .iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        let text = serde_json::to_string_pretty(&raw).map_err(|e| e.to_string())?;
        let dir = self.path.parent().unwrap_or(Path::new("."));
        crate::fsutil::write_atomic(dir, FILE, text.as_bytes()).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ncm-loud-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn entry(lufs: f32) -> TrackLoudness {
        TrackLoudness {
            lufs,
            sample_peak: 0.98,
            measured_at_ms: 1_700_000_000_000,
        }
    }

    #[test]
    fn put_then_reload_round_trips() {
        let dir = temp_dir("rt");
        let mut store = LoudnessStore::open(&dir);
        assert!(store.is_empty());
        store.put(42, entry(-9.5)).unwrap();
        drop(store);

        let store = LoudnessStore::open(&dir);
        assert_eq!(store.len(), 1);
        let got = store.get(42).expect("应能读回");
        assert!((got.lufs + 9.5).abs() < 1e-4);
        assert_eq!(got.measured_at_ms, 1_700_000_000_000);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_degrades_to_empty() {
        let dir = temp_dir("bad");
        std::fs::write(dir.join("loudness.json"), "{not json").unwrap();
        let store = LoudnessStore::open(&dir);
        assert!(store.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_deletes_entry() {
        let dir = temp_dir("rm");
        let mut store = LoudnessStore::open(&dir);
        store.put(1, entry(-14.0)).unwrap();
        store.remove(1).unwrap();
        assert!(store.get(1).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn non_numeric_keys_are_ignored() {
        let dir = temp_dir("keys");
        std::fs::write(
            dir.join("loudness.json"),
            r#"{"oops":{"lufs":-1.0,"sample_peak":0.1,"measured_at_ms":1},"7":{"lufs":-12.0,"sample_peak":0.5,"measured_at_ms":2}}"#,
        )
        .unwrap();
        let store = LoudnessStore::open(&dir);
        assert_eq!(store.len(), 1);
        assert!(store.get(7).is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// R2 判据: 两个线程各自 `open`(拿快照) → 改一条不同的曲目 → 落盘,
    /// 这正是 FFI 的调用形态。修复前两边快照都是空表, 后落盘的那份会把对方那条盖掉。
    #[test]
    fn concurrent_puts_keep_both_tracks() {
        let dir = temp_dir("concurrent");
        // 先让两边都读完快照, 再一起写: 把"丢更新"的窗口钉在判据里(不靠运气)
        let barrier = Arc::new(Barrier::new(2));
        let handles: Vec<_> = [(11u64, -9.0f32), (22u64, -14.0f32)]
            .into_iter()
            .map(|(track_id, lufs)| {
                let dir = dir.clone();
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    let mut store = LoudnessStore::open(&dir);
                    barrier.wait();
                    store.put(track_id, entry(lufs)).expect("put 不应失败");
                })
            })
            .collect();
        for handle in handles {
            handle.join().expect("写线程不应 panic");
        }

        let store = LoudnessStore::open(&dir);
        assert_eq!(store.len(), 2, "两条测量都必须落盘(丢更新 = 少一条)");
        assert!((store.get(11).expect("11 丢了").lufs + 9.0).abs() < 1e-4);
        assert!((store.get(22).expect("22 丢了").lufs + 14.0).abs() < 1e-4);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
