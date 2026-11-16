package com.minincm.minincm

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.AudioManager
import android.os.Bundle
import android.view.WindowManager
import android.widget.MediaController
import android.widget.Toast
import android.widget.VideoView
import androidx.core.content.ContextCompat

/**
 * MV 播放页(C3): 独立 VideoView 播放, 刻意不进 PlaybackService/Media3 队列 ——
 * MV 是一次性直链播放(1 小时签名过期), 和歌曲队列/通知栏互不相干。
 *
 * 生命周期(P-07): onPause 暂停并把播放位置记下来(按 Home/锁屏后 MV 声音必须停,
 * 否则会和后台歌曲播放叠加), onResume 回到原位置继续; 真正结束(isFinishing)才 stopPlayback()。
 * 直链 403(签名过期)或解析失败时给出可读 toast, 返回键直接回 Flutter 页面。
 */
class MvPlayerActivity : Activity() {
    private lateinit var video: VideoView

    /** 是否因生命周期(onPause)而暂停; 只有这种情况 onResume 才自动续播 */
    private var pausedByLifecycle = false

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
        setContentView(video)

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
                val parent = video.parent as android.view.ViewGroup
                parent.post {
                    val pw = parent.width
                    val ph = parent.height
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

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 系统控件即可, 方向变化交给 VideoView 重新布局; 不锁定方向
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    override fun onPause() {
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
        super.onResume()
        if (!::video.isInitialized) return
        if (!pausedByLifecycle) return
        pausedByLifecycle = false
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
        if (::video.isInitialized) video.stopPlayback()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_URL = "mv_url"
        const val EXTRA_TITLE = "mv_title"
    }
}
