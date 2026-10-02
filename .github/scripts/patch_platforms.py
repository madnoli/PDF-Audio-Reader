"""Adjusts the platform folders that `flutter create` generates in CI.

The android/ and windows/ folders aren't committed; CI regenerates them on
every build, then this script applies the few settings the app needs.
"""
import pathlib
import re
import shutil
import sys

app = pathlib.Path(__file__).resolve().parents[2] / "app"


def edit(path, *replacements):
    file = app / path
    text = file.read_text(encoding="utf-8")
    for old, new in replacements:
        if old not in text:
            sys.exit(f"patch_platforms: '{old}' not found in {path}")
        text = text.replace(old, new, 1)
    file.write_text(text, encoding="utf-8")
    print(f"patched {path}")


# The default widget test refers to the template's counter app.
shutil.rmtree(app / "test", ignore_errors=True)

if "android" in sys.argv:
    edit(
        "android/app/src/main/AndroidManifest.xml",
        ('android:label="audio_reader"', 'android:label="Audio Reader"'),
        # Android 11+ hides the text-to-speech engines from apps unless they declare this.
        ("<application", '<queries>\n        <intent>\n            <action android:name="android.intent.action.TTS_SERVICE" />\n        </intent>\n    </queries>\n    <application'),
    )
    gradle = app / "android/app/build.gradle.kts"
    text = gradle.read_text(encoding="utf-8")
    # flutter_tts needs Android 7.0 (API 24) or newer.
    text, n = re.subn(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = maxOf(flutter.minSdkVersion, 24)", text)
    if n != 1:
        sys.exit("patch_platforms: minSdk line not found in build.gradle.kts")
    gradle.write_text(text, encoding="utf-8")
    print("patched android/app/build.gradle.kts")

if "windows" in sys.argv:
    edit("windows/runner/main.cpp", ('L"audio_reader"', 'L"Audio Reader"'))
    edit("windows/CMakeLists.txt", ('set(BINARY_NAME "audio_reader")', 'set(BINARY_NAME "AudioReader")'))
