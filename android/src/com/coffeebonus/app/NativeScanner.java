package com.coffeebonus.app;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.hardware.Camera;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.TextView;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;

import java.util.Collections;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Родной сканер QR: камера приложения с автофокусом и высоким разрешением, распознавание — ZXing.
 * Видео не идёт через WebView, поэтому нет «пикселей» и тормозов, которые бывают у живого видео в браузере.
 */
public class NativeScanner implements SurfaceHolder.Callback, Camera.PreviewCallback {
    public interface Listener {
        void onResult(String text);

        void onError(String message);
    }

    private static final int MAX_PIXELS = 1920 * 1080;   // выше — распознавание медленнее, а QR читается и так

    private final Activity activity;
    private final ViewGroup parent;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final QRCodeReader reader = new QRCodeReader();
    private final Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
    private ExecutorService worker;

    private FrameLayout overlay;
    private SurfaceView surface;
    private TextView info;
    private Camera camera;
    private int previewW, previewH;
    private boolean autoFocusLoop;
    private volatile boolean active, busy;

    // У многих телефонов несколько задних камер (основная, сверхширокая, макро, глубина).
    // Лучшая выбирается автоматически (см. chooseCamera); результат замеров запоминается.
    private final android.content.SharedPreferences prefs;
    private int currentId = 0;

    public NativeScanner(Activity activity, ViewGroup parent, Listener listener) {
        this.activity = activity;
        this.parent = parent;
        this.listener = listener;
        this.prefs = activity.getSharedPreferences("scanner", Context.MODE_PRIVATE);
        hints.put(DecodeHintType.POSSIBLE_FORMATS, Collections.singletonList(BarcodeFormat.QR_CODE));
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
    }

    public boolean isOpen() {
        return overlay != null;
    }

    public void show() {
        if (overlay != null) {
            return;
        }
        try {
            prepareCamera();
            worker = Executors.newSingleThreadExecutor();
            buildUi();
            active = true;
        } catch (Throwable e) {
            // что бы ни пошло не так — не роняем приложение, страница переключится на обычный сканер
            close();
            listener.onError("Родная камера недоступна.");
        }
    }

    public void close() {
        active = false;
        main.removeCallbacksAndMessages(null);
        release();
        if (worker != null) {
            worker.shutdownNow();
            worker = null;
        }
        if (overlay != null) {
            parent.removeView(overlay);
            overlay = null;
        }
    }

    // ---------------------------------------------------------------- камера

    /**
     * Оценка задней камеры: чем выше, тем лучше подходит для чтения QR.
     * Учитываем размер снимка (основная камера — самая «мегапиксельная», у макро и глубины 2 Мп),
     * наличие постоянного автофокуса (у камер глубины и части сверхшироких его нет)
     * и номер 0 — это камера по умолчанию, которую производитель делает основной.
     */
    private long scoreCamera(int id) {
        long cached = prefs.getLong("v2_score_" + id, 0);
        if (cached > 0) {
            return cached;
        }
        Camera c = null;
        try {
            c = Camera.open(id);
            Camera.Parameters p = c.getParameters();
            long area = 0;
            for (Camera.Size s : p.getSupportedPictureSizes()) {
                area = Math.max(area, (long) s.width * s.height);
            }
            List<String> modes = p.getSupportedFocusModes();
            boolean autofocus = modes != null && modes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
            long score = area * (autofocus ? 4 : 1) * (id == 0 ? 2 : 1);
            if (score > 0) {
                prefs.edit().putLong("v2_score_" + id, score).apply();   // запоминаем только удачные замеры
            }
            return score;
        } catch (Exception e) {
            return 0;   // камера не открылась (занята или недоступна) — не выбираем её
        } finally {
            if (c != null) {
                c.release();
            }
        }
    }

    /** Берём заднюю камеру с лучшей оценкой; если ни одну оценить не удалось — камеру по умолчанию. */
    private void chooseCamera() {
        long bestScore = 0;
        int bestId = -1;
        Camera.CameraInfo ci = new Camera.CameraInfo();
        for (int i = 0; i < Camera.getNumberOfCameras(); i++) {
            Camera.getCameraInfo(i, ci);
            if (ci.facing == Camera.CameraInfo.CAMERA_FACING_BACK) {
                long s = scoreCamera(i);
                if (s > bestScore) {
                    bestScore = s;
                    bestId = i;
                }
            }
        }
        currentId = bestId >= 0 ? bestId : 0;
    }

    private void prepareCamera() {
        chooseCamera();
        int id = currentId;
        camera = Camera.open(id);
        Camera.Parameters p = camera.getParameters();

        Camera.Size best = null;
        for (Camera.Size s : p.getSupportedPreviewSizes()) {
            if (s.width * s.height <= MAX_PIXELS && (best == null || s.width * s.height > best.width * best.height)) {
                best = s;
            }
        }
        if (best == null) {
            best = p.getPreviewSize();
        }
        previewW = best.width;
        previewH = best.height;
        p.setPreviewSize(previewW, previewH);

        List<String> modes = p.getSupportedFocusModes();
        if (modes != null && modes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
            p.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);   // постоянная резкость
        } else if (modes != null && modes.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
            p.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO);
            autoFocusLoop = true;
        }
        try {
            camera.setParameters(p);
        } catch (RuntimeException e) {
            // некоторые камеры не принимают набор параметров целиком — оставляем настройки по умолчанию
            Camera.Size def = camera.getParameters().getPreviewSize();
            previewW = def.width;
            previewH = def.height;
        }

        camera.setDisplayOrientation(displayOrientation(id));
    }

    private int displayOrientation(int cameraId) {
        Camera.CameraInfo info = new Camera.CameraInfo();
        Camera.getCameraInfo(cameraId, info);
        int degrees = 0;
        switch (activity.getWindowManager().getDefaultDisplay().getRotation()) {
            case Surface.ROTATION_90:
                degrees = 90;
                break;
            case Surface.ROTATION_180:
                degrees = 180;
                break;
            case Surface.ROTATION_270:
                degrees = 270;
                break;
            default:
                break;
        }
        return (info.orientation - degrees + 360) % 360;
    }

    private void release() {
        if (camera != null) {
            try {
                camera.setPreviewCallback(null);
                camera.stopPreview();
            } catch (Exception ignored) {
                // камера уже остановлена
            }
            camera.release();
            camera = null;
        }
    }

    // ---------------------------------------------------------------- экран

    private int dp(int v) {
        return (int) (v * activity.getResources().getDisplayMetrics().density);
    }

    private void buildUi() {
        Context c = activity;
        overlay = new FrameLayout(c);
        overlay.setBackgroundColor(Color.BLACK);
        overlay.setClickable(true);   // не пропускаем нажатия к странице под сканером

        // Размер картинки: вписываем превью в экран с сохранением пропорций (камера повёрнута на 90° в портрете).
        boolean rotated = displayOrientation(currentId) % 180 != 0;
        int viewW = rotated ? previewH : previewW, viewH = rotated ? previewW : previewH;
        int availW = parent.getWidth(), availH = parent.getHeight();
        float k = Math.min((float) availW / viewW, (float) availH / viewH);
        int w = Math.round(viewW * k), h = Math.round(viewH * k);

        surface = new SurfaceView(c);
        surface.getHolder().addCallback(this);
        FrameLayout.LayoutParams sp = new FrameLayout.LayoutParams(w, h, Gravity.CENTER);
        overlay.addView(surface, sp);

        // Рамка-видоискатель
        View frame = new View(c);
        GradientDrawable g = new GradientDrawable();
        g.setStroke(dp(3), Color.WHITE);
        g.setCornerRadius(dp(24));
        g.setColor(Color.TRANSPARENT);
        frame.setBackground(g);
        int side = Math.min(w, h) * 6 / 10;
        overlay.addView(frame, new FrameLayout.LayoutParams(side, side, Gravity.CENTER));

        TextView hint = new TextView(c);
        hint.setText("Наведите камеру на QR клиента");
        hint.setTextColor(Color.WHITE);
        hint.setTextSize(17);
        hint.setGravity(Gravity.CENTER);
        hint.setShadowLayer(6, 0, 2, Color.BLACK);
        FrameLayout.LayoutParams hp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP);
        hp.topMargin = dp(28);
        overlay.addView(hint, hp);

        info = new TextView(c);
        info.setText("Камера " + currentId + " · превью " + previewW + "×" + previewH);
        info.setTextColor(Color.LTGRAY);
        info.setTextSize(12);
        info.setGravity(Gravity.CENTER);
        info.setShadowLayer(4, 0, 1, Color.BLACK);
        FrameLayout.LayoutParams ip = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM);
        ip.bottomMargin = dp(86);
        overlay.addView(info, ip);

        Button closeBtn = new Button(c);
        closeBtn.setText("Закрыть");
        closeBtn.setAllCaps(false);
        closeBtn.setTextSize(17);
        closeBtn.setTextColor(Color.parseColor("#1e1510"));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.parseColor("#e0914f"));
        bg.setCornerRadius(dp(16));
        closeBtn.setBackground(bg);
        closeBtn.setOnClickListener(v -> close());
        FrameLayout.LayoutParams cp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(54), Gravity.BOTTOM);
        cp.setMargins(dp(24), 0, dp(24), dp(20));
        overlay.addView(closeBtn, cp);

        parent.addView(overlay, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }

    // ---------------------------------------------------------------- SurfaceHolder.Callback

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        if (camera == null) {
            return;
        }
        try {
            camera.setPreviewDisplay(holder);
            camera.setPreviewCallback(this);
            camera.startPreview();
            scheduleAutoFocus();
        } catch (Exception e) {
            listener.onError("Не удалось запустить камеру.");
            close();
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        // размер и пропорции заданы заранее, перенастраивать нечего
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        if (camera != null) {
            try {
                camera.stopPreview();
            } catch (Exception ignored) {
                // уже остановлена
            }
        }
    }

    private void scheduleAutoFocus() {
        if (!autoFocusLoop) {
            return;
        }
        main.postDelayed(() -> {
            if (camera != null && active) {
                try {
                    camera.autoFocus(null);
                } catch (Exception ignored) {
                    // камера занята
                }
                scheduleAutoFocus();
            }
        }, 2000);
    }

    // ---------------------------------------------------------------- распознавание

    @Override
    public void onPreviewFrame(final byte[] data, Camera cam) {
        if (!active || busy || worker == null) {
            return;   // пока предыдущий кадр обрабатывается, новые пропускаем
        }
        busy = true;
        final int w = previewW, h = previewH;
        try {
            worker.execute(() -> {
                String text = null;
                try {
                    PlanarYUVLuminanceSource src = new PlanarYUVLuminanceSource(data, w, h, 0, 0, w, h, false);
                    Result r = reader.decode(new BinaryBitmap(new HybridBinarizer(src)), hints);
                    text = r.getText();
                } catch (Exception notFound) {
                    // QR в этом кадре нет — берём следующий
                } finally {
                    reader.reset();
                    busy = false;
                }
                if (text != null && text.startsWith("BC1.") && active) {
                    final String result = text;
                    active = false;
                    main.post(() -> {
                        listener.onResult(result);
                        close();
                    });
                }
            });
        } catch (Exception rejected) {
            busy = false;
        }
    }
}
