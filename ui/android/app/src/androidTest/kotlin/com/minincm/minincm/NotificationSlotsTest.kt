package com.minincm.minincm

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.AfterClass
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

/**
 * P-11 首个 instrumented 测试: 通知渠道 + 通知按钮**槽位**。
 *
 * 为什么这么测:
 * - 断言对象是 **Media3 真正拼出来的 Notification**(而不是 "上一首/下一首" 这几个常量), 用的是
 *   [PlaybackService.onCreate] 自己调过 setMediaButtonPreferences 的那个 MediaSession —— 也就是生产
 *   代码里的 buildCustomLayout() + Media3 的 slot 拼装(getMediaButtons -> CommandButton
 *   .getCustomLayoutFromMediaButtonPreferences)。改一行槽位就会红。
 * - 不走 "播放一首然后读 getActiveNotifications()": 那需要网络 + 账号 + 前台服务启动,
 *   在 CI 模拟器上是不稳定源。「真机/模拟器上实际 post 出来的通知」由
 *   tools/devui/notif-slots(读 dumpsys notification --noredact)负责, 两者互补。
 * - 不需要登录、不需要联网、不需要解码音频: 只创建 Service(ExoPlayer 空转)+ 拼一条通知对象。
 *
 * 运行(需模拟器, 别在用户物理机上跑):
 *   cd ui/android && ./gradlew :app:connectedDebugAndroidTest
 * 或: DEV=emulator-5554 tools/devui/androidtest  (见该脚本)
 */
@RunWith(AndroidJUnit4::class)
class NotificationSlotsTest {

    companion object {
        /** PlaybackService 的按钮顺序契约(见 media-notification-custom-buttons.md) */
        private val EXPECTED_TITLES = listOf("上一首", "下一首", "喜欢", "播放顺序")

        private const val MEDIA_SESSION_SERVICE_ACTION = "androidx.media3.session.MediaSessionService"

        private lateinit var context: Context
        private lateinit var session: MediaSession
        private var connection: ServiceConnection? = null

        @BeforeClass
        @JvmStatic
        fun bindPlaybackService() {
            context = ApplicationProvider.getApplicationContext()
            val latch = CountDownLatch(1)
            val conn = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                    latch.countDown()
                }

                override fun onServiceDisconnected(name: ComponentName?) = Unit

                override fun onNullBinding(name: ComponentName?) {
                    // 服务已创建(onCreate 里 instance 已赋值), 只是没给 binder
                    latch.countDown()
                }
            }
            connection = conn
            // 必须带 MediaSessionService 的 action: Media3 的 onBind 在 action==null 时直接返回 null
            val intent = Intent(context, PlaybackService::class.java).setAction(MEDIA_SESSION_SERVICE_ACTION)
            if (!context.bindService(intent, conn, Context.BIND_AUTO_CREATE)) {
                fail("bindService(PlaybackService) 直接被拒")
            }
            if (!latch.await(10, TimeUnit.SECONDS)) {
                fail("PlaybackService 10s 内没有创建完成")
            }
            val service = PlaybackService.instance
            if (service == null) {
                fail("PlaybackService.instance 为空 —— 服务没起来或被立刻回收")
                return
            }
            session = sessionOf(service)
        }

        /** service 的 mediaSession 是 private(生产代码不需要为测试开洞), 测试侧反射读取 */
        private fun sessionOf(service: PlaybackService): MediaSession {
            val field = PlaybackService::class.java.getDeclaredField("mediaSession")
            field.isAccessible = true
            return field.get(service) as? MediaSession
                ?: throw AssertionError("PlaybackService.mediaSession 仍是 null(onCreate 应该已经建好)")
        }

        @AfterClass
        @JvmStatic
        fun unbindPlaybackService() {
            connection?.let {
                try {
                    context.unbindService(it)
                } catch (e: IllegalArgumentException) {
                    // 已经断了, 无所谓
                }
            }
            connection = null
        }
    }

    @After
    fun resetActionState() {
        // 案例 3 会改静态 likedState/modeIcon, 复位避免污染后续案例与同进程 logcat 断言
        onMain { PlaybackService.instance?.setActionState(liked = false, icon = "sequence") }
    }

    // ---- 案例 1: 通知渠道存在且 importance 正确 ----

    @Test
    fun notificationChannelHasLowImportance() {
        buildNotification() // createNotification 内部 ensureNotificationChannel()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = nm.getNotificationChannel(DefaultMediaNotificationProvider.DEFAULT_CHANNEL_ID)
        assertNotNull(
            "默认通知渠道 " + DefaultMediaNotificationProvider.DEFAULT_CHANNEL_ID + " 不存在",
            channel,
        )
        assertEquals(
            "媒体通知应为 IMPORTANCE_LOW(不响铃/不弹横幅), 实际 importance=" + channel.importance,
            NotificationManager.IMPORTANCE_LOW,
            channel.importance,
        )
        // 媒体通知不该亮灯/震动: 这两项若被改成默认值会让后台播放变成骚扰
        assertEquals("showLights 应为 false", false, channel.shouldShowLights())
        assertEquals("vibration 应为 null", null, channel.vibrationPattern)
    }

    // ---- 案例 2: 通知 action 槽位数量与顺序 ----

    @Test
    fun notificationActionsFollowSlotContract() {
        val notification = buildNotification()
        val titles = actionTitles(notification)

        assertEquals(
            "通知 action 数量应为 5(上一首/播放暂停/下一首/喜欢/播放顺序), 实际 " + titles,
            5,
            titles.size,
        )
        assertEquals("第 1 位应是上一首", "上一首", titles[0])
        assertTrue(
            "第 2 位应是系统 play/pause 槽(标题由 Media3 提供), 实际 " + titles[1],
            EXPECTED_TITLES.none { it == titles[1] },
        )
        assertEquals("第 3 位应是下一首", "下一首", titles[2])
        assertEquals("第 4 位应是喜欢", "喜欢", titles[3])
        assertEquals("第 5 位应是播放顺序", "播放顺序", titles[4])
        // P-01 那类回归的具体症状: 「下一首」被顶成重复项/消失
        assertEquals("「下一首」只能出现一次, 实际 " + titles, 1, titles.count { it == "下一首" })

        // 紧凑视图(锁屏媒体卡片)只显示前三个 action
        val compact = notification.extras.getIntArray(Notification.EXTRA_COMPACT_ACTIONS)
        assertNotNull("通知缺少 android.compactActions, MediaStyle 没生效", compact)
        assertTrue(
            "紧凑视图索引应为 [0,1,2], 实际 " + compact!!.joinToString(","),
            compact.contentEquals(intArrayOf(0, 1, 2)),
        )
    }

    // ---- 案例 3: 状态回推(喜欢/模式)真的改到了通知按钮 ----

    @Test
    fun actionStatePushUpdatesLikeAndModeButtons() {
        onMain { PlaybackService.instance?.setActionState(liked = true, icon = "shuffle") }

        val titles = actionTitles(buildNotification())
        assertEquals("红心打开后第 4 位应变成「取消喜欢」, 实际 " + titles, "取消喜欢", titles[3])
        assertEquals("喜欢/取消喜欢占据的槽位不能变(仍在前 5 位内)", 5, titles.size)

        onMain { PlaybackService.instance?.setActionState(liked = false, icon = "sequence") }
        val back = actionTitles(buildNotification())
        assertEquals("红心关回后第 4 位应回到「喜欢」, 实际 " + back, "喜欢", back[3])
    }

    // ---- 工具 ----

    /**
     * 用生产代码那套 mediaButtonPreferences 让 Media3 拼一条通知(不 post, 因此不需要 POST_NOTIFICATIONS
     * 也不需要前台服务), 返回 Notification 对象供断言。
     */
    private fun buildNotification(): Notification {
        // 必须回主线程: MediaSession/Player 是主线程亲和的, 在 instrumentation 线程上调
        // createNotification / mediaButtonPreferences 会抛
        // "Player is accessed on the wrong thread"(2026-11-17 在真机上实测踩到)。
        var built: Notification? = null
        onMain {
            val provider = DefaultMediaNotificationProvider(context)
            val factory = SlotRecordingActionFactory(context)
            val media = provider.createNotification(
                session,
                session.mediaButtonPreferences,
                factory,
                androidx.media3.session.MediaNotification.Provider.Callback { },
            )
            built = media.notification
        }
        return built ?: throw AssertionError("主线程上没有拼出通知")
    }

    private fun actionTitles(notification: Notification): List<String> =
        (notification.actions ?: emptyArray()).map { (it.title ?: "").toString().trim() }

    private fun onMain(block: () -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
    }

    /**
     * Media3 只会通过 [MediaNotification.ActionFactory] 要 action; 这里把它要的顺序与标题记下来,
     * 并给出一个占位 PendingIntent(测试不点击按钮, 点按钮的行为由 notif-slots 脚本/手工冒烟覆盖)。
     */
    private class SlotRecordingActionFactory(private val context: Context) :
        MediaNotification.ActionFactory {
        private var seq = 0

        private fun placeholderPendingIntent(): PendingIntent = PendingIntent.getService(
            context,
            seq++,
            Intent(context, PlaybackService::class.java).setAction("com.minincm.minincm.TEST_NOOP"),
            PendingIntent.FLAG_IMMUTABLE,
        )

        override fun createMediaAction(
            session: MediaSession,
            icon: IconCompat,
            title: CharSequence,
            command: Int,
        ): NotificationCompat.Action =
            NotificationCompat.Action.Builder(icon, title, placeholderPendingIntent()).build()

        override fun createCustomAction(
            session: MediaSession,
            icon: IconCompat,
            title: CharSequence,
            customAction: String,
            args: Bundle,
        ): NotificationCompat.Action =
            NotificationCompat.Action.Builder(icon, title, placeholderPendingIntent()).build()

        override fun createCustomActionFromCustomCommandButton(
            session: MediaSession,
            customCommandButton: CommandButton,
        ): NotificationCompat.Action = NotificationCompat.Action.Builder(
            customCommandButton.icon,
            customCommandButton.displayName,
            placeholderPendingIntent(),
        ).build()

        override fun createMediaActionPendingIntent(
            session: MediaSession,
            command: Long,
        ): PendingIntent = placeholderPendingIntent()
    }
}
