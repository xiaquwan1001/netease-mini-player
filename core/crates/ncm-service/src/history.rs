//! 本地历史: 搜索历史 + 播放历史.
//!
//! 搜索历史没有服务端接口, 必须本地存; 播放历史服务端只给登录用户
//! (/api/play-record/song/list), 未登录/离线时用这里的本地记录兜底。
//! 与身份文件同目录, 权限 0600 (列表里也能看到歌名/歌手, 属于隐私数据)。

use std::io;
use std::path::{Path, PathBuf};

use ncm_domain::Song;
use serde::{Deserialize, Serialize};

pub const SEARCH_LIMIT: usize = 20;
pub const PLAYED_LIMIT: usize = 100;

#[derive(Debug, Default, Serialize, Deserialize)]
struct Data {
    #[serde(default)]
    search: Vec<String>,
    #[serde(default)]
    played: Vec<Song>,
}

pub struct HistoryStore {
    path: PathBuf,
}

impl HistoryStore {
    pub fn open(dir: &Path) -> io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        Ok(Self {
            path: dir.join("history.json"),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn load(&self) -> Data {
        std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    fn save(&self, data: &Data) -> io::Result<()> {
        let tmp = self.path.with_extension("json.tmp");
        let body = serde_json::to_vec_pretty(data)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        std::fs::write(&tmp, body)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }

    /// 搜索历史(最近在前)
    pub fn search_history(&self) -> Vec<String> {
        self.load().search
    }

    /// 记一条搜索: 去重(同一关键词提到最前), 最多 SEARCH_LIMIT 条.
    pub fn record_search(&self, keyword: &str) -> io::Result<Vec<String>> {
        let kw = keyword.trim();
        if kw.is_empty() {
            return Ok(self.search_history());
        }
        let mut data = self.load();
        data.search.retain(|s| s != kw);
        data.search.insert(0, kw.to_string());
        data.search.truncate(SEARCH_LIMIT);
        self.save(&data)?;
        Ok(data.search)
    }

    pub fn clear_search(&self) -> io::Result<()> {
        let mut data = self.load();
        data.search.clear();
        self.save(&data)
    }

    /// 本地播放历史(最近在前)
    pub fn played(&self) -> Vec<Song> {
        self.load().played
    }

    /// 记一次播放: 同一首提到最前, 最多 PLAYED_LIMIT 条.
    pub fn record_play(&self, song: &Song) -> io::Result<()> {
        let mut data = self.load();
        data.played.retain(|s| s.id != song.id);
        data.played.insert(0, song.clone());
        data.played.truncate(PLAYED_LIMIT);
        self.save(&data)
    }

    pub fn clear_played(&self) -> io::Result<()> {
        let mut data = self.load();
        data.played.clear();
        self.save(&data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_domain::TrackId;

    fn song(id: u64, name: &str) -> Song {
        Song {
            id: TrackId::new(id),
            name: name.into(),
            artists: vec![],
            album: None,
            duration_ms: 0,
            fee: None,
            playable: true,
        }
    }

    fn temp_store(tag: &str) -> HistoryStore {
        let dir =
            std::env::temp_dir().join(format!("ncm-history-test-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        HistoryStore::open(&dir).unwrap()
    }

    #[test]
    fn search_dedupes_and_keeps_order() {
        let s = temp_store("search");
        s.record_search("晴天").unwrap();
        s.record_search("七里香").unwrap();
        s.record_search("晴天").unwrap();
        assert_eq!(
            s.search_history(),
            vec!["晴天".to_string(), "七里香".to_string()]
        );
        s.clear_search().unwrap();
        assert!(s.search_history().is_empty());
    }

    #[test]
    fn search_caps_at_limit() {
        let s = temp_store("cap");
        for i in 0..(SEARCH_LIMIT + 5) {
            s.record_search(&format!("kw{i}")).unwrap();
        }
        assert_eq!(s.search_history().len(), SEARCH_LIMIT);
        assert_eq!(s.search_history()[0], format!("kw{}", SEARCH_LIMIT + 4));
    }

    #[test]
    fn played_dedupes_and_prepends() {
        let s = temp_store("played");
        s.record_play(&song(1, "a")).unwrap();
        s.record_play(&song(2, "b")).unwrap();
        s.record_play(&song(1, "a")).unwrap();
        let list = s.played();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].id.0, 1);
        s.clear_played().unwrap();
        assert!(s.played().is_empty());
    }

    #[test]
    fn empty_keyword_is_ignored() {
        let s = temp_store("empty");
        s.record_search("   ").unwrap();
        assert!(s.search_history().is_empty());
    }
}
