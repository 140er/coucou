package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent

/**
 * The Today widget: how many agent tasks finished today. The count is kept on this phone only ([TodayStore]) and starts
 * again at local midnight: the system's "the date changed" broadcast redraws it, so nothing runs on a timer. A tap opens the app.
 */
class TodayWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action in DAY_CHANGED) WidgetHub.refreshAll(context)
    }

    companion object {
        private val DAY_CHANGED = setOf(Intent.ACTION_DATE_CHANGED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED)

        fun views(context: Context, c: WidgetContent): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_today)
            WidgetHub.paint(v, R.id.today_root, R.id.today_tint, c.todayLook)
            v.setImageViewBitmap(R.id.today_face, MochiBitmap.of(c.todayMood, WidgetHub.px(context, 72), glow = true))
            v.setContentDescription(R.id.today_face, context.getString(R.string.widget_mochi_description, c.todayMood.key))
            v.setTextViewText(R.id.today_count, c.today.toString())
            v.setContentDescription(R.id.today_root, context.getString(R.string.widget_today_cd, c.today))
            v.setOnClickPendingIntent(R.id.today_root, WidgetHub.openApp(context, WidgetHub.CODE_TODAY))
            return v
        }
    }
}
