//! `init()` 单例发布的一致性与 `init()` 的接通性回归(2026-11-23 桌面端播放全废的根因 + R7)。
//!
//! 历史: api.rs 拆分时在 playback.rs 里重复声明了一份 `static DATA_DIR`,
//! 遮蔽了 `super::*` 里 `init()` 实际写入的那份 ⇒ 所有目录读取永远是 None,
//! play_track/缓存/歌词全部报 "core not initialized"。现在 playback.rs 不再持有任何单例,
//! 目录/Core/插件句柄统一从 `super::inited()` 取, 这条用例就是它的判据。
//!
//! R7: `init()` 以前把 DATA_DIR / CORE / PLUGIN 分三步 `set` 并吞掉失败, 回给 Dart 的又是
//! **入参**目录。现在三者同一个 `Arc` 原子发布, 且重复 init 传别的目录时回的是**实际生效**
//! 的那个 —— 断言 ③ 就是这条(修复前会拿到入参, 必红)。
//!
//! 注意: `init()` 写的是**进程级**单例, 一进程只能定一次, 所以这里的断言必须只用一个
//! 用例完成 —— 两条用例各传一个临时目录并行跑会互相抢(实测: 谁先跑谁赢, 另一条必红)。
//! 这也是它写在这一个文件里、不分函数的原因。

use super::{core, data_dir, init, plugin_host};

#[test]
fn init_wires_the_shared_singletons() {
    let dir = std::env::temp_dir().join(format!("ncm-ffi-datadir-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp data dir");
    let want = dir.to_string_lossy().into_owned();

    let info = init(Some(want.clone())).expect("init should succeed on a fresh temp dir");
    assert_eq!(info.data_dir, want, "首次 init 用的就是传入的显式目录");

    // ① 关键回归: init 之后 api 树内读到的目录必须**就是** init 发布的那份。
    //    (修复前: playback.rs 里另有一份同名 `static DATA_DIR` 遮蔽了 super::* 的,
    //     那份没人 set ⇒ 所有播放/缓存/歌词调用报 "core not initialized"。)
    let seen = data_dir().expect("data_dir() must succeed after init()");
    assert_eq!(seen, std::path::Path::new(&want));

    // ② 同源性: 目录 / Core / 插件句柄是同一个 `Arc` 一起发布的(三件套只该有一处发布点)
    assert!(core().is_ok(), "core() must succeed after init()");
    assert!(
        plugin_host().is_ok(),
        "plugin_host() must succeed after init()"
    );

    // ③ R7: 第二次 init 传别的目录 ⇒ 回**实际生效**的那个(修复前回的是入参,
    //    于是 Dart 拿 dir2 写 settings.json, Rust 仍在 dir1 里写缓存/历史)。
    let other = dir.join("another");
    let again = init(Some(other.to_string_lossy().into_owned())).expect("重复 init 仍应成功");
    assert_eq!(
        again.data_dir, want,
        "重复 init 必须回实际生效的目录, 而不是入参"
    );
    assert_eq!(
        data_dir()
            .expect("data_dir() must stay available")
            .to_path_buf(),
        std::path::PathBuf::from(&want)
    );

    let _ = std::fs::remove_dir_all(&dir);
}
