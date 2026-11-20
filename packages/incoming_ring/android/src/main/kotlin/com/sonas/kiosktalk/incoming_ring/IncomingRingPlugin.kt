package com.sonas.kiosktalk.incoming_ring

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class IncomingRingPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "kiosk_talk/incoming_ring")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                Ring.start(context, call.argument<Boolean>("tone") == true)
                result.success(null)
            }
            "stop" -> {
                Ring.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

object IncomingRingBridge {
    fun stop() {
        Ring.stop()
    }
}

private object Ring {
    private val handler = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private var vibrator: Vibrator? = null
    private var tone: Ringtone? = null
    private var focus: AudioFocusRequest? = null
    private var ringing = false
    private val pulse = object : Runnable {
        override fun run() {
            val context = app
            if (!ringing || context == null) return
            buzz(context)
            handler.postDelayed(this, 1400)
        }
    }
    private val replay = object : Runnable {
        override fun run() {
            if (!ringing) return
            val current = tone
            if (current != null && !current.isPlaying) current.play()
            handler.postDelayed(this, 1000)
        }
    }

    fun start(context: Context, withTone: Boolean) {
        ringing = true
        app = context.applicationContext
        handler.removeCallbacksAndMessages(null)
        tone?.stop()
        tone = null
        if (withTone) playTone(app!!)
        handler.post(pulse)
    }

    fun stop() {
        ringing = false
        handler.removeCallbacksAndMessages(null)
        vibrator?.cancel()
        vibrator = null
        tone?.stop()
        tone = null
        val context = app
        if (context != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            focus?.let { audio.abandonAudioFocusRequest(it) }
        }
        focus = null
    }

    private fun playTone(context: Context) {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) ?: return
        val next = RingtoneManager.getRingtone(context.applicationContext, uri) ?: return
        val headset = headsetConnected(audio)
        val attributes = AudioAttributes.Builder()
            .setUsage(if (headset) AudioAttributes.USAGE_MEDIA else AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(if (headset) AudioAttributes.CONTENT_TYPE_MUSIC else AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        next.audioAttributes = attributes
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .build()
            focus = request
            audio.requestAudioFocus(request)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) next.isLooping = true
        next.play()
        tone = next
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) handler.postDelayed(replay, 1000)
    }

    private fun headsetConnected(audio: AudioManager): Boolean {
        for (device in audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            when (device.type) {
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_HEARING_AID,
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLE_SPEAKER -> return true
            }
        }
        return false
    }

    private fun buzz(context: Context) {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audio.ringerMode == AudioManager.RINGER_MODE_SILENT) return
        val motor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        vibrator = motor
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            motor.vibrate(
                VibrationEffect.createOneShot(700, VibrationEffect.DEFAULT_AMPLITUDE),
                VibrationAttributes.createForUsage(VibrationAttributes.USAGE_RINGTONE),
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            motor.vibrate(VibrationEffect.createOneShot(700, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            motor.vibrate(700)
        }
    }
}
