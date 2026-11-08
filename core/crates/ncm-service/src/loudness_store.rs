//! 响度测量结果缓存(`loudness.json`): 每曲只测一次, 未测曲目先按 0 dB 播放.
//!
//! 语义(任务书 §2.1): key = trackId, value = {lufs, sample_peak, measured_at_ms}.
//! 文件与 settings.json 同目录(数据目录), 原子写(先 .tmp 再 rename)避免断电写坏.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use ncm_domain::TrackLoudness;

/// 一条测量记录的来源标记: 未测曲目不需要读它, 但需要知道"测过且失败"(避免每首重测).
#[derive(Debug, Clone, PartialEq)]
pub struct LoudnessStore {
    path: PathBuf,
    entries: BTreeMap<u64, TrackLoudness>,
}

impl LoudnessStore {
    /// 打开(不存在则视为空表). 读不出来就当空表, 不要因为缓存损坏让播放失败.
    pub fn open(dir: &Path) -> Self {
        let path = dir.join("loudness.json");
        let entries = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<BTreeMap<String, TrackLoudness>>(&text).ok())
            .map(|raw| {
                raw.into_iter()
                    .filter_map(|(k, v)| k.parse::<u64>().ok().map(|id| (id, v)))
                    .collect()
            })
            .unwrap_or_default();
        Self { path, entries }
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

    /// 记录一次测量(覆盖旧值)并落盘
    pub fn put(&mut self, track_id: u64, entry: TrackLoudness) -> Result<(), String> {
        self.entries.insert(track_id, entry);
        self.save()
    }

    /// 删除一条(曲目被替换/纠正时用)
    pub fn remove(&mut self, track_id: u64) -> Result<(), String> {
        if self.entries.remove(&track_id).is_none() {
            return Ok(());
        }
        self.save()
    }

    fn save(&self) -> Result<(), String> {
        let raw: BTreeMap<String, &TrackLoudness> =
            self.entries.iter().map(|(k, v)| (k.to_string(), v)).collect();
        let text = serde_json::to_string_pretty(&raw).map_err(|e| e.to_string())?;
        let tmp = self.path.with_extension("json.tmp");
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        TrackLoudness { lufs, sample_peak: 0.98, measured_at_ms: 1_700_000_000_000 }
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
}
