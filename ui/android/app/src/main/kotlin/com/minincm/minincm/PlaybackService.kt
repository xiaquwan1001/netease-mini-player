package com.minincm.minincm

import androidx.annotation.OptIn
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
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
 *
 * 队列纪律: 播放队列只在 Dart 一处(PlayQueue), 原生播放器永远只有一个 MediaItem.
 * 因此 Media3 默认认为 hasNext/hasPrevious=false, 通知栏/耳机键不会出现上一首·下一首.
 * 这里用 ForwardingPlayer 声明"有上下曲", 并把跳转请求回调给 Dart 队列执行,
 * 业务逻辑仍只有一份.
 */
class PlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null
    private var exoPlayer: ExoPlayer? = null

    @OptIn(UnstableApi::class)
    override fun onCreate() {
        super.onCreate()

        val dataSource = DefaultHttpDataSource.Factory()
            .setUserAgent(USER_AGENT)
            .setDefaultRequestProperties(mapOf("Referer" to "https://music.163.com/"))
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)
            .setAllowCrossProtocolRedirects(true)

        val exo = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .build()
        exoPlayer = exo

        mediaSession = MediaSession.Builder(this, SkipAwarePlayer(exo)).build()
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
        exoPlayer = null
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

        /**
         * 上一首/下一首的出口: true=下一首, false=上一首.
         * MainActivity 在建立 MethodChannel 后注入(同进程), 由它转发给 Dart 队列.
         */
        @Volatile
        var skipListener: ((Boolean) -> Unit)? = null

        fun requestSkip(next: Boolean) {
            skipListener?.invoke(next)
        }
    }
}

/**
 * 声明式"有上下曲"的门面: 队列在 Dart, 原生侧只有当前一首,
 * 所以 hasNext/hasPrevious 由我们恒定为真(单曲也允许手动跳),
 * 实际换曲交给 Dart 队列, 避免两端各存一份队列.
 */
@OptIn(UnstableApi::class)
private class SkipAwarePlayer(private val delegate: Player) : ForwardingPlayer(delegate) {
    override fun hasNextMediaItem(): Boolean = true

    override fun hasPreviousMediaItem(): Boolean = true

    override fun getAvailableCommands(): Player.Commands {
        val builder = Player.Commands.Builder().addAll(super.getAvailableCommands())
        if (delegate.mediaItemCount > 0) {
            builder.add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            builder.add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
            builder.add(Player.COMMAND_SEEK_TO_NEXT)
            builder.add(Player.COMMAND_SEEK_TO_PREVIOUS)
        }
        return builder.build()
    }

    override fun seekToNextMediaItem() = PlaybackService.requestSkip(true)

    override fun seekToPreviousMediaItem() = PlaybackService.requestSkip(false)

    override fun seekToNext() = PlaybackService.requestSkip(true)

    override fun seekToPrevious() = PlaybackService.requestSkip(false)
}
