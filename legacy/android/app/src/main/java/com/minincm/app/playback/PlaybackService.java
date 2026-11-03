package com.minincm.app.playback;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.IBinder;

import com.minincm.app.MainActivity;
import com.minincm.app.R;

import org.json.JSONObject;

/**
 * 播放前台服务: 唯一持有 MediaPlayer 的进程内单例。
 *
 * 为什么必须在前台服务: 音乐 App 切后台/锁屏后, 普通组件会被系统回收,
 * WebView 也可能被销毁, 但前台服务里的 MediaPlayer 不受影响 ——
 * JS 只负责把 URL 传进来, 播放生命周期完全由这里接管。
 */
public class PlaybackService extends Service {

    public static final String ACTION_PLAY = "com.minincm.app.PLAY";
    public static final String ACTION_PAUSE = "com.minincm.app.PAUSE";
    public static final String ACTION_RESUME = "com.minincm.app.RESUME";
    public static final String ACTION_SEEK = "com.minincm.app.SEEK";
    public static final String ACTION_STOP = "com.minincm.app.STOP";

    private static final String CHANNEL_ID = "playback";
    private static final int NOTIF_ID = 1001;

    private static PlaybackService instance;
    private static Runnable completionListener;

    private MediaPlayer mp;
    private String currentUrl;
    private String title = "";
    private String artist = "";
    private boolean preparing = false;
    private boolean paused = false;

    public static PlaybackService get() {
        return instance;
    }

    public static void setCompletionListener(Runnable r) {
        completionListener = r;
    }

    /** JS 轮询用的快照, 静态可调(可能 service 未启动) */
    public static String snapshot() {
        PlaybackService s = instance;
        if (s == null) {
            return "{\"state\":\"idle\",\"position\":0,\"duration\":0,\"title\":\"\",\"artist\":\"\"}";
        }
        return s.snap();
    }

    private String snap() {
        JSONObject o = new JSONObject();
        try {
            int pos = 0;
            int dur = 0;
            boolean playing = false;
            String st = "idle";
            if (mp != null) {
                try {
                    pos = mp.getCurrentPosition();
                } catch (Exception ignore) {
                }
                try {
                    dur = mp.getDuration();
                } catch (Exception ignore) {
                }
                playing = mp.isPlaying();
            }
            if (preparing) st = "preparing";
            else if (mp != null && !paused && playing) st = "playing";
            else if (mp != null && paused) st = "paused";
            else if (mp != null) st = "stopped";
            o.put("state", st);
            o.put("position", pos);
            o.put("duration", dur);
            o.put("title", title);
            o.put("artist", artist);
            o.put("url", currentUrl == null ? "" : currentUrl);
        } catch (Exception ignore) {
        }
        return o.toString();
    }

    // ---------- 生命周期 ----------

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        createChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || intent.getAction() == null) {
            return START_NOT_STICKY;
        }
        switch (intent.getAction()) {
            case ACTION_PLAY:
                play(intent.getStringExtra("url"), intent.getStringExtra("meta"));
                break;
            case ACTION_PAUSE:
                pause();
                break;
            case ACTION_RESUME:
                resume();
                break;
            case ACTION_SEEK:
                if (mp != null) {
                    try {
                        mp.seekTo(intent.getIntExtra("ms", 0));
                    } catch (Exception ignore) {
                    }
                }
                break;
            case ACTION_STOP:
                stopPlayback();
                stopForeground(STOP_FOREGROUND_REMOVE);
                stopSelf();
                break;
        }
        return START_NOT_STICKY;
    }

    private void play(String url, String metaJson) {
        if (url == null) return;
        if (metaJson != null) {
            try {
                JSONObject m = new JSONObject(metaJson);
                title = m.optString("title", "");
                artist = m.optString("artist", "");
            } catch (Exception ignore) {
            }
        }
        currentUrl = url;
        paused = false;
        preparing = true;
        notifyState();

        try {
            if (mp == null) {
                mp = new MediaPlayer();
                mp.setAudioAttributes(new AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .build());
                mp.setOnPreparedListener(m -> {
                    preparing = false;
                    m.start();
                    notifyState();
                });
                mp.setOnCompletionListener(m -> {
                    paused = false;
                    notifyState();
                    if (completionListener != null) {
                        completionListener.run();
                    }
                });
                mp.setOnErrorListener((m, what, extra) -> {
                    preparing = false;
                    stopSelf();
                    return true;
                });
            } else {
                mp.reset();
            }
            mp.setDataSource(url);
            mp.prepareAsync();
        } catch (Exception e) {
            preparing = false;
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
        }
    }

    private void pause() {
        paused = true;
        if (mp != null && mp.isPlaying()) {
            mp.pause();
        }
        notifyState();
    }

    private void resume() {
        paused = false;
        if (mp != null && !mp.isPlaying()) {
            mp.start();
        }
        notifyState();
    }

    private void stopPlayback() {
        paused = false;
        if (mp != null) {
            try {
                mp.reset();
            } catch (Exception ignore) {
            }
        }
        notifyState();
    }

    // ---------- 通知 ----------

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_ID, "播放", NotificationManager.IMPORTANCE_LOW);
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) nm.createNotificationChannel(ch);
        }
    }

    private void notifyState() {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Intent toggle = new Intent(this, PlaybackService.class);
        toggle.setAction(paused ? ACTION_RESUME : ACTION_PAUSE);
        PendingIntent togglePi = PendingIntent.getService(this, 1, toggle,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        b.setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle(title.isEmpty() ? "轻音" : title)
                .setContentText(artist)
                .setOngoing(true)
                .setContentIntent(pi)
                .addAction(paused ? android.R.drawable.ic_media_play : android.R.drawable.ic_media_pause,
                        paused ? "播放" : "暂停", togglePi);

        Notification n = b.build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        if (mp != null) {
            try {
                mp.release();
            } catch (Exception ignore) {
            }
            mp = null;
        }
        instance = null;
        super.onDestroy();
    }
}
