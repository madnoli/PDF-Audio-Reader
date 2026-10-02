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


ANDROID_PERMISSIONS = """
    xmlns:tools="http://schemas.android.com/tools">
    <!-- Keep reading in a foreground service after the app is closed (audio_service). -->
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
    <!-- Library scan: find PDF/EPUB files anywhere on the device. -->
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" tools:ignore="ScopedStorage" />"""

# Android 11+ hides the text-to-speech engines from apps unless they declare this.
ANDROID_TTS_QUERY = """<queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
    </queries>
    <application
        android:requestLegacyExternalStorage="true\""""

ANDROID_MEDIA_SERVICE = """    <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>
    </application>"""

MAIN_ACTIVITY = """
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "audio_reader/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAccess" -> result.success(hasAllFilesAccess())
                    "requestAccess" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 1)
        }
    }
}
"""

# The default widget test refers to the template's counter app.
shutil.rmtree(app / "test", ignore_errors=True)

if "android" in sys.argv:
    edit(
        "android/app/src/main/AndroidManifest.xml",
        ('xmlns:android="http://schemas.android.com/apk/res/android">',
         'xmlns:android="http://schemas.android.com/apk/res/android"' + ANDROID_PERMISSIONS),
        ('android:label="audio_reader"', 'android:label="Audio Reader"'),
        ("<application", ANDROID_TTS_QUERY),
        ("</application>", ANDROID_MEDIA_SERVICE),
    )

    # audio_service keeps the Flutter engine alive in the background through its own activity class.
    # The activity also answers the library's "can I read all files?" questions (see library.dart).
    activity = next((app / "android/app/src/main").rglob("MainActivity.kt"))
    package = re.search(r"^package .+$", activity.read_text(encoding="utf-8"), re.M).group(0)
    activity.write_text(package + "\n" + MAIN_ACTIVITY, encoding="utf-8")
    print(f"patched {activity.relative_to(app)}")

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
