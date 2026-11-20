package com.sonas.kiosktalk.kiosk_talk

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.Cursor
import android.net.Uri
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import com.sonas.kiosktalk.incoming_ring.IncomingRingBridge
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Collections

class TalkRejectProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val context = context ?: return true
        CallRejectWatcher.install(context)
        return true
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}

private object CallRejectWatcher {
    private val sent = Collections.synchronizedSet(mutableSetOf<String>())
    private var previous = mapOf<String, Pending>()
    private var app: Context? = null
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { prefs, key ->
        if (key != "ACTIVE_CALLS") return@OnSharedPreferenceChangeListener
        val context = app ?: return@OnSharedPreferenceChangeListener
        val next = read(prefs.getString("ACTIVE_CALLS", "[]"))
        val gone = previous.filter { (id, item) -> !item.accepted && !next.containsKey(id) }
        previous = next
        if (gone.isEmpty()) return@OnSharedPreferenceChangeListener
        silence()
        for (item in gone.values) reject(context, item.merchantNo)
    }

    fun install(context: Context) {
        val application = context.applicationContext
        app = application
        val calls = application.getSharedPreferences("flutter_callkit_incoming", Context.MODE_PRIVATE)
        previous = read(calls.getString("ACTIVE_CALLS", "[]"))
        calls.registerOnSharedPreferenceChangeListener(listener)
    }

    private fun silence() {
        IncomingRingBridge.stop()
        try {
            FlutterCallkitIncomingPlugin.getInstance()?.getCallkitSoundPlayerManager()?.stop()
        } catch (_: Exception) {
        }
    }

    private fun reject(context: Context, merchantNo: String) {
        if (!merchantNo.matches(Regex("^[A-Za-z0-9_-]{8,64}$"))) return
        if (!sent.add(merchantNo)) return
        Thread {
            var delivered = false
            val prefs = context.getSharedPreferences("kiosk_talk_native", Context.MODE_PRIVATE)
            val token = prefs.getString("token", "") ?: ""
            val api = prefs.getString("api", "") ?: ""
            if (token.isEmpty() || api.isEmpty()) {
                sent.remove(merchantNo)
                return@Thread
            }
            repeat(3) { attempt ->
                var connection: HttpURLConnection? = null
                try {
                    connection = (URL("$api/calls/$merchantNo/reject").openConnection() as HttpURLConnection).apply {
                        requestMethod = "POST"
                        connectTimeout = 8000
                        readTimeout = 8000
                        doOutput = true
                        setRequestProperty("authorization", "Bearer $token")
                        setRequestProperty("content-type", "application/json")
                    }
                    connection.outputStream.use { it.write("{}".toByteArray()) }
                    val code = connection.responseCode
                    if (code in 200..299 || code == 401 || code == 403 || code == 404 || code == 409) {
                        delivered = true
                        return@Thread
                    }
                } catch (_: Exception) {
                } finally {
                    connection?.disconnect()
                }
                if (attempt < 2) Thread.sleep(500)
            }
            if (!delivered) sent.remove(merchantNo)
        }.start()
    }

    private fun read(raw: String?): Map<String, Pending> {
        val rows = linkedMapOf<String, Pending>()
        val text = raw ?: return rows
        try {
            val array = JSONArray(text)
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val id = item.optString("id")
                if (id.isEmpty()) continue
                val extra = item.optJSONObject("extra") ?: JSONObject()
                val merchant = extra.optString("merchantNo").ifEmpty { item.optString("handle") }
                rows[id] = Pending(merchant, item.optBoolean("isAccepted"))
            }
        } catch (_: Exception) {
        }
        return rows
    }
}

private data class Pending(val merchantNo: String, val accepted: Boolean)
