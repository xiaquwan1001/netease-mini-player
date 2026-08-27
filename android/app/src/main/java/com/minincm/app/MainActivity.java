package com.minincm.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.os.Bundle;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import com.minincm.app.bridge.AppBridge;
import com.minincm.app.playback.PlaybackService;

/**
 * 壳 Activity: 只负责承载 WebView + 注册 JS 桥。
 * 所有业务逻辑(登录/搜索/播放控制/插件)都在 assets/www 的前端 SPA 里。
 * 原生层只提供三样东西: HTTP IO(桥)、存储(桥)、播放(前台服务)。
 */
public class MainActivity extends Activity {

    private WebView webView;
    private AppBridge bridge;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        webView = new WebView(this);
        setContentView(webView);

        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        // 关键: 允许媒体自动播放(JS 拿到 URL 后直接触发播放)
        s.setMediaPlaybackRequiresUserGesture(false);
        // 关键: file:// 页面允许跨域 fetch(前端用 Chromium 网络栈调 API,
        // 绕开安卓 HttpURLConnection 被网易云 TLS 指纹风控的问题)
        s.setAllowUniversalAccessFromFileURLs(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(false);

        bridge = new AppBridge(this, webView);
        webView.addJavascriptInterface(bridge, "Native");

        webView.setWebViewClient(new WebViewClient());

        // 播放完成/状态事件 -> JS
        PlaybackService.setCompletionListener(() -> {
            runOnUiThread(() -> {
                if (webView != null) {
                    webView.evaluateJavascript(
                            "window.__nativeEvent && window.__nativeEvent('ended', {})", null);
                }
            });
        });

        webView.loadUrl("file:///android_asset/www/index.html");
    }

    @Override
    protected void onResume() {
        super.onResume();
        // 网页登录返回后通知前端重新检查登录态
        if (webView != null) {
            webView.evaluateJavascript(
                    "window.__nativeEvent && window.__nativeEvent('loginStateChanged')", null);
        }
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        PlaybackService.setCompletionListener(null);
        if (webView != null) {
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
