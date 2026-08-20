package com.hyperpulse.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * [HyperPulseForegroundService] is a resilient Android Foreground Service that prevents
 * OEM battery managers (Xiaomi MIUI/HyperOS, Samsung OneUI, Huawei) from killing
 * HyperPulse when the user minimizes the app or copies links in external browsers.
 */
class HyperPulseForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "hyperpulse_catcher_channel"
        const val NOTIFICATION_ID = 90210
        const val ACTION_START_SERVICE = "ACTION_START_HYPERPULSE_SERVICE"
        const val ACTION_STOP_SERVICE = "ACTION_STOP_HYPERPULSE_SERVICE"
        const val BROADCAST_URL_CAUGHT = "com.hyperpulse.app.URL_CAUGHT"
        var isRunning = false
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var clipboardManager: ClipboardManager? = null
    private var clipChangedListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastClipText: String? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireWakeLock()
        initClipboardListener()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_SERVICE) {
            stopForegroundService()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        isRunning = true
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("HyperPulse Turbo Downloader ⚡")
            .setContentText("محرك التنزيل السريع نشط في الخلفية • لن يتوقف التحميل عند تصغير التطبيق")
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "HyperPulse Link Catcher Radar",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "خدمة المراقبة الدائمة لروابط التحميل والوسائط في الخلفية"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun acquireWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "HyperPulse::ForegroundServiceWakeLock"
            ).apply {
                acquire(120 * 60 * 1000L) // 2 hours keep-alive while downloading
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun initClipboardListener() {
        try {
            clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            clipChangedListener = ClipboardManager.OnPrimaryClipChangedListener {
                inspectClipboard()
            }
            clipboardManager?.addPrimaryClipChangedListener(clipChangedListener)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun inspectClipboard() {
        try {
            val clip: ClipData? = clipboardManager?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0)?.coerceToText(this)?.toString()?.trim()
                if (!text.isNullOrEmpty() && text != lastClipText) {
                    if (text.startsWith("http://") || text.startsWith("https://")) {
                        lastClipText = text
                        // Broadcast URL to Flutter Activity
                        val broadcastIntent = Intent(BROADCAST_URL_CAUGHT).apply {
                            putExtra("url", text)
                            setPackage(packageName)
                        }
                        sendBroadcast(broadcastIntent)
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopForegroundService() {
        isRunning = false
        try {
            if (clipChangedListener != null && clipboardManager != null) {
                clipboardManager?.removePrimaryClipChangedListener(clipChangedListener)
            }
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        stopForegroundService()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
