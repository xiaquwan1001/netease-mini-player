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
}

flutter {
    source = "../.."
}
