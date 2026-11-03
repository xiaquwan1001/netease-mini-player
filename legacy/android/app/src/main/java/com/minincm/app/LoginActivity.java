package com.minincm.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * 网页登录 Activity: 加载网易云官方网页登录页(零风控的官方登录通道),
 * 用户扫码后从 CookieManager 抓取 MUSIC_U 保存, 完成后自动关闭。
 *
 * 背景: API 扫码登录接口(/eapi/login/qrcode/client/login)在网页端形态下
 * 会被 8821"安全环境风险"风控拦截, 官方网页登录页无此问题(与 Ncrust 同方案)。
 */
public class LoginActivity extends Activity {

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        WebView wv = new WebView(this);
        WebSettings s = wv.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        // 关键: 不要伪造桌面 UA。用设备默认(移动)UA, music.163.com 才会给出
        // 移动端授权页(官方 App 风格, 手机号/QQ/微信都能用); 伪装 PC Chrome 会拿到
        // 那个又重又小的桌面 SPA 登录页, 二级登录还加载不出来。
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true);
        CookieManager.getInstance().setAcceptCookie(true);

        // 重新登录前清掉旧登录态(避免误判)
        CookieManager.getInstance().removeAllCookies(null);

        wv.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                android.util.Log.i("MiniNCM", "login page finished: " + url);
                tryCapture(view);
                // 桌面版页面上有播放条/页脚, 移动版没有; 注入也无害
                view.evaluateJavascript(
                        "(function(){var css='#g_player,.g-player,#g_footer,.m-footer,.f-faq{display:none!important;}';"
                        + "var s=document.createElement('style');s.textContent=css;document.head.appendChild(s);})();", null);
            }
        });

        // 用无 hash 的 /login: 移动 UA 下服务端 302 到 https://y.music.163.com/m/login,
        // 那才是官方移动端授权页(手机号/QQ/微信/扫码都在里面)。
        // 带 "#/login" 是桌面 SPA 的路由, 移动 UA 下只会得到白屏。
        wv.loadUrl("https://music.163.com/login");
        setContentView(wv);

        // 移动端登录会在多个页面间跳转(手机号/QQ/微信/扫码), 轮询 cookie 更稳
        startCookieWatch(wv);
    }

    /** 每 800ms 检查一次 MUSIC_U, 出现即保存并关闭 */
    private void startCookieWatch(WebView wv) {
        final android.os.Handler h = new android.os.Handler(getMainLooper());
        final Runnable[] task = new Runnable[1];
        task[0] = new Runnable() {
            @Override
            public void run() {
                String cookie = CookieManager.getInstance().getCookie("https://music.163.com");
                if (cookie != null && cookie.contains("MUSIC_U=")) {
                    String mus = extractCookie(cookie, "MUSIC_U");
                    if (mus != null && !mus.isEmpty()) {
                        SharedPreferences sp = getSharedPreferences("mini_ncm", MODE_PRIVATE);
                        sp.edit().putString("ncm.music_u", mus).commit();
                        CookieManager.getInstance().flush();
                        android.util.Log.i("MiniNCM", "登录成功, MUSIC_U 已保存");
                        finish();
                        return;
                    }
                }
                h.postDelayed(task[0], 800);
            }
        };
        h.postDelayed(task[0], 800);
    }

    private void tryCapture(WebView view) {
        String cookie = CookieManager.getInstance().getCookie("https://music.163.com");
        if (cookie == null) return;
        String mus = extractCookie(cookie, "MUSIC_U");
        if (mus != null && !mus.isEmpty()) {
            SharedPreferences sp = getSharedPreferences("mini_ncm", MODE_PRIVATE);
            sp.edit().putString("ncm.music_u", mus).commit();
            CookieManager.getInstance().flush();
            android.util.Log.i("MiniNCM", "登录成功, MUSIC_U 已保存");
            finish();
        }
    }

    private String extractCookie(String cookie, String name) {
        for (String part : cookie.split(";")) {
            String p = part.trim();
            if (p.startsWith(name + "=")) {
                return p.substring(name.length() + 1);
            }
        }
        return null;
    }
}
