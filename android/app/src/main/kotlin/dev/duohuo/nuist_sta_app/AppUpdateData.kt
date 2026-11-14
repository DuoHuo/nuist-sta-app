package dev.duohuo.nuist_sta_app

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArraySet

/** 更新失败只跨通道传递稳定分类，不携带网址、文件路径或系统异常正文。 */
internal class AppUpdateFailure(val code: String) : IOException(code)

/** 一次可分发缓存修订；所有本地文件及续传都绑定该修订的完整哈希。 */
internal data class AppUpdateRelease(val values: Map<String, Any>) {
    val revision get() = values["revision"] as String
    val sha256 get() = values["sha256"] as String
    val size get() = values["size"] as Long
    val packageName get() = values["packageName"] as String
    val downloadUrl get() = values["downloadUrl"] as String
    val statusUrl get() = values["statusUrl"] as String

    fun sameArtifact(other: AppUpdateRelease): Boolean = listOf(
        "revision", "versionName", "versionCode", "packageName", "channel", "abi", "minSdk",
        "size", "sha256", "downloadUrl", "statusUrl",
    ).all { values[it] == other.values[it] }

    companion object {
        fun parse(source: Map<*, *>): AppUpdateRelease {
            val data = mutableMapOf<String, Any>()
            for (key in listOf("revision", "versionName", "packageName", "channel", "abi", "sha256", "downloadUrl", "statusUrl")) {
                val value = source[key] as? String ?: throw AppUpdateFailure("invalid_release")
                if (value.isBlank() || value.length > 2048) throw AppUpdateFailure("invalid_release")
                data[key] = value
            }
            for (key in listOf("versionCode", "minSdk", "size")) {
                val number = source[key] as? Number ?: throw AppUpdateFailure("invalid_release")
                val value = number.toLong()
                if (number.toDouble() != value.toDouble() || value <= 0) throw AppUpdateFailure("invalid_release")
                data[key] = value
            }
            for (key in listOf("title", "changelog", "publishedAt")) {
                val value = source[key] as? String ?: ""
                if (value.length > 1024 * 1024) throw AppUpdateFailure("invalid_release")
                data[key] = value
            }
            val release = AppUpdateRelease(data.toMap())
            if (!Regex("^[A-Za-z0-9_.-]{1,128}$").matches(release.revision) ||
                !Regex("^[0-9a-f]{64}$").matches(release.sha256) ||
                release.size > 2L * 1024 * 1024 * 1024
            ) throw AppUpdateFailure("invalid_release")
            AppUpdateHttp.validateUrl(release.downloadUrl)
            AppUpdateHttp.validateUrl(release.statusUrl)
            return release
        }

        fun parse(source: JSONObject): AppUpdateRelease = parse(
            source.keys().asSequence().associateWith { source.get(it) },
        )
    }
}

/** 原生更新任务的单一状态源；文件放在不参与备份的应用私有目录。 */
internal object AppUpdateStore {
    private lateinit var app: Context
    private lateinit var stateFile: AtomicFile
    private val main = Handler(Looper.getMainLooper())
    val listeners = CopyOnWriteArraySet<() -> Unit>()
    @Volatile var release: AppUpdateRelease? = null
        private set
    @Volatile var headers: Map<String, String> = emptyMap()
        private set
    @Volatile var status = "idle"
        private set
    @Volatile var bytes = 0L
        private set
    @Volatile var errorCode: String? = null
        private set
    @Volatile var etag: String? = null
        private set
    @Volatile var token = 0L
        private set
    @Volatile var sessionId = -1
        private set

    @Synchronized fun initialize(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        stateFile = AtomicFile(File(File(app.noBackupFilesDir, "app_updates"), "task.json"))
        try {
            if (!stateFile.baseFile.exists()) return
            if (stateFile.baseFile.length() > 8 * 1024 * 1024) throw AppUpdateFailure("storage")
            val raw = stateFile.openRead().bufferedReader().use { it.readText() }
            if (raw.length > 8 * 1024 * 1024) throw AppUpdateFailure("storage")
            val json = JSONObject(raw)
            release = json.optJSONObject("release")?.let(AppUpdateRelease::parse)
            headers = json.optJSONObject("headers")?.let { headerJson ->
                cleanHeaders(headerJson.keys().asSequence().associateWith { headerJson.get(it) })
            } ?: emptyMap()
            token = json.optLong("token", 0)
            sessionId = json.optInt("sessionId", -1)
            status = json.optString("status", "idle")
            errorCode = json.optString("errorCode").takeIf { it.isNotEmpty() }
            etag = json.optString("etag").takeIf(::validEtag)
            if (status !in setOf("idle", "downloading", "paused", "verifying", "ready", "installing", "failed", "revoked")) {
                throw AppUpdateFailure("storage")
            }
            val item = release
            if (status == "installing" && item != null) {
                val session = if (sessionId >= 0) app.packageManager.packageInstaller.getSessionInfo(sessionId) else null
                if (session?.isSealed != true) {
                    // 未提交的会话可重新安装；已消失的会话保留标识，以接收迟到的系统结果。
                    if (session != null) abandonSession()
                    status = "paused"
                    errorCode = "interrupted"
                }
            } else {
                token++
                abandonSession()
                if (status in setOf("downloading", "verifying", "ready")) {
                    status = "paused"
                    errorCode = "interrupted"
                }
            }
            bytes = item?.let { if (completeFile(it).exists()) completeFile(it).length() else partFile(it).length() } ?: 0
            persist()
        } catch (_: Exception) {
            release = null
            headers = emptyMap()
            status = "idle"
            bytes = 0
            errorCode = "storage"
            etag = null
        }
    }

    fun directory(): File = File(app.noBackupFilesDir, "app_updates").also {
        if (!it.isDirectory && !it.mkdirs()) throw AppUpdateFailure("storage")
    }
    fun partFile(item: AppUpdateRelease) = File(directory(), "${item.sha256}.part")
    fun completeFile(item: AppUpdateRelease) = File(directory(), "${item.sha256}.apk")
    fun validEtag(value: String): Boolean = value.length in 3..256 &&
        value.startsWith('"') && value.endsWith('"') && value.none { it.code < 32 || it.code > 126 }

    @Synchronized fun prepare(item: AppUpdateRelease, requestHeaders: Map<*, *>): Long {
        if (status in setOf("downloading", "verifying", "installing")) throw AppUpdateFailure("busy")
        val clean = cleanHeaders(requestHeaders)
        val old = release
        if (old?.revision != item.revision || old.sha256 != item.sha256) {
            if (old != null) deleteFiles(old)
            bytes = 0
            etag = null
        }
        abandonSession()
        release = item
        headers = clean
        status = "paused"
        errorCode = null
        token++
        persist()
        notifyChanged()
        return token
    }

    @Synchronized fun active(expected: Long): Boolean = token == expected && release != null && status != "revoked"

    /** 取消与文件创建、提升为已校验文件互斥，避免已取消任务重新留下可安装文件。 */
    @Synchronized fun <T> guarded(expected: Long, action: () -> T): T {
        if (!active(expected)) throw AppUpdateFailure("cancelled")
        return action()
    }

    @Synchronized fun update(expected: Long, nextStatus: String = status, count: Long = bytes,
                             error: String? = null, nextEtag: String? = etag, save: Boolean = true) {
        if (!active(expected)) return
        status = nextStatus
        bytes = count
        errorCode = error
        etag = nextEtag
        if (save) {
            try { persist() } finally { notifyChanged() }
        } else notifyChanged()
    }

    @Synchronized fun cancel(expected: Long = token, revoked: Boolean = false) {
        if (token != expected) return
        token++
        abandonSession()
        release?.let(::deleteFiles)
        status = if (revoked) "revoked" else "idle"
        errorCode = if (revoked) "revoked" else null
        bytes = 0
        etag = null
        if (!revoked) { release = null; headers = emptyMap() }
        persist()
        notifyChanged()
    }

    @Synchronized fun setSession(expected: Long, id: Int) {
        if (!active(expected)) throw AppUpdateFailure("cancelled")
        sessionId = id
        persist()
    }

    @Synchronized fun abandonSession() {
        if (sessionId >= 0) {
            try { app.packageManager.packageInstaller.abandonSession(sessionId) } catch (_: Exception) { }
            sessionId = -1
        }
    }

    @Synchronized fun snapshot(): Map<String, Any?> = mapOf(
        "status" to status, "downloadedBytes" to bytes, "totalBytes" to (release?.size ?: 0L),
        "release" to release?.values, "errorCode" to errorCode,
        "notificationAllowed" to notificationsAllowed(app),
        "installAllowed" to installAllowed(app),
    )

    fun notifyChanged() { main.post { listeners.forEach { it() } } }

    @Synchronized private fun persist() {
        val json = JSONObject().put("release", release?.let { JSONObject(it.values) })
            .put("headers", JSONObject(headers)).put("status", status).put("token", token)
            .put("errorCode", errorCode).put("etag", etag).put("sessionId", sessionId)
        var stream: java.io.FileOutputStream? = null
        try {
            stream = stateFile.startWrite()
            stream.write(json.toString().toByteArray(Charsets.UTF_8))
            stateFile.finishWrite(stream)
        } catch (_: Exception) {
            stateFile.failWrite(stream)
            throw AppUpdateFailure("storage")
        }
    }

    fun deleteFiles(item: AppUpdateRelease) {
        partFile(item).delete()
        completeFile(item).delete()
    }

    fun notificationsAllowed(context: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            (context.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() == true) &&
            (Build.VERSION.SDK_INT < 26 || context.getSystemService(NotificationManager::class.java)
                ?.getNotificationChannel(AppUpdateService.CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE)

    fun installAllowed(context: Context) = Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()

    /** 下载完成后校验文件大小与 SHA256，安装是否可行由系统安装器判断。 */
    fun verify(item: AppUpdateRelease, file: File, stillActive: () -> Boolean) {
        if (file.length() != item.size) throw AppUpdateFailure("size_mismatch")
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                if (!stillActive()) throw AppUpdateFailure("cancelled")
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        if (hex(digest.digest()) != item.sha256) throw AppUpdateFailure("hash_mismatch")
    }

    private fun cleanHeaders(source: Map<*, *>): Map<String, String> {
        val allowed = setOf("X-Client-Metadata-Version", "X-Client-Platform", "X-App-Package", "X-App-Channel",
            "X-App-Version", "X-App-Version-Code", "X-Client-ID", "X-Client-ID-Type", "X-Android-Version",
            "X-Android-SDK", "X-ROM-Name", "X-ROM-Version")
        return source.entries.mapNotNull { (key, value) ->
            if (key is String && key in allowed && value is String && value.length in 1..255 &&
                value.all { it.code in 0x21..0x7e }) key to value else null
        }.toMap()
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}

/** 更新网络只连接现有社团 HTTPS 原点，禁止重定向和门户请求头。 */
/** 原生请求经过现有事件通道交回统一日志器；不在原生侧保存未脱敏正文。 */
internal object AppUpdateDiagnostics {
    private val main = Handler(Looper.getMainLooper())
    private var missing = 0
    var listener: ((Map<String, Any?>) -> Unit)? = null
        set(value) {
            field = value
            if (value != null && missing > 0) {
                value(mapOf("type" to "http_diagnostic", "exchange" to mapOf(
                    "source" to "android_update",
                    "capture" to mapOf("complete" to false, "reason" to "flutter_engine_unavailable", "missing_exchanges" to missing)
                )))
                missing = 0
            }
        }

    fun publish(exchange: Map<String, Any?>, bodyFile: File? = null) {
        main.post {
            val receiver = listener
            if (receiver == null) missing++ else receiver(mapOf(
                "type" to "http_diagnostic", "exchange" to exchange,
                "bodyFile" to bodyFile?.absolutePath,
            ))
        }
    }

    fun response(status: Int?, headers: Map<String, List<String>>?, body: String?, complete: Boolean): Map<String, Any?> = mapOf(
        "status_code" to status,
        "headers" to headers,
        "body" to body,
        "encoding" to "utf8",
        "complete" to complete,
    )
}

internal object AppUpdateHttp {
    /** 校验续传响应；200 必须重写，206 必须精确匹配偏移、长度和强 ETag。 */
    fun downloadOffset(code: Int, offset: Long, size: Long, contentRange: String?,
                       previousEtag: String?, responseEtag: String?): Long = when (code) {
        200 -> 0
        206 -> {
            val range = Regex("^bytes (\\d+)-(\\d+)/(\\d+)$").matchEntire(contentRange ?: "")
                ?: throw AppUpdateFailure("invalid_response")
            if (range.groupValues[1].toLongOrNull() != offset ||
                range.groupValues[2].toLongOrNull() != size - 1 ||
                range.groupValues[3].toLongOrNull() != size ||
                (offset > 0 && (previousEtag == null || responseEtag != previousEtag))
            ) throw AppUpdateFailure("invalid_response")
            offset
        }
        410 -> throw AppUpdateFailure("revoked")
        429, in 500..599 -> throw AppUpdateFailure("network")
        else -> throw AppUpdateFailure("invalid_response")
    }

    fun validateUrl(value: String) {
        val uri = try { URI(value) } catch (_: Exception) { throw AppUpdateFailure("invalid_release") }
        if (uri.scheme != "https" || uri.host != "app.duohuo.org.cn" || uri.port !in setOf(-1, 443) ||
            uri.rawUserInfo != null || uri.rawFragment != null
        ) throw AppUpdateFailure("invalid_release")
    }

    fun connect(url: String, headers: Map<String, String>): HttpURLConnection {
        validateUrl(url)
        return (URI(url).toURL().openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            connectTimeout = 15000
            readTimeout = 20000
            useCaches = false
            setRequestProperty("Accept-Encoding", "identity")
            setRequestProperty("User-Agent", "NUIST++/AppUpdate")
            headers.forEach { (key, value) -> setRequestProperty(key, value) }
        }
    }

    fun check(item: AppUpdateRelease, headers: Map<String, String>) {
        val connection = connect(item.statusUrl, headers)
        val requestHeaders = connection.requestProperties.toMap()
        val started = android.os.SystemClock.elapsedRealtime()
        val output = java.io.ByteArrayOutputStream()
        var complete = false
        var failure: Exception? = null
        var status: Int? = null
        var responseHeaders: Map<String, List<String>>? = null
        try {
            status = connection.responseCode
            responseHeaders = connection.headerFields.entries.filter { it.key != null }.associate { it.key!! to it.value }
            when (status) {
                410 -> throw AppUpdateFailure("revoked")
                200 -> Unit
                429, in 500..599 -> throw AppUpdateFailure("network")
                else -> throw AppUpdateFailure("invalid_response")
            }
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > 8 * 1024 * 1024) throw AppUpdateFailure("invalid_response")
                    output.write(buffer, 0, count)
                }
            }
            complete = true
            val response = JSONObject(output.toString("UTF-8"))
            if (!response.optBoolean("available", false)) throw AppUpdateFailure("revoked")
            val current = AppUpdateRelease.parse(response.getJSONObject("release"))
            if (!current.sameArtifact(item)) throw AppUpdateFailure("revoked")
        } catch (error: Exception) {
            failure = error
            // 非成功状态的错误体只能从 errorStream 取得，不能重新发送请求。
            if (output.size() == 0 && status != null) {
                try {
                    connection.errorStream?.use { input -> input.copyTo(output) }
                    complete = connection.errorStream != null
                } catch (_: Exception) { complete = false }
            }
            throw error
        } finally {
            AppUpdateDiagnostics.publish(mapOf(
                "source" to "android_update", "stage" to "update.validate",
                "request" to mapOf("url" to item.statusUrl, "method" to "GET", "headers" to requestHeaders),
                "response" to AppUpdateDiagnostics.response(status, responseHeaders, output.toString("UTF-8"), complete),
                "capture" to mapOf("complete" to complete, "reason" to if (complete) "complete" else "response_incomplete"),
                "duration_ms" to android.os.SystemClock.elapsedRealtime() - started,
                "error" to failure?.let { mapOf("type" to it.javaClass.simpleName, "message" to it.message,
                    "stack" to it.stackTraceToString(), "code" to (it as? AppUpdateFailure)?.code) },
            ))
            connection.disconnect()
        }
    }
}
