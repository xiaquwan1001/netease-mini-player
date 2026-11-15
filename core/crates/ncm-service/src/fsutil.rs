//! 原子落盘 + `<dataDir>` 目录/文件归属表(跨语言契约的唯一出处).
//!
//! ## 为什么集中在这里
//!
//! 所有"写完才算数"的 JSON/文本/二进制文件都走同一条路径:
//! `create_dir_all(dir)` → 写 `<dir>/<name>.tmp` → `rename` 成 `<dir>/<name>`.
//! rename 之前读者看不到半截文件, 掉电最多丢掉这一次写, 不会让下次启动去读坏文件.
//!
//! Windows 仍按既有做法处理: 不额外做"删了目标再 rename"的退化尝试 ——
//! 目标被别的进程开着时 rename 会失败, 此时旧文件必须原样保留(宁可这次写失败,
//! 也不能把上一份好数据删掉). 见 ncm-ffi `play_track` 处的平台差异说明.
//!
//! ## `<dataDir>` 下谁写什么(改路径/改名先改这张表)
//!
//! Rust 侧(ncm-service), 本文件统一为原子写:
//!
//! | 路径 | owner | 说明 |
//! |---|---|---|
//! | `identity.json` | `identity.rs` IdentityStore | 设备指纹 + 会话骨架(登录键在凭据后端), 0600 |
//! | `accounts.json` | `identity.rs` AccountBook | 多账号簿(昵称/头像/vip + 每账号登录键), 0600 |
//! | `history.json` | `history.rs` HistoryStore | 搜索历史 + 播放历史兜底, 0600 |
//! | `credential_policy.json` | `credential_store.rs` CredentialPolicy | 明文回退同意标记 + 迁移标记, 0600 |
//! | `credentials.json` | `credential_store.rs` FileStore | 0600 明文凭据后端(需用户同意) |
//! | `credentials.dpapi` | `credential_store.rs` DpapiStore(仅 Windows) | DPAPI 密文二进制 |
//! | `loudness.json` | `loudness_store.rs` LoudnessStore | 每曲响度测量缓存 |
//! | `ttml/` | `ttml_source.rs` | `<id>.ttml` 逐字歌词正文, `<id>.none` "无数据"标记 |
//!
//! Rust 侧(ncm-ffi, 目录由 FFI 传入, 不经过本模块):
//!
//! | 路径 | owner | 说明 |
//! |---|---|---|
//! | `audio/` | `ncm-ffi` -> `cache.rs` AudioCache | `<trackId>.<ext>` 音频缓存, 下载中为 `.part`(`.part` 命名是清理规则的契约, 别改成 `.tmp`) |
//!
//! Dart 侧(ui/lib, 与 Rust 共用同一个 dataDir):
//!
//! | 路径 | owner | 说明 |
//! |---|---|---|
//! | `settings.json` | `app_settings.dart` | UI/播放偏好(坏了写 `settings.json.bad`) |
//! | `play_state.json` | `playback_state.dart` | 现场恢复(队列/进度/音量) |
//! | `cache/daily-playlists/` | `daily_cache.dart` | `YYYY-MM-DD.json` 每日推荐歌单 + `last-cleanup` 清理时间戳 |
//! | `debug/` | `debug_report.dart` | `anonymous-report-<stamp>.json` 诊断报告 |
//!
//! 不在 dataDir 下的相关落盘(易混, 记一笔): Android Keystore 密文在
//! `filesDir/cred/<key>.bin`(Kotlin 侧写); 边下边播的 Media3 缓存走
//! `cacheDir/audio`(见 PlaybackService, 与 `dataDir/audio` 不共享);
//! 图片另存在 `~/Pictures/MiniNCM`(image_io.dart).

use std::io;
use std::path::Path;

/// 原子写: 建目录 → 写 `<name>.tmp` → rename 成 `<name>`. 普通权限(0644 umask).
pub fn write_atomic(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    write_atomic_inner(dir, name, bytes, false)
}

/// 同 [write_atomic], 但落盘文件是 **0600(unix)** 的敏感文件(身份/账号/历史/凭据).
pub fn write_atomic_private(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    write_atomic_inner(dir, name, bytes, true)
}

fn write_atomic_inner(dir: &Path, name: &str, bytes: &[u8], private: bool) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!("{name}.tmp"));
    std::fs::write(&tmp, bytes)?;
    if private {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            // 先改权限再 rename: 正式文件名下永远不会出现 0644 的瞬间
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        }
    }
    std::fs::rename(&tmp, dir.join(name))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ncm-fsutil-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        dir
    }

    #[test]
    fn creates_missing_dir_and_leaves_no_tmp() {
        let dir = temp_dir("mkdir").join("nested");
        write_atomic(&dir, "a.json", b"{}").unwrap();
        assert_eq!(std::fs::read(dir.join("a.json")).unwrap(), b"{}");
        assert!(!dir.join("a.json.tmp").exists(), "临时文件必须被 rename 走");
    }

    #[test]
    fn overwrite_replaces_whole_file() {
        let dir = temp_dir("overwrite");
        write_atomic(&dir, "a.json", b"{\"long\":\"payload\"}").unwrap();
        write_atomic(&dir, "a.json", b"{}").unwrap();
        assert_eq!(std::fs::read(dir.join("a.json")).unwrap(), b"{}");
        assert!(!dir.join("a.json.tmp").exists());
    }

    #[cfg(unix)]
    #[test]
    fn private_is_0600_plain_is_not_forced() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("mode");
        write_atomic_private(&dir, "identity.json", b"{}").unwrap();
        let mode = std::fs::metadata(dir.join("identity.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "敏感文件必须 0600");
    }

    #[test]
    fn name_with_extension_uses_single_tmp_suffix() {
        let dir = temp_dir("name");
        write_atomic(&dir, "42.ttml", b"<tt/>").unwrap();
        assert!(dir.join("42.ttml").exists());
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "残留: {leftovers:?}");
    }
}
