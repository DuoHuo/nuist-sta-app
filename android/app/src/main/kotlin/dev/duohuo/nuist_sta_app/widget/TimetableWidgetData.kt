package dev.duohuo.nuist_sta_app.widget

import android.content.Context
import android.content.SharedPreferences
import dev.duohuo.nuist_sta_app.NotifyStore
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.conflate
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** Flutter 数据窗口中的一节课；墙上时间每次读取都按当前时区解析。 */
internal data class WidgetCourse(
    val name: String,
    val location: String,
    val teacher: String,
    val nodes: String,
    val start: Long,
    val end: Long,
    val lightColor: Int,
    val darkColor: Int,
) {
    val timeRange: String get() = "${widgetTime(start)}–${widgetTime(end)}"
}

/** 对应一个日期的完整数据，以及公共课表接口注入的明日首节。 */
internal data class WidgetDay(
    val date: String,
    val courses: List<WidgetCourse>,
    val tomorrowFirst: WidgetCourse?,
)

/** 原生展示使用的设置；隐藏的字段在解析入口再次过滤。 */
internal data class WidgetPreferences(
    val courseCount: Int = 2,
    val showCount: Boolean = true,
    val showCountdown: Boolean = true,
    val showLocation: Boolean = true,
    val showTeacher: Boolean = true,
    val showPeriod: Boolean = true,
)

/** 一次渲染的不可变快照，确保课表、倒计时和日期使用同一个时刻。 */
internal data class WidgetSnapshot(
    val now: Long,
    val preferences: WidgetPreferences = WidgetPreferences(),
    val days: List<WidgetDay> = emptyList(),
    val state: String = "needsUpdate",
    val hasCache: Boolean = false,
) {
    val today: WidgetDay? get() = days.firstOrNull { it.date == NotifyStore.today(now) }
    val pending: List<WidgetCourse> get() = today?.courses.orEmpty().filter { it.end > now }
    val usable: Boolean get() = today != null && (state == "ok" || state == "loadFailed" && hasCache)
    val tomorrow: WidgetCourse? get() {
        val date = Calendar.getInstance().apply {
            timeInMillis = now
            add(Calendar.DAY_OF_MONTH, 1)
        }.timeInMillis
        return today?.tomorrowFirst?.takeIf { NotifyStore.today(it.start) == NotifyStore.today(date) }
    }
    val statusTitle: String get() = when {
        !usable && state == "loadFailed" -> "课表加载失败"
        !usable -> "课表需要更新"
        today?.courses.isNullOrEmpty() -> "今天没有课程"
        else -> "今天的课上完了"
    }
}

internal fun widgetTime(time: Long): String = SimpleDateFormat("HH:mm", Locale.US).format(time)

/** 只读取现有桥接存储。Glance 会话存活时也能收到同步、时钟和配置变化。 */
internal object TimetableWidgetData {
    private const val REVISION = "widget_render_revision"

    fun read(context: Context, now: Long = System.currentTimeMillis()): WidgetSnapshot = try {
        parse(NotifyStore.prefs(context).getString(NotifyStore.KEY_WIDGET, null), now)
    } catch (_: Exception) {
        WidgetSnapshot(now)
    }

    fun parse(json: String?, now: Long): WidgetSnapshot {
        if (json.isNullOrBlank()) return WidgetSnapshot(now)
        return try {
            val root = JSONObject(json)
            val p = root.optJSONObject("prefs") ?: JSONObject()
            val preferences = WidgetPreferences(
                courseCount = p.optInt("courseCount", 2).takeIf { it in 1..3 } ?: 2,
                showCount = p.optBoolean("showCount", true),
                showCountdown = p.optBoolean("showCountdown", true),
                showLocation = p.optBoolean("showLocation", true),
                showTeacher = p.optBoolean("showTeacher", true),
                showPeriod = p.optBoolean("showPeriod", true),
            )
            fun course(o: JSONObject?): WidgetCourse? {
                if (o == null) return null
                val start = NotifyStore.parseLocal(o.optString("start")) ?: return null
                val end = NotifyStore.parseLocal(o.optString("end")) ?: return null
                if (end <= start) return null
                fun text(key: String) = if (o.isNull(key)) "" else o.optString(key).trim()
                return WidgetCourse(
                    name = text("name"),
                    location = if (preferences.showLocation) text("location") else "",
                    teacher = if (preferences.showTeacher) text("teacherFirst") else "",
                    nodes = if (preferences.showPeriod) text("nodes") else "",
                    start = start, end = end,
                    lightColor = o.optLong("color", 0).toInt(),
                    darkColor = o.optLong("colorDark", 0).toInt(),
                )
            }
            val array = root.optJSONArray("days")
            val days = buildList {
                for (index in 0 until (array?.length() ?: 0)) {
                    val day = array?.optJSONObject(index) ?: continue
                    val items = day.optJSONArray("items")
                    val courses = buildList {
                        for (item in 0 until (items?.length() ?: 0)) {
                            course(items?.optJSONObject(item))?.let { add(it) }
                        }
                    }.sortedBy { it.start }
                    // 显式 null 表示明天没课，不能回退到旧的顶层注入值。
                    val tomorrow = if (day.has("tomorrowFirst")) day.optJSONObject("tomorrowFirst")
                        else root.optJSONObject("tomorrowFirst")
                    add(WidgetDay(day.optString("date"), courses, course(tomorrow)))
                }
            }
            WidgetSnapshot(now, preferences, days, root.optString("state", "needsUpdate"),
                root.optBoolean("hasCache", false))
        } catch (_: Exception) {
            WidgetSnapshot(now)
        }
    }

    fun observe(context: Context): Flow<WidgetSnapshot> = callbackFlow {
        val preferences = try { NotifyStore.prefs(context) } catch (_: Exception) { null }
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == NotifyStore.KEY_WIDGET || key == REVISION || key == null) {
                trySend(read(context))
            }
        }
        preferences?.registerOnSharedPreferenceChangeListener(listener)
        trySend(read(context))
        awaitClose { preferences?.unregisterOnSharedPreferenceChangeListener(listener) }
    }.conflate()

    fun invalidate(context: Context) {
        try {
            NotifyStore.prefs(context).edit().putLong(REVISION, System.nanoTime()).apply()
        } catch (_: Exception) {
            // 存储不可用时，新 Glance 会话仍会提供需要更新的空状态。
        }
    }
}
