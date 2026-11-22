package dev.duohuo.nuist_sta_app

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.PackageManager.ComponentEnabledSetting
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** 应用图标桥接：切换桌面 alias，并从系统相册生成额外的自定义快捷方式。 */
class AppIconPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener, Application.ActivityLifecycleCallbacks {
    private lateinit var app: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var binding: ActivityPluginBinding? = null
    private var pickResult: MethodChannel.Result? = null
    private var customResult: MethodChannel.Result? = null
    private var pickInFlight = false
    private var customInFlight = false
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        attached = true
        try {
            AppIconStore.recoverCustomIconFiles(app)
            AppIconStore.reconcileBuiltinState(app)
        } catch (error: Exception) {
            AppIconStore.recordDegradation(error, "app_icon.startup", "icon_recovery_failed")
        }
        (app as Application).registerActivityLifecycleCallbacks(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        try {
            (app as Application).unregisterActivityLifecycleCallbacks(this)
        } catch (_: Exception) {
        }
        pickResult?.error("pick_failed", "图片选择已取消", null)
        pickResult = null
        pickInFlight = false
        customResult?.error("shortcut_failed", "图标处理已取消", null)
        customResult = null
        customInFlight = false
        worker.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> runInBackground(result, "icon_failed", "无法读取应用图标状态", "app_icon.get_state") {
                AppIconStore.state(app)
            }
            "setBuiltin" -> {
                val id = call.argument<String>("id")
                if (id == null || !AppIconStore.isBuiltin(id)) {
                    result.error("icon_failed", "未知的内置图标", null)
                    return
                }
                runInBackground(result, "icon_failed", "应用图标切换失败，已尝试恢复原图标", "app_icon.set_builtin") {
                    AppIconStore.setBuiltin(app, id)
                    AppIconStore.state(app)
                }
            }
            "pickImage" -> pickImage(result)
            "setCustomIcon" -> setCustomIcon(call, result)
            "pinCustomIcon" -> pinCustomIcon(result)
            else -> result.notImplemented()
        }
    }

    private fun pickImage(result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null) {
            result.error("pick_failed", "当前页面无法打开相册", null)
            return
        }
        if (pickInFlight) {
            result.error("pick_failed", "正在读取上一张图片", null)
            return
        }
        val intent = try {
            imagePickerIntent(activity)
        } catch (error: Exception) {
            result.error("pick_failed", "系统相册不可用", appIconFailureDetails(error, "app_icon.pick_image") + ("diagnostics" to AppIconStore.takeDiagnostics()))
            return
        }
        if (intent == null) {
            result.error("pick_failed", "系统相册不可用", null)
            return
        }
        pickInFlight = true
        pickResult = result
        try {
            activity.startActivityForResult(intent, REQUEST_PICK_IMAGE)
        } catch (error: Exception) {
            pickInFlight = false
            pickResult = null
            result.error("pick_failed", "系统相册不可用", appIconFailureDetails(error, "app_icon.pick_image") + ("diagnostics" to AppIconStore.takeDiagnostics()))
        }
    }

    private fun imagePickerIntent(activity: Activity): Intent? {
        val picker = if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).setType("image/*")
        } else null
        if (picker != null && picker.resolveActivity(activity.packageManager) != null) return picker
        val document = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return if (document.resolveActivity(activity.packageManager) != null) document else null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_IMAGE) return false
        val result = pickResult ?: return true
        if (resultCode != Activity.RESULT_OK) {
            finishPick(result, bytes = null, error = null)
            return true
        }
        val uri = data?.data ?: data?.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
        if (uri == null) {
            finishPick(result, bytes = null, error = AppIconFailure("pick_failed", "没有选择图片"))
            return true
        }
        worker.execute {
            try {
                val bytes = AppIconStore.readPickedImage(app, uri)
                main.post { finishPick(result, bytes, null) }
            } catch (failure: AppIconFailure) {
                main.post { finishPick(result, null, failure) }
            } catch (error: Exception) {
                main.post { finishPick(result, null, AppIconFailure("pick_failed", "无法读取这张图片", error)) }
            }
        }
        return true
    }

    private fun finishPick(result: MethodChannel.Result, bytes: ByteArray?, error: AppIconFailure?) {
        if (pickResult !== result) return
        pickResult = null
        pickInFlight = false
        if (error == null) {
            result.success(bytes?.let { mapOf("bytes" to it, "diagnostics" to AppIconStore.takeDiagnostics()) })
        } else {
            result.error(normalizeCode(error.code), error.message,
                appIconFailureDetails(error, "app_icon.pick_image") + ("diagnostics" to AppIconStore.takeDiagnostics()))
        }
    }

    private fun setCustomIcon(call: MethodCall, result: MethodChannel.Result) {
        if (customInFlight) {
            result.error("shortcut_failed", "正在保存上一张自定义图标", null)
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null || bytes.isEmpty()) {
            result.error("invalid_image", "自定义图标内容为空", null)
            return
        }
        if (bytes.size > MAX_CUSTOM_ICON_BYTES) {
            result.error("too_large", "自定义图标文件过大", null)
            return
        }
        if (!AppIconStore.customShortcutAvailable(app)) {
            result.error("shortcut_unsupported", "当前桌面不支持自定义图标快捷方式", null)
            return
        }
        customInFlight = true
        customResult = result
        worker.execute {
            try {
                val state = AppIconStore.installCustomIcon(app, bytes)
                main.post { finishCustom(result, state, null) }
            } catch (failure: AppIconFailure) {
                main.post { finishCustom(result, null, failure) }
            } catch (error: Exception) {
                main.post { finishCustom(result, null, AppIconFailure("shortcut_failed", "自定义图标保存失败", error)) }
            }
        }
    }

    private fun finishCustom(result: MethodChannel.Result, state: Map<String, Any?>?, error: AppIconFailure?) {
        if (customResult !== result) return
        customResult = null
        customInFlight = false
        if (!attached) return
        if (error == null && state != null) result.success(state)
        else {
            val failure = error ?: AppIconFailure("shortcut_failed", "自定义图标保存失败")
            result.error(normalizeCode(failure.code), failure.message, appIconFailureDetails(failure, "app_icon.custom_icon") + ("diagnostics" to AppIconStore.takeDiagnostics()))
        }
    }

    private fun pinCustomIcon(result: MethodChannel.Result) {
        if (customInFlight) {
            result.error("shortcut_failed", "正在处理上一张自定义图标", null)
            return
        }
        customInFlight = true
        customResult = result
        worker.execute {
            try {
                val state = AppIconStore.pinSavedCustomIcon(app)
                main.post { finishCustom(result, state, null) }
            } catch (failure: AppIconFailure) {
                main.post { finishCustom(result, null, failure) }
            } catch (error: Exception) {
                main.post { finishCustom(result, null, AppIconFailure("shortcut_failed", "无法添加到桌面", error)) }
            }
        }
    }

    private fun runInBackground(
        result: MethodChannel.Result,
        code: String,
        message: String,
        stage: String,
        block: () -> Map<String, Any?>,
    ) {
        worker.execute {
            try {
                val value = block()
                main.post {
                    if (attached) result.success(value)
                }
            } catch (error: Exception) {
                main.post {
                    if (attached) result.error(code, message, appIconFailureDetails(error, stage) + ("diagnostics" to AppIconStore.takeDiagnostics()))
                }
            }
        }
    }

    private fun normalizeCode(code: String?): String = when (code) {
        "too_large", "invalid_image", "pick_failed", "shortcut_unsupported", "shortcut_failed", "icon_failed" -> code
        "image_too_large" -> "too_large"
        "image_read", "no_image" -> "pick_failed"
        "unsupported" -> "shortcut_unsupported"
        "update_failed", "pin_rejected", "storage", "encode_failed" -> "shortcut_failed"
        else -> "icon_failed"
    }

    private fun attach(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }

    private fun detach() {
        binding?.removeActivityResultListener(this)
        binding = null
        pickResult?.error("pick_failed", "图片选择已取消", null)
        pickResult = null
        pickInFlight = false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() = detach()

    override fun onActivityResumed(activity: Activity) {
        if (binding?.activity === activity) {
            try {
                AppIconStore.refreshPinConfirmation(app)
            } catch (error: Exception) {
                AppIconStore.recordDegradation(error, "app_icon.pin_confirmation", "pin_confirmation_refresh_failed")
            }
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit

    companion object {
        private const val CHANNEL = "nuist/app_icon"
        private const val REQUEST_PICK_IMAGE = 0x4E70
        private const val MAX_CUSTOM_ICON_BYTES = 8 * 1024 * 1024
    }
}

/** 自定义快捷方式确认回调；只接受应用自己 PendingIntent 发出的广播。 */
class AppIconShortcutReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AppIconStore.ACTION_SHORTCUT_PINNED) return
        val shortcutId = intent.getStringExtra(AppIconStore.EXTRA_SHORTCUT_ID) ?: return
        if (!AppIconStore.isCustomShortcut(shortcutId)) return
        try {
            AppIconStore.markPinConfirmed(context, shortcutId)
            NativeBackgroundDiagnostics.enqueue(context, AppIconStore.takeDiagnostics(), scope = "app_icon.native_background")
        } catch (error: Exception) {
            // 广播无 Flutter 回执，沿用本机原生诊断队列；下次 getState 仍以实际 pinned 列表为准。
            NativeBackgroundDiagnostics.enqueue(context, listOf(
                appIconFailureDetails(error, "app_icon.pin_confirmation") + ("reason_code" to "pin_confirmation_save_failed")) + AppIconStore.takeDiagnostics(),
                scope = "app_icon.native_background")
        }
    }
}

/** 图标 alias、图片与快捷方式的本地状态；所有失败都保留可用的旧图标。 */
internal object AppIconStore {
    const val ACTION_SHORTCUT_PINNED = "dev.duohuo.nuist_sta_app.APP_ICON_SHORTCUT_PINNED"
    const val EXTRA_SHORTCUT_ID = "shortcut_id"
    const val SHORTCUT_ID = "nuist_custom_app_icon"
    private const val SHORTCUT_PREFIX = "${SHORTCUT_ID}_"
    private const val PREFS = "nuist_app_icon"
    private const val KEY_BUILTIN = "builtin_id"
    private const val KEY_PENDING_BUILTIN = "pending_builtin_id"
    private const val KEY_SHORTCUT_PENDING = "shortcut_pending"
    private const val KEY_PENDING_SHORTCUT_ID = "pending_shortcut_id"
    private const val KEY_SHORTCUT_REQUESTED_AT = "shortcut_requested_at"
    private const val PIN_PENDING_TIMEOUT_MS = 2 * 60 * 1000L
    private const val ICON_DIRECTORY = "app_icon"
    private const val ICON_FILE = "custom.png"
    private const val MAX_SOURCE_BYTES = 20 * 1024 * 1024
    private const val MAX_PICKED_EDGE = 2048
    private const val CUSTOM_ICON_EDGE = 512
    private const val MAX_DIAGNOSTICS = 64
    private val diagnostics = mutableListOf<Map<String, Any?>>()
    private var diagnosticsDropped = 0

    /** 同步操作的降级依据随下次平台回执返回，由 Dart 统一脱敏及留存。 */
    @Synchronized
    fun recordDegradation(error: Throwable, stage: String, reason: String) {
        if (diagnostics.size >= MAX_DIAGNOSTICS) {
            diagnostics.removeAt(0)
            diagnosticsDropped++
        }
        diagnostics.add(appIconFailureDetails(error, stage) + mapOf("reason_code" to reason, "degraded" to true))
    }

    @Synchronized
    fun takeDiagnostics(): List<Map<String, Any?>> {
        val result = diagnostics.toMutableList()
        if (diagnosticsDropped > 0 && result.isNotEmpty()) {
            result[result.lastIndex] = result.last() + ("diagnostics_dropped_before" to diagnosticsDropped)
        }
        diagnostics.clear()
        diagnosticsDropped = 0
        return result
    }

    private val aliases = linkedMapOf(
        "default" to "DefaultIcon",
        "mascot" to "MascotIcon",
        "mascot_color" to "MascotColorIcon",
    )

    fun isBuiltin(id: String): Boolean = aliases.containsKey(id)

    fun isCustomShortcut(id: String): Boolean = id == SHORTCUT_ID || id.startsWith(SHORTCUT_PREFIX)

    @Synchronized
    fun state(context: Context): Map<String, Any?> {
        val builtin = reconcileBuiltinState(context)
        val pinned = isPinned(context)
        refreshPinConfirmation(context)
        val prefs = prefs(context)
        var pending = prefs.getBoolean(KEY_SHORTCUT_PENDING, false)
        // 首次请求若没有回调，短时间后清理悬空状态；这只是请求状态，不代表桌面已确认。
        if (pending && prefs.getLong(KEY_SHORTCUT_REQUESTED_AT, 0L) + PIN_PENDING_TIMEOUT_MS <
            System.currentTimeMillis()
        ) {
            // 系统没有取消 pin 请求的接口；超时仅结束界面提示，保留可迁移的动态 ID。
            clearShortcutPending(context, keepId = true)
            pending = false
        }
        return linkedMapOf(
            "supported" to true,
            "builtinId" to builtin,
            "canPin" to canPin(context),
            "customPinned" to pinned,
            "confirmed" to pinned,
            "pending" to pending,
            "customIcon" to readCustomIcon(context),
            "diagnostics" to takeDiagnostics(),
        )
    }

    @Synchronized
    fun reconcileBuiltinState(context: Context): String {
        val prefs = prefs(context)
        val pending = prefs.getString(KEY_PENDING_BUILTIN, null)?.takeIf(::isBuiltin)
        val stored = prefs.getString(KEY_BUILTIN, null)?.takeIf(::isBuiltin)
        val enabled = aliases.keys.filter { isAliasEnabled(context, it) }
        val desired = when {
            pending != null -> pending
            enabled.size == 1 -> enabled.first()
            stored != null && enabled.contains(stored) -> stored
            enabled.isNotEmpty() -> enabled.first()
            else -> stored ?: "default"
        }
        if (pending != null || enabled.size != 1 || enabled.firstOrNull() != desired) {
            try {
                applyBuiltin(context, desired, repairPinnedBeforeDisable = true)
                if (!prefs.edit().putString(KEY_BUILTIN, desired).remove(KEY_PENDING_BUILTIN).commit()) {
                    throw AppIconFailure("storage", "无法保存恢复后的内置图标状态")
                }
            } catch (error: Exception) {
                recordDegradation(error, "app_icon.builtin_reconcile", "builtin_reconcile_failed")
                if (enabled.isEmpty()) {
                    try {
                        applyBuiltin(context, "default", repairPinnedBeforeDisable = true)
                        if (!prefs.edit().putString(KEY_BUILTIN, "default").remove(KEY_PENDING_BUILTIN).commit()) {
                            throw AppIconFailure("storage", "无法保存默认图标恢复状态")
                        }
                    } catch (fallbackError: Exception) {
                        recordDegradation(fallbackError, "app_icon.builtin_reconcile", "default_icon_recovery_failed")
                    }
                }
            }
        }
        val actual = currentBuiltin(context) ?: desired
        // 启动修复悬空 alias 后，把所有自定义快捷方式重新关联到当前桌面入口。
        repairPinnedShortcutActivity(context, actual)
        return actual
    }

    @Synchronized
    fun setBuiltin(context: Context, id: String) {
        require(isBuiltin(id))
        val prefs = prefs(context)
        val previous = currentBuiltin(context) ?: prefs.getString(KEY_BUILTIN, null)?.takeIf(::isBuiltin) ?: "default"
        if (!prefs.edit().putString(KEY_PENDING_BUILTIN, id).commit()) {
            throw AppIconFailure("icon_failed", "无法保存图标切换状态")
        }
        try {
            applyBuiltin(context, id, repairPinnedBeforeDisable = true)
            if (currentBuiltin(context) != id) throw IllegalStateException("alias 状态未生效")
            if (!prefs.edit().putString(KEY_BUILTIN, id).remove(KEY_PENDING_BUILTIN).commit()) {
                throw AppIconFailure("storage", "无法保存切换后的内置图标状态")
            }
        } catch (error: Exception) {
            val restored = try {
                applyBuiltin(context, previous, repairPinnedBeforeDisable = true)
                currentBuiltin(context) == previous
            } catch (rollbackError: Exception) {
                error.addSuppressed(rollbackError)
                false
            }
            if (restored && !prefs.edit().putString(KEY_BUILTIN, previous).remove(KEY_PENDING_BUILTIN).commit()) {
                error.addSuppressed(AppIconFailure("storage", "无法保存内置图标回滚状态"))
            }
            throw error
        }
    }

    private fun currentBuiltin(context: Context): String? =
        aliases.keys.filter { isAliasEnabled(context, it) }.singleOrNull()

    private fun aliasComponent(context: Context, id: String): ComponentName {
        val className = aliases[id] ?: throw IllegalArgumentException("未知图标")
        // Class.getPackageName 需要 API 26；这里从类名截取 namespace，并让 debug suffix 只作用于包名。
        val namespace = MainActivity::class.java.name.substringBeforeLast('.')
        return ComponentName(context.packageName, "$namespace.$className")
    }

    private fun isAliasEnabled(context: Context, id: String): Boolean {
        val state = context.packageManager.getComponentEnabledSetting(aliasComponent(context, id))
        return when (state) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> id == "default"
            else -> false
        }
    }

    @Suppress("NewApi")
    private fun applyBuiltin(
        context: Context,
        id: String,
        repairPinnedBeforeDisable: Boolean = false,
    ) {
        val pm = context.packageManager
        val target = aliasComponent(context, id)
        val others = aliases.keys.filter { it != id }.map { aliasComponent(context, it) }

        // 先只启用目标 alias，确认其可见后再迁移自定义快捷方式的 activity 关联。
        pm.setComponentEnabledSetting(
            target,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        if (!isAliasEnabled(context, id)) {
            throw IllegalStateException("目标桌面图标入口未启用")
        }
        if (repairPinnedBeforeDisable) {
            repairPinnedShortcutActivity(context, id, required = true)
        }

        if (Build.VERSION.SDK_INT >= 33) {
            pm.setComponentEnabledSettings(
                others.map { component ->
                    ComponentEnabledSetting(
                        component,
                        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                        PackageManager.DONT_KILL_APP,
                    )
                },
            )
        } else {
            others.forEach { component ->
                pm.setComponentEnabledSetting(
                    component,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }

    private fun shortcutManager(context: Context): ShortcutManager? =
        context.getSystemService(ShortcutManager::class.java)

    private fun isPinned(context: Context): Boolean = try {
        shortcutManager(context)?.pinnedShortcuts?.any { isCustomShortcut(it.id) } == true
    } catch (error: Exception) {
        recordDegradation(error, "app_icon.pinned_query", "pinned_query_failed")
        false
    }

    /**
     * 更新已固定及待确认的动态快捷方式关联，保留其图标与启动 Intent。
     * pin 接受时 Android 会按 ID 查询当前记录，所以不能只迁移 pinned，也不能在界面超时后删动态记录。
     */
    @Synchronized
    private fun repairPinnedShortcutActivity(context: Context, builtinId: String, required: Boolean = false) {
        val manager = shortcutManager(context) ?: return
        if (!isAliasEnabled(context, builtinId)) {
            if (required) throw AppIconFailure("shortcut_failed", "新的桌面图标入口尚未启用")
            return
        }
        try {
            val target = aliasComponent(context, builtinId)
            val known = (manager.pinnedShortcuts + manager.dynamicShortcuts).distinctBy { it.id }
            // 覆盖安装前已发出的请求可能尚无动态记录；用保存的 PNG 补登记同一 ID，兼容晚确认。
            val pendingId = prefs(context).getString(KEY_PENDING_SHORTCUT_ID, null)?.takeIf(::isCustomShortcut)
            if (pendingId != null && known.none { it.id == pendingId }) {
                val bytes = readCustomIcon(context)
                    ?: throw AppIconFailure("shortcut_failed", "待确认快捷方式的图片不可用")
                val bitmap = decodeSampled(bytes, CUSTOM_ICON_EDGE)
                try {
                    if (!manager.addDynamicShortcuts(listOf(buildShortcut(context, bitmap, pendingId, builtinId)))) {
                        throw AppIconFailure("shortcut_failed", "无法登记待确认快捷方式")
                    }
                } finally {
                    bitmap.recycle()
                }
            }
            val updates = known
                .filter { isCustomShortcut(it.id) && it.activity != target }
                .map { ShortcutInfo.Builder(context, it.id).setActivity(target).build() }
            if (updates.isNotEmpty() && !manager.updateShortcuts(updates)) {
                throw AppIconFailure("shortcut_failed", "无法更新快捷方式的桌面图标入口")
            }
        } catch (error: Exception) {
            if (required) {
                if (error is AppIconFailure) throw error
                throw AppIconFailure("shortcut_failed", "无法更新快捷方式的桌面图标入口", error)
            }
            recordDegradation(error, "app_icon.shortcut_activity", "shortcut_activity_repair_failed")
        }
    }

    private fun requestPinSupported(context: Context): Boolean = try {
        shortcutManager(context)?.isRequestPinShortcutSupported == true
    } catch (error: Exception) {
        recordDegradation(error, "app_icon.pin_capability", "pin_capability_query_failed")
        false
    }

    private fun canPin(context: Context): Boolean = isPinned(context) || requestPinSupported(context)

    fun customShortcutAvailable(context: Context): Boolean = canPin(context)

    @Synchronized
    fun refreshPinConfirmation(context: Context) {
        val manager = shortcutManager(context) ?: return
        val pinned = manager.pinnedShortcuts.filter { isCustomShortcut(it.id) }
        // 确认后只移除动态发布，已 pinned 的记录仍由系统保留；晚确认不依赖界面 pending 标志。
        val dynamicPinnedIds = pinned.filter { it.isDynamic }.map { it.id }
        if (dynamicPinnedIds.isNotEmpty()) {
            try {
                manager.removeDynamicShortcuts(dynamicPinnedIds)
            } catch (error: Exception) {
                recordDegradation(error, "app_icon.pin_confirmation", "confirmed_dynamic_cleanup_failed")
            }
        }
        val pendingId = prefs(context).getString(KEY_PENDING_SHORTCUT_ID, null)
        if (pinned.any { it.id == pendingId }) clearShortcutPending(context)
    }

    @Synchronized
    fun markPinConfirmed(context: Context, shortcutId: String) {
        if (!isCustomShortcut(shortcutId)) return
        // 旧请求回调也清理其已固定动态记录，但不能清除后来请求的等待状态。
        refreshPinConfirmation(context)
    }

    private fun clearShortcutPending(context: Context, keepId: Boolean = false) {
        val editor = prefs(context).edit().putBoolean(KEY_SHORTCUT_PENDING, false)
            .remove(KEY_SHORTCUT_REQUESTED_AT)
        if (!keepId) editor.remove(KEY_PENDING_SHORTCUT_ID)
        if (!editor.commit()) throw AppIconFailure("storage", "无法保存快捷方式确认状态")
    }

    fun readPickedImage(context: Context, uri: Uri): ByteArray {
        val source = readLimited(context, uri)
        val bitmap = decodeSampled(source, MAX_PICKED_EDGE)
        return try {
            val oriented = applyOrientation(source, bitmap)
            try {
                encodePng(oriented)
            } finally {
                if (oriented !== bitmap) oriented.recycle()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun readLimited(context: Context, uri: Uri): ByteArray {
        val input = context.contentResolver.openInputStream(uri)
            ?: throw AppIconFailure("image_read", "无法读取这张图片")
        input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_SOURCE_BYTES) {
                    throw AppIconFailure("image_too_large", "图片不能超过 20 MiB")
                }
                output.write(buffer, 0, count)
            }
            if (total == 0) throw AppIconFailure("invalid_image", "图片内容为空")
            return output.toByteArray()
        }
    }

    private fun decodeSampled(bytes: ByteArray, maxEdge: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw AppIconFailure("invalid_image", "无法识别图片")
        }
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > maxEdge) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw AppIconFailure("invalid_image", "无法解析图片")
    }

    private fun applyOrientation(source: ByteArray, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(source)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (error: Exception) {
            recordDegradation(error, "app_icon.image_orientation", "image_orientation_unavailable")
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(270f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(270f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    @Synchronized
    fun installCustomIcon(context: Context, bytes: ByteArray): Map<String, Any?> {
        // 旧快捷方式若不关联当前 alias，切换图标后可能随入口被禁用；先修复关联再写入新图。
        repairPinnedShortcutActivity(context, currentBuiltin(context) ?: "default", required = true)
        val source = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw AppIconFailure("invalid_image", "无法解析自定义图标")
        if (source.width <= 0 || source.height <= 0) {
            source.recycle()
            throw AppIconFailure("invalid_image", "自定义图标尺寸无效")
        }
        val iconBitmap = try {
            val side = min(source.width, source.height)
            if (side <= 0) throw AppIconFailure("invalid_image", "自定义图标尺寸无效")
            val left = (source.width - side) / 2
            val top = (source.height - side) / 2
            // 始终绘制到独立位图，避免 createBitmap 返回源图本身后随源图一起回收。
            Bitmap.createBitmap(CUSTOM_ICON_EDGE, CUSTOM_ICON_EDGE, Bitmap.Config.ARGB_8888).also { output ->
                val canvas = android.graphics.Canvas(output)
                val paint = android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG)
                canvas.drawBitmap(
                    source,
                    android.graphics.Rect(left, top, left + side, top + side),
                    android.graphics.Rect(0, 0, CUSTOM_ICON_EDGE, CUSTOM_ICON_EDGE),
                    paint,
                )
            }
        } catch (failure: AppIconFailure) {
            throw failure
        } finally {
            source.recycle()
        }
        try {
            val png = encodePng(iconBitmap)
            val manager = shortcutManager(context)
                ?: throw AppIconFailure("shortcut_unsupported", "当前系统不支持自定义快捷方式")
            val pinned = manager.pinnedShortcuts.filter { isCustomShortcut(it.id) }
            if (pinned.isEmpty() && !requestPinSupported(context)) {
                throw AppIconFailure("shortcut_unsupported", "当前桌面不支持添加自定义图标")
            }
            // 先构建 ShortcutInfo，避免无效 PNG 已落盘后才因快捷方式校验失败。
            val shortcuts = if (pinned.isNotEmpty()) {
                (pinned + manager.dynamicShortcuts)
                    .filter { isCustomShortcut(it.id) }
                    .distinctBy { it.id }
                    .map { buildShortcut(context, iconBitmap, it.id) }
            } else emptyList()
            val previousIcon = readCustomIcon(context)
            val transaction = IconFileTransaction(context)
            transaction.write(png)
            transaction.commit()
            try {
                if (shortcuts.isNotEmpty() && !manager.updateShortcuts(shortcuts)) {
                    throw AppIconFailure("shortcut_failed", "桌面自定义图标更新失败")
                }
                if (pinned.isEmpty()) requestNewShortcut(context, manager, iconBitmap, previousIcon)
                transaction.finish()
            } catch (error: Exception) {
                // 新图已经落盘但快捷方式未成功时，恢复旧的 PNG，避免界面与新快捷方式不一致。
                try {
                    transaction.rollback()
                } catch (rollbackError: Exception) {
                    error.addSuppressed(rollbackError)
                }
                throw error
            }
            return state(context)
        } finally {
            iconBitmap.recycle()
        }
    }

    /** 使用已保存图片请求一个独立桌面入口；取消后可再次调用，不依赖已有入口是否存在。 */
    @Synchronized
    fun pinSavedCustomIcon(context: Context): Map<String, Any?> {
        val manager = shortcutManager(context)
            ?: throw AppIconFailure("shortcut_unsupported", "当前系统不支持自定义快捷方式")
        if (!requestPinSupported(context)) {
            throw AppIconFailure("shortcut_unsupported", "当前桌面不支持添加自定义图标")
        }
        reconcileBuiltinState(context)
        val bytes = readCustomIcon(context)
            ?: throw AppIconFailure("invalid_image", "请先从相册选择图片")
        val bitmap = decodeSampled(bytes, CUSTOM_ICON_EDGE)
        try {
            requestNewShortcut(context, manager, bitmap)
            return state(context)
        } finally {
            bitmap.recycle()
        }
    }

    @Synchronized
    private fun requestNewShortcut(
        context: Context,
        manager: ShortcutManager,
        bitmap: Bitmap,
        previousIconBytes: ByteArray? = readCustomIcon(context),
    ) {
        refreshPinConfirmation(context)
        val prefs = prefs(context)
        val pinnedIds = manager.pinnedShortcuts.filter { isCustomShortcut(it.id) }.map { it.id }.toSet()
        val existingDynamic = manager.dynamicShortcuts.filter { isCustomShortcut(it.id) && it.id !in pinnedIds }
        val previousPending = prefs.getBoolean(KEY_SHORTCUT_PENDING, false)
        val previousId = prefs.getString(KEY_PENDING_SHORTCUT_ID, null)
        val previousTime = prefs.getLong(KEY_SHORTCUT_REQUESTED_AT, 0L)
        // 系统没有撤销请求接口。取消或超时后复用同一未确认 ID，避免堆积动态入口或失去旧请求。
        // 已确认的入口不复用，因此再次添加仍会生成独立桌面图标。
        val shortcutId = previousId?.takeIf { isCustomShortcut(it) && it !in pinnedIds }
            ?: existingDynamic.firstOrNull()?.id
            ?: (SHORTCUT_PREFIX + UUID.randomUUID().toString())
        val wasDynamic = existingDynamic.any { it.id == shortcutId }
        val shortcut = buildShortcut(context, bitmap, shortcutId)
        try {
            if (!manager.addDynamicShortcuts(listOf(shortcut))) {
                throw AppIconFailure("shortcut_failed", "无法登记待确认快捷方式")
            }
            if (!prefs.edit()
                    .putBoolean(KEY_SHORTCUT_PENDING, true)
                    .putString(KEY_PENDING_SHORTCUT_ID, shortcutId)
                    .putLong(KEY_SHORTCUT_REQUESTED_AT, System.currentTimeMillis())
                    .commit()
            ) {
                throw AppIconFailure("shortcut_failed", "无法保存快捷方式请求状态")
            }
            if (!manager.requestPinShortcut(shortcut, pinCallback(context, shortcutId).intentSender)) {
                throw AppIconFailure("shortcut_failed", "桌面未接受快捷方式请求")
            }
        } catch (error: Exception) {
            try {
                val editor = prefs.edit().putBoolean(KEY_SHORTCUT_PENDING, previousPending)
                    .putLong(KEY_SHORTCUT_REQUESTED_AT, previousTime)
                if (previousId == null) editor.remove(KEY_PENDING_SHORTCUT_ID)
                else editor.putString(KEY_PENDING_SHORTCUT_ID, previousId)
                if (!editor.commit()) throw AppIconFailure("storage", "无法恢复快捷方式请求状态")
                if (wasDynamic && previousIconBytes != null) {
                    val previousBitmap = decodeSampled(previousIconBytes, CUSTOM_ICON_EDGE)
                    try {
                        if (!manager.addDynamicShortcuts(listOf(buildShortcut(context, previousBitmap, shortcutId)))) {
                            throw AppIconFailure("shortcut_failed", "无法恢复上一张待确认快捷方式图标")
                        }
                    } finally {
                        previousBitmap.recycle()
                    }
                } else if (!wasDynamic) {
                    manager.removeDynamicShortcuts(listOf(shortcutId))
                }
            } catch (rollbackError: Exception) {
                error.addSuppressed(rollbackError)
            }
            throw error
        }
    }

    private fun buildShortcut(
        context: Context,
        bitmap: Bitmap,
        shortcutId: String,
        builtinId: String = currentBuiltin(context) ?: "default",
    ): ShortcutInfo {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        }
        return ShortcutInfo.Builder(context, shortcutId)
            .setShortLabel("NUIST++")
            .setLongLabel("NUIST++ 自定义图标")
            .setIcon(Icon.createWithBitmap(bitmap))
            .setIntent(intent)
            // 官方要求 activity 自身提供 MAIN + LAUNCHER；绑定当前 enabled 的 alias，避免切换后失效。
            .setActivity(aliasComponent(context, builtinId))
            .build()
    }

    private fun pinCallback(context: Context, shortcutId: String): android.app.PendingIntent {
        val intent = Intent(context, AppIconShortcutReceiver::class.java).apply {
            action = ACTION_SHORTCUT_PINNED
            data = Uri.Builder().scheme("nuist-app-icon").authority(context.packageName)
                .appendPath(shortcutId).build()
            putExtra(EXTRA_SHORTCUT_ID, shortcutId)
        }
        return android.app.PendingIntent.getBroadcast(
            context,
            0x4E71,
            intent,
            android.app.PendingIntent.FLAG_ONE_SHOT or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun readCustomIcon(context: Context): ByteArray? = try {
        val file = iconFile(context)
        if (file.isFile) file.readBytes() else null
    } catch (error: Exception) {
        recordDegradation(error, "app_icon.image_read", "saved_image_read_failed")
        null
    }

    fun recoverCustomIconFiles(context: Context) {
        val directory = iconDirectory(context)
        val target = File(directory, ICON_FILE)
        val temporary = File(directory, "${ICON_FILE}.tmp")
        val backup = File(directory, "${ICON_FILE}.bak")
        try {
            if (!target.exists() && backup.exists()) backup.renameTo(target)
            if (target.exists()) {
                temporary.delete()
                backup.delete()
            } else {
                temporary.delete()
            }
        } catch (error: Exception) {
            recordDegradation(error, "app_icon.image_recovery", "image_file_recovery_failed")
        }
    }

    private fun iconDirectory(context: Context): File =
        File(context.filesDir, ICON_DIRECTORY).apply { mkdirs() }

    private fun iconFile(context: Context): File = File(iconDirectory(context), ICON_FILE)

    private fun encodePng(bitmap: Bitmap): ByteArray = ByteArrayOutputStream().use { output ->
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
            throw AppIconFailure("encode_failed", "无法生成 PNG 图标")
        }
        output.toByteArray()
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private class IconFileTransaction(context: Context) {
        private val target = File(iconDirectory(context), ICON_FILE)
        private val temporary = File(iconDirectory(context), "${ICON_FILE}.tmp")
        private val backup = File(iconDirectory(context), "${ICON_FILE}.bak")
        private var hadPrevious = false

        fun write(bytes: ByteArray) {
            temporary.delete()
            FileOutputStream(temporary).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
        }

        fun commit() {
            backup.delete()
            hadPrevious = target.exists()
            if (hadPrevious && !target.renameTo(backup)) {
                throw AppIconFailure("shortcut_failed", "无法暂存上一张自定义图标")
            }
            if (!temporary.renameTo(target)) {
                if (backup.exists()) backup.renameTo(target)
                throw AppIconFailure("shortcut_failed", "无法保存自定义图标")
            }
        }

        fun finish() {
            if (backup.exists() && !backup.delete()) {
                recordDegradation(AppIconFailure("storage", "无法清理上一张图标备份"), "app_icon.image_save", "image_backup_cleanup_failed")
            }
        }

        fun rollback() {
            if (target.exists() && !target.delete()) throw AppIconFailure("storage", "无法移除失败的新图标")
            if (hadPrevious && backup.exists() && !backup.renameTo(target)) {
                throw AppIconFailure("storage", "无法恢复上一张自定义图标")
            }
            if (temporary.exists() && !temporary.delete()) throw AppIconFailure("storage", "无法清理失败的图标临时文件")
        }
    }
}

/** 原生失败详情不做截断或输出，交给既有 Dart 日志出口统一脱敏。 */
private fun appIconFailureDetails(error: Throwable, stage: String): Map<String, Any?> =
    notifyFailureDetails(error, stage) + ("reason_code" to ((error as? AppIconFailure)?.code ?: "native_operation_failed"))

private class AppIconFailure(val code: String, override val message: String, cause: Throwable? = null) : Exception(message, cause)
