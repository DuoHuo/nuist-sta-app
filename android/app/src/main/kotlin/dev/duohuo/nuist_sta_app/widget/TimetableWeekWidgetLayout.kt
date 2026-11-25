package dev.duohuo.nuist_sta_app.widget

import dev.duohuo.nuist_sta_app.NotifyStore
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** 左侧节次列的一行。 */
internal data class WeekRow(val node: Int, val period: WeekPeriod?)

/** 连续课程或冲突共用一个底色与一份文字；不绘制单节续格。 */
internal data class WeekCourseBlock(val startNode: Int, val endNode: Int, val courses: List<WeekCourse>)

/** App 周视图尺寸；纵向行高单独按 Launcher 允许的高度拉伸。 */
internal class WeekGeometry(widthDp: Float, heightDp: Float, days: Int, totalRows: Int, showPeriod: Boolean) {
    // W 固定按七列加节次栏计算；显示周末或节次栏的开关不改变基准。
    private val baseWidth = widthDp / 8f
    val headerHeight = baseWidth
    val weekdayHeight = baseWidth
    val periodWidth = if (showPeriod) baseWidth else 0f
    private val gridWidth = (widthDp - periodWidth).coerceAtLeast(0f)
    val dayWidth = gridWidth / days
    val compactText = days == 7 && dayWidth < 46f
    val cellMargin = if (compactText) 1f else 1.5f
    val cellPadding = if (compactText) 2f else 4f
    val minimumTextSize = if (days == 7) 8f else 9f
    private val unit = gridWidth / 7f
    private val available = (heightDp - headerHeight - weekdayHeight - BOTTOM_INSET).coerceAtLeast(0f)
    val rowCount = if (unit > 0f) floor(available / unit).toInt().coerceIn(0, totalRows) else 0
    val rowHeight = if (rowCount > 0) max(unit, available / rowCount) else unit

    // 与 App 相同，格面宽向上对齐物理像素，扣除内距后才供测字。
    fun fontReferenceWidth(density: Float): Float =
        ceil((unit - cellMargin * 2) * density) / density

    companion object {
        // 留出宿主布局的像素取整与卡片底边，不把最后一节压到裁切线上。
        private const val BOTTOM_INSET = 2f
        const val MAX_ROWS = 11
        const val DEFAULT_ROWS = MAX_ROWS
    }
}

/** 周课表的可见行列与落格结果。 */
internal data class WeekPlan(
    val geometry: WeekGeometry,
    val weekdays: List<Int>,
    val dates: Map<Int, String>,
    val month: Int?,
    val rows: List<WeekRow>,
    val blocks: Map<Int, List<WeekCourseBlock>>,
    val unplaced: Map<Int, List<WeekCourse>>,
    val todayWeekday: Int?,
    val weekLabel: String,
)

internal object TimetableWeekWidgetLayout {
    fun plan(data: WeekSnapshot, week: WeekBlock?, widthDp: Float, heightDp: Float): WeekPlan {
        val preferences = data.preferences
        val weekdays = when {
            !preferences.showWeekend -> (1..5).toList()
            preferences.weekStartsSunday -> listOf(7, 1, 2, 3, 4, 5, 6)
            else -> (1..7).toList()
        }
        val periodOf = data.periods.associateBy { it.node }
        val totalRows = (preferences.nodesPerDay ?: periodOf.keys.maxOrNull() ?: WeekGeometry.DEFAULT_ROWS)
            .coerceIn(1, WeekGeometry.MAX_ROWS)
        val geometry = WeekGeometry(widthDp, heightDp, weekdays.size, totalRows, preferences.showPeriod)
        val days = week?.days.orEmpty().associateBy { it.weekday }
        val blocks = mutableMapOf<Int, List<WeekCourseBlock>>()
        val unplaced = mutableMapOf<Int, MutableList<WeekCourse>>()
        for (weekday in weekdays) {
            val entries = buildList {
                for (course in days[weekday]?.courses.orEmpty()) {
                    val range = nodeRange(course, data.periods)
                    if (range == null) {
                        unplaced.getOrPut(weekday) { mutableListOf() }.add(course)
                    } else if (range.first <= geometry.rowCount) {
                        add(Entry(range.first, min(range.last, geometry.rowCount), course))
                    }
                }
            }
            blocks[weekday] = dayBlocks(entries)
        }
        val today = NotifyStore.today(data.now)
        return WeekPlan(
            geometry = geometry,
            weekdays = weekdays,
            dates = days.mapValues { (_, day) -> day.date.substringAfterLast('-').toIntOrNull()?.toString().orEmpty() },
            month = week?.start?.split('-')?.getOrNull(1)?.toIntOrNull(),
            rows = (1..geometry.rowCount).map { WeekRow(it, periodOf[it]) },
            blocks = blocks,
            unplaced = unplaced,
            todayWeekday = week?.days?.firstOrNull { it.date == today }?.weekday,
            weekLabel = week?.week?.let { "第${it}周" }.orEmpty(),
        )
    }

    private data class Entry(val start: Int, val end: Int, val course: WeekCourse)

    private fun dayBlocks(entries: List<Entry>): List<WeekCourseBlock> {
        val runs = mutableListOf<Entry>()
        for (entry in entries.sortedBy { it.start }) {
            val previous = runs.indexOfLast { it.end + 1 == entry.start && sameCourse(it.course, entry.course) }
            if (previous < 0) {
                runs.add(entry)
            } else {
                val first = runs[previous]
                runs[previous] = first.copy(end = entry.end, course = mergeCourse(first.course, entry.course))
            }
        }
        return buildList {
            var index = 0
            val priority = compareBy<WeekCourse> {
                when (it.kind) {
                    WidgetItemKind.EXAM -> 0
                    WidgetItemKind.COURSE -> 1
                    WidgetItemKind.SCHEDULE -> 2
                }
            }.thenBy { if (it.kind == WidgetItemKind.COURSE) 0L else it.start }
                .thenBy { normalizedName(it.name) }.thenBy { it.start }
            while (index < runs.size) {
                val first = runs[index++]
                var end = first.end
                val group = mutableListOf(first.course)
                while (index < runs.size && runs[index].start <= end) {
                    val next = runs[index++]
                    end = max(end, next.end)
                    group.add(next.course)
                }
                add(WeekCourseBlock(first.start, end, group.sortedWith(priority)))
            }
        }
    }

    private fun normalizedName(name: String): String = name.trim().replace('(', '（').replace(')', '）')

    private fun sameCourse(a: WeekCourse, b: WeekCourse): Boolean =
        a.kind == WidgetItemKind.COURSE && b.kind == WidgetItemKind.COURSE &&
            a.id == b.id && normalizedName(a.name) == normalizedName(b.name) &&
            a.lightColor == b.lightColor && a.darkColor == b.darkColor &&
            (a.id.isNotEmpty() || (a.location == b.location && a.teacher == b.teacher))

    private fun mergeCourse(a: WeekCourse, b: WeekCourse): WeekCourse = a.copy(
        location = (a.location.split(" / ") + b.location.split(" / "))
            .map { it.trim() }.filter { it.isNotEmpty() }.distinct().joinToString(" / "),
        teacher = (a.teacher.lines() + b.teacher.lines()).filter { it.isNotBlank() }.distinct().joinToString("\n"),
        endNode = b.endNode,
        end = b.end,
        weekTag = a.weekTag.takeIf { it == b.weekTag }.orEmpty(),
    )

    /** 普通课兼容旧数据；考试和日程没有节次时只在表头提示，不猜测。 */
    fun nodeRange(course: WeekCourse, periods: List<WeekPeriod>): IntRange? {
        if (course.startNode > 0) {
            val start = course.startNode
            return start..max(start, course.endNode)
        }
        if (course.kind != WidgetItemKind.COURSE) return null
        val sorted = periods.sortedBy { it.node }
        if (sorted.isEmpty()) return 1..1
        val startMinute = minutesOfDay(course.start)
        val endMinute = minutesOfDay(course.end)
        val containing = sorted.firstOrNull {
            it.startMinutes <= startMinute && it.endMinutes > startMinute
        }
        val first = containing
            ?: sorted.firstOrNull { it.startMinutes >= startMinute }
            ?: sorted.last()
        val last = sorted.lastOrNull { it.startMinutes < endMinute } ?: first
        return first.node..max(first.node, last.node)
    }
}
