//! `DATA_DIR` 单例与 `init()` 的接通性回归(2026-11-23 桌面端播放全废的根因)。
//!
//! 背景: api.rs 拆分时在 playback.rs 里重复声明了一份 `static DATA_DIR`,
//! 遮蔽了 `super::*` 里 `init()` 实际写入的那份 ⇒ 所有 `DATA_DIR.get()` 永远 None,
//! play_track/缓存/歌词全部报 "core not initialized"。
//! 用例 = 走一次**真实的 `init()`**(独立临时目录, 不污染全局 CORE —— init 幂等),
//! 再断言本 crate 能看到非 None 的 DATA_DIR。
//!
//! 注意: 用例跑在共享进程里时 CORE 已被其它用例占用也没关系 —— init 对已初始化的
//! CORE 是幂等返回, 但仍会执行 `DATA_DIR.set`; 而对全新进程这条用例单独也能成立。

use super::{core, init, plugin_host};

// 注意: `init()` 写的是**进程级** `OnceLock`(CORE / PLUGIN / DATA_DIR), 一进程只能定一次,
// 所以这里的断言必须只用一个用例完成 —— 两个用例各传一个临时目录并行跑会互相抢
// (实测: 谁先跑谁赢, 另一条必红)。这也是它写在这一个文件里、不分函数的原因。

#[test]
fn init_wires_the_shared_singletons() {
    let dir = std::env::temp_dir().join(format!("ncm-ffi-datadir-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp data dir");
    let want = dir.to_string_lossy().into_owned();

    let info = init(Some(want.clone())).expect("init should succeed on a fresh temp dir");
    assert_eq!(info.data_dir, want, "init 应该原样使用传入的显式目录");

    // ① 关键回归: init 之后 api 树内读到的 DATA_DIR 必须**就是** init 写入的那份。
    //    (修复前: playback.rs 里另有一份同名 `static DATA_DIR` 遮蔽了 super::* 的,
    //     那份没人 set ⇒ 所有播放/缓存/歌词调用报 "core not initialized"。)
    let seen = super::DATA_DIR.get().expect(
        "DATA_DIR must be set after init(); \
         None here usually means a local static shadows super::*'s instance",
    );
    assert_eq!(seen.to_string_lossy(), want);

    // ② 同源性: CORE / PLUGIN 也必须同时可用(三件套只该有一处定义)
    assert!(core().is_ok(), "core() must succeed after init()");
    assert!(
        plugin_host().is_ok(),
        "plugin_host() must succeed after init()"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
