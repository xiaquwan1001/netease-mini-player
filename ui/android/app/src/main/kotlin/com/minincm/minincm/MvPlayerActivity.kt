package com.minincm.minincm

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.Toast
import android.widget.VideoView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

/**
 * MV 播放页(C3): 独立 VideoView 播放, 刻意不进 PlaybackService/Media3 队列 ——
 * MV 是一次性直链播放(1 小时签名过期), 和歌曲队列/通知栏互不相干。
 *
 * 生命周期(P-07): onPause 暂停并把播放位置记下来(按 Home/锁屏后 MV 声音必须停,
 * 否则会和后台歌曲播放叠加), onResume 回到原位置继续; 真正结束(isFinishing)才 stopPlayback()。
 * 直链 403(签名过期)或解析失败时给出可读 toast, 返回键直接回 Flutter 页面。
 *
 * 音频焦点(U-04, 2026-11-18): MV 是第二个音源, 以前完全不参与系统焦点仲裁 ⇒ 和歌曲同时出声。
 * 现在 onStart 申请 AUDIOFOCUS_GAIN、onStop/onDestroy 放弃, 失去焦点就暂停
 * (决策见纯逻辑 [MvAudioFocusPolicy]); 歌曲侧 ExoPlayer 同时打开了 handleAudioFocus
 * (见 [PlaybackService.buildExoPlayer]), 谁最后起播谁出声, 不会两路叠放。
 * Dart 侧还会在起播前主动暂停歌曲(ui/lib/src/mv_playback.dart), 那是"让体验顺滑"的一层,
 * 焦点这一层是"无论 Dart 漏了都不叠音"的兜底。
 */
class MvPlayerActivity : Activity() {
    private lateinit var video: VideoView

    /** 是否因生命周期(onPause)而暂停; 只有这种情况 onResume 才自动续播 */
    private var pausedByLifecycle = false

    /** 是否因**音频焦点**被别人抢走而暂停; 只有拿到 AUDIOFOCUS_GAIN 才恢复(U-04) */
    private var pausedByFocus = false

    /** 是否正持有音频焦点(onStart 申请/onStop 放弃, 幂等) */
    private var holdingFocus = false

    /** 窗口是否在前台(onResume 起为 true, onPause 起为 false): 焦点恢复只在可见时真出声 */
    private var inForeground = false

    /** API 26+ 的焦点请求句柄(放弃时要传同一个对象; 24/25 走旧接口, 这里保持 null) */
    private var focusRequest: AudioFocusRequest? = null

    /**
     * 焦点变化 → 动作。决策在 [MvAudioFocusPolicy](纯逻辑, 有 JVM 单测), 这里只做副作用:
     * 暂停/恢复 VideoView, 并记住"这次停是不是焦点造成的"。
     */
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        // 用户设置「总是在后台播放」时 MV 也不自动续播(与歌曲侧同一口径, 见 [AudioFocusPolicy])。
        val action = MvAudioFocusPolicy.actionFor(change, pausedByFocus)
        if (
            action == MvAudioFocusPolicy.Action.RESUME &&
            !AudioFocusPolicy.mvResumesOnGain(PlaybackService.configuredAudioFocusMode)
        ) {
            return@OnAudioFocusChangeListener
        }
        when (action) {
            MvAudioFocusPolicy.Action.PAUSE -> {
                // 只有"真的在播"才记成焦点暂停(审计 U4, 2026-11-25): 用户自己按的暂停
                // 不该被 GAIN 偷偷播起来([MvAudioFocusPolicy] KDoc 的承诺)。
                if (::video.isInitialized && video.isPlaying) {
                    pausedByFocus = true
                    video.pause()
                }
            }

            MvAudioFocusPolicy.Action.RESUME -> {
                pausedByFocus = false
                // 只在窗口可见时真恢复: 后台里被"焦点回来"起播就变成本次要修的那个问题了
                if (::video.isInitialized && inForeground) video.start()
            }

            MvAudioFocusPolicy.Action.NONE -> Unit
        }
    }

    /** onPause 时的播放位置, onResume 用它续播(不重头) */
    private var resumePositionMs = 0

    /**
     * 待落位的播放位置(毫秒), -1 表示无需 seek。
     *
     * 窗口重新可见时 VideoView 会重建 MediaPlayer 并重新 prepare(surfaceCreated -> openVideo),
     * 在 onResume 里对还没 prepare 的播放器 seekTo 会被那次 prepare 冲掉, 所以要等 onPrepared。
     */
    private var pendingSeekMs = -1

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        volumeControlStream = AudioManager.STREAM_MUSIC

        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "MV"
        if (url.isBlank()) {
            Toast.makeText(this, "MV 链接为空", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        setTitle(title)
        // P-09: 黑边底色从资源取(values/values-night 都是纯黑); 主题 MvTheme 负责
        // 状态栏/导航栏底色与图标亮度, 随系统深浅色切换, 不再固定写死一套。
        video = VideoView(this)
        video.setBackgroundColor(ContextCompat.getColor(this, R.color.player_background))
        // Android 15+(targetSdk 36)起系统**强制** edge-to-edge: statusBarColor /
        // navigationBarColor 已失效, 视频与控制条会铺到状态栏/手势条底下。显式关掉
        // 「系统替我们留边」, 下面自己按 insets 留白。
        // 容器只是为了能有 padding: VideoView 是 SurfaceView, 给它自己设 padding 不会
        // 移动画面, 所以由外层 FrameLayout 吃 insets(黑底也在容器上)。
        val container = FrameLayout(this).apply {
            setBackgroundColor(ContextCompat.getColor(this@MvPlayerActivity, R.color.player_background))
        }
        container.addView(video, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContentView(container)
        // 这块区域永远是纯黑底 → 状态栏/手势条图标一律用浅色(MvTheme 只覆盖了启动瞬间的
        // 状态栏图标, 手势条图标一直没人管)。
        WindowCompat.getInsetsController(window, container).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }
        // 只吃 left/right/bottom: 顶部让视频居中在黑底上(顶部黑边已足够, 再吃一遍 top
        // 会让画面整体下移); 底部手势条/横屏挖孔 + 输入法都要让开(控制条在底部)。
        ViewCompat.setOnApplyWindowInsetsListener(container) { _, windowInsets ->
            val bars = windowInsets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime(),
            )
            container.setPadding(bars.left, 0, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
        ViewCompat.requestApplyInsets(container)

        // 竖屏按 16:9 容器居中, 横屏铺满(简单处理: 只做居中适配)
        video.setOnPreparedListener { mp ->
            // MediaPlayer 被重建过(见 pendingSeekMs 注释): 在这里落回暂停位置再起播。
            // 用 mp.seekTo 而不是 video.seekTo —— VideoView.seekTo 要求 isInPlaybackState(),
            // 此刻 videoWidth/Height 可能还没通过 onVideoSizeChanged 回填, 会被降级成
            // "记下位置等 prepare", 结果就是从 0 重播。
            val seek = pendingSeekMs
            if (seek >= 0) {
                pendingSeekMs = -1
                mp.seekTo(seek)
                video.start()
            }
            val vw = mp.videoWidth
            val vh = mp.videoHeight
            if (vw > 0 && vh > 0) {
                val parent = video.parent as ViewGroup
                parent.post {
                    // 可用区要减掉容器吃进去的 insets(见容器上的 insets 监听):
                    // 用整块宽高算会把画面顶进手势条/挖孔那一条。
                    val pw = parent.width - parent.paddingLeft - parent.paddingRight
                    val ph = parent.height - parent.paddingTop - parent.paddingBottom
                    if (pw <= 0 || ph <= 0) return@post
                    val scale = minOf(pw.toFloat() / vw, ph.toFloat() / vh)
                    val lp = video.layoutParams
                    lp.width = (vw * scale).toInt()
                    lp.height = (vh * scale).toInt()
                    video.layoutParams = lp
                }
            }
        }
        video.setOnErrorListener { _, what, extra ->
            Toast.makeText(
                this,
                "MV 播放失败(what=$what extra=$extra)。直链约 1 小时过期, 请返回后重试",
                Toast.LENGTH_LONG,
            ).show()
            true
        }
        video.setMediaController(MediaController(this))
        video.setVideoPath(url)
        video.start()
    }

    /**
     * 申请音频焦点: API 26+ 用 [AudioFocusRequest], minSdk 24 的两档走旧接口。
     * 类型 MOVIE/MEDIA + `setWillPauseWhenDucked(true)`: 别人要 ducking 时我们不压低音量硬放,
     * 而是直接暂停(视频有对白, 压着听不清)。
     */
    private fun requestAudioFocus(): Boolean {
        // 「总是在后台播放」: MV 也不抢焦点(否则一进 MV 就把正在播的音乐/导航打断)
        if (!AudioFocusPolicy.mvRequestsFocus(PlaybackService.configuredAudioFocusMode)) {
            return false
        }
        val am = getSystemService(AudioManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    /** 放弃焦点(幂等)。放弃后清掉 pausedByFocus: 重新申请时系统回的那个 GAIN 不该自动起播 */
    private fun abandonAudioFocus() {
        val am = getSystemService(AudioManager::class.java)
        if (am != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusListener)
            }
        }
        focusRequest = null
        holdingFocus = false
        pausedByFocus = false
    }

    override fun onStart() {
        super.onStart()
        // 每次回前台都要重新持焦点(onStop 已放弃); 跨窗口重建/旋转也走这里
        if (!holdingFocus) holdingFocus = requestAudioFocus()
    }

    override fun onStop() {
        // 离开 MV(返回 Flutter / 按 Home)就不再占用音频焦点, 让别的 App 正常拿焦点
        abandonAudioFocus()
        super.onStop()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 系统控件即可, 方向变化交给 VideoView 重新布局; 不锁定方向
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    override fun onPause() {
        inForeground = false
        super.onPause()
        if (!::video.isInitialized) return
        // VideoView 不会随 Activity 暂停自动停: 这里显式 pause, 并记住位置供 onResume 续播
        if (isFinishing) {
            video.stopPlayback()
        } else {
            resumePositionMs = video.currentPosition
            pausedByLifecycle = true
            video.pause()
        }
    }

    override fun onResume() {
        inForeground = true
        super.onResume()
        if (!::video.isInitialized) return
        if (!pausedByLifecycle) return
        pausedByLifecycle = false
        if (pausedByFocus) {
            // 上次是被别的音源抢走焦点才停的(暂停位置仍在播放器里, 不需要 seek):
            // 回到前台就把焦点要回来 —— 拿到时系统会回调 GAIN, 由 focusListener 续播;
            // 要不到(别的音源仍在放)就保持静音, 用户可用控制器上的播放键。
            holdingFocus = requestAudioFocus()
            return
        }
        if (video.duration > 0) {
            // 播放器还在(窗口没被重建): 直接落位置续播, 不必等 onPrepared
            video.seekTo(resumePositionMs)
            video.start()
        } else {
            // MediaPlayer 已被重建且还没 prepare 好: 交给 onPrepared 落位置
            pendingSeekMs = resumePositionMs
        }
    }

    override fun onDestroy() {
        abandonAudioFocus()
        if (::video.isInitialized) video.stopPlayback()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_URL = "mv_url"
        const val EXTRA_TITLE = "mv_title"
    }
}
