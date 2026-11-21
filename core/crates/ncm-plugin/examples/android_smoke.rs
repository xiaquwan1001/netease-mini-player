//! Android 目标的最小运行时冒烟(设备侧验收用, 不起 App、不联网).
//!
//! 为什么是 example 而不是集成测试: Android 上的插件宿主只能经 FFI/Dart 调到, 而
//! instrumented test 那层不直连 Rust; 但「引擎语义在真机成立」这件事可以像
//! docs/audit/2026-11-21-plugin-android-crosscompile.md §1.2 那样用一个独立二进制验证 ——
//! 同一份 ncm-plugin 代码、同一套沙箱预算, 只是入口是 main。
//!
//! 用法(模拟器 x86_64 或真机 arm64):
//!   tools/android-bindgen-env.sh cargo build --manifest-path core/Cargo.toml \
//!     --example android_smoke --target x86_64-linux-android --release
//!   adb push core/target/x86_64-linux-android/release/examples/android_smoke /data/local/tmp/
//!   adb shell /data/local/tmp/android_smoke
//! 期望最后一行输出 SMOKE_PASS(四项: 装载+request 适配 / 事件分发 / 超时中断 / 内存上限)。
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ncm_plugin::{
    MemoryStorage, SandboxConfig, ScriptEngine, Transport, TransportError, TransportRequest,
    TransportResponse,
};
use serde_json::json;

/// 假出站: 立刻回一条常量 JSON(不联网), 记录调用次数。
struct FakeTransport {
    calls: Mutex<usize>,
}

impl Transport for FakeTransport {
    fn send(&self, _request: &TransportRequest) -> Result<TransportResponse, TransportError> {
        *self.calls.lock().unwrap_or_else(|e| e.into_inner()) += 1;
        Ok(TransportResponse {
            status: 200,
            headers: Vec::new(),
            body: r#"{"url":"https://cdn.test/android.mp3"}"#.to_string(),
        })
    }
}

const FIXTURE: &str = r#"
lx.send(lx.EVENT_NAMES.inited, { sources: { wy: { name: '网易云', type: 'music', actions: ['musicUrl'] } } });
lx.on(lx.EVENT_NAMES.request, ({ source, action, info }) => {
  if (action !== 'musicUrl') return Promise.reject(new Error('unsupported action'));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), 5000);
    lx.request('https://example.test/url?id=' + info.musicInfo.id, {}, (err, resp) => {
      clearTimeout(timer);
      if (err) return reject(err);
      resolve(JSON.parse(resp.body).url);
    });
  });
});
"#;

fn engine(source: &str, timeout: Duration, memory: usize) -> ScriptEngine {
    ScriptEngine::new(
        source,
        SandboxConfig {
            call_timeout: timeout,
            memory_limit_bytes: memory,
            ..SandboxConfig::default()
        },
        Arc::new(FakeTransport {
            calls: Mutex::new(0),
        }),
        Arc::new(MemoryStorage::new()),
        "android-smoke",
    )
    .expect("引擎装载失败")
}

fn main() {
    // ① 装载 + request 事件适配 + 回调式 lx.request + setTimeout/clearTimeout
    let mut ok = engine(FIXTURE, Duration::from_secs(8), 32 * 1024 * 1024);
    println!("handlers={:?}", ok.handlers());
    println!("sources={:?}", ok.declared_sources());
    let out = ok
        .invoke(
            "musicUrl",
            json!(["script", { "id": 42, "name": "夜曲", "singer": "周杰伦", "interval": 227 }, "flac"]),
        )
        .expect("取链调用失败");
    println!("music_url_ok={out}");
    assert_eq!(out, json!("https://cdn.test/android.mp3"));

    // ② 超时: 死循环必须被 interrupt 打断(不是 abort 进程)
    let mut slow = engine(
        "lx.on('musicUrl', () => { while (true) {} });",
        Duration::from_millis(300),
        32 * 1024 * 1024,
    );
    let timeout_err = slow
        .invoke("musicUrl", json!(["script", {}, "flac"]))
        .unwrap_err();
    println!("interrupt_kind={:?}", timeout_err.kind);
    assert!(matches!(
        timeout_err.kind,
        ncm_plugin::PluginErrorKind::Timeout
    ));

    // ③ 内存上限: 内存炸弹必须被分配器拒绝(不是 OOM abort)
    let mut bomb = engine(
        "lx.on('musicUrl', () => { const a = []; for (;;) a.push(new Array(1 << 20).fill(7)); });",
        Duration::from_secs(5),
        8 * 1024 * 1024,
    );
    let mem_err = bomb
        .invoke("musicUrl", json!(["script", {}, "flac"]))
        .unwrap_err();
    println!("memlimit_kind={:?}", mem_err.kind);
    assert!(matches!(mem_err.kind, ncm_plugin::PluginErrorKind::Memory));

    println!("SMOKE_PASS");
}
