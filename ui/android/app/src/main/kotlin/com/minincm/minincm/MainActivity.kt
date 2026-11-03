package com.minincm.minincm

import android.Manifest
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Build
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
    private var controllerFuture: ListenableFuture<MediaController>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/player")
        channel.setMethodCallHandler { call, result ->
            try {
                handle(call.method, call.arguments as? Map<*, *>, result)
            } catch (e: Exception) {
                result.error("player_error", e.message, null)
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

    override fun onDestroy() {
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controller = null
        super.onDestroy()
    }
}
