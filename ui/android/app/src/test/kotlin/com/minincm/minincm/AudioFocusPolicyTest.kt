package com.minincm.minincm

import android.media.AudioManager
import com.minincm.minincm.AudioFocusPolicy.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「被其他媒体抢占时怎么办」的三档策略单测(JVM, 不需要设备)。
 *
 * 锁住的是**策略 → 行为**的映射:
 * - 跟随系统: 只有 Media3 管焦点(默认档, 升级用户不该感到变化);
 * - 总是在后台播放: 谁都不申请、谁都不理(代价是可能叠音, 用户自己选的);
 * - 总是停止播放: 服务自己申请焦点, 任何失去都暂停且**不自动恢复**。
 */
class AudioFocusPolicyTest {
    @Test
    fun unknownOrMissingIdFallsBackToFollowSystem() {
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId(null))
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId(""))
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId("whatever"))
        assertEquals(AudioFocusMode.ALWAYS_PLAY, AudioFocusMode.fromId("alwaysPlay"))
        assertEquals(AudioFocusMode.ALWAYS_STOP, AudioFocusMode.fromId("alwaysStop"))
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId("followSystem"))
    }

    @Test
    fun onlyFollowSystemDelegatesToExoPlayer() {
        assertTrue(AudioFocusPolicy.useExoPlayerFocus(AudioFocusMode.FOLLOW_SYSTEM))
        assertFalse(AudioFocusPolicy.useExoPlayerFocus(AudioFocusMode.ALWAYS_PLAY))
        // 总是停止: media3 会在 GAIN 时自动续播, 与"总是停止"语义相反 ⇒ 必须自己管
        assertFalse(AudioFocusPolicy.useExoPlayerFocus(AudioFocusMode.ALWAYS_STOP))
    }

    @Test
    fun onlyAlwaysStopManagesFocusInService() {
        assertFalse(AudioFocusPolicy.manageFocusInService(AudioFocusMode.FOLLOW_SYSTEM))
        assertFalse(AudioFocusPolicy.manageFocusInService(AudioFocusMode.ALWAYS_PLAY))
        assertTrue(AudioFocusPolicy.manageFocusInService(AudioFocusMode.ALWAYS_STOP))
    }

    @Test
    fun alwaysStopPausesOnEveryKindOfLoss() {
        listOf(
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
        ).forEach { change ->
            assertEquals(
                "change=$change 必须暂停",
                Action.PAUSE,
                AudioFocusPolicy.actionFor(AudioFocusMode.ALWAYS_STOP, change),
            )
        }
    }

    @Test
    fun alwaysStopNeverAutoResumes() {
        // 焦点回来(GAIN / GAIN_TRANSIENT / DUCK) 一律不动作: 等用户自己按播放
        listOf(
            AudioManager.AUDIOFOCUS_GAIN,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
        ).forEach { change ->
            assertEquals(
                "change=$change 不许自动续播",
                Action.NONE,
                AudioFocusPolicy.actionFor(AudioFocusMode.ALWAYS_STOP, change),
            )
        }
    }

    @Test
    fun otherModesNeverTouchFocusThemselves() {
        val changes = listOf(
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            AudioManager.AUDIOFOCUS_GAIN,
        )
        for (mode in listOf(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.ALWAYS_PLAY)) {
            for (change in changes) {
                assertEquals(
                    "mode=$mode change=$change",
                    Action.NONE,
                    AudioFocusPolicy.actionFor(mode, change),
                )
            }
        }
    }

    @Test
    fun mvAlignment() {
        // 跟随系统: MV 照旧申请焦点、焦点回来照旧续播
        assertTrue(AudioFocusPolicy.mvRequestsFocus(AudioFocusMode.FOLLOW_SYSTEM))
        assertTrue(AudioFocusPolicy.mvResumesOnGain(AudioFocusMode.FOLLOW_SYSTEM))
        // 总是在后台播放: MV 也不抢焦点, 更不自动续播
        assertFalse(AudioFocusPolicy.mvRequestsFocus(AudioFocusMode.ALWAYS_PLAY))
        assertFalse(AudioFocusPolicy.mvResumesOnGain(AudioFocusMode.ALWAYS_PLAY))
        // 总是停止: MV 仍申请焦点(要能被抢占), 但不自动续播
        assertTrue(AudioFocusPolicy.mvRequestsFocus(AudioFocusMode.ALWAYS_STOP))
        assertFalse(AudioFocusPolicy.mvResumesOnGain(AudioFocusMode.ALWAYS_STOP))
    }
}
