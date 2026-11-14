package dev.duohuo.nuist_sta_app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.UUID

/** 无 Flutter 回执的广播诊断。只保存净化后的系统信息，不保存课程、通知正文或凭据。 */
internal object NativeBackgroundDiagnostics {
    private const val PREFS = "native_background_diagnostics"
    private const val KEY = "pending"
    private const val MAX_RECORDS = 64
    private const val RETENTION_MS = 7L * 24 * 60 * 60 * 1000

    private fun preferences(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 广播调用使用此入口；同步 MethodChannel 操作由原回执记录，不能重复入队。 */
    @Synchronized fun enqueue(context: Context, diagnostics: List<Map<String, Any?>>) {
        if (diagnostics.isEmpty()) return
        try {
            val now = System.currentTimeMillis()
            val records = load(context).filter { now - (it["ts"] as Number).toLong() <= RETENTION_MS }.toMutableList()
            for (diagnostic in diagnostics) {
                val fallback = diagnostic["reason_code"] in setOf(
                    "exact_alarm_permission_unavailable", "exact_alarm_permission_revoked", "exact_alarm_failed",
                )
                records.add(mapOf(
                    "id" to UUID.randomUUID().toString(), "ts" to now,
                    "scope" to "timetable.native_background", "event" to if (fallback) "background.degraded" else "background.failed",
                    "details" to safeDetails(diagnostic),
                ))
            }
            val dropped = (records.size - MAX_RECORDS).coerceAtLeast(0)
            if (dropped > 0) {
                val previousDropped = records.take(dropped).sumOf {
                    ((it["details"] as? Map<*, *>)?.get("queue_dropped_before") as? Number)?.toInt() ?: 0
                }
                records.subList(0, dropped).clear()
                val latest = records.last()
                @Suppress("UNCHECKED_CAST")
                records[records.lastIndex] = latest + ("details" to ((latest["details"] as Map<String, Any?>) + ("queue_dropped_before" to dropped + previousDropped)))
            }
            save(context, records)
        } catch (_: Exception) {
            // 诊断存储不可用时不能让系统广播崩溃；没有另一可靠介质可递归记录自身故障。
        }
    }

    /** 不移除记录；Dart 持久化成功后再按 id 确认。 */
    @Synchronized fun read(context: Context): List<Map<String, Any?>> {
        val records = load(context)
        val cutoff = System.currentTimeMillis() - RETENTION_MS
        val retained = records.filter { (it["ts"] as Number).toLong() >= cutoff }
        if (records.size != retained.size) save(context, retained)
        return retained
    }

    @Synchronized fun acknowledge(context: Context, ids: Set<String>) {
        save(context, read(context).filter { it["id"] !in ids })
    }

    @Synchronized fun clear(context: Context) {
        if (!preferences(context).edit().remove(KEY).commit()) throw IOException("无法清除原生诊断队列")
    }

    private fun load(context: Context): List<Map<String, Any?>> {
        val array = JSONArray(preferences(context).getString(KEY, "[]") ?: "[]")
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            if (item.optString("id").isEmpty() || item.optLong("ts", -1) < 0) return@mapNotNull null
            objectMap(item)
        }
    }

    private fun save(context: Context, records: List<Map<String, Any?>>) {
        val encoded = JSONArray(records.map { JSONObject(it) }).toString()
        if (!preferences(context).edit().putString(KEY, encoded).commit()) throw IOException("无法保存原生诊断队列")
    }

    private fun objectMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key ->
        decode(value.opt(key))
    }

    private fun decode(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> objectMap(value)
        is JSONArray -> (0 until value.length()).map { decode(value.opt(it)) }
        else -> value
    }

    private fun safeDetails(value: Map<String, Any?>): Map<String, Any?> {
        val result = safeException(value, (value["stage"] as? String)?.endsWith(".decode") == true).toMutableMap()
        for (key in listOf("stage", "reason_code")) {
            val text = value[key] as? String
            if (text != null && text.matches(Regex("[a-zA-Z0-9_.]+"))) result[key] = text
        }
        result["capture_source"] = "android_broadcast"
        return result
    }

    private fun safeException(value: Map<String, Any?>, parsing: Boolean = false): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val type = (value["native_type"] ?: value["type"]) as? String
        if (type != null && type.matches(Regex("[a-zA-Z0-9_.$]+"))) result["native_type"] = type
        val raw = value["message"] as? String
        val parserMessage = parsing || type?.contains("JSONException") == true ||
            type?.endsWith("NumberFormatException") == true || type?.endsWith("ParseException") == true
        if (raw != null) {
            val cleaned = if (parserMessage) cleanJsonMessage(raw, result) else cleanSystemMessage(raw)
            result["message"] = cleaned
            if (cleaned != raw) result["message_redacted"] = true
        }
        // Throwable.stackTraceToString 的首行和 Caused by 行含 message；帧本身不含用户数据。
        val stack = value["stack"] as? String
        if (stack != null) result["stack"] = stack.lineSequence().filter {
            it.trimStart().startsWith("at ") || it.trimStart().matches(Regex("\\.\\.\\. \\d+ more"))
        }.joinToString("\n")
        val causes = value["causes"] as? List<*>
        if (causes != null) result["causes"] = causes.mapNotNull {
            @Suppress("UNCHECKED_CAST")
            (it as? Map<String, Any?>)?.let { cause -> safeException(cause, parserMessage) }
        }
        return result
    }

    private fun cleanJsonMessage(raw: String, details: MutableMap<String, Any?>): String {
        val position = Regex("(?i)(?:at character|position|offset)\\s+(\\d+)").find(raw)
        position?.groupValues?.get(1)?.toLongOrNull()?.let { details["parse_position"] = it }
        var message = raw.replace(Regex("(?is)(at character\\s+\\d+)\\s+of\\s+.*$"), "$1 of [REDACTED_JSON_SOURCE]")
        message = message.replace(Regex("(?is)^Value .*? of type ([a-zA-Z0-9_.$]+) cannot be converted to ([a-zA-Z0-9_.$]+).*$"),
            "Value [REDACTED_JSON_VALUE] of type $1 cannot be converted to $2")
        message = message.replace(Regex("(?is)^Value .*? cannot be converted to ([a-zA-Z0-9_.$]+).*$"),
            "Value [REDACTED_JSON_VALUE] cannot be converted to $1")
        message = message.replace(Regex("(?is)(Expected ':' after).*?(?= at character|$)"), "$1 [REDACTED_JSON_KEY]")
        val reason = when {
            raw.startsWith("End of input") -> "unexpected_end"
            raw.startsWith("Unterminated") -> "unterminated_value"
            raw.startsWith("Expected") -> "expected_token"
            raw.startsWith("Value") -> "invalid_value_type"
            raw.startsWith("Invalid") || raw.startsWith("Bad") -> "invalid_token"
            else -> "invalid_json"
        }
        details["parse_reason"] = reason
        if (reason == "invalid_json") message = "JSON parsing failed" + (position?.value?.let { " ($it)" } ?: "")
        return cleanSystemMessage(message)
    }

    private fun cleanSystemMessage(raw: String): String = raw
        .replace(Regex("(?i)(?:https?|content|file)://[^\\s<>]+"), "[REDACTED_URL]")
        .replace(Regex("(?i)((?:authorization|cookie|token|password|secret|ticket|jwt|pin|private[_-]?key)\\s*[:=]\\s*)[^\\r\\n]+"), "$1[REDACTED_SECRET]")
        .replace(Regex("(?i)((?:student[_-]?id|studentnumber|姓名|学号|课程名|宿舍号|payload)\\s*[:=]\\s*)[^\\r\\n]+"), "$1[REDACTED_PERSONAL]")
        .replace(Regex("(?<!\\d)\\d{12,}(?!\\d)"), "[REDACTED_ID]")
        .replace(Regex("/(?:data|storage|sdcard)/[^\\s:]+"), "[REDACTED_PATH]")
}
