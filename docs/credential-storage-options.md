# 凭据存储方案调研(可决策稿)

> lane/w4-cred-audit @ v0.5.2, 2026-11-11。只含事实(带代码指针)与方案对比, 不拍板。

## 1. 现状审计(全部来自代码, 无猜测)

### 1.1 落盘文件与权限

| 文件 | 内容 | 写入方 | 读取方 | 权限 |
|---|---|---|---|---|
| `<dataDir>/identity.json` | `Session{cookie, device_id, profile}`; cookie 含设备指纹(deviceId/_ntes_nuid/_ntes_nnid/WNMCID/NMTID/os/appver/...) **和**登录凭据 | `IdentityStore::save` (identity.rs:209) | `load_or_create` (identity.rs:158) | 0600 (unix, identity.rs:215 `write_private`: tmp+chmod+rename) |
| `<dataDir>/accounts.json` | `AccountBook{active, accounts[]}`, 每条 `StoredAccount.cookie` 只含登录键 | `save_accounts` (identity.rs:202) | `load_accounts` (identity.rs:193) | 同上 |
| `<dataDir>/settings.json` | UI 偏好(非凭据) | Dart `AppSettings` (ui/lib/src/app_settings.dart:191) | — | 默认 |

登录凭据键 `LOGIN_KEYS` (identity.rs:230): `MUSIC_U / MUSIC_A / __csrf / JSESSIONID-WYYY / _iuqxldmzr_ / __remember_me`。
凭据来源与落盘点: `login_qr_check` (api.rs:578, 803 的 Set-Cookie → `apply_login_cookie`)、`login_sms_verify` (api.rs:614)、`login_with_cookie` (api.rs:946, Dart 直接传 cookie 串进来)。建立链: `Core::open` (lib.rs:36) → `IdentityStore::open` (lib.rs:37)。

### 1.2 进程内生命周期 / FFI 边界

- 会话 cookie **常驻 Rust 侧** `Core.session`(Mutex 单例, api.rs:24 `CORE`), provider 请求时在 Rust 内拼 header; Dart 平时拿不到 cookie。
- **但有三个过 FFI 的口子**: ① `QrLoginCheck.cookie` (api.rs:526) 与 `PhoneLoginResult.cookie` (api.rs:544) 会以 String 回传 Dart(login_sheet.dart:304 直接在 Dart 里检查 `MUSIC_U`); ② `loginWithCookie(cookie)` (api.rs:946) 由 Dart 传入; ③ `device_id` 经 `InitInfo` (api.rs:75) 回 Dart。⇒ 换密钥串方案时这三个接口形状需同步考虑(至少文档标注"凭据勿在 UI 层留存")。

### 1.3 `<dataDir>` 解析(三端)

| 平台 | 值 | 出处 |
|---|---|---|
| Android | `File(filesDir, "ncm")` = `/data/data/com.minincm.minincm/files/ncm` | MainActivity.kt:255, 经 `ncm/player` 通道 `dataDir()` (playback.dart:116) 回 Dart, 再传给 `rust.init` (main.dart:728) |
| Linux | `$NCM_DATA_DIR` 或 `$HOME/.local/share/ncm` | api.rs:57 `data_dir_default` |
| Windows | 同 api.rs:57; Flutter 侧 `dataDir()` 仅 Android 返回值, Windows 上 `HOME` 通常未设 → 兜底 `"./.local/share/ncm"`(**未验证实际运行值, 需在 Windows 上跑一次确认**) | api.rs:57 |

## 2. 候选方案对比

依赖体积口径: 本地 `cargo tree -p ncm_ffi` 当前 normal 依赖 492 行 / --target all 715 行(cargo 1.99, --offline 实测)。**未实测新增依赖树**(禁止联网加依赖), crate 版本/树规模标注为"以 crates.io 为准", 验证方法: 在 scratch 分支 `cargo add` 后 `cargo tree -d` 对比行数与编译产物 `du -sh target/`。

| 方案 | 依赖与体积 | 跨平台 | 回退 | 实现/测试成本 | 权限影响 |
|---|---|---|---|---|---|
| **a) secret-service (Linux)** — 推荐 `keyring` 3.x(内建 linux 后端) 或直用 `zbus` 5.x 裸 D-Bus | `keyring`+linux 后端约 +15~25 crates(zbus 系: zbus/zvariant/nix...); 预估二进制增量 <1MB。zbus 直用树更小但 D-Bus API 面自己扛 | 仅 Linux; Android/Windows 需各自后端(组合 b/c) | 无 D-Bus/无 keyring → 报错或退 0600 明文(见 §5 决策点) | 中: 一个 trait + Linux impl + 启动迁移; 测试要 headless D-Bus | 无新 Android 权限; Linux 无系统权限诉求 |
| **b) Windows DPAPI** — `windows-sys` 0.52 已在依赖树(core/Cargo.lock), 加 `Win32_Security_Cryptography` feature 即可, **近零增量** | 仅 Windows cfg(`#[cfg(windows)]`); 不影响 APK | 文件坏/换 Windows 账户 → 解密失败当未登录(可重登) | 低: ~50 行 unsafe; windows.yml 可编可测 | 无 |
| **c) Android Keystore** (Kotlin MethodChannel, 同 `ncm/player` 套路 MainActivity.kt:38) | Rust/Dart 零新依赖; Kotlin 自写 AES/GCM + Keystore, ~150 行 Kotlin | 仅 Android | Keystore 异常(厂商 ROM 偶发) → 报错让用户重登 | 中: Kotlin impl + 通道 + Dart 接线 + 模拟器手测 | 无新权限; 注意 keystore 密钥不随备份迁移 |
| **d) 加密文件(折中)** — AES-GCM, 密钥=派生(device_id+固定盐)落盘同目录 | 只需 `aes-gcm`/`ring`(~+5 crates; aes 已在 vendor 树) | 全平台一致 | 文件坏 → 当未登录 | 低 | 无 |

**d 为什么不推荐当最终方案**: 密钥与密文同机同用户可读(device_id 就写在 identity.json 里), 攻击者读到密文即能解密; 它只防"误上传/打包外泄"这类粗心泄露, 不防本地提权。**只作为钥匙串不可用时的降级路径, 不推荐当最终方案。**

APK 体积注记: a/b/d 走 Rust 侧不影响 APK Kotlin/Dart 体积; c 走 Kotlin 也不引入依赖。四个方案对 ~28MB 现状的增量都在 <1MB 级, 500KB 目标(若恢复执行)只有 d/a 需要复核实测。

## 3. 推荐方案与分阶段落地

**推荐: 抽象 Rust 侧 `CredentialStore` trait, 按端选后端 — Windows 先 DPAPI(b, 近零依赖), Android 用 Keystore 经通道(c), Linux 后置 secret-service(a)。**

trait 草案(只签名, 放 ncm-service):

```rust
pub trait CredentialStore: Send + Sync {
    fn put(&self, key: CredentialKey, secret: &str) -> Result<(), CredentialError>;
    fn get(&self, key: CredentialKey) -> Result<Option<String>, CredentialError>;
    fn remove(&self, key: CredentialKey) -> Result<(), CredentialError>;
    /// 钥匙串不可用时的策略由启动逻辑决定, store 只报告不可用
    fn available(&self) -> Result<(), CredentialError>;
}
pub enum CredentialKey { Session, Account(u64) }
pub enum CredentialError { Unavailable(String), AccessDenied(String), Backend(String) }
```

**落地状态(2026-11-12 更新)**:
- trait + `FileStore`(0600 + 同意门) + `CredentialPolicy`(`credential_policy.json`) + `CredentialStatus` 已落地于
  `core/crates/ncm-service/src/credential_store.rs`, `IdentityStore` 已接入(会话/账号凭据入 store,
  identity.json/accounts.json 写回**骨架**: 只留 deviceId/uid/nickname, 不再含 MUSIC_U);旧明文迁移
  `migrate_legacy_cleartext` 一次性幂等、失败保留明文不阻塞启动。
- 决策点 4 已执行: **凭据不再过 FFI 回 Dart**。`QrLoginCheck`/`PhoneLoginResult` 去掉 `cookie`, 换 `logged_in`;
  凭据改走内部类型 `QrLoginOutcome`/`PhoneLoginOutcome`(在 ncm-provider → ncm-service → ncm-ffi 之间流动,
  由 FFI 落盘后丢弃)。设置页可用 `credential_status()` / `consent_plaintext_storage(bool)`。
- 决策点 3 已执行: 迁移后旧明文文件"清零置空保留骨架"(可回读设备指纹与账号元数据)。

分阶段(最小改动优先):
1. **P0 Windows DPAPI**(已落地): `#[cfg(windows)] DpapiStore`, `open_backend` 在 Windows 上 DPAPI 可用即用;
   Linux/Android 走同意门。
2. **P1 Android Keystore**: Kotlin `ncm/keystore` 通道(存/取/删 blob), 通道里只传 secret 本身, 不新增持久化副本; 迁移见下。模拟器 a34 手测。
3. **P2 Linux secret-service**: `keyring` crate; 无 D-Bus 时按 §5 决策回退。

迁移兼容(各端一致): 启动时在 `IdentityStore::load_or_create` 前探测旧明文文件 → 读入 → 写 CredentialStore → **旧文件字段清零(identity.json 写回只剩设备指纹; accounts.json 删 cookie 只留 uid/nickname 元数据)** → 一次性迁移标记进 settings。写 keychain 失败则保留明文原样 + UI 提示, 不阻塞启动。

失败回退: 钥匙串不可用**不建议静默退回明文**(隐私目标落空); 建议默认报错并在设置页给三选: 重试 / 本次会话内存态不落盘(退出即丢) / 用户明确同意后退回 0600 明文。第三项 = 决策点。

## 4. 风险与 CI 判据

| 方案 | CI 可自动验证 | 只能手工 | 不可行/风险场景 |
|---|---|---|---|
| a secret-service | `cargo test` 需 D-Bus; CI 可尝试 `dbus-run-session`+gnome-keyring(未验证, 需 spike) | 真实桌面会话的 keyring 解锁弹窗 | **无 D-Bus 容器、无桌面会话的 Linux** → `available()` 失败, 必须有回退; Flatpak portal 权限未验证 |
| b DPAPI | windows.yml 编译 + roundtrip/非明文断言, 完全自动 | 跨 Windows 账户迁移场景 | 重装系统旧密文不可解 → 当未登录 |
| c Keystore | CI 只能测 Dart 侧逻辑 | 模拟器 a34 手测存取/清数据后重登; 厂商 ROM 需真机 | 卸载重装密钥销毁 → 凭据丢失(可重登, 可接受) |
| d 加密文件 | 纯 Rust 单测, 全自动 | — | 无技术风险, 只有"安全自欺"风险 |

## 5. 需要用户决策的点

1. Linux 无钥匙串(无 D-Bus/无桌面会话)时, 是否允许**经用户明确确认后退回 0600 明文**, 还是坚持不落盘(每次重登)?
2. 是否接受 Linux 端新增 `keyring`/zbus 系依赖(预估 +15~25 crates, <1MB; 桌面产物无 APK 压力, 但需确认)?
3. 迁移后旧明文文件: "清零置空保留骨架"还是"直接删除"?
4. `QrLoginCheck.cookie`/`PhoneLoginResult.cookie` 仍过 FFI 回 Dart(login_sheet.dart:304 依赖它判 MUSIC_U), 是否接受"凭据短暂出现在 Dart 内存"并保留接口, 还是重构为 Dart 只收 bool?
5. 分阶段顺序(P0 Windows → P1 Android → P2 Linux)是否认可, 还是隐私优先先做 Android?
