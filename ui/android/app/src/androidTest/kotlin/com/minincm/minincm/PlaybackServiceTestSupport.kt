package com.minincm.minincm

import android.app.Notification
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
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.fail

/**
 * 设备级 Android 测试的公共设施(2026-11-17 抽出, 供 [NotificationSlotsTest] / [NotificationClickTest] 复用)。
 *
 * 两个关键约定, 都是踩坑换来的:
 * - **必须带 `MediaSessionService` 的 action 去 bind**: Media3 的 `onBind` 在 action==null 时
 *   直接返回 null(服务照样 onCreate, 但拿不到 binder)。
 * - **拼通知/读 mediaButtonPreferences 必须回主线程**: Player/MediaSession 主线程亲和,
 *   在 instrumentation 线程上会抛 "Player is accessed on the wrong thread"(真机实测)。
 */
object PlaybackServiceTestSupport {

    const val MEDIA_SESSION_SERVICE_ACTION = "androidx.media3.session.MediaSessionService"

    lateinit var context: Context
        private set

    lateinit var session: MediaSession
        private set

    private var connection: ServiceConnection? = null

    /** 绑定 PlaybackService 并取出生产代码建好的 MediaSession(失败直接 fail)。 */
    fun bind() {
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
        val intent = Intent(context, PlaybackService::class.java).setAction(MEDIA_SESSION_SERVICE_ACTION)
        if (!context.bindService(intent, conn, Context.BIND_AUTO_CREATE)) {
            fail("bindService(PlaybackService) 直接被拒")
        }
        if (!latch.await(10, TimeUnit.SECONDS)) {
            fail("PlaybackService 10s 内没有创建完成")
        }
        val service = PlaybackService.instance
            ?: fail("PlaybackService.instance 为空 —— 服务没起来或被立刻回收").let { return }
        session = sessionOf(service)
    }

    fun unbind() {
        connection?.let {
            try {
                context.unbindService(it)
            } catch (e: IllegalArgumentException) {
                // 已经断了, 无所谓
            }
        }
        connection = null
    }

    /** service 的 mediaSession 是 private(生产代码不为测试开洞), 测试侧反射读取 */
    fun sessionOf(service: PlaybackService): MediaSession {
        val field = PlaybackService::class.java.getDeclaredField("mediaSession")
        field.isAccessible = true
        return field.get(service) as? MediaSession
            ?: throw AssertionError("PlaybackService.mediaSession 仍是 null(onCreate 应该已经建好)")
    }

    /** 用生产代码那套 mediaButtonPreferences 让 Media3 拼一条通知(不 post, 不需要前台服务)。 */
    fun buildNotification(): Notification {
        var built: Notification? = null
        onMain {
            val provider = DefaultMediaNotificationProvider(context)
            val media = provider.createNotification(
                session,
                session.mediaButtonPreferences,
                SlotRecordingActionFactory(context),
                MediaNotification.Provider.Callback { },
            )
            built = media.notification
        }
        return built ?: throw AssertionError("主线程上没有拼出通知")
    }

    fun actionTitles(notification: Notification): List<String> =
        (notification.actions ?: emptyArray()).map { (it.title ?: "").toString().trim() }

    fun onMain(block: () -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
    }

    /**
     * Media3 只会通过 [MediaNotification.ActionFactory] 要 action; 这里把它要的顺序与标题记下来,
     * 并给出占位 PendingIntent。
     *
     * **注意**: 因为这里是占位实现, **通知按钮上的 PendingIntent 不是生产对象** ——
     * 「按钮点下去真的发什么意图」由 [NotificationClickTest] 用 MediaController + 自定义
     * SessionCommand 这条**生产代码同路径**覆盖, 真实 post 出来的通知由
     * `tools/devui/notif-slots`(dumpsys) 覆盖。
     */
    private class SlotRecordingActionFactory(private val context: Context) :
        MediaNotification.ActionFactory {
        private var seq = 0

        private fun placeholderPendingIntent() = android.app.PendingIntent.getService(
            context,
            seq++,
            Intent(context, PlaybackService::class.java).setAction("com.minincm.minincm.TEST_NOOP"),
            android.app.PendingIntent.FLAG_IMMUTABLE,
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
        ): android.app.PendingIntent = placeholderPendingIntent()
    }
}
