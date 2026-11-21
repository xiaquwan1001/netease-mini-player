package com.minincm.minincm

/**
 * configure 到达时 volume 该由谁接管(R5 淡入 vs 增益斜坡): **纯决策 + 不碰 Android 框架**,
 * 便于 JVM 单测(见 src/test/.../**/VolumeHandoffPolicyTest.kt)。真正生效在
 * [PlaybackService.applyGainChange]。
 *
 * 背景(2026-11-21 用户反馈 #3「选了淡入淡出, 听感上没生效」的**安卓侧根因**):
 * 切歌的调用顺序是
 *   ① Dart `playback.play()` → 通道 `play` → MainActivity `c.play()` + `fadeIn()`
 *      (ValueAnimator 从 0 升到目标音量, 时长 = fadeMs);
 *   ② 紧接着同一轮 Dart 代码 `unawaited(applyLoudnessForTrack(...))` → `applyAudioTuning()`
 *      → 通道 `configure` → [PlaybackService.applyGainChange]。
 * ②以前**无条件** `fadeAnimator?.cancel()` 再 `exoPlayer.volume = appliedVolume()`
 * ⇒ ①刚起的淡入在几毫秒内被打断, 用户无论选 200ms/500ms/1s 都听不到淡入。
 *
 * 判据(不变量): **目标增益没变时, 正在跑的淡入不被 configure 抢走** ——
 * 淡入的终点本来就是当前目标音量, 让它自己跑完即可; 目标真的变了才按 last-wins
 * 取消淡入/斜坡, 由增益路径重算(与既有 P-03 口径一致)。
 */
internal enum class VolumeOwner {
    /** 交回正在跑的淡入(configure 不动 player.volume) */
    Fade,

    /** 增益路径接管(取消淡入/斜坡, 按目标增益瞬时或斜坡落地) */
    Gain,
}

internal object VolumeHandoffPolicy {
    /** 增益视为"没变"的阈值(dB): 与 PlaybackService 里既有的 1e-4 判断同一口径 */
    const val GAIN_UNCHANGED_DB = 1e-4

    /**
     * [deltaDb] = 目标增益 - 当前实际增益; [fadeRunning] = 是否有淡入动画在跑。
     *
     * 返回 [VolumeOwner.Fade] 的唯一条件: 淡入在跑 **且** 目标增益与当前实际一致
     * (此时淡入的终点就是目标, 打断它只会让用户听不到淡入)。
     */
    fun owner(deltaDb: Double, fadeRunning: Boolean): VolumeOwner =
        if (fadeRunning && (deltaDb.isFinite() && kotlin.math.abs(deltaDb) <= GAIN_UNCHANGED_DB)) {
            VolumeOwner.Fade
        } else {
            VolumeOwner.Gain
        }
}
