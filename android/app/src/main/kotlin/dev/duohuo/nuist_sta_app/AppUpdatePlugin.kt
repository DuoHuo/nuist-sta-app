package dev.duohuo.nuist_sta_app

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

/** 应用内更新桥接；下载归前台服务管理，安装只由前台用户动作触发。 */
class AppUpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, PluginRegistry.NewIntentListener,
    PluginRegistry.RequestPermissionsResultListener, Application.ActivityLifecycleCallbacks {
    private lateinit var app: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var binding: ActivityPluginBinding? = null
    private var sink: EventChannel.EventSink? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var attached = false
    @Volatile private var resumed = false
    private var pendingOpen = false
    private var permissionResult: MethodChannel.Result? = null
    private var notificationResultReady = false
    private val listener: () -> Unit = { if (attached) sink?.success(AppUpdateStore.snapshot()) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        AppUpdateStore.initialize(app)
        methods = MethodChannel(binding.binaryMessenger, "nuist/app_update")
        events = EventChannel(binding.binaryMessenger, "nuist/app_update/events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        AppUpdateStore.listeners.add(listener)
        (app as Application).registerActivityLifecycleCallbacks(this)
        attached = true
        instance = WeakReference(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        AppUpdateStore.listeners.remove(listener)
        (app as Application).unregisterActivityLifecycleCallbacks(this)
        sink = null
        AppUpdateDiagnostics.listener = null
        worker.shutdownNow()
        if (instance?.get() === this) instance = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        AppUpdateDiagnostics.listener = { event -> if (attached) sink?.success(event) }
        events.success(AppUpdateStore.snapshot())
    }
    override fun onCancel(arguments: Any?) {
        sink = null
        AppUpdateDiagnostics.listener = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getState" -> result.success(AppUpdateStore.snapshot())
                "takeLaunchRequest" -> {
                    result.success(pendingOpen)
                    pendingOpen = false
                }
                "requestNotificationPermission" -> requestNotifications(result)
                "openInstallSettings" -> {
                    val activity = foregroundActivity()
                    if (Build.VERSION.SDK_INT >= 26 && !AppUpdateStore.installAllowed(app)) {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${app.packageName}")))
                    }
                    result.success(true)
                }
                "startDownload" -> {
                    foregroundActivity()
                    val release = AppUpdateRelease.parse(call.argument<Map<*, *>>("release")
                        ?: throw AppUpdateFailure("invalid_release"))
                    val headers = call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>()
                    val token = AppUpdateStore.prepare(release, headers)
                    startService(token)
                    result.success(AppUpdateStore.snapshot())
                }
                "resumeDownload" -> {
                    foregroundActivity()
                    val release = AppUpdateStore.release ?: throw AppUpdateFailure("no_download")
                    if (AppUpdateStore.status == "revoked") throw AppUpdateFailure("revoked")
                    val token = AppUpdateStore.prepare(release, AppUpdateStore.headers)
                    startService(token)
                    result.success(AppUpdateStore.snapshot())
                }
                "cancelDownload" -> {
                    if (AppUpdateStore.status == "installing") throw AppUpdateFailure("busy")
                    AppUpdateStore.cancel()
                    app.stopService(Intent(app, AppUpdateService::class.java))
                    app.getSystemService(NotificationManager::class.java)?.cancel(AppUpdateService.NOTIFICATION_ID)
                    result.success(AppUpdateStore.snapshot())
                }
                "install" -> beginInstall(result)
                else -> result.notImplemented()
            }
        } catch (failure: AppUpdateFailure) {
            result.error(failure.code, "更新操作暂时无法完成", null)
        } catch (_: Exception) {
            result.error("update_failed", "更新操作暂时无法完成", null)
        }
    }

    private fun startService(token: Long) {
        val intent = Intent(app, AppUpdateService::class.java).putExtra(AppUpdateService.EXTRA_TOKEN, token)
        try {
            AppUpdateStore.update(token, "downloading")
            if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent) else app.startService(intent)
        } catch (failure: AppUpdateFailure) {
            // 状态落盘失败时服务尚未启动，仍须在内存中恢复可重试状态。
            AppUpdateStore.update(token, "paused", error = failure.code, save = false)
            throw failure
        } catch (_: Exception) {
            try { AppUpdateStore.update(token, "paused", error = "foreground_unavailable") } catch (_: Exception) { }
            throw AppUpdateFailure("foreground_unavailable")
        }
    }

    private fun foregroundActivity(): Activity {
        val activity = binding?.activity
        if (!resumed || activity == null || activity.isFinishing || activity.isDestroyed) {
            throw AppUpdateFailure("foreground_required")
        }
        return activity
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        val activity = foregroundActivity()
        if (Build.VERSION.SDK_INT < 33 || AppUpdateStore.notificationsAllowed(app)) {
            result.success(AppUpdateStore.notificationsAllowed(app))
            return
        }
        if (permissionResult != null) throw AppUpdateFailure("busy")
        permissionResult = result
        notificationResultReady = false
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != NOTIFICATION_REQUEST) return false
        notificationResultReady = true
        completeNotificationRequest()
        AppUpdateStore.notifyChanged()
        return true
    }

    private fun completeNotificationRequest() {
        // 系统可能先返回权限结果再恢复 Activity；等恢复后再让 Dart 继续启动前台服务。
        if (!resumed || !notificationResultReady) return
        permissionResult?.success(AppUpdateStore.notificationsAllowed(app))
        permissionResult = null
        notificationResultReady = false
    }

    private fun beginInstall(result: MethodChannel.Result) {
        foregroundActivity()
        if (!AppUpdateStore.installAllowed(app)) throw AppUpdateFailure("install_permission")
        if (AppUpdateStore.status != "ready") throw AppUpdateFailure("not_ready")
        val item = AppUpdateStore.release ?: throw AppUpdateFailure("no_download")
        val token = AppUpdateStore.token
        try {
            AppUpdateStore.update(token, "installing")
        } catch (failure: AppUpdateFailure) {
            // 安装尚未启动；即使存储仍不可写，也必须恢复安装与取消入口。
            installFailed(token, failure.code)
            throw failure
        }
        worker.execute {
            var sessionId = -1
            try {
                val file = AppUpdateStore.completeFile(item)
                AppUpdateStore.verify(item, file) { AppUpdateStore.active(token) && !Thread.currentThread().isInterrupted }
                AppUpdateHttp.check(item, AppUpdateStore.headers)
                val installer = app.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(item.packageName)
                    setSize(item.size)
                    if (Build.VERSION.SDK_INT >= 26) setInstallReason(PackageManager.INSTALL_REASON_USER)
                    if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                }
                sessionId = installer.createSession(params)
                AppUpdateStore.setSession(token, sessionId)
                installer.openSession(sessionId).use { session ->
                    file.inputStream().use { input ->
                        session.openWrite("base.apk", 0, item.size).use { output ->
                            val buffer = ByteArray(65536)
                            while (true) {
                                if (!AppUpdateStore.active(token) || Thread.currentThread().isInterrupted) throw AppUpdateFailure("cancelled")
                                val count = input.read(buffer)
                                if (count < 0) break
                                output.write(buffer, 0, count)
                            }
                            session.fsync(output)
                        }
                    }
                }
                // 拷贝安装会话可能耗时，提交前再次查询精确修订的撤包状态。
                AppUpdateHttp.check(item, AppUpdateStore.headers)
                val finalSession = sessionId
                main.post {
                    try {
                        foregroundActivity()
                        if (!AppUpdateStore.active(token)) throw AppUpdateFailure("cancelled")
                        val callback = Intent(app, AppUpdateInstallReceiver::class.java)
                            .setAction("nuist.app_update.INSTALL_RESULT")
                            .setData(Uri.parse("nuist-update://install/$finalSession"))
                            .putExtra(AppUpdateService.EXTRA_TOKEN, token)
                        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                        val pending = PendingIntent.getBroadcast(app, finalSession, callback, flags)
                        installer.openSession(finalSession).use { it.commit(pending.intentSender) }
                        result.success(AppUpdateStore.snapshot())
                    } catch (failure: AppUpdateFailure) {
                        installFailed(token, failure.code)
                        result.error(failure.code, "安装暂时无法继续", null)
                    } catch (_: Exception) {
                        installFailed(token, "install_failed")
                        result.error("install_failed", "安装暂时无法继续", null)
                    }
                }
            } catch (failure: AppUpdateFailure) {
                installFailed(token, failure.code)
                main.post { result.error(failure.code, "安装暂时无法继续", null) }
            } catch (_: IOException) {
                installFailed(token, "network")
                main.post { result.error("network", "暂时无法确认更新状态", null) }
            } catch (_: Exception) {
                installFailed(token, "install_failed")
                main.post { result.error("install_failed", "安装暂时无法继续", null) }
            }
        }
    }

    /** 安装器要求用户确认时，只在应用仍位于前台且版本未撤销时显示系统界面。 */
    private fun showInstallConfirmation(intent: Intent, token: Long): Boolean {
        if (!attached || !resumed) return false
        worker.execute {
            try {
                val item = AppUpdateStore.release ?: throw AppUpdateFailure("cancelled")
                AppUpdateHttp.check(item, AppUpdateStore.headers)
                main.post {
                    try {
                        if (!AppUpdateStore.active(token)) throw AppUpdateFailure("cancelled")
                        foregroundActivity().startActivity(intent)
                    } catch (_: Exception) {
                        installFailed(token, "foreground_required")
                        AppUpdateService.notifyReady(app)
                    }
                }
            } catch (failure: AppUpdateFailure) {
                installFailed(token, failure.code)
            } catch (_: Exception) {
                installFailed(token, "network")
            }
        }
        return true
    }

    override fun onNewIntent(intent: Intent): Boolean {
        if (!intent.getBooleanExtra(AppUpdateService.EXTRA_OPEN, false)) return false
        intent.removeExtra(AppUpdateService.EXTRA_OPEN)
        methods.invokeMethod("onOpenUpdate", null)
        return true
    }

    private fun attach(value: ActivityPluginBinding) {
        binding = value
        value.addOnNewIntentListener(this)
        value.addRequestPermissionsResultListener(this)
        if (value.activity.intent?.getBooleanExtra(AppUpdateService.EXTRA_OPEN, false) == true) {
            pendingOpen = true
            value.activity.intent.removeExtra(AppUpdateService.EXTRA_OPEN)
        }
    }
    private fun detach() {
        binding?.removeOnNewIntentListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        resumed = false
        permissionResult?.success(AppUpdateStore.notificationsAllowed(app))
        permissionResult = null
        notificationResultReady = false
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() = detach()
    override fun onActivityResumed(activity: Activity) {
        if (binding?.activity === activity) {
            resumed = true
            completeNotificationRequest()
            AppUpdateStore.notifyChanged()
        }
    }
    override fun onActivityPaused(activity: Activity) { if (binding?.activity === activity) resumed = false }
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit

    companion object {
        private const val NOTIFICATION_REQUEST = 0x4E76
        private var instance: WeakReference<AppUpdatePlugin>? = null

        internal fun deliverInstallConfirmation(intent: Intent, token: Long): Boolean =
            instance?.get()?.showInstallConfirmation(intent, token) == true

        internal fun installFailed(token: Long, code: String) {
            if (!AppUpdateStore.active(token)) return
            try {
                AppUpdateStore.abandonSession()
                if (code == "revoked") AppUpdateStore.cancel(token, revoked = true)
                else {
                    val invalid = code in setOf("hash_mismatch", "size_mismatch", "incompatible")
                    if (invalid) AppUpdateStore.release?.let(AppUpdateStore::deleteFiles)
                    AppUpdateStore.update(token, if (invalid) "failed" else "ready", error = code)
                }
            } catch (_: Exception) { }
        }
    }
}

/** 系统安装结果回调；不读取系统异常正文，不在后台直接拉起安装确认页面。 */
class AppUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AppUpdateStore.initialize(context)
        val token = intent.getLongExtra(AppUpdateService.EXTRA_TOKEN, -1)
        val session = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (!AppUpdateStore.active(token) || session < 0 || session != AppUpdateStore.sessionId) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val prompt = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (prompt == null || !AppUpdatePlugin.deliverInstallConfirmation(prompt, token)) {
                    AppUpdatePlugin.installFailed(token, "foreground_required")
                    AppUpdateService.notifyReady(context)
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                try { AppUpdateStore.cancel(token) } catch (_: Exception) { }
                context.getSystemService(NotificationManager::class.java)?.cancel(AppUpdateService.NOTIFICATION_ID)
            }
            PackageInstaller.STATUS_FAILURE_ABORTED -> AppUpdatePlugin.installFailed(token, "install_cancelled")
            PackageInstaller.STATUS_FAILURE_BLOCKED -> AppUpdatePlugin.installFailed(token, "install_blocked")
            PackageInstaller.STATUS_FAILURE_STORAGE -> AppUpdatePlugin.installFailed(token, "insufficient_storage")
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> AppUpdatePlugin.installFailed(token, "incompatible")
            else -> AppUpdatePlugin.installFailed(token, "install_failed")
        }
    }
}
