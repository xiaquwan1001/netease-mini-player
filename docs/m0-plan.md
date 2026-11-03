# M0 落地清单(基建周)

> 前置: `docs/architecture-restart.md` §11 已拍板(方案 A / 暂不做脚本插件 / 用 ncm-api-rs)。
> M0 目标: **两端能启动 + 桥能往返 + 协议库在 Linux 真实取到直链**。不写业务 UI。

## 0. 环境(一次性)

| 项 | 版本/命令 | 备注 |
|---|---|---|
| Flutter SDK | stable(锁一个版本写进 `.fvmrc` 或 `FLUTTER_VERSION`) | 本机未装,需 `~/android-dev` 同级用户级安装 |
| Rust | 已装 1.99.1 | 追加 target: `aarch64-linux-android`、`x86_64-unknown-linux-gnu` |
| cargo-ndk + NDK | `cargo install cargo-ndk`, SDK 里装 `ndk;27.x` | Android 交叉编译 |
| flutter_rust_bridge_codegen | `cargo install flutter_rust_bridge_codegen` | 桥代码生成 |
| 现有 JDK21 / Gradle8.9 | 复用 `~/android-dev` | 不重装 |

## 1. 目录骨架(新建,旧代码保留在 `legacy/`)

```
netease-mini-player/
├── core/                       # cargo workspace
│   ├── Cargo.toml
│   ├── crates/
│   │   ├── ncm-domain/         # 领域模型(纯,无 IO)
│   │   ├── ncm-provider/       # Provider trait + Registry + ProviderError
│   │   ├── ncm-service/        # 组合: 会话、队列、缓存、SQLite
│   │   ├── ncm-ffi/            # cdylib: flutter_rust_bridge 暴露面
│   │   └── ncm-cli/            # bin: search / url / lyric / download
│   └── vendor/ncm-api/         # 锁定的 ncm-api-rs(patch 记录见 vendor/README.md)
├── ui/                         # Flutter(android + linux)
├── platform/android/           # Kotlin: Media3 / 登录 WebView / 前台服务
├── platform/linux/             # Rust: mpv、MPRIS、托盘(可后置)
└── legacy/                     # 现有 android/ + plugins/ + tools/(只读存档)
```

迁移方式: `git mv android legacy/android`、`git mv plugins legacy/plugins`、`git mv tools legacy/tools`
(新 `tools/` 重建),一次性提交,历史不丢。

## 2. 步骤与验收

| 步 | 动作 | 验收(命令) | 估时 |
|---|---|---|---|
| S1 | 装 Flutter + 建 `ui/`(`--platforms=android,linux`)+ 空跑两端 | `flutter run -d linux` 出窗口;`flutter build apk --debug` 出包 | 0.5~1d |
| S2 | cargo workspace + 五个 crate 空壳 + `ncm-domain` 单测 | `cargo test -p ncm-domain` 绿 | 0.5d |
| S3 | vendor `ncm-api`(pin commit),`ncm-cli` 接上: `search` | `cargo run -p ncm-cli -- search 晴天` 打印结构化结果 | 1d |
| S4 | `ncm-cli url <id> --level exhigh` + 下载前 1MB 校验 | 抓到直链并 `curl` 到音频字节;记录 HTTP/域名/耗时 | 0.5d |
| S5 | 通道 spike: 同一请求分别打 `interface` / `interface3`,记录 code/是否 403 | 出一张对照表写进 `docs/api-channel.md` | 0.5d |
| S6 | `ncm-ffi` 暴露 `ping()` + `search()`;`flutter_rust_bridge` 生成绑定 | UI 按钮点击显示搜索结果条数 | 1d |
| S7 | Android faceless 交叉编译验证: `cargo ndk -t arm64-v8a -o ui/android/app/src/main/jniLibs build -p ncm-ffi` | APK 里含 `libncm_ffi.so`,启动不崩 | 0.5d |
| S8 | 构建脚本 + CI(ubuntu-latest: cargo test + flutter build linux + assembleDebug) | 一条 `bash tools/ci.sh` 本地全绿 | 0.5d |

合计 **4~5 天**。

## 3. 这一步就要定死的接口(之后改代价大)

```rust
// ncm-provider
pub trait Provider: Send + Sync {
    fn id(&self) -> &'static str;
    fn capabilities(&self) -> &'static [Capability];      // search/songUrl/lyric/login/...
    fn search(&self, q: SearchQuery) -> BoxFuture<'_, Result<SearchPage>>;
    fn song_url(&self, req: SongUrlRequest) -> BoxFuture<'_, Result<StreamUrl>>;
    fn lyric(&self, id: TrackId) -> BoxFuture<'_, Result<Lyric>>;
}

pub enum ProviderErrorKind { Network, Auth, RiskControl, NotFound, Unsupported, Internal }
pub struct ProviderError { pub kind: ProviderErrorKind, pub retryable: bool, pub detail: String }
```

规则:
- provider 只吃 DTO、只吐 DTO,**不碰** SQLite / 播放器 / UI 类型;
- `StreamUrl` 带 `expire_at`,让队列在到期前换链(直链有时效,这是个真实坑);
- 任何"风控"都归 `RiskControl`,UI 文案与重试策略统一处理。

## 4. 会话与身份(必须第一天就做对)

```rust
pub struct Session { pub cookie: String, pub device_id: String, pub profile: Option<Profile> }
```
- `device_id`: 首启生成 52 hex,写 `app_data/identity.json`,**永久复用**(登出/重装应用不换;库默认随机必须覆盖);
- 设备 cookie(`NMTID/_ntes_nuid/_ntes_nnid/WNMCID/WEVNSM`)同文件持久化;
- 身份头/`os` 参数按平台注入:`os=pc, appver=3.1.17, osver=Windows 10`(桌面) / `os=android, appver=8.20.20`(安卓);
- 敏感文件权限 0600(Linux)/ 应用私有目录(Android),不入日志。

## 5. 明确不做(M0 范围外)

- 不做 QuickJS / 插件导入 UI(只留 `Provider` 接口);
- 不做播放器(Media3 / mpv 放 M2);
- 不做登录 UI(M4),M0 用 CLI 的 cookie 参数即可;
- 不做主题/动画/多语言。

## 6. M0 结束时的三个数字

1. `cargo test` 用例数 + 全绿耗时;
2. Linux 上 `ncm-cli search/url` 的成功率与耗时(含冷/热);
3. APK debug 体积 + 空壳冷启动与 PSS(给 M3 的预算一个基线)。
