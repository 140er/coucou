package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.LaunchScreen
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetTone

/**
 * The Mochi Big widget: a large Mochi with a glow and a speech bubble that says who is doing what in plain words
 * ([WidgetContent.bubble]: a name and a state, never a command or a file). Drawn by [WidgetHub] when something changes
 * (updatePeriodMillis = 0). A tap on the card opens the top agent, or the app. Below the status line are buttons (Home, Chat, Settings, Recent, the top agent, Pair again): none when the card is small, one row of four, then two rows; they only open things.
 */
class MochiBigWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        // Height in dp, so that Mochi keeps at least 40% of the card: under 290 no buttons, from 290 one row of four, from 400 two rows.
        private val MEDIUM_AT = SizeF(0f, 290f)
        private val LARGE_AT = SizeF(0f, 400f)

        private class Tile(val view: Int, val screen: LaunchScreen?)

        // Home, Chat, Settings, Recent; then the top agent (a session, not a screen) and Pair again.
        private val TILES = listOf(
            Tile(R.id.big_tile_home, LaunchScreen.HOME),
            Tile(R.id.big_tile_chat, LaunchScreen.CHAT),
            Tile(R.id.big_tile_settings, LaunchScreen.SETTINGS),
            Tile(R.id.big_tile_recent, LaunchScreen.RECENT),
            Tile(R.id.big_tile_session, null),
            Tile(R.id.big_tile_pair, LaunchScreen.PAIR),
        )

        fun views(context: Context, c: WidgetContent): RemoteViews =
            WidgetHub.responsive(MEDIUM_AT, LARGE_AT) { size -> render(context, c, size) }

        private fun render(context: Context, c: WidgetContent, size: WidgetHub.Size): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_big)
            WidgetHub.paint(v, R.id.big_root, R.id.big_tint, c.look)
            val top = c.top
            val large = size == WidgetHub.Size.LARGE
            val small = size == WidgetHub.Size.SMALL

            v.setTextViewText(R.id.big_bubble, c.bubble)
            v.setTextViewTextSize(R.id.big_bubble, TypedValue.COMPLEX_UNIT_SP, if (large) 19f else if (small) 14f else 16f)
            v.setImageViewBitmap(R.id.big_mochi, MochiBitmap.of(c.mood, WidgetHub.px(context, if (large) 240 else if (small) 110 else 180), glow = true))
            v.setContentDescription(R.id.big_mochi, context.getString(R.string.widget_mochi_description, (top?.stateWord ?: c.headline).lowercase()))

            if (top != null) {
                v.setViewVisibility(R.id.big_row, View.VISIBLE)
                v.setInt(R.id.big_dot, "setColorFilter", top.tone.argb)
                v.setTextViewText(R.id.big_name, top.name)
                v.setTextViewText(R.id.big_state, top.stateWord)
            } else {
                v.setViewVisibility(R.id.big_row, View.GONE)
            }

            // The buttons: none when small, one row of four by default, two rows when tall. They only open things.
            v.setViewVisibility(R.id.big_buttons, if (small) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.big_buttons_b, if (large) View.VISIBLE else View.GONE)
            val tile = if (c.look == WidgetTone.ATTENTION) R.drawable.widget_tile_bg_attention else R.drawable.widget_tile_bg
            TILES.forEachIndexed { i, t ->
                v.setInt(t.view, "setBackgroundResource", tile)
                val open = when {
                    t.screen != null -> WidgetHub.openScreen(context, WidgetHub.CODE_BIG_BUTTON + i, t.screen)
                    top != null -> WidgetHub.openSession(context, WidgetHub.CODE_BIG_BUTTON + i, top.pillId)
                    else -> WidgetHub.openScreen(context, WidgetHub.CODE_BIG_BUTTON + i, LaunchScreen.HOME) // no agent yet: the app
                }
                v.setOnClickPendingIntent(t.view, open)
            }

            if (c.waiting > 0) {
                v.setTextViewText(R.id.big_badge, c.waiting.toString())
                v.setContentDescription(R.id.big_badge, context.getString(R.string.widget_badge_description, c.waiting))
                v.setViewVisibility(R.id.big_badge, View.VISIBLE)
            } else {
                v.setViewVisibility(R.id.big_badge, View.GONE)
            }
            v.setOnClickPendingIntent(
                R.id.big_root,
                if (top != null) WidgetHub.openSession(context, WidgetHub.CODE_BIG, top.pillId) else WidgetHub.openApp(context, WidgetHub.CODE_BIG),
            )
            return v
        }
    }
}
