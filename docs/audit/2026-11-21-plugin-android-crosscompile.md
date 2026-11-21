# 2026-11-21 插件宿主 Android 可用性评估（rquickjs 交叉编译实测）

> 问题：`core/crates/ncm-plugin`（rquickjs 0.12.2 音源插件宿主）能不能在 Android 上跑？
> `ncm-plugin/README.md` §4 第 8 项当时写的是「Android(NDK)/桌面交叉编译 rquickjs-sys 未验证」。
> 本文把它变成实测结论（**编译 + 真机运行都做过**），并给出候选方案的成本/风险与取舍。
>
> 方法：只读 + 临时目录复现（`/tmp/plugtest`、`/tmp/plugtest2`、`/tmp/plugsmoke`）。
> **仓库源码零改动**，唯一写入是本文件。不 commit / 不 push。docs/README.md 索引由父车道补。

## 0. 快照

| 项 | 值 |
|---|---|
| HEAD | `aa78cbc` feat(plugin): 清单 apiVersion 版本协商 + 连续装载失败 3 次自动禁用 (P3) |
| 机器时间 | 2026-11-20 22:20 (+08:00)，工作区干净（`git status --porcelain` 空） |
| rustc / cargo | 1.99.1 |
| NDK | r28c = 28.2.13676358（`~/android-dev/sdk/ndk/28.2.13676358`） |
| libclang | Ubuntu clang 21.1.8，`/usr/lib/llvm-21/lib/libclang.so` |
| 真机 | 华为 ELS-AN00，arm64-v8a，`ro.build.version.sdk=31`（adb 上唯一在线设备） |
| 插件宿主规模 | `core/crates/ncm-plugin/src/*.rs` 2,845 行，唯一 C 依赖 = rquickjs-sys 内的 quickjs |

## 1. 现状实测

### 1.1 失败面：默认特性下 Android 目标**开箱即失败**，缺的是预生成 bindings（不是 C 编译）

复现命令（临时目录，仓库不动）：

```bash
source tools/env.sh
export NDK="$ANDROID_HOME/ndk/28.2.13676358"; export TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
export CC_aarch64_linux_android="$TC/bin/aarch64-linux-android24-clang"
export AR_aarch64_linux_android="$TC/bin/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TC/bin/aarch64-linux-android24-clang"
cargo build --offline --manifest-path core/Cargo.toml -p ncm-plugin --target aarch64-linux-android
```

真实报错原文（`rquickjs-sys` 的 build script 本身没失败，失败在 lib 的 `include!`）：

```
error: couldn't find file `.../rquickjs-sys-0.12.2/src/bindings/aarch64-linux-android.rs`
  --> .../rquickjs-sys-0.12.2/src/lib.rs:19:1
19 | include!(concat!("bindings", bindings_env!("TARGET"), ".rs"));
warning: rquickjs-sys@0.12.2: rquickjs probably doesn't ship bindings for platform
         `aarch64-linux-android(n/a)`. try the `bindgen` feature instead.
error: could not compile `rquickjs-sys` (lib) due to 1 previous error
```

判据（本机实测，`ls rquickjs-sys-0.12.2/src/bindings/`）：0.12.2 只带 **16 个** target 的 bindings
（apple-darwin ×2、windows ×3、linux-gnu/musl ×4、armv7-gnueabihf、i686-linux、loongarch64 ×2、
powerpc64、wasm32-wasi ×2），**没有任何 `*-linux-android`**。即 §4 第 8 项的真实含义是
「不是没验证，而是默认路径必然失败」，并且**失败点不是 QuickJS C 源码编不过**。

顺带确认当前产品的 Android 面（不必再推翻，只是证据定位）：`core/crates/ncm-service/src/lib.rs:21-33`
按 `cfg(not(target_os = "android"))` 整层 cut 掉 plugins；`core/crates/ncm-ffi/src/api/plugin.rs`
非 Android 也照样导出函数（Android 返回空视图/unsupported），形状两端一致。

### 1.2 反向实测：打开 `bindgen` 特性后，**交叉编译与真机运行都通**

三组实验，全部在 /tmp：

1. **C 侧**：用 NDK clang 直接编 quickjs 四个 .c（`quickjs.c/libregexp.c/libunicode.c/dtoa.c`，
   `-D_GNU_SOURCE`）→ 4 个 `.o` 全部产出，**QuickJS C 源码本身对 aarch64-linux-android 无兼容问题**。
2. **Rust 侧**：临时 crate `rquickjs = {default-features=false, features=["std","bindgen"]}`，
   `--target aarch64-linux-android` + `cdylib`：**rquickjs 0.12.2 与 0.14.0 都链接成功**
   （0.12.2 干净构建 14.7s / 0.14.0 20.5s，产物 `libplugtest.so` 477KB，
   `file` 报 `ELF 64-bit LSB shared object, ARM aarch64 ... for Android 24, built by NDK r28c`）。
   同样命令换 `x86_64-linux-android`（模拟器 ABI）也过。
3. **本仓 crate 本体**：把 `core/crates/{ncm-plugin,ncm-domain,ncm-provider}` 复制到 /tmp，
   **仅**在副本里把 `ncm-plugin/Cargo.toml` 的 rquickjs 特性从 `["std"]` 改成 `["std","bindgen"]`：
   `cargo build --release --offline -p ncm-plugin --target aarch64-linux-android` → **17.7s 成功，RC=0**。
   即「宿主这 2,845 行 Rust」本身没有 Android 不兼容点，卡住的只有 sys 层 bindings。

**真机运行**（不是只有编译过）：`/tmp/plugsmoke` 一个 1.8MB 的 rquickjs 0.14 bin，
`adb push /data/local/tmp/plugsmoke` 后直接执行（跑完即删）：

```
eval_ok=42
json_ok={"a":1,"b":[1,2]}
promise_pump_ok=0            # execute_pending_job 泵队列可用(ScriptProvider 的 await 依赖它)
interrupt_ok=true            # set_interrupt_handler 8s 硬超时机制可用(抛 Exception, 不 abort)
memlimit_ok=true             # set_memory_limit(32MB) 内存炸弹抛 Exception, 不 abort
SMOKE_PASS
```

—— 也就是说本宿主赖以成立的三件事在 arm64 Android 上都成立：
**自带分配器下的内存上限、interrupt 超时中断、手动泵 promise job queue**。

### 1.3 反事实：缺了 env 就失败，但一条环境变量就够

不设 sysroot 时 bindgen 会拿宿主 glibc 头（`rquickjs-sys` build.rs 的 `detect_include_paths`）：

```
/usr/include/stdio.h:28:10: fatal error: 'bits/libc-header-start.h' file not found
thread 'main' panicked at rquickjs-sys-0.12.2/build.rs:362:39: Unable to generate bindings
```

补上 NDK sysroot 后即通过；这是**每个构建入口都要带的一条 env**（不是改代码）：

```bash
export LIBCLANG_PATH=/usr/lib/llvm-21/lib
export 'BINDGEN_EXTRA_CLANG_ARGS_aarch64-linux-android=--target=aarch64-linux-android24 \
  --sysroot=$TC/sysroot -I$TC/sysroot/usr/include -I$TC/sysroot/usr/include/aarch64-linux-android'
# x86_64-linux-android 同理换一个变量名(变量名带连字符 ⇒ 必须用 env 'NAME=...' 形式导出, bash export 不接受)
```

成本量化（本机实测）：干净构建每次多 **15~20s**（bindgen 拉起 15 个 build-dep：bindgen/clang-sys/nom/
cexpr/regex/syn…）；体积 **libquickjs.a 1.94MB（未 strip）→ 剥离后 .so 增量约 +311KB/ABI**。

## 2. 方案对比

| 方案 | 实测/证据 | 成本 | 风险 |
|---|---|---|---|
| **a) 等上游新版给 Android bindings** | crates.io `rquickjs` 最新 **0.14.0**（2026-09-18）；docs.rs 0.14.0 `src/bindings/` 仍是 **20 个 target，无 `*-linux-android`**（<https://docs.rs/crate/rquickjs-sys/0.14.0/source/src/bindings/>）。相关 PR 「Support for aarch64-linux-android」#419 至今 **Review required 未合**，维护者明确要求「同时补 bindings 生成 + CI 覆盖才合」（<https://github.com/DelSkayn/rquickjs/pull/419>）；早期 #291 已关闭。上游官方给的解法就是 `bindgen` 特性（#600 的收敛回复、#711「Fix rquickjs-sys host build failing when cross-compiling to Android」2026-07-24 已合，本机 0.12.2 里已含该修复） | 0（等） | **不可当计划**：上游 3 年没落地，且我们的 Android 需求不会因为等待而消失。只能当「偶尔回看」 |
| **b) 自己 bindgen + NDK（构建期生成）** | 本文 §1.2 的 3 组实验：C 编过、.so 链接过、**真机 4 项运行时能力全过**；ncm-plugin 本体 17.7s 过 | **S~M**：`ncm-plugin/Cargo.toml` 加 `"bindgen"`（或仅 Android 目标加）+ `ncm-service` 撤 `cfg` 门 + `tools/build-android.sh:20` 附近与 `.github/workflows/release.yml`(android job, NDK 28.2 已装) 各加 3 行 env + CI 装 libclang | **中**：①每个构建机要有 libclang（CI 加 apt 包，约百 MB）；②bindgen 是构建期依赖，`--offline` 场景需预热 cache；③bindings 由宿主 clang 生成 → 与 NDK 头必须对齐（必须带上面那条 env，否则 1.3 的错）；④Android 上**仍缺运行时验收**（本文只覆盖引擎语义，未覆盖 4 个 ABI 上的 APK 整包 + 真实插件脚本） |
| **b') 同上，但预生成 bindings 并 vendored** | 同 b 的实测；机制 = `--features update-bindings` 把 `aarch64/x86_64-linux-android.rs` 写进 `src/bindings/` 后锁版本（本仓已有 `core/vendor/ncm-api` 按 commit 锁上游的先例，见 `vendor/UPSTREAM.txt`） | **M**：多一个「自己维护的 rquickjs-sys 补丁副本」+ 升级时的重新生成流程 | **低~中**：构建期零 libclang、零额外 15s；代价是 vendored crate 的升级/审计成本，且离线 cache 命中要保证 |
| **c) 换纯 Rust 引擎（boa_engine 0.22.0）** | boa 是纯 Rust，理论上 Android 无 C 依赖；但**没有内存上限**：Boa 分配不可失败，OOM 直接 abort 进程（`catch_unwind` 拦不住），参考 <https://github.com/storytold/pdfcraft/issues/4001>；只有 loop/recursion 两个 limit（<https://boajs.dev/docs/debugging/debug_object#boalimits>，`$boa.limits.loop/recursion`） | **L**：`sandbox.rs`/`prelude.js` 的 promise 泵、interrupt、`set_memory_limit` 预算全部重做；体积/性能差距需重测 | **高**：①丢掉「32MB 内存炸弹被拦」这条已有红→绿实证（README §3），插件是不可信第三方 JS，这条不能降级；②boa 覆盖率/体积/速度均未在本仓评估；③等于把已绿的 21 例沙箱门全部重写 |
| **d) Android 不做插件化，走产品替代** | 现状即此（`ncm-service/src/lib.rs:21` 的 gate）；可替代能力：桌面/服务端取链代理、歌单/分享链接导入（仓内已有分享链接解析 `ui/lib/src/song_share.dart`） | **S**（保持现状）~ **M**（加一个「桌面代理取链」的协议） | **低**（风险都在"没有插件就没有第三方音源"这个产品损失上，不在工程） |

## 3. 推荐

**推荐路径：b（先构建期 bindgen）起步，等 Android 侧真的要用时再收敛到 b'（vendored 预生成 bindings）。
a 只作为「顺手回看上游」；c 不做。**

落地顺序（每步都可独立验收，前两步就能让 Android 编过）：

1. `ncm-plugin/Cargo.toml`：rquickjs 特性从 `["std"]` 改成 `["std","bindgen"]`（或写成
   `[target.'cfg(target_os="android")'.dependencies]` 只对 Android 开，桌面继续吃预生成 bindings 以省 15s）。
2. 构建入口补 env：`tools/build-android.sh`（`source tools/env.sh` 之后）+ `tools/ci.sh`/android job
   与 `.github/workflows/release.yml` 的 android job（该 job 已装 NDK 28.2.13676358，见 workflow 第 109/120 行）
   加 `LIBCLANG_PATH` + `BINDGEN_EXTRA_CLANG_ARGS_<target>`；CI 另加一步装 libclang。
3. `ncm-service/src/lib.rs:21-33` 撤 `cfg(not(target_os="android"))` 门，一次只撤 plugins 的 dep 与 module，
   FFI 形状已两端一致（`ncm-ffi/src/api/plugin.rs` 不用改）。
4. 真机验收门（本文没做的部分）：arm64 + x86_64 两个 ABI 各跑一次
   「启用宿主 → 装载 fixtures 里的 `music_url.js` → 取一次链 → 超时/内存炸弹各触发一次」，
   并把 §1.2 的四行 `SMOKE_PASS` 语义做成 instrumented 用例。

**触发条件（什么条件下才值得做）——三条全中才动**：

- 桌面插件化**已经可用**（有管理页、能导入并启用真实 LX 脚本、取链能进播放链路）；
- 出现**明确的 Android 用户诉求**（例如 issue 里 ≥3 人问「安卓为什么没有插件」），不是"顺手补齐"；
- 接受的代价：APK 每 ABI +≈300KB、构建机加 libclang、Android 侧多一道真机验收。

**只做桌面插件化还缺什么**（对比 `ncm-plugin/README.md` §4，Android 不是唯一缺口）：

| # | 缺的事 | 现状指针 |
|---|---|---|
| 1 | 插件管理页（导入/启停/卸载/失败视图） | README §4 第 2/3 项；FFI 8 个函数已导出（`ncm-ffi/src/api/plugin.rs`），无 UI 入口 |
| 2 | 路由层用插件 provider | README §4 第 7 项尾巴：`ScriptProvider::id()` 恒为 `"script"`，直接塞 `ProviderRegistry` 会静默丢第二个插件 |
| 3 | `songUrl` 上下文补齐（name/singer/albumName/interval） | README §1.2 + §4 第 6 项；`SongUrlRequest` 只带 `track+level` |
| 4 | LX 真实脚本对表（`search` 形状、`lx.send('inited')`、脚本头元信息） | README §5 待验证项 1/2/4/5 |
| 5 | 日志通道到 UI（现在是 `take_logs()` 拉取） | README §4 第 9 项 |
| 6 | 进程外隔离（二期；与 Android 无关） | README §4 第 11 项 |

> 换句话说：**Android 交叉编译曾是「未验证」里最不确定的一条，现在它是全表里最确定的一条**
> （引擎语义已在真机跑过）。剩下 5 条全是产品接线工作，成本都比它高。

## 3.5 落地记录(2026-11-21, 用户拍板做推荐路径 b)

| 步骤 | 落点 | 状态 |
|---|---|---|
| ① rquickjs 特性按目标分段 | `core/crates/ncm-plugin/Cargo.toml`: 桌面 `[target.'cfg(not(target_os = "android"))']` 用 `std`(预生成 bindings); Android 用 `std` + `bindgen` | ✅ |
| ② 构建入口注入 NDK sysroot + libclang | 新增 `tools/android-bindgen-env.sh`(env(1) 注入 `BINDGEN_EXTRA_CLANG_ARGS_<triple>` / `CC_<triple>` / `AR_<triple>`, 变量名带连字符不能用 export); `tools/build-android.sh` 自 re-exec; `tools/ci-gates.sh` 的 android-unit/android-lint 套这层; `ci.yml`(android job + Debug APK job) 与 `release.yml`(Tests gate + Android 构建) 加装 libclang 并把 NDK 28.2 装进每个会触发 cargokit 的 job | ✅ |
| ③ 撤 `cfg(not(android))` 门 | `ncm-service/Cargo.toml` 的 ncm-plugin 依赖回到 `[dependencies]`; `ncm-service/src/lib.rs` 的 `plugins` mod/use/`Core::plugin_host`/`impl Core` 全部无条件; `ncm-ffi/src/api/plugin.rs` 删掉整套「Android 空视图」分支(两端同一份实现), `api.rs` 的 `with_provider`/`routed_call` 也只剩一条路由实现 | ✅ |
| ④ 真机/模拟器验收门 | 本机只连着用户物理机(未动); 已验证: `cargo check --target aarch64-linux-android -p ncm_ffi` 过(含 rquickjs-sys bindgen + ncm-plugin/service/ffi)、`tools/ci-gates.sh verify` 全绿(`android-unit`/`android-lint` 会真的编 Android 目标的 Rust)、`bash tools/build-android.sh debug` 出两个 ABI 的 APK | ⏳ 设备侧「启用宿主→装 fixture 插件→取一次链→超时/内存炸弹各一次」仍待模拟器/真机跑 |

成本实测(本机): Android 目标首次 bindgen + 15 个 build-dep 拉取约 +15s/ABI; 桌面构建零变化(仍吃预生成 bindings, 不需要 libclang)。

## 4. 明确不做
## 4. 明确不做

- **不做 c（换 boa_engine）**：为省一条构建 env 而丢掉「32MB 内存上限」这条不可信脚本的硬门，
  并把已绿的沙箱预算体系重写一遍，收益是负的。
- **不把 a（等上游）当阻塞项**：不作为前置条件等待 #419 合入；上游合了就是白赚，没合也不影响 b。
- **不为 Android 单独 fork 加解密/ABI 差异**：vendor 库口径不变，插件契约 v1 不变（同一份脚本两端通用）。
- **不在 Android 上先做进程外隔离/子进程沙箱**：与桌面统一放二期（README §4 第 11 项），
  Android 侧进程模型差异单独评估，不混进本次。
- **不改 `docs/README.md` 索引**（父车道补），不在本文件写"已接线"之类未发生的状态。
