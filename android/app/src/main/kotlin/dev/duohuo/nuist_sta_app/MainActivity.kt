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

    override fun onNewIntent(intent: Intent) {
        // Flutter 插件在 super 内分发 Intent；由同一 openRoute 通道处理所有点击，避免双重压栈。
        if (intent.dataString == NextDayReminder.OPEN_URI) {
            intent.putExtra(NotifyStore.EXTRA_ROUTE, "/apps/timetable?focus=tomorrow")
        }
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // 旧版 WidgetPin 动态快捷方式覆盖安装后会残留（id=add_timetable_widget，文案「添加小组件」）。
        clearLegacyShortcuts()
        super.configureFlutterEngine(flutterEngine)
        // 只接收 Dart 日志层已清洗的摘要，保留 logcat 原生严重程度。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nuist/diagnostic_logging")
            .setMethodCallHandler { call, result ->
                if (call.method != "write") {
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
                            try {
                                if (NextDayReminder.update(this, args)) {
                                    result.success(null)
                                    // 默认开：首次有可用缓存时申请一次，不在每次启动重复询问。
                                    val prefs = getSharedPreferences("timetable_next_day", MODE_PRIVATE)
                                    if (args["enabled"] == true && !prefs.getBoolean("permissionAsked", false)) {
                                        requestReminderPermission(null)
                                    }
                                } else result.error("storage", "明日提醒配置保存失败", null)
                            } catch (_: RuntimeException) {
                                result.error("schedule", "明日提醒暂不可用", null)
                            }
                        }
                    }
                    "requestPermission" -> requestReminderPermission(result)
                    else -> result.notImplemented()
                }
            }
        if (!flutterEngine.plugins.has(AttachmentPdfPreviewPlugin::class.java)) {
            flutterEngine.plugins.add(AttachmentPdfPreviewPlugin())
        }
        if (!flutterEngine.plugins.has(NotifyWidgetPlugin::class.java)) {
            flutterEngine.plugins.add(NotifyWidgetPlugin())
        }
    }

    // 明暗切换（configChanges 含 uiMode，Activity 不重建）：桌面小组件按新配色重绘。
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        TimetableWidgetProvider.refreshIfNightChanged(applicationContext)
    }

    private fun requestReminderPermission(result: MethodChannel.Result?) {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result?.success(true)
            return
        }
        if (permissionRequestInFlight) {
            result?.success(false)
            return
        }
        getSharedPreferences("timetable_next_day", MODE_PRIVATE).edit()
            .putBoolean("permissionAsked", true).apply()
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
            permissionRequestInFlight = false
            if (granted) NextDayReminder.reschedule(this)
        }
    }

    /** 清除旧版动态 shortcut，并禁用可能被用户 pinned 的旧 id，避免长按图标出现无效「添加小组件」。
     *  不碰 AppWidgetProvider：系统桌面「小组件」入口是系统行为，应保留。 */
    private fun clearLegacyShortcuts() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        try {
            val sm = getSystemService(ShortcutManager::class.java) ?: return
            sm.removeAllDynamicShortcuts()
            try {
                sm.disableShortcuts(listOf("add_timetable_widget"))
            } catch (_: IllegalArgumentException) {
                // 本机从未发布过该 id（干净安装）时忽略。
            } catch (_: IllegalStateException) {
                // 桌面/系统暂时不可用时忽略。
            }
        } catch (_: Exception) {
            // shortcut 清理失败不影响启动。
        }
    }

}
