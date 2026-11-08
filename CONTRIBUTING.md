# 贡献指南(Contributing)

欢迎 issue / PR。这个项目的取舍很明确:**极简、可长期维护**,所以"少加代码"通常比"多加功能"更受欢迎。

## 开发环境

全部依赖装在用户目录,不碰系统包(见 `tools/env.sh`):

```bash
source tools/env.sh          # JDK 21 / Flutter / Android SDK / Rust
bash tools/build-linux.sh    # Linux bundle
bash tools/build-android.sh  # Android debug APK
```

细节见 `docs/architecture-restart.md` 与 `docs/testing-dual-platform.md`。

## 提 PR 前请自测

| 门禁 | 命令 |
|---|---|
| Rust 单测 | `cargo test --manifest-path core/Cargo.toml --workspace --exclude ncm-api-rs` |
| Dart 静态检查 | `cd ui && dart analyze`(0 error / 0 warning) |
| Flutter 单测 | `cd ui && flutter test --exclude-tags network` |
| 双端构建 | `bash tools/build-linux.sh` + `bash tools/build-android.sh` |

- 真实联网 smoke 打了 `network` 标签(上游风控会抖),本地可跑 `flutter test`,
  CI 默认跳过。
- 格式暂未强制(`cargo fmt` / `dart format` 历史代码未统一),请不要整文件重排制造大 diff。

## 代码约定

- **协议/风控/加解密只用 `core/vendor/ncm-api`**,不要自己重写加密或猜接口;
  需要新接口时先在 `ncm-service` 里包装,并补单测。
- 跨层只传 `ncm-domain` 里可序列化的类型;UI 不直接吃 `serde_json::Value`。
- provider 的外部错误统一转 `ProviderError{kind, retryable, detail}`,UI 按 `kind` 决策。
- **平台差异只允许出现在** `ui/lib/src/playback.dart` 与 `ui/lib/src/platform.dart`。
- 身份纪律:`device_id` 首启生成后永久复用,设备 cookie 必须持久化,禁止每进程随机。
- 不引第三方**平台插件**(原生能力用自建 MethodChannel:`ncm/player` `ncm/auth` `ncm/open` `ncm/share`)。
- 提交信息用 Conventional Commits(`feat(ui): …` / `fix(core): …` / `docs: …`)。

## 不要提交的东西

凭据(`identity.json`、cookie、token)、`key.properties`、keystore、`dist/` 产物、
`screenshots/` 临时走查图。发现凭据泄露请直接开 issue 说明,不要在 PR 里贴。

## 许可

提交即表示你同意以本项目的 **MIT** 许可发布你的贡献;
依赖与第三方组件的许可见 `THIRD_PARTY_NOTICES.md`。
