package dev.duohuo.nuist_sta_app

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** 课表提醒 / 桌面小组件桥接，通道 `dev.duohuo.nuist_sta_app/notify_widget`。 */
class NotifyWidgetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, PluginRegistry.NewIntentListener {

    private lateinit var channel: MethodChannel
    private lateinit var app: Context
    private var binding: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null

    /**
     * ACTION_CONFIGURATION_CHANGED 只能运行时注册（API 26+ 清单接收器收不到）：
     * 进程存活期间系统明暗切换时重绘小组件。进程不在时由 onUpdate / 下一次定时刷新兜底，
     * API 31+ 另有 setColorInt 让桌面自行切换。
     */
    private val configReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            TimetableWidgetProvider.refreshIfNightChanged(context)
        }
    }

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        app = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        try {
            app.registerReceiver(configReceiver, IntentFilter(Intent.ACTION_CONFIGURATION_CHANGED))
        } catch (_: Exception) {
        }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        try {
            app.unregisterReceiver(configReceiver)
        } catch (_: Exception) {
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "scheduleReminders" -> {
                    ReminderScheduler.replace(app, call.argument<String>("alarms") ?: "[]")
                    result.success(null)
                }
                "cancelReminders" -> {
                    ReminderScheduler.cancelAll(app)
                    result.success(null)
                }
                "updateWidget" -> {
                    TimetableWidgetProvider.savePayload(app, call.argument<String>("payload") ?: "")
                    result.success(null)
                }
                "permissionStatus" -> result.success(status())
                "requestNotificationPermission" -> requestNotification(result)
                "openExactAlarmSettings" -> result.success(openExactAlarm())
                "openBatteryOptimizationSettings" -> result.success(openBattery())
                "openNotificationSettings" -> result.success(openNotificationSettings())
                "takeLaunchRoute" -> {
                    val p = NotifyStore.prefs(app)
                    val r = p.getString(NotifyStore.KEY_PENDING_ROUTE, null)
                    p.edit().remove(NotifyStore.KEY_PENDING_ROUTE).apply()
                    result.success(r)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            result.error("notify_failed", "操作失败", null)
        }
    }

    private fun notificationsGranted(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        return app.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() ?: false
    }

    private fun status(): Map<String, Boolean> {
        val pm = app.getSystemService(PowerManager::class.java)
        return mapOf(
            "notifications" to notificationsGranted(),
            "exactAlarm" to NotifyStore.canExact(app),
            "ignoringBattery" to (pm?.isIgnoringBatteryOptimizations(app.packageName) ?: false),
        )
    }

    private fun requestNotification(result: MethodChannel.Result) {
        val act = binding?.activity
        if (Build.VERSION.SDK_INT < 33 || notificationsGranted() || act == null) {
            result.success(notificationsGranted())
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        act.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_NOTIFY) return false
        pendingPermission?.success(notificationsGranted())
        pendingPermission = null
        return true
    }

    private fun start(intent: Intent): Boolean {
        val ctx: Context = binding?.activity ?: app
        if (ctx !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun appDetails() = Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${app.packageName}"),
    )

    private fun openExactAlarm(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return start(
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${app.packageName}")),
        ) || start(appDetails())
    }

    private fun openBattery(): Boolean {
        val pm = app.getSystemService(PowerManager::class.java)
        val ignoring = pm?.isIgnoringBatteryOptimizations(app.packageName) ?: false
        if (!ignoring && start(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${app.packageName}"),
                ),
            )
        ) return true
        return start(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
            start(appDetails())
    }

    private fun openNotificationSettings(): Boolean {
        val i = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
        } else appDetails()
        return start(i) || start(appDetails())
    }

    override fun onNewIntent(intent: Intent): Boolean {
        val route = intent.getStringExtra(NotifyStore.EXTRA_ROUTE) ?: return false
        intent.removeExtra(NotifyStore.EXTRA_ROUTE)
        channel.invokeMethod("openRoute", route)
        return true
    }

    private fun attach(b: ActivityPluginBinding) {
        binding = b
        b.addRequestPermissionsResultListener(this)
        b.addOnNewIntentListener(this)
        // 冷启动时的点击路由：存起来等 Dart 侧 takeLaunchRoute 取。
        val intent = b.activity.intent
        val route = intent?.getStringExtra(NotifyStore.EXTRA_ROUTE)
            ?: if (intent?.dataString == NextDayReminder.OPEN_URI) "/apps/timetable?focus=tomorrow" else null
        route?.let {
            NotifyStore.prefs(app).edit().putString(NotifyStore.KEY_PENDING_ROUTE, it).apply()
            intent?.removeExtra(NotifyStore.EXTRA_ROUTE)
        }
    }

    private fun detach() {
        binding?.removeRequestPermissionsResultListener(this)
        binding?.removeOnNewIntentListener(this)
        binding = null
        pendingPermission?.success(notificationsGranted())
        pendingPermission = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) = attach(b)
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = attach(b)
    override fun onDetachedFromActivity() = detach()

    companion object {
        const val CHANNEL = "dev.duohuo.nuist_sta_app/notify_widget"
        private const val REQ_NOTIFY = 0x4E57
    }
}
