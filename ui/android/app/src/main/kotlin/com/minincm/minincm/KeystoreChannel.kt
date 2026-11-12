package com.minincm.minincm

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keystore 凭据后端(通道层, 调研报告 §2c).
 *
 * - 密钥: Android Keystore 里 AES-256-GCM, alias `minincm-cred-v1`,
 *   不设 setUserAuthenticationRequired(后台/无感读取).
 * - 落盘: filesDir/cred/<key>.bin, 内容 = 12 字节 IV + 密文, 每次写随机 IV.
 * - 失效语义: 清数据/备份恢复导致密钥丢失或解密失败时, 一律删文件并回
 *   null / false, 绝不把异常抛到 Dart.
 * - 不打任何含明文的日志; Rust identity 侧尚未接线.
 */
object KeystoreChannel {
    private const val CHANNEL = "ncm/keystore"
    private const val KEY_ALIAS = "minincm-cred-v1"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_LEN = 12
    private const val TAG_BITS = 128

    fun register(messenger: FlutterEngine, context: Context) {
        val channel = MethodChannel(messenger.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            val key = args?.get("key") as? String
            try {
                when (call.method) {
                    "put" -> {
                        val value = args?.get("value") as? String
                        if (key.isNullOrEmpty() || value == null) {
                            result.error("bad_args", "key/value missing", null)
                        } else {
                            result.success(put(context, key, value))
                        }
                    }
                    "get" -> {
                        if (key.isNullOrEmpty()) {
                            result.error("bad_args", "key missing", null)
                        } else {
                            result.success(get(context, key))
                        }
                    }
                    "remove" -> {
                        if (key.isNullOrEmpty()) {
                            result.error("bad_args", "key missing", null)
                        } else {
                            result.success(remove(context, key))
                        }
                    }
                    "list" -> result.success(listKeys(context))
                    "available" -> result.success(available())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                // 兜底: 任何 Keystore/IO 异常都不抛到 Dart, 按失效处理
                if (call.method == "get") result.success(null) else result.success(false)
            }
        }
    }

    private fun credDir(context: Context): File = File(context.filesDir, "cred")

    private fun fileFor(context: Context, key: String): File {
        // key 来自 Dart, 只允许文件名安全字符, 其余替换成 _ 防路径穿越
        val safe = key.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(credDir(context), "$safe.bin")
    }

    /// 现存凭据 key 列表(去 .bin 后缀), 供启动 restore 拉全量.
    /// 只回文件名, 不含任何明文.
    @Synchronized
    private fun listKeys(context: Context): List<String> = try {
        val dir = credDir(context)
        (dir.listFiles() ?: emptyArray())
            .filter { it.isFile && it.name.endsWith(".bin") }
            .map { it.name.removeSuffix(".bin") }
    } catch (e: Exception) {
        emptyList()
    }

    @Synchronized
    private fun obtainKey(): SecretKey? = try {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
            ?: run {
                val gen = KeyGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_AES,
                    ANDROID_KEYSTORE,
                )
                gen.init(
                    KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build(),
                )
                gen.generateKey()
            }
    } catch (e: Exception) {
        null
    }

    fun available(): Boolean = try {
        obtainKey() != null
    } catch (e: Exception) {
        false
    }

    @Synchronized
    private fun put(context: Context, key: String, value: String): Boolean {
        val key2 = obtainKey() ?: return false
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key2)
            val iv = cipher.iv
            val ct = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val dir = credDir(context)
            if (!dir.exists()) dir.mkdirs()
            val out = fileFor(context, key)
            val tmp = File(dir, out.name + ".tmp")
            tmp.outputStream().use { s ->
                s.write(iv)
                s.write(ct)
            }
            if (!tmp.renameTo(out)) {
                out.delete()
                tmp.renameTo(out)
            } else {
                true
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            false
        } catch (e: Exception) {
            false
        }
    }

    @Synchronized
    private fun get(context: Context, key: String): String? {
        val f = fileFor(context, key)
        if (!f.isFile) return null
        val blob = try {
            f.readBytes()
        } catch (e: Exception) {
            return null
        }
        if (blob.size <= IV_LEN) {
            f.delete()
            return null
        }
        val key2 = obtainKey()
        if (key2 == null) {
            f.delete()
            return null
        }
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key2, GCMParameterSpec(TAG_BITS, blob, 0, IV_LEN))
            String(cipher.doFinal(blob, IV_LEN, blob.size - IV_LEN), Charsets.UTF_8)
        } catch (e: KeyPermanentlyInvalidatedException) {
            f.delete()
            null
        } catch (e: Exception) {
            // AEADBadTagException 等 = 密钥已换(清数据/备份恢复), 删掉旧密文
            f.delete()
            null
        }
    }

    @Synchronized
    private fun remove(context: Context, key: String): Boolean = try {
        fileFor(context, key).delete()
    } catch (e: Exception) {
        false
    }
}
