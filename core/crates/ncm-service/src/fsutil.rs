//! 原子落盘 + `<dataDir>` 目录/文件归属表(跨语言契约的唯一出处).
//!
//! ## 为什么集中在这里
//!
//! 所有"写完才算数"的 JSON/文本/二进制文件都走同一条路径:
//! `create_dir_all(dir)` → 写 `<dir>/<name>.tmp.<pid>.<seq>` → `sync_all` →
//! `rename` 成 `<dir>/<name>`.
//! rename 之前读者看不到半截文件, 掉电最多丢掉这一次写, 不会让下次启动去读坏文件.
//!
//! 三道防线各自防什么见 [`write_atomic_inner`] 的头注释(唯一 tmp 名 / 进程内写锁 / fsync).
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
//! ## dataDir 自己在哪(P-18 后半, 2026-11-17)
//!
//! 桌面端(Linux/Windows)默认目录跟随 application-id:
//! `~/.local/share/io.github.xiaquwan1001.MiniNCM`([`DATA_DIR_APP_ID`]);
//! 更早的版本用的是 `~/.local/share/ncm`([`LEGACY_DATA_DIR_NAME`]), 升级时由
//! [`resolve_desktop_data_dir`] 做**一次性迁移**(见该函数的纪律说明)。
//! `$NCM_DATA_DIR` 是显式指定, 永远不参与迁移; Android 走平台通道传私有目录, 同理不参与。
//!
//! 不在 dataDir 下的相关落盘(易混, 记一笔): Android Keystore 密文在
//! `filesDir/cred/<key>.bin`(Kotlin 侧写); 边下边播的 Media3 缓存走
//! `cacheDir/audio`(见 PlaybackService, 与 `dataDir/audio` 不共享);
//! 图片另存在 `~/Pictures/MiniNCM`(image_io.dart).

use std::io;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

// ---------------------------- 数据目录定位与一次性迁移 ----------------------------
//
// 纪律(改这里之前先读完):
//
// 1. **只搬一次**: 判据是"新目录存在 ⇒ 什么都不做"(幂等)。旧目录里的 `.migrated`
//    标记只是给人看/给排查用的, 不参与判定 —— 所以重复启动、迁移中途掉电再启动都不会
//    重复搬, 也不会把旧目录再搬回来盖掉新数据。
// 2. **新旧同时存在 ⇒ 以新为准**(用户已经在用新版), 旧目录原样留着不动(不删、不标记),
//    由用户在需要时自己清理; 这条规则保证"先手工建过新目录"的人不会被旧数据覆盖。
// 3. **失败保留旧目录并回退到旧目录**: 迁移失败时返回旧路径(等于退回 P-18 之前的行为),
//    用户数据照常可用; 不做"半新半旧"的混合状态(先搬到临时目录, 校验通过才 rename)。
// 4. **迁移必须在打开任何缓存/凭据/播放状态文件之前**: 现在唯一调用点是
//    `ncm-ffi::api::data_dir_default()`(init 里, Core::open 之前), headless/cli 路径
//    不经过它 ⇒ 无 GUI 也安全(纯 std::fs, 不依赖 GLib/DBus/窗口系统)。
// 5. **降级注意**: 迁移后旧目录只剩 `.migrated` 标记, 用旧版本(com.minincm.minincm)
//    启动会当成"首次运行"重新生成 device_id。要降级就先把新目录内容搬回旧目录并删标记。

/// 桌面端默认数据目录名(跟随 application-id, 与 AppStream/deb/desktop 同名)。
pub const DATA_DIR_APP_ID: &str = "io.github.xiaquwan1001.MiniNCM";

/// P-18 之前的桌面端默认数据目录名, **只作为迁移来源**。
pub const LEGACY_DATA_DIR_NAME: &str = "ncm";

/// 迁移成功后留在旧目录里的标记文件名(内容是人类可读的说明)。
pub const MIGRATED_MARKER: &str = ".migrated";

/// `<home>/.local/share/io.github.xiaquwan1001.MiniNCM`
pub fn default_desktop_data_dir(home: &Path) -> PathBuf {
    home.join(".local").join("share").join(DATA_DIR_APP_ID)
}

/// `<home>/.local/share/ncm`(迁移来源, 不要再往这里写新数据)
pub fn legacy_desktop_data_dir(home: &Path) -> PathBuf {
    home.join(".local").join("share").join(LEGACY_DATA_DIR_NAME)
}

/// [`resolve_desktop_data_dir`] 对磁盘做了什么(给日志/测试用; 不参与控制流)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DataDirMigration {
    /// 新目录已存在(正常启动/重复启动): 没碰旧目录。
    KeptCurrent,
    /// 只有旧目录 ⇒ 已迁移到这里。`copied` = 跨设备走的是 copy+校验+rename。
    Migrated { copied: bool },
    /// 两个目录都没有(首次启动): 由上层按需创建。
    NoData,
    /// 该迁移但失败了: 旧目录原样保留, 调用方拿到的是**旧**路径。
    Failed,
}

/// 决定这次启动用哪个数据目录, 需要时把旧目录一次性搬到新目录。
///
/// 返回 `(要用的目录, 发生了什么)`。除了 [`DataDirMigration::Failed`] 之外, 返回的
/// 目录都是 `current`; 失败时返回 `legacy`(旧数据继续可用, 行为退回 P-18 之前)。
pub fn resolve_desktop_data_dir(current: &Path, legacy: &Path) -> (PathBuf, DataDirMigration) {
    if current.exists() {
        return (current.to_path_buf(), DataDirMigration::KeptCurrent);
    }
    if !legacy.is_dir() {
        return (current.to_path_buf(), DataDirMigration::NoData);
    }
    match migrate_dir(legacy, current) {
        Ok(copied) => {
            // 迁移成功是"一次性事件", 用 eprintln 而不是静默: 用户/排障需要知道路径变了。
            eprintln!(
                "[data-dir] 已迁移 {} -> {}{}",
                legacy.display(),
                current.display(),
                if copied {
                    " (跨设备: 复制+校验+rename)"
                } else {
                    ""
                }
            );
            (current.to_path_buf(), DataDirMigration::Migrated { copied })
        }
        Err(e) => {
            eprintln!(
                "[data-dir] 迁移失败({e}), 继续使用旧目录 {}",
                legacy.display()
            );
            (legacy.to_path_buf(), DataDirMigration::Failed)
        }
    }
}

/// 先试同设备 `rename`(原子、最快); 跨设备才走 copy+校验+rename。
fn migrate_dir(legacy: &Path, current: &Path) -> io::Result<bool> {
    if let Some(parent) = current.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let copied = match std::fs::rename(legacy, current) {
        Ok(()) => false,
        Err(e) if is_cross_device(&e) => {
            copy_migrate(legacy, current)?;
            true
        }
        Err(e) => return Err(e),
    };
    write_migration_marker(legacy, current);
    Ok(copied)
}

/// EXDEV 判定: `ErrorKind::CrossesDevices`(1.83+) 或裸 errno 18, 覆盖老内核/老工具链。
fn is_cross_device(e: &io::Error) -> bool {
    matches!(e.kind(), io::ErrorKind::CrossesDevices) || e.raw_os_error() == Some(18)
}

/// 跨设备迁移: 复制到同级的临时目录 → 全量校验(相对路径 + 字节数) → rename 成正式目录。
/// 任一步失败都删临时目录并原样留下旧目录(不会出现"半个新目录")。
fn copy_migrate(legacy: &Path, current: &Path) -> io::Result<()> {
    let tmp = temp_migration_dir(current);
    let _ = std::fs::remove_dir_all(&tmp);
    let result = copy_tree(legacy, &tmp)
        .and_then(|()| verify_tree(legacy, &tmp))
        .and_then(|()| std::fs::rename(&tmp, current));
    if let Err(e) = result {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err(e);
    }
    Ok(())
}

/// 迁移临时目录: 与目标同级(保证最后那步 rename 同设备), 名字带 pid 防并发互相踩。
fn temp_migration_dir(current: &Path) -> PathBuf {
    let name = current
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "data-dir".to_string());
    current.with_file_name(format!("{name}.migrating-{}", std::process::id()))
}

fn copy_tree(src: &Path, dst: &Path) -> io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        let ft = entry.file_type()?;
        if ft.is_dir() {
            copy_tree(&from, &to)?;
        } else if ft.is_file() {
            // std::fs::copy 连权限位一起复制(unix 上 0600 的 identity.json 仍是 0600)
            std::fs::copy(&from, &to)?;
        } else if ft.is_symlink() {
            copy_symlink(&from, &to)?;
        }
        // 其它类型(fifo/socket/设备): 数据目录里不该有, 跳过并让 verify_tree 判失败
    }
    Ok(())
}

#[cfg(unix)]
fn copy_symlink(from: &Path, to: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(std::fs::read_link(from)?, to)
}

#[cfg(not(unix))]
fn copy_symlink(from: &Path, _to: &Path) -> io::Result<()> {
    Err(io::Error::other(format!(
        "不支持迁移符号链接: {}",
        from.display()
    )))
}

/// 校验: 两棵树的"相对路径 + 字节数"清单必须完全一致(不比对内容, 字节数+路径足以
/// 抓住截断/漏文件/多文件这三类真实故障, 且对大缓存目录仍是线性且便宜)。
fn verify_tree(src: &Path, dst: &Path) -> io::Result<()> {
    let a = tree_manifest(src)?;
    let b = tree_manifest(dst)?;
    if a != b {
        let only_src: Vec<_> = a.iter().filter(|e| !b.contains(e)).collect();
        let only_dst: Vec<_> = b.iter().filter(|e| !a.contains(e)).collect();
        return Err(io::Error::other(format!(
            "迁移校验失败: 源 {} 项 / 目标 {} 项; 仅源有 {:?}; 仅目标有 {:?}",
            a.len(),
            b.len(),
            only_src.iter().take(5).collect::<Vec<_>>(),
            only_dst.iter().take(5).collect::<Vec<_>>()
        )));
    }
    Ok(())
}

fn tree_manifest(root: &Path) -> io::Result<Vec<(String, u64)>> {
    let mut out = Vec::new();
    collect_manifest(root, root, &mut out)?;
    out.sort();
    Ok(out)
}

fn collect_manifest(root: &Path, dir: &Path, out: &mut Vec<(String, u64)>) -> io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let rel = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .into_owned();
        let ft = entry.file_type()?;
        if ft.is_dir() {
            out.push((format!("{rel}/"), 0));
            collect_manifest(root, &path, out)?;
        } else {
            // 符号链接按"链接自身"的长度计, 避免跟随目标导致两边口径不一致
            let len = entry.metadata().map(|m| m.len()).unwrap_or(0);
            out.push((rel, len));
        }
    }
    Ok(())
}

/// 迁移后在旧目录留一个 `.migrated` 标记(说明搬去哪了 + 怎么降级)。best-effort:
/// 标记写失败不影响迁移结果(数据已经在正确的位置)。
fn write_migration_marker(legacy: &Path, current: &Path) {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let body = format!(
        "P-18: MiniNCM 数据目录已迁移(2026-11-17), unix_ts={stamp}\n\
         旧路径: {}\n\
         新路径: {}\n\
         本目录只剩这个标记, 不要在这里写数据。\n\
         降级到旧版本: 把新目录内容搬回旧目录并删掉本文件。\n",
        legacy.display(),
        current.display()
    );
    let _ = std::fs::create_dir_all(legacy);
    let _ = std::fs::write(legacy.join(MIGRATED_MARKER), body);
}

/// 原子写: 建目录 → 写 `<name>.tmp.<pid>.<seq>` → `sync_all` → rename 成 `<name>`.
/// 普通权限(0644 umask).
pub fn write_atomic(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    write_atomic_inner(dir, name, bytes, false)
}

/// 同 [write_atomic], 但落盘文件是 **0600(unix)** 的敏感文件(身份/账号/历史/凭据).
pub fn write_atomic_private(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    write_atomic_inner(dir, name, bytes, true)
}

/// 进程内写锁: 所有 `write_atomic*` 的「写 tmp + 改权限 + rename」都在它下面串行执行.
///
/// 三道防线各自防的是不同的事, **不要只留其中一道**:
/// 1. **唯一 tmp 名**(`{name}.tmp.{pid}.{seq}`): 防两个写者共用同一个 tmp. 同名 tmp 时
///    后开会 `truncate` 掉前者正在写的内容, 一方的 rename 还会顺手把另一方仍在写的 inode
///    摘走(对方 rename 就 ENOENT) —— 正式文件因此可能出现两份内容的交错.
///    跨进程靠 pid 区分, 进程内同 pid 靠自增序号区分.
/// 2. **进程内写锁**: 唯一 tmp 名只保证各自的 tmp 干净, "谁最后落地"仍由磁盘时序运气决定 ——
///    先后发起的两次整表重写(history/loudness 这类)可能倒序落地, 表现是较旧的快照盖掉较新的.
///    持锁后落地顺序 = 进锁顺序, 与调用方的程序顺序一致. 锁只包那三件小文件 IO,
///    `create_dir_all` 之外的慢活(序列化/网络)一律在锁外由调用方做完.
/// 3. **`sync_all`**: rename 落了盘而数据还在页缓存时, 掉电会得到一个**长度正确、内容全零**
///    的文件 —— 比读不到更坏(`history.json` 会被 `serde_json` 判坏后回落成空表).
///
/// 实现与 `ncm-plugin/src/storage.rs` 的 `FileStorage::persist` 是**两份**独立实现(依赖方向
/// service → plugin, 不能反向复用), 顺序必须对齐: tmp → 写 → fsync → (改权限) → rename.
/// 改一侧就去看另一侧(那边有反向注释指回这里).
static WRITE_LOCK: Mutex<()> = Mutex::new(());

fn write_lock() -> std::sync::MutexGuard<'static, ()> {
    // 锁被 poison 只可能是"持锁期间 panic"; rename 是最后一步, 那种情况下磁盘上的正式
    // 文件仍是旧的完整内容, 继续用这把锁是安全的 —— 没理由让之后所有写都失败.
    WRITE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// `<name>.tmp.<pid>.<seq>`: 唯一临时名(见 [`WRITE_LOCK`] 第 1 条).
fn tmp_name(name: &str) -> String {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    format!("{name}.tmp.{}.{seq}", std::process::id())
}

fn write_atomic_inner(dir: &Path, name: &str, bytes: &[u8], private: bool) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let final_path = dir.join(name);
    let tmp = dir.join(tmp_name(name));
    let result = {
        let _guard = write_lock();
        write_tmp_then_rename(&tmp, &final_path, bytes, private)
    };
    if result.is_err() {
        // 失败不留残骸: 以前 `?` 提前返回会把 tmp 留在数据目录里(下次启动也认不出它是垃圾)
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// 调用方必须已持 [`WRITE_LOCK`].
fn write_tmp_then_rename(
    tmp: &Path,
    final_path: &Path,
    bytes: &[u8],
    private: bool,
) -> io::Result<()> {
    let mut file = std::fs::File::create(tmp)?;
    file.write_all(bytes)?;
    // rename 之前先把数据刷到盘上(与 ncm-plugin 的 FileStorage::persist 同一顺序)
    file.sync_all()?;
    drop(file);
    if private {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            // 先改权限再 rename: 正式文件名下永远不会出现 0644 的瞬间
            std::fs::set_permissions(tmp, std::fs::Permissions::from_mode(0o600))?;
        }
    }
    std::fs::rename(tmp, final_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

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
        assert!(
            leftover_tmp_files(&dir).is_empty(),
            "临时文件必须被 rename 走"
        );
    }

    #[test]
    fn overwrite_replaces_whole_file() {
        let dir = temp_dir("overwrite");
        write_atomic(&dir, "a.json", b"{\"long\":\"payload\"}").unwrap();
        write_atomic(&dir, "a.json", b"{}").unwrap();
        assert_eq!(std::fs::read(dir.join("a.json")).unwrap(), b"{}");
        assert!(leftover_tmp_files(&dir).is_empty());
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
    fn name_with_extension_replaces_in_place_without_leftover_tmp() {
        let dir = temp_dir("name");
        write_atomic(&dir, "42.ttml", b"<tt/>").unwrap();
        assert!(dir.join("42.ttml").exists());
        let leftovers = leftover_tmp_files(&dir);
        assert!(leftovers.is_empty(), "残留: {leftovers:?}");
    }

    /// 目录里所有临时文件名(`{name}.tmp.{pid}.{seq}`).
    fn leftover_tmp_files(dir: &Path) -> Vec<String> {
        std::fs::read_dir(dir)
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.contains(".tmp"))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// R1 判据: 两个线程各写同名文件、payload 长度不同、各写 N 次(模拟 history.json
    /// 的两份并发快照), 同时有读者在跑:
    /// - 读者看到的每一份都必须是**完整的某一份**, 不能是两份内容的拼接;
    /// - 每次写的**rename 都不能失败**(同名 tmp 时一方会把另一方仍在写的 inode 摘走 ⇒ ENOENT);
    /// - 事后目录里不留任何 tmp 残骸.
    #[test]
    fn concurrent_writes_never_interleave_and_leave_no_tmp() {
        use std::sync::atomic::{AtomicBool, AtomicUsize};

        const ROUNDS: usize = 200;
        let dir = temp_dir("concurrent");
        std::fs::create_dir_all(&dir).unwrap();
        let short = vec![b'a'; 8 * 1024];
        let long = vec![b'b'; 200 * 1024];

        let stop = std::sync::Arc::new(AtomicBool::new(false));
        let bad_reads = std::sync::Arc::new(AtomicUsize::new(0));
        let reader = {
            let dir = dir.clone();
            let stop = stop.clone();
            let bad_reads = bad_reads.clone();
            let (short, long) = (short.clone(), long.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    let Ok(bytes) = std::fs::read(dir.join("history.json")) else {
                        // 文件还不存在(第一次写之前)不算错
                        continue;
                    };
                    if bytes != short && bytes != long {
                        bad_reads.fetch_add(1, Ordering::Relaxed);
                    }
                }
            })
        };

        let writers: Vec<_> = [short.clone(), long.clone()]
            .into_iter()
            .map(|payload| {
                let dir = dir.clone();
                std::thread::spawn(move || {
                    let mut errors = Vec::new();
                    for _ in 0..ROUNDS {
                        if let Err(e) = write_atomic(&dir, "history.json", &payload) {
                            errors.push(e.to_string());
                        }
                    }
                    errors
                })
            })
            .collect();

        let mut errors = Vec::new();
        for writer in writers {
            errors.extend(writer.join().expect("写线程不应 panic"));
        }
        stop.store(true, Ordering::Relaxed);
        reader.join().expect("读线程不应 panic");

        assert!(errors.is_empty(), "并发写不允许失败: {errors:?}");
        assert_eq!(
            bad_reads.load(Ordering::Relaxed),
            0,
            "读者读到的必须是完整的某一份, 不能是两份内容的拼接"
        );
        let final_bytes = std::fs::read(dir.join("history.json")).unwrap();
        assert!(
            final_bytes == short || final_bytes == long,
            "最终文件必须是完整的某一份"
        );
        let leftovers = leftover_tmp_files(&dir);
        assert!(leftovers.is_empty(), "残留: {leftovers:?}");
    }

    // ---------- P-18 后半: 数据目录一次性迁移(四种组合 + 幂等 + 跨设备分支) ----------

    /// 造一份"旧目录里该有的东西"(含子目录/多层/敏感文件)
    fn seed_tree(root: &Path) {
        std::fs::create_dir_all(root.join("ttml")).unwrap();
        std::fs::create_dir_all(root.join("cache").join("daily-playlists")).unwrap();
        std::fs::write(root.join("identity.json"), b"{\"device_id\":\"old\"}").unwrap();
        std::fs::write(root.join("settings.json"), b"{}").unwrap();
        std::fs::write(root.join("ttml").join("1.ttml"), b"<tt/>").unwrap();
        std::fs::write(
            root.join("cache")
                .join("daily-playlists")
                .join("2026-11-17.json"),
            b"{}",
        )
        .unwrap();
    }

    #[test]
    fn only_legacy_is_migrated_and_marker_left() {
        let root = temp_dir("mig-only-legacy");
        let legacy = root.join("ncm");
        let current = root.join(DATA_DIR_APP_ID);
        seed_tree(&legacy);

        let (used, outcome) = resolve_desktop_data_dir(&current, &legacy);
        assert_eq!(outcome, DataDirMigration::Migrated { copied: false });
        assert_eq!(used, current);
        // 数据都在新目录, 内容一致
        assert_eq!(
            std::fs::read(current.join("identity.json")).unwrap(),
            b"{\"device_id\":\"old\"}"
        );
        assert!(current.join("ttml").join("1.ttml").exists());
        assert!(current
            .join("cache")
            .join("daily-playlists")
            .join("2026-11-17.json")
            .exists());
        // 旧目录: 只剩标记(不静默删除, 也不留半份数据)
        let names: Vec<String> = std::fs::read_dir(&legacy)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec![MIGRATED_MARKER.to_string()], "旧目录应只剩标记");
        let marker = std::fs::read_to_string(legacy.join(MIGRATED_MARKER)).unwrap();
        assert!(
            marker.contains(&current.display().to_string()),
            "标记要指出新路径"
        );
    }

    #[test]
    fn only_current_is_untouched() {
        let root = temp_dir("mig-only-current");
        let legacy = root.join("ncm");
        let current = root.join(DATA_DIR_APP_ID);
        std::fs::create_dir_all(&current).unwrap();
        std::fs::write(current.join("settings.json"), b"{\"new\":1}").unwrap();

        let (used, outcome) = resolve_desktop_data_dir(&current, &legacy);
        assert_eq!(outcome, DataDirMigration::KeptCurrent);
        assert_eq!(used, current);
        assert!(!legacy.exists(), "没有旧目录就不该凭空造一个");
        assert_eq!(
            std::fs::read(current.join("settings.json")).unwrap(),
            b"{\"new\":1}"
        );
    }

    #[test]
    fn both_present_keeps_current_and_leaves_legacy_alone() {
        let root = temp_dir("mig-both");
        let legacy = root.join("ncm");
        let current = root.join(DATA_DIR_APP_ID);
        seed_tree(&legacy);
        std::fs::create_dir_all(&current).unwrap();
        std::fs::write(current.join("settings.json"), b"{\"new\":1}").unwrap();

        let (used, outcome) = resolve_desktop_data_dir(&current, &legacy);
        assert_eq!(outcome, DataDirMigration::KeptCurrent);
        assert_eq!(used, current);
        // 新目录不被旧数据覆盖
        assert_eq!(
            std::fs::read(current.join("settings.json")).unwrap(),
            b"{\"new\":1}"
        );
        assert!(
            !current.join("identity.json").exists(),
            "不该把旧数据搬过来"
        );
        // 旧目录一动不动(不标记、不删)
        assert!(legacy.join("identity.json").exists());
        assert!(!legacy.join(MIGRATED_MARKER).exists());
    }

    #[test]
    fn neither_present_reports_no_data() {
        let root = temp_dir("mig-none");
        let legacy = root.join("ncm");
        let current = root.join(DATA_DIR_APP_ID);

        let (used, outcome) = resolve_desktop_data_dir(&current, &legacy);
        assert_eq!(outcome, DataDirMigration::NoData);
        assert_eq!(used, current);
        assert!(!current.exists() && !legacy.exists(), "首次启动不预建目录");
    }

    #[test]
    fn second_run_is_idempotent() {
        let root = temp_dir("mig-idempotent");
        let legacy = root.join("ncm");
        let current = root.join(DATA_DIR_APP_ID);
        seed_tree(&legacy);
        let (_, first) = resolve_desktop_data_dir(&current, &legacy);
        assert_eq!(first, DataDirMigration::Migrated { copied: false });

        // 新目录里用户已经产生了新数据; 再启动一次不许动它, 也不许把旧标记当"待迁移"
        std::fs::write(current.join("settings.json"), b"{\"after\":1}").unwrap();
        let (used, second) = resolve_desktop_data_dir(&current, &legacy);
        assert_eq!(second, DataDirMigration::KeptCurrent);
        assert_eq!(used, current);
        assert_eq!(
            std::fs::read(current.join("settings.json")).unwrap(),
            b"{\"after\":1}"
        );
        // 标记没有被重写/重复搬
        let marker = std::fs::read_to_string(legacy.join(MIGRATED_MARKER)).unwrap();
        assert!(marker.contains("unix_ts="));
    }

    #[cfg(unix)]
    #[test]
    fn copy_path_preserves_private_mode_and_cleans_tmp() {
        use std::os::unix::fs::PermissionsExt;
        let root = temp_dir("mig-copy");
        let legacy = root.join("ncm");
        let current = root.join(DATA_DIR_APP_ID);
        seed_tree(&legacy);
        std::fs::set_permissions(
            legacy.join("identity.json"),
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();

        // 跨设备分支的实现直接调, 不必真有两块盘
        copy_migrate(&legacy, &current).unwrap();

        assert!(current.join("identity.json").exists());
        let mode = std::fs::metadata(current.join("identity.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "0600 的敏感文件迁移后必须仍是 0600");
        assert_eq!(
            tree_manifest(&legacy).unwrap(),
            tree_manifest(&current).unwrap()
        );
        // 临时目录不留残骸
        let leftovers: Vec<String> = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains(".migrating-"))
            .collect();
        assert!(leftovers.is_empty(), "残留: {leftovers:?}");
    }

    #[test]
    fn copy_path_failure_keeps_legacy_and_drops_tmp() {
        let root = temp_dir("mig-copy-fail");
        let legacy = root.join("ncm");
        seed_tree(&legacy);
        // 目标父路径是个文件 ⇒ create_dir_all/rename 必失败
        let blocker = root.join("blocker");
        std::fs::write(&blocker, b"x").unwrap();
        let current = blocker.join(DATA_DIR_APP_ID);

        let (used, outcome) = resolve_desktop_data_dir(&current, &legacy);
        assert_eq!(outcome, DataDirMigration::Failed);
        // 回退到旧目录(等于 P-18 之前的路径), 旧数据完好
        assert_eq!(used, legacy);
        assert_eq!(
            std::fs::read(legacy.join("identity.json")).unwrap(),
            b"{\"device_id\":\"old\"}"
        );
    }

    #[test]
    fn verify_tree_catches_missing_file() {
        let root = temp_dir("mig-verify");
        let a = root.join("a");
        let b = root.join("b");
        seed_tree(&a);
        seed_tree(&b);
        std::fs::remove_file(b.join("ttml").join("1.ttml")).unwrap();
        let err = verify_tree(&a, &b).unwrap_err();
        assert!(err.to_string().contains("迁移校验失败"), "{err}");
    }
}
