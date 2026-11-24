package dev.duohuo.nuist_sta_app

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray

/**
 * 上课提醒：用 AlarmManager 排 Flutter 算好的提醒（已合并同时开始的课、7 天窗口）。
 * 有精确闹钟权限 → setExactAndAllowWhileIdle；否则退化为 setAndAllowWhileIdle（可能晚几分钟）。
 */
object ReminderScheduler {
    const val CHANNEL_ID = "class_reminder"
    private const val ACTION_FIRE = "dev.duohuo.nuist_sta_app.REMINDER_FIRE"
    private const val BASE_CODE = 10_000
    /** 闹钟迟到超过这么久就不补发（不补发已错过的提醒）。 */
    private const val LATE_TOLERANCE_MS = 10 * 60 * 1000L

    fun replace(ctx: Context, alarmsJson: String): Map<String, Any?> {
        NotifyStore.prefs(ctx).edit().putString(NotifyStore.KEY_ALARMS, alarmsJson).commit()
        return reschedule(ctx)
    }

    fun cancelAll(ctx: Context): Map<String, Any?> {
        NotifyStore.prefs(ctx).edit().putString(NotifyStore.KEY_ALARMS, "[]").commit()
        return reschedule(ctx)
    }

    /** 按已存列表重排（开机 / 改时间 / 改时区 / 权限变化也走这里）。 */
    fun reschedule(ctx: Context): Map<String, Any?> {
        val diagnostics = mutableListOf<Map<String, Any?>>()
        val am = ctx.getSystemService(AlarmManager::class.java) ?: return mapOf(
            "diagnostics" to listOf(mapOf("reason_code" to "alarm_service_unavailable", "stage" to "reminder.schedule")))
        val prefs = NotifyStore.prefs(ctx)
        val old = prefs.getInt(NotifyStore.KEY_ALARM_COUNT, 0)
        for (i in 0 until old) {
            pending(ctx, i, null, PendingIntent.FLAG_NO_CREATE)?.let {
                am.cancel(it)
                it.cancel()
            }
        }
        val arr = try {
            JSONArray(prefs.getString(NotifyStore.KEY_ALARMS, "[]"))
        } catch (error: Exception) {
            diagnostics.add(notifyFailureDetails(error, "reminder.decode") + ("reason_code" to "alarm_cache_invalid_json"))
            JSONArray()
        }
        if (arr.length() > 0) ensureChannel(ctx)
        val now = System.currentTimeMillis()
        val exact = NotifyStore.canExact(ctx)
        if (!exact && arr.length() > 0) diagnostics.add(mapOf("reason_code" to "exact_alarm_permission_unavailable", "stage" to "reminder.schedule"))
        var n = 0
        try {
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val fireAt = NotifyStore.parseLocal(o.optString("fireAt")) ?: continue
                val start = NotifyStore.parseLocal(o.optString("classStart")) ?: continue
                if (fireAt <= now) continue
                val intent = Intent(ctx, ReminderReceiver::class.java).apply {
                    action = ACTION_FIRE
                    putExtra("title", o.optString("title"))
                    putExtra("body", o.optString("body"))
                    putExtra("fireAt", fireAt)
                    putExtra("classStart", start)
                }
                val pi = pending(ctx, n, intent, PendingIntent.FLAG_UPDATE_CURRENT) ?: continue
                try {
                    if (exact) {
                        am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pi)
                    } else {
                        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pi)
                    }
                    n++
                } catch (error: SecurityException) {
                    diagnostics.add(notifyFailureDetails(error, "reminder.schedule") + ("reason_code" to "exact_alarm_permission_revoked"))
                    try {
                        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pi)
                        n++
                    } catch (fallbackError: RuntimeException) {
                        diagnostics.add(notifyFailureDetails(fallbackError, "reminder.schedule") + ("reason_code" to "alarm_schedule_failed"))
                    }
                } catch (error: RuntimeException) {
                    diagnostics.add(notifyFailureDetails(error, "reminder.schedule") + ("reason_code" to "alarm_schedule_failed"))
                }
            }
        } finally {
            prefs.edit().putInt(NotifyStore.KEY_ALARM_COUNT, n).commit()
        }
        return mapOf("scheduled_count" to n, "exact" to exact, "diagnostics" to diagnostics)
    }

    private fun pending(ctx: Context, index: Int, intent: Intent?, flag: Int): PendingIntent? {
        val i = intent ?: Intent(ctx, ReminderReceiver::class.java).apply { action = ACTION_FIRE }
        return PendingIntent.getBroadcast(
            ctx, BASE_CODE + index, i, flag or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun ensureChannel(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "上课提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "上课前提醒"
            },
        )
    }

    fun show(ctx: Context, intent: Intent, diagnostics: MutableList<Map<String, Any?>> = mutableListOf()) {
        val now = System.currentTimeMillis()
        val fireAt = intent.getLongExtra("fireAt", 0L)
        val start = intent.getLongExtra("classStart", 0L)
        // 不补发：迟到太多或课已开始。
        if (now - fireAt > LATE_TOLERANCE_MS || now >= start) return
        ensureChannel(ctx)
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val postDenied = Build.VERSION.SDK_INT >= 33 &&
            ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        val channelBlocked = nm?.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE
        if (postDenied || nm == null || !nm.areNotificationsEnabled() || channelBlocked) {
            diagnostics.add(mapOf("reason_code" to "notification_permission_denied", "stage" to "reminder.notify"))
            return
        }
        val tap = PendingIntent.getActivity(
            ctx, (start / 60000L).toInt(), NotifyStore.launchIntent(ctx),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = Notification.Builder(ctx, CHANNEL_ID)
        val body = intent.getStringExtra("body") ?: ""
        val n = b.setSmallIcon(R.drawable.ic_stat_class)
            .setContentTitle(intent.getStringExtra("title") ?: "即将上课")
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setWhen(start)
            .setShowWhen(true)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        try {
            nm.notify((start / 60000L).toInt(), n)
        } catch (error: SecurityException) {
            diagnostics.add(notifyFailureDetails(error, "reminder.notify") + ("reason_code" to "notification_permission_denied"))
            // 未授予通知权限。
        }
    }
}

/** 提醒闹钟到点。 */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val app = context.applicationContext
        TimetableNativeWork.background(app, "reminder.dispatch", "reminder_dispatch_failed", pending::finish) {
            ReminderScheduler.show(app, intent, it)
        }
    }
}

/** 开机 / 升级 / 改时间 / 改时区 / 精确闹钟权限变化：重排提醒并刷新小组件。 */
class NotifySystemEventReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val app = context.applicationContext
        TimetableNativeWork.background(app, "reminder.system_dispatch", "reminder_reschedule_failed", pending::finish) { diagnostics ->
            try {
                @Suppress("UNCHECKED_CAST")
                diagnostics.addAll(ReminderScheduler.reschedule(app)["diagnostics"] as? List<Map<String, Any?>> ?: emptyList())
            } catch (error: Exception) {
                diagnostics.add(notifyFailureDetails(error, "reminder.system_reschedule") + ("reason_code" to "reminder_reschedule_failed"))
            }
            try { TimetableWidgetProvider.refreshAll(app) } catch (error: Exception) {
                diagnostics.add(notifyFailureDetails(error, "widget.system_refresh") + ("reason_code" to "widget_refresh_failed"))
            }
        }
    }
}
