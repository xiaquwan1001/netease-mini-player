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
import android.provider.Settings
import android.webkit.CookieManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
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

    /** 云盘上传选文件: ACTION_OPEN_DOCUMENT 结束后把本地副本路径交回 Dart */
    private var pendingPick: MethodChannel.Result? = null

    /**
     * 通知按钮在没有同进程消费者时(上划清任务后)会用 Intent 把 App 拉起来并带上动作,
     * 动作先在这里接住, 等 Dart 侧回调注册好(_registerNativeHandler 会调 actionHandlersReady)再执行。
     */
    private var pendingPlaybackAction: Pair<String, Long>? = null

    /** Dart 侧的通知回调是否已注册(握手方法 = ncm/player#actionHandlersReady) */
    private var dartActionReady = false

    companion object {
        private const val REQUEST_PICK_AUDIO = 4201

        /** 拉起 App 到 Dart 回调就绪之间的最大容忍时间; 超过就丢弃(过期的「下一首」执行起来很突兀) */
        private const val PLAYBACK_ACTION_TTL_MS = 60_000L

        private const val TAG = "NCM-PLAYER"
    }

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
                val method = when (cmd) {
                    PlaybackService.CMD_LIKE -> "toggleLike"
                    PlaybackService.CMD_MODE -> "cycleMode"
                    // 通知栏「下一首」: 与耳机键/锁屏的 skipNext 走同一条 Dart 队列
                    PlaybackService.CMD_NEXT -> "skipNext"
                    else -> null
                }
                if (method != null) channel.invokeMethod(method, null)
            }
        }
        // 通知按钮状态回读(P-02): 服务被系统回收重建 / 控制器重连时请求 Dart 重推红心/模式,
        // 主线程投递是因为这里会被 PlaybackService 的 MediaSession 回调触发。
        PlaybackService.actionStateSyncListener = {
            runOnUiThread { playerChannel?.invokeMethod("syncActionState", null) }
        }
        channel.setMethodCallHandler { call, result ->
            try {
                handle(call.method, call.arguments as? Map<*, *>, result)
            } catch (e: Exception) {
                result.error("player_error", e.message, null)
            }
        }

        // 登录通道: WebView 里完成官方授权页登录, 只回传 cookie, 不碰账号密码
        // 云盘上传: 选一个音频文件, 复制到 cache 后把**绝对路径**交给 Dart/Rust 去传
        // (Rust 侧只认本地路径; content:// 不能直接读, 所以这里先落盘)。
        val uploadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/upload")
        uploadChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickAudio" -> {
                    if (pendingPick != null) {
                        result.error("pick_busy", "选文件窗口已经打开了", null)
                    } else {
                        pendingPick = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "audio/*"
                        }
                        startActivityForResult(intent, REQUEST_PICK_AUDIO)
                    }
                }
                else -> result.notImplemented()
            }
        }

        val auth = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/auth")
        auth.setMethodCallHandler { call, result ->
            when (call.method) {
                // 只负责开页面: 清 WebView cookie 的动作在 LoginActivity.onCreate 里做,
                // 且必须等异步清理回调落地后再 loadUrl(P-08, 只留一处语义)。
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

        // 凭据存储: Android Keystore 后端(通道层, 见 KeystoreChannel.kt)
        // Rust identity 侧尚未接线, 这里先把通道挂上, 便于 Dart/手工验证.
        KeystoreChannel.register(flutterEngine, this)

        // MV 播放: 起独立 VideoView Activity, 不进 Media3 歌曲队列
        val mv = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncm/mv")
        mv.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "play" -> {
                    val url = args?.get("url") as? String
                    val title = args?.get("title") as? String ?: "MV"
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "url missing", null)
                    } else {
                        try {
                            val intent = Intent(this, MvPlayerActivity::class.java)
                                .putExtra(MvPlayerActivity.EXTRA_URL, url)
                                .putExtra(MvPlayerActivity.EXTRA_TITLE, title)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("mv_error", e.message, null)
                        }
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
                // 通知权限(P2#7): 设置页要把「有没有通知权限」如实显示出来, 并在被拒绝时
                // 给一个直达本应用通知设置页的入口 —— 否则用户拒过一次就再无出路。
                "notificationPermissionGranted" -> result.success(hasNotificationPermission())
                "openNotificationSettings" -> {
                    try {
                        startActivity(notificationSettingsIntent())
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("settings_error", e.message, null)
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
                val c = runCatching { future.get() }.getOrNull()
                controller = c
                // 播完立刻告诉 Dart(而不是等 500ms 轮询发现"位置到末尾了"):
                // 自动续播的间隙就是这两步的延迟堆出来的, 用户听感上是"每首都卡一下"
                c?.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_ENDED) {
                            channel.invokeMethod("trackEnded", null)
                        }
                    }
                })
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
        // Dart 侧通知回调(上一首/下一首/喜欢/模式)已注册: 执行先前排队等待的意图,
        // 并顺手请原生把红心/模式重推一次(此时才有真正的状态可推)。
        if (method == "actionHandlersReady") {
            dartActionReady = true
            // 同一次点击可能**既**塞进了拉起用的 Intent, **又**排在服务的兜底队列里(launchForAction
            // 两条路都会留痕)。两个都执行 = 「下一首」跳两首, 所以只取一条:
            // Intent 里带的那条时间戳最新, 优先用它; 用了它就作废队列里那条。
            val hadIntentAction = pendingPlaybackAction != null
            deliverPendingPlaybackAction()
            if (hadIntentAction) {
                PlaybackService.discardPendingFallback()
            } else {
                // 上划清任务时点过通知按钮、但拉起被 Android 14 BAL 拦掉的情形: 用户从通知本体回到 App,
                // 此时 Dart 已就绪, 把排在服务里的那条意图补执行(Toast 里承诺过的动作真的会发生)。
                PlaybackService.consumePendingFallbackAction()?.let { action ->
                    android.util.Log.i(TAG, "补执行排队的通知按钮意图 " + action)
                    dispatchPlaybackAction(action, 0L)
                }
            }
            PlaybackService.instance?.requestActionStateSync()
            result.success(null)
            return
        }
        if (method == "dataDir") {
            result.success(dataDir())
            return
        }
        // 播放 UA 的唯一来源在 Rust(ncm-service 的 platform_profile().ua), Dart 启动时把它
        // 推进来; 服务还没创建也照样收下(存 companion 静态字段, onCreate 时读)。
        // 兜底常量留在 PlaybackService.FALLBACK_USER_AGENT(P-21)。
        if (method == "setUserAgent") {
            PlaybackService.setUserAgent(args?.get("ua") as? String)
            result.success(null)
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
                // 通知/锁屏/车载的封面 = 当前播放内容的图(歌曲封面或播客封面)。
                // 由 Dart 带正确 UA 下载好字节传进来: 让 Media3 自己按 URL 拉图会
                // 用默认 UA 被网易 CDN 回 403, 通知上就是个空白方块。
                val artwork = args?.get("artwork") as? ByteArray
                val metadata = MediaMetadata.Builder()
                    .setTitle(title)
                    .setArtist(artist)
                if (artwork != null && artwork.isNotEmpty()) {
                    metadata.setArtworkData(
                        artwork,
                        MediaMetadata.PICTURE_TYPE_FRONT_COVER,
                    )
                }
                val item = MediaItem.Builder()
                    .setUri(url)
                    .setMediaId(trackId.toString())
                    .setMediaMetadata(metadata.build())
                    .build()
                c.setMediaItem(item)
                // 恢复现场的续播(F7): 起播位置直接交给 ExoPlayer —— 比"起播后再 seek"稳,
                // 不会出现"先用 0 加载一段, 再跳"的观感(也不看 seek 通道的时序)
                val startMs = (args["positionMs"] as? Number)?.toLong() ?: 0L
                // 接口给的时长(审计 U2 尾巴): Dart 已经把 song.durationMs 传进来, 不再写死 0 ——
                // 否则换曲后进度条要等下一次 500ms 轮询才有总长。缺失/非法仍按 0(未知)处理。
                val durationMs = (args["durationMs"] as? Number)?.toLong() ?: 0L
                if (startMs > 0L) c.seekTo(startMs)
                c.prepare()
                // 换曲/首次起播: **不淡入**(2026-11-23 用户口径 —— 淡入会把歌曲开头
                // 1s 盖成静音, 听感是错过开头)。标志在下一次 `play()` 里生效并清掉。
                PlaybackService.instance?.markTrackStart()
                c.play()
                // 返回值**用请求参数拼**, 不回读 MediaController(审计 U2, 2026-11-25):
                // setMediaItem/prepare/play 只是把命令发给会话, MediaController 缓存的
                // PlayerInfo 要靠 binder 回调刷新, 而本方法仍在主线程上 ⇒ stateMap(c) 读到的
                // 是**上一首**的 trackId/positionMs 且 playing=false。那份快照会被 Dart 直接
                // adoptPlayer 并立刻 force 落盘 ⇒ "新曲的现场"从旧曲位置上开始。
                result.success(
                    playResult(
                        trackId = trackId,
                        startMs = startMs,
                        durationMs = durationMs,
                        volume = c.volume,
                    ),
                )
            }
            // 立即暂停(不走淡出): MV 起播让路专用(审计 U3)。「总是在后台播放」档的 MV
            // 不申请音频焦点, 没有"系统压停歌曲"这层兜底, 走 pause 的淡出就是双声窗口。
            "pauseImmediate" -> {
                val svc = PlaybackService.instance
                if (svc != null) svc.pauseImmediately() else c.pause()
                // 命令已发出: 缓存里的 isPlaying 还是旧值, 按请求意图报"未播"(同上一条的理由)
                result.success(stateMap(c, playingOverride = false))
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

    private fun stateMap(c: MediaController, playingOverride: Boolean? = null): Map<String, Any?> {
        val duration = if (c.duration == C.TIME_UNSET) 0L else c.duration
        // 淡出挂起态必须在这层合并(审计 P1, 2026-11-23): MediaController.isPlaying 读的是
        // 会话缓存的 PlayerInfo, 淡出期间只有音量动画、无 Player 事件 ⇒ 只覆写服务的
        // SkipAwarePlayer.isPlaying 不会传导到这里, Dart 轮询仍拿到「还在播」(F6 症状)。
        //
        // [playingOverride]: 刚发出播放/暂停命令时缓存还是旧值, 用**请求意图**报
        // (与 [playResult] 同一个理由, 见那里的注释)。
        val playing = playingOverride
            ?: (c.isPlaying && PlaybackService.instance?.isFadeOutPending != true)
        return mapOf(
            "trackId" to c.currentMediaItem?.mediaId?.toLongOrNull(),
            "playing" to playing,
            "positionMs" to c.currentPosition,
            "durationMs" to duration,
            "volume" to c.volume.toDouble(),
        )
    }

    /**
     * `ncm/player#play` 的返回值: 全部用**请求参数**拼(审计 U2)。
     *
     * 为什么不能直接用 [stateMap]: 命令发出后 MediaController 的 PlayerInfo 仍是旧值
     * (binder 回调要等本方法返回、主线程回到 looper 之后才会到), 读到的是上一首的
     * trackId/positionMs 且 playing=false。各字段口径:
     *
     * - `trackId`: 请求值(不是 `c.currentMediaItem`);
     * - `positionMs`: 传进来的起播位置(没传即 0) —— 这条曲目真正的进度起点,
     *   Dart 的 force 落盘也用它, 不会再写成旧曲的位置;
     * - `playing`: 命令已发出, 按"在播"报(与旧行为一致, 也是用户按下的瞬间状态);
     * - `durationMs`: 请求参数里的接口时长(没有就 0 = 未知); 不再写死 0 —— 换曲后进度条
     *   立刻就有总长, 不必等下一次 500ms 轮询; 但**绝不编造**: 调用方没给就仍是 0;
     * - `volume`: 音量与曲目无关(`setVolume` 走服务, 不随 setMediaItem 变), 用缓存值即可。
     */
    private fun playResult(
        trackId: Long,
        startMs: Long,
        durationMs: Long,
        volume: Float,
    ): Map<String, Any?> =
        mapOf(
            "trackId" to trackId,
            "playing" to true,
            "positionMs" to startMs,
            "durationMs" to if (durationMs > 0L) durationMs else 0L,
            "volume" to volume.toDouble(),
        )

    private fun ensureNotificationPermission() {
        if (!hasNotificationPermission()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                101,
            )
        }
    }

    /**
     * 本应用是否能发通知(Android 13+ 要运行时权限, 更早的系统恒为 true)。
     *
     * 唯一判据在 `ncm/open#notificationPermissionGranted` 与 [ensureNotificationPermission]
     * 两处共用 —— 设置页显示的「已开启/被拒绝」与冷启动那次申请必须同一口径。
     */
    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * 打开本应用的**通知**设置页(Android 8.0+ 有专属页, 更早的系统落到应用详情页)。
     *
     * 用 ACTION_APP_NOTIFICATION_SETTINGS + EXTRA_APP_PACKAGE 而不是跳到应用详情:
     * 用户拒过权限时, 详情页要点两层才到通知开关, 而通知栏没播放控制的直接修复入口就是
     * 那个通知总开关。
     */
    private fun notificationSettingsIntent(): Intent =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            )
        }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_AUDIO) {
            val result = pendingPick
            pendingPick = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                result?.success(null)
                return
            }
            try {
                // 复制到 cacheDir/cloud_upload/: Rust 侧按路径读文件做 md5 + 上传
                val name = queryDisplayName(uri) ?: "upload.mp3"
                val dir = File(cacheDir, "cloud_upload").apply { mkdirs() }
                val out = File(dir, name)
                contentResolver.openInputStream(uri)?.use { input ->
                    out.outputStream().use { output -> input.copyTo(output) }
                } ?: throw IllegalStateException("openInputStream 返回 null")
                result?.success(out.absolutePath)
            } catch (e: Exception) {
                result?.error("pick_failed", e.message, null)
            }
            return
        }
        if (requestCode == LoginActivity.REQUEST_CODE) {
            // 只有 RESULT_OK(真的拿到 MUSIC_U)才回传 cookie; 取消 = null(放弃登录)
            val cookie = if (resultCode == RESULT_OK) {
                data?.getStringExtra(LoginActivity.EXTRA_COOKIE)
            } else {
                null
            }
            pendingLogin?.success(if (cookie.isNullOrBlank()) null else cookie)
            pendingLogin = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /** content:// 的显示名(用于上传文件名/歌名); 取不到就给 null 让调用方兜底 */
    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // 必须在 super.onCreate 之前取: 冷启动时 Intent 里的动作要在 Dart 起来之前先接住
        capturePlaybackAction(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        capturePlaybackAction(intent)
        deliverPendingPlaybackAction()
    }

    /** 取出并抹掉 Intent 里的通知按钮动作(同一次启动只消费一次) */
    private fun capturePlaybackAction(intent: Intent?) {
        val action = intent?.getStringExtra(PlaybackService.EXTRA_PLAYBACK_ACTION) ?: return
        intent.removeExtra(PlaybackService.EXTRA_PLAYBACK_ACTION)
        pendingPlaybackAction = action to System.currentTimeMillis()
    }

    /**
     * 把排队中的通知按钮动作交给 Dart(与 PlaybackService.actionListener 的映射保持一致)。
     * Dart 未就绪就继续等(下一次握手/onNewIntent 还会再调), 过期的直接丢弃并记日志。
     */
    private fun deliverPendingPlaybackAction() {
        val pending = pendingPlaybackAction ?: return
        if (!dartActionReady) return
        pendingPlaybackAction = null
        val (action, at) = pending
        val ageMs = System.currentTimeMillis() - at
        if (ageMs > PLAYBACK_ACTION_TTL_MS) {
            android.util.Log.w(TAG, "丢弃过期的通知按钮意图 " + action + " (" + ageMs + "ms)")
            return
        }
        dispatchPlaybackAction(action, ageMs)
    }

    /** 动作名 -> Dart 方法名的唯一映射(与 PlaybackService.actionListener 的口径保持一致) */
    private fun dispatchPlaybackAction(action: String, ageMs: Long) {
        val method = when (action) {
            PlaybackService.CMD_LIKE -> "toggleLike"
            PlaybackService.CMD_MODE -> "cycleMode"
            PlaybackService.CMD_PREV -> "skipPrevious"
            PlaybackService.CMD_NEXT -> "skipNext"
            else -> null
        }
        if (method == null) {
            android.util.Log.w(TAG, "未知的通知按钮意图: " + action)
            return
        }
        android.util.Log.i(TAG, "执行通知按钮意图 " + action + " -> Dart " + method + " (排队 " + ageMs + "ms)")
        playerChannel?.invokeMethod(method, null)
    }

    override fun onDestroy() {
        PlaybackService.skipListener = null
        PlaybackService.actionListener = null
        PlaybackService.actionStateSyncListener = null
        playerChannel = null
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controller = null
        super.onDestroy()
    }
}
