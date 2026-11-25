package dev.duohuo.nuist_sta_app.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.util.SizeF
import android.widget.RemoteViews
import dev.duohuo.nuist_sta_app.NotifyStore
import dev.duohuo.nuist_sta_app.R
import dev.duohuo.nuist_sta_app.TimetableWeekWidgetFlipReceiver
import dev.duohuo.nuist_sta_app.TimetableWeekWidgetProvider
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import kotlin.math.abs

/** 课程布局在后台生成；发布完整布局和翻周只在主线程串行应用。 */
internal object TimetableWeekWidgetRuntime {
    const val ACTION_FLIP = "dev.duohuo.nuist_sta_app.WIDGET_WEEK_FLIP"
    private const val LAYOUT_VERSION = 11
    private const val PENDING_FLAGS = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    private val main = Handler(Looper.getMainLooper())
    // 只在主线程访问。应用进程死亡后的首次点击才从持久状态恢复。
    private val frames = mutableMapOf<Int, RenderedWeeks>()

    fun render(context: Context, manager: AppWidgetManager, ids: IntArray, force: Boolean = false) {
        if (ids.isEmpty()) return
        val snapshot = TimetableWeekWidgetData.read(context)
        val current = snapshot.displayWeek()
        val next = snapshot.displayWeek(1)
        val config = context.resources.configuration
        // 忽略本次读取的毫秒时刻：共享倒计时闹钟不应重建没有变动的周课表。
        val dataKey = renderKey(listOf(
            LAYOUT_VERSION, NotifyStore.today(snapshot.now), snapshot.state, snapshot.termStartMissing,
            snapshot.reason, snapshot.hasIndependentLocalData, snapshot.preferences, snapshot.periods, current, next,
            config.uiMode and Configuration.UI_MODE_NIGHT_MASK, config.densityDpi, config.fontScale,
            config.locales.toLanguageTags(),
        ))
        val state = state(context)
        for (id in ids) {
            if (!ownsWidget(context, manager, id)) continue
            val size = context.contentSize(manager.getAppWidgetOptions(id))
            val key = "$dataKey:$size"
            val stored = read(state, id)
            if (!force && stored?.renderKey == key) continue
            val currentPlan = TimetableWeekWidgetLayout.plan(snapshot, current, size.width, size.height)
            val nextPlan = next?.let { TimetableWeekWidgetLayout.plan(snapshot, it, size.width, size.height) }
            val views = TimetableWeekWidgetContent(context, size, snapshot, currentPlan, nextPlan).build(
                activity(context, id, settings = false), activity(context, id, settings = true), flipIntent(context, id),
            )
            onMain {
                // 布局生成期间的点击已经更新内存选中态，不能被旧快照覆盖。
                val showNext = (frames[id] ?: stored)?.showNext == true && nextPlan != null
                val frame = RenderedWeeks(key, currentPlan.weekLabel, nextPlan?.weekLabel, showNext)
                views.applyWeekSelection(context, showNext, frame.selectedLabel)
                Trace.beginSection("npp.week.publishFull")
                try {
                    manager.updateAppWidget(id, views)
                } finally {
                    Trace.endSection()
                }
                frames[id] = frame
                write(state, id, frame)
            }
        }
    }

    fun flip(context: Context, manager: AppWidgetManager, id: Int) {
        val state = state(context)
        val frame = frames[id] ?: run {
            if (!ownsWidget(context, manager, id)) return
            read(state, id) ?: return
        }
        if (frame.nextLabel == null) return
        val next = frame.copy(showNext = !frame.showNext)
        val patch = RemoteViews(context.packageName, R.layout.widget_timetable_week).apply {
            applyWeekSelection(context, next.showNext, next.selectedLabel)
        }
        Trace.beginSection("npp.week.publishPartial")
        try {
            manager.partiallyUpdateAppWidget(id, patch)
        } finally {
            Trace.endSection()
        }
        frames[id] = next
        state.edit().putBoolean(selectionKey(id), next.showNext).apply()
    }

    fun clear(context: Context, ids: IntArray) = onMain {
        val edit = state(context).edit()
        ids.forEach { id ->
            frames.remove(id)
            edit.remove(id.toString()).remove(selectionKey(id))
        }
        edit.apply()
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == main.looper) {
            action()
            return
        }
        // 后台接收器在发布结束前保留 goAsync，不会提前结束广播生命周期。
        val task = FutureTask<Unit>({ action() }, Unit)
        check(main.post(task))
        try {
            task.get()
        } catch (error: ExecutionException) {
            throw (error.cause as? Exception ?: error)
        }
    }

    private fun ownsWidget(context: Context, manager: AppWidgetManager, id: Int): Boolean =
        manager.getAppWidgetInfo(id)?.provider == ComponentName(context, TimetableWeekWidgetProvider::class.java)

    private fun activity(context: Context, id: Int, settings: Boolean): PendingIntent {
        val route = if (settings) NotifyStore.ROUTE_TIMETABLE_WIDGET_SETTINGS else NotifyStore.ROUTE_TIMETABLE
        val intent = NotifyStore.launchIntent(context, route).setAction(
            if (settings) NotifyStore.widgetSettingsAction(context) else "${context.packageName}.OPEN_WEEK_WIDGET",
        )
        // PendingIntent 标识不包含 extra；动作和 requestCode 都区分主体/齿轮。
        return PendingIntent.getActivity(context, if (settings) id.inv() else id, intent, PENDING_FLAGS)
    }

    private fun flipIntent(context: Context, id: Int): PendingIntent = PendingIntent.getBroadcast(
        context, id, Intent(context, TimetableWeekWidgetFlipReceiver::class.java)
            .setAction(ACTION_FLIP).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id), PENDING_FLAGS,
    )

    /** 估算当前方向的节数和文字预算；实际行高由宿主测量权重布局。 */
    @Suppress("DEPRECATION")
    private fun Context.contentSize(options: Bundle): SizeF {
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val density = resources.displayMetrics.density
        fun maxOption(min: String, max: String) = maxOf(options.getInt(min), options.getInt(max)).toFloat()
        val width = maxOption(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)
        val height = maxOption(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
        val exact = if (Build.VERSION.SDK_INT >= 31) {
            options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES).orEmpty()
                .filter { it.width > 0f && it.height > 0f }
        } else {
            emptyList()
        }
        val oriented = exact.filter { (it.width > it.height) == landscape }.ifEmpty { exact }
        val selected = oriented.minByOrNull { abs(it.width - width) + abs(it.height - height) }
        return SizeF(
            (selected?.width ?: width.takeIf { it > 0f } ?: (resources.getDimension(R.dimen.wg_week_min_width) / density)).coerceIn(1f, 900f),
            (selected?.height ?: height.takeIf { it > 0f } ?: (resources.getDimension(R.dimen.wg_week_min_height) / density)).coerceIn(1f, 1000f),
        )
    }

    private fun state(context: Context): SharedPreferences = context.getSharedPreferences("week_widget_frames", Context.MODE_PRIVATE)

    private fun selectionKey(id: Int) = "selected_$id"

    private data class RenderedWeeks(val renderKey: String, val currentLabel: String, val nextLabel: String?, val showNext: Boolean) {
        val selectedLabel: String get() = if (showNext) nextLabel ?: currentLabel else currentLabel
    }

    private fun read(state: SharedPreferences, id: Int): RenderedWeeks? {
        val raw = state.getString(id.toString(), null) ?: return null
        return try {
            val frame = JSONObject(raw)
            RenderedWeeks(frame.getString("render"), frame.getString("current"),
                frame.optString("next").takeIf { frame.has("next") },
                state.getBoolean(selectionKey(id), frame.optBoolean("showNext")))
        } catch (_: Exception) {
            null
        }
    }

    private fun write(state: SharedPreferences, id: Int, frame: RenderedWeeks) {
        val json = JSONObject().put("render", frame.renderKey).put("current", frame.currentLabel)
            .put("next", frame.nextLabel)
        state.edit().putString(id.toString(), json.toString()).putBoolean(selectionKey(id), frame.showNext).apply()
    }

    private fun renderKey(inputs: List<Any?>): String =
        MessageDigest.getInstance("SHA-256").digest(inputs.toString().toByteArray()).joinToString("") { "%02x".format(it) }
}
