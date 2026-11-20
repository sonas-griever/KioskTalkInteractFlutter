package com.sonas.kiosktalk.kiosk_talk

import android.app.KeyguardManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kiosk_talk/session").setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("kiosk_talk_native", MODE_PRIVATE)
            when (call.method) {
                "save" -> {
                    prefs.edit()
                        .putString("token", call.argument<String>("token") ?: "")
                        .putString("api", call.argument<String>("api") ?: "")
                        .apply()
                    result.success(null)
                }
                "clear" -> {
                    prefs.edit().remove("token").remove("api").apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kiosk_talk/lock").setMethodCallHandler { call, result ->
            if (call.method == "openNotifications") {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(Uri.parse("package:$packageName"))
                }
                startActivity(intent)
                result.success(null)
            } else if (call.method == "callVisible") {
                val visible = call.argument<Boolean>("visible") == true
                setCallOverLock(visible)
                holdCallProcess(visible)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun setCallOverLock(visible: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(visible)
            setTurnScreenOn(visible)
        }
        if (visible) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            return
        }
        window.clearFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )
        val locked = getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
        if (locked) moveTaskToBack(true)
    }

    private fun holdCallProcess(visible: Boolean) {
        val intent = android.content.Intent(this, CallForegroundService::class.java)
        try {
            if (!visible) {
                stopService(intent)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (_: Exception) {
        }
    }
}
