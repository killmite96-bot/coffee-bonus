#!/usr/bin/env python3
"""Сборка APK без Gradle: aapt2 + javac + d8 + zipalign + apksigner из Android SDK.

Использование:
    python build_apk.py                       # адрес сайта пользователь введёт в приложении
    python build_apk.py --url https://coffee.example.ru   # адрес зашит в приложение
Результат: ../Kofe-karta.apk
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent
OUT_APK = HERE.parent / "Kofe-karta.apk"
KEYSTORE = HERE / "debug.keystore"
VERSION_CODE, VERSION_NAME = 3, "1.2"
MIN_SDK, TARGET_SDK = 24, 34


def find_sdk():
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(var) and Path(os.environ[var]).is_dir():
            return Path(os.environ[var])
    local = Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk"
    if local.is_dir():
        return local
    sys.exit("Android SDK не найден. Установите Android Studio или задайте ANDROID_HOME.")


def jdk_tool(name):
    """javac/keytool: сначала JAVA_HOME и стандартные папки JDK, потом PATH (там бывают только заглушки)."""
    bins = []
    if os.environ.get("JAVA_HOME"):
        bins.append(Path(os.environ["JAVA_HOME"]) / "bin")
    for parent, pattern in (("C:/Program Files/Java", "jdk*"), ("C:/Program Files/Eclipse Adoptium", "jdk*")):
        if Path(parent).is_dir():
            bins += [d / "bin" for d in sorted(Path(parent).glob(pattern), reverse=True)]
    bins.append(Path("C:/Program Files/Android/Android Studio/jbr/bin"))
    for b in bins:
        for ext in (".exe", ""):
            if (b / (name + ext)).exists():
                return str(b / (name + ext))
    return shutil.which(name) or sys.exit(f"JDK не найден (нужен {name}). Установите JDK 11+ или задайте JAVA_HOME.")


def newest(path):
    dirs = sorted((p for p in path.iterdir() if p.is_dir()),
                  key=lambda p: [int(x) if x.isdigit() else 0 for x in p.name.replace("android-", "").split(".")])
    if not dirs:
        sys.exit(f"В {path} ничего не установлено")
    return dirs[-1]


def tool(folder, name):
    for ext in (".exe", ".bat", ".cmd", ""):
        p = folder / (name + ext)
        if p.exists():
            return str(p)
    sys.exit(f"Не найден {name} в {folder}")


def run(cmd, **kw):
    print(">", Path(str(cmd[0])).name, *[str(c) for c in cmd[1:4]], "..." if len(cmd) > 4 else "")
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    if r.returncode:
        print(r.stdout, r.stderr, sep="\n")
        sys.exit(f"Ошибка на шаге {Path(str(cmd[0])).name}")
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="", help="адрес сайта, зашитый в приложение")
    args = ap.parse_args()

    sdk = find_sdk()
    bt = newest(sdk / "build-tools")
    platform = newest(sdk / "platforms")
    android_jar = platform / "android.jar"
    javac = jdk_tool("javac")
    keytool = jdk_tool("keytool")
    print(f"SDK: {sdk}\nbuild-tools: {bt.name}, platform: {platform.name}")

    # Java-инструменты Android плохо переносят кириллицу в путях — собираем во временной папке.
    work = Path(tempfile.mkdtemp(prefix="apkbuild_"))
    try:
        res = work / "res"
        shutil.copytree(HERE / "res", res)
        (res / "values").mkdir(exist_ok=True)
        (res / "values" / "strings.xml").write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
            '    <string name="app_name">Кофе-карта</string>\n'
            f'    <string name="default_url">{escape(args.url)}</string>\n</resources>\n', "utf-8")

        compiled = work / "compiled"
        compiled.mkdir()
        aapt2 = tool(bt, "aapt2")
        run([aapt2, "compile", "--dir", res, "-o", compiled])

        gen = work / "gen"
        gen.mkdir()
        base = work / "base.apk"
        run([aapt2, "link", "-I", android_jar, "--manifest", HERE / "AndroidManifest.xml",
             "--min-sdk-version", MIN_SDK, "--target-sdk-version", TARGET_SDK,
             "--version-code", VERSION_CODE, "--version-name", VERSION_NAME,
             "--java", gen, "-o", base, *sorted(compiled.glob("*.flat"))])

        classes = work / "classes"
        classes.mkdir()
        sources = [str(p) for p in (HERE / "src").rglob("*.java")] + [str(p) for p in gen.rglob("*.java")]
        run([javac, "--release", "11", "-encoding", "UTF-8", "-cp", android_jar, "-d", classes, *sources])

        dexdir = work / "dex"
        dexdir.mkdir()
        class_files = [str(p) for p in classes.rglob("*.class")]
        run([tool(bt, "d8"), "--lib", android_jar, "--min-api", MIN_SDK, "--output", dexdir, *class_files])

        with zipfile.ZipFile(base, "a", zipfile.ZIP_DEFLATED) as z:
            z.write(dexdir / "classes.dex", "classes.dex")

        aligned = work / "aligned.apk"
        run([tool(bt, "zipalign"), "-f", "4", base, aligned])

        if not KEYSTORE.exists():
            print("Создаю тестовый ключ подписи (debug.keystore)")
            run([keytool, "-genkeypair", "-keystore", KEYSTORE, "-alias", "debug", "-keyalg", "RSA",
                 "-keysize", "2048", "-validity", "10000", "-storepass", "android", "-keypass", "android",
                 "-dname", "CN=Coffee Bonus Debug"])
        signed = work / "signed.apk"
        run([tool(bt, "apksigner"), "sign", "--ks", KEYSTORE, "--ks-key-alias", "debug",
             "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", signed, aligned])
        run([tool(bt, "apksigner"), "verify", signed])

        shutil.copyfile(signed, OUT_APK)
        print(f"\nГотово: {OUT_APK} ({OUT_APK.stat().st_size // 1024} КБ)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
