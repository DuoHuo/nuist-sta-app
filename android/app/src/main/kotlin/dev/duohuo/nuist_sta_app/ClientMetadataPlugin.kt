package dev.duohuo.nuist_sta_app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** 自有服务元数据桥接；原始 Android ID 不离开 Android 层。 */
class ClientMetadataPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var worker: ExecutorService
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        worker = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, "nuist/client_metadata")
        channel.setMethodCallHandler(this)
        attached = true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getMetadata") {
            result.notImplemented()
            return
        }
        worker.execute {
            val metadata = synchronized(cacheLock) {
                cached ?: readMetadata(context).also { cached = it }
            }
            main.post { if (attached) result.success(metadata) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    companion object {
        private val cacheLock = Any()
        private var cached: Map<String, Any>? = null

        private fun readMetadata(context: Context): Map<String, Any> {
            val result = mutableMapOf<String, Any>("appPackage" to context.packageName)
            try {
                val rawId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
                deriveClientId(rawId)?.let { result["clientId"] = it }
            } catch (_: Exception) {
                // 不可用时省略，不能生成虚假的设备标识，也不记录原始值。
            }
            try {
                result["androidVersion"] = Build.VERSION.RELEASE
                result["androidSdk"] = Build.VERSION.SDK_INT
            } catch (_: Exception) {
                // 各来源单独降级，系统信息不可用不影响包信息。
            }
            try {
                val properties = BoundedSystemProperties()
                RomInfoResolver.resolve(properties::read, Build.BRAND)?.let { rom ->
                    result["romName"] = rom.name
                    rom.version?.let { result["romVersion"] = it }
                }
            } catch (_: Exception) {
                // 厂商属性不是稳定契约，失败不能阻断请求。
            }
            return result.toMap()
        }

        internal fun deriveClientId(rawId: String?): String? {
            val value = rawId?.lowercase() ?: return null
            if (!Regex("^[0-9a-f]{1,16}$").matches(value)) return null
            val canonical = value.padStart(16, '0')
            if (canonical == "0000000000000000" || canonical == "9774d56d682e549c") return null
            val digest = MessageDigest.getInstance("SHA-256")
                .digest("nuist-sta:ssaid:v1:$canonical".toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        }
    }
}

/** 只读单个白名单属性；进程总预算 1200 ms，每项不超过 150 ms 或 256 字节。 */
private class BoundedSystemProperties {
    private val deadline = System.nanoTime() + 1_200_000_000L
    private val values = mutableMapOf<String, String?>()

    fun read(key: String): String? {
        if (key !in RomInfoResolver.propertyKeys) return null
        if (values.containsKey(key)) return values[key]
        if (System.nanoTime() >= deadline) return null
        val value = readProperty(key)
        values[key] = value
        return value
    }

    private fun readProperty(key: String): String? {
        var process: Process? = null
        try {
            process = ProcessBuilder("/system/bin/getprop", key).redirectErrorStream(true).start()
            val propertyDeadline = minOf(deadline, System.nanoTime() + 150_000_000L)
            // Process.waitFor(timeout) 需要更高 Android 版本，这里兼容应用的 minSdk。
            while (true) {
                val exited = try {
                    process.exitValue()
                    true
                } catch (_: IllegalThreadStateException) {
                    false
                }
                if (exited) break
                if (System.nanoTime() >= propertyDeadline) return null
                Thread.sleep(5)
            }
            if (process.exitValue() != 0) return null
            val bytes = ByteArray(257)
            val count = process.inputStream.read(bytes)
            if (count <= 0 || count > 256) return null
            val value = String(bytes, 0, count, Charsets.UTF_8).trim()
            return value.takeIf { it.isNotEmpty() && it.all { character -> character.code in 32..126 } }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return null
        } catch (_: Exception) {
            return null
        } finally {
            process?.destroy()
            try { process?.inputStream?.close() } catch (_: Exception) { }
            try { process?.outputStream?.close() } catch (_: Exception) { }
            try { process?.errorStream?.close() } catch (_: Exception) { }
        }
    }
}
