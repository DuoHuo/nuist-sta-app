package dev.duohuo.nuist_sta_app

import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.os.Build
import java.text.SimpleDateFormat
import java.util.Locale

/** 提醒 / 小组件共用的本地存储与时间工具。数据由 Flutter 侧写入。 */
object NotifyStore {
    private const val PREFS = "nuist_notify_widget"
    const val KEY_ALARMS = "alarms"
    const val KEY_ALARM_COUNT = "alarm_count"
    const val KEY_WIDGET = "widget_payload"
    const val KEY_PENDING_ROUTE = "pending_route"

    /** 点击通知 / 小组件时带给 MainActivity 的 extra。 */
    const val EXTRA_ROUTE = "nuist_route"
    const val ROUTE_TIMETABLE = "/apps/timetable"

    fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 解析 Flutter 写的本地墙上时间 `yyyy-MM-ddTHH:mm`，按**当前**时区换算。 */
    fun parseLocal(s: String?): Long? {
        if (s.isNullOrEmpty()) return null
        return try {
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.US).apply { isLenient = false }
                .parse(s)?.time
        } catch (_: Exception) {
            null
        }
    }

    fun today(now: Long = System.currentTimeMillis()): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now)

    fun canExact(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = ctx.getSystemService(AlarmManager::class.java) ?: return false
        return am.canScheduleExactAlarms()
    }

    fun launchIntent(ctx: Context, route: String = ROUTE_TIMETABLE): Intent =
        Intent(ctx, MainActivity::class.java).apply {
            putExtra(EXTRA_ROUTE, route)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
}
