package com.coffeebonus.app;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.util.SparseArray;
import android.view.View;
import android.view.ViewStructure;
import android.view.autofill.AutofillValue;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONObject;

/**
 * Оболочка над сайтом бонусной системы: один экран с WebView.
 * Адрес сайта берётся из сборки (default_url) или вводится при первом запуске.
 */
public class MainActivity extends Activity {
    private static final int REQ_CAMERA = 1;
    private static final int REQ_CAMERA_FOR_SCAN = 4;
    private static final String APP_VERSION = "1.11";
    private static final int BG = Color.parseColor("#1e1510");
    private static final int ACCENT = Color.parseColor("#d98a45");

    private SharedPreferences prefs;
    private FrameLayout root;
    private WebView web;
    private PermissionRequest pendingPermission;
    private String baseHost = "";

    // родной сканер QR (вызывается со страницы кассы через мост AndroidApp)
    private NativeScanner scanner;

    /** Мост для страницы: window.AndroidApp.scanQr() / version(). Доступен только страницам нашего сайта. */
    private class Bridge {
        @JavascriptInterface
        public void scanQr() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    startNativeScan();
                }
            });
        }

        @JavascriptInterface
        public String version() {
            return APP_VERSION;
        }
    }

    private void startNativeScan() {
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAMERA_FOR_SCAN);
            return;
        }
        if (scanner != null && scanner.isOpen()) {
            return;
        }
        scanner = new NativeScanner(this, root, new NativeScanner.Listener() {
            @Override
            public void onResult(String text) {
                callPage("window.onNativeQr && window.onNativeQr(" + JSONObject.quote(text) + ")");
            }

            @Override
            public void onError(String message) {
                callPage("window.onNativeQrError && window.onNativeQrError(" + JSONObject.quote(message) + ")");
            }
        });
        scanner.show();
    }

    private void callPage(String js) {
        if (web != null) {
            web.evaluateJavascript(js, null);
        }
    }

    @Override
    protected void onPause() {
        if (scanner != null) {
            scanner.close();   // камеру нельзя держать, когда приложение свёрнуто
            scanner = null;
        }
        super.onPause();
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("app", MODE_PRIVATE);
        root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        noAutofill(root);
        noAutofill(getWindow().getDecorView());   // и всё окно целиком
        setContentView(root);
        // Если адрес зашит в сборку — пользователь его не вводит и старый сохранённый адрес не нужен.
        String baked = getString(R.string.default_url);
        String url = baked.trim().isEmpty() ? prefs.getString("url", "") : baked;
        if (url == null || url.trim().isEmpty()) {
            showAddressScreen("");
        } else {
            showWeb(url);
        }
    }

    // ---------------------------------------------------------------- экраны

    private void showWeb(final String url) {
        destroyWeb();
        root.removeAllViews();
        Uri u = Uri.parse(url);
        baseHost = u.getHost() == null ? "" : u.getHost();

        web = new QuietWebView(this);
        noAutofill(web);   // без системного окна автозаполнения («Выбрать вручную»), которое перекрывает клавиатуру
        web.setLayerType(View.LAYER_TYPE_HARDWARE, null);   // видео и анимации рисует видеокарта, а не процессор
        web.clearCache(true);   // при каждом запуске берём свежую версию сайта, а не копию из кэша
        web.setBackgroundColor(BG);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setSaveFormData(false);
        s.setMediaPlaybackRequiresUserGesture(false);

        web.addJavascriptInterface(new Bridge(), "AndroidApp");

        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(web, true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                String host = r.getUrl().getHost();
                if (host == null || host.equals(baseHost) || host.endsWith("telegram.org")) {
                    return false; // свой сайт и вход через Telegram — внутри приложения
                }
                startActivity(new Intent(Intent.ACTION_VIEW, r.getUrl())); // остальное — во внешнем браузере
                return true;
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (r.isForMainFrame()) {
                    showError(url, String.valueOf(e.getDescription()));
                }
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(final PermissionRequest request) {
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        handlePermission(request);
                    }
                });
            }
        });

        root.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        web.loadUrl(url);
    }

    private void showAddressScreen(String current) {
        destroyWeb();
        root.removeAllViews();
        LinearLayout box = column();
        box.addView(label("☕ Кофе-карта", 26, Color.WHITE), lp(0));
        box.addView(label("Введите адрес сайта кофейни, который вам дали.", 15, Color.LTGRAY), lp(dp(8)));

        final EditText input = new EditText(this);
        input.setHint("https://coffee.example.ru");
        input.setHintTextColor(Color.GRAY);
        input.setTextColor(Color.WHITE);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setText(current);
        box.addView(input, lp(dp(20)));

        Button go = button("Открыть");
        go.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                String url = normalize(input.getText().toString());
                if (url.isEmpty()) {
                    input.setError("Введите адрес");
                    return;
                }
                prefs.edit().putString("url", url).apply();
                showWeb(url);
            }
        });
        box.addView(go, lp(dp(16)));
        root.addView(box);
    }

    private void showError(final String url, String message) {
        destroyWeb();
        root.removeAllViews();
        LinearLayout box = column();
        box.addView(label("Не удалось открыть сайт", 22, Color.WHITE), lp(0));
        box.addView(label(url, 14, Color.LTGRAY), lp(dp(6)));
        box.addView(label(message, 13, Color.GRAY), lp(dp(6)));

        Button retry = button("Повторить");
        retry.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showWeb(url);
            }
        });
        box.addView(retry, lp(dp(20)));

        Button change = button("Изменить адрес");
        change.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showAddressScreen(url);
            }
        });
        box.addView(change, lp(dp(10)));
        root.addView(box);
    }

    // ---------------------------------------------------------------- камера для сканера QR

    private void handlePermission(PermissionRequest request) {
        boolean wantsCamera = false;
        for (String r : request.getResources()) {
            if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r)) {
                wantsCamera = true;
            }
        }
        if (!wantsCamera) {
            request.deny();
        } else if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            request.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
        } else {
            pendingPermission = request;
            requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAMERA);
        }
    }


    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == REQ_CAMERA_FOR_SCAN) {
            if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) {
                startNativeScan();
            } else {
                callPage("window.onNativeQrError && window.onNativeQrError('Нет доступа к камере. Разрешите её в настройках приложения.')");
            }
            return;
        }
        if (code == REQ_CAMERA && pendingPermission != null) {
            if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) {
                pendingPermission.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
            } else {
                pendingPermission.deny();
            }
            pendingPermission = null;
        }
    }

    // ---------------------------------------------------------------- прочее

    @Override
    public void onBackPressed() {
        if (scanner != null && scanner.isOpen()) {
            scanner.close();   // «Назад» закрывает сканер, а не уходит со страницы
            scanner = null;
        } else if (web != null && web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        destroyWeb();
        super.onDestroy();
    }

    private void destroyWeb() {
        if (web != null) {
            web.destroy();
            web = null;
        }
    }

    private static String normalize(String raw) {
        String s = raw.trim();
        if (s.isEmpty() || s.contains("://")) {
            return s;
        }
        boolean local = s.startsWith("localhost") || s.matches("^[0-9.]+(:\\d+)?(/.*)?$");
        return (local ? "http://" : "https://") + s;
    }

    /**
     * Встроенный браузер, который не рассказывает системе о полях на странице и не принимает подстановку.
     * Флага importantForAutofill для этого мало: WebView сам сообщает системе о своих полях, и тогда поверх
     * клавиатуры появляются подсказки с ключом, картой и «Выбрать вручную». Если полей системе не отдавать,
     * показывать автозаполнению нечего.
     */
    private static class QuietWebView extends WebView {
        QuietWebView(Context context) {
            super(context);
        }

        @Override
        public void onProvideAutofillVirtualStructure(ViewStructure structure, int flags) {
            // намеренно пусто: структуру страницы для автозаполнения не отдаём
        }

        @Override
        public void autofill(SparseArray<AutofillValue> values) {
            // намеренно пусто: подстановку не принимаем
        }

        @Override
        public int getAutofillType() {
            return AUTOFILL_TYPE_NONE;
        }
    }

    /**
     * Android 13+ при нажатии на поле показывает окно автозаполнения вместо клавиатуры (с кнопкой «Выбрать вручную»).
     * В приложении оно только мешает — отключаем для всего экрана.
     */
    private void noAutofill(View v) {
        if (Build.VERSION.SDK_INT >= 26) {
            v.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        }
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density);
    }

    private LinearLayout column() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        box.setPadding(dp(24), dp(24), dp(24), dp(24));
        box.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        return box;
    }

    private TextView label(String text, int sp, int color) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setGravity(Gravity.CENTER);
        return t;
    }

    private Button button(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(BG);
        b.setBackgroundColor(ACCENT);
        return b;
    }

    private LinearLayout.LayoutParams lp(int topMargin) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        p.topMargin = topMargin;
        return p;
    }
}
