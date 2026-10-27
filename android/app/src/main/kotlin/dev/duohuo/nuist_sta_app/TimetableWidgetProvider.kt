package dev.duohuo.nuist_sta_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Paint
import android.util.TypedValue
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * 桌面小组件 4×2「今日课表」并提供 2×2「当前/下一节」共用的数据 / 刷新底座
 * （两种尺寸分别遵循 spec-widget-4x2.md 的 §13 / §14）。
 *
 * 两种尺寸使用**同一份** Flutter payload（SharedPreferences `nuist_notify_widget/widget_payload`）
 * 与 `prefs` / 颜色 token，仅布局和渲染不同：4×2 用 `widget_timetable.xml`，2×2 用
 * `widget_timetable_2x2.xml`，由 [render] 按 AppWidget 的 provider 组件分发。
 * 不使用 updatePeriodMillis，改为在每个上课 / 下课 / 「>60 分钟静态行切换倒计时」时刻和 00:01
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
        /** 第一位教师（原样，不加「等」）；[teacherCount] 为教师总数。 */
        val teacherFirst: String = "", val teacherCount: Int = 0, val periodTime: String = "",
    ) {
        /** 显示用教师：第一位，多位时加「等」；无教师为空串。 */
        val teacherLabel: String
            get() = when {
                teacherFirst.isEmpty() -> ""
                teacherCount > 1 -> "${teacherFirst}等"
                else -> teacherFirst
            }
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

        /** 明暗与上次渲染不同则重绘（Activity / 插件收到配置变化时调用）。 */
        fun refreshIfNightChanged(ctx: Context) {
            val night = isDark(ctx)
            val prefs = NotifyStore.prefs(ctx)
            if (prefs.contains(KEY_LAST_NIGHT) && prefs.getBoolean(KEY_LAST_NIGHT, false) == night) return
            refreshAll(ctx)
        }

        fun refreshAll(ctx: Context) {
            NotifyStore.prefs(ctx).edit().putBoolean(KEY_LAST_NIGHT, isDark(ctx)).apply()
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
                o.optString("teacherFirst"), o.optJSONArray("teachers")?.length() ?: 0,
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

        private fun color(ctx: Context, id: Int) = ctx.getColor(id)

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

        /** 课程竖条：payload 的浅 / 深两色（缺失时用资源 wg_acc）。 */
        private fun barColor(ctx: Context, v: RemoteViews, id: Int, light: Int, darkColor: Int) {
            val l = if (light != 0) light else modeCtx(ctx, false).getColor(R.color.wg_acc)
            val d = if (darkColor != 0) darkColor else modeCtx(ctx, true).getColor(R.color.wg_acc)
            if (Build.VERSION.SDK_INT >= 31) {
                v.setColorInt(id, "setColorFilter", l, d)
            } else {
                v.setInt(id, "setColorFilter", if (isDark(ctx)) d else l)
            }
        }

        private fun isDark(ctx: Context) =
            (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES

        /** [sp] 文本宽度（px），默认 11sp。 */
        private fun textPx(ctx: Context, text: String, sp: Float = 11f): Float {
            val paint = Paint().apply {
                textSize = TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_SP, sp, ctx.resources.displayMetrics,
                )
            }
            return paint.measureText(text)
        }

        private fun dpPx(ctx: Context, dp: Int) = dp * ctx.resources.displayMetrics.density

        private fun openPending(ctx: Context, code: Int, route: String = NotifyStore.ROUTE_TIMETABLE) =
            PendingIntent.getActivity(
                ctx, code, NotifyStore.launchIntent(ctx, route),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        /** 按 AppWidget provider 组件分发到 4×2 / 2×2 渲染。 */
        fun render(ctx: Context, mgr: AppWidgetManager, widgetId: Int) {
            val provider = mgr.getAppWidgetInfo(widgetId)?.provider
            if (provider == ComponentName(ctx, TimetableWidget2x2Provider::class.java)) {
                render2x2(ctx, mgr, widgetId)
            } else {
                render4x2(ctx, mgr, widgetId)
            }
        }

        /** 2×2 新版：主课与之后四态，忽略课程数、倒计时与剩余数量偏好。 */
        private fun render2x2(ctx: Context, mgr: AppWidgetManager, widgetId: Int) {
            val v = RemoteViews(ctx.packageName, R.layout.widget_timetable_2x2)
            val now = System.currentTimeMillis()
            val p = payload(ctx)
            val all = days(p)
            val state = p?.optString("state") ?: "needsUpdate"
            val hasCache = p?.optBoolean("hasCache", false) ?: false
            val todayStr = NotifyStore.today(now)
            val idx = all.indexOfFirst { it.date == todayStr }
            val today = if (idx >= 0) all[idx] else null

            // 日期与星期拆开，星期始终使用强调色。
            val cal = Calendar.getInstance().apply { timeInMillis = now }
            val date = "${cal.get(Calendar.MONTH) + 1}/${cal.get(Calendar.DAY_OF_MONTH)}"
            val wd = WEEKDAYS[((cal.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1]
            v.setTextViewText(R.id.wg2_header_date, date)
            v.setTextViewText(R.id.wg2_header_weekday, wd)
            v.setOnClickPendingIntent(R.id.wg2_root, openPending(ctx, 20))
            v.setOnClickPendingIntent(R.id.wg2_main_area, openPending(ctx, 21))
            v.setOnClickPendingIntent(R.id.wg2_header, openPending(ctx, 22))

            fun empty(title: String, sub: String?, login: Boolean, retry: Boolean) {
                v.setViewVisibility(R.id.wg2_group_main, View.GONE)
                v.setViewVisibility(R.id.wg2_group_empty, View.VISIBLE)
                v.setTextViewText(R.id.wg2_empty_title, title)
                v.setViewVisibility(
                    R.id.wg2_empty_sub,
                    if (sub == null) View.GONE else View.VISIBLE,
                )
                v.setTextViewText(R.id.wg2_empty_sub, sub ?: "")
                v.setViewVisibility(
                    R.id.wg2_empty_button,
                    if (login) View.VISIBLE else View.GONE,
                )
                v.setTextViewText(R.id.wg2_empty_button, "打开 App")
                v.setOnClickPendingIntent(R.id.wg2_empty_button, openPending(ctx, 23))
                v.setViewVisibility(
                    R.id.wg2_empty_retry,
                    if (retry) View.VISIBLE else View.GONE,
                )
                v.setTextViewText(R.id.wg2_empty_retry, "⟳ 重试")
                // 失败重试需要真正同步数据，只能拉起 App（启动即同步）；小组件广播只重绘。
                v.setOnClickPendingIntent(R.id.wg2_empty_retry, openPending(ctx, 24))
                v.setContentDescription(
                    R.id.wg2_group_empty,
                    listOfNotNull(title, sub).joinToString("，"),
                )
                mgr.updateAppWidget(widgetId, v)
            }

            if (state == "needsUpdate" || today == null) {
                return empty("课表需要更新", "请登录后刷新", login = true, retry = false)
            }
            if (state == "loadFailed" && !hasCache) {
                return empty(
                    "加载失败", "网络异常\n显示的可能不是最新",
                    login = false, retry = true,
                )
            }

            val pending = today.items.filter { it.end > now }
            val main = pending.firstOrNull()
            val after = if (main == null) tomorrowFirst(p, now) else pending.getOrNull(1)
            v.setViewVisibility(R.id.wg2_group_main, View.VISIBLE)
            v.setViewVisibility(R.id.wg2_group_empty, View.GONE)
            v.setViewVisibility(R.id.wg2_main_bar, if (main == null) View.GONE else View.VISIBLE)
            v.setTextViewText(R.id.wg2_main_name, main?.name ?: "今天的课上完了")
            val detail = main?.let {
                listOf(it.location, it.teacherLabel).filter { s -> s.isNotBlank() }.joinToString(" · ")
            } ?: ""
            v.setTextViewText(R.id.wg2_main_loc, detail)
            v.setViewVisibility(R.id.wg2_main_loc, if (detail.isEmpty()) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.wg2_main_time, if (main == null) View.GONE else View.VISIBLE)
            if (main != null) {
                barColor(ctx, v, R.id.wg2_main_bar, main.color, main.colorDark)
                v.setTextViewText(R.id.wg2_main_time, "${hm(main.start)} - ${hm(main.end)}")
            }
            v.setViewVisibility(R.id.wg2_after_bar, if (after == null) View.GONE else View.VISIBLE)
            val afterText = when {
                after != null && main == null -> "明天 ${hm(after.start)} ${after.name}"
                after != null -> after.name
                main != null -> "今天最后一节"
                else -> "明天没课"
            }
            val afterDetail = when {
                after == null -> ""
                main == null -> after.location
                else -> listOf(hm(after.start), after.location).filter { it.isNotBlank() }.joinToString(" ")
            }
            v.setTextViewText(R.id.wg2_after_name, afterText)
            v.setTextViewTextSize(R.id.wg2_after_name, TypedValue.COMPLEX_UNIT_SP, if (after == null) 11f else 12f)
            resColor(ctx, v, R.id.wg2_after_name, "setTextColor", if (after == null) R.color.wg_t3 else R.color.wg_t1)
            v.setTextViewText(R.id.wg2_after_detail, afterDetail)
            v.setViewVisibility(R.id.wg2_after_detail, if (afterDetail.isEmpty()) View.GONE else View.VISIBLE)
            if (after != null) barColor(ctx, v, R.id.wg2_after_bar, after.color, after.colorDark)
            v.setOnClickPendingIntent(R.id.wg2_after, openPending(ctx, 25))
            v.setContentDescription(R.id.wg2_group_main, listOf(main?.name ?: "今天的课上完了", detail,
                main?.let { "${hm(it.start)} - ${hm(it.end)}" } ?: "", afterText, afterDetail)
                .filter { it.isNotBlank() }.joinToString("，"))
            mgr.updateAppWidget(widgetId, v)
        }

        private fun render4x2(ctx: Context, mgr: AppWidgetManager, widgetId: Int) {
            val v = RemoteViews(ctx.packageName, R.layout.widget_timetable)
            val opts = mgr.getAppWidgetOptions(widgetId)
            val minW = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 320)
            val narrow = minW in 1 until 280
            val widthDp = if (minW > 0) minW else 320
            val now = System.currentTimeMillis()
            val p = payload(ctx)
            val all = days(p)
            // 用户显示开关（payload.prefs，默认全开）；教师 / 地点已在 Dart 侧按开关置空。
            val prefs = p?.optJSONObject("prefs")
            val showCountdown = prefs?.optBoolean("showCountdown", true) ?: true
            val todayStr = NotifyStore.today(now)
            val idx = all.indexOfFirst { it.date == todayStr }
            val today = if (idx >= 0) all[idx] else null
            val state = p?.optString("state") ?: "needsUpdate"
            val hasCache = p?.optBoolean("hasCache", false) ?: false

            // 头部
            val cal = Calendar.getInstance().apply { timeInMillis = now }
            val wd = WEEKDAYS[((cal.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1]
            var title = "${cal.get(Calendar.MONTH) + 1}月${cal.get(Calendar.DAY_OF_MONTH)}日 $wd"
            val week = today?.week
            if (!narrow && week != null && week >= 1) title += " · 第${week}周"
            v.setTextViewText(R.id.wg_header_title, title)
            v.setViewVisibility(R.id.wg_header_more, View.GONE)

            // 整卡点击打开 App；头部不再放刷新/分享类图标（点不到且易误导）。
            v.setOnClickPendingIntent(R.id.wg_root, openPending(ctx, 1))
            v.setOnClickPendingIntent(R.id.wg_more, openPending(ctx, 4))

            fun empty(t: String, sub: String?, button: String?) {
                v.setViewVisibility(R.id.wg_group_main, View.GONE)
                v.setViewVisibility(R.id.wg_group_empty, View.VISIBLE)
                v.setTextViewText(R.id.wg_empty_title, t)
                v.setViewVisibility(R.id.wg_empty_sub, if (sub == null) View.GONE else View.VISIBLE)
                v.setTextViewText(R.id.wg_empty_sub, sub ?: "")
                v.setViewVisibility(R.id.wg_empty_button, if (button == null) View.GONE else View.VISIBLE)
                v.setTextViewText(R.id.wg_empty_button, button ?: "")
                v.setOnClickPendingIntent(R.id.wg_empty_button, openPending(ctx, 5))
                mgr.updateAppWidget(widgetId, v)
            }

            if (state == "needsUpdate" || today == null) {
                val synced = p?.optLong("lastSyncedAt", 0L) ?: 0L
                val sub = if (synced > 0) {
                    val c = Calendar.getInstance().apply { timeInMillis = synced }
                    "上次同步 ${c.get(Calendar.MONTH) + 1}月${c.get(Calendar.DAY_OF_MONTH)}日 · 请登录后刷新"
                } else "请登录后刷新"
                return empty("课表需要更新", sub, "打开 App 登录")
            }
            if (state == "loadFailed" && !hasCache) {
                return empty("加载失败", "网络异常，显示的可能不是最新", "⟳ 重试")
            }

            val pending = today.items.filter { it.end > now }
            if (pending.isEmpty()) {
                val first = tomorrowFirst(p, now)
                return empty("今天的课都上完了",
                    if (first != null) "明天 ${hm(first.start)} ${first.name}" else "明天没课", null)
            }

            v.setViewVisibility(R.id.wg_group_main, View.VISIBLE)
            v.setViewVisibility(R.id.wg_group_empty, View.GONE)
            // §13 统一结构：所有课程数均使用同一个主块，不做单课放大。
            val main = pending[0]
            val ongoing = main.start <= now
            barColor(ctx, v, R.id.wg_main_bar, main.color, main.colorDark)
            v.setTextViewText(R.id.wg_main_name, main.name)
            // 副行三段：地点（可省略）/ 教师（放不下先隐藏）/ 节次+时段（永远完整）。
            val periodTime = main.periodTime.ifEmpty { "${hm(main.start)}-${hm(main.end)}" }
            val hasLoc = main.location.isNotEmpty()
            val teacherText = if (main.teacherLabel.isEmpty()) "" else
                (if (hasLoc) " · " else "") + main.teacherLabel
            val timeText = (if (hasLoc || teacherText.isNotEmpty()) " · " else "") + periodTime
            // 可用宽 ≈ 小组件宽 − 24 − 主块内边距 16 − 竖条 11 − 倒计时列与间距 68。
            val subAvail = dpPx(ctx, widthDp - 24 - 16 - 11 - 68)
            val showTeacher = teacherText.isNotEmpty() &&
                textPx(ctx, main.location + teacherText + timeText) <= subAvail
            v.setTextViewText(R.id.wg_main_loc, main.location)
            v.setViewVisibility(R.id.wg_main_loc, if (hasLoc) View.VISIBLE else View.GONE)
            v.setTextViewText(R.id.wg_main_teacher, teacherText)
            v.setViewVisibility(R.id.wg_main_teacher, if (showTeacher) View.VISIBLE else View.GONE)
            v.setTextViewText(
                R.id.wg_main_time,
                if (!showTeacher && !hasLoc) periodTime else timeText,
            )
            val target = if (ongoing) main.end else main.start
            val accent = if (ongoing) R.color.wg_acc else R.color.wg_brk_text
            val staticSp = 17f
            if (!showCountdown) {
                // 倒计时关：右列两行静态文字「下课 / 11:50」或「上课 / 10:10」。
                v.setViewVisibility(R.id.wg_main_label, View.VISIBLE)
                v.setViewVisibility(R.id.wg_main_chrono, View.GONE)
                v.setViewVisibility(R.id.wg_main_static, View.VISIBLE)
                v.setTextViewText(R.id.wg_main_label, if (ongoing) "下课" else "上课")
                resColor(ctx, v, R.id.wg_main_label, "setTextColor", R.color.wg_t3)
                v.setTextViewText(R.id.wg_main_static, hm(target))
                v.setTextViewTextSize(R.id.wg_main_static, TypedValue.COMPLEX_UNIT_SP, staticSp)
            } else if (target - now > HOUR) {
                // >60 分钟：不用 Chronometer（避免 h:mm:ss 撑宽），改为静态「下课 / 11:50」或
                // 「上课 / 10:10」，与倒计时相同的两行列宽。
                v.setViewVisibility(R.id.wg_main_label, View.VISIBLE)
                v.setViewVisibility(R.id.wg_main_chrono, View.GONE)
                v.setViewVisibility(R.id.wg_main_static, View.VISIBLE)
                v.setTextViewText(R.id.wg_main_label, if (ongoing) "下课" else "上课")
                resColor(ctx, v, R.id.wg_main_label, "setTextColor", R.color.wg_t3)
                v.setTextViewText(R.id.wg_main_static, hm(target))
                v.setTextViewTextSize(R.id.wg_main_static, TypedValue.COMPLEX_UNIT_SP, staticSp)
            } else {
                v.setViewVisibility(R.id.wg_main_label, View.VISIBLE)
                v.setViewVisibility(R.id.wg_main_chrono, View.VISIBLE)
                v.setViewVisibility(R.id.wg_main_static, View.GONE)
                v.setTextViewText(R.id.wg_main_label, if (ongoing) "距下课" else "距上课")
                resColor(ctx, v, R.id.wg_main_label, "setTextColor", accent)
                resColor(ctx, v, R.id.wg_main_chrono, "setTextColor", accent)
                val base = SystemClock.elapsedRealtime() + (target - now)
                v.setChronometerCountDown(R.id.wg_main_chrono, true)
                v.setChronometer(R.id.wg_main_chrono, base, "%s", true)
            }
            val minutesLeft = (target - now + MINUTE - 1) / MINUTE
            v.setContentDescription(
                R.id.wg_main,
                "${main.name}，${main.location}，${main.nodes}，" +
                    (if (ongoing) "距下课" else "距上课") + "${minutesLeft}分钟",
            )
            v.setOnClickPendingIntent(R.id.wg_main, openPending(ctx, 6))

            val count = (prefs?.optInt("courseCount", 2) ?: 2).let { if (it in 1..3) it else 2 }
            val follows = when (count) {
                1 -> emptyList()
                3 -> listOf("compact", "compact")
                else -> listOf("main")
            }
            val height = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 168)
                .let { if (it > 0) it else 168 }
            val showCount = prefs?.optBoolean("showCount", true) ?: true
            val (rows, more, badge) = widgetLayout(pending.size - 1, height, follows, showCount)
            v.setViewVisibility(R.id.wg_main2, View.GONE)
            v.setViewVisibility(R.id.wg_rows, View.GONE)
            v.setViewVisibility(R.id.wg_row1, View.GONE)
            v.setViewVisibility(R.id.wg_row2, View.GONE)
            if (rows > 0 && follows.firstOrNull() == "main") {
                val second = pending[1]
                v.setViewVisibility(R.id.wg_main2, View.VISIBLE)
                barColor(ctx, v, R.id.wg_main2_bar, second.color, second.colorDark)
                v.setTextViewText(R.id.wg_main2_name, second.name)
                v.setTextViewText(R.id.wg_main2_loc, second.location)
                v.setViewVisibility(R.id.wg_main2_loc, if (second.location.isEmpty()) View.GONE else View.VISIBLE)
                val secondTime = second.periodTime.ifEmpty { "${hm(second.start)}-${hm(second.end)}" }
                val secondTeacher = second.teacherLabel
                val secondTeacherText = (if (second.location.isEmpty()) "" else " · ") + secondTeacher
                val fitsTeacher = secondTeacher.isNotEmpty() &&
                    textPx(ctx, second.location + secondTeacherText + " · " + secondTime) <= subAvail
                v.setViewVisibility(R.id.wg_main2_teacher, if (fitsTeacher) View.VISIBLE else View.GONE)
                v.setTextViewText(R.id.wg_main2_teacher, secondTeacherText)
                v.setTextViewText(R.id.wg_main2_time,
                    (if (second.location.isNotEmpty() || fitsTeacher) " · " else "") + secondTime)
                v.setTextViewText(R.id.wg_main2_start, hm(second.start))
                v.setOnClickPendingIntent(R.id.wg_main2, openPending(ctx, 7))
            } else if (rows > 0) {
                v.setViewVisibility(R.id.wg_rows, View.VISIBLE)
                val rowIds = arrayOf(
                    intArrayOf(R.id.wg_row1, R.id.wg_row1_bar, R.id.wg_row1_name, R.id.wg_row1_loc, R.id.wg_row1_time),
                    intArrayOf(R.id.wg_row2, R.id.wg_row2_bar, R.id.wg_row2_name, R.id.wg_row2_loc, R.id.wg_row2_time),
                )
                for (i in 0 until rows) {
                    val c = pending[i + 1]
                    val ids = rowIds[i]
                    v.setViewVisibility(ids[0], View.VISIBLE)
                    barColor(ctx, v, ids[1], c.color, c.colorDark)
                    v.setTextViewText(ids[2], c.name)
                    v.setTextViewText(ids[3], c.location)
                    v.setTextViewText(ids[4], c.periodTime.ifEmpty { "${hm(c.start)}-${hm(c.end)}" })
                    v.setOnClickPendingIntent(ids[0], openPending(ctx, 8 + i))
                }
            }
            v.setViewVisibility(R.id.wg_header_more, if (badge > 0) View.VISIBLE else View.GONE)
            v.setTextViewText(R.id.wg_header_more, "+$badge")
            val last = pending.size == 1
            v.setViewVisibility(R.id.wg_more, if (more > 0 || last) View.VISIBLE else View.GONE)
            v.setTextViewText(R.id.wg_more, if (more > 0) "还有 $more 节 · 点开查看 ›" else "今天最后一节")
            resColor(ctx, v, R.id.wg_more, "setTextColor", R.color.wg_t3)
            mgr.updateAppWidget(widgetId, v)
        }

        /**
         * 返回 (主块之后显示的块数, 底行「还有 N 节」N, 头部「+N」N)。与 Dart `widgetLayout` 同规则：
         * 高 < 140dp → 只留主块 + 头部 +N；课程数 1 → 只 1 块（follows 为空），底行 N = 全部剩余；
         * 否则最多 follows.size 块（main 块 50dp，compact 行 24dp，前置间距 4），放不下底行先改头部 +N 再减块。
         */
        fun widgetLayout(
            remaining: Int, heightDp: Int, follows: List<String>,
            showCount: Boolean,
        ): Triple<Int, Int, Int> {
            fun n(x: Int) = if (showCount) x else 0
            if (heightDp < 140) return Triple(0, 0, n(remaining))
            // spec §11：上 10 + 头部 20 + 6 + 第 1 块 50 + 下 8；后续块前间距 4，主块样式 50 / 紧凑行 24。
            val avail = heightDp - (10 + 20 + 6 + 50 + 8)
            fun used(k: Int) = if (k == 0) 0 else 4 + follows.take(k).sumOf { if (it == "main") 50 else 24 }
            var rows = minOf(remaining, follows.size)
            val needLine = showCount && remaining - rows > 0
            if (used(rows) + (if (needLine) 16 else 0) <= avail) {
                return Triple(rows, n(remaining - rows), 0)
            }
            while (rows > 0 && used(rows) > avail) rows--
            return Triple(rows, 0, n(remaining - rows))
        }

        /** 下一个需要重绘的时刻：任一上课 / 下课、上课 / 下课前一小时（静态行↔倒计时）、次日 00:01。
         * 与 Dart `nextWidgetRefreshAt` 同规则；4×2 / 2×2 共用，排闹钟时另加 1 秒避开边界。
         */
        fun nextRefreshAt(ctx: Context, now: Long): Long {
            val cal = Calendar.getInstance().apply {
                timeInMillis = now
                add(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 1)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }
            var next = cal.timeInMillis
            for (d in days(payload(ctx))) for (it in d.items) {
                for (t in longArrayOf(it.start - HOUR, it.start, it.end - HOUR, it.end)) {
                    if (t > now && t < next) next = t
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
                    am.setWindow(AlarmManager.RTC, at - MINUTE, 2 * MINUTE, pi)
                }
            } catch (_: SecurityException) {
                am.setWindow(AlarmManager.RTC, at - MINUTE, 2 * MINUTE, pi)
            }
        }
    }
}
