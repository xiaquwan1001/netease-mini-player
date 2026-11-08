# Android 签名与版本号

> 结论先行: **正式发布的 APK 必须用固定 keystore 签名, 且 `versionCode` 每次递增**。
> 二者任一不满足, 已安装用户就只能卸载重装(丢本地设置/登录态)。

## 1. 为什么必须固定签名

Android 只允许「同包名 + 同签名证书」的 APK 覆盖安装。签名换了就是
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`(签名不符), 只能 `adb uninstall` 后再装。

v0.1.0 的 APK 是用 **debug 签名**出的:
- 本地 debug keystore 是 `~/.android/debug.keystore`, 每台机器不同;
- GitHub Actions 每次 runner 都是全新环境, 生成的 debug keystore 也每次不同。

于是「CI 出的包」和「本地出的包」签名不一致, 甚至两次 CI 之间也不一致 ⇒ 用户装了
v0.1.0 之后无法升级到 v0.1.1, 只能卸载重装。

## 2. 本地正式签名

```bash
# 1) 一次性生成 keystore(放到仓库外, 不要提交; 密码自己保管)
mkdir -p ~/.android/keys
keytool -genkeypair -v -keystore ~/.android/keys/minincm-release.jks \
  -alias minincm -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=MiniNCM, O=MiniNCM, C=CN"

# 2) 写 ui/android/key.properties(已在 .gitignore 里, 不会入库)
cat > ui/android/key.properties <<EOF
storeFile=$HOME/.android/keys/minincm-release.jks
storePassword=<keystore 密码>
keyAlias=minincm
keyPassword=<key 密码>
EOF
```

缺失 `key.properties` 时 Gradle 回落到 debug 签名并打印警告 —— 新克隆的仓库仍然能构建,
但**不要**把那产物当正式发布包。

> keystore 与密码属于凭据: 不进仓库、不进记忆文件, 丢了就再也无法发升级包(只能换包名或换签名重来)。

## 3. CI 正式签名

在 GitHub 仓库 Settings → Secrets and variables → Actions 里加:

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 ~/.android/keys/minincm-release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 例如 `minincm` |
| `ANDROID_KEY_PASSWORD` | key 密码 |

`.github/workflows/release.yml` 会在构建前把 keystore 落成 `ui/android/release.jks` +
`key.properties`; 没配 Secret 时打印 `::warning::` 并回落到 debug 签名。

## 4. 版本号规则

单一来源: `ui/pubspec.yaml` 的 `version: X.Y.Z+N`
- `X.Y.Z` → `versionName`(用户可见, 也决定 Release 资产名 `MiniNCM-X.Y.Z-...`)
- `+N` → `versionCode`(**覆盖安装必须严格递增**)

改版本号只走脚本, 它会同时同步 `ui/lib/src/app_meta.dart` 的 `kAppVersion`
(设置页「关于」显示的值), 一致性由 `ui/test/version_consistency_test.dart` 守住:

```bash
bash tools/bump-version.sh patch   # 0.1.1+2 -> 0.1.2+3 ; minor/major 同理
```

发布流程: bump → 提交 → `git tag vX.Y.Z` → push tag → CI 出 APK + Linux 包。

## 5. 真机验证时的并存安装

`debug` buildType 带 `applicationIdSuffix = ".dev"`(包名 `com.minincm.minincm.dev`,
版本名后缀 `-dev`), 所以调试包可以和正式包同时装在手机上, 既不会顶掉正式版,
也不会因签名不同而安装失败:

```bash
bash tools/build-android.sh          # 出 ui/build/app/outputs/flutter-apk/app-debug.apk
adb install -r ui/build/app/outputs/flutter-apk/app-debug.apk   # 装成 .dev 包
```

注意: `.dev` 包有自己的数据目录与登录态, 和正式包不共享。
