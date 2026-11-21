package com.minincm.minincm

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * R5 淡入 × configure 的交接判据单测(JVM, 不需要设备/声卡)。
 *
 * 锁的是**决策不变量**: 每次切歌 Dart 都会紧跟一次响度 configure, 那时目标增益没变,
 * 必须让淡入继续跑; 只有目标增益真的变了才由增益路径接管。真实听感仍要真机核对
 * (选 1s 淡入 → 切歌 → 耳朵/录音确认前 1s 是渐入), 但"configure 把淡入打断"
 * 这类回归会在这里立刻红。
 */
class VolumeHandoffPolicyTest {
    @Test
    fun unchangedGainKeepsTheRunningFade() {
        // 切歌后那次 configure: 增益没变(实测淡入刚起时 appliedGainDb 已对齐目标)
        assertEquals(VolumeOwner.Fade, VolumeHandoffPolicy.owner(deltaDb = 0.0, fadeRunning = true))
        // 浮点抖动(响度测量先给 0 dB、后给同一值)也不能把淡入抢走
        assertEquals(VolumeOwner.Fade, VolumeHandoffPolicy.owner(deltaDb = 5e-5, fadeRunning = true))
        assertEquals(VolumeOwner.Fade, VolumeHandoffPolicy.owner(deltaDb = -5e-5, fadeRunning = true))
    }

    @Test
    fun changedGainTakesOverFromTheFade() {
        // 响度均衡真的测出新增益 / 用户拖精细音量: last-wins, 增益路径接管
        assertEquals(VolumeOwner.Gain, VolumeHandoffPolicy.owner(deltaDb = 0.5, fadeRunning = true))
        assertEquals(VolumeOwner.Gain, VolumeHandoffPolicy.owner(deltaDb = -3.0, fadeRunning = true))
        // 超过阈值一点点就要接管(阈值只挡浮点噪声, 不挡真实变化)
        assertEquals(
            VolumeOwner.Gain,
            VolumeHandoffPolicy.owner(deltaDb = VolumeHandoffPolicy.GAIN_UNCHANGED_DB * 2, fadeRunning = true),
        )
    }

    @Test
    fun noRunningFadeAlwaysLetsGainOwnTheVolume() {
        // 没有淡入在跑时, 行为与改造前完全一致: 增益路径无条件接管
        assertEquals(VolumeOwner.Gain, VolumeHandoffPolicy.owner(deltaDb = 0.0, fadeRunning = false))
        assertEquals(VolumeOwner.Gain, VolumeHandoffPolicy.owner(deltaDb = 2.0, fadeRunning = false))
        // 非有限值(NaN/Inf)不能把 volume 交出去 —— 否则音量会卡在淡入的半截值上
        assertEquals(VolumeOwner.Gain, VolumeHandoffPolicy.owner(deltaDb = Double.NaN, fadeRunning = true))
    }
}
