package com.minincm.minincm

import android.animation.ValueAnimator
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
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
import android.os.Bundle
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
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
        mediaSession = MediaSession.Builder(this, SkipAwarePlayer(exo))
            // 通知本体点击 = 回 App。默认(不设 sessionActivity)Media3 不生成 contentIntent,
            // 模拟器 a34 实测点通知本体毫无反应; 而没有同进程消费者时按钮只能给提示
            // 「请打开 App 操作」, 用户总得有一条路回来(P-01 的恢复半场)。
            .setSessionActivity(openAppPendingIntent())
            .setCallback(sessionCallback)
            .build()
        // 通知上的自定义按钮(喜欢/播放顺序): 只发意图, 状态由 Dart 经 setActionState 回推
        applyCustomLayout()
    }

    /** 通知本体点击用的 PendingIntent(系统发送 ⇒ 允许后台启动 Activity, 不受 BAL 限制) */
    private fun openAppPendingIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    // ---- 通知自定义按钮(喜欢 / 播放顺序): 只发意图, 队列/红心/模式状态全在 Dart ----
    // 状态字段本身在 companion(likedState/modeIcon): 服务被系统回收后重建时实例字段会回到默认值,
    // 通知图标就与实际红心/模式脱节; 同进程内用静态字段保住最近一次已知值, 跨进程由 Dart 重推兜底。

    private val sessionCallback = object : MediaSession.Callback {
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS
                .buildUpon()
                .add(SessionCommand(CMD_LIKE, Bundle.EMPTY))
                .add(SessionCommand(CMD_MODE, Bundle.EMPTY))
                .add(SessionCommand(CMD_PREV, Bundle.EMPTY))
                .add(SessionCommand(CMD_NEXT, Bundle.EMPTY))
                .build()
            // 控制器(重)连上 = Dart 就绪 或 服务刚被系统重建: 请 Dart 把红心/模式重推一次,
            // 否则通知图标会停在原生默认值(红心空/列表循环)直到用户切歌(P-02 自愈路径)。
            requestActionStateSync()
            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(commands)
                .build()
        }

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            // 上一首/下一首: 与耳机键走同一条出口(同进程, 不经过 MethodChannel 的 actionListener)
            when (customCommand.customAction) {
                CMD_PREV -> requestSkip(false)
                CMD_NEXT -> requestSkip(true)
                // 喜欢/播放顺序: 只把点击转发给 Dart, 不碰 ExoPlayer
                // (无同进程消费者时 requestAction 会拉起 App 兜底, 不再是无声失败)
                else -> requestAction(customCommand.customAction)
            }
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }
    }

    fun setActionState(liked: Boolean, icon: String) {
        likedState = liked
        modeIcon = icon
        applyCustomLayout()
    }

    /**
     * 请 Dart 把通知按钮状态(红心/模式)重推一次。
     *
     * 触发点: 控制器(重)连上(见 [sessionCallback.onConnect])、Dart 回调注册好的握手(MainActivity)。
     * 没有消费者(服务独立存活/App 进程已退)时静默跳过 —— 此时也没有"真实状态"可谈。
     */
    fun requestActionStateSync() {
        val listener = actionStateSyncListener ?: return
        try {
            listener.invoke()
        } catch (e: Exception) {
            Log.w(TAG, "actionStateSync 通知失败: $e")
        }
    }

    /**
     * 把按钮偏好(media button preferences)推给会话, 并把**生效顺序与槽位**打进 logcat(NCM-PLAYER),
     * 供 dumpsys / 回归核对(顺序契约见 [NOTIFICATION_BUTTON_ORDER])。
     */
    @OptIn(UnstableApi::class)
    private fun applyCustomLayout() {
        val buttons = buildCustomLayout()
        mediaSession?.setMediaButtonPreferences(buttons)
        val cmds = mediaSession?.player?.availableCommands
        Log.d(
            "NCM-PLAYER",
            "notification buttons = " + NOTIFICATION_BUTTON_ORDER.joinToString(" -> ") +
                " / liked=" + likedState + " mode=" + modeIcon +
                " / custom = [" +
                buttons.joinToString(", ") {
                    it.displayName.toString() + ":" + it.slots.toArray().joinToString("/")
                } +
                "] / playerSeekCommands prev=" +
                cmds?.containsAny(Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM) +
                " next=" +
                cmds?.containsAny(Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM),
        )
    }

    /**
     * 通知栏按钮**偏好**(media button preferences), 槽位写死:
     * 上一首 = SLOT_BACK, 下一首 = SLOT_FORWARD, 喜欢/取消喜欢 = overflow, 播放顺序 = overflow。
     *
     * 顺序契约写死在 [NOTIFICATION_BUTTON_ORDER]:
     * 上一首 -> 暂停/播放 -> 下一首 -> 喜欢/取消喜欢 -> 播放顺序。
     *
     * Media3 1.9.4 的 DefaultMediaNotificationProvider.getMediaButtons() 拼装规则是固定的:
     * (1) BACK 槽按钮(没有就用系统 COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
     * (2) COMMAND_PLAY_PAUSE 系统按钮 —— 永远占中间位, 图标随播放态自动翻转, 自定义按钮挤不进去
     * (3) FORWARD 槽按钮(没有就用系统 next)
     * (4) 其余 overflow 按钮按声明顺序追加
     * 所以只有"上一首/下一首显式钉 BACK/FORWARD 槽, 喜欢/播放顺序留在 overflow"才能得到目标顺序,
     * 而且 5 个按钮一定齐(不依赖 player 当时是否有 seekToNext/Previous 命令)。
     *
     * 为什么不用"系统默认 3 个 + 自定义 [喜欢, 播放顺序]"(已实测否决): 用 setCustomLayout 时 Media3 会按
     * hasDefaultBackCommand / hasDefaultForwardCommand(即 player 当场有没有 SEEK_TO_NEXT/PREVIOUS 命令)
     * 把**自定义列表的第 1/2 个**自动塞进空缺的 BACK/FORWARD 槽。模拟器 a34 实测(dumpsys notification):
     * 通知只剩 4 个 action = [上一首, 暂停, 喜欢, 播放顺序], "喜欢"被顶到 forward 槽第 3 位、"下一首"整个消失,
     * 紧凑视图(int[]=3)变成 [上一首, 暂停, 喜欢]。=> 必须显式钉槽位, 不能靠 Media3 的默认推断。
     *
     * 为什么"暂停/播放"不做自定义按钮(需求原文的"5 个全部自定义"做不到): 见上 (2), Media3 无条件用系统按钮
     * 占中间位; 我们再放一个自定义播放键只会掉到末尾 overflow 变成第 6 个按钮。系统按钮自带播放/暂停
     * 图标翻转, 正好满足"图标随状态刷新", 比自定义更可靠。
     *
     * 为什么上一首/下一首用**自定义 session command**(CMD_PREV/CMD_NEXT)而不是
     * setPlayerCommand(COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)(已实测否决): Media3 在把偏好发给 controller 前会调
     * CommandButton.copyWithUnavailableButtonsDisabled(), 把"player 命令当前不可用"的按钮 isEnabled 置 false;
     * 而 getCustomLayoutFromMediaButtonPreferences() 会整块跳过 isEnabled=false 的按钮。实测(a34): 用 player
     * 命令做上一首/下一首时, 两个按钮都被判不可用而丢弃, 通知退化成系统 prev/Pause/next + 喜欢 + 播放顺序
     * (顺序碰巧对, 但完全取决于 player 当时有没有 seekToNext 命令, 属不可控的巧合)。
     * 自定义 session command 只要在 onConnect 里注册过就永远"可用", 槽位也不会被推断改写。
     *
     * 点击路径: 通知 action -> MediaSessionLegacyStub.onCustomAction -> [sessionCallback].onCustomCommand
     * -> CMD_PREV/CMD_NEXT 直接 requestSkip(false/true)(与耳机键同一个 skipListener 出口,
     * MainActivity -> Dart skipPrevious/skipNext); 喜欢/播放顺序仍走 actionListener -> toggleLike/cycleMode。
     * 队列语义一点没动, 只改了通知按钮的槽位与去重。
     */
    @OptIn(UnstableApi::class)
    private fun buildCustomLayout(): List<CommandButton> = listOf(
        // 上一首: 显式钉 SLOT_BACK(通知第 1 位)
        CommandButton.Builder()
            .setDisplayName("上一首")
            .setSessionCommand(SessionCommand(CMD_PREV, Bundle.EMPTY))
            .setSlots(CommandButton.SLOT_BACK)
            .setIconResId(R.drawable.ic_notif_prev)
            .build(),
        // 下一首: 显式钉 SLOT_FORWARD(通知第 3 位)
        CommandButton.Builder()
            .setDisplayName("下一首")
            .setSessionCommand(SessionCommand(CMD_NEXT, Bundle.EMPTY))
            .setSlots(CommandButton.SLOT_FORWARD)
            .setIconResId(R.drawable.ic_notif_next)
            .build(),
        // 喜欢/取消喜欢: overflow(第 4 位)
        CommandButton.Builder()
            .setDisplayName(if (likedState) "取消喜欢" else "喜欢")
            .setSessionCommand(SessionCommand(CMD_LIKE, Bundle.EMPTY))
            .setIconResId(
                if (likedState) R.drawable.ic_notif_heart_filled
                else R.drawable.ic_notif_heart_outline
            )
            .build(),
        CommandButton.Builder()
            .setDisplayName("播放顺序")
            .setSessionCommand(SessionCommand(CMD_MODE, Bundle.EMPTY))
            .setIconResId(modeIconRes(modeIcon))
            .build(),
    )

    private fun modeIconRes(icon: String): Int = when (icon) {
        "repeat" -> R.drawable.ic_notif_repeat
        "repeatOne" -> R.drawable.ic_notif_repeat_one
        "shuffle" -> R.drawable.ic_notif_shuffle
        "heart" -> R.drawable.ic_notif_heart_filled
        else -> R.drawable.ic_notif_sequence
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
        // UA 的唯一来源是 Rust(ncm-service 的 platform_profile().ua, 取链用同一串),
        // 由 Dart 启动时经 ncm/player#setUserAgent 注入; 这里的兜底常量只在注入失败时生效.
        val ua = PlaybackService.resolvedUserAgent()
        if (!PlaybackService.userAgentInjected()) {
            Log.w(NCM_UA_TAG, "构建 DataSource 时还没有注入 UA, 用兜底常量: " + ua)
        }
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(ua)
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
     * Dart 注入的 UA 与兜底常量不同(升级客户端版本后的正常漂移): DataSource 在构建时就捕获了
     * UA, 要让新值生效只能重建播放器。启动注入时通常还没有 MediaItem, 重建是零代价的;
     * 若正在播, 由 [rebuildPlayer] 保留播放项/位置, 代价与改 EQ 同量级(几十毫秒)。
     */
    private fun applyUserAgentChange(matchesFallback: Boolean) {
        if (matchesFallback || exoPlayer == null) return
        Log.i(TAG, "UA 变更 ⇒ 重建 ExoPlayer, 让 CDN 请求改用注入的 UA")
        rebuildPlayer()
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
         * 【兜底】CDN 的 UA: 安卓 App 用官方安卓客户端 UA, 不要拿 PC 桌面 UA 冒充。
         * ExoPlayer 默认 UA(NeteaseLib/ExoPlayerLib) 会被 CDN 拒。
         *
         * **真值来自 Dart/Rust**: `ncm-ffi` 的 `playback_user_agent()`
         * (= ncm-service 的 `platform_profile().ua`, 与取链同一个常量) 在启动时经
         * `ncm/player#setUserAgent` 注入, 见 [setUserAgent]。这里的字符串只在注入失败
         * (Dart 侧 Rust 未就绪/通道未建)时生效, 不再需要与 Rust 手工保持一致;
         * 注入值与它不同时 logcat 会打一条 `NCM-UA`(P-21 的防漂移面)。
         */
        const val FALLBACK_USER_AGENT =
            "NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0 (Linux; U; Android 14; " +
                "23013RK75C Build/UKQ1.230804.001)"

        /** UA 注入/漂移的 logcat 标签: `adb logcat -s NCM-UA` 即可对比兜底与真值 */
        const val NCM_UA_TAG = "NCM-UA"

        /** Dart 从 Rust 拿到的 UA(真值); null = 还没注入, 全程用 [FALLBACK_USER_AGENT] */
        @Volatile
        private var injectedUserAgent: String? = null

        /** 播放器该用的 UA: 注入值优先, 否则兜底常量 */
        fun resolvedUserAgent(): String = injectedUserAgent ?: FALLBACK_USER_AGENT

        /** 是否已收到 Dart 注入(兜底路径的可观测判据) */
        fun userAgentInjected(): Boolean = injectedUserAgent != null

        /**
         * `ncm/player#setUserAgent` 的落点(Dart → Kotlin), 由 MainActivity 转发。
         *
         * 三件事: 记住真值 / 打一条可对比的日志 / 让已建好的播放器改用新值。
         */
        fun setUserAgent(ua: String?) {
            val trimmed = ua?.trim().orEmpty()
            if (trimmed.isEmpty()) {
                Log.w(NCM_UA_TAG, "注入的 UA 为空, 继续用兜底常量: " + FALLBACK_USER_AGENT)
                return
            }
            if (trimmed == injectedUserAgent) return
            injectedUserAgent = trimmed
            val matchesFallback = trimmed == FALLBACK_USER_AGENT
            if (matchesFallback) {
                Log.i(NCM_UA_TAG, "UA 已注入, 与兜底常量一致: " + trimmed)
            } else {
                // 不是错误: 真值以 Rust 为准, 只是 Kotlin 的兜底副本过期了(升级客户端版本时正常出现)
                Log.w(
                    NCM_UA_TAG,
                    "UA 已注入(播放用注入值), 兜底常量已过期:\n  注入=" + trimmed +
                        "\n  兜底=" + FALLBACK_USER_AGENT,
                )
            }
            // DataSource 在构建时捕获 UA: 已经建好且真值不同 ⇒ 重建一次(此刻通常还没开始播)
            instance?.applyUserAgentChange(matchesFallback)
        }

        /** logcat 统一前缀(NCM-PLAYER): 通知按钮/调音的可观测面, 回归与真机排查都看它 */
        const val TAG = "NCM-PLAYER"

        /**
         * 「没有同进程消费者」时的兜底出口: 用 Intent 把 MainActivity 拉起来并带上动作名。
         * MainActivity 在 Dart 侧回调就绪后再执行(见 deliverPendingPlaybackAction)。
         */
        const val EXTRA_PLAYBACK_ACTION = "com.minincm.minincm.PLAYBACK_ACTION"

        /** 同进程引用, 让 MainActivity 的 MethodChannel 直接落到本服务(同进程, 无 IPC) */
        @Volatile
        var instance: PlaybackService? = null

        /**
         * 通知自定义按钮的状态(红心实/空 + 模式图标)。
         *
         * 放 companion(而不是实例字段): 服务被系统回收后重建会走 onCreate, 实例字段回到
         * liked=false/mode=sequence, 而通知里显示的仍是用户看到的旧图标 ⇒ 红心/模式与实际状态
         * 不一致, 直到用户切歌触发 Dart 重推(P-02)。同进程内静态字段保住最近一次已知值,
         * 跨进程再由 [requestActionStateSync] 请 Dart 重推。
         */
        @Volatile
        private var likedState = false
        @Volatile
        private var modeIcon = "sequence"

        /**
         * 上一首/下一首的出口: true=下一首, false=上一首.
         * MainActivity 在建立 MethodChannel 后注入(同进程), 由它转发给 Dart 队列.
         */
        @Volatile
        var skipListener: ((Boolean) -> Unit)? = null

        /**
         * 状态回读的出口: MainActivity 注入, 效果是向 Dart 发一条 "syncActionState"
         * (Dart 侧 _registerNativeHandler 收到后重推红心/模式)。
         */
        @Volatile
        var actionStateSyncListener: (() -> Unit)? = null

        /** 兜底意图的有效期: 超过就不补执行(过期的一首"下一首"执行起来很突兵) */
        const val PENDING_ACTION_TTL_MS = 60_000L

        /** 无消费者时点下、但拉起被 BAL 拦掉的意图(等 App 回来补执行) */
        @Volatile
        private var pendingFallback: Pair<String, Long>? = null

        /**
         * 取走排队中的兜底意图(过期作废)。MainActivity 在 Dart 回调就绪(`actionHandlersReady`)时调用。
         * 返回 null = 没有要补执行的动作。
         */
        /**
         * 作废排队中的兜底意图(不执行)。
         *
         * 用在同一击已经通过拉起用的 Intent(EXTRA_PLAYBACK_ACTION)送达时: 两条路都留过痕,
         * 都执行会让「下一首」跳两首(见 MainActivity 的 actionHandlersReady 处理)。
         */
        fun discardPendingFallback() {
            if (pendingFallback != null) {
                Log.i(TAG, "兜底意图已由 Intent 送达, 作废队列里那条")
            }
            pendingFallback = null
        }

        fun consumePendingFallbackAction(): String? {
            val pending = pendingFallback ?: return null
            pendingFallback = null
            val ageMs = System.currentTimeMillis() - pending.second
            if (ageMs > PENDING_ACTION_TTL_MS) {
                Log.w(TAG, "丢弃过期的兜底意图 " + pending.first + " (" + ageMs + "ms)")
                return null
            }
            return pending.first
        }

        fun requestSkip(next: Boolean) {
            val listener = skipListener
            if (listener != null) {
                listener.invoke(next)
                return
            }
            // 上划清任务后 MainActivity 已销毁(skipListener 被置空), 而"正在播放"时服务不 stopSelf:
            // 通知/耳机键还在, 回调却没有消费者 —— 以前这里静默失败(用户点了没反应)。
            // 现在改为把 App 拉起来并把意图带过去: 任何时刻点按钮都有可见结果(P-01)。
            launchForAction(if (next) CMD_NEXT else CMD_PREV)
        }

        /** 通知栏喜欢/播放顺序的出口: 有消费者就直连, 没有就拉起 App 兜底 */
        fun requestAction(action: String) {
            val listener = actionListener
            if (listener != null) {
                listener.invoke(action)
            } else {
                launchForAction(action)
            }
        }

        /**
         * 兜底出口(没有同进程消费者时): 把动作塞进 Intent 拉起 MainActivity, 同时给一次可见反馈。
         *
         * 为什么不用"缓存意图等 listener 恢复再重放"(审计备选 a): 用户点按钮的那一刻 Activity
         * 可能永远不回来, 缓存的意图要到下次打开 App 才生效, 期间仍然是"看着能点、实际哑掉"。
         *
         * 关于"为什么还配一条 Toast"(模拟器 a34 / Android 14 实测): 通知 action 的 PendingIntent 是
         * startService 型, 系统给的是 BackgroundStartPrivileges[allowsBackgroundActivityStarts=false,
         * allowsBackgroundForegroundServiceStarts=true], 所以从这里 startActivity 会被 BAL 拦掉
         * (logcat: "Background activity launch blocked ... (BAL_BLOCK) result code=102")。
         * 拉起成功与否不能当作可见反馈, 因此点击一律先给 Toast + logcat, 再尽力拉起 App:
         * 拉起成功(旧系统/允许后台启动的 ROM)时动作会在 Dart 就绪后执行, 失败时用户至少看到
         * "请打开 App 操作" —— 不再是无声失败(P-01 的目标: 任何时刻点按钮都有可见结果)。
         */
        private fun launchForAction(action: String) {
            val svc = instance
            if (svc == null) {
                Log.w(TAG, "通知按钮意图 " + action + " 无人消费且服务已销毁")
                return
            }
            Log.i(TAG, "无同进程消费者, 通知按钮意图 " + action + " 转交 App 处理")
            // 拉起可能被 BAL 拦掉(见上), 所以同时把意图排进静态队列: 用户随后从通知本体回到 App 时,
            // MainActivity 在 Dart 回调就绪后 consumePendingFallbackAction() 补执行(审计备选 a 的重放语义,
            // 但不会"等到下次想起来才生效": 点下去就有 Toast + 立即可用的恢复路径)。
            pendingFallback = action to System.currentTimeMillis()
            showBackgroundToast(svc, action)
            try {
                val intent = Intent(svc.applicationContext, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    putExtra(EXTRA_PLAYBACK_ACTION, action)
                }
                svc.applicationContext.startActivity(intent)
                // startActivity 不抛异常不代表真的起来了: Android 14 会异步判 BAL 并 abort
                // (logcat: ActivityTaskManager: Abort background activity starts), 那条兜底队列才是准的。
                Log.i(TAG, "已发起拉起 MainActivity 处理 " + action + "(被 BAL 拦掉时靠兜底队列补执行)")
            } catch (e: Exception) {
                Log.w(TAG, "拉起 MainActivity 处理 " + action + " 失败: " + e)
            }
        }

        /**
         * 后台可见反馈: 服务没有 Activity 时用 Toast 告诉用户"动作交给了 App"。
         * Android 12+ 对后台**自定义视图** Toast 有限制, 纯文本 Toast 由系统渲染, 前台服务进程仍可显示
         * (模拟器 a34 实测可见); 万一某机型被系统拦掉, logcat 那条 NCM-PLAYER 仍是可追溯的记录。
         */
        private fun showBackgroundToast(svc: PlaybackService, action: String) {
            val what = when (action) {
                CMD_LIKE -> "喜欢"
                CMD_MODE -> "播放顺序"
                CMD_PREV -> "上一首"
                CMD_NEXT -> "下一首"
                else -> "操作"
            }
            Handler(Looper.getMainLooper()).post {
                try {
                    Toast.makeText(
                        svc.applicationContext,
                        "轻音 MiniNCM: 队列在 App 内, 请打开 App 后执行「" + what + "」",
                        Toast.LENGTH_SHORT,
                    ).show()
                } catch (e: Exception) {
                    Log.w(TAG, "Toast 失败: " + e)
                }
            }
        }

        /**
         * 通知栏按钮顺序契约(需求 7): 上一首 -> 暂停/播放 -> 下一首 -> 喜欢/取消喜欢 -> 播放顺序。
         *
         * 仅供注释与 logcat 自检(NCM-PLAYER "notification buttons = ...")使用, 真正的顺序由 Media3
         * 的槽位拼装决定(见 [buildCustomLayout] 的 KDoc); 只改这里不改布局 = 自欺, 别只改这一处。
         */
        val NOTIFICATION_BUTTON_ORDER = listOf("上一首", "暂停/播放", "下一首", "喜欢/取消喜欢", "播放顺序")

        const val CMD_LIKE = "ncm.LIKE"
        const val CMD_MODE = "ncm.MODE"

        /** 通知栏「上一首」: 与耳机键同一条出口(skipListener -> skipPrevious), 不走 actionListener */
        const val CMD_PREV = "ncm.PREV"

        /**
         * 通知栏「下一首」: onCustomCommand 里直接 requestSkip(true)(与耳机键同一条出口)。
         * MainActivity 里那条 CMD_NEXT -> skipNext 的映射因此不再被使用(文件范围外, 未删, 留着也无副作用)。
         */
        const val CMD_NEXT = "ncm.NEXT"

        @Volatile
        var actionListener: ((String) -> Unit)? = null
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
