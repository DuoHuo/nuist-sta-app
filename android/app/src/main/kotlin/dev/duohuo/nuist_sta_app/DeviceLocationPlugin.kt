package dev.duohuo.nuist_sta_app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * 校园地图的定位桥接，只使用系统 [LocationManager]，不依赖 Google Play 服务。
 *
 * 通道 `nuist/device_location`：`isEnabled`、`permission`、`requestPermission`、
 * `lastKnown`、`getCurrent`；事件通道 `nuist/device_location/updates` 提供持续更新。
 */
class DeviceLocationPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var watchListeners: List<LocationListener> = emptyList()

    private val manager: LocationManager?
        get() = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "nuist/device_location")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "nuist/device_location/updates")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        stopWatching()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isEnabled" -> result.success(enabledProviders().isNotEmpty())
            "permission" -> result.success(permissionState())
            "requestPermission" -> requestPermission(result)
            "lastKnown" -> result.success(lastKnown()?.let(::encode))
            "getCurrent" -> getCurrent(
                high = call.argument<Boolean>("high") ?: true,
                timeoutMs = (call.argument<Number>("timeoutMs") ?: 8000).toLong(),
                result = result,
            )
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** `granted`、`denied`（可再次询问）、`deniedForever`（系统不再弹窗）。 */
    private fun permissionState(): String {
        if (hasPermission()) return "granted"
        val activity = activityBinding?.activity ?: return "denied"
        val asked = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ASKED, false)
        val canAsk = ActivityCompat.shouldShowRequestPermissionRationale(
            activity, Manifest.permission.ACCESS_FINE_LOCATION,
        )
        return if (asked && !canAsk) "deniedForever" else "denied"
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (hasPermission()) {
            result.success("granted")
            return
        }
        if (activity == null || pendingPermission != null) {
            result.error("no_activity", "无法请求定位权限", null)
            return
        }
        pendingPermission = result
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_ASKED, true).apply()
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        result.success(permissionState())
        return true
    }

    private fun enabledProviders(): List<String> {
        val manager = manager ?: return emptyList()
        return PROVIDERS.filter { provider ->
            try {
                manager.isProviderEnabled(provider)
            } catch (_: Exception) {
                false
            }
        }
    }

    @Suppress("MissingPermission")
    private fun lastKnown(): Location? {
        if (!hasPermission()) return null
        val manager = manager ?: return null
        var best: Location? = null
        for (provider in PROVIDERS + LocationManager.PASSIVE_PROVIDER) {
            val candidate = try {
                manager.getLastKnownLocation(provider)
            } catch (_: Exception) {
                null
            } ?: continue
            if (best == null || isBetter(candidate, best)) best = candidate
        }
        return best
    }

    /** 比较两个位置：明显更新的优先；同样新时精度高的优先。 */
    private fun isBetter(candidate: Location, current: Location): Boolean {
        val delta = candidate.time - current.time
        if (delta > TWO_MINUTES) return true
        if (delta < -TWO_MINUTES) return false
        if (!candidate.hasAccuracy()) return false
        if (!current.hasAccuracy()) return true
        return candidate.accuracy < current.accuracy ||
            (delta > 0 && candidate.accuracy <= current.accuracy + 50f)
    }

    @Suppress("MissingPermission")
    private fun getCurrent(high: Boolean, timeoutMs: Long, result: MethodChannel.Result) {
        val manager = manager
        if (manager == null || !hasPermission()) {
            result.error("permission_denied", "没有定位权限", null)
            return
        }
        val enabled = enabledProviders()
        // 中等精度只用网络（Wi-Fi / 基站）定位；网络定位不可用时退到其他来源。
        val providers = if (high || LocationManager.NETWORK_PROVIDER !in enabled) {
            enabled
        } else {
            listOf(LocationManager.NETWORK_PROVIDER)
        }
        if (providers.isEmpty()) {
            result.success(null)
            return
        }
        var finished = false
        val listeners = mutableListOf<LocationListener>()
        lateinit var timeout: Runnable
        fun finish(location: Location?) {
            if (finished) return
            finished = true
            main.removeCallbacks(timeout)
            listeners.forEach { manager.removeUpdates(it) }
            result.success(location?.let(::encode))
        }
        timeout = Runnable { finish(null) }
        for (provider in providers) {
            val listener = SimpleListener { location -> finish(location) }
            listeners.add(listener)
            try {
                manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
            } catch (_: Exception) {
                // 某个来源不可用不影响其他来源。
            }
        }
        main.postDelayed(timeout, timeoutMs)
    }

    @Suppress("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val manager = manager
        if (manager == null || !hasPermission()) {
            events.error("permission_denied", "没有定位权限", null)
            return
        }
        stopWatching()
        var best: Location? = null
        val listeners = mutableListOf<LocationListener>()
        for (provider in enabledProviders()) {
            val listener = SimpleListener { location ->
                val current = best
                if (current == null || isBetter(location, current)) {
                    best = location
                    events.success(encode(location))
                }
            }
            listeners.add(listener)
            try {
                manager.requestLocationUpdates(
                    provider, MIN_INTERVAL_MS, MIN_DISTANCE_M, listener, Looper.getMainLooper(),
                )
            } catch (_: Exception) {
                // 同上。
            }
        }
        watchListeners = listeners
    }

    override fun onCancel(arguments: Any?) = stopWatching()

    private fun stopWatching() {
        val manager = manager ?: return
        watchListeners.forEach { manager.removeUpdates(it) }
        watchListeners = emptyList()
    }

    private fun encode(location: Location): Map<String, Any> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy" to (if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0),
        "timestamp" to location.time,
    )

    private class SimpleListener(private val onLocation: (Location) -> Unit) : LocationListener {
        override fun onLocationChanged(location: Location) = onLocation(location)

        @Deprecated("API 29 起不再调用")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit

        override fun onProviderEnabled(provider: String) = Unit

        override fun onProviderDisabled(provider: String) = Unit
    }

    private companion object {
        const val REQUEST_CODE = 0x4c0c
        const val PREFS = "device_location"
        const val KEY_ASKED = "permission_asked"
        const val TWO_MINUTES = 2 * 60 * 1000L
        const val MIN_INTERVAL_MS = 1000L
        const val MIN_DISTANCE_M = 3f
        val PROVIDERS = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
    }
}
