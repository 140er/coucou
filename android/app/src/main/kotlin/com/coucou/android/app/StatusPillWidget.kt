package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent

/**
 * The Status Pill widget: one slim line, a dot in the state's tone, the name of the most urgent agent and its state word.
 * With no agent, the headline and the one clear line. Drawn by [WidgetHub] when something changes (updatePeriodMillis = 0).
 * A tap opens that agent, or the app. It only opens things.
 */
class StatusPillWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        fun views(context: Context, c: WidgetContent): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_pill)
            WidgetHub.paint(v, R.id.pill_root, R.id.pill_tint, c.look)
            val top = c.top
            val name = top?.name ?: c.headline
            val state = top?.stateWord ?: c.emptyLine.orEmpty()
            v.setTextViewText(R.id.pill_name, name)
            v.setTextViewText(R.id.pill_state, state)
            v.setImageViewResource(R.id.pill_dot, if (top == null && !c.connected) R.drawable.ic_widget_offline else R.drawable.widget_dot)
            v.setInt(R.id.pill_dot, "setColorFilter", (top?.tone ?: c.look).argb)
            v.setContentDescription(R.id.pill_root, context.getString(R.string.widget_pill_cd, name, state))
            v.setOnClickPendingIntent(
                R.id.pill_root,
                if (top != null) WidgetHub.openSession(context, WidgetHub.CODE_PILL, top.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_PILL),
            )
            return v
        }
    }
}
