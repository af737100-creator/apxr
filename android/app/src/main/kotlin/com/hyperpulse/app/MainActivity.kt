package com.hyperpulse.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val SERVICE_CHANNEL = "com.hyperpulse.app/foreground_service"
    private val SYSTEM_CHANNEL = "com.hyperpulse.app/android_system"
    private var serviceMethodChannel: MethodChannel? = null
    private var systemMethodChannel: MethodChannel? = null

    private val urlReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val url = intent?.getStringExtra("url")
            if (!url.isNullOrEmpty()) {
                serviceMethodChannel?.invokeMethod("onUrlCaughtFromBackground", url)
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Foreground Service Channel
        serviceMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SERVICE_CHANNEL)
        serviceMethodChannel?.setMethodCallHandler { call, result ->
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

        // 2. Android System / Permissions / MediaScanner Channel
        systemMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
        systemMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Check if Draw Over Other Apps (SYSTEM_ALERT_WINDOW) is granted
                "canDrawOverlays" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        result.success(Settings.canDrawOverlays(this))
                    } else {
                        result.success(true)
                    }
                }
                // Open Settings to grant Overlay Permission
                "openOverlaySettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                            startActivity(intent)
                            result.success(true)
                        }
                    } else {
                        result.success(true)
                    }
                }
                // Check if Notifications are enabled
                "areNotificationsEnabled" -> {
                    val enabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
                    result.success(enabled)
                }
                // Open Notification Settings
                "openNotificationSettings" -> {
                    try {
                        val intent = Intent().apply {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            } else {
                                action = "android.settings.APP_NOTIFICATION_SETTINGS"
                                putExtra("app_package", packageName)
                                putExtra("app_uid", applicationInfo.uid)
                            }
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERR_NOTIF_SETTINGS", e.message, null)
                    }
                }
                // MediaScannerConnection: Indexes newly downloaded Video/Audio into Android Gallery
                "scanMediaFile" -> {
                    val filePath = call.argument<String>("filePath")
                    if (!filePath.isNullOrEmpty()) {
                        scanFileForGallery(filePath)
                        result.success(true)
                    } else {
                        result.error("INVALID_PATH", "File path cannot be null or empty", null)
                    }
                }
                // Resolves the public Movies/HyperPulse directory
                "getPublicMoviesPath" -> {
                    val moviesDir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "HyperPulse")
                    if (!moviesDir.exists()) {
                        moviesDir.mkdirs()
                    }
                    result.success(moviesDir.absolutePath)
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

    private fun scanFileForGallery(filePath: String) {
        try {
            val file = File(filePath)
            if (file.exists()) {
                val mimeType = when {
                    filePath.endsWith(".mp4", ignoreCase = true) -> "video/mp4"
                    filePath.endsWith(".mp3", ignoreCase = true) -> "audio/mp3"
                    filePath.endsWith(".mkv", ignoreCase = true) -> "video/x-matroska"
                    filePath.endsWith(".webm", ignoreCase = true) -> "video/webm"
                    else -> "*/*"
                }

                // 1. Android Modern MediaScannerConnection
                MediaScannerConnection.scanFile(
                    this,
                    arrayOf(file.absolutePath),
                    arrayOf(mimeType)
                ) { path, uri ->
                    // Media indexed successfully into MediaStore
                }

                // 2. Legacy Broadcast for maximum compatibility across Android 8-15
                val mediaScanIntent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
                mediaScanIntent.data = Uri.fromFile(file)
                sendBroadcast(mediaScanIntent)
            }
        } catch (e: Exception) {
            e.printStackTrace()
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
