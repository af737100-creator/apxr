package com.pulsesphere.speedcore

import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.annotation.NonNull
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val SERVICE_CHANNEL = "com.hyperpulse.app/foreground_service"
    private val SYSTEM_CHANNEL = "com.hyperpulse.app/android_system"
    private var serviceMethodChannel: MethodChannel? = null
    private var systemMethodChannel: MethodChannel? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()

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

        // Ensure app storage folder tree exists safely in background
        ioExecutor.execute {
            createAppStorageFolders()
        }

        // Register DualNetworkPlugin
        try {
            flutterEngine.plugins.add(DualNetworkPlugin())
        } catch (e: Throwable) {
            Log.w("MainActivity", "DualNetworkPlugin notice: ${e.message}")
        }

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
                // Request all system permissions directly on app launch (Allow, Allow)
                "requestAllAppPermissions" -> {
                    val requested = requestAllAppPermissions()
                    createAppStorageFolders()
                    result.success(requested)
                }
                // Pre-create public and categorized download folders immediately
                "createAppStorageFolders" -> {
                    val created = createAppStorageFolders()
                    result.success(created)
                }
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
                // MediaScannerConnection & Public MediaStore Exporter:
                // Ensures files show up in Android Gallery and File Manager (Download/HyperPulse)
                "scanMediaFile", "exportToPublicStorage" -> {
                    val filePath = call.argument<String>("filePath")
                    if (!filePath.isNullOrEmpty()) {
                        ioExecutor.execute {
                            exportFileToPublicStorage(filePath)
                        }
                        result.success(filePath)
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
                // Resolves the public Download/HyperPulse directory
                "getPublicDownloadsPath" -> {
                    val dlDir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "HyperPulse")
                    if (!dlDir.exists()) {
                        dlDir.mkdirs()
                    }
                    result.success(dlDir.absolutePath)
                }
                // Installs downloaded APK file directly with FileProvider
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (!filePath.isNullOrEmpty()) {
                        val installed = installApkDirectly(filePath)
                        result.success(installed)
                    } else {
                        result.error("INVALID_PATH", "APK path cannot be null or empty", null)
                    }
                }
                // Opens any downloaded file (Video, Audio, Document, Zip) in external default app
                "openFile" -> {
                    val filePath = call.argument<String>("filePath")
                    if (!filePath.isNullOrEmpty()) {
                        val opened = openFileExternally(filePath)
                        result.success(opened)
                    } else {
                        result.error("INVALID_PATH", "File path cannot be null or empty", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Register broadcast receiver for URLs captured in background safely
        try {
            val filter = IntentFilter(HyperPulseForegroundService.BROADCAST_URL_CAUGHT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(urlReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(urlReceiver, filter)
            }
        } catch (e: Throwable) {
            Log.e("MainActivity", "registerReceiver warning: ${e.message}")
        }
    }

    private fun exportFileToPublicStorage(filePath: String): String? {
        try {
            val file = File(filePath)
            if (!file.exists() || file.length() == 0L) return null

            val lower = filePath.lowercase()
            val isVideo = lower.endsWith(".mp4") || lower.endsWith(".mkv") || lower.endsWith(".webm") || lower.endsWith(".mov") || lower.endsWith(".avi") || lower.endsWith(".3gp")
            val isAudio = lower.endsWith(".mp3") || lower.endsWith(".m4a") || lower.endsWith(".aac") || lower.endsWith(".wav") || lower.endsWith(".flac")
            val isImage = lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp")
            val isApk = lower.endsWith(".apk") || lower.endsWith(".xapk")
            val isArchive = lower.endsWith(".zip") || lower.endsWith(".rar") || lower.endsWith(".7z") || lower.endsWith(".tar") || lower.endsWith(".gz") || lower.endsWith(".iso")

            val category = when {
                isApk -> "Apps"
                isVideo -> "Videos"
                isArchive -> "Archives"
                isAudio -> "Audio"
                lower.endsWith(".pdf") || lower.endsWith(".doc") || lower.endsWith(".docx") || lower.endsWith(".txt") -> "Documents"
                else -> "General"
            }

            val mimeType = when {
                lower.endsWith(".mp4") -> "video/mp4"
                lower.endsWith(".mkv") -> "video/x-matroska"
                lower.endsWith(".webm") -> "video/webm"
                lower.endsWith(".mov") -> "video/quicktime"
                lower.endsWith(".avi") -> "video/x-msvideo"
                lower.endsWith(".3gp") -> "video/3gpp"
                lower.endsWith(".mp3") -> "audio/mpeg"
                lower.endsWith(".m4a") -> "audio/mp4"
                lower.endsWith(".aac") -> "audio/aac"
                lower.endsWith(".wav") -> "audio/wav"
                lower.endsWith(".flac") -> "audio/flac"
                lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
                lower.endsWith(".png") -> "image/png"
                lower.endsWith(".webp") -> "image/webp"
                lower.endsWith(".apk") || lower.endsWith(".xapk") -> "application/vnd.android.package-archive"
                lower.endsWith(".pdf") -> "application/pdf"
                lower.endsWith(".zip") -> "application/zip"
                else -> "application/octet-stream"
            }

            // 1. Ensure file exists in the public categorized folder: Download/HyperPulse/Apps, Videos, Archives, etc.
            var targetPublicPath = file.absolutePath
            try {
                val pubDlDir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "HyperPulse/$category")
                if (!pubDlDir.exists()) {
                    pubDlDir.mkdirs()
                }
                val pubDestFile = File(pubDlDir, file.name)
                if (pubDestFile.absolutePath != file.absolutePath) {
                    file.copyTo(pubDestFile, overwrite = true)
                }
                targetPublicPath = pubDestFile.absolutePath
                MediaScannerConnection.scanFile(applicationContext, arrayOf(pubDestFile.absolutePath), arrayOf(mimeType), null)
            } catch (e: Exception) {
                Log.w("HyperPulse", "Direct copy to categorized public Download notice: ${e.message}")
            }

            // 2. Android 10+ (API 29+) MediaStore Export for Videos, Audio, Images and Downloads
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    val (contentUri, relativeDir) = when {
                        isVideo -> Pair(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, Environment.DIRECTORY_MOVIES + "/HyperPulse/Videos")
                        isAudio -> Pair(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, Environment.DIRECTORY_MUSIC + "/HyperPulse/Audio")
                        isImage -> Pair(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, Environment.DIRECTORY_PICTURES + "/HyperPulse")
                        else -> Pair(MediaStore.Downloads.EXTERNAL_CONTENT_URI, Environment.DIRECTORY_DOWNLOADS + "/HyperPulse/$category")
                    }

                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                        put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                        put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir)
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }

                    val uri = contentResolver.insert(contentUri, values)
                    if (uri != null) {
                        contentResolver.openOutputStream(uri)?.use { outStream ->
                            file.inputStream().use { inStream ->
                                inStream.copyTo(outStream)
                            }
                        }
                        values.clear()
                        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                        contentResolver.update(uri, values, null, null)
                        Log.d("HyperPulse", "Successfully exported $mimeType to MediaStore URI: $uri ($relativeDir)")
                    }
                } catch (e: Exception) {
                    Log.w("HyperPulse", "MediaStore copy warning: ${e.message}")
                }
            }

            // 3. MediaScannerConnection (Official Android Media Indexer for Gallery and File Managers)
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(targetPublicPath, file.absolutePath),
                arrayOf(mimeType, mimeType)
            ) { path, uri ->
                Log.d("HyperPulse", "MediaScanner indexed: $path -> $uri")
            }

            // 4. Legacy Broadcast
            try {
                val mediaScanIntent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
                mediaScanIntent.data = Uri.fromFile(File(targetPublicPath))
                sendBroadcast(mediaScanIntent)
            } catch (e: Exception) {}

            return targetPublicPath
        } catch (e: Exception) {
            Log.e("HyperPulse", "exportFileToPublicStorage failed: ${e.message}")
            return null
        }
    }

    private fun scanFileForGallery(filePath: String) {
        exportFileToPublicStorage(filePath)
    }

    private fun startHyperPulseForegroundService() {
        try {
            val intent = Intent(this, HyperPulseForegroundService::class.java).apply {
                action = HyperPulseForegroundService.ACTION_START_SERVICE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Throwable) {
            Log.e("MainActivity", "startHyperPulseForegroundService error: ${e.message}")
        }
    }

    private fun stopHyperPulseForegroundService() {
        try {
            val intent = Intent(this, HyperPulseForegroundService::class.java).apply {
                action = HyperPulseForegroundService.ACTION_STOP_SERVICE
            }
            startService(intent)
        } catch (e: Throwable) {
            Log.e("MainActivity", "stopHyperPulseForegroundService error: ${e.message}")
        }
    }

    private fun installApkDirectly(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists()) return false

            val intent = Intent(Intent.ACTION_VIEW).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                val uri = FileProvider.getUriForFile(
                    this@MainActivity,
                    "$packageName.fileprovider",
                    file
                )
                setDataAndType(uri, "application/vnd.android.package-archive")
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun openFileExternally(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists()) return false

            val extension = file.extension.lowercase()
            val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: when (extension) {
                "mp4", "mkv", "webm", "avi", "mov", "flv" -> "video/*"
                "mp3", "m4a", "wav", "flac", "aac", "ogg" -> "audio/*"
                "apk" -> "application/vnd.android.package-archive"
                "zip", "rar", "7z", "tar", "gz" -> "application/zip"
                "pdf" -> "application/pdf"
                "jpg", "jpeg", "png", "webp", "gif" -> "image/*"
                else -> "*/*"
            }

            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
            }
            startActivity(Intent.createChooser(intent, "فتح بواسطة"))
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private val RUNTIME_PERMISSIONS_CODE = 9912

    private fun requestAllAppPermissions(): Boolean {
        return try {
            // Runtime permissions only apply to Android 6.0+ (API 23+)
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                return true
            }

            val permissionsToRequest = mutableListOf<String>()

            // 1. Android 13+ (API 33+) Media & Notification permissions
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    permissionsToRequest.add(android.Manifest.permission.POST_NOTIFICATIONS)
                }
                if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.READ_MEDIA_VIDEO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    permissionsToRequest.add(android.Manifest.permission.READ_MEDIA_VIDEO)
                }
                if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.READ_MEDIA_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    permissionsToRequest.add(android.Manifest.permission.READ_MEDIA_AUDIO)
                }
                if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.READ_MEDIA_IMAGES) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    permissionsToRequest.add(android.Manifest.permission.READ_MEDIA_IMAGES)
                }
            } else {
                // 2. Android 12 and below storage permissions
                if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.READ_EXTERNAL_STORAGE) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    permissionsToRequest.add(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                }
                if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q) {
                    if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        permissionsToRequest.add(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    }
                }
            }

            // Pop up native system dialogs for user to tap "Allow" (سماح)
            if (permissionsToRequest.isNotEmpty()) {
                runOnUiThread {
                    try {
                        androidx.core.app.ActivityCompat.requestPermissions(this, permissionsToRequest.toTypedArray(), RUNTIME_PERMISSIONS_CODE)
                    } catch (e: Throwable) {
                        Log.w("MainActivity", "ActivityCompat.requestPermissions notice: ${e.message}")
                    }
                }
            }
            true
        } catch (e: Throwable) {
            Log.e("MainActivity", "requestAllAppPermissions error: ${e.message}")
            false
        }
    }

    private fun createAppStorageFolders(): Boolean {
        return try {
            val downloadPublic = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (downloadPublic != null) {
                val hpDownload = File(downloadPublic, "HyperPulse")
                if (!hpDownload.exists()) {
                    hpDownload.mkdirs()
                }
                val subDirs = listOf("Apps", "Videos", "Audio", "Archives", "Documents")
                for (sub in subDirs) {
                    val f = File(hpDownload, sub)
                    if (!f.exists()) {
                        f.mkdirs()
                    }
                }
            }

            val moviesPublic = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            if (moviesPublic != null) {
                val hpMovies = File(moviesPublic, "HyperPulse")
                if (!hpMovies.exists()) {
                    hpMovies.mkdirs()
                }
            }

            val musicPublic = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
            if (musicPublic != null) {
                val hpMusic = File(musicPublic, "HyperPulse")
                if (!hpMusic.exists()) {
                    hpMusic.mkdirs()
                }
            }
            true
        } catch (e: Throwable) {
            Log.e("MainActivity", "createAppStorageFolders error: ${e.message}")
            false
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(urlReceiver)
        } catch (e: Exception) {
            // Receiver might not be registered
        }
        try {
            if (!HyperPulseForegroundService.hasActiveDownloads) {
                stopHyperPulseForegroundService()
            }
        } catch (e: Exception) {}
        super.onDestroy()
    }
}
