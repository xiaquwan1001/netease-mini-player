package com.minincm.app.bridge;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import com.minincm.app.playback.PlaybackService;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * JS <-> 原生桥。
 *
 * 设计原则: 原生只做 IO 和播放, 业务逻辑全部在前端。
 *  - httpPost: 无 CORS 限制的 HTTP POST (cookie/加密头由 JS 全权构造)
 *  - store*:   SharedPreferences 持久化 (登录态/cookie)
 *  - play*:    转发给前台播放服务 (MediaPlayer)
 *  - getState: 播放器状态轮询
 */
public class AppBridge {

    private final android.app.Activity activity;
    private final Context ctx;
    private final WebView webView;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newFixedThreadPool(2);
    private final SharedPreferences sp;

    public AppBridge(android.app.Activity activity, WebView webView) {
        this.activity = activity;
        this.ctx = activity.getApplicationContext();
        this.webView = webView;
        this.sp = this.ctx.getSharedPreferences("mini_ncm", Context.MODE_PRIVATE);
    }

    // ---------- HTTP ----------

    @JavascriptInterface
    public void httpPost(String url, String headersJson, String body, int cbId) {
        io.execute(() -> {
            String result;
            try {
                result = doPost(url, headersJson, body);
            } catch (Exception e) {
                JSONObject err = new JSONObject();
                try {
                    err.put("error", String.valueOf(e.getMessage()));
                } catch (Exception ignore) {
                }
                result = err.toString();
            }
            final String r = result;
            main.post(() -> {
                if (webView != null) {
                    webView.evaluateJavascript(
                            "window.__nativeCb && window.__nativeCb(" + cbId + ", " + r + ")", null);
                }
            });
        });
    }

    private String doPost(String url, String headersJson, String body) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(20000);
        conn.setDoOutput(true);
        // 关闭重定向跟随, 手动处理 (保留原始状态码)
        conn.setInstanceFollowRedirects(false);

        // TLS 指纹风控绕过: 网易云拦截"裸 Conscrypt/Chromium 默认指纹"的 TLS 握手(实测空响应),
        // 但放行 OkHttp 的指纹(官方 App 同款)。这里把 HttpURLConnection 的 SSL 层包装成
        // OkHttp 风格的 cipher 列表, 模拟官方指纹 —— 零依赖方案。
        if (conn instanceof HttpsURLConnection) {
            javax.net.ssl.SSLContext ctx = javax.net.ssl.SSLContext.getInstance("TLS");
            ctx.init(null, null, null);
            ((HttpsURLConnection) conn).setSSLSocketFactory(
                    new OkHttpStyleSSLSocketFactory(ctx.getSocketFactory()));
        }

        if (headersJson != null && !headersJson.isEmpty()) {
            JSONObject h = new JSONObject(headersJson);
            for (java.util.Iterator<String> it = h.keys(); it.hasNext(); ) {
                String k = it.next();
                conn.setRequestProperty(k, h.getString(k));
            }
        }
        if (body != null && !body.isEmpty()) {
            byte[] data = body.getBytes(StandardCharsets.UTF_8);
            conn.setFixedLengthStreamingMode(data.length);
            try (OutputStream os = conn.getOutputStream()) {
                os.write(data);
            }
        }

        int status = conn.getResponseCode();
        InputStream is = status >= 400 ? conn.getErrorStream() : conn.getInputStream();
        StringBuilder sb = new StringBuilder();
        if (is != null) {
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(is, StandardCharsets.UTF_8))) {
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line).append('\n');
                }
            }
        }

        // 诊断日志: 记录实际响应
        android.util.Log.i("MiniNCM", "httpPost " + url + " -> status=" + status
                + " bytes=" + sb.length()
                + " body=" + sb.toString().substring(0, Math.min(200, sb.length()))
                + " set-cookie=" + conn.getHeaderField("Set-Cookie"));

        JSONObject out = new JSONObject();
        out.put("status", status);
        JSONObject respHeaders = new JSONObject();
        for (Map.Entry<String, List<String>> e : conn.getHeaderFields().entrySet()) {
            if (e.getKey() == null) continue;
            String v = String.join("; ", e.getValue());
            // 保留所有 set-cookie (可能多个, 逗号分隔拼接)
            if ("Set-Cookie".equalsIgnoreCase(e.getKey())) {
                v = String.join(", ", e.getValue());
            }
            respHeaders.put(e.getKey(), v);
        }
        out.put("headers", respHeaders);
        out.put("body", sb.toString());
        conn.disconnect();
        return out.toString();
    }

    // ---------- 存储 ----------

    @JavascriptInterface
    public String storeGet(String key) {
        return sp.getString(key, null);
    }

    @JavascriptInterface
    public void storeSet(String key, String value) {
        sp.edit().putString(key, value).commit();
    }

    @JavascriptInterface
    public void storeRemove(String key) {
        sp.edit().remove(key).commit();
    }

    // ---------- WebView Cookie 读取(fetch 模式下 Set-Cookie 对 JS 不可见, 主动同步) ----------

    @JavascriptInterface
    public String cookieGet(String domain) {
        try {
            String cs = android.webkit.CookieManager.getInstance().getCookie(domain);
            return cs == null ? "" : cs;
        } catch (Exception e) {
            return "";
        }
    }

    // ---------- 播放 ----------

    @JavascriptInterface
    public void play(String url, String metaJson) {
        Intent i = new Intent(ctx, PlaybackService.class);
        i.setAction(PlaybackService.ACTION_PLAY);
        i.putExtra("url", url);
        i.putExtra("meta", metaJson);
        ctx.startForegroundService(i);
    }

    @JavascriptInterface
    public void pause() {
        ctx.startService(new Intent(ctx, PlaybackService.class)
                .setAction(PlaybackService.ACTION_PAUSE));
    }

    @JavascriptInterface
    public void resume() {
        ctx.startService(new Intent(ctx, PlaybackService.class)
                .setAction(PlaybackService.ACTION_RESUME));
    }

    @JavascriptInterface
    public void seekTo(int ms) {
        ctx.startService(new Intent(ctx, PlaybackService.class)
                .setAction(PlaybackService.ACTION_SEEK)
                .putExtra("ms", ms));
    }

    @JavascriptInterface
    public void stop() {
        ctx.startService(new Intent(ctx, PlaybackService.class)
                .setAction(PlaybackService.ACTION_STOP));
    }

    @JavascriptInterface
    public String getState() {
        return PlaybackService.snapshot();
    }

    // ---------- 提示 ----------

    @JavascriptInterface
    public void toast(final String msg) {
        main.post(() -> android.widget.Toast.makeText(ctx, msg, android.widget.Toast.LENGTH_SHORT).show());
    }

    @JavascriptInterface
    public void log(String msg) {
        android.util.Log.i("MiniNCM", msg);
    }

    // ---------- 网页登录 ----------

    /** 打开官方网页登录页(零风控通道, 登录后 MUSIC_U 存入 ncm.music_u) */
    @JavascriptInterface
    public void loginWeb() {
        main.post(() -> {
            if (activity != null && !activity.isFinishing()) {
                activity.startActivity(new android.content.Intent(activity, com.minincm.app.LoginActivity.class));
            }
        });
    }

    // ---------- TLS 指纹模拟(OkHttp 风格, 官方 App 同款) ----------

    /** OkHttp 3.x MODERN_TLS 的 cipher 套件列表(顺序即指纹) */
    private static final String[] OKHTTP_CIPHERS = {
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
            "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
            "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
            "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
            "TLS_RSA_WITH_AES_128_GCM_SHA256",
            "TLS_RSA_WITH_AES_256_GCM_SHA384",
            "TLS_RSA_WITH_AES_128_CBC_SHA",
            "TLS_RSA_WITH_AES_256_CBC_SHA",
            "TLS_RSA_WITH_3DES_EDE_CBC_SHA",
    };

    /** 包装 SSLSocketFactory: 仅暴露 OkHttp 风格的 cipher 列表, 让 ClientHello 指纹贴近官方 App */
    static class OkHttpStyleSSLSocketFactory extends javax.net.ssl.SSLSocketFactory {
        private final javax.net.ssl.SSLSocketFactory delegate;

        OkHttpStyleSSLSocketFactory(javax.net.ssl.SSLSocketFactory delegate) {
            this.delegate = delegate;
        }

        private java.net.Socket configure(java.net.Socket socket) {
            if (socket instanceof javax.net.ssl.SSLSocket) {
                javax.net.ssl.SSLSocket ssl = (javax.net.ssl.SSLSocket) socket;
                try {
                    // 取双方支持的 cipher 交集, 保持 OkHttp 顺序
                    java.util.List<String> supported =
                            java.util.Arrays.asList(ssl.getSupportedCipherSuites());
                    java.util.List<String> enabled = new java.util.ArrayList<>();
                    for (String c : OKHTTP_CIPHERS) {
                        if (supported.contains(c)) enabled.add(c);
                    }
                    ssl.setEnabledCipherSuites(enabled.toArray(new String[0]));
                } catch (Exception ignore) {
                }
            }
            return socket;
        }

        @Override
        public String[] getDefaultCipherSuites() { return delegate.getDefaultCipherSuites(); }
        @Override
        public String[] getSupportedCipherSuites() { return delegate.getSupportedCipherSuites(); }
        @Override
        public java.net.Socket createSocket(java.net.Socket s, String h, int p, boolean a) throws java.io.IOException {
            return configure(delegate.createSocket(s, h, p, a));
        }
        @Override
        public java.net.Socket createSocket(String h, int p) throws java.io.IOException {
            return configure(delegate.createSocket(h, p));
        }
        @Override
        public java.net.Socket createSocket(String h, int p, java.net.InetAddress lh, int lp) throws java.io.IOException {
            return configure(delegate.createSocket(h, p, lh, lp));
        }
        @Override
        public java.net.Socket createSocket(java.net.InetAddress h, int p) throws java.io.IOException {
            return configure(delegate.createSocket(h, p));
        }
        @Override
        public java.net.Socket createSocket(java.net.InetAddress h, int p, java.net.InetAddress lh, int lp) throws java.io.IOException {
            return configure(delegate.createSocket(h, p, lh, lp));
        }
    }
}
