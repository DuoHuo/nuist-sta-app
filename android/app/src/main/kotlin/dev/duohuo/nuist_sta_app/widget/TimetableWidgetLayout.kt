package dev.duohuo.nuist_sta_app.widget

import android.content.Context
import android.graphics.Typeface
import android.util.TypedValue
import android.view.View
import android.widget.TextView
import kotlin.math.ceil

/** 一块课程的显示内容和自然高度，不保存任何桌面坐标或方向猜测。 */
internal data class CourseBlock(
    val course: WidgetCourse,
    val nameSize: Float,
    val nameLines: Int,
    val detail: String,
    val time: String,
    val timeSize: Float,
    val clockLabel: String,
    val clock: String,
    val clockWidth: Float,
    val clockSize: Float,
    val contentHeight: Float,
    val height: Float,
    val compact: Boolean = false,
)

/** 通用桌面的布局预算；OriginOS 与荣耀由宿主实际测量，不使用此预估方案。 */
internal data class WidgetLayout(
    val inset: Float,
    val headerHeight: Float,
    val blocks: List<CourseBlock>,
    val tomorrow: CourseBlock?,
    val lastHeight: Float,
    val showEmptyDetail: Boolean,
    val showEmptyButton: Boolean,
    val statusLines: Int,
    val showStatus: Boolean,
    val tomorrowHeight: Float,
)

/** 按 Android 实际字体与字号计算文字预算；只精简内容，不缩放或偏移宿主视图。 */
internal class WidgetTextMeasure(private val context: Context) {
    private val density = context.resources.displayMetrics.density

    private fun text(value: String, sp: Float, medium: Boolean) = TextView(context).apply {
        text = value
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        typeface = Typeface.create(if (medium) "sans-serif-medium" else "sans-serif", Typeface.NORMAL)
        // Glance 的标准 TextView 保留系统字体边界，测量必须与真实远程视图一致。
        includeFontPadding = true
    }

    fun width(value: String, sp: Float, medium: Boolean = false): Float =
        text(value, sp, medium).apply {
            measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        }.measuredWidth / density

    fun height(value: String, sp: Float, availableWidth: Float, lines: Int = 1, medium: Boolean = false): Float =
        text(value, sp, medium).apply {
            maxLines = lines
            measure(View.MeasureSpec.makeMeasureSpec(ceil(availableWidth.coerceAtLeast(1f) * density).toInt(),
                View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        }.measuredHeight / density

    fun firstFitting(values: List<String>, sp: Float, width: Float): String =
        values.firstOrNull { width(it, sp) <= width } ?: values.last()
}

/** 在卡片内按文字实际高度分配内容，保留大字号下的防溢出处理。 */
internal object TimetableWidgetLayout {
    fun plan(context: Context, data: WidgetSnapshot, square: Boolean, width: Float, height: Float): WidgetLayout {
        val measure = WidgetTextMeasure(context)
        val inset = if (width < 140 || height < 140) 8f else 10f
        val innerWidth = (width - inset * 2).coerceAtLeast(1f)
        var header = maxOf(16f, measure.height("今日课表", if (square) 11f else 12f, innerWidth)) + 4f
        var body = (height - inset * 2 - header).coerceAtLeast(1f)
        fun hideHeader() {
            header = 0f
            body = (height - inset * 2).coerceAtLeast(1f)
        }
        val pending = data.pending
        var details = true
        var multiline = true
        var count = minOf(pending.size, if (square) 2 else data.preferences.courseCount)
        fun blocks() = pending.take(count).mapIndexed { index, course ->
            block(measure, course, data, square, index, innerWidth, details, multiline)
        }
        var blocks = if (data.usable) blocks() else emptyList()
        fun needed(): Float {
            val courses = if (!square && blocks.size > 1) {
                maxOf(blocks[0].height, blocks[1].height) * 2 + (blocks.getOrNull(2)?.height ?: 0f)
            } else blocks.sumOf { it.height.toDouble() }.toFloat()
            return courses + (blocks.size - 1).coerceAtLeast(0) * 5
        }
        if (needed() > body) { multiline = false; blocks = blocks() }
        if (needed() > body) { details = false; blocks = blocks() }
        while (needed() > body && count > 1) { count--; blocks = blocks() }
        if (needed() > body) {
            hideHeader()
        }
        // “最后一节”和非课程的“最后一项”等宽，统一预留一次文字高度。
        val lastHeight = measure.height("今天最后一项", 10f, innerWidth) + 4f
        val tomorrow = if (data.usable && pending.isEmpty()) data.tomorrow?.let {
            var result = block(measure, it, data, square, 1, innerWidth, true, false, tomorrow = true)
            if (result.height + measure.height(data.statusTitle, 12f, innerWidth, 2) + 11f > body) {
                result = block(measure, it, data, square, 1, innerWidth, false, false, tomorrow = true)
            }
            result
        } else null
        var statusLines = 2
        var showStatus = true
        val tomorrowHeight = tomorrow?.height ?: maxOf(42f, measure.height("明天没有安排", 12f, innerWidth))
        if (data.usable && pending.isEmpty()) {
            fun statusHeight() = measure.height(data.statusTitle, 12f, innerWidth, statusLines)
            if (statusHeight() + tomorrowHeight + 11f > body) statusLines = 1
            if (statusHeight() + tomorrowHeight + 11f > body) hideHeader()
            // 极小格子配合最大字号时优先保留明日课名与时间，状态仍提供给读屏。
            showStatus = statusHeight() + tomorrowHeight + 11f <= body
        }
        if (!data.usable && measure.height(data.statusTitle, 15f, innerWidth, statusLines, true) > body) {
            hideHeader()
            if (measure.height(data.statusTitle, 15f, innerWidth, statusLines, true) > body) statusLines = 1
        }
        val titleHeight = measure.height(data.statusTitle, 15f, innerWidth, statusLines, true)
        val subHeight = measure.height("网络异常，请打开课表重试", 11f, innerWidth, 3) + 8f
        return WidgetLayout(inset, header, blocks, tomorrow,
            if (pending.size == 1 && needed() + lastHeight <= body) lastHeight else 0f,
            titleHeight + subHeight + 56f <= body,
            titleHeight + 56f <= body, statusLines, showStatus, tomorrowHeight)
    }

    private fun block(
        measure: WidgetTextMeasure, course: WidgetCourse, data: WidgetSnapshot, square: Boolean,
        index: Int, width: Float, details: Boolean, multiline: Boolean, tomorrow: Boolean = false,
    ): CourseBlock {
        val compact = !square && index == 2
        val main = index == 0
        val nameSize = if (square) { if (main) 16f else 12f } else if (compact) 13f else 14f
        val ongoing = main && course.start <= data.now
        val target = if (ongoing) course.end else course.start
        val countdown = main && data.preferences.showCountdown && target - data.now in 1..3_600_000L
        var clock = if (countdown) "${TimetableWidgetUpdates.minutes(data.now, target)} 分钟" else widgetTime(target)
        val clockSize = if (main) 17f else if (compact) 12f else 15f
        var clockWidth = if (square) 0f else maxOf(if (main) 68f else 64f, measure.width(clock, clockSize, true))
        val padding = if (square) 12f else 28f
        if (square || !compact && measure.width(course.timeRange, 10f) > width - padding - clockWidth - 8f) {
            clock = ""
            clockWidth = 0f
        }
        val textWidth = (width - padding - if (clockWidth > 0) clockWidth + 8 else 0f).coerceAtLeast(1f)
        val nameLines = if (multiline && main && measure.width(course.displayName, nameSize, true) > textWidth) 2 else 1
        val fullDetail = listOf(course.location, course.teacher).filter { it.isNotBlank() }.joinToString(" · ")
        val detail = if (details && !compact && (!square || main)) {
            if (measure.width(fullDetail, 11f) <= textWidth) fullDetail else course.location
        } else ""
        val timeSize = if (square) 11f else 10f
        val prefix = "${if (tomorrow) "明天" else "之后"} ${widgetTime(course.start)}"
        val time = when {
            compact -> ""
            square && !main -> measure.firstFitting(listOf(
                listOf(prefix, course.location).filter { it.isNotBlank() }.joinToString(" · "), prefix,
                widgetTime(course.start)), timeSize, textWidth)
            else -> measure.firstFitting(listOf(
                listOf(course.nodes.takeIf { !square && details }.orEmpty(), course.timeRange)
                    .filter { it.isNotBlank() }.joinToString(" · "),
                course.timeRange,
                "${widgetTime(target)} ${if (ongoing) course.endLabel else course.startLabel}",
                widgetTime(target)),
                timeSize, textWidth)
        }
        val textHeight = measure.height(course.displayName, nameSize, textWidth, nameLines, true) +
            (if (detail.isNotEmpty()) 2 + measure.height(detail, 11f, textWidth) else 0f) +
            (if (time.isNotEmpty()) 2 + measure.height(time, timeSize, textWidth) else 0f)
        val clockLabel = if (compact) "" else if (tomorrow) "明天" else if (countdown) {
            "距${if (ongoing) course.endLabel else course.startLabel}"
        } else if (ongoing) course.endLabel else course.startLabel
        val clockHeight = if (clockWidth == 0f) 0f else measure.height(clock, clockSize, clockWidth, medium = true) +
            (if (clockLabel.isNotEmpty()) measure.height(clockLabel, 10f, clockWidth) else 0f)
        val natural = maxOf(textHeight, clockHeight) + if (square || compact) 0 else 4
        return CourseBlock(course, nameSize, nameLines, detail, time, timeSize,
            clockLabel, clock, clockWidth, clockSize, maxOf(textHeight, clockHeight),
            maxOf(natural, if (square && !main) 42f else if (compact) 24f else 0f), compact)
    }
}
