package com.hyperpulse.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.hyperpulse.app/foreground_service"
    private var methodChannel: MethodChannel? = null

    private val urlReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val url = intent?.getStringExtra("url")
            if (!url.isNullOrEmpty()) {
                methodChannel?.invokeMethod("onUrlCaughtFromBackground", url)
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    startHyperPulseForegroundService()
                    result.success(true)
                }
                "stopService" -> {
                    stopHyperPulseForegroundService()
                    result.success(true)
                }
                "isServiceRunning" -> {
                    result.success(HyperPulseForegroundService.isRunning)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Register broadcast receiver for URLs captured in background
        val filter = IntentFilter(HyperPulseForegroundService.BROADCAST_URL_CAUGHT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(urlReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(urlReceiver, filter)
        }
    }

    private fun startHyperPulseForegroundService() {
        val intent = Intent(this, HyperPulseForegroundService::class.java).apply {
            action = HyperPulseForegroundService.ACTION_START_SERVICE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopHyperPulseForegroundService() {
        val intent = Intent(this, HyperPulseForegroundService::class.java).apply {
            action = HyperPulseForegroundService.ACTION_STOP_SERVICE
        }
        startService(intent)
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(urlReceiver)
        } catch (e: Exception) {
            // Receiver might not be registered
        }
        super.onDestroy()
    }
}
