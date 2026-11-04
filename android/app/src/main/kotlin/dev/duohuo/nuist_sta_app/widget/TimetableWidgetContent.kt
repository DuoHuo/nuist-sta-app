package dev.duohuo.nuist_sta_app.widget

import android.content.Context
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.DpSize
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

/** 使用 Canonical 文本栈的 LocalSize 排版原则，保持既有课表的视觉层级。 */
@Composable
internal fun TimetableWidgetContent(data: WidgetSnapshot, square: Boolean) {
    val hostSize = LocalSize.current
    val side = minOf(hostSize.width, hostSize.height)
    val cardSize = if (square) DpSize(side, side) else hostSize
    // 2×2 的视觉卡片保持正方形，宿主可能分配长方形；剩余空间必须对称分布。
    // 只约束卡片尺寸，字体与内部布局按实际正方形空间重排，不缩放最终 RemoteViews。
    Box(GlanceModifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CompositionLocalProvider(LocalSize provides cardSize) {
            TimetableCard(data, square, GlanceModifier.width(cardSize.width).height(cardSize.height))
        }
    }
}

@Composable
private fun TimetableCard(data: WidgetSnapshot, square: Boolean, modifier: GlanceModifier) {
    val context = LocalContext.current
    val size = LocalSize.current
    val plan = TimetableWidgetLayout.plan(context, data, square, size.width.value, size.height.value)
    val open = actionStartActivity(NotifyStore.launchIntent(context))
    val cacheWarning = if (data.state == "loadFailed" && data.usable) "更新失败，请打开课表刷新" else ""
    // 宿主负责格子与默认外边距，背景标识只附着在真实卡片上，便于圆角裁剪和启动动画。
    Column(
        modifier = modifier.appWidgetBackground()
            .background(ImageProvider(R.drawable.wg_bg)).cornerRadius(20.dp)
            .clickable(open).padding(plan.inset.dp)
            .then(if (cacheWarning.isNotEmpty()) GlanceModifier.semantics {
                contentDescription = cacheWarning
            } else GlanceModifier),
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
