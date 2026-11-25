package dev.duohuo.nuist_sta_app.widget

import android.content.Context
import dev.duohuo.nuist_sta_app.NotifyStore
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** 4×6 当周课表的显示设置；越界值在解析时钳制。 */
internal data class WeekPreferences(
    val opacity: Int = 100,
    val widgetOpacity: Int = 100,
    val showWeekend: Boolean = false,
    val showTeacher: Boolean = true,
    val showPeriod: Boolean = true,
    val nodesPerDay: Int? = null,
    val weekStartsSunday: Boolean = false,
    val showGridLines: Boolean = true,
    val headerTextSize: Float = 11f,
    val fontScale: Float = 1f,
)

/** 一节作息；时间只用于解析缺少节次的旧数据。 */
internal data class WeekPeriod(val node: Int, val start: String, val end: String) {
    val startMinutes: Int get() = minutesOf(start)
    val endMinutes: Int get() = minutesOf(end)
}

/** HH:mm 转当日分钟数；无法解析时返回 0。 */
internal fun minutesOf(hhmm: String): Int {
    val parts = hhmm.split(":")
    if (parts.size < 2) return 0
    val hour = parts[0].toIntOrNull() ?: return 0
    val minute = parts[1].toIntOrNull() ?: return 0
    return hour * 60 + minute
}

/** 绝对时间在当前时区的当日分钟数。 */
internal fun minutesOfDay(time: Long): Int {
    val calendar = Calendar.getInstance().apply { timeInMillis = time }
    return calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE)
}

/** 一周中的一节或多节课；颜色保留浅 / 深两套。 */
internal data class WeekCourse(
    val id: String,
    val name: String,
    val kind: WidgetItemKind,
    val location: String,
    val teacher: String,
    val nodes: String,
    val weekTag: String,
    val startNode: Int,
    val endNode: Int,
    val start: Long,
    val end: Long,
    val lightColor: Int,
    val darkColor: Int,
    val lightCellColor: Int,
    val darkCellColor: Int,
    val lightTextColor: Int,
    val darkTextColor: Int,
) {
    val displayName: String
        get() = when {
            kind.label.isEmpty() -> name
            name.isEmpty() -> kind.label
            else -> kind.label + " · " + name
        }
}

internal data class WeekDay(val date: String, val weekday: Int, val courses: List<WeekCourse>)

internal data class WeekBlock(val start: String, val week: Int?, val days: List<WeekDay>) {
    fun contains(date: String): Boolean = days.any { it.date == date }
}

/** 一次渲染的周课表快照；缺 week 段时 weeks 为空，由内容层显示空态。 */
internal data class WeekSnapshot(
    val now: Long,
    val preferences: WeekPreferences = WeekPreferences(),
    val periods: List<WeekPeriod> = emptyList(),
    val weeks: List<WeekBlock> = emptyList(),
    val state: String = "needsUpdate",
    val hasCache: Boolean = false,
    val termStartMissing: Boolean = false,
    val reason: String = "",
    val hasIndependentLocalData: Boolean = false,
) {
    fun displayWeek(offset: Int = 0): WeekBlock? {
        // 本地课程在未设置开学日时沿用 App 网格的第 1 周。
        if (termStartMissing && !hasIndependentLocalData) return null
        if (state != "ok" && !(state == "loadFailed" && hasCache)) {
            return null
        }
        val today = NotifyStore.today(now)
        val current = weeks.indexOfFirst { it.contains(today) }
        return if (current < 0) null else weeks.getOrNull(current + offset)
    }
}

/** 只读取现有桥接存储；payload 缺少 week 段或解析失败时降级为空快照。 */
internal object TimetableWeekWidgetData {
    fun read(context: Context, now: Long = System.currentTimeMillis()): WeekSnapshot = try {
        parse(NotifyStore.prefs(context).getString(NotifyStore.KEY_WIDGET, null), now)
    } catch (_: Exception) {
        WeekSnapshot(now)
    }

    fun parse(json: String?, now: Long): WeekSnapshot {
        if (json.isNullOrBlank()) return WeekSnapshot(now)
        return try {
            val root = JSONObject(json)
            val source = WidgetSourceStatus(root, now)
            val hasCache = root.optBoolean("hasCache", false)
            val week = root.optJSONObject("week") ?: return WeekSnapshot(
                now = now,
                state = source.state,
                hasCache = hasCache,
                reason = source.reason,
                hasIndependentLocalData = source.hasIndependentLocalData,
            )
            val top = root.optJSONObject("prefs")
            val prefsJson = week.optJSONObject("prefs") ?: top
            fun bool(key: String, fallback: Boolean): Boolean {
                val value = prefsJson
                if (value != null && value.has(key)) return value.optBoolean(key, fallback)
                if (top != null && top.has(key)) return top.optBoolean(key, fallback)
                return fallback
            }

            fun int(key: String, fallback: Int, min: Int, max: Int): Int {
                val value = prefsJson?.optInt(key, fallback) ?: fallback
                return value.coerceIn(min, max)
            }

            fun float(key: String, fallback: Float, min: Float, max: Float): Float {
                val value = prefsJson?.optDouble(key, fallback.toDouble())?.toFloat() ?: fallback
                return if (value.isFinite()) value.coerceIn(min, max) else fallback
            }

            val preferences = WeekPreferences(
                opacity = int("opacity", 100, 30, 100),
                widgetOpacity = int("widgetOpacity", 100, 30, 100),
                showWeekend = bool("showWeekend", false),
                showTeacher = bool("showTeacher", true),
                showPeriod = bool("showPeriod", true),
                nodesPerDay = prefsJson?.optInt("nodesPerDay", 0)?.takeIf { it > 0 },
                weekStartsSunday = bool("weekStartsSunday", false),
                showGridLines = bool("showGridLines", true),
                headerTextSize = float("headerTextSize", 11f, 10f, 14f),
                fontScale = float("fontScale", 1f, 0.9f, 1.15f),
            )
            val periodsJson = week.optJSONArray("periods")
            val periods = buildList {
                for (index in 0 until (periodsJson?.length() ?: 0)) {
                    val item = periodsJson?.optJSONObject(index) ?: continue
                    val node = item.optInt("node", 0)
                    if (node !in 1..WeekGeometry.MAX_ROWS) continue
                    add(WeekPeriod(node, item.optString("start"), item.optString("end")))
                }
            }
            val weeksJson = week.optJSONArray("weeks")
            val weeks = buildList {
                for (index in 0 until (weeksJson?.length() ?: 0)) {
                    val block = weeksJson?.optJSONObject(index) ?: continue
                    val daysJson = block.optJSONArray("days")
                    val days = buildList {
                        for (dayIndex in 0 until (daysJson?.length() ?: 0)) {
                            val day = daysJson?.optJSONObject(dayIndex) ?: continue
                            val itemsJson = day.optJSONArray("items")
                            val courses = buildList {
                                for (itemIndex in 0 until (itemsJson?.length() ?: 0)) {
                                    val item = itemsJson?.optJSONObject(itemIndex) ?: continue
                                    if (source.isVisible(item)) {
                                        parseCourse(item, preferences)?.let { add(it) }
                                    }
                                }
                            }.sortedBy { it.start }
                            val date = day.optString("date")
                            val weekday = day.optInt("weekday", 0).takeIf { it in 1..7 }
                                ?: weekdayOf(date)
                            if (date.isNotEmpty() && weekday in 1..7) {
                                add(WeekDay(date, weekday, courses))
                            }
                        }
                    }
                    add(
                        WeekBlock(
                            start = block.optString("start"),
                            week = block.optInt("week", 0).takeIf { it > 0 },
                            days = days,
                        ),
                    )
                }
            }
            WeekSnapshot(
                now = now,
                preferences = preferences,
                periods = periods,
                weeks = weeks,
                state = source.state,
                hasCache = hasCache,
                termStartMissing = week.optBoolean("termStartMissing", false),
                reason = source.reason,
                hasIndependentLocalData = source.hasIndependentLocalData,
            )
        } catch (_: Exception) {
            WeekSnapshot(now)
        }
    }

    private fun parseCourse(item: JSONObject, preferences: WeekPreferences): WeekCourse? {
        val start = NotifyStore.parseLocal(item.optString("start")) ?: return null
        val end = NotifyStore.parseLocal(item.optString("end")) ?: return null
        if (end <= start) return null
        fun text(key: String) = if (item.isNull(key)) "" else item.optString(key).trim()
        return WeekCourse(
            id = text("courseId"),
            name = text("name"),
            kind = WidgetItemKind.parse(text("kind")),
            location = text("location"),
            teacher = if (preferences.showTeacher) text("teacher").ifBlank { text("teacherFirst") } else "",
            nodes = if (preferences.showPeriod) text("nodes") else "",
            weekTag = text("weekTag"),
            startNode = item.optInt("startNode", 0),
            endNode = item.optInt("endNode", 0),
            start = start,
            end = end,
            lightColor = item.optLong("color", 0).toInt(),
            darkColor = item.optLong("colorDark", 0).toInt(),
            lightCellColor = item.optLong("cellColor", 0).toInt(),
            darkCellColor = item.optLong("cellColorDark", 0).toInt(),
            lightTextColor = item.optLong("textColor", 0).toInt(),
            darkTextColor = item.optLong("textColorDark", 0).toInt(),
        )
    }

    private fun weekdayOf(date: String): Int {
        return try {
            val parsed = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                isLenient = false
            }.parse(date) ?: return 0
            val day = Calendar.getInstance().apply { time = parsed }
                .get(Calendar.DAY_OF_WEEK)
            if (day == Calendar.SUNDAY) 7 else day - 1
        } catch (_: Exception) {
            0
        }
    }
}
