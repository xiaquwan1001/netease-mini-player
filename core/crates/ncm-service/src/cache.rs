//! 音频缓存: 直链有时效, 播完即缓存文件, 复播不再走网络.

use std::path::{Path, PathBuf};

pub struct AudioCache {
    dir: PathBuf,
}

impl AudioCache {
    pub fn open(dir: &Path) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        Ok(Self { dir: dir.to_path_buf() })
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
