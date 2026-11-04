package com.minincm.minincm

import android.app.Activity
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
import android.widget.ProgressBar

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
class LoginActivity : Activity() {
    private lateinit var webView: WebView
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
        CookieManager.getInstance().setAcceptCookie(true)

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
            // 允许 adb 指定别的 URL(排查网络/区域差异用):
            //   adb shell am start -n com.minincm.minincm/.LoginActivity --es url https://y.music.163.com/m/login
            loadUrl(intent?.getStringExtra(EXTRA_URL) ?: LOGIN_URL)
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        val root = FrameLayout(this).apply {
            addView(webView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(
                loadingBar,
                FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER),
            )
        }
        setContentView(root)
        handler.postDelayed(cookiePoll, POLL_MS)
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

    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
            return
        }
        // 用户放弃登录也要把已拿到的 cookie 交回去(可能已经登录成功但页面还没跳)
        setResult(RESULT_CANCELED, Intent().putExtra(EXTRA_COOKIE, collectCookies()))
        super.onBackPressed()
    }

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
        private const val POLL_MS = 1500L
        private val COOKIE_URLS = listOf("https://music.163.com", "https://163.com")
    }
}
