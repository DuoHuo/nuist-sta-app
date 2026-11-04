package dev.duohuo.nuist_sta_app.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import dev.duohuo.nuist_sta_app.NotifyStore
import dev.duohuo.nuist_sta_app.TimetableWidget2x2Provider
import dev.duohuo.nuist_sta_app.TimetableWidgetProvider
import java.util.Calendar

/** 两种尺寸共用刷新闹钟，数据同步和系统事件统一交给 Glance 接收器。 */
internal object TimetableWidgetUpdates {
    const val ACTION_TICK = "dev.duohuo.nuist_sta_app.WIDGET_TICK"
    const val ACTION_REFRESH = "dev.duohuo.nuist_sta_app.WIDGET_REFRESH"
    const val MINUTE = 60_000L
    private const val HOUR = 60 * MINUTE
    private val receivers = listOf(TimetableWidgetProvider::class.java, TimetableWidget2x2Provider::class.java)

    fun refresh(context: Context) {
        TimetableWidgetData.invalidate(context)
        val manager = AppWidgetManager.getInstance(context)
        for (receiver in receivers) {
            val component = ComponentName(context, receiver)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                // 系统更新广播在部分新系统中受保护，应用主动刷新使用自己的显式 action。
                context.sendBroadcast(Intent(ACTION_REFRESH).setComponent(component))
            }
        }
        schedule(context)
    }

    fun save(context: Context, json: String) {
        NotifyStore.prefs(context).edit().putString(NotifyStore.KEY_WIDGET, json).apply()
        refresh(context)
    }

    fun minutes(now: Long, target: Long): Long = ((target - now + MINUTE - 1) / MINUTE).coerceAtLeast(0)

    fun nextRefresh(snapshot: WidgetSnapshot): Long {
        val now = snapshot.now
        var next = Calendar.getInstance().apply {
            timeInMillis = now
            add(Calendar.DAY_OF_MONTH, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        if (!snapshot.usable) return next
        for (course in snapshot.days.flatMap { it.courses }) {
            for (boundary in listOf(course.start - HOUR, course.start, course.end - HOUR, course.end)) {
                if (boundary > now) next = minOf(next, boundary)
            }
        }
        if (snapshot.preferences.showCountdown) {
            snapshot.pending.firstOrNull()?.let { course ->
                val target = if (course.start > now) course.start else course.end
                if (target - now in 1..HOUR) {
                    next = minOf(next, target - (minutes(now, target) - 1) * MINUTE)
                }
            }
        }
        return next
    }

    fun schedule(context: Context) {
        val alarm = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = PendingIntent.getBroadcast(context, 9_000,
            Intent(context, TimetableWidgetProvider::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val manager = AppWidgetManager.getInstance(context)
        if (receivers.none { manager.getAppWidgetIds(ComponentName(context, it)).isNotEmpty() }) {
            alarm.cancel(pending)
            return
        }
        val at = nextRefresh(TimetableWidgetData.read(context)) + 1_000
        try {
            if (NotifyStore.canExact(context)) alarm.setExact(AlarmManager.RTC, at, pending)
            else alarm.set(AlarmManager.RTC, at, pending)
        } catch (_: SecurityException) {
            alarm.set(AlarmManager.RTC, at, pending)
        }
    }
}
