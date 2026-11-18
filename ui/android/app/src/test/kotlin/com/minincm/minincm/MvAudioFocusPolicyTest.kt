package com.minincm.minincm

import android.media.AudioManager
import com.minincm.minincm.MvAudioFocusPolicy.Action
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * U-04 的焦点决策单测(JVM, 不需要设备)。
 *
 * 真正的音量/焦点行为只能在真机上听(报告里已注明), 这里锁住的是"回调 → 动作"的映射,
 * 防止以后有人把"永久失去焦点也自动恢复"这类反向语义写回来。
 */
class MvAudioFocusPolicyTest {
    @Test
    fun permanentLossPauses() {
        assertEquals(Action.PAUSE, MvAudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS, false))
        assertEquals(Action.PAUSE, MvAudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS, true))
    }

    @Test
    fun transientLossAndDuckBothPause() {
        assertEquals(
            Action.PAUSE,
            MvAudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false),
        )
        assertEquals(
            Action.PAUSE,
            MvAudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, false),
        )
    }

    @Test
    fun gainResumesOnlyWhenPausedByFocus() {
        assertEquals(Action.RESUME, MvAudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_GAIN, true))
        // 用户自己暂停的: 焦点回来也不许偷偷起播
        assertEquals(Action.NONE, MvAudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_GAIN, false))
    }

    @Test
    fun unknownOrDuplicateCallbacksDoNothing() {
        assertEquals(Action.NONE, MvAudioFocusPolicy.actionFor(12345, true))
        // AUDIOFOCUS_LOSS 之后又来一个同样的回调: 仍然只是暂停(幂等), 不是恢复
        assertEquals(Action.PAUSE, MvAudioFocusPolicy.actionFor(AudioManager.AUDIOFOCUS_LOSS, true))
    }
}
