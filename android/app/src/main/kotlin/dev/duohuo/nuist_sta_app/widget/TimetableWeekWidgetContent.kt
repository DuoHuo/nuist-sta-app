package dev.duohuo.nuist_sta_app.widget

import android.app.PendingIntent
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import androidx.core.graphics.ColorUtils
import dev.duohuo.nuist_sta_app.R
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/** 完整渲染预装两周内容；翻周只调用 applyWeekSelection，不能经过这里。 */
internal class TimetableWeekWidgetContent(
    private val context: Context,
    size: SizeF,
    private val snapshot: WeekSnapshot,
    private val current: WeekPlan,
    private val next: WeekPlan?,
) {
    private val density = context.resources.displayMetrics.density
    private val geometry = current.geometry
    private val pixels = WeekPixels(size, density, current)
    private val prefs = snapshot.preferences
    private val componentOpacity = prefs.widgetOpacity / 100f
    private val componentAlpha = (255 * componentOpacity).roundToInt()
    private val palette = WeekPalette
    private val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val textSizes = context.weekTextSizesForWidth(
        referenceWidth = geometry.fontReferenceWidth(density) - geometry.cellPadding * 2,
        factor = prefs.fontScale,
        minSize = geometry.minimumTextSize,
        referenceText = if (geometry.compactText) "课课课课" else "课课课",
    )

    fun build(open: PendingIntent, settings: PendingIntent, flip: PendingIntent): RemoteViews =
        views(R.layout.widget_timetable_week).apply {
            shape(R.id.wg_week_background, R.drawable.wg_week_bg, palette.surface)
            // 用空容器的 padding 定尺寸，避免依赖 Android 12 才有的 setViewLayoutHeight。
            setViewPadding(R.id.wg_week_header_size, 0, 0, 0, pixels.headerHeight)
            setViewPadding(R.id.wg_week_weekday_size, 0, 0, 0, pixels.weekdayHeight)
            styleHeader(next != null)
            setOnClickPendingIntent(R.id.wg_week_open, open)
            setContentDescription(R.id.wg_week_open, if (snapshot.state == "loadFailed" && snapshot.displayWeek() != null) "更新失败，请打开课表刷新" else "打开课表")

            shape(R.id.wg_week_settings, R.drawable.wg_week_settings, palette.label)
            setContentDescription(R.id.wg_week_settings, context.getString(R.string.wg_week_open_settings))
            visible(R.id.wg_week_settings, true)
            setOnClickPendingIntent(R.id.wg_week_settings, settings)

            visible(R.id.wg_week_flip, next != null)
            tint(R.id.wg_week_flip, palette.label)
            setInt(R.id.wg_week_flip, "setImageAlpha", componentAlpha)
            setOnClickPendingIntent(R.id.wg_week_flip, flip)
            clearWeekContent()
            val hasWeek = snapshot.displayWeek() != null
            val showGrid = hasWeek && prefs.showGridLines && current.rows.isNotEmpty()
            // 完整刷新替换旧网格；翻周仍不碰网格。
            removeAllViews(R.id.wg_week_grid_layer)
            visible(R.id.wg_week_grid_layer, showGrid)
            visible(R.id.wg_week_empty, !hasWeek)
            if (!hasWeek) {
                addWeek(R.id.wg_week_current_days, R.id.wg_week_current, current)
                addEmptyState()
            } else {
                if (showGrid) addGrid()
                addPeriods()
                addWeek(R.id.wg_week_current_days, R.id.wg_week_current, current)
                if (next != null) addWeek(R.id.wg_week_next_days, R.id.wg_week_next, next)
            }
        }

    private fun RemoteViews.styleHeader(canFlip: Boolean) {
        val title = context.getString(R.string.wg_week_label)
        val nextTitle = context.getString(R.string.wg_week_next_label)
        val titles = if (canFlip) listOf(title, nextTitle) else listOf(title)
        val numberLabels = listOf(current.weekLabel, next?.weekLabel.orEmpty()).filter { it.isNotEmpty() }
        // 跟 XML 的标题内距和按钮宽度一致，尺寸预算扣掉它们后再按像素测字。
        val textWidth = pixels.width - pixels.dp(18f) - pixels.dp(8f) - pixels.dp(4f) -
            pixels.dp(44f) * (if (canFlip) 2 else 1)
        // 与 XML 的 14dp 留白预算一致；视觉平移不改变可用于测字的高度。
        val textHeight = pixels.headerHeight - pixels.dp(14f) - 2 * pixels.dp(3f)
        val numberSize = numberLabels.minOfOrNull { label ->
            context.fitWeekAxisFonts(label, 11f, "", 0f, textWidth / 2, textHeight).first
        } ?: 11f
        val numberPaint = context.weekTextPaint(numberSize)
        val numberWidth = ceil(numberLabels.maxOfOrNull { numberPaint.measureText(it) } ?: 0f).toInt()
        val titleSize = titles.minOf { label ->
            context.fitWeekAxisFonts(label, 16f, "", 0f, textWidth - numberWidth, textHeight, primaryMedium = true).first
        }
        textColor(R.id.wg_week_title, palette.heading)
        textSize(R.id.wg_week_title, titleSize)
        textColor(R.id.wg_week_number, palette.weekNumber)
        textSize(R.id.wg_week_number, numberSize)
    }

    private fun RemoteViews.clearWeekContent() {
        // 缩放时宿主可重应用旧根布局；先移除动态列，不复用列内已挂载的节次。
        for (container in listOf(
            R.id.wg_week_current_days, R.id.wg_week_next_days, R.id.wg_week_current,
            R.id.wg_week_next, R.id.wg_week_periods,
        )) {
            removeAllViews(container)
        }
    }

    private fun RemoteViews.addGrid() {
        setViewPadding(R.id.wg_week_grid_layer, pixels.periodWidth, 0, 0, 0)
        addView(R.id.wg_week_grid_layer, views(R.layout.widget_timetable_week_grid).apply {
            repeat(current.weekdays.size) {
                addView(R.id.wg_week_grid_columns, views(R.layout.widget_timetable_week_grid_column).apply {
                    gridLineColor(R.id.wg_week_grid_column_line)
                })
            }
            repeat(current.rows.size) {
                val line = views(R.layout.widget_timetable_week_grid_row).apply {
                    gridLineColor(R.id.wg_week_grid_row_line)
                }
                addView(R.id.wg_week_grid_rows, slot(1, line))
            }
            gridLineColor(R.id.wg_week_grid_bottom_line)
        })
    }

    private fun RemoteViews.gridLineColor(id: Int) {
        val light = palette.divider.light.withOpacity(componentOpacity)
        val dark = palette.divider.dark.withOpacity(componentOpacity)
        if (Build.VERSION.SDK_INT >= 31) setColorInt(id, "setBackgroundColor", light, dark)
        else setInt(id, "setBackgroundColor", if (night) dark else light)
    }

    private fun RemoteViews.addWeek(daysId: Int, bodyId: Int, plan: WeekPlan) {
        setViewPadding(bodyId, pixels.periodWidth, 0, 0, 0)
        if (pixels.periodWidth > 0) {
            val month = plan.month?.let { "${it}月" }.orEmpty()
            val monthLabel = axis(month, 9f, palette.hint, pixels.periodWidth, pixels.weekdayHeight)
            addView(daysId, column(monthLabel, period = true))
        }
        for ((dayIndex, weekday) in plan.weekdays.withIndex()) {
            val today = plan.todayWeekday == weekday
            val events = plan.unplaced[weekday].orEmpty()
            val label = weekWeekdayLabels[weekday - 1]
            val date = plan.dates[weekday].orEmpty()
            val dayWidth = pixels.x(dayIndex + 1) - pixels.x(dayIndex)
            val header = axis(
                label = label,
                labelSp = prefs.headerTextSize,
                color = if (today) palette.accent else palette.label,
                width = dayWidth,
                height = pixels.weekdayHeight - if (events.isEmpty()) 0 else pixels.dp(4f) + pixels.dp(1f),
                detail = date,
                detailSp = 9f,
                detailColor = if (today) palette.accent else palette.hint,
            ).apply {
                if (today) {
                    visible(R.id.wg_week_axis_today, true)
                    shape(R.id.wg_week_axis_today, R.drawable.wg_week_today, palette.today)
                }
                if (events.isNotEmpty()) {
                    visible(R.id.wg_week_axis_dot, true)
                    shape(R.id.wg_week_axis_dot, R.drawable.wg_week_cell, palette.eventAccent(events.first()))
                }
                setContentDescription(R.id.wg_week_axis, buildString {
                    append("周$label")
                    if (date.isNotEmpty()) append("，${date}日")
                    if (today) append("，今天")
                    if (events.isNotEmpty()) append("，不在节次内：").append(events.joinToString("、") { it.displayName })
                })
            }
            addView(daysId, column(header))
            val day = column().apply {
                var end = 0
                val margin = pixels.dp(geometry.cellMargin)
                for (block in plan.blocks[weekday].orEmpty()) {
                    val start = block.startNode - 1
                    if (start > end) addView(R.id.wg_week_column, slot(start - end))
                    end = block.endNode
                    val span = end - start
                    val width = dayWidth - margin * 2
                    val textBudget = pixels.dp(plan.geometry.rowHeight * span) - margin * 2
                    val child = if (width > 0 && textBudget > 0) courseCell(width, textBudget, weekday, block) else null
                    addView(R.id.wg_week_column, slot(span, child, margin))
                }
                val tail = plan.rows.size - end
                if (tail > 0) addView(R.id.wg_week_column, slot(tail))
            }
            addView(bodyId, day)
        }
    }

    private fun RemoteViews.addPeriods() {
        if (pixels.periodWidth == 0) return
        val periods = column(period = true).apply {
            for (row in current.rows) {
                val times = row.period?.let { "${it.start}\n${it.end}" }.orEmpty()
                val label = axis(
                    label = row.node.toString(),
                    labelSp = 12f,
                    color = palette.heading,
                    width = pixels.periodWidth,
                    height = pixels.dp(geometry.rowHeight),
                    detail = times,
                    detailSp = 9f,
                    detailColor = palette.hint,
                )
                addView(R.id.wg_week_column, slot(1, label))
            }
        }
        addView(R.id.wg_week_periods, periods)
    }

    private fun column(header: RemoteViews? = null, period: Boolean = false) =
        views(if (period) R.layout.widget_timetable_week_period_column else R.layout.widget_timetable_week_column).apply {
            if (period) setViewPadding(R.id.wg_week_period_size, pixels.periodWidth, 0, 0, 0)
            if (header != null) addView(R.id.wg_week_column, header)
        }

    private fun axis(
        label: String,
        labelSp: Float,
        color: WeekColor,
        width: Int,
        height: Int,
        detail: String = "",
        detailSp: Float = 0f,
        detailColor: WeekColor = color,
    ) = views(R.layout.widget_timetable_week_axis).apply {
        val (primarySize, secondarySize) = context.fitWeekAxisFonts(
            label, labelSp, detail, detailSp,
            width - 2 * pixels.dp(2f), height - 2 * pixels.dp(2f),
            primaryMedium = true,
        )
        text(R.id.wg_week_axis_label, label, primarySize, color)
        if (detail.isNotEmpty()) text(R.id.wg_week_axis_detail, detail, secondarySize, detailColor)
    }

    private fun courseCell(width: Int, height: Int, weekday: Int, block: WeekCourseBlock): RemoteViews {
        val course = block.courses.first()
        val colors = palette.cell(course, prefs.opacity)
        val inset = pixels.dp(geometry.cellPadding)
        val textWidth = (width - inset * 2).coerceAtLeast(1)
        val textHeight = ((height - inset * 2) / density).coerceAtLeast(1f)
        val location = context.weekLocationForWidth(course.location, textWidth, textSizes.minimum, geometry.compactText)
        val name = course.name.ifEmpty { course.kind.label }.replace('(', '（').replace(')', '）')
        val badge = when {
            block.courses.size > 1 -> "${block.courses.size} " + if (block.courses.all { it.kind == WidgetItemKind.COURSE }) "门" else "项"
            course.kind != WidgetItemKind.COURSE -> course.kind.label
            else -> course.weekTag.trim()
        }
        val plan = context.planWeekText(name, location, course.teacher, badge, textWidth, textHeight, geometry.cellPadding, textSizes, geometry.compactText)
        return views(R.layout.widget_timetable_week_course_text).apply {
            shape(R.id.wg_week_course_background, R.drawable.wg_week_cell, colors.bg, opacity = 1f)
            setContentDescription(R.id.wg_week_course_cell, (listOf("周" + weekWeekdayLabels[weekday - 1]) + block.courses.map {
                listOf(it.displayName, it.location, it.teacher).filter(String::isNotBlank).joinToString("，")
            }).joinToString("；"))
            setViewPadding(R.id.wg_week_course_text, inset, inset, inset, inset + pixels.dp(plan.badgeReserve))
            text(R.id.wg_week_course_name, plan.name, plan.nameSize, colors.fg, opacity = 1f)
            setInt(R.id.wg_week_course_name, "setMaxLines", plan.nameLines)
            text(R.id.wg_week_course_location, location, plan.subSize, colors.fg, opacity = 1f)
            text(R.id.wg_week_course_teacher, if (plan.showTeacher) course.teacher else "", plan.subSize, colors.fg, opacity = 1f)
            setViewPadding(R.id.wg_week_course_teacher, 0, plan.teacherGapPx, 0, 0)
            if (plan.badgeReserve > 0f) {
                visible(R.id.wg_week_course_badge, true)
                shape(R.id.wg_week_course_badge_border, R.drawable.wg_week_badge, colors.fg, opacity = 1f)
                text(R.id.wg_week_course_badge_label, badge, WEEK_BADGE_SIZE, colors.fg, opacity = 1f)
            }
            if (block.courses.size > 1) {
                visible(R.id.wg_week_course_conflict_box, true)
                setViewPadding(R.id.wg_week_course_conflict_box, 0, inset, inset, 0)
                shape(R.id.wg_week_course_conflict, R.drawable.wg_week_cell, colors.fg, opacity = 1f)
            }
        }
    }

    private fun RemoteViews.addEmptyState() {
        val (title, hint) = when {
            snapshot.reason == "jwxtUnbound" -> "课表需要更新" to "打开 App 登录并同步"
            snapshot.reason == "jwxtExpired" -> "教务课表已过期" to "打开 App 同步课表"
            snapshot.reason == "noSchedule" -> "暂无课表" to "打开 App 查看课表"
            snapshot.termStartMissing && !snapshot.hasIndependentLocalData ->
                "请先设置开学日" to "打开 App，在课表设置中设置开学日"
            snapshot.state == "loadFailed" -> "课表加载失败" to "网络异常，请打开课表重试"
            else -> "课表需要更新" to "打开 App 查看课表"
        }
        visible(R.id.wg_week_empty, true)
        text(R.id.wg_week_empty_title, title, 17f, palette.heading)
        text(R.id.wg_week_empty_hint, hint, 12f, palette.label)
    }

    private fun views(layout: Int) = RemoteViews(context.packageName, layout)

    /** 列的总权重固定为可见节数；由 Launcher 给每个块分配真实高度。 */
    private fun slot(span: Int, content: RemoteViews? = null, margin: Int = 0): RemoteViews =
        views(weekSlotLayouts[span - 1]).apply {
            if (content != null) {
                if (margin != 0) setViewPadding(R.id.wg_week_slot_content, margin, margin, margin, margin)
                addView(R.id.wg_week_slot_content, content)
            }
        }

    private fun RemoteViews.textColor(id: Int, color: WeekColor, opacity: Float = componentOpacity) {
        val light = color.light.withOpacity(opacity)
        val dark = color.dark.withOpacity(opacity)
        if (Build.VERSION.SDK_INT >= 31) setColorInt(id, "setTextColor", light, dark)
        else setTextColor(id, if (night) dark else light)
    }

    private fun RemoteViews.tint(id: Int, color: WeekColor) {
        val light = ColorUtils.setAlphaComponent(color.light, 255)
        val dark = ColorUtils.setAlphaComponent(color.dark, 255)
        if (Build.VERSION.SDK_INT >= 31) setColorInt(id, "setColorFilter", light, dark)
        else setInt(id, "setColorFilter", if (night) dark else light)
    }

    private fun RemoteViews.text(id: Int, value: String, size: Float, color: WeekColor, opacity: Float = componentOpacity) {
        visible(id, value.isNotEmpty())
        if (value.isEmpty()) return
        setTextViewText(id, value)
        textSize(id, size)
        textColor(id, color, opacity)
    }

    private fun RemoteViews.shape(id: Int, drawable: Int, tint: WeekColor, opacity: Float = componentOpacity) {
        setImageViewResource(id, drawable)
        tint(id, tint)
        val lightAlpha = (Color.alpha(tint.light) * opacity).roundToInt()
        val darkAlpha = (Color.alpha(tint.dark) * opacity).roundToInt()
        if (Build.VERSION.SDK_INT >= 31 && lightAlpha != darkAlpha) {
            setColorInt(id, "setImageAlpha", lightAlpha, darkAlpha)
        } else {
            setInt(id, "setImageAlpha", if (night) darkAlpha else lightAlpha)
        }
    }
}

/** 局部补丁只改标题、箭头和周容器可见性，不写入网格、课程或点击操作。 */
internal fun RemoteViews.applyWeekSelection(context: Context, showNext: Boolean, weekLabel: String) {
    setViewVisibility(if (showNext) R.id.wg_week_current else R.id.wg_week_next, View.GONE)
    setViewVisibility(if (showNext) R.id.wg_week_current_days else R.id.wg_week_next_days, View.GONE)
    setViewVisibility(if (showNext) R.id.wg_week_next else R.id.wg_week_current, View.VISIBLE)
    setViewVisibility(if (showNext) R.id.wg_week_next_days else R.id.wg_week_current_days, View.VISIBLE)
    setTextViewText(R.id.wg_week_title, context.getString(if (showNext) R.string.wg_week_next_label else R.string.wg_week_label))
    setTextViewText(R.id.wg_week_number, weekLabel)
    setImageViewResource(R.id.wg_week_flip, if (showNext) R.drawable.wg_week_previous else R.drawable.wg_week_next)
    setContentDescription(R.id.wg_week_flip, context.getString(if (showNext) R.string.wg_week_switch_current else R.string.wg_week_switch_next))
}

// 框架比例和测字使用同一份宿主尺寸，表体的实际行列边界仍由 XML 权重决定。
private class WeekPixels(size: SizeF, private val density: Float, private val plan: WeekPlan) {
    val width = dp(size.width)
    val periodWidth = dp(plan.geometry.periodWidth)
    val headerHeight = dp(plan.geometry.headerHeight)
    val weekdayHeight = dp(plan.geometry.weekdayHeight)

    fun dp(size: Float) = (size * density).roundToInt()
    fun x(column: Int) = periodWidth + ((width - periodWidth) * column / plan.weekdays.size.toFloat()).roundToInt()
}

// RemoteViews 不能动态设置 layout_weight。模板的权重对应 1 至 11 节。
private val weekSlotLayouts = intArrayOf(
    R.layout.widget_timetable_week_slot,
    R.layout.widget_timetable_week_slot_2,
    R.layout.widget_timetable_week_slot_3,
    R.layout.widget_timetable_week_slot_4,
    R.layout.widget_timetable_week_slot_5,
    R.layout.widget_timetable_week_slot_6,
    R.layout.widget_timetable_week_slot_7,
    R.layout.widget_timetable_week_slot_8,
    R.layout.widget_timetable_week_slot_9,
    R.layout.widget_timetable_week_slot_10,
    R.layout.widget_timetable_week_slot_11,
)

private fun RemoteViews.visible(id: Int, visible: Boolean) = setViewVisibility(id, if (visible) View.VISIBLE else View.GONE)
private fun RemoteViews.textSize(id: Int, size: Float) = setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, size)
private data class WeekColor(val light: Int, val dark: Int) {
    constructor(light: Long, dark: Long) : this(light.toInt(), dark.toInt())

    fun atNight(night: Boolean) = if (night) dark else light
}

private val weekWeekdayLabels = listOf("一", "二", "三", "四", "五", "六", "日")
private const val MEDIUM_FONT = "sans-serif-medium"
private const val REGULAR_FONT = "sans-serif"

private fun Context.spPx(size: Float): Float =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, size, resources.displayMetrics)

private const val CELL_NAME_SIZE = 11f
private const val CELL_SUB_SIZE = 10f
private const val WEEK_BADGE_SIZE = 8f
private const val TEXT_EPSILON = 0.01f

private data class WeekTextSizes(val name: Float, val sub: Float, val step: Float, val minimum: Float)

private fun Context.weekTextPaint(size: Float, medium: Boolean = false) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
    typeface = Typeface.create(if (medium) MEDIUM_FONT else REGULAR_FONT, Typeface.NORMAL)
    textSize = spPx(size)
}

private fun weekTextLayout(text: String, paint: TextPaint, width: Int): StaticLayout =
    StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
        .setIncludePad(false)
        .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
        .setTextDirection(TextDirectionHeuristics.FIRSTSTRONG_LTR)
        .apply { if (Build.VERSION.SDK_INT >= 28) setUseLineSpacingFromFallbacks(true) }
        .build()

/** 先以当前系统的 sp → px 转换测量，再按容器的物理像素预算缩小。 */
private fun Context.fitWeekAxisFonts(
    label: String,
    labelSp: Float,
    detail: String,
    detailSp: Float,
    widthPx: Int,
    heightPx: Int,
    primaryMedium: Boolean = false,
): Pair<Float, Float> {
    fun fits(scale: Float): Boolean {
        var measuredWidth = 0
        var measuredHeight = 0
        fun measure(text: String, size: Float, medium: Boolean = false) {
            if (text.isEmpty()) return
            val paint = weekTextPaint(size * scale, medium)
            val lineWidth = ceil(text.lineSequence().maxOf { paint.measureText(it) }).toInt()
            measuredWidth = max(measuredWidth, lineWidth)
            measuredHeight += weekTextLayout(text, paint, lineWidth + 1).height
        }
        measure(label, labelSp, primaryMedium)
        measure(detail, detailSp)
        return measuredWidth <= widthPx && measuredHeight <= heightPx
    }
    if (fits(1f)) return labelSp to detailSp
    var low = 0f
    var high = 1f
    // Android 14 起系统字号缩放可能是非线性的，不能直接拿 px 比例换算 sp。
    repeat(8) {
        val mid = (low + high) / 2f
        if (fits(mid)) low = mid else high = mid
    }
    return labelSp * low to detailSp * low
}

/** 对应 TimetableTheme.cellTextSizesForWidth：七列格宽量「课课课」，副文字等比缩小。 */
private fun Context.weekTextSizesForWidth(
    referenceWidth: Float,
    factor: Float,
    minSize: Float,
    referenceText: String = "课课课",
): WeekTextSizes {
    val density = resources.displayMetrics.density
    val scale = (spPx(1f) / density).takeIf { it > 0f } ?: 1f
    val step = 1f / scale
    val minimum = ceil(minSize / scale)
    val initial = max(minimum, (CELL_NAME_SIZE * factor).roundToInt().toFloat())
    val widthPx = referenceWidth.coerceAtLeast(1f) * density
    var i = 0
    while (true) {
        val size = max(minimum, initial - i++ * step).roundToInt().toFloat()
        if (size <= minimum || weekTextPaint(size, medium = true).measureText(referenceText) <= widthPx + TEXT_EPSILON * density) {
            val sub = (CELL_SUB_SIZE * factor * size / initial).roundToInt().toFloat()
            return WeekTextSizes(size, max(minimum, sub), step, minimum)
        }
    }
}

private data class WeekTextPlan(
    val name: String,
    val nameSize: Float,
    val subSize: Float,
    val nameLines: Int,
    val showTeacher: Boolean,
    val teacherGapPx: Int,
    val badgeReserve: Float,
)

/** 先保证课名和完整地点；教师只有在所有行都能显示时才保留。 */
private fun Context.planWeekText(
    name: String,
    location: String,
    teacher: String,
    badge: String,
    widthPx: Int,
    height: Float,
    inset: Float,
    sizes: WeekTextSizes,
    compact: Boolean,
): WeekTextPlan {
    val density = resources.displayMetrics.density
    val eps = TEXT_EPSILON * density
    val badgePaint = weekTextPaint(WEEK_BADGE_SIZE)
    val badgeLineWidth = ceil(badgePaint.measureText(badge)).toInt() + 1
    val measuredBadgeHeight = weekTextLayout(badge, badgePaint, badgeLineWidth).height / density + 2f
    val minNameHeight = weekTextLayout("课", weekTextPaint(sizes.minimum, medium = true), widthPx).height / density
    val minLocationHeight = if (location.isNotEmpty()) {
        weekTextLayout(location, weekTextPaint(sizes.minimum, medium = true), widthPx).height / density
    } else {
        0f
    }
    val reserve = max(14f, measuredBadgeHeight + 2f)
    // 标签在列宽内单行省略，只有课名和地点的垂直空间不足才隐藏。
    val showBadge = badge.isNotEmpty() && widthPx / density + 2 * inset > 12f &&
        reserve + minNameHeight + minLocationHeight <= height
    val badgeReserve = if (showBadge) reserve else 0f
    val room = (height - badgeReserve) * density
    var showTeacher = teacher.isNotEmpty()
    var step = 0
    while (true) {
        val nameSize = max(sizes.minimum, sizes.name - step * sizes.step).roundToInt().toFloat()
        val subSize = max(sizes.minimum, sizes.sub - step * sizes.step).roundToInt().toFloat()
        val namePaint = weekTextPaint(nameSize, medium = true)
        val subPaint = weekTextPaint(subSize)
        val laidOutName = layoutWeekCourseName(name, namePaint, widthPx)
        val nameLayout = weekTextLayout(laidOutName, namePaint, widthPx)
        val locationHeight = if (location.isEmpty()) 0 else
            weekTextLayout(location, weekTextPaint(subSize, medium = true), widthPx).height
        val teacherHeight = if (showTeacher) weekTextLayout(teacher, subPaint, widthPx).height else 0
        val teacherGap = when {
            !showTeacher -> 0
            compact -> (2f * density).roundToInt()
            else -> weekTextLayout("课", subPaint, widthPx).height
        }
        // Launcher 的 TextView 测量可能多取几个像素；不能把老师最后一行留在裁切边缘。
        val teacherClearance = if (showTeacher) density else 0f
        val nameBudget = room - locationHeight - teacherHeight - teacherGap - teacherClearance + eps
        val displayLines = (nameLayout.lineCount downTo 1).firstOrNull { nameLayout.getLineTop(it) <= nameBudget }
        if (displayLines != null) {
            return WeekTextPlan(laidOutName, nameSize, subSize, displayLines, showTeacher, teacherGap, badgeReserve)
        }
        if (nameSize <= sizes.minimum && subSize <= sizes.minimum) {
            if (!showTeacher) {
                return WeekTextPlan(laidOutName, nameSize, subSize, 1, false, 0, badgeReserve)
            }
            // 取消教师后回到正常字号再排，地点从不截行，也不白留教师的间距。
            showTeacher = false
            step = 0
        } else {
            step++
        }
    }
}

private val weekTrailingParen = Regex("^(.*\\S)(（[^（）]*）)$")
private val weekTrailingRomanParen = Regex("^(.*\\S)([\u2160-\u217F]+)(（[^（）]*）)$")

private fun layoutWeekCourseName(name: String, paint: TextPaint, width: Int): String {
    val parenMatch = weekTrailingParen.matchEntire(name) ?: return name
    val layout = weekTextLayout(name, paint, width)
    fun fits(text: String) = paint.measureText(text) <= width + TEXT_EPSILON
    fun tailOnOneLine(start: Int) = layout.getLineForOffset(start) == layout.getLineForOffset(name.lastIndex)
    val roman = weekTrailingRomanParen.matchEntire(name)
    if (roman != null) {
        val (head, numeral, parens) = roman.destructured
        if (fits(numeral + parens)) return if (tailOnOneLine(head.length)) name else "$head\n$numeral$parens"
    }
    val (head, parens) = parenMatch.destructured
    if (tailOnOneLine(head.length)) return name
    val lastStart = head.offsetByCodePoints(head.length, -1)
    if (roman == null && lastStart > 0 && fits(head.substring(lastStart) + parens)) {
        return head.substring(0, lastStart) + "\n" + head.substring(lastStart) + parens
    }
    return if (fits(parens)) "$head\n$parens" else name
}

/** 与 cellLocationText 一样，允许教室号里的字母、数字和符号参与正常断行。 */
private fun weekLocationText(location: String, showMarker: Boolean = true): String {
    if (location.isEmpty()) return ""
    fun breakable(code: Int) = code != 0x20 && code != 0x09 && code != 0x0A && code != 0x200B &&
        code !in 0x2E80..0x9FFF && code !in 0xF900..0xFAFF && code !in 0xFF00..0xFFEF && code !in 0x20000..0x3FFFF
    return buildString {
        if (showMarker) append('@')
        var previous = if (showMarker) '@'.code else 0x20
        var offset = 0
        while (offset < location.length) {
            val code = location.codePointAt(offset)
            if (breakable(previous) && breakable(code)) append('\u200B')
            appendCodePoint(code)
            previous = code
            offset += Character.charCount(code)
        }
    }
}

/** 窄七列只在 @ 会多占一行时去掉标记，地点原文始终保留。 */
private fun Context.weekLocationForWidth(location: String, widthPx: Int, minSize: Float, compact: Boolean): String {
    val withMarker = weekLocationText(location)
    if (!compact || location.isEmpty()) return withMarker
    val withoutMarker = weekLocationText(location, showMarker = false)
    val paint = weekTextPaint(minSize, medium = true)
    return if (weekTextLayout(withMarker, paint, widthPx).lineCount > weekTextLayout(withoutMarker, paint, widthPx).lineCount) {
        withoutMarker
    } else {
        withMarker
    }
}

private fun Int.withOpacity(opacity: Float) = ColorUtils.setAlphaComponent(this, (Color.alpha(this) * opacity).roundToInt())

private data class WeekCellColors(val bg: WeekColor, val fg: WeekColor)

/** 明暗在 Launcher 应用 RemoteViews 时解析，应用进程退出也能跟随宿主。 */
private object WeekPalette {
    val surface = WeekColor(0xFFFFFFFF, 0xFF1C1D21)
    private val page = WeekColor(0xFFF5F6F8, 0xFF121316)
    val heading = WeekColor(0xFF171A1F, 0xFFF2F3F5)
    val label = WeekColor(0xFF4A4F66, 0xFFC8CBD2)
    val weekNumber = WeekColor(0xFF5F6675, 0xFFAAB1C1)
    val hint = WeekColor(0xFF9AA0B4, 0xFF8A8F99)
    // 与 Dart 设置预览的网格色对齐。
    val divider = WeekColor(0xFFD9DDE3, 0xFF454851)
    val accent = WeekColor(0xFF0082EF, 0xFF4DA3F5)
    val today = WeekColor(0x1F0082EF, 0x2E4DA3F5)

    fun eventAccent(course: WeekCourse): WeekColor = if (course.kind == WidgetItemKind.EXAM) {
        WeekColor(course.lightColor, course.lightColor)
    } else {
        WeekColor(course.lightTextColor.takeUnless { it == 0 } ?: accent.light,
            course.darkTextColor.takeUnless { it == 0 } ?: accent.dark)
    }

    fun cell(course: WeekCourse, opacity: Int): WeekCellColors {
        // 新 payload 已按 App 公式求值；旧缓存仍按同样的底色插值方式渲染。
        fun colors(night: Boolean): Pair<Int, Int> {
            val base = (if (night) course.darkColor else course.lightColor).takeUnless { it == 0 } ?: accent.atNight(night)
            val bg = (if (night) course.darkCellColor else course.lightCellColor).takeUnless { it == 0 }
                ?: if (opacity == 100 || course.kind == WidgetItemKind.EXAM) base else ColorUtils.blendARGB(page.atNight(night), base, opacity / 100f)
            val fg = (if (night) course.darkTextColor else course.lightTextColor).takeUnless { it == 0 }
                ?: if (ColorUtils.calculateLuminance(bg) >= 0.17913) Color.BLACK else Color.WHITE
            return bg to fg
        }
        val (lightBg, lightFg) = colors(false)
        val (darkBg, darkFg) = colors(true)
        return WeekCellColors(WeekColor(lightBg, darkBg), WeekColor(lightFg, darkFg))
    }
}
