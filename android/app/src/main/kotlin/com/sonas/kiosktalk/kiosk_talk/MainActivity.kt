package com.sonas.kiosktalk.kiosk_talk

import android.app.KeyguardManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kiosk_talk/lock").setMethodCallHandler { call, result ->
            if (call.method == "callVisible") {
                setCallOverLock(call.argument<Boolean>("visible") == true)
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
}
