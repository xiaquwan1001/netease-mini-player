package com.minincm.minincm

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.webkit.CookieManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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

        val token = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        controllerFuture = MediaController.Builder(this, token).buildAsync().also { future ->
            future.addListener({
                controller = runCatching { future.get() }.getOrNull()
            }, ContextCompat.getMainExecutor(this))
        }

        ensureNotificationPermission()
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
                c.volume = ((args?.get("volume") as? Number)?.toFloat() ?: 1f).coerceIn(0f, 1f)
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
        playerChannel = null
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controller = null
        super.onDestroy()
    }
}
