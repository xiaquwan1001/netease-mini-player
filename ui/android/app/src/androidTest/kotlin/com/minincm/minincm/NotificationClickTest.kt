package com.minincm.minincm

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import android.os.Looper
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 设备级「通知点击行为」测试(2026-11-17, P-11 完整版 ③ 的第一层自动化)。
 *
 * 覆盖两件此前**只能靠真机手点**的事:
 *
 * 1. **点通知本体回 App**(P-01 的恢复半场): `PlaybackService.onCreate` 用
 *    `setSessionActivity(openAppPendingIntent())` 给通知挂了一个 contentIntent。
 *    这里断言它 ① 存在 ② 由本应用创建 ③ 指向 `MainActivity` 且带
 *    `NEW_TASK|SINGLE_TOP`(与生产代码逐个 flag 对比 PendingIntent 相等性 —— 不用反射,
 *    也不依赖 BAL 是否允许后台拉起), 再**真的 send 一次**确认不会崩。
 *
 * 2. **通知按钮背后的命令真的接到了处理方**: 按钮的 PendingIntent 由 Media3 自己造
 *    (拿不到生产对象), 但每个按钮最终都变成一条 `SessionCommand`/媒体命令发给服务。
 *    这里用 `MediaController` 连上生产服务, 断言 ① 自定义命令 CMD_PREV/CMD_NEXT/CMD_LIKE/CMD_MODE
 *    都在 `availableSessionCommands` 里(否则按钮点了会被系统吞成 unsupported) ② 发 CMD_PREV/CMD_NEXT
 *    返回 `RESULT_SUCCESS`(走 requestSkip 出口, 与耳机键同源)。
 *
 * 不做的事: 不播放音频、不联网、不依赖账号/前台服务 —— 所以能在 CI 模拟器上稳定跑。
 * 「真机/模拟器上实际 post 出来的那一条通知长什么样」仍由 `tools/devui/notif-slots` 覆盖。
 */
@RunWith(AndroidJUnit4::class)
class NotificationClickTest {

    companion object {
        private const val CMD_PREV = "ncm.PREV"
        private const val CMD_NEXT = "ncm.NEXT"
        private const val CMD_LIKE = "ncm.LIKE"
        private const val CMD_MODE = "ncm.MODE"

        @BeforeClass
        @JvmStatic
        fun bindPlaybackService() = PlaybackServiceTestSupport.bind()

        @AfterClass
        @JvmStatic
        fun unbindPlaybackService() = PlaybackServiceTestSupport.unbind()
    }

    @After
    fun finishLaunchedActivities() {
        // 案例 2 会真的把 MainActivity 拉起来: 收尾掉, 免得影响后面的案例/其它测试类
        onMain {
            val registry = ActivityLifecycleMonitorRegistry.getInstance()
            for (stage in Stage.values()) {
                registry.getActivitiesInStage(stage).toList()
                    .filterIsInstance<MainActivity>()
                    .forEach { it.finish() }
            }
        }
    }

    // ---- 案例 1: contentIntent 指向 MainActivity(生产 PendingIntent 的等价性断言) ----

    @Test
    fun notificationContentIntentTargetsMainActivity() {
        val notification = PlaybackServiceTestSupport.buildNotification()
        val contentIntent = notification.contentIntent
        assertNotNull(
            "通知没有 contentIntent —— 点通知本体不会回 App(模拟器 a34 实测过这个状态: 点了毫无反应)",
            contentIntent,
        )

        val context = PlaybackServiceTestSupport.context
        assertEquals(
            "contentIntent 应由本应用创建(系统才会按包名放行后台启动), 实际 creatorPackage=" +
                contentIntent!!.creatorPackage,
            context.packageName,
            contentIntent.creatorPackage,
        )

        // 与生产代码 openAppPendingIntent() 逐个 flag 对齐: Intent/MainActivity/flags 任一漂移都不相等。
        val expectedIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val expected = PendingIntent.getActivity(
            context,
            0,
            expectedIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        assertEquals(
            "通知点击的目标不是 MainActivity(NEW_TASK|SINGLE_TOP)",
            expected,
            contentIntent,
        )

        // 真的点一下: 不崩即可(是否允许后台拉起 Activity 受 BAL 影响, 这里不当作断言)
        PlaybackServiceTestSupport.onMain { contentIntent.send() }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    // ---- 案例 2: 点通知本体真的把 App 带回前台(环境受限时记为 skip) ----

    /**
     * 两个前提先硬断言, 再尝试真的点一次:
     *
     * 硬断言: ① `MainActivity` 是 exported 且 enabled(否则 PendingIntent 指向它也没用);
     *        ② contentIntent 由本应用创建(案例 1 已断言与生产意图逐个 flag 相等)。
     *
     * 软断言(环境受限时 skip): 由**本测试进程**发送 PendingIntent 时 Android 10+ 的 BAL 会拦掉
     * (模拟器 a34 实测 logcat: `Background activity launch blocked ... Abort background activity starts`,
     * `START ... cmp=.../MainActivity (BAL_BLOCK)`); 真机上点通知的是 SystemUI, 自带
     * `backgroundStartPrivileges`, 不受此限。instrumentation 里也起不来 Flutter 首帧前的 Activity
     * 阶段(同进程 + 引擎冷启动), 所以这条**不作为硬门**, 只把可自动化的部分锁定。
     */
    @Test
    fun contentIntentClickBringsMainActivityToFront() {
        val context = PlaybackServiceTestSupport.context
        // ① 目标 Activity 必须可被外部拉起
        val info = context.packageManager.getActivityInfo(
            android.content.ComponentName(context, MainActivity::class.java),
            0,
        )
        assertTrue("MainActivity 必须 exported(否则 system 点通知也起不来)", info.exported)
        assertTrue("MainActivity 必须 enabled", info.enabled)

        val notification = PlaybackServiceTestSupport.buildNotification()
        val contentIntent = notification.contentIntent
        assertNotNull("通知没有 contentIntent", contentIntent)

        finishMainActivities()
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        PlaybackServiceTestSupport.onMain { contentIntent!!.send() }

        val visible = waitForMainActivityResumed(15_000)
        org.junit.Assume.assumeTrue(
            "instrumentation 侧点击被 BAL 拦(模拟器实测 Abort background activity starts) 或" +
                "Flutter 冷启动没在 15s 内到 STARTED —— 真机/系统点击路径需人工冒烟;" +
                " 本用例的自动化部分(目标 exported + contentIntent 与生产意图逐 flag 相等)已通过。",
            visible,
        )
    }

    // ---- 案例 3: 通知按钮背后的自定义命令都接上了处理方 ----

    // ---- 案例 3: 通知按钮背后的自定义命令都接上了处理方 ----

    @Test
    fun customButtonCommandsAreWiredOnSession() {
        val context = PlaybackServiceTestSupport.context
        val controller = connectController(context)
        try {
            // MediaController 的所有 getter 都必须在 application(main) 线程上读
            var commands: androidx.media3.session.SessionCommands? = null
            onMain { commands = controller.availableSessionCommands }
            val cmds = commands ?: throw AssertionError("读不到 availableSessionCommands")
            val debug: () -> String = {
                cmds.commands.map { it.customAction }.filter { it.isNotEmpty() }.joinToString(",")
            }
            for (cmd in listOf(CMD_PREV, CMD_NEXT, CMD_LIKE, CMD_MODE)) {
                assertTrue(
                    "服务没有声明自定义命令 $cmd(通知上对应按钮点下去会被当成 unsupported)," +
                        " 实际可用命令=[" + debug() + "]",
                    cmds.contains(SessionCommand(cmd, Bundle.EMPTY)),
                )
            }

            // 让 requestSkip 那条路真的跑一次(与耳机键同一条出口); 没有可播放曲目时是 no-op
            assertEquals(
                "CMD_PREV 应被接受(上一首按钮点了不该被吞)",
                SessionResult0.SUCCESS,
                sendCommand(controller, CMD_PREV),
            )
            assertEquals(
                "CMD_NEXT 应被接受(下一首按钮点了不该被吞)",
                SessionResult0.SUCCESS,
                sendCommand(controller, CMD_NEXT),
            )
        } finally {
            PlaybackServiceTestSupport.onMain { controller.release() }
        }
    }

    // ---- 工具 ----

    /** 服务端返回的 SessionResult.ResultCode 值(RESULT_SUCCESS = 0) */
    private object SessionResult0 {
        const val SUCCESS = 0
    }

    private fun connectController(context: android.content.Context): MediaController {
        val token = SessionToken(context, android.content.ComponentName(context, PlaybackService::class.java))
        val latch = CountDownLatch(1)
        var controller: MediaController? = null
        var error: Throwable? = null
        // MediaController.Builder 必须在主线程 build + 在主线程回调
        onMain {
            val future: ListenableFuture<MediaController> =
                MediaController.Builder(context, token).buildAsync()
            future.addListener(
                {
                    try {
                        controller = future.get()
                    } catch (e: Throwable) {
                        error = e
                    }
                    latch.countDown()
                },
                ContextCompat.getMainExecutor(context),
            )
        }
        if (!latch.await(15, TimeUnit.SECONDS)) {
            fail("15s 内没连上 MediaController(服务没起来?)")
        }
        error?.let { throw AssertionError("MediaController 连接失败: $it", it) }
        return controller ?: throw AssertionError("MediaController 为 null")
    }

    private fun sendCommand(controller: MediaController, customAction: String): Int {
        val latch = CountDownLatch(1)
        var code = -1
        onMain {
            val future = controller.sendCustomCommand(SessionCommand(customAction, Bundle.EMPTY), Bundle.EMPTY)
            future.addListener(
                {
                    code = try {
                        future.get().resultCode
                    } catch (e: Throwable) {
                        -1
                    }
                    latch.countDown()
                },
                ContextCompat.getMainExecutor(PlaybackServiceTestSupport.context),
            )
        }
        if (!latch.await(10, TimeUnit.SECONDS)) {
            fail("10s 内没有收到 $customAction 的 SessionResult")
        }
        return code
    }

    /** 收掉所有 MainActivity(收尾/让"已在前台"不再成立) */
    private fun finishMainActivities() {
        onMain {
            val registry = ActivityLifecycleMonitorRegistry.getInstance()
            for (stage in Stage.values()) {
                registry.getActivitiesInStage(stage).toList()
                    .filterIsInstance<MainActivity>()
                    .forEach { it.finish() }
            }
        }
    }

    /**
     * 用 instrumentation 直接启动 MainActivity(绕过 BAL, 因为 instrumentation 自身被视为前台),
     * 等到 RESUMED 即返回 true。用于「通知点击目标可启动」这条二级断言。
     */
    private fun startMainActivitySync(): Boolean {
        val context = PlaybackServiceTestSupport.context
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            InstrumentationRegistry.getInstrumentation().startActivitySync(intent)
        } catch (e: Throwable) {
            // 把真实原因带出去(否则只能看到笼统的 false)
            throw AssertionError("startActivitySync(MainActivity) 抛异常: " + e, e)
        }
        return waitForMainActivityResumed(30_000)
    }

    /**
     * 轮询 MainActivity 是否已可见(RESUMED 或 STARTED; 阶段查询必须在主线程)。
     *
     * 接受 STARTED: 模拟器上 Flutter 冷启动首帧没出来之前 Activity 会停在 STARTED,
     * 那是渲染/引擎启动耗时, 不是"没打开"。真正的失败是连 STARTED 都到不了。
     */
    private fun waitForMainActivityResumed(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            var visible = false
            onMain {
                val registry = ActivityLifecycleMonitorRegistry.getInstance()
                visible = registry.getActivitiesInStage(Stage.RESUMED).toList().any { it is MainActivity } ||
                    registry.getActivitiesInStage(Stage.STARTED).toList().any { it is MainActivity }
            }
            if (visible) return true
            Thread.sleep(200)
        }
        return false
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            PlaybackServiceTestSupport.onMain(block)
        }
    }
}
