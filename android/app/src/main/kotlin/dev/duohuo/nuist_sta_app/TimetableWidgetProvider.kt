package dev.duohuo.nuist_sta_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Typeface
import androidx.core.graphics.ColorUtils
import android.util.TypedValue
import android.util.SizeF
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.RemoteViews
import android.widget.FrameLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * 桌面小组件 4×2「今日课表」并提供 2×2「当前/下一节」共用的数据 / 刷新底座
 * 两种尺寸按桌面提供的宽高和系统字号精简内容。
 *
 * 两种尺寸使用**同一份** Flutter payload（SharedPreferences `nuist_notify_widget/widget_payload`）
 * 与 `prefs` / 颜色 token，仅布局和渲染不同：4×2 用 `widget_timetable.xml`，2×2 用
 * `widget_timetable_2x2.xml`，由 [render] 按 AppWidget 的 provider 组件分发。
 * 不使用 updatePeriodMillis，改为在上下课、倒计时分钟变化时刻和 00:01
 * 用 AlarmManager 唤起刷新；开机 / 改时间 / 改时区由 [NotifySystemEventReceiver] 刷新。
 */
open class TimetableWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(ctx, mgr, id)
        scheduleNext(ctx)
    }

    override fun onAppWidgetOptionsChanged(
        ctx: Context, mgr: AppWidgetManager, id: Int, options: Bundle,
    ) = render(ctx, mgr, id)

    override fun onReceive(ctx: Context, intent: Intent) {
        super.onReceive(ctx, intent)
        if (intent.action == ACTION_TICK) refreshAll(ctx)
    }

    override fun onDisabled(ctx: Context) {
        // 两种尺寸共用同一个 AlarmManager tick：只剩其中一种时不能取消。
        val mgr = AppWidgetManager.getInstance(ctx)
        val has4x2 = mgr.getAppWidgetIds(
            ComponentName(ctx, TimetableWidgetProvider::class.java),
        ).isNotEmpty()
        val has2x2 = mgr.getAppWidgetIds(
            ComponentName(ctx, TimetableWidget2x2Provider::class.java),
        ).isNotEmpty()
        if (!has4x2 && !has2x2) {
            ctx.getSystemService(AlarmManager::class.java)?.cancel(tickIntent(ctx))
        }
    }

    /** 一节课（时间已按当前时区换算）。 */
    data class Item(
        val name: String, val location: String, val nodes: String,
        val start: Long, val end: Long, val color: Int, val colorDark: Int,
        /** 只显示第一位教师的原始姓名。 */
        val teacherFirst: String = "", val periodTime: String = "",
    ) {
        /** 显示第一位姓名，不添加后缀。 */
        val teacherLabel: String
            get() = teacherFirst
    }

    data class Day(val date: String, val weekday: Int, val week: Int?, val items: List<Item>)

    companion object {
        private const val ACTION_TICK = "dev.duohuo.nuist_sta_app.WIDGET_TICK"
        private const val HOUR = 60 * 60 * 1000L
        private const val MINUTE = 60 * 1000L
        private val WEEKDAYS = arrayOf("", "周一", "周二", "周三", "周四", "周五", "周六", "周日")

        fun savePayload(ctx: Context, json: String) {
            NotifyStore.prefs(ctx).edit().putString(NotifyStore.KEY_WIDGET, json).apply()
            refreshAll(ctx)
        }

        private const val KEY_LAST_NIGHT = "widget_last_night"
        private const val KEY_LAST_FONT_SCALE = "widget_last_font_scale"

        /** 明暗或字号变化时重绘（Activity / 插件收到配置变化时调用）。 */
        fun refreshIfNightChanged(ctx: Context) {
            val night = isDark(ctx)
            val prefs = NotifyStore.prefs(ctx)
            val fontScale = ctx.resources.configuration.fontScale
            if (prefs.contains(KEY_LAST_NIGHT) && prefs.getBoolean(KEY_LAST_NIGHT, false) == night &&
                prefs.getFloat(KEY_LAST_FONT_SCALE, 0f) == fontScale) return
            refreshAll(ctx)
        }

        fun refreshAll(ctx: Context) {
            NotifyStore.prefs(ctx).edit().putBoolean(KEY_LAST_NIGHT, isDark(ctx))
                .putFloat(KEY_LAST_FONT_SCALE, ctx.resources.configuration.fontScale).apply()
            val mgr = AppWidgetManager.getInstance(ctx)
            val ids = ArrayList<Int>()
            ids.addAll(
                mgr.getAppWidgetIds(ComponentName(ctx, TimetableWidgetProvider::class.java)).toList(),
            )
            ids.addAll(
                mgr.getAppWidgetIds(ComponentName(ctx, TimetableWidget2x2Provider::class.java)).toList(),
            )
            for (id in ids) render(ctx, mgr, id)
            if (ids.isNotEmpty()) scheduleNext(ctx)
        }

        private fun payload(ctx: Context): JSONObject? = try {
            NotifyStore.prefs(ctx).getString(NotifyStore.KEY_WIDGET, null)?.let { JSONObject(it) }
        } catch (_: Exception) {
            null
        }

        /** 普通课与注入的明天首节共用解析；缺字段 / null 时按无课程处理。 */
        private fun item(o: JSONObject?): Item? {
            if (o == null) return null
            val s = NotifyStore.parseLocal(o.optString("start")) ?: return null
            val e = NotifyStore.parseLocal(o.optString("end")) ?: return null
            return Item(
                o.optString("name"), o.optString("location"), o.optString("nodes"),
                s, e, o.optInt("color", 0), o.optInt("colorDark", 0),
                o.optString("teacherFirst"),
                o.optString("periodTime"),
            )
        }

        /** 读取当日对应的接口注入值，跨零点无需启动 Flutter；旧 payload 仍按日期校验。 */
        private fun tomorrowFirst(p: JSONObject?, now: Long): Item? {
            val dates = p?.optJSONArray("days")
            var injected = p?.optJSONObject("tomorrowFirst")
            if (dates != null) for (i in 0 until dates.length()) {
                val day = dates.optJSONObject(i) ?: continue
                if (day.optString("date") == NotifyStore.today(now) && day.has("tomorrowFirst")) {
                    injected = day.optJSONObject("tomorrowFirst")
                    break
                }
            }
            val first = item(injected) ?: return null
            val tomorrow = Calendar.getInstance().apply {
                timeInMillis = now
                add(Calendar.DAY_OF_MONTH, 1)
            }
            return first.takeIf { NotifyStore.today(it.start) == NotifyStore.today(tomorrow.timeInMillis) }
        }

        private fun days(p: JSONObject?): List<Day> {
            val arr = p?.optJSONArray("days") ?: JSONArray()
            val out = ArrayList<Day>()
            for (i in 0 until arr.length()) {
                val d = arr.optJSONObject(i) ?: continue
                val items = ArrayList<Item>()
                val ia = d.optJSONArray("items") ?: JSONArray()
                for (j in 0 until ia.length()) {
                    val o = ia.optJSONObject(j) ?: continue
                    item(o)?.let { items.add(it) }
                }
                items.sortBy { it.start }
                val week = if (d.isNull("week")) null else d.optInt("week")
                out.add(Day(d.optString("date"), d.optInt("weekday"), week, items))
            }
            return out
        }

        private fun hm(t: Long) = SimpleDateFormat("HH:mm", Locale.US).format(t)

        /** 强制浅 / 深配置的 Context，用于取 values / values-night 两套颜色。 */
        private fun modeCtx(ctx: Context, night: Boolean): Context {
            val c = Configuration(ctx.resources.configuration)
            c.uiMode = (c.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                (if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO)
            return ctx.createConfigurationContext(c)
        }

        /**
         * 资源颜色（values / values-night）。API 31+ 用 setColorInt 同时给浅 / 深两值，
         * 由桌面按 uiMode 自动切换；更低版本按当前 uiMode 取值，切换明暗时靠刷新重绘。
         */
        private fun resColor(ctx: Context, v: RemoteViews, id: Int, method: String, res: Int) {
            if (Build.VERSION.SDK_INT >= 31) {
                v.setColorInt(id, method, modeCtx(ctx, false).getColor(res), modeCtx(ctx, true).getColor(res))
            } else {
                v.setInt(id, method, ctx.getColor(res))
            }
        }

        /** 课程竖条沿用课程色，并确保在小组件底色上可见。 */
        private fun barColor(ctx: Context, v: RemoteViews, id: Int, light: Int, darkColor: Int) {
            fun visibleColor(value: Int, night: Boolean): Int {
                val themed = modeCtx(ctx, night)
                val initial = if (value != 0) value else themed.getColor(R.color.wg_acc)
                val background = themed.getColor(R.color.wg_bg)
                val chip = themed.getColor(R.color.wg_chip)
                val target = themed.getColor(R.color.wg_t1)
                for (step in 0..10) {
                    val adjusted = ColorUtils.blendARGB(initial, target, step / 10f)
                    if (minOf(ColorUtils.calculateContrast(adjusted, background),
                            ColorUtils.calculateContrast(adjusted, chip)) >= 3.0) return adjusted
                }
                return target
            }
            val l = visibleColor(light, false)
            val d = visibleColor(darkColor, true)
            if (Build.VERSION.SDK_INT >= 31) {
                v.setColorInt(id, "setColorFilter", l, d)
            } else {
                v.setInt(id, "setColorFilter", if (isDark(ctx)) d else l)
            }
        }

        private fun isDark(ctx: Context) =
            (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES

        /** 使用 TextView 的实际字体测量宽度，包含系统字号缩放。 */
        private fun textPx(ctx: Context, text: String, sp: Float, bold: Boolean = false): Int =
            TextView(ctx).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
                typeface = Typeface.create("sans-serif", if (bold) Typeface.BOLD else Typeface.NORMAL)
                this.text = text
                measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
            }.measuredWidth

        private fun dpPx(ctx: Context, dp: Float) = (dp * ctx.resources.displayMetrics.density).toInt()

        private fun visible(v: RemoteViews, id: Int, show: Boolean) =
            v.setViewVisibility(id, if (show) View.VISIBLE else View.GONE)

        private fun openPending(ctx: Context, code: Int, route: String = NotifyStore.ROUTE_TIMETABLE) =
            PendingIntent.getActivity(
                ctx, code, NotifyStore.launchIntent(ctx, route),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        /** Android 12+ 每个实际尺寸各给一份布局；旧桌面按当前方向选宽高。 */
        fun render(ctx: Context, mgr: AppWidgetManager, widgetId: Int) {
            val square = mgr.getAppWidgetInfo(widgetId)?.provider ==
                ComponentName(ctx, TimetableWidget2x2Provider::class.java)
            val options = mgr.getAppWidgetOptions(widgetId)
            val now = System.currentTimeMillis()
            val p = payload(ctx)
            val today = days(p).firstOrNull { it.date == NotifyStore.today(now) }
            fun build(size: SizeF) = if (square) render2x2(ctx, size, p, today, now)
                else render4x2(ctx, size, p, today, now)
            if (Build.VERSION.SDK_INT >= 31) {
                val supplied = if (Build.VERSION.SDK_INT >= 33) {
                    options.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                }
                val sizes = supplied
                    ?.filter { it.width > 0 && it.height > 0 }?.distinct()?.take(16)
                if (!sizes.isNullOrEmpty()) {
                    mgr.updateAppWidget(widgetId, RemoteViews(sizes.associateWith { build(it) }))
                    return
                }
            }
            val landscape = ctx.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
            val defaultW = if (square) 160 else 320
            val defaultH = if (square) 160 else 168
            val width = options.getInt(if (landscape) AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH
                else AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, defaultW).takeIf { it > 0 } ?: defaultW
            val height = options.getInt(if (landscape) AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
                else AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, defaultH).takeIf { it > 0 } ?: defaultH
            mgr.updateAppWidget(widgetId, build(SizeF(width.toFloat(), height.toFloat())))
        }

        /** 在本地应用 RemoteViews 并测量，用实际文字高度判断是否需要精简。 */
        private fun measured(ctx: Context, v: RemoteViews, size: SizeF): View =
            v.apply(ctx, FrameLayout(ctx)).apply {
                measure(
                    View.MeasureSpec.makeMeasureSpec(dpPx(ctx, size.width), View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(dpPx(ctx, size.height), View.MeasureSpec.EXACTLY),
                )
            }

        /** 在最终内容宽度下重新测量自然高度，不使用父布局压缩后的高度。 */
        private fun naturalHeight(content: View): Int {
            content.measure(
                View.MeasureSpec.makeMeasureSpec(content.measuredWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.UNSPECIFIED,
            )
            return content.measuredHeight
        }

        private fun mainFits(ctx: Context, v: RemoteViews, size: SizeF, areaId: Int, contentId: Int): Boolean {
            val root = measured(ctx, v, size)
            val area = root.findViewById<View>(areaId)
            val content = root.findViewById<View>(contentId)
            var available = area.measuredHeight - area.paddingTop - area.paddingBottom
            if (areaId == R.id.wg_main_area || areaId == R.id.wg2_main_area) {
                // 主课按自然高度测量，预算扣除后续课程，忽略用于整体居中的弹性留白。
                val group = area.parent as ViewGroup
                available = group.measuredHeight - group.paddingTop - group.paddingBottom
                for (i in 0 until group.childCount) {
                    val child = group.getChildAt(i)
                    if (child.visibility == View.GONE || child.id == R.id.wg_bottom_space ||
                        child.id == R.id.wg2_main_space_top || child.id == R.id.wg2_main_space_bottom) continue
                    val margins = child.layoutParams as? ViewGroup.MarginLayoutParams
                    available -= (margins?.topMargin ?: 0) + (margins?.bottomMargin ?: 0)
                    if (child !== area) available -= child.measuredHeight
                }
                available -= area.paddingTop + area.paddingBottom
            }
            // wrap_content 在父布局的限制下可能已被压缩，所以重新测量内容的自然高度。
            return naturalHeight(content) <= available
        }

        /** 空状态也按字号测量：说明和按钮放不下时由整卡承担打开操作。 */
        private fun empty(
            ctx: Context, v: RemoteViews, size: SizeF, square: Boolean,
            title: String, sub: String, action: String?,
        ): RemoteViews {
            val group = if (square) R.id.wg2_group_empty else R.id.wg_group_empty
            val main = if (square) R.id.wg2_group_main else R.id.wg_group_main
            val titleId = if (square) R.id.wg2_empty_title else R.id.wg_empty_title
            val subId = if (square) R.id.wg2_empty_sub else R.id.wg_empty_sub
            val buttonId = if (square) R.id.wg2_empty_button else R.id.wg_empty_button
            val header = if (square) R.id.wg2_header else R.id.wg_header
            visible(v, main, false)
            visible(v, group, true)
            v.setTextViewText(titleId, title)
            v.setTextViewText(subId, sub)
            visible(v, subId, sub.isNotBlank())
            visible(v, buttonId, action != null)
            v.setTextViewText(buttonId, action.orEmpty())
            v.setOnClickPendingIntent(buttonId, openPending(ctx, if (square) 23 else 5))
            fun fits(): Boolean {
                val root = measured(ctx, v, size)
                val container = root.findViewById<View>(group)
                val available = container.measuredHeight
                container.measure(
                    View.MeasureSpec.makeMeasureSpec(container.measuredWidth, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.UNSPECIFIED,
                )
                return container.measuredHeight <= available
            }
            if (!fits()) visible(v, subId, false)
            if (!fits()) visible(v, header, false)
            if (!fits()) visible(v, buttonId, false)
            v.setContentDescription(group, listOf(title, sub, action.orEmpty()).filter { it.isNotBlank() }.joinToString("，"))
            return v
        }

        private fun detail(ctx: Context, c: Item, avail: Int, allowTeacher: Boolean): String {
            val text = listOf(c.location, c.teacherLabel).filter { it.isNotBlank() }.joinToString(" · ")
            return if (allowTeacher && textPx(ctx, text, 11f) <= avail) text else c.location
        }

        /** 两种尺寸同日课程都用固定间距，只有隔天信息显示分隔线。 */
        private fun afterVisible(v: RemoteViews, square: Boolean, show: Boolean, tomorrow: Boolean = false) {
            visible(v, if (square) R.id.wg2_after else R.id.wg_rows, show)
            visible(v, if (square) R.id.wg2_after_divider else R.id.wg_after_divider, show && tomorrow)
            visible(v, if (square) R.id.wg2_course_gap else R.id.wg_course_gap, show && !tomorrow)
        }

        /** 2×2 同日课程组整体居中；最后一节课程靠上、提示贴底。 */
        private fun squareMainCentered(v: RemoteViews, center: Boolean) {
            visible(v, R.id.wg2_main_space_top, center)
            visible(v, R.id.wg2_main_space_bottom, true)
        }

        private fun squareAfter(ctx: Context, v: RemoteViews, c: Item, tomorrow: Boolean, width: Int) {
            visible(v, R.id.wg2_after_course, true)
            visible(v, R.id.wg2_tomorrow_free, false)
            v.setTextViewText(R.id.wg2_after_name, c.name)
            val prefix = "${if (tomorrow) "明天" else "之后"} ${hm(c.start)}"
            val full = listOf(prefix, c.location).filter { it.isNotBlank() }.joinToString(" · ")
            v.setTextViewText(R.id.wg2_after_detail, if (textPx(ctx, full, 11f) <= width) full else prefix)
            visible(v, R.id.wg2_after_detail, true)
            barColor(ctx, v, R.id.wg2_after_bar, c.color, c.colorDark)
        }

        /** 下一节与明日首节复用完整课程块，遵循 payload 中的显示开关。 */
        private fun wideAfter(ctx: Context, v: RemoteViews, c: Item, tomorrow: Boolean, width: Int, compact: Boolean) {
            visible(v, R.id.wg_row1_course, true)
            visible(v, R.id.wg_tomorrow_free, false)
            visible(v, R.id.wg_row1_label, true)
            v.setTextViewText(R.id.wg_row1_name, c.name)
            val info = detail(ctx, c, width, !compact)
            v.setTextViewText(R.id.wg_row1_loc, info)
            visible(v, R.id.wg_row1_loc, info.isNotBlank())
            val range = "${hm(c.start)}–${hm(c.end)}"
            val full = listOf(c.nodes, range).filter { it.isNotBlank() }.joinToString(" · ")
            v.setTextViewText(R.id.wg_row1_range, if (!compact && textPx(ctx, full, 10f) <= width) full else range)
            visible(v, R.id.wg_row1_range, true)
            visible(v, R.id.wg_row1_clock, true)
            v.setTextViewText(R.id.wg_row1_label, if (tomorrow) "明天" else "上课")
            v.setTextViewText(R.id.wg_row1_time, hm(c.start))
            barColor(ctx, v, R.id.wg_row1_bar, c.color, c.colorDark)
            if (textPx(ctx, range, 10f) > width) {
                visible(v, R.id.wg_row1_clock, false)
                v.setTextViewText(R.id.wg_row1_range, if (tomorrow) "明天 · $range" else range)
            }
        }

        /** 先按底部区的自然高度精简大字号详情，再为同日课程分配剩余高度。 */
        private fun fitAfter(ctx: Context, v: RemoteViews, size: SizeF, square: Boolean) {
            val area = if (square) R.id.wg2_after else R.id.wg_row1_course
            val content = if (square) R.id.wg2_after_course else R.id.wg_row1_content
            fun fits() = mainFits(ctx, v, size, area, content)
            if (!fits()) visible(v, if (square) R.id.wg2_after_detail else R.id.wg_row1_loc, false)
            if (!square && !fits()) visible(v, R.id.wg_row1_label, false)
            if (!square && !fits()) {
                visible(v, R.id.wg_row1_clock, true)
                visible(v, R.id.wg_row1_range, false)
                // 仍保留右侧开始时间，不能让精简后的课程失去上课时间。
            }
        }

        /** 当天没有未结束课程时，保留上下分区，只预告明日首节。 */
        private fun dayFinished(
            ctx: Context, v: RemoteViews, size: SizeF, square: Boolean,
            p: JSONObject?, today: Day, now: Long, compact: Boolean, width: Int,
        ): RemoteViews {
            val title = if (today.items.isEmpty()) "今天没有课程" else "今天的课上完了"
            val first = tomorrowFirst(p, now)
            val status = if (square) R.id.wg2_status else R.id.wg_status
            val area = status
            visible(v, if (square) R.id.wg2_main else R.id.wg_main, false)
            visible(v, if (square) R.id.wg2_last else R.id.wg_more, false)
            visible(v, status, true)
            v.setTextViewText(status, title)
            if (square) {
                visible(v, R.id.wg2_main_space_top, false)
                visible(v, R.id.wg2_main_space_bottom, false)
                visible(v, R.id.wg2_after_course, first != null)
                visible(v, R.id.wg2_tomorrow_free, first == null)
                if (first != null) squareAfter(ctx, v, first, true, width)
            } else {
                visible(v, R.id.wg_main_area, false)
                visible(v, R.id.wg_bottom_space, false)
                visible(v, R.id.wg_row1, true)
                visible(v, R.id.wg_row2, false)
                visible(v, R.id.wg_row1_course, first != null)
                visible(v, R.id.wg_tomorrow_free, first == null)
                if (first != null) wideAfter(ctx, v, first, true, width, compact)
            }
            afterVisible(v, square, true, tomorrow = true)
            if (first != null) fitAfter(ctx, v, size, square)
            if (!mainFits(ctx, v, size, area, status)) {
                visible(v, if (square) R.id.wg2_header else R.id.wg_header, false)
            }
            val next = first?.let {
                listOf("明天 ${hm(it.start)} ${it.name}", it.location, it.teacherLabel,
                    "${hm(it.start)}–${hm(it.end)}").filter { s -> s.isNotBlank() }.joinToString("，")
            } ?: "明天没课"
            v.setContentDescription(if (square) R.id.wg2_group_main else R.id.wg_group_main,
                listOf(title, next, if (p?.optString("state") == "loadFailed")
                    "更新失败，请打开课表刷新" else "").filter { it.isNotBlank() }.joinToString("，"))
            return v
        }

        private fun render2x2(ctx: Context, size: SizeF, p: JSONObject?, today: Day?, now: Long): RemoteViews {
            val v = RemoteViews(ctx.packageName, R.layout.widget_timetable_2x2)
            visible(v, R.id.wg2_header, true)
            v.setInt(R.id.wg2_main_name, "setMaxLines", 1)
            // 2×2 是桌面格数，格子可能不是正方形；实际卡片使用短边，剩余区域透明。
            val side = minOf(size.width, size.height)
            v.setViewPadding(R.id.wg2_root, 0, 0, dpPx(ctx, size.width - side), dpPx(ctx, size.height - side))
            val compact = side < 140
            val inset = if (compact) 8f else 10f
            val contentWidth = dpPx(ctx, side - inset * 2 - 12)
            v.setViewPadding(R.id.wg2_surface, dpPx(ctx, inset), dpPx(ctx, inset), dpPx(ctx, inset), dpPx(ctx, inset))
            val cal = Calendar.getInstance().apply { timeInMillis = now }
            val date = "${cal.get(Calendar.MONTH) + 1}/${cal.get(Calendar.DAY_OF_MONTH)}"
            val wd = WEEKDAYS[((cal.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1]
            v.setTextViewText(R.id.wg2_header_title, "我的课表")
            v.setTextViewText(R.id.wg2_header_date, date)
            v.setTextViewText(R.id.wg2_header_weekday, wd)
            resColor(ctx, v, R.id.wg2_header_weekday, "setTextColor", R.color.wg_weekday)
            v.setOnClickPendingIntent(R.id.wg2_root, openPending(ctx, 20))
            val state = p?.optString("state") ?: "needsUpdate"
            val cachedFailure = state == "loadFailed" && p?.optBoolean("hasCache", false) == true && today != null
            if (state == "loadFailed" && !cachedFailure) {
                return empty(ctx, v, size, true, "课表加载失败", "网络异常，请打开课表重试", "打开课表重试")
            }
            if (state == "needsUpdate" || today == null) {
                return empty(ctx, v, size, true, "课表需要更新", "打开 App 登录并同步", "打开 App")
            }
            // 桌面可能复用同一份布局；显式恢复上一状态隐藏的主区和提示。
            visible(v, R.id.wg2_group_main, true)
            visible(v, R.id.wg2_group_empty, false)
            visible(v, R.id.wg2_main, true)
            visible(v, R.id.wg2_status, false)
            val pending = today.items.filter { it.end > now }
            val main = pending.firstOrNull()
            if (main == null) {
                return dayFinished(ctx, v, size, true, p, today, now, compact, contentWidth)
            }
            v.setTextViewText(R.id.wg2_main_name, main.name)
            visible(v, R.id.wg2_main_bar, true)
            barColor(ctx, v, R.id.wg2_main_bar, main.color, main.colorDark)
            val info = detail(ctx, main, contentWidth, !compact)
            v.setTextViewText(R.id.wg2_main_loc, info)
            visible(v, R.id.wg2_main_loc, info.isNotBlank())
            val range = "${hm(main.start)}–${hm(main.end)}"
            v.setTextViewText(R.id.wg2_main_time, if (textPx(ctx, range, 11f) <= contentWidth) range
                else if (main.start <= now) hm(main.end) else hm(main.start))
            val after = pending.getOrNull(1)
            val showAfter = after != null && !compact
            squareMainCentered(v, showAfter)
            afterVisible(v, true, showAfter)
            visible(v, R.id.wg2_last, after == null)
            if (after != null) {
                squareAfter(ctx, v, after, false, contentWidth)
                if (showAfter) fitAfter(ctx, v, size, true)
            }
            val root = measured(ctx, v, size)
            val name = root.findViewById<TextView>(R.id.wg2_main_name)
            if (!compact && name.layout?.getEllipsisCount(0) != 0) v.setInt(R.id.wg2_main_name, "setMaxLines", 2)
            fun fits() = mainFits(ctx, v, size, R.id.wg2_main_area, R.id.wg2_main)
            if (!fits()) {
                afterVisible(v, true, false)
                // 居中依据实际显示的课程数；下一节被精简掉后，主课必须恢复顶部对齐。
                squareMainCentered(v, false)
            }
            if (!fits()) v.setInt(R.id.wg2_main_name, "setMaxLines", 1)
            if (!fits()) visible(v, R.id.wg2_main_loc, false)
            if (!fits()) visible(v, R.id.wg2_header, false)
            if (!fits()) visible(v, R.id.wg2_last, false)
            v.setContentDescription(R.id.wg2_group_main,
                listOf(if (main.start <= now) "上课中" else "下一节", main.name, main.location, range,
                    after?.let { "之后 ${hm(it.start)} ${it.name}" } ?: "今天最后一节",
                    if (cachedFailure) "更新失败，请打开课表刷新" else "").filter { it.isNotBlank() }.joinToString("，"))
            return v
        }

        private fun render4x2(ctx: Context, size: SizeF, p: JSONObject?, today: Day?, now: Long): RemoteViews {
            val v = RemoteViews(ctx.packageName, R.layout.widget_timetable)
            // 桌面会复用视图，切换到最后一节或隔天前必须撤销同日课程的弹性高度。
            v.setInt(R.id.wg_main, "setMinimumHeight", 0)
            v.setInt(R.id.wg_row1, "setMinimumHeight", 0)
            v.setInt(R.id.wg_row1_course, "setMinimumHeight", 0)
            for (id in intArrayOf(R.id.wg_main, R.id.wg_row1_course)) {
                v.setViewPadding(id, dpPx(ctx, 8f), dpPx(ctx, 2f), dpPx(ctx, 8f), dpPx(ctx, 2f))
            }
            visible(v, R.id.wg_header, true)
            visible(v, R.id.wg_header_more, false)
            visible(v, R.id.wg_main_label, true)
            v.setInt(R.id.wg_main_name, "setMaxLines", 1)
            val compact = size.width < 280 || size.height < 140
            val inset = if (compact) 8f else 10f
            v.setViewPadding(R.id.wg_root, dpPx(ctx, inset), dpPx(ctx, inset), dpPx(ctx, inset), dpPx(ctx, inset))
            val cal = Calendar.getInstance().apply { timeInMillis = now }
            val wd = WEEKDAYS[((cal.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1]
            v.setTextViewText(R.id.wg_header_title, "今日课表")
            v.setTextViewText(R.id.wg_header_date, "${cal.get(Calendar.MONTH) + 1}/${cal.get(Calendar.DAY_OF_MONTH)}")
            v.setTextViewText(R.id.wg_header_weekday, wd)
            resColor(ctx, v, R.id.wg_header_weekday, "setTextColor", R.color.wg_weekday)
            val state = p?.optString("state") ?: "needsUpdate"
            val cachedFailure = state == "loadFailed" && p?.optBoolean("hasCache", false) == true && today != null
            v.setOnClickPendingIntent(R.id.wg_root, openPending(ctx, 1))
            if (state == "loadFailed" && !cachedFailure) {
                return empty(ctx, v, size, false, "课表加载失败", "网络异常，请打开课表重试", "打开课表重试")
            }
            if (state == "needsUpdate" || today == null) {
                return empty(ctx, v, size, false, "课表需要更新", "打开 App 登录并同步", "打开 App")
            }
            visible(v, R.id.wg_group_main, true)
            visible(v, R.id.wg_group_empty, false)
            visible(v, R.id.wg_main_area, true)
            visible(v, R.id.wg_main, true)
            visible(v, R.id.wg_status, false)
            val pending = today.items.filter { it.end > now }
            val main = pending.firstOrNull()
            val clockPx = maxOf(dpPx(ctx, 68f), textPx(ctx, "60 分钟", 17f, true))
            val available = dpPx(ctx, size.width - inset * 2 - 16 - 12 - 8) - clockPx
            val afterAvailable = dpPx(ctx, size.width - inset * 2 - 16 - 12 - 8) -
                maxOf(dpPx(ctx, 64f), textPx(ctx, "23:59", 15f, true))
            if (main == null) {
                return dayFinished(ctx, v, size, false, p, today, now, compact, afterAvailable)
            }
            val prefs = p?.optJSONObject("prefs")
            val showCountdown = prefs?.optBoolean("showCountdown", true) ?: true
            val count = (prefs?.optInt("courseCount", 2) ?: 2).let { if (it in 1..3) it else 2 }
            val ongoing = main.start <= now
            val target = if (ongoing) main.end else main.start
            val countdown = showCountdown && target - now <= HOUR
            val accent = if (ongoing) R.color.wg_acc else R.color.wg_brk_text
            val minutes = countdownMinutes(now, target)
            v.setTextViewText(R.id.wg_main_static, if (countdown) "$minutes 分钟" else hm(target))
            v.setTextViewText(R.id.wg_main_label, if (countdown) { if (ongoing) "距下课" else "距上课" }
                else if (ongoing) "下课" else "上课")
            for (id in intArrayOf(R.id.wg_main_label, R.id.wg_main_static)) resColor(ctx, v, id, "setTextColor", accent)
            v.setTextViewText(R.id.wg_main_name, main.name)
            barColor(ctx, v, R.id.wg_main_bar, main.color, main.colorDark)
            val info = detail(ctx, main, available, !compact)
            v.setTextViewText(R.id.wg_main_loc, info)
            visible(v, R.id.wg_main_loc, info.isNotBlank())
            val range = "${hm(main.start)}–${hm(main.end)}"
            val fullTime = listOf(main.nodes, range).filter { it.isNotBlank() }.joinToString(" · ")
            val time = if (!compact && textPx(ctx, fullTime, 10f) <= available) fullTime else range
            v.setTextViewText(R.id.wg_main_time, time)
            var clock = textPx(ctx, range, 10f) <= available
            visible(v, R.id.wg_main_clock, clock)
            if (!clock) {
                v.setTextViewText(R.id.wg_main_time, "${hm(target)} ${if (ongoing) "下课" else "上课"}")
                visible(v, R.id.wg_main_loc, false)
            }
            val root = measured(ctx, v, size)
            val name = root.findViewById<TextView>(R.id.wg_main_name)
            if (!compact && name.layout?.getEllipsisCount(0) != 0) v.setInt(R.id.wg_main_name, "setMaxLines", 2)
            val ids = arrayOf(
                intArrayOf(R.id.wg_row1, R.id.wg_row1_bar, R.id.wg_row1_name, R.id.wg_row1_loc, R.id.wg_row1_time),
                intArrayOf(R.id.wg_row2, R.id.wg_row2_bar, R.id.wg_row2_name, R.id.wg_row2_loc, R.id.wg_row2_time),
            )
            var rows = minOf(pending.size - 1, count - 1)
            for (i in ids.indices) {
                visible(v, ids[i][0], i < rows)
                if (i >= rows) continue
                val c = pending[i + 1]
                if (i == 0) {
                    wideAfter(ctx, v, c, false, afterAvailable, compact)
                    continue
                }
                barColor(ctx, v, ids[i][1], c.color, c.colorDark)
                v.setTextViewText(ids[i][2], c.name)
                v.setTextViewText(ids[i][3], c.location)
                v.setTextViewText(ids[i][4], hm(c.start))
                val roomFits = textPx(ctx, c.name, 13f) + textPx(ctx, c.location, 11f) + textPx(ctx, hm(c.start), 12f) <=
                    dpPx(ctx, size.width - inset * 2 - 16 - 12 - 16)
                visible(v, ids[i][3], roomFits && c.location.isNotBlank())
            }
            afterVisible(v, false, rows > 0)
            // 没有下一节块时由留白与主课块均分高度，主课不被拉满整张卡片。
            visible(v, R.id.wg_bottom_space, rows == 0)
            visible(v, R.id.wg_more, pending.size == 1)
            v.setTextViewText(R.id.wg_more, "今天最后一节")
            val badge = if (prefs?.optBoolean("showCount", true) != false) pending.size - 1 - rows else 0
            visible(v, R.id.wg_header_more, badge > 0)
            v.setTextViewText(R.id.wg_header_more, "+$badge")
            v.setContentDescription(R.id.wg_group_main,
                listOf(main.name, main.location, range, if (ongoing) "上课中" else "下一节",
                    if (clock) "${if (ongoing) "距下课" else "距上课"}${(target - now + MINUTE - 1) / MINUTE}分钟" else "",
                    "之后还有 ${pending.size - 1} 节", if (cachedFailure) "更新失败，请打开课表刷新" else "")
                    .filter { it.isNotBlank() }.joinToString("，"))
            return v
        }

        /** 使用课程墙上时间计算分钟，避免设备重启后沿用旧的 elapsedRealtime 基准。 */
        fun countdownMinutes(now: Long, target: Long): Long = maxOf(0, (target - now + MINUTE - 1) / MINUTE)

        /** 下一次刷新：上下课、倒计时分钟变化及次日 00:01。 */
        fun nextRefreshAt(ctx: Context, now: Long): Long {
            val cal = Calendar.getInstance().apply {
                timeInMillis = now
                add(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 1)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }
            var next = cal.timeInMillis
            val p = payload(ctx)
            for (d in days(p)) for (item in d.items) {
                for (t in longArrayOf(item.start - HOUR, item.start, item.end - HOUR, item.end)) {
                    if (t > now && t < next) next = t
                }
            }
            if (p?.optJSONObject("prefs")?.optBoolean("showCountdown", true) != false) {
                val main = days(p).firstOrNull { it.date == NotifyStore.today(now) }?.items?.firstOrNull { it.end > now }
                if (main != null) {
                    val target = if (main.start > now) main.start else main.end
                    if (target - now in 1..HOUR) {
                        val minuteChange = target - (countdownMinutes(now, target) - 1) * MINUTE
                        if (minuteChange > now && minuteChange < next) next = minuteChange
                    }
                }
            }
            return next
        }

        private fun tickIntent(ctx: Context) = PendingIntent.getBroadcast(
            ctx, 9_000,
            Intent(ctx, TimetableWidgetProvider::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        fun scheduleNext(ctx: Context) {
            val am = ctx.getSystemService(AlarmManager::class.java) ?: return
            val at = nextRefreshAt(ctx, System.currentTimeMillis()) + 1_000L
            val pi = tickIntent(ctx)
            try {
                if (NotifyStore.canExact(ctx)) {
                    am.setExact(AlarmManager.RTC, at, pi)
                } else {
                    // Android 12+ 的 setWindow 会把短窗口放大到至少十分钟，分钟倒计时不适用。
                    am.set(AlarmManager.RTC, at, pi)
                }
            } catch (_: SecurityException) {
                am.set(AlarmManager.RTC, at, pi)
            }
        }
    }
}
