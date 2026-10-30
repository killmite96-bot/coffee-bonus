package com.coffeebonus.app;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;
import android.widget.Toast;

import java.io.File;

/**
 * Обновление приложения изнутри: скачивает APK системным загрузчиком и открывает установщик Android.
 * Подтвердить установку всё равно нужно вручную — это требование системы.
 */
final class AppUpdater {
    private final Activity activity;
    private long downloadId = -1;
    private BroadcastReceiver receiver;

    AppUpdater(Activity activity) {
        this.activity = activity;
    }

    /** Нужен адрес на APK (https). Вызывается с потока интерфейса. */
    void start(String url) {
        if (url == null || !url.startsWith("https://")) {
            return;
        }
        // Android требует отдельного разрешения «Установка неизвестных приложений» для нашего приложения
        if (Build.VERSION.SDK_INT >= 26 && !activity.getPackageManager().canRequestPackageInstalls()) {
            Toast.makeText(activity, "Разрешите установку из этого приложения и нажмите «Обновить» ещё раз",
                    Toast.LENGTH_LONG).show();
            Intent i = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + activity.getPackageName()));
            activity.startActivity(i);
            return;
        }
        try {
            File dir = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS);
            File old = new File(dir, "Kofe-karta-update.apk");
            if (old.exists()) {
                old.delete();
            }
            DownloadManager dm = (DownloadManager) activity.getSystemService(Context.DOWNLOAD_SERVICE);
            DownloadManager.Request req = new DownloadManager.Request(Uri.parse(url));
            req.setTitle("Обновление приложения");
            req.setMimeType("application/vnd.android.package-archive");
            req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            req.setDestinationUri(Uri.fromFile(old));
            downloadId = dm.enqueue(req);
            Toast.makeText(activity, "Скачиваем обновление…", Toast.LENGTH_SHORT).show();
            listen(dm);
        } catch (Exception e) {
            openInBrowser(url);
        }
    }

    private void listen(final DownloadManager dm) {
        if (receiver != null) {
            return;
        }
        receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                long id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1);
                if (id != downloadId) {
                    return;
                }
                stop();
                Uri apk = dm.getUriForDownloadedFile(id);
                if (apk == null) {
                    Toast.makeText(activity, "Не удалось скачать обновление", Toast.LENGTH_LONG).show();
                    return;
                }
                try {
                    Intent install = new Intent(Intent.ACTION_VIEW);
                    install.setDataAndType(apk, "application/vnd.android.package-archive");
                    install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
                    activity.startActivity(install);
                } catch (Exception e) {
                    Toast.makeText(activity, "Откройте скачанный файл из «Загрузок» и установите его",
                            Toast.LENGTH_LONG).show();
                }
            }
        };
        IntentFilter filter = new IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE);
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
        } else {
            activity.registerReceiver(receiver, filter);
        }
    }

    private void openInBrowser(String url) {
        try {
            activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception ignored) {
            // нет браузера — ничего не поделать
        }
    }

    void stop() {
        if (receiver != null) {
            try {
                activity.unregisterReceiver(receiver);
            } catch (Exception ignored) {
                // уже снят
            }
            receiver = null;
        }
    }
}
