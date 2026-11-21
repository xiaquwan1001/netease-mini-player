package com.minincm.minincm

import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.content.ContextCompat

/**
 * 官方网页登录页(移动端授权页).
 *
 * 为什么不自己实现原生登录: 网易云 eapi/weapi 扫码在用户确认后必返 8821 安全环境风险,
 * 那是绑定"完成验证的客户端"的交互式风控; 官方网页登录是零风控路径。
 *
 * 两个关键细节(踩过):
 * 1. **不伪造桌面 UA**: 桌面 UA 会打开桌面 SPA, 手机号/二维码二级页加载不出来;
 *    设备默认移动 UA + 无 hash 的 /login 会 302 到 y.music.163.com/m/login 官方授权页。
 * 2. 登录成功的唯一判据是 music.163.com 域下出现 MUSIC_U cookie;
 *    页面文案/跳转都不可靠, 所以要轮询 cookie。
 */
class LoginActivity : ComponentActivity() {
    private lateinit var webView: WebView

    /**
     * 返回键/返回手势 = 放弃登录(与顶栏「关闭」同一个出口)。
     *
     * 2026-11-18: 从 `override onBackPressed()` 迁到 OnBackPressedDispatcher ——
     * targetSdk 36 起预测性返回默认开启, 系统**不再调用** onBackPressed(lint
     * `GestureBackNavigation` 报错那一条), 旧写法在 Android 16 上会“返回键没反应”。
     */
    private val backCallback = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() {
            finishCancelled()
        }
    }
    private lateinit var loadingBar: ProgressBar
    private val handler = Handler(Looper.getMainLooper())
    private var finishedWithCookie = false

    private val cookiePoll = object : Runnable {
        override fun run() {
            if (finishedWithCookie) return
            if (maybeFinishWithCookie()) return
            handler.postDelayed(this, POLL_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        onBackPressedDispatcher.addCallback(this, backCallback)
        CookieManager.getInstance().setAcceptCookie(true)
        val loginUrl = intent?.getStringExtra(EXTRA_URL) ?: LOGIN_URL

        loadingBar = ProgressBar(this).apply { visibility = ProgressBar.GONE }

        webView = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.loadsImagesAutomatically = true
            webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                    loadingBar.visibility = ProgressBar.VISIBLE
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    loadingBar.visibility = ProgressBar.GONE
                    maybeFinishWithCookie()
                }
            }
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        // 顶栏: 官方登录页是个 SPA, 页内 history 很深, 系统返回键只会一页页退网页,
        // 用户永远退不出去(2026-11 用户报"登录页无法返回")。这里给一条明确的「关闭」,
        // 系统返回键也直接关闭本页(放弃登录)。
        val web = FrameLayout(this).apply {
            addView(webView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(
                loadingBar,
                FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER),
            )
        }
        // P-09: 顶栏配色改从资源取(values/values-night 各一份), 不再硬编码浅色,
        // 夜间打开登录页不再整屏闪白。资源名与主题 LoginTheme 用的是同一组 @color。
        val headerBg = ContextCompat.getColor(this, R.color.login_chrome_bg)
        val headerFg = ContextCompat.getColor(this, R.color.login_chrome_fg)
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), 0, dp(4), 0)
            setBackgroundColor(headerBg)
        }
        header.addView(
            TextView(this).apply {
                text = "登录网易云音乐"
                textSize = 16f
                setTextColor(headerFg)
                layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
            },
        )
        header.addView(
            TextView(this).apply {
                text = "关闭"
                textSize = 16f
                setTextColor(headerFg)
                gravity = Gravity.CENTER
                setPadding(dp(16), dp(14), dp(16), dp(14))
                setOnClickListener { finishCancelled() }
            },
        )
        // WebView 页面本身就是白底网页; 这里把「页面还没画出来」的空窗也染成顶栏色,
        // 否则夜间会在顶栏下方再闪一块白。
        webView.setBackgroundColor(headerBg)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(headerBg)
        }
        root.addView(header, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(web, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        setContentView(root)

        // 登录 cookie 的清理**只在这一处**(P-08): 已登录状态下 WebView 里还留着上一个账号的
        // MUSIC_U, 页面会直接判定"已登录"并原地返回 —— "想加第二个账号却立刻跳回来"的根因.
        // 账号簿保存在 Rust 侧, 清 WebView cookie 不影响已记住的账号。
        //
        // 2026-11-21(#5 回归): 以前这里是无差别 removeAllCookies, 把网易自己的
        // "这台设备登录过谁"的证据(设备指纹 / 记住上次账号)一起清了 ⇒ 官方登录页每次都
        // 当新设备, 用户报"以前有一键手机号/输后四位继续, 现在必须完整手机号 + 验证码"。
        // 现在只删**登录凭据键**(见 LoginCookiePolicy), 设备指纹与 __remember_me 留着。
        //
        // 兜底: 分键删除在不同机型/域 cookie 上未必一次到位; 删完再查一遍, 还看得到
        // 登录凭据就仍然整体清空 —— 宁可丢"记住账号", 也不能让 P-08 回归(旧账号自动登录)。
        // removeAllCookies 是**异步**的: loadUrl 必须放进它的回调里, 否则页面会先加载并把
        // 新的 MUSIC_U 写进 cookie 仓库, 随后的清理再把它吃掉(取决于机型时序)。
        // MainActivity 的 loginWeb 只负责 startActivity, 不再清一遍。
        val manager = CookieManager.getInstance()
        clearLoginCookies(manager)
        if (hasLoginCookieLeft(manager)) {
            manager.removeAllCookies {
                manager.flush()
                loadLoginPage(loginUrl)
            }
        } else {
            manager.flush()
            loadLoginPage(loginUrl)
        }
        handler.postDelayed(cookiePoll, POLL_MS)
    }

    /** 只删登录凭据键, 保留设备指纹与"记住上次账号"类 cookie(#5). */
    private fun clearLoginCookies(manager: CookieManager) {
        for (url in COOKIE_URLS) {
            val raw = manager.getCookie(url) ?: continue
            val host = url.substringAfter("://", url)
            for (key in LoginCookiePolicy.keysToClear(raw)) {
                // 网易写的是域 cookie(.163.com / .music.163.com): 只按 host 写过期的
                // Set-Cookie 删不掉, 所以 host-only 与 Domain=.<当前域> 各写一次。
                manager.setCookie(url, "$key=; Max-Age=0; Path=/")
                manager.setCookie(url, "$key=; Domain=.$host; Max-Age=0; Path=/")
            }
        }
    }

    /** 分键清理之后还残留登录凭据吗(是 ⇒ 走整体清空兜底). */
    private fun hasLoginCookieLeft(manager: CookieManager): Boolean =
        COOKIE_URLS.any { url ->
            val raw = manager.getCookie(url) ?: return@any false
            LoginCookiePolicy.hasLoginCookie(raw)
        }

    /** 加载登录页(带"页面已经关了"守卫). */
    private fun loadLoginPage(url: String) {
        if (isFinishing || isDestroyed || !::webView.isInitialized) return
        // 允许 adb 指定别的 URL(排查网络/区域差异用):
        //   adb shell am start -n com.minincm.minincm/.LoginActivity --es url https://y.music.163.com/m/login
        webView.loadUrl(url)
    }

    /** 返回 true 表示已拿到登录态并结束页面 */
    private fun maybeFinishWithCookie(): Boolean {
        val cookies = collectCookies()
        if (!cookies.contains("MUSIC_U=")) return false
        finishedWithCookie = true
        setResult(RESULT_OK, Intent().putExtra(EXTRA_COOKIE, cookies))
        finish()
        return true
    }

    private fun collectCookies(): String {
        val manager = CookieManager.getInstance()
        // MUSIC_U 可能落在 .music.163.com 或 .163.com, 两个域都取并去重
        val parts = LinkedHashSet<String>()
        for (url in COOKIE_URLS) {
            manager.getCookie(url)?.split(';')?.forEach { piece ->
                val trimmed = piece.trim()
                if (trimmed.isNotEmpty()) parts.add(trimmed)
            }
        }
        return parts.joinToString("; ")
    }

    /**
     * 用户主动关闭登录页(顶栏「关闭」/系统返回键): 放弃登录。
     *
     * **不要回传 cookie**: 之前这里把 collectCookies() 塞进 RESULT_CANCELED 的返回里,
     * 上层(Host)只取 extra 不看 resultCode, 于是"已有账号 + 打开登录页后直接关闭"
     * 会把旧/半成品 cookie 当成一次登录提交(用户反馈的假成功提示)。
     */
    private fun finishCancelled() {
        if (finishedWithCookie) return
        finishedWithCookie = true
        setResult(RESULT_CANCELED)
        finish()
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }

    companion object {
        const val EXTRA_COOKIE = "cookie"
        const val EXTRA_URL = "url"
        const val REQUEST_CODE = 7001

        /** 移动端授权页(官方 302 目标); 不要用带 #/login 的桌面路由 */
        private const val LOGIN_URL = "https://music.163.com/login"

        /** 顶栏配色见 res/values{,-night}/colors.xml(login_chrome_bg / login_chrome_fg) */
        private const val POLL_MS = 1500L
        private val COOKIE_URLS = listOf("https://music.163.com", "https://163.com")
    }
}
