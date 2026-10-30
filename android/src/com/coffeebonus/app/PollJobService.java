package com.coffeebonus.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Фоновая проверка новых сообщений (покупки, акции, сгорание бонусов) без сервисов Google.
 * Раз в ~15 минут спрашивает у базы, есть ли новое для клиента, и показывает обычное уведомление.
 * Работает, пока клиент вошёл в приложении. Телефоны с агрессивной экономией батареи могут откладывать запуск.
 */
public class PollJobService extends JobService {
    static final int JOB_ID = 4711;
    static final String CHANNEL = "bonus";
    private volatile boolean stopped;

    /** Включает периодическую проверку (вызывается после входа клиента). */
    static void schedule(Context ctx) {
        JobScheduler js = (JobScheduler) ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        JobInfo job = new JobInfo.Builder(JOB_ID, new ComponentName(ctx, PollJobService.class))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .build();
        js.schedule(job);
    }

    static void cancel(Context ctx) {
        JobScheduler js = (JobScheduler) ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        js.cancel(JOB_ID);
    }

    static void ensureChannel(Context ctx) {
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Бонусы и акции",
                    NotificationManager.IMPORTANCE_DEFAULT));
        }
    }

    @Override
    public boolean onStartJob(final JobParameters params) {
        stopped = false;
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    poll();
                } catch (Exception ignored) {
                    // нет связи или сервер недоступен — попробуем в следующий раз
                }
                jobFinished(params, false);
            }
        }).start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        stopped = true;
        return true;
    }

    private void poll() throws Exception {
        SharedPreferences p = getSharedPreferences("app", MODE_PRIVATE);
        String token = p.getString("session_token", "");
        String api = p.getString("api_url", "");
        String key = p.getString("api_key", "");
        if (token.isEmpty() || api.isEmpty() || key.isEmpty()) {
            return;
        }
        long last = p.getLong("seen_id", -1);
        JSONObject body = new JSONObject();
        body.put("p_token", token);
        body.put("p_after", last < 0 ? JSONObject.NULL : (Object) Long.valueOf(last));

        HttpURLConnection c = (HttpURLConnection) new URL(api.replaceAll("/$", "") + "/rest/v1/rpc/my_messages").openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(20000);
        c.setRequestMethod("POST");
        c.setRequestProperty("apikey", key);
        c.setRequestProperty("Content-Type", "application/json");
        c.setDoOutput(true);
        OutputStream os = c.getOutputStream();
        os.write(body.toString().getBytes("UTF-8"));
        os.close();
        int code = c.getResponseCode();
        if (code == 401) {                         // сессия истекла — до нового входа не опрашиваем
            p.edit().remove("session_token").apply();
            return;
        }
        if (code != 200) {
            return;
        }
        InputStream in = c.getInputStream();
        java.io.ByteArrayOutputStream buf = new java.io.ByteArrayOutputStream();
        byte[] b = new byte[4096];
        int n;
        while ((n = in.read(b)) > 0) {
            buf.write(b, 0, n);
        }
        JSONObject res = new JSONObject(buf.toString("UTF-8"));
        long newLast = res.optLong("last_id", last);
        if (last >= 0 && !stopped && !MainActivity.foreground) {   // в открытом приложении сообщения показывает страница
            JSONArray items = res.optJSONArray("items");
            for (int i = 0; items != null && i < items.length(); i++) {
                JSONObject m = items.getJSONObject(i);
                show(m.optLong("id"), m.optString("title"), m.optString("body"));
            }
        }
        if (newLast > last && !(MainActivity.foreground && last >= 0)) {
            p.edit().putLong("seen_id", newLast).apply();
        }
    }

    private void show(long id, String title, String text) {
        ensureChannel(this);
        Intent open = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build();
        ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE)).notify((int) (id % 100000), n);
    }
}
