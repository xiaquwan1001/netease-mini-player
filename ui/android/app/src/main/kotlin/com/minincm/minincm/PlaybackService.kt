package com.minincm.minincm

import android.animation.ValueAnimator
import android.content.Context
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import java.io.File
import kotlin.math.pow

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
 *
 * S3 新增: 精细音量(增益×系统音量)、淡入、硬解开关、边听边存(SimpleCache)+LRU 上限、
 * 自定义曲线 EQ(AudioProcessor)。配置入口是 MainActivity 的 ncm/player#configure 通道,
 * 直接经 [configure] 落到本服务; [userVolume]/[gainDb]/[fadeMs] 是音量三要素, 都归这里管,
 * 避免 MainActivity 与 Service 各存一份音量状态。
 */
class PlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null
    private var exoPlayer: ExoPlayer? = null
    private var simpleCache: SimpleCache? = null

    // 用户通过 ncm/player#volume 设的"系统音量档"(0..1), 与精细增益相乘后才是 player.volume
    private var userVolume = 1.0f

    // Dart 已把「精细音量 + 响度增益」合成为 gainDb(-40..+12), 这里如实乘上, 不自己测响度
    private var gainDb = 0.0
    // 增益斜坡的限速(dB/s): 0 = 瞬时(默认, 静态 RG2.0); >0 时按该速率从当前增益逼近目标(动态 AGC 防 pump)
    private var gainSlewDbPerSec = 0.0
    // 当前**实际施加**的增益(dB): 斜坡期间与 gainDb(目标)不同, 结束后相等
    private var appliedGainDb = 0.0
    private var fadeMs = 0
    private var hardwareDecode = true
    private var streamCache = true
    private var cacheLimitMb = 512
    private var eqText: String? = null
    private var eqProcessor: EqAudioProcessor? = null

    private var fadeAnimator: ValueAnimator? = null
    private var gainSlewAnimator: ValueAnimator? = null

    @OptIn(UnstableApi::class)
    override fun onCreate() {
        super.onCreate()
        instance = this
        val exo = buildExoPlayer()
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
        instance = null
        fadeAnimator?.cancel()
        fadeAnimator = null
        gainSlewAnimator?.cancel()
        gainSlewAnimator = null
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        exoPlayer = null
        releaseCache()
        super.onDestroy()
    }

    /**
     * S3 通道 configure 的落地: 应用调音参数并回显生效值, 便于 Dart 断言.
     * 全部在应用主线程执行(MethodChannel 回调线程)。
     */

/**
     * 返回某条直链在 SimpleCache 里可用的音频文件路径, 给响度测量(R2b)用。
     *
     * - 优先返回**完整**缓存 span(整首已存完);
     * - 否则返回"从 0 开始且已存够 [minPrefixBytes]"的前缀 span —— ExoPlayer 正常播放时只缓冲
     *   前方几十秒, 等整首存完要等到播完, 那之前先按前缀测(前缀响度足以代表整首);
     * - 都没有就返回 null(下一次补测再试)。
     */
    fun cachedFileFor(url: String, minPrefixBytes: Long = 256L * 1024): String? {
        val cache = simpleCache ?: return null
        return try {
            val spans = cache.getCachedSpans(url)
            val complete = spans.firstOrNull { it.isCached && it.length > 0 }
            val prefix = spans.firstOrNull { it.position == 0L && it.length >= minPrefixBytes }
            (complete ?: prefix)?.file?.absolutePath
        } catch (e: Exception) {
            Log.w("NCM-PLAYER", "cachedFileFor failed: $e")
            null
        }
    }

    fun configure(args: Map<*, *>): Map<String, Any?> {
        val newGainDb = (args["gainDb"] as? Number)?.toDouble() ?: gainDb
        val newGainSlewDbPerSec = (args["gainSlewDbPerSec"] as? Number)?.toDouble() ?: gainSlewDbPerSec
        val newFadeMs = (args["fadeMs"] as? Number)?.toInt() ?: fadeMs
        val newHardwareDecode = args["hardwareDecode"] as? Boolean ?: hardwareDecode
        val newStreamCache = args["streamCache"] as? Boolean ?: streamCache
        val newCacheLimitMb = (args["cacheLimitMb"] as? Number)?.toInt() ?: cacheLimitMb
        val rawEqText = args["eqText"] as? String
        val newEqText = if (rawEqText.isNullOrBlank()) null else rawEqText

        val clampedGain = newGainDb.coerceIn(-40.0, 12.0)
        val clampedFade = newFadeMs.coerceIn(0, 5000)
        val clampedLimit = newCacheLimitMb.coerceIn(1, 65536)
        // 限速只接受正的有限值, 其余(0/负/NaN)一律按瞬时处理(与 Dart 侧 0 = 瞬时口径一致)
        val clampedGainSlew = if (newGainSlewDbPerSec.isFinite() && newGainSlewDbPerSec > 0.0) {
            newGainSlewDbPerSec
        } else {
            0.0
        }

        // EQ 解析: 失败则旁路(不生效), 记 logcat NCM-EQ 前缀 + 行号/原因, 并在回显里带上 eqError
        var eqOk = true
        var eqError: String? = null
        var eqFilterCount = 0
        var newEqProcessor: EqAudioProcessor? = null
        if (newEqText != null) {
            try {
                val profile = parseParametricEq(newEqText)
                if (profile.hasEffect) {
                    newEqProcessor = EqAudioProcessor(profile)
                    eqFilterCount = profile.activeFilters().size
                }
            } catch (e: EqParseException) {
                eqOk = false
                eqError = "第 ${e.line} 行: ${e.reason}"
                Log.w("NCM-EQ", "第 ${e.line} 行: ${e.reason}")
            } catch (e: Exception) {
                eqOk = false
                eqError = "EQ 解析失败: ${e.message}"
                Log.w("NCM-EQ", "EQ 解析失败", e)
            }
        }

        // 一行可观测日志: 便于 adb logcat 核对「设置真的落到播放器上」(编排者/回归都用它)
        Log.d(
            "NCM-PLAYER",
            "configure gain=$clampedGain fade=$clampedFade slew=$clampedGainSlew hw=$newHardwareDecode " +
                "cache=$newStreamCache limit=${clampedLimit}MB eqFilters=$eqFilterCount eqError=$eqError",
        )

        // media3 1.9 没有运行期 setAudioProcessors, EQ 变化也要重建 player(见 rebuildPlayer 注释)
        val rebuildNeeded = newHardwareDecode != hardwareDecode ||
            newStreamCache != streamCache ||
            clampedLimit != cacheLimitMb ||
            newEqText != eqText

        if (rebuildNeeded && (newStreamCache != streamCache || clampedLimit != cacheLimitMb)) {
            // 缓存上限变化要换 evictor; 开关变化要整体重建 —— 都先丢旧缓存库
            releaseCache()
        }

        // 先更新字段再重建: buildExoPlayer()/buildDataSourceFactory() 读的就是这些字段
        gainDb = clampedGain
        gainSlewDbPerSec = clampedGainSlew
        fadeMs = clampedFade
        hardwareDecode = newHardwareDecode
        streamCache = newStreamCache
        cacheLimitMb = clampedLimit
        eqText = newEqText
        eqProcessor = newEqProcessor

        if (rebuildNeeded) rebuildPlayer()

        // 增益变化: 动态模式(限速>0)按 dB/s 斜坡逼近, 静态模式瞬时(默认, 行为不变)
        applyGainChange()

        return mapOf(
            "gainDb" to gainDb,
            "gainSlewDbPerSec" to gainSlewDbPerSec,
            "fadeMs" to fadeMs,
            "hardwareDecode" to hardwareDecode,
            "streamCache" to streamCache,
            "cacheLimitMb" to cacheLimitMb,
            "eqApplied" to eqOk,
            "eqError" to eqError,
            "eqFilters" to eqFilterCount,
        )
    }

    /** ncm/player#volume: 只更新用户音量档, 立即生效(取消正在进行的淡入, 但不打断增益斜坡) */
    fun setUserVolume(v: Float) {
        userVolume = v.coerceIn(0f, 1f)
        // 系统音量必须立刻响应: 只取消淡入(淡入目标里含旧 userVolume);
        // 增益斜坡(若有)继续跑, 它的每帧回调会读最新的 userVolume, 这里先同步一次当前值。
        fadeAnimator?.cancel()
        fadeAnimator = null
        exoPlayer?.volume = appliedVolume()
    }

    /** 换曲/开始: 在 fadeMs 内把音量从 0 线性升到目标值, 避免切歌爆音(0 = 关闭) */
    fun fadeIn() {
        val exo = exoPlayer ?: return
        fadeAnimator?.cancel()
        // 淡入与增益斜坡互斥(last-wins): 淡入开始即取消斜坡, 并把 appliedGainDb 对齐到当前目标增益,
        // 这样淡入结束后音量就是目标值, 下一次 configure 的斜坡也从正确基线出发(不带半截斜坡残留)。
        gainSlewAnimator?.cancel()
        gainSlewAnimator = null
        appliedGainDb = gainDb
        val target = targetVolume()
        if (fadeMs <= 0) {
            exo.volume = target
            return
        }
        val animator = ValueAnimator.ofFloat(0f, target)
        animator.duration = fadeMs.toLong()
        animator.addUpdateListener { a ->
            exo.volume = (a.animatedValue as Float).coerceIn(0f, 1f)
        }
        fadeAnimator = animator
        animator.start()
    }

    private fun targetVolume(): Float {
        // 精细音量 = 系统音量档 × 10^(gainDb/20), 钳到 0..1:
        // 正增益在系统音量满时自然封顶, 不引入额外削波(削波只发生在 EQ 样本级)
        val linear = 10.0.pow(gainDb / 20.0).toFloat()
        return (userVolume * linear).coerceIn(0f, 1f)
    }

    /** 当前实际音量 = 系统音量档 × 10^(appliedGainDb/20): 斜坡期间 appliedGainDb 还没到 gainDb */
    private fun appliedVolume(): Float {
        val linear = 10.0.pow(appliedGainDb / 20.0).toFloat()
        return (userVolume * linear).coerceIn(0f, 1f)
    }

    /** 把目标增益 [gainDb] 作用到音量: 限速>0 时按 dB/s 斜坡逼近, 否则瞬时(静态 RG2.0 行为不变) */
    private fun applyGainChange() {
        // 增益变化与淡入互斥: 这里(重新)接管 volume, 先取消淡入(last-wins)
        fadeAnimator?.cancel()
        fadeAnimator = null
        gainSlewAnimator?.cancel()
        gainSlewAnimator = null
        val delta = gainDb - appliedGainDb
        if (gainSlewDbPerSec > 0.0 && kotlin.math.abs(delta) > 1e-4) {
            // 按 dB/s 限速: 时长 = |ΔdB| / slew。斜坡在 dB 域线性推进, 与 Rust GainLimiter(3 dB/s)口径一致,
            // 保证"每秒最多变 slew dB"严格成立(在 volume 线性域直接差值会把 dB 变成非均匀速率)。
            val durationMs = (kotlin.math.abs(delta) / gainSlewDbPerSec * 1000.0).toLong().coerceAtLeast(1L)
            val animator = ValueAnimator.ofFloat(appliedGainDb.toFloat(), gainDb.toFloat())
            animator.duration = durationMs
            animator.addUpdateListener { a ->
                appliedGainDb = (a.animatedValue as Float).toDouble()
                exoPlayer?.volume = appliedVolume()
            }
            gainSlewAnimator = animator
            animator.start()
        } else {
            appliedGainDb = gainDb
            exoPlayer?.volume = appliedVolume()
        }
    }

    private fun buildExoPlayer(): ExoPlayer {
        val dataSourceFactory = buildDataSourceFactory()
        val processors: Array<AudioProcessor> = eqProcessor?.let { arrayOf(it) } ?: emptyArray()
        val renderersFactory = NcmRenderersFactory(forceSoftware = !hardwareDecode, processors = processors)
        return ExoPlayer.Builder(this)
            .setRenderersFactory(renderersFactory)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .build()
    }

    private fun buildDataSourceFactory(): DataSource.Factory {
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(USER_AGENT)
            .setDefaultRequestProperties(mapOf("Referer" to "https://music.163.com/"))
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)
            .setAllowCrossProtocolRedirects(true)
        if (!streamCache) return http
        // streamCache=true: 边听边存。不设 flags(默认 0) ⇒ 缓存未命中时回源、边读边写缓存;
        // 与 FLAG_BLOCK_ON_CACHE(强制只读缓存)语义相反, 后者会卡住直链首播。
        return CacheDataSource.Factory()
            .setCache(ensureCache())
            .setUpstreamDataSourceFactory(http)
    }

    private fun ensureCache(): SimpleCache {
        simpleCache?.let { return it }
        val dir = File(cacheDir, "audio")
        if (!dir.exists()) dir.mkdirs()
        // 缓存目录放在应用私有 cacheDir/audio, 与 Rust 的 dataDir/audio 不共享:
        // Rust AudioCache 是"播完才落盘的完整文件缓存", Media3 SimpleCache 是"边播边写的分片缓存",
        // 二者同目录会互相把对方当垃圾淘汰/双写同一批文件, 所以刻意隔离。
        val cache = SimpleCache(
            dir,
            LeastRecentlyUsedCacheEvictor(cacheLimitMb.toLong() * 1024L * 1024L),
            StandaloneDatabaseProvider(this),
        )
        simpleCache = cache
        return cache
    }

    private fun releaseCache() {
        simpleCache?.release()
        simpleCache = null
    }

    /**
     * 重建 ExoPlayer(硬解开关 / 缓存开关 / 缓存上限 / EQ 变化时)。
     * 为什么必须重建: MediaCodecSelector 与 CacheDataSource 都只在 ExoPlayer 创建时生效;
     * media3 1.9 也没有运行期 setAudioProcessors, EQ 要换 processor 链也只能重建。
     * 代价: 当前曲目会短暂中断一下(几十毫秒); 这里保留播放项/位置, 属于可接受范围。
     */
    private fun rebuildPlayer() {
        val old = exoPlayer ?: return
        val item = old.currentMediaItem
        val position = old.currentPosition
        val playWhenReady = old.playWhenReady

        val newExo = buildExoPlayer()
        exoPlayer = newExo

        if (item != null) {
            newExo.setMediaItem(item)
            newExo.prepare()
            newExo.seekTo(position)
            newExo.playWhenReady = playWhenReady
        }

        // 同一个 MediaSession 换底层 player: media3 会通知已连接的 MediaController 更新,
        // MainActivity 的 controller 无需重连。
        mediaSession?.setPlayer(SkipAwarePlayer(newExo))

        old.release()
        // 新 player 的音量按当前实际增益补上(重建不改增益, appliedGainDb 保持不变);
        // 取消可能存在的淡入/斜坡 —— 它们的回调引用的旧 player 已被 release。
        fadeAnimator?.cancel()
        fadeAnimator = null
        gainSlewAnimator?.cancel()
        gainSlewAnimator = null
        exoPlayer?.volume = appliedVolume()
    }

    /**
     * 渲染器工厂: 承载硬解开关(MediaCodecSelector)与 EQ(AudioProcessor 注入 AudioSink)。
     * EQ 注入只能走 buildAudioSink 覆写, 因为 media3 1.9 的 ExoPlayer 没有 setAudioProcessors。
     */
    private inner class NcmRenderersFactory(
        private val forceSoftware: Boolean,
        private val processors: Array<AudioProcessor>,
    ) : DefaultRenderersFactory(this@PlaybackService) {
        init {
            if (forceSoftware) {
                // 强制软解: 过滤掉硬件加速的 codec。
                // 为什么不是 emptyList(): MediaCodecAudioRenderer 拿不到任何解码器会直接无声/失败,
                // 而"强制软解"的语义是"只用软解 codec 且仍可播", 所以过滤 hardwareAccelerated=false。
                setMediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
                    MediaCodecSelector.DEFAULT
                        .getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
                        .filter { !it.hardwareAccelerated }
                }
            }
        }

        override fun buildAudioSink(
            context: Context,
            enableFloatOutput: Boolean,
            enableAudioOutputPlaybackParameters: Boolean,
        ): AudioSink {
            return DefaultAudioSink.Builder(context)
                .setAudioProcessors(processors)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParameters)
                .build()
        }
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

        /** 同进程引用, 让 MainActivity 的 MethodChannel 直接落到本服务(同进程, 无 IPC) */
        @Volatile
        var instance: PlaybackService? = null

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
