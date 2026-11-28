import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/// 正式签名 keystore 配置: ui/android/key.properties(不入库, 见 ui/android/.gitignore)
///   storeFile=/绝对路径/minincm-release.jks
///   storePassword=...
///   keyAlias=minincm
///   keyPassword=...
/// 缺失时回落到 debug 签名(新克隆/无凭据环境仍能构建), 但那样每次构建签名都可能不同,
/// 已发布的 APK 永远无法覆盖升级 —— 正式发布必须在带 keystore 的环境里构建。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.minincm.minincm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.minincm.minincm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 应用名走资源: release=「轻音 MiniNCM」, debug 额外加 (dev) 后缀,
        // 避免桌面上和正式包同名 —— 视觉验收时点错旧版本(曾把 0.5.5 当成新包)。
        resValue("string", "app_name", "轻音 MiniNCM")
        // P-11: instrumented 测试(需要模拟器, 见 src/androidTest/)。
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // ABI 约束: 本项目的目标设备只有 64 位(arm64 真机 / x86_64 模拟器)。
        // 不写这里时 `flutter build apk`(不带 --split-per-abi) 会打进 3–4 个 ABI,
        // 实测 226.8MB(含已不支持的 v7a, 其链接在 rustc+NDK 下本来就失败)。
        // 口径必须与 tools/build-android.sh 的 --target-platform 一致。
        //
        // **不能与 splits 同时存在**: `--split-per-abi` 时 Flutter 插件自己按
        // --target-platform 配 `splits.abi`, AGP 会直接报
        // "Conflicting configuration : 'x86_64,arm64-v8a' in ndk abiFilters cannot be
        // present when splits abi filters are set"(2026-11-28 实测) ⇒ 只在没开拆分时兜底。
        if (!(project.findProperty("split-per-abi")?.toString()?.toBoolean() ?: false)) {
            ndk {
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // debug 包换包名后缀: 可以和正式包并存, 真机验证时不会顶掉已装版本,
            // 也不会因签名不同而 INSTALL_FAILED_UPDATE_INCOMPATIBLE。
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "轻音 MiniNCM dev")
        }
        release {
            // R8 + 资源压缩(2026-11-28 构建链审计 #1): 之前两项都是默认 false,
            // media3/kotlin 全量进 classes.dex(实测 1,927,164 B)。
            // 规则见 app/proguard-rules.pro(只保留反射入口, 不抄 AAR 的 consumer rules)。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "WARNING: ui/android/key.properties 不存在 → release 用 debug 签名; " +
                        "该 APK 无法覆盖升级其他签名构建出的版本"
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.9.4")
    implementation("androidx.media3:media3-session:1.9.4")
    // S3: SimpleCache/CacheDataSource/LeastRecentlyUsedCacheEvictor 在 datasource 模块里;
    // exoplayer 只是传递依赖它, 这里显式声明并锁到同一 1.9.4, 避免版本漂移
    implementation("androidx.media3:media3-datasource:1.9.4")
    implementation("androidx.core:core-ktx:1.17.0")

    // P-11: 纯逻辑(Kotlin 解析/biquad)的 JVM 单测, 不需要设备也不需要真机.
    // 三端共享夹具 ui/test/fixtures/eq_profile_cases.json 由 EqProfileParserFixtureTest 读取;
    // gson 用来读该 JSON —— Android 的 org.json 在 JVM 单测里是 android.jar 的桩(调用即抛),
    // 所以这里显式用 gson(2.10.1 与本机 gradle 缓存一致, 可离线解析).
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.google.code.gson:gson:2.10.1")

    // P-11: instrumented(设备上跑)测试。只允许在模拟器上跑(见 tools/devui/androidtest),
    // 用户物理机上的 App 绝不能被这套测试 install/uninstall。
    // 只有 test 那一半是设备无关的 JVM 单测(android-unit 门); 这里的 androidTest 需要 :app:connectedDebugAndroidTest。
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:core-ktx:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
}

flutter {
    source = "../.."
}
