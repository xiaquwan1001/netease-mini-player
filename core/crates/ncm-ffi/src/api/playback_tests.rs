//! 桌面播放的判据用例(目前只有 R10: 「缓存命中」与「真正打开文件」之间的 TOCTOU)。

use super::*;
use ncm_service::cache::AudioCache;

/// R10: 「命中判定(只 stat) → 真正 open」之间文件被 `cache_enforce_limit` 删掉时,
/// `play_cached` 必须回 `false` —— 上层据此回落「重新下载并播」, 而不是静默无声。
///
/// 打不开的分支在 `File::open` 就返回, 不碰音频线程, 所以 CI 没有输出设备也成立。
#[test]
fn cached_hit_deleted_before_open_falls_back_to_download() {
    let dir = std::env::temp_dir().join(format!("ncm-ffi-r10-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let cache = AudioCache::open(&dir).expect("建缓存目录");
    let url = "https://m801.music.126.net/x/y.mp3";
    let path = cache.path_for_level(42, url, None);
    // 够大才能过 `cached_with_level` 的门槛(小于 64KiB 视为被劫持的 HTML)
    std::fs::write(&path, vec![0u8; 128 * 1024]).expect("写缓存文件");
    assert!(
        cache.cached_with_level(42, url, None).is_some(),
        "前提: 命中判定先通过"
    );
    // 模拟 `cache_enforce_limit` 在这两步之间动手(UI 每次换曲都 `unawaited` 调一次)
    std::fs::remove_file(&path).expect("淘汰删掉它");

    let started = tokio::runtime::Runtime::new()
        .expect("建 runtime")
        .block_on(play_cached(42, &path));
    assert!(
        !started,
        "打不开的缓存文件必须回 false(= 回落「重新下载并播」), 不能静默无声"
    );
    // 回落只有一次: 判定不再命中, 下载路径拿到的是一份干净的起点(不会二次命中坏文件)
    assert!(cache.cached_with_level(42, url, None).is_none());

    let _ = std::fs::remove_dir_all(&dir);
}
