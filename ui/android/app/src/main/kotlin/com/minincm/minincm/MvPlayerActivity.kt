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

/**
 * MV 播放页(C3): 独立 VideoView 播放, 刻意不进 PlaybackService/Media3 队列 ——
 * MV 是一次性直链播放(1 小时签名过期), 和歌曲队列/通知栏互不相干。
 *
 * 生命周期: onDestroy/onPause 停止播放并释放, 不留后台解码器。
 * 直链 403(签名过期)或解析失败时给出可读 toast, 返回键直接回 Flutter 页面。
 */
class MvPlayerActivity : Activity() {
    private lateinit var video: VideoView

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
        video = VideoView(this)
        setContentView(video)

        // 竖屏按 16:9 容器居中, 横屏铺满(简单处理: 只做居中适配)
        video.setOnPreparedListener { mp ->
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
        if (isFinishing) video.stopPlayback()
    }

    override fun onDestroy() {
        video.stopPlayback()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_URL = "mv_url"
        const val EXTRA_TITLE = "mv_title"
    }
}
