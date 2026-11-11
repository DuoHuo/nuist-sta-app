package dev.duohuo.nuist_sta_app.widget

import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LocalAppWidgetOptions
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import dev.duohuo.nuist_sta_app.R
import java.util.Locale
import kotlin.math.roundToInt

private val measurePageKey = intPreferencesKey("measurement_page")
private val measureSquareKey = ActionParameters.Key<Boolean>("measurement_square")
private val measurePageCountKey = ActionParameters.Key<Int>("measurement_pages")

/** 独立的 2×2 测量入口，不读取课表或登录状态。 */
class WidgetMeasure2x2Receiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = WidgetMeasureWidget(square = true)
}

/** 独立的 4×2 测量入口，与正式宽版使用相同占格声明。 */
class WidgetMeasure4x2Receiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = WidgetMeasureWidget(square = false)
}

/** 与课表共用 Exact 链路；蓝框始终保留指定 dp，不按上报尺寸缩小。 */
internal class WidgetMeasureWidget(private val square: Boolean) : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val pages = measurementPages(LocalContext.current, square, LocalSize.current, LocalAppWidgetOptions.current)
            val page = (currentState<Preferences>()[measurePageKey] ?: 0).mod(pages.size)
            MeasurementContent(square, pages, page)
        }
    }
}

/** 点击整块组件循环翻页，各组件独立保存页码，方便在云测中逐页截图。 */
class WidgetMeasureNextPage : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val square = parameters[measureSquareKey] ?: return
        val count = parameters[measurePageCountKey]?.coerceAtLeast(1) ?: return
        updateAppWidgetState(context, glanceId) { state ->
            state[measurePageKey] = ((state[measurePageKey] ?: 0) + 1).mod(count)
        }
        WidgetMeasureWidget(square).update(context, glanceId)
    }
}

private data class MeasurementPage(val title: String, val lines: List<String>)

/** 蓝框仅作原子组件规范尺寸对照，不参与正式课表布局。 */
private fun originOsReferenceSize(square: Boolean): DpSize =
    DpSize(if (square) 144.dp else 308.dp, 144.dp)

@Composable
private fun MeasurementContent(square: Boolean, pages: List<MeasurementPage>, index: Int) {
    val target = originOsReferenceSize(square)
    val page = pages[index]
    val next = actionRunCallback<WidgetMeasureNextPage>(actionParametersOf(
        measureSquareKey to square, measurePageCountKey to pages.size,
    ))
    // 红框是 RemoteViews 渲染根边界；宿主在它之外的留白只能通过截图对照。
    Box(GlanceModifier.fillMaxSize().background(measurementColor(R.color.wg_bg)).clickable(next),
        contentAlignment = Alignment.Center) {
        Box(GlanceModifier.width(target.width).height(target.height)
            .background(ImageProvider(R.drawable.widget_measure_target))) {}
        Column(GlanceModifier.fillMaxSize().padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            MeasurementText("${if (square) "2×2" else "4×2"} · ${page.title}", 11)
            Column(GlanceModifier.fillMaxWidth().defaultWeight(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalAlignment = Alignment.CenterHorizontally) {
                page.lines.forEach { MeasurementText(it, 12, lines = 2) }
            }
            MeasurementText("点击翻页 ${index + 1}/${pages.size}", 10)
        }
        // 最后叠加红框，蓝框超过宿主时仍能辨认根边界。
        Box(GlanceModifier.fillMaxSize().background(ImageProvider(R.drawable.widget_measure_root))) {}
    }
}

@Composable
private fun MeasurementText(value: String, size: Int, lines: Int = 1) {
    Text(value, style = TextStyle(color = measurementColor(R.color.wg_t1),
        fontSize = size.sp, textAlign = TextAlign.Center), maxLines = lines)
}

@Composable
private fun measurementColor(resource: Int): androidx.glance.unit.ColorProvider {
    val context = LocalContext.current
    fun color(night: Boolean): Color {
        val configuration = Configuration(context.resources.configuration).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        }
        return Color(context.createConfigurationContext(configuration).getColor(resource))
    }
    return androidx.glance.color.ColorProvider(color(false), color(true))
}

private fun measurementPages(context: Context, square: Boolean, local: DpSize, options: Bundle): List<MeasurementPage> {
    val target = originOsReferenceSize(square)
    val originOs = TimetableWidgetGeometry.isOriginOsHome(context)
    val honorHome = TimetableWidgetGeometry.isHonorHome(context)
    val content = if (originOs || honorHome) null else TimetableWidgetGeometry.contentSize(square, local)
    val metrics = context.resources.displayMetrics
    val config = context.resources.configuration
    val component = ComponentName(context,
        if (square) WidgetMeasure2x2Receiver::class.java else WidgetMeasure4x2Receiver::class.java)
    val padding = AppWidgetHostView.getDefaultPaddingForWidget(context, component, null)
    fun option(key: String) = if (options.containsKey(key)) options.getInt(key).toString() else "未提供"
    return buildList {
        add(MeasurementPage("边界对照", listOf("红：渲染根边界", "蓝：${sizeLabel(target)} dp", "实际大小请对照截图")))
        add(MeasurementPage("Glance 上报", listOf("${sizeLabel(local)} dp", "上报值，仅诊断")))
        add(MeasurementPage("课表内容", when {
            honorHome && square -> listOf("按实际短边居中正方形", "内部由桌面实际测量")
            honorHome -> listOf("按两列宽度折算等高", "宽度铺满，垂直居中")
            content == null -> listOf("填满父容器", "由桌面实际测量")
            else -> listOf("布局预算", "${sizeLabel(content)} dp")
        }))
        add(MeasurementPage("桌面声明 dp", listOf(
            "宽 min / max", "${option(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)} / ${option(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)}")))
        add(MeasurementPage("桌面声明 dp", listOf(
            "高 min / max", "${option(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)} / ${option(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)}")))
        val sizes = reportedSizes(options)
        if (sizes.isEmpty()) add(MeasurementPage("尺寸列表", listOf("桌面未提供", "OPTION_APPWIDGET_SIZES")))
        sizes.forEachIndexed { index, size ->
            add(MeasurementPage("尺寸列表 ${index + 1}/${sizes.size}", listOf("${number(size.width)} × ${number(size.height)} dp")))
        }
        add(MeasurementPage("资源密度", listOf("density = ${number(metrics.density)}", "DPI = ${metrics.densityDpi}", "字号倍率 = ${number(config.fontScale)}")))
        // 仅计算应用侧理论像素，不把它当成宿主最终显示的像素。
        add(MeasurementPage("应用侧换算", listOf("蓝框理论像素", "${(target.width.value * metrics.density).roundToInt()} × ${(target.height.value * metrics.density).roundToInt()} px", "桌面可能另行缩放")))
        add(MeasurementPage("资源窗口", listOf("${metrics.widthPixels} × ${metrics.heightPixels} px", "${config.screenWidthDp} × ${config.screenHeightDp} dp")))
        add(MeasurementPage("默认边距 px", listOf("左 ${padding.left} · 右 ${padding.right}", "上 ${padding.top} · 下 ${padding.bottom}", "API 默认值，非实测")))
        add(MeasurementPage("默认桌面", listOf(TimetableWidgetGeometry.homePackage(context) ?: "未识别")))
        add(MeasurementPage("尺寸策略", listOf(when {
            originOs -> "OriginOS 宿主测量"
            honorHome -> "荣耀宿主测量"
            else -> "通用策略"
        }, "蓝框仅为规范尺寸参考")))
        add(MeasurementPage("系统", listOf("Android ${Build.VERSION.RELEASE} · API ${Build.VERSION.SDK_INT}", Build.MANUFACTURER, Build.MODEL)))
    }
}

/** 只读取标准尺寸字段，旧系统、未提供或类型异常时回退为空列表。 */
private fun reportedSizes(options: Bundle): List<SizeF> = try {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            options.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java).orEmpty()
        } else {
            @Suppress("DEPRECATION")
            options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES).orEmpty()
        }
    } else emptyList()
} catch (_: RuntimeException) {
    emptyList()
}

private fun sizeLabel(size: DpSize) = "${number(size.width.value)} × ${number(size.height.value)}"

private fun number(value: Float): String = String.format(Locale.ROOT, "%.2f", value).trimEnd('0').trimEnd('.')
