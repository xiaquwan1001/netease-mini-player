# R8 / 资源压缩的保留规则(2026-11-28 构建链审计 #1)。
#
# 原则: 只保留**反射/跨进程入口**, 其余交给 R8。Flutter 引擎与 media3 的
# consumer rules 已经在各自 AAR 里, 这里不重复抄它们(抄了等于关掉压缩收益)。

# 平台层(本 App 的 Kotlin)全部保留: 它是 MethodChannel handler、MediaSession.Callback、
# 通知 CommandButton 的 builder 与 BroadcastReceiver 的宿主 —— 入口全由字符串/框架反射
# 决定, R8 看不到调用边。包很小(~千行), 收益不值得为它冒一次线上 NoSuchMethod。
-keep class com.minincm.minincm.** { *; }

# Flutter 嵌入层: FlutterActivity/插件注册走反射(引擎 consumer rules 之外再兜一层,
# 因为本工程用 FlutterActivity 子类 + 自定义通道名)。
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# 泛型/注解/内部类签名: Kotlin 反射与 Gson(仅单测, 但保持一致性)需要
-keepattributes Signature, InnerClasses, EnclosingMethod, *Annotation*

# media3 的通知/会话动作在恢复播放时按类名与 Intent action 反序列化
-keepclassmembers class androidx.media3.session.** { *; }
-dontwarn androidx.media3.**
