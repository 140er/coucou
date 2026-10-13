package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent

/**
 * The Solo widget: Mochi in the state of the most urgent agent, its name and one state word. Drawn by [WidgetHub] when
 * something changes (updatePeriodMillis = 0). A tap opens that agent, or the app when none is running. It only opens things: nothing is changed from here.
 */
class SoloWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        /** Mochi's picture is drawn this many dp wide; the system scales it to the widget. */
        private const val MOCHI_DP = 96

        fun views(context: Context, c: WidgetContent): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_solo)
            val top = c.top
            val px = (MOCHI_DP * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
            v.setImageViewBitmap(R.id.solo_mochi, MochiBitmap.of(c.mood, px))
            val word = top?.stateWord ?: c.headline
            v.setContentDescription(R.id.solo_mochi, context.getString(R.string.widget_mochi_description, word.lowercase()))
            v.setTextViewText(R.id.solo_name, top?.name ?: c.headline)
            v.setTextColor(R.id.solo_name, top?.argb ?: c.tone.argb)
            v.setTextViewText(R.id.solo_state, top?.stateWord.orEmpty())
            v.setViewVisibility(R.id.solo_state, if (top == null) View.GONE else View.VISIBLE)
            if (c.waiting > 0) {
                v.setTextViewText(R.id.solo_badge, c.waiting.toString())
                v.setContentDescription(R.id.solo_badge, context.getString(R.string.widget_badge_description, c.waiting))
                v.setViewVisibility(R.id.solo_badge, View.VISIBLE)
            } else {
                v.setViewVisibility(R.id.solo_badge, View.GONE)
            }
            v.setOnClickPendingIntent(
                R.id.solo_root,
                if (top != null) WidgetHub.openSession(context, WidgetHub.CODE_SOLO, top.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_SOLO),
            )
            return v
        }
    }
}
