package com.minincm.minincm

import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * 媒体会话服务: 拥有 ExoPlayer 与 MediaSession.
 * 通知/锁屏/蓝牙/车机控制都走 Media3 默认通道, 不自己画通知.
 *
 * 两个必须项(网易云直链特性):
 * 1) 直链是 plain-http 的 *.music.126.net, 需要 manifest 允许 cleartext
 * 2) CDN 对 UA/Referer 敏感, 用官方桌面端 UA + music.163.com referer
 */
class PlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()

        val dataSource = DefaultHttpDataSource.Factory()
            .setUserAgent(USER_AGENT)
            .setDefaultRequestProperties(mapOf("Referer" to "https://music.163.com/"))
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)
            .setAllowCrossProtocolRedirects(true)

        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .build()

        mediaSession = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onTaskRemoved(rootIntent: android.content.Intent?) {
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        super.onDestroy()
    }

    companion object {
        /**
         * CDN 的 UA 也要与客户端形态一致: 安卓 App 用官方安卓客户端 UA
         * (与 ncm-service 的 ANDROID_PROFILE.ua 同一串), 不要拿 PC 桌面 UA 冒充。
         * ExoPlayer 默认 UA(NeteaseLib/ExoPlayerLib) 会被 CDN 拒。
         */
        const val USER_AGENT =
            "NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0 (Linux; U; Android 14; " +
                "23013RK75C Build/UKQ1.230804.001)"
    }
}
