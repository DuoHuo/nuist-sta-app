package dev.duohuo.nuist_sta_app

import android.content.res.Configuration
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.content.pm.ShortcutManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private var permissionRequestInFlight = false
    private var initialRouteRead = false
    private var initialRoute: String? = null

    override fun shouldHandleDeeplinking(): Boolean = false

    override fun getInitialRoute(): String? {
        if (initialRouteRead) return initialRoute
        initialRouteRead = true
        val route = NotifyStore.timetableLaunchRoute(this, intent)
            ?: if (intent?.dataString == NextDayReminder.OPEN_URI) "/apps/timetable?focus=tomorrow" else null
        // 可信系统入口在 Flutter 第一帧前决定目标；其余 Intent 沿用普通启动。
        initialRoute = when (route) {
            NotifyStore.ROUTE_TIMETABLE,
            NotifyStore.ROUTE_TIMETABLE_NEXT_WEEK,
            NotifyStore.ROUTE_TIMETABLE_WIDGET_SETTINGS,
            "/apps/timetable?focus=tomorrow" -> route
            else -> super.getInitialRoute()
        }
        return initialRoute
    }

    override fun onNewIntent(intent: Intent) {
        // Flutter 插件在 super 内分发 Intent；由同一 openRoute 通道处理所有点击，避免双重压栈。
        if (intent.action == NotifyStore.widgetSettingsAction(this)) {
            intent.putExtra(NotifyStore.EXTRA_ROUTE, NotifyStore.ROUTE_TIMETABLE_WIDGET_SETTINGS)
        } else if (intent.dataString == NextDayReminder.OPEN_URI) {
            intent.putExtra(NotifyStore.EXTRA_ROUTE, "/apps/timetable?focus=tomorrow")
            intent.data = null
        }
        // Glance 用内部 URI 区分点击动作；交给提醒插件处理，不能作为 Flutter 深链。
        if (intent.hasExtra(NotifyStore.EXTRA_ROUTE) && intent.data?.scheme == "glance-action") {
            intent.data = null
        }
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (intent?.dataString == NextDayReminder.OPEN_URI) {
            intent.putExtra(NotifyStore.EXTRA_ROUTE, "/apps/timetable?focus=tomorrow")
            intent.data = null
        }
        if (intent?.hasExtra(NotifyStore.EXTRA_ROUTE) == true && intent?.data?.scheme == "glance-action") {
            intent.data = null
        }
        // 旧版 WidgetPin 动态快捷方式覆盖安装后会残留（id=add_timetable_widget，文案「添加小组件」）。
        clearLegacyShortcuts()
        super.configureFlutterEngine(flutterEngine)
        // 只接收 Dart 日志层已清洗的摘要，保留 logcat 原生严重程度。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nuist/diagnostic_logging")
            .setMethodCallHandler { call, result ->
                val method = call.method
                if (method in setOf("readNativeDiagnostics", "acknowledgeNativeDiagnostics", "clearNativeDiagnostics")) {
                    val appContext = applicationContext
                    val ids = if (method == "acknowledgeNativeDiagnostics") {
                        call.argument<List<String>>("ids")?.toSet() ?: emptySet()
                    } else {
                        emptySet()
                    }
                    TimetableNativeWork.reply(
                        result,
                        "native_diagnostics_unavailable",
                        "原生诊断队列暂不可用",
                        "diagnostics.$method",
                        action = {
                            when (method) {
                                "readNativeDiagnostics" -> NativeBackgroundDiagnostics.read(appContext)
                                "acknowledgeNativeDiagnostics" -> {
                                    NativeBackgroundDiagnostics.acknowledge(appContext, ids)
                                    null
                                }
                                else -> {
                                    NativeBackgroundDiagnostics.clear(appContext)
                                    null
                                }
                            }
                        },
                    )
                } else if (method != "write") {
                    result.notImplemented()
                } else {
                    val args = call.arguments as? Map<*, *>
                    val level = (args?.get("level") as? Number)?.toInt()
                    val message = args?.get("message") as? String
                    val priority = when (level) {
                        0 -> Log.DEBUG
                        1 -> Log.INFO
                        2 -> Log.WARN
                        3, 4 -> Log.ERROR
                        else -> null
                    }
                    if (priority == null || message == null) {
                        result.error("arguments", "日志参数无效", null)
                    } else {
                        // 每片最多约 3 KiB UTF-8，避免 logcat 截断长堆栈。
                        message.lineSequence().forEach { line ->
                            line.chunked(1000).forEach { Log.println(priority, "flutter.NUIST++", it) }
                        }
                        result.success(null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nuist/timetable_next_day")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("arguments", "缺少明日提醒配置", null)
                        } else {
                            val context = applicationContext
                            TimetableNativeWork.reply(result, "schedule", "明日提醒暂不可用", "next_day.update", action = {
                                val diagnostics = mutableListOf<Map<String, Any?>>()
                                val saved = NextDayReminder.update(context, args, diagnostics)
                                saved to diagnostics
                            }, onSuccess = { value ->
                                @Suppress("UNCHECKED_CAST")
                                val (saved, diagnostics) = value as Pair<Boolean, MutableList<Map<String, Any?>>>
                                if (saved) {
                                    result.success(mapOf("diagnostics" to diagnostics))
                                } else result.error("storage", "明日提醒配置保存失败", null)
                            })
                        }
                    }
                    "requestPermission" -> requestReminderPermission(result)
                    else -> result.notImplemented()
                }
            }
        if (!flutterEngine.plugins.has(AttachmentPdfPreviewPlugin::class.java)) {
            flutterEngine.plugins.add(AttachmentPdfPreviewPlugin())
        }
        BulletinAttachmentActions.register(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            BulletinOfficeViewFactory.VIEW_TYPE,
            BulletinOfficeViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        if (!flutterEngine.plugins.has(ClientMetadataPlugin::class.java)) {
            flutterEngine.plugins.add(ClientMetadataPlugin())
        }
        if (!flutterEngine.plugins.has(DeviceLocationPlugin::class.java)) {
            flutterEngine.plugins.add(DeviceLocationPlugin())
        }
        if (!flutterEngine.plugins.has(NotifyWidgetPlugin::class.java)) {
            flutterEngine.plugins.add(NotifyWidgetPlugin())
        }
        if (!flutterEngine.plugins.has(AppUpdatePlugin::class.java)) {
            flutterEngine.plugins.add(AppUpdatePlugin())
        }
        if (!flutterEngine.plugins.has(AppIconPlugin::class.java)) {
            flutterEngine.plugins.add(AppIconPlugin())
        }
    }

    // 明暗切换（configChanges 含 uiMode，Activity 不重建）：桌面小组件按新配色重绘。
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val context = applicationContext
        TimetableNativeWork.background(context, "widget.configuration", "widget_configuration_refresh_failed") {
            TimetableWidgetProvider.refreshIfNightChanged(context)
        }
    }

    private fun requestReminderPermission(result: MethodChannel.Result?) {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result?.success(true)
            return
        }
        if (NotifyStore.notificationPermissionInFlight || permissionRequestInFlight) {
            result?.success(false)
            return
        }
        NotifyStore.notificationPermissionInFlight = true
        permissionRequestInFlight = true
        permissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2202)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 2202) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            permissionResult?.success(granted)
            permissionResult = null
            if (permissionRequestInFlight) {
                permissionRequestInFlight = false
                NotifyStore.notificationPermissionInFlight = false
            }
            if (granted) {
                val context = applicationContext
                TimetableNativeWork.background(context, "next_day.permission_reschedule", "next_day_dispatch_failed") {
                    NextDayReminder.reschedule(context, it)
                }
            }
        }
    }

    override fun onDestroy() {
        if (permissionRequestInFlight) {
            permissionRequestInFlight = false
            NotifyStore.notificationPermissionInFlight = false
        }
        permissionResult = null
        super.onDestroy()
    }

    /** 清除旧版动态 shortcut，并禁用可能被用户 pinned 的旧 id，避免长按图标出现无效「添加小组件」。
     *  不碰 AppWidgetProvider：系统桌面「小组件」入口是系统行为，应保留。 */
    private fun clearLegacyShortcuts() {
        val context = applicationContext
        TimetableNativeWork.background(context, "shortcut.clear_legacy", "legacy_shortcut_clear_failed") {
            try {
                val prefs = context.getSharedPreferences("timetable_legacy_cleanup", MODE_PRIVATE)
                if (prefs.getBoolean("legacy_shortcuts_cleared_v1", false)) return@background
                val sm = context.getSystemService(ShortcutManager::class.java) ?: return@background
                var transientFailure = false
                try {
                    sm.removeDynamicShortcuts(listOf("add_timetable_widget"))
                } catch (_: IllegalArgumentException) {
                    // 本机没有这个旧动态 shortcut 时继续禁用可能已固定到桌面的旧 id。
                } catch (_: IllegalStateException) {
                    // 桌面/系统暂时不可用时仍尝试禁用旧 id。
                    transientFailure = true
                }
                try {
                    sm.disableShortcuts(listOf("add_timetable_widget"))
                } catch (_: IllegalArgumentException) {
                    // 本机从未发布过该 id（干净安装）时忽略。
                } catch (_: IllegalStateException) {
                    // 桌面/系统暂时不可用时忽略。
                    transientFailure = true
                }
                if (!transientFailure) {
                    prefs.edit().putBoolean("legacy_shortcuts_cleared_v1", true).apply()
                }
            } catch (_: Exception) {
                // shortcut 清理失败不影响启动。
            }
        }
    }

}
