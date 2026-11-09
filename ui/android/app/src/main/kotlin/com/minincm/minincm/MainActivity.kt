package com.minincm.minincm

import android.Manifest
import android.app.DownloadManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var controller: MediaController? = null
    private var playerChannel: MethodChannel? = null
    private var controllerFuture: ListenableFuture<MediaController>? = null

    /** 官方网页登录: 页面结束后把 cookie 交回 Dart */
    private var pendingLogin: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/player")
        playerChannel = channel
        // 通知栏/耳机键/蓝牙的上一首·下一首: 播放队列在 Dart, 这里只做转发
        PlaybackService.skipListener = { next ->
            runOnUiThread {
                channel.invokeMethod(if (next) "skipNext" else "skipPrevious", null)
            }
        }
        // 通知栏自定义按钮(喜欢/播放顺序): 同样只转发, 状态与副作用都在 Dart
        PlaybackService.actionListener = { cmd ->
            runOnUiThread {
                channel.invokeMethod(
                    if (cmd == PlaybackService.CMD_LIKE) "toggleLike" else "cycleMode",
                    null,
                )
            }
        }
        channel.setMethodCallHandler { call, result ->
            try {
                handle(call.method, call.arguments as? Map<*, *>, result)
            } catch (e: Exception) {
                result.error("player_error", e.message, null)
            }
        }

        // 登录通道: WebView 里完成官方授权页登录, 只回传 cookie, 不碰账号密码
        val auth = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/auth")
        auth.setMethodCallHandler { call, result ->
            when (call.method) {
                "loginWeb" -> {
                    if (pendingLogin != null) {
                        result.error("login_busy", "登录页已经打开了", null)
                    } else {
                        pendingLogin = result
                        startActivityForResult(
                            Intent(this, LoginActivity::class.java),
                            LoginActivity.REQUEST_CODE,
                        )
                    }
                }
                // 退出/切换账号时必须清掉 WebView 的 cookie, 否则再开登录页会以旧账号自动登录
                "clearCookies" -> {
                    CookieManager.getInstance().removeAllCookies { removed ->
                        CookieManager.getInstance().flush()
                        result.success(removed)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 打开外部链接 / 下载: 不引第三方插件, 用系统 Intent + DownloadManager
        val open = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/open")
        open.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "openUrl" -> {
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "url missing", null)
                    } else {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("open_error", e.message, null)
                        }
                    }
                }
                "download" -> {
                    val url = args?.get("url") as? String
                    val filename = (args?.get("filename") as? String) ?: "download.mp3"
                    val ua = args?.get("ua") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "url missing", null)
                    } else {
                        try {
                            val req = DownloadManager.Request(Uri.parse(url))
                                .setTitle(filename)
                                .setDescription("轻音 MiniNCM 下载")
                                .setNotificationVisibility(
                                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                                )
                                .setDestinationInExternalPublicDir(
                                    Environment.DIRECTORY_DOWNLOADS,
                                    "MiniNCM/$filename"
                                )
                            if (!ua.isNullOrBlank()) req.addRequestHeader("User-Agent", ua)
                            req.addRequestHeader("Referer", "https://music.163.com/")
                            val dm = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
                            result.success(dm.enqueue(req).toString())
                        } catch (e: Exception) {
                            result.error("download_error", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 歌曲分享: 图片走 FileProvider + ACTION_SEND, 不引第三方插件
        val share = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/share")
        share.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            val bytes = args?.get("bytes") as? ByteArray
            val filename = (args?.get("filename") as? String) ?: "share.png"
            val text = (args?.get("text") as? String) ?: ""
            if (bytes == null || bytes.isEmpty()) {
                result.error("bad_args", "bytes missing", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "shareImage" -> {
                        val file = writeShareCache(bytes, sanitize(filename))
                        val uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            file,
                        )
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "image/png"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            // clipData 必须一起带上: 只给 EXTRA_STREAM 时, 系统选择器
                            // (com.android.intentresolver) 的缩略图预览会报
                            // "Permission Denial ... FileProvider ... not exported"
                            clipData = android.content.ClipData.newRawUri("image", uri)
                            if (text.isNotBlank()) putExtra(Intent.EXTRA_TEXT, text)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(intent, "分享到"))
                        result.success(true)
                    }
                    // 保存到系统图库: Q+ 走 MediaStore(免权限), 老系统落公共 Pictures
                    "saveImage" -> result.success(saveToGallery(bytes, sanitize(filename)))
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("share_error", e.message, null)
            }
        }

        val token = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        controllerFuture = MediaController.Builder(this, token).buildAsync().also { future ->
            future.addListener({
                controller = runCatching { future.get() }.getOrNull()
            }, ContextCompat.getMainExecutor(this))
        }

        ensureNotificationPermission()
    }

    private fun sanitize(name: String): String =
        name.replace(Regex("""[/\\:*?"<>|]"""), "_").ifBlank { "share.png" }

    /** 分享用的临时文件: 必须放在 FileProvider 声明的路径(cache/shared)下 */
    private fun writeShareCache(bytes: ByteArray, filename: String): File {
        val dir = File(cacheDir, "shared")
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, filename)
        file.writeBytes(bytes)
        return file
    }

    private fun saveToGallery(bytes: ByteArray, filename: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = android.content.ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, filename)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/MiniNCM")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("无法写入图库")
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "系统图库 Pictures/MiniNCM"
        }
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "MiniNCM",
        )
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, filename)
        file.writeBytes(bytes)
        return file.absolutePath
    }

    private fun dataDir(): String {
        val dir = File(filesDir, "ncm")
        if (!dir.exists()) dir.mkdirs()
        return dir.absolutePath
    }

    private fun handle(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        if (method == "dataDir") {
            result.success(dataDir())
            return
        }
        // configure 不需要 MediaController: 它落在 PlaybackService 上(服务拥有 ExoPlayer)
        if (method == "configure") {
            val svc = PlaybackService.instance
            if (svc == null) {
                result.error("not_ready", "PlaybackService 尚未创建", null)
            } else {
                result.success(svc.configure(args ?: emptyMap<Any?, Any?>()))
            }
            return
        }
        // cachedAudioFile 同 configure: 落在 PlaybackService(缓存由它拥有)
        if (method == "cachedAudioFile") {
            val url = args?.get("url") as? String
            val svc = PlaybackService.instance
            if (url == null) {
                result.error("bad_args", "url missing", null)
            } else if (svc == null) {
                result.error("not_ready", "PlaybackService 尚未创建", null)
            } else {
                result.success(svc.cachedFileFor(url))
            }
            return
        }
        // 通知按钮状态回传(Dart → 原生): 更新按钮图标并刷新通知
        if (method == "setActionState") {
            val liked = args?.get("liked") as? Boolean ?: false
            val icon = args?.get("modeIcon") as? String ?: "sequence"
            PlaybackService.instance?.setActionState(liked, icon)
            result.success(null)
            return
        }
        val c = controller
        if (c == null) {
            result.error("not_ready", "MediaController 尚未连接", null)
            return
        }
        when (method) {
            "play" -> {
                val url = args?.get("url") as? String ?: return result.error("bad_args", "url missing", null)
                val title = args["title"] as? String ?: ""
                val artist = args["artist"] as? String ?: ""
                val trackId = (args["trackId"] as? Number)?.toLong() ?: 0L
                val item = MediaItem.Builder()
                    .setUri(url)
                    .setMediaId(trackId.toString())
                    .setMediaMetadata(
                        MediaMetadata.Builder()
                            .setTitle(title)
                            .setArtist(artist)
                            .build()
                    )
                    .build()
                c.setMediaItem(item)
                c.prepare()
                c.play()
                // 换曲/开始: 按 fadeMs 做淡入, 避免切歌爆音(0 = 关闭)
                PlaybackService.instance?.fadeIn()
                result.success(stateMap(c))
            }
            "pause" -> { c.pause(); result.success(stateMap(c)) }
            "resume" -> { c.play(); result.success(stateMap(c)) }
            "stop" -> { c.stop(); c.clearMediaItems(); result.success(stateMap(c)) }
            "seek" -> {
                c.seekTo(((args?.get("positionMs") as? Number)?.toLong() ?: 0L))
                result.success(stateMap(c))
            }
            "volume" -> {
                val v = ((args?.get("volume") as? Number)?.toFloat() ?: 1f).coerceIn(0f, 1f)
                // 用户音量档交给服务管(服务会乘上精细增益), 避免两端各存一份音量状态
                val svc = PlaybackService.instance
                if (svc != null) svc.setUserVolume(v) else c.volume = v
                result.success(stateMap(c))
            }
            "state" -> result.success(stateMap(c))
            else -> result.notImplemented()
        }
    }

    private fun stateMap(c: MediaController): Map<String, Any?> {
        val duration = if (c.duration == C.TIME_UNSET) 0L else c.duration
        return mapOf(
            "trackId" to c.currentMediaItem?.mediaId?.toLongOrNull(),
            "playing" to c.isPlaying,
            "positionMs" to c.currentPosition,
            "durationMs" to duration,
            "volume" to c.volume.toDouble(),
        )
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    101,
                )
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == LoginActivity.REQUEST_CODE) {
            val cookie = data?.getStringExtra(LoginActivity.EXTRA_COOKIE)
            pendingLogin?.success(if (cookie.isNullOrBlank()) null else cookie)
            pendingLogin = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        PlaybackService.skipListener = null
        PlaybackService.actionListener = null
        playerChannel = null
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controller = null
        super.onDestroy()
    }
}
