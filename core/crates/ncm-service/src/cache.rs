//! 音频缓存: 直链有时效, 播完即缓存文件, 复播不再走网络.

use std::path::{Path, PathBuf};

pub struct AudioCache {
    dir: PathBuf,
}

impl AudioCache {
    pub fn open(dir: &Path) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        Ok(Self {
            dir: dir.to_path_buf(),
        })
    }

    pub fn path_for(&self, track_id: u64, url: &str) -> PathBuf {
        let ext = if url.contains(".flac") {
            "flac"
        } else if url.contains(".m4a") {
            "m4a"
        } else {
            "mp3"
        };
        self.dir.join(format!("{track_id}.{ext}"))
    }

    pub fn cached(&self, track_id: u64, url: &str) -> Option<PathBuf> {
        let p = self.path_for(track_id, url);
        match std::fs::metadata(&p) {
            Ok(m) if m.len() > 64 * 1024 => Some(p),
            _ => None,
        }
    }

    /// 下载到临时文件后原子改名; 已存在则直接返回.
    pub async fn fetch(&self, track_id: u64, url: &str) -> Result<PathBuf, String> {
        if let Some(p) = self.cached(track_id, url) {
            return Ok(p);
        }
        let final_path = self.path_for(track_id, url);
        let tmp = final_path.with_extension("part");
        let resp = reqwest::get(url).await.map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(format!("http {}", resp.status()));
        }
        let bytes = resp.bytes().await.map_err(|e| e.to_string())?;
        if bytes.len() < 64 * 1024 {
            return Err(format!("suspiciously small audio: {} bytes", bytes.len()));
        }
        std::fs::write(&tmp, &bytes).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &final_path).map_err(|e| e.to_string())?;
        Ok(final_path)
    }
}

/// 一次容量收敛的结果(R5: 缓存占用上限)
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CacheEviction {
    /// 删掉的文件数
    pub removed: usize,
    /// 释放的字节数
    pub freed_bytes: u64,
    /// 收敛后的总占用
    pub total_bytes: u64,
}

impl AudioCache {
    /// 缓存目录里所有已完成文件(不含 `.part`)的 (路径, 大小, 修改时间)
    fn entries(&self) -> Vec<(PathBuf, u64, std::time::SystemTime)> {
        let mut out = Vec::new();
        let Ok(dir) = std::fs::read_dir(&self.dir) else {
            return out;
        };
        for entry in dir.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("part") {
                continue; // 正在下载的临时文件不参与淘汰
            }
            let Ok(meta) = entry.metadata() else { continue };
            if !meta.is_file() || meta.len() < 64 * 1024 {
                continue;
            }
            let mtime = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
            out.push((path, meta.len(), mtime));
        }
        out
    }

    /// 不看直链, 直接按曲目 id 找已缓存文件(响度测量等后台任务用)
    pub fn cached_path(&self, track_id: u64) -> Option<PathBuf> {
        let prefix = format!("{track_id}.");
        self.entries()
            .into_iter()
            .find(|(p, _, _)| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.starts_with(prefix.as_str()))
                    .unwrap_or(false)
            })
            .map(|(p, _, _)| p)
    }

    /// 已完成缓存文件的数量(不含 .part)
    pub fn file_count(&self) -> usize {
        self.entries().len()
    }

    /// 当前缓存总占用(字节, 不含 .part)
    pub fn total_bytes(&self) -> u64 {
        self.entries().iter().map(|(_, size, _)| *size).sum()
    }

    /// 按「最久未修改优先」淘汰, 直到总占用 <= limit_bytes。
    ///
    /// - `limit_bytes == 0` 表示不限制(直接返回当前占用)。
    /// - `keep_track_id`: 正在播放的曲目对应的文件**永不删除**(R5 的验收口径)。
    /// - 只删已完成文件(`.part`)与小于 64 KiB 的残片不参与统计/删除。
    pub fn enforce_limit(
        &self,
        limit_bytes: u64,
        keep_track_id: Option<u64>,
    ) -> Result<CacheEviction, String> {
        let mut entries = self.entries();
        let mut total: u64 = entries.iter().map(|(_, size, _)| *size).sum();
        if limit_bytes == 0 || total <= limit_bytes {
            return Ok(CacheEviction {
                removed: 0,
                freed_bytes: 0,
                total_bytes: total,
            });
        }
        entries.sort_by_key(|(_, _, mtime)| *mtime);

        let keep_prefix = keep_track_id.map(|id| format!("{id}."));
        let mut removed = 0usize;
        let mut freed = 0u64;
        for (path, size, _) in entries {
            if total <= limit_bytes {
                break;
            }
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if let Some(prefix) = &keep_prefix {
                if name.starts_with(prefix.as_str()) {
                    continue; // 正在播放的文件不动
                }
            }
            match std::fs::remove_file(&path) {
                Ok(()) => {
                    removed += 1;
                    freed += size;
                    total = total.saturating_sub(size);
                }
                // 删不掉(被占用/权限)就跳过, 不要把整个流程打断
                Err(e) => eprintln!("[cache] evict {} failed: {e}", path.display()),
            }
        }
        Ok(CacheEviction {
            removed,
            freed_bytes: freed,
            total_bytes: total,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "ncm-cache-test-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    const KIB: usize = 1024;
    /// 让文件大于 64 KiB 的门槛
    fn write_track(dir: &Path, name: &str, kib: usize) {
        std::fs::write(dir.join(name), vec![0u8; kib * KIB]).unwrap();
    }

    /// 逐个文件设置 mtime, 用相对顺序模拟"最久未使用"
    fn touch(dir: &Path, name: &str, secs_ago: u64) {
        let path = dir.join(name);
        let t = std::time::SystemTime::now() - std::time::Duration::from_secs(secs_ago);
        let f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
        f.set_modified(t).unwrap();
    }

    #[test]
    fn total_bytes_ignores_partial_files() {
        let tmp = TempDir::new("total");
        write_track(&tmp.0, "1.mp3", 100);
        write_track(&tmp.0, "2.mp3.part", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();
        assert_eq!(cache.total_bytes(), 100 * 1024);
    }

    #[test]
    fn enforce_limit_evicts_oldest_first() {
        let tmp = TempDir::new("evict");
        write_track(&tmp.0, "1.mp3", 100);
        write_track(&tmp.0, "2.mp3", 100);
        write_track(&tmp.0, "3.mp3", 100);
        touch(&tmp.0, "1.mp3", 300);
        touch(&tmp.0, "2.mp3", 200);
        touch(&tmp.0, "3.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();

        // 上限 250 KiB: 必须删掉最老的 1.mp3, 剩 200 KiB
        let r = cache.enforce_limit(250 * 1024, None).unwrap();
        assert_eq!(r.removed, 1);
        assert_eq!(r.total_bytes, 200 * 1024);
        assert!(!tmp.0.join("1.mp3").exists());
        assert!(tmp.0.join("2.mp3").exists() && tmp.0.join("3.mp3").exists());
    }

    #[test]
    fn enforce_limit_never_deletes_currently_playing_track() {
        let tmp = TempDir::new("keep");
        write_track(&tmp.0, "7.mp3", 100);
        write_track(&tmp.0, "8.mp3", 100);
        touch(&tmp.0, "7.mp3", 500); // 7 最老, 但它正在播
        touch(&tmp.0, "8.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();

        let r = cache.enforce_limit(150 * 1024, Some(7)).unwrap();
        assert!(tmp.0.join("7.mp3").exists(), "正在播放的文件不能被淘汰");
        assert!(!tmp.0.join("8.mp3").exists());
        assert_eq!(r.removed, 1);
        assert_eq!(r.total_bytes, 100 * 1024);
    }

    #[test]
    fn under_limit_is_noop() {
        let tmp = TempDir::new("noop");
        write_track(&tmp.0, "1.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();
        let r = cache.enforce_limit(10 * 1024 * 1024, None).unwrap();
        assert_eq!(r.removed, 0);
        assert_eq!(r.freed_bytes, 0);
    }

    #[test]
    fn zero_limit_means_unlimited() {
        let tmp = TempDir::new("zero");
        write_track(&tmp.0, "1.mp3", 100);
        let cache = AudioCache::open(&tmp.0).unwrap();
        let r = cache.enforce_limit(0, None).unwrap();
        assert_eq!(r.removed, 0);
        assert!(tmp.0.join("1.mp3").exists());
    }
}
