package dev.duohuo.nuist_sta_app.widget

import android.content.Context
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.ColorUtils
import androidx.glance.ColorFilter
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontFamily
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import dev.duohuo.nuist_sta_app.NotifyStore
import dev.duohuo.nuist_sta_app.R
import java.util.Calendar

/** OriginOS 交给宿主测量内容；其他桌面保留原有尺寸预算和卡片边界。 */
@Composable
internal fun TimetableWidgetContent(data: WidgetSnapshot, square: Boolean) {
    val context = LocalContext.current
    val originOs = TimetableWidgetGeometry.isOriginOsHome(context)
    val cacheWarning = if (data.state == "loadFailed" && data.usable) "更新失败，请打开课表刷新" else ""
    // 背景、圆角、点击与缓存告警统一附着在可见卡片上，保持启动动画和读屏范围一致。
    val surface = GlanceModifier.appWidgetBackground()
        .background(ImageProvider(R.drawable.wg_bg)).cornerRadius(20.dp)
        .clickable(actionStartActivity(NotifyStore.launchIntent(context)))
        .then(if (cacheWarning.isNotEmpty()) GlanceModifier.semantics {
            contentDescription = cacheWarning
        } else GlanceModifier)
    if (originOs) {
        // 此分支不读取 LocalSize，也不执行基于上报宽高的文字测量和内容删减。
        OriginOsCard(data, square, surface)
    } else {
        val contentSize = TimetableWidgetGeometry.contentSize(square, LocalSize.current)
        Box(GlanceModifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CompositionLocalProvider(LocalSize provides contentSize) {
                TimetableCard(data, square,
                    GlanceModifier.width(contentSize.width).height(contentSize.height).then(surface))
            }
        }
    }
}

/** 两种占格共用自然高度与剩余空间分配，宽高由桌面的 RemoteViews 容器实际测量。 */
@Composable
private fun OriginOsCard(data: WidgetSnapshot, square: Boolean, surface: GlanceModifier) {
    val context = LocalContext.current
    val open = actionStartActivity(NotifyStore.launchIntent(context))
    val courses = if (data.usable) data.pending.take(if (square) 2 else data.preferences.courseCount)
        else emptyList()
    Column(GlanceModifier.fillMaxSize().then(surface).padding(10.dp)) {
        Header(data, square, courses.size, GlanceModifier)
        Spacer(GlanceModifier.height(4.dp))
        when {
            !data.usable -> Column(GlanceModifier.fillMaxWidth().defaultWeight(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalAlignment = Alignment.CenterHorizontally) {
                Column(GlanceModifier.fillMaxWidth().defaultWeight(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    Label(data.statusTitle, 15f, R.color.wg_t1, medium = true, lines = 2,
                        align = TextAlign.Center)
                    if (!square) {
                        Spacer(GlanceModifier.height(4.dp))
                        Label(if (data.state == "loadFailed") "网络异常，请打开课表重试" else "打开 App 登录并同步",
                            11f, R.color.wg_t3, lines = 2, align = TextAlign.Center)
                    }
                }
                Spacer(GlanceModifier.height(4.dp))
                Box(GlanceModifier.height(48.dp).background(ImageProvider(R.drawable.wg_button))
                    .clickable(open).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
                    Label(if (data.state == "loadFailed") "打开课表重试" else "打开 App",
                        12f, R.color.wg_on_acc)
                }
            }
            courses.isEmpty() -> Column(GlanceModifier.fillMaxWidth().defaultWeight().semantics {
                contentDescription = listOf(data.statusTitle, data.tomorrow?.let {
                    "明天 ${widgetTime(it.start)} ${it.name}"
                } ?: "明天没课").joinToString("，")
            }) {
                Box(GlanceModifier.fillMaxWidth().defaultWeight(), contentAlignment = Alignment.Center) {
                    Label(data.statusTitle, 12f, R.color.wg_t3, lines = 2, align = TextAlign.Center)
                }
                Spacer(GlanceModifier.height(5.dp))
                Box(GlanceModifier.fillMaxWidth().height(1.dp).background(widgetColor(context, R.color.wg_divider))) {}
                Spacer(GlanceModifier.height(5.dp))
                val tomorrow = data.tomorrow
                if (tomorrow != null) {
                    OriginOsCourse(tomorrow, data, square, 1, 1, tomorrow = true)
                } else {
                    Box(GlanceModifier.fillMaxWidth().defaultWeight(), contentAlignment = Alignment.Center) {
                        Label("明天没课", 12f, R.color.wg_t3)
                    }
                }
            }
            else -> Column(GlanceModifier.fillMaxWidth().defaultWeight()) {
                courses.forEachIndexed { index, course ->
                    if (index > 0) Spacer(GlanceModifier.height(5.dp))
                    val modifier = if (!square && courses.size > 1 && index < 2) GlanceModifier.defaultWeight()
                        else GlanceModifier
                    if (square && index > 0) Spacer(GlanceModifier.defaultWeight())
                    OriginOsCourse(course, data, square, index, courses.size, modifier)
                }
                if (courses.size == 1) {
                    Spacer(GlanceModifier.defaultWeight())
                    if (data.pending.size == 1) {
                        Spacer(GlanceModifier.height(4.dp))
                        Label("今天最后一节", 10f, R.color.wg_t3)
                    }
                }
            }
        }
    }
}

/** 课程文字由宿主按实际列宽换行和省略，不使用预估的文字宽高锁定行框。 */
@Composable
private fun OriginOsCourse(
    course: WidgetCourse, data: WidgetSnapshot, square: Boolean, index: Int, count: Int,
    modifier: GlanceModifier = GlanceModifier, tomorrow: Boolean = false,
) {
    val main = index == 0 && !tomorrow
    val compact = !square && index == 2
    val dense = !square && count >= 2
    val singleLine = !square && count >= 3
    val ongoing = main && course.start <= data.now
    val target = if (ongoing) course.end else course.start
    val countdown = main && data.preferences.showCountdown && target - data.now in 1..3_600_000L
    val clock = if (countdown) "${TimetableWidgetUpdates.minutes(data.now, target)} 分钟" else widgetTime(target)
    val clockLabel = if (tomorrow) "明天" else if (countdown) {
        if (ongoing) "距下课" else "距上课"
    } else if (ongoing) "下课" else "上课"
    val detail = listOf(course.location, course.teacher).filter { it.isNotBlank() }.joinToString(" · ")
    val time = if (square && !main) {
        listOf("${if (tomorrow) "明天" else "之后"} ${widgetTime(course.start)}", course.location)
            .filter { it.isNotBlank() }.joinToString(" · ")
    } else {
        listOf(course.nodes.takeIf { !square }.orEmpty(), course.timeRange)
            .filter { it.isNotBlank() }.joinToString(" · ")
    }
    var surface = modifier.fillMaxWidth()
    if (!square && !compact) surface = surface.background(ImageProvider(R.drawable.wg_chip))
    Box(surface.padding(horizontal = if (square) 0.dp else 8.dp,
        vertical = if (square || compact) 0.dp else 2.dp).semantics {
        contentDescription = listOf(course.name, course.location, course.teacher, course.nodes,
            course.timeRange, clockLabel, clock).filter { it.isNotBlank() }.joinToString("，")
    }, contentAlignment = Alignment.CenterStart) {
        // 自然高度容器内不能放 fillMaxHeight 色条，否则 RemoteViews 会把课程撑到剩余高度。
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Image(ImageProvider(R.drawable.wg_bar), contentDescription = null,
                modifier = GlanceModifier.width(4.dp).height(16.dp), contentScale = ContentScale.FillBounds,
                colorFilter = ColorFilter.tint(courseColor(LocalContext.current, course)))
            Spacer(GlanceModifier.width(8.dp))
            Column(GlanceModifier.defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                Label(course.name, if (square) { if (main) 16f else 12f } else if (singleLine) 13f else 14f,
                    R.color.wg_t1, medium = true, lines = if (main && count == 1) 2 else 1)
                if (!singleLine) {
                    if (detail.isNotBlank() && !dense && (!square || main)) {
                        Spacer(GlanceModifier.height(2.dp))
                        Label(detail, 11f, R.color.wg_t3)
                    }
                    Spacer(GlanceModifier.height(2.dp))
                    Label(time, if (square) 11f else 10f, R.color.wg_t3)
                }
            }
            if (!square) {
                Spacer(GlanceModifier.width(8.dp))
                Column(horizontalAlignment = Alignment.End, verticalAlignment = Alignment.CenterVertically) {
                    val color = if (main) { if (ongoing) R.color.wg_acc else R.color.wg_brk_text } else R.color.wg_t1
                    if (!singleLine) Label(clockLabel, 10f, if (main) color else R.color.wg_t3)
                    Label(clock, if (singleLine) 13f else if (main) 17f else 15f, color, medium = true)
                }
            }
        }
    }
}

@Composable
private fun TimetableCard(data: WidgetSnapshot, square: Boolean, modifier: GlanceModifier) {
    val context = LocalContext.current
    val size = LocalSize.current
    val plan = TimetableWidgetLayout.plan(context, data, square, size.width.value, size.height.value)
    val open = actionStartActivity(NotifyStore.launchIntent(context))
    Column(
        modifier = modifier.padding(plan.inset.dp),
    ) {
        if (plan.headerHeight > 0) {
            Header(data, square, plan.blocks.size, GlanceModifier.height((plan.headerHeight - 4).dp))
            Spacer(GlanceModifier.height(4.dp))
        }
        if (!data.usable) {
            Column(GlanceModifier.fillMaxWidth().defaultWeight(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalAlignment = Alignment.CenterHorizontally) {
                Label(data.statusTitle, 15f, R.color.wg_t1, medium = true, lines = plan.statusLines, align = TextAlign.Center)
                if (plan.showEmptyDetail) {
                    Spacer(GlanceModifier.height(8.dp))
                    Label(if (data.state == "loadFailed") "网络异常，请打开课表重试" else "打开 App 登录并同步",
                        11f, R.color.wg_t3, lines = 3, align = TextAlign.Center)
                }
                if (plan.showEmptyButton) {
                    Spacer(GlanceModifier.height(8.dp))
                    Box(GlanceModifier.height(48.dp).background(ImageProvider(R.drawable.wg_button))
                        .clickable(open).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
                        Label(if (data.state == "loadFailed") "打开课表重试" else "打开 App",
                            12f, R.color.wg_on_acc)
                    }
                }
            }
        } else if (data.pending.isEmpty()) {
            Column(GlanceModifier.fillMaxWidth().defaultWeight().semantics {
                contentDescription = listOf(data.statusTitle, data.tomorrow?.let {
                    "明天 ${widgetTime(it.start)} ${it.name}"
                } ?: "明天没课").joinToString("，")
            }, verticalAlignment = if (plan.showStatus) Alignment.Top else Alignment.CenterVertically) {
                if (plan.showStatus) {
                    Box(GlanceModifier.fillMaxWidth().defaultWeight(), contentAlignment = Alignment.Center) {
                        Label(data.statusTitle, 12f, R.color.wg_t3, lines = plan.statusLines, align = TextAlign.Center)
                    }
                    Spacer(GlanceModifier.height(5.dp))
                    Box(GlanceModifier.fillMaxWidth().height(1.dp).background(widgetColor(context, R.color.wg_divider))) {}
                    Spacer(GlanceModifier.height(5.dp))
                }
                val tomorrow = plan.tomorrow
                if (tomorrow != null) {
                    Course(tomorrow, square, false, false, GlanceModifier.height(tomorrow.height.dp))
                } else {
                    Box(GlanceModifier.fillMaxWidth().height(plan.tomorrowHeight.dp), contentAlignment = Alignment.Center) {
                        Label("明天没课", 12f, R.color.wg_t3)
                    }
                }
            }
        } else {
            val blocks = plan.blocks
            Column(GlanceModifier.fillMaxWidth().defaultWeight()) {
                if (square && blocks.size > 1) Spacer(GlanceModifier.defaultWeight())
                blocks.forEachIndexed { index, block ->
                    if (index > 0) Spacer(GlanceModifier.height(5.dp))
                    val modifier = if (!square && blocks.size > 1 && !block.compact) GlanceModifier.defaultWeight()
                        else GlanceModifier.height(block.height.dp)
                    Course(block, square, index == 0, block.course.start <= data.now, modifier)
                }
                if (square || blocks.size == 1) Spacer(GlanceModifier.defaultWeight())
                if (plan.lastHeight > 0) {
                    Spacer(GlanceModifier.height(4.dp))
                    Label("今天最后一节", 10f, R.color.wg_t3,
                        modifier = GlanceModifier.padding(start = if (square) 0.dp else 8.dp))
                }
            }
        }
    }
}

@Composable
private fun Header(data: WidgetSnapshot, square: Boolean, shown: Int, modifier: GlanceModifier) {
    val calendar = Calendar.getInstance().apply { timeInMillis = data.now }
    val weekdays = listOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Label(if (square) "我的课表" else "今日课表", if (square) 11f else 12f, R.color.wg_t2,
            modifier = GlanceModifier.defaultWeight())
        val hidden = data.pending.size - shown
        if (!square && data.usable && data.preferences.showCount && hidden > 0) {
            Label("+$hidden", 12f, R.color.wg_link, modifier = GlanceModifier.padding(start = 8.dp))
        }
        Label("${calendar.get(Calendar.MONTH) + 1}/${calendar.get(Calendar.DAY_OF_MONTH)}",
            if (square) 10f else 11f, R.color.wg_t2, modifier = GlanceModifier.padding(start = 4.dp))
        Label(weekdays[calendar.get(Calendar.DAY_OF_WEEK) - 1], if (square) 10f else 11f,
            R.color.wg_weekday, modifier = GlanceModifier.padding(start = 3.dp))
    }
}

@Composable
private fun Course(block: CourseBlock, square: Boolean, main: Boolean, ongoing: Boolean, modifier: GlanceModifier) {
    var surface = modifier.fillMaxWidth()
    if (!square && !block.compact) surface = surface.background(ImageProvider(R.drawable.wg_chip))
    val horizontal = if (square) 0.dp else 8.dp
    val description = listOf(block.course.name, block.course.location, block.course.teacher,
        block.course.timeRange, block.clockLabel, block.clock).filter { it.isNotBlank() }.joinToString("，")
    Box(surface.padding(horizontal = horizontal, vertical = if (square || block.compact) 0.dp else 2.dp)
        .semantics { contentDescription = description }, contentAlignment = Alignment.CenterStart) {
        // 文字栈和竖条共享自然高度，避免在桌面上对 RemoteViews 二次测量或拉伸。
        Row(GlanceModifier.fillMaxWidth().height(block.contentHeight.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Image(ImageProvider(R.drawable.wg_bar), contentDescription = null,
                modifier = GlanceModifier.width(4.dp).fillMaxHeight(), contentScale = ContentScale.FillBounds,
                colorFilter = ColorFilter.tint(courseColor(LocalContext.current, block.course)))
            Spacer(GlanceModifier.width(8.dp))
            Column(GlanceModifier.defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                Label(block.course.name, block.nameSize, R.color.wg_t1, medium = true, lines = block.nameLines)
                if (block.detail.isNotBlank()) {
                    Spacer(GlanceModifier.height(2.dp))
                    Label(block.detail, 11f, R.color.wg_t3)
                }
                if (block.time.isNotBlank()) {
                    Spacer(GlanceModifier.height(2.dp))
                    Label(block.time, block.timeSize, R.color.wg_t3)
                }
            }
            if (block.clockWidth > 0) {
                Spacer(GlanceModifier.width(8.dp))
                Column(GlanceModifier.width(block.clockWidth.dp), horizontalAlignment = Alignment.End,
                    verticalAlignment = Alignment.CenterVertically) {
                    val color = if (main) { if (ongoing) R.color.wg_acc else R.color.wg_brk_text } else R.color.wg_t1
                    if (block.clockLabel.isNotBlank()) Label(block.clockLabel, 10f, if (main) color else R.color.wg_t3)
                    Label(block.clock, block.clockSize, color, medium = true)
                }
            }
        }
    }
}

@Composable
private fun Label(
    text: String, size: Float, color: Int, modifier: GlanceModifier = GlanceModifier,
    medium: Boolean = false, lines: Int = 1, align: TextAlign = TextAlign.Start,
) {
    Text(text, modifier, style = TextStyle(color = widgetColor(LocalContext.current, color), fontSize = size.sp,
        fontFamily = FontFamily(if (medium) "sans-serif-medium" else "sans-serif"), textAlign = align), maxLines = lines)
}

/** 使用公开的昼夜颜色接口，避免依赖 Glance 内部资源 ColorProvider 重载。 */
private fun widgetColor(context: Context, resource: Int): ColorProvider =
    androidx.glance.color.ColorProvider(
        Color(widgetThemeContext(context, false).getColor(resource)),
        Color(widgetThemeContext(context, true).getColor(resource)),
    )

private fun widgetThemeContext(context: Context, night: Boolean): Context {
    val configuration = Configuration(context.resources.configuration).apply {
        uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
            if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
    }
    return context.createConfigurationContext(configuration)
}

/** 保留两套课程色，并确保竖条在浅／深色卡片和课程块上的对比度。 */
private fun courseColor(context: Context, course: WidgetCourse): ColorProvider {
    fun color(night: Boolean): Color {
        val themed = widgetThemeContext(context, night)
        val raw = if (night) course.darkColor else course.lightColor
        val initial = if (raw != 0) ColorUtils.setAlphaComponent(raw, 255) else themed.getColor(R.color.wg_acc)
        val target = themed.getColor(R.color.wg_t1)
        for (step in 0..10) {
            val value = ColorUtils.blendARGB(initial, target, step / 10f)
            if (minOf(ColorUtils.calculateContrast(value, themed.getColor(R.color.wg_bg)),
                    ColorUtils.calculateContrast(value, themed.getColor(R.color.wg_chip))) >= 3.0) return Color(value)
        }
        return Color(target)
    }
    return androidx.glance.color.ColorProvider(color(false), color(true))
}
