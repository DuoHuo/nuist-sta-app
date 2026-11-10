package dev.duohuo.nuist_sta_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.util.concurrent.Executors

/** 用户主动下载时运行的 dataSync 前台服务，任务不依赖 Flutter 页面或引擎存活。 */
class AppUpdateService : Service() {
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var stopping = false
    private var running = false
    private var taskToken = -1L
    private val main = Handler(Looper.getMainLooper())
    private var nextStart: Pair<Intent, Int>? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        AppUpdateStore.initialize(this)
        createChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val token = intent?.getLongExtra(EXTRA_TOKEN, -1) ?: -1
        if (running) {
            if (token != taskToken && token >= 0 && AppUpdateStore.active(token) && intent != null) {
                nextStart = intent to startId
                connection?.disconnect()
            }
            return START_NOT_STICKY
        }
        if (token < 0 || !AppUpdateStore.active(token)) {
            if (!running) stopSelf()
            return START_NOT_STICKY
        }
        taskToken = token
        running = true
        stopping = false
        try {
            val notice = notification(this, "准备下载更新", true)
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION_ID, notice)
        } catch (_: Exception) {
            failSafely(token, "foreground_unavailable")
            stopSelf()
            return START_NOT_STICKY
        }
        worker.execute {
            try {
                download(token)
            } catch (failure: AppUpdateFailure) {
                if (failure.code == "revoked") {
                    try { AppUpdateStore.cancel(token, revoked = true) } catch (_: Exception) { }
                } else if (failure.code != "cancelled" && active(token)) {
                    val keep = failure.code in setOf("network", "storage", "insufficient_storage", "timeout")
                    try {
                        if (!keep) AppUpdateStore.guarded(token) {
                            AppUpdateStore.release?.let { AppUpdateStore.deleteFiles(it) }
                        }
                        AppUpdateStore.update(token, if (keep) "paused" else "failed", error = failure.code)
                    } catch (_: Exception) { }
                }
            } catch (_: IOException) {
                failSafely(token, "network")
            } catch (_: Exception) {
                failSafely(token, "download_failed")
            } finally {
                connection?.disconnect()
                connection = null
                main.post {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    if (AppUpdateStore.active(token) && AppUpdateStore.status == "ready") notifyReady(this)
                    running = false
                    val next = nextStart
                    nextStart = null
                    if (!stopping && next != null) onStartCommand(next.first, 0, next.second)
                    else stopSelf(startId)
                }
            }
        }
        // 系统或用户停止后只保存断点；下一次前台操作恢复，不利用开机或后台广播复活服务。
        return START_NOT_STICKY
    }

    private fun active(token: Long) = !stopping && AppUpdateStore.active(token) && !Thread.currentThread().isInterrupted

    private fun download(token: Long) {
        val item = AppUpdateStore.release ?: throw AppUpdateFailure("cancelled")
        val headers = AppUpdateStore.headers
        AppUpdateHttp.check(item, headers)
        if (!active(token)) throw AppUpdateFailure("cancelled")
        val complete = AppUpdateStore.completeFile(item)
        val part = AppUpdateStore.partFile(item)
        if (!complete.exists()) {
            var offset = part.length()
            if (offset > item.size || (offset > 0 && !AppUpdateStore.validEtag(AppUpdateStore.etag ?: ""))) {
                AppUpdateStore.guarded(token) { part.delete() }
                offset = 0
            }
            if (StatFs(AppUpdateStore.directory().path).availableBytes < item.size - offset + 16L * 1024 * 1024) {
                throw AppUpdateFailure("insufficient_storage")
            }
            if (offset < item.size) {
                val request = AppUpdateHttp.connect(item.downloadUrl, headers)
                connection = request
                if (offset > 0) {
                    request.setRequestProperty("Range", "bytes=$offset-")
                    request.setRequestProperty("If-Range", AppUpdateStore.etag)
                }
                offset = AppUpdateHttp.downloadOffset(request.responseCode, offset, item.size,
                    request.getHeaderField("Content-Range"), AppUpdateStore.etag, request.getHeaderField("ETag"))
                val encoding = request.getHeaderField("Content-Encoding")
                if (!encoding.isNullOrEmpty() && !encoding.equals("identity", true)) throw AppUpdateFailure("invalid_response")
                val length = request.getHeaderField("Content-Length")?.toLongOrNull()
                if (length != null && length != item.size - offset) throw AppUpdateFailure("size_mismatch")
                val etag = request.getHeaderField("ETag")?.takeIf(AppUpdateStore::validEtag)
                AppUpdateStore.update(token, "downloading", offset, nextEtag = etag)
                var count = offset
                var lastEvent = 0L
                var lastSave = 0L
                var lastCheck = android.os.SystemClock.elapsedRealtime()
                request.inputStream.use { input ->
                    AppUpdateStore.guarded(token) {
                        RandomAccessFile(part, "rw").apply {
                            try { setLength(offset); seek(offset) }
                            catch (_: Exception) { close(); throw AppUpdateFailure("storage") }
                        }
                    }.use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            if (!active(token)) throw AppUpdateFailure("cancelled")
                            val read = input.read(buffer)
                            if (read < 0) break
                            if (count + read > item.size) throw AppUpdateFailure("size_mismatch")
                            try { output.write(buffer, 0, read) }
                            catch (_: IOException) { throw AppUpdateFailure("storage") }
                            count += read
                            val now = android.os.SystemClock.elapsedRealtime()
                            if (now - lastEvent >= 500) {
                                val save = now - lastSave >= 2000
                                if (save) {
                                    try { output.fd.sync() } catch (_: IOException) { throw AppUpdateFailure("storage") }
                                    lastSave = now
                                }
                                AppUpdateStore.update(token, "downloading", count, nextEtag = etag, save = save)
                                updateNotification("正在下载更新")
                                lastEvent = now
                            }
                            if (now - lastCheck >= 30000) {
                                AppUpdateHttp.check(item, headers)
                                lastCheck = now
                            }
                        }
                        try { output.fd.sync() } catch (_: IOException) { throw AppUpdateFailure("storage") }
                    }
                }
                request.disconnect()
                connection = null
                if (count != item.size) throw AppUpdateFailure("network")
            }
        }
        if (!active(token)) throw AppUpdateFailure("cancelled")
        AppUpdateStore.update(token, "verifying", item.size)
        updateNotification("正在校验安装包")
        AppUpdateStore.verify(item, if (complete.exists()) complete else part) { active(token) }
        AppUpdateHttp.check(item, headers)
        if (!active(token)) throw AppUpdateFailure("cancelled")
        AppUpdateStore.guarded(token) {
            if (!complete.exists() && !part.renameTo(complete)) throw AppUpdateFailure("storage")
        }
        AppUpdateStore.update(token, "ready", item.size)
    }

    private fun updateNotification(text: String) {
        try {
            getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(this, text, true))
        } catch (_: SecurityException) { /* 通知权限被拒仍可完成前台服务的传输。 */ }
    }

    private fun failSafely(token: Long, error: String) {
        if (active(token)) {
            try { AppUpdateStore.update(token, "paused", error = error) } catch (_: Exception) { }
        }
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        failSafely(taskToken, "timeout")
        stopping = true
        connection?.disconnect()
        worker.shutdownNow()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (AppUpdateStore.status in setOf("downloading", "verifying")) failSafely(taskToken, "interrupted")
        stopping = true
        connection?.disconnect()
        worker.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "app_update_download"
        const val NOTIFICATION_ID = 0x4E75
        const val EXTRA_TOKEN = "nuist_update_task"
        const val EXTRA_OPEN = "nuist_update_open"

        fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= 26) context.getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(NotificationChannel(CHANNEL_ID, "应用更新", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "下载应用更新时显示进度和取消入口"
                })
        }

        fun notifyReady(context: Context) {
            if (!AppUpdateStore.notificationsAllowed(context)) return
            createChannel(context)
            try {
                context.getSystemService(NotificationManager::class.java)
                    ?.notify(NOTIFICATION_ID, notification(context, "更新已下载，点击回到应用安装", false))
            } catch (_: SecurityException) { }
        }

        private fun notification(context: Context, text: String, ongoing: Boolean): Notification {
            val open = Intent(context, MainActivity::class.java).putExtra(EXTRA_OPEN, true)
                .setAction("nuist.app_update.OPEN")
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val view = PendingIntent.getActivity(context, NOTIFICATION_ID, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL_ID)
                else Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
            builder.setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("NUIST++ 应用更新").setContentText(text).setContentIntent(view)
                .setOnlyAlertOnce(true).setOngoing(ongoing).setAutoCancel(!ongoing)
                .setCategory(Notification.CATEGORY_PROGRESS)
            if (ongoing) {
                val size = AppUpdateStore.release?.size ?: 0
                val percent = if (size > 0) ((AppUpdateStore.bytes * 100) / size).toInt().coerceIn(0, 100) else 0
                builder.setProgress(100, percent, AppUpdateStore.status != "downloading")
                val cancel = Intent(context, AppUpdateActionReceiver::class.java)
                    .putExtra(EXTRA_TOKEN, AppUpdateStore.token).setAction("nuist.app_update.CANCEL")
                val action = PendingIntent.getBroadcast(context, NOTIFICATION_ID, cancel,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                builder.addAction(Notification.Action.Builder(null, "取消下载", action).build())
            }
            return builder.build()
        }
    }
}

/** 通知只允许取消明确的当前任务，不接受外部下载地址或文件路径。 */
class AppUpdateActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AppUpdateStore.initialize(context)
        val token = intent.getLongExtra(AppUpdateService.EXTRA_TOKEN, -1)
        if (intent.action != "nuist.app_update.CANCEL" || token != AppUpdateStore.token) return
        try {
            AppUpdateStore.cancel(token)
            context.stopService(Intent(context, AppUpdateService::class.java))
            context.getSystemService(NotificationManager::class.java)?.cancel(AppUpdateService.NOTIFICATION_ID)
        } catch (_: Exception) { }
    }
}
