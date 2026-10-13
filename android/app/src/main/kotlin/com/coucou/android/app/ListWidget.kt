package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent

/**
 * The List widget: the headline, then one row per agent (a dot in its colour, its name, a state word). Drawn by
 * [WidgetHub] when something changes (updatePeriodMillis = 0). A tap on a row opens that agent; a tap on the headline
 * opens the app. It only opens things: a request waits for you in the app, behind the fingerprint.
 */
class ListWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        private val ROWS = listOf(
            Row(R.id.list_row0, R.id.list_dot0, R.id.list_name0, R.id.list_state0),
            Row(R.id.list_row1, R.id.list_dot1, R.id.list_name1, R.id.list_state1),
            Row(R.id.list_row2, R.id.list_dot2, R.id.list_name2, R.id.list_state2),
            Row(R.id.list_row3, R.id.list_dot3, R.id.list_name3, R.id.list_state3),
            Row(R.id.list_row4, R.id.list_dot4, R.id.list_name4, R.id.list_state4),
        )

        private class Row(val row: Int, val dot: Int, val name: Int, val state: Int)

        fun views(context: Context, c: WidgetContent): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_list)
            v.setTextViewText(R.id.list_headline, c.headline)
            v.setTextColor(R.id.list_headline, c.tone.argb)
            v.setOnClickPendingIntent(R.id.list_header, WidgetHub.openApp(context, WidgetHub.CODE_LIST_HEADER))
            if (c.waiting > 0) {
                v.setTextViewText(R.id.list_badge, c.waiting.toString())
                v.setContentDescription(R.id.list_badge, context.getString(R.string.widget_badge_description, c.waiting))
                v.setViewVisibility(R.id.list_badge, View.VISIBLE)
            } else {
                v.setViewVisibility(R.id.list_badge, View.GONE)
            }
            ROWS.forEachIndexed { i, r ->
                val tile = c.tiles.getOrNull(i)
                if (tile == null) {
                    v.setViewVisibility(r.row, View.GONE)
                    return@forEachIndexed
                }
                v.setViewVisibility(r.row, View.VISIBLE)
                v.setTextColor(r.dot, tile.argb)
                v.setTextViewText(r.name, tile.name)
                v.setTextViewText(r.state, tile.stateWord)
                v.setOnClickPendingIntent(r.row, WidgetHub.openSession(context, WidgetHub.CODE_LIST_ROW + i, tile.pillId))
            }
            return v
        }
    }
}
