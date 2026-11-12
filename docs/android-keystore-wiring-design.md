# Android Keystore 凭据接线设计（lane p1，2026-11-12）

> 前置阅读: docs/credential-storage-options.md §3、core/crates/ncm-service/src/credential_store.rs、
> ui/lib/src/keystore.dart + ui/android/**/KeystoreChannel.kt。
> 用户已拍板: 钥匙串可用就用; 不可用**经用户明确同意**才退 0600 明文; 凭据不落明文、不回传 Dart。

## 1. 接口形状决策（三候选对比与结论）

### 候选 A: Rust 同步 store 直接回调 Dart（FRB DartFn）
- FRB 的 DartFn 是 **async** 且经 DartHandlerPort 派发: Rust 侧要拿到 `&str` 就必须 block_on 一个
  Dart Future。启动链路是 Dart `await rust.init()` → Rust `Core::open` → `open_backend`/迁移 →
  store 同步 `put/get` —— 此时 Dart isolate 正阻塞在 await 上, 只能跑 microtask; DartFn 回调要进
  event loop, `block_on` 在同 isolate 语义下会自锁; 换线程 block_on 又要把 Future 跨 port 递回
  正忙着的 isolate, 登录链路（login_qr_check 内部 apply_login_cookie → store.put）同样如此。
- 结论: **否决**。要么改 trait 为 async（identity.rs 12+ 处同步调用全动, 违反判据①）, 要么死锁
  （违反判据②）。

### 候选 B: 写穿 + 写后缓冲（Rust 内存态权威, Dart 拉取落 Keystore）
- Rust 侧新增 `ChannelStore`（credential_channel.rs, 不带 cfg, 各平台可编译可单测）:
  实现 `CredentialStore` trait（签名不变, 判据①）; `put/get/remove` 读写**内存 BTreeMap（权威）**,
  同时把操作追加进 pending 队列（同 key 合并, 后写覆盖）。FFI 暴露
  `credential_restore(entries)`（启动时 Dart 把 Keystore 里现存条目灌进来, 幂等合并）与
  `credential_pending_writes()`（Dart 拉走并经 `ncm/keystore` 通道写 Keystore）。
- 时序: Dart 启动 → `KeystoreChannel.available/list/get` → `rust.credentialRestore(...)` →
  `rust.init(dataDir)`（Core::open 里 `open_backend` 的 android 分支发现 ChannelStore 已激活 →
  直接用, 上报 backend=android-keystore）→ 之后每次登录/登出/切换账号产生 pending →
  Dart 在关键点（init 后、登录成功后）`credentialPendingWrites()` 拉取并落 Keystore。
- 崩溃窗口: 内存权威已写入、pending 未落 Keystore 之间崩溃 ⇒ 该凭据丢了 ⇒ 重登一次, 其他状态
  （identity 骨架/设备指纹/播放数据）不丢 —— 满足判据③。restore 幂等（判据④里 mock 测）。
- 结论: **选定 B**。

### 候选 C: Rust 经 JNI 直调 Kotlin 静态方法
- 可行性: FRB 的 Rust 跑在 std 线程上, 需要 Kotlin 启动时把 JavaVM* + KeystoreBridge 全局引用
  注册进 Rust（jni crate）, 每次 IO 前 AttachCurrentThread + 用 app classloader 找类。工程上能做,
  但: ①引入 jni 依赖 + 大量 unsafe; ②classloader 坑（插件类与 app 类加载器不同）在厂商 ROM 上
  长尾; ③CI 无设备, JNI 路径完全测不到, 只能模拟器手测。
- 结论: 保留为后备, 本轮不做。若日后需要 Rust 侧同步读 Keystore（如多进程）再评估。

### 判据核对（选定 B）
| 判据 | B 的表现 |
|---|---|
| ①trait 同步签名不变 | ChannelStore 实现同一 trait, identity.rs 零改动 |
| ②不自锁/死锁 | Rust↔Dart 无反向调用, 全是 Dart 主动拉取 |
| ③崩溃最多丢凭据=重登 | pending 落盘前的窗口只影响凭据本身 |
| ④CI 无设备可测 | ChannelStore 纯内存 + mock 回调单测; Dart 侧 Fake channel 单测 |

## 2. 调用时序（文字版）

启动:
```
main() → RustLib.init()
_bootstrap():
  Android 且 Keystore.available():
    keys = keystore.list(); entries = keys.map(k => (k, keystore.get(k)))
    rust.credentialRestore(entries)            # 幂等: 重复调用合并
  rust.init(dataDir)                            # Core::open → open_backend:
                                                #   android 分支: channel_backend() 已激活?
                                                #     是 → Secure{backend: "android-keystore"}
                                                #     否 → 走既有同意门(FileStore/None)
  drainPending()                                # 拉 pending 写 Keystore(首次通常空)
```
登录/登出/切换/忘记账号（login_sheet、账号页）:
```
rust 层 store.put/remove → ChannelStore 内存权威生效 + pending 追加
Dart 关键点调用 drainPending(): rust.credentialPendingWrites()
  → 对每条 op: keystore.put(key, value) / keystore.remove(key)
  → 失败(op 返回 false): 丢弃并记日志(下次启动凭据丢失 ⇒ 重登, 可接受)
```

## 3. 失败回退表

| 场景 | 行为 |
|---|---|
| Keystore.available() == false（厂商 ROM 异常/通道缺） | 不 restore, open_backend 走既有同意门: 未同意 → PlaintextFallback(旧明文兼容), 同意 → FileStore 0600 |
| Keystore 中途写失败（put 返回 false） | pending 丢弃, 内存权威仍生效（本会话正常用）; 下次启动该凭据没有 ⇒ 未登录 ⇒ 重登 |
| Keystore 密文解不开（清数据/备份恢复） | Kotlin 侧删文件回 null ⇒ restore 得到空 ⇒ 未登录, 与密钥丢失语义一致 |
| drain 前进程被杀 | 同上, 只丢凭据 |
| App 卸载重装 | Keystore 密钥销毁, 密文文件随 dataDir 清除 ⇒ 未登录（可接受, 已在调研 §4 记录） |

## 4. 不做的事 / 边界

- 不新增任何明文落盘路径; ChannelStore 不碰磁盘。
- Keystore 密文文件（iv+密文）仍由 Kotlin 侧落 `filesDir/cred/<key>.bin`, 本轮只补 `list` 方法。
- Linux(P2 secret-service) 不在本 lane。
- pending 只在 Dart 侧消费, Rust 不重试推送; 同 key 合并保证 drain 语义为「最终态」。
