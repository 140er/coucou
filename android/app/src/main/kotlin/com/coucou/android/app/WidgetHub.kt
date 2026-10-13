package com.coucou.android.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.SizeF
import android.widget.RemoteViews
import com.coucou.android.MainActivity
import com.coucou.android.R
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetTone
import kotlin.math.roundToInt

/**
 * The one place that pushes the Widgets (Solo, List, Mochi Big, Status Pill, Waiting Alert, Usage Ring, Today and Mochi Mood). The app calls [update] on every change of sessions, requests and
 * link (from AppModel.pushGlance); a push whose content is the same as the last one is dropped, so a change that does not
 * show on a widget costs nothing. There is no timer: a widget is drawn when something changes or when it is added.
 */
object WidgetHub {
    private class Kind(val provider: Class<out AppWidgetProvider>, val views: (Context, WidgetContent) -> RemoteViews)

    private val widgets = listOf(
        Kind(SoloWidget::class.java) { c, w -> SoloWidget.views(c, w) },
        Kind(ListWidget::class.java) { c, w -> ListWidget.views(c, w) },
        Kind(MochiBigWidget::class.java) { c, w -> MochiBigWidget.views(c, w) },
        Kind(StatusPillWidget::class.java) { c, w -> StatusPillWidget.views(c, w) },
        Kind(WaitingAlertWidget::class.java) { c, w -> WaitingAlertWidget.views(c, w) },
        Kind(UsageRingWidget::class.java) { c, w -> UsageRingWidget.views(c, w) },
        Kind(TodayWidget::class.java) { c, w -> TodayWidget.views(c, w) },
        Kind(MoodWidget::class.java) { c, w -> MoodWidget.views(c, w) },
    )

    private var last: WidgetContent? = null

    /** Pushes [content] to every Widget of the family on the home screen (none: nothing happens). */
    @Synchronized
    fun update(context: Context, content: WidgetContent) {
        if (content == last) return
        runCatching {
            val manager = AppWidgetManager.getInstance(context)
            var pushed = false
            for (kind in widgets) {
                val ids = manager.getAppWidgetIds(ComponentName(context, kind.provider))
                if (ids.isEmpty()) continue
                val rendered = kind.views(context, content)
                for (id in ids) manager.updateAppWidget(id, rendered)
                pushed = true
            }
            // With no widget on screen nothing is remembered, so the first one added is drawn.
            if (pushed) last = content
        }
    }

    /** Draws the widgets the system just created or resized, from what the app says now. */
    fun refresh(context: Context, manager: AppWidgetManager, ids: IntArray, views: (Context, WidgetContent) -> RemoteViews) {
        val rendered = views(context, current(context))
        for (id in ids) runCatching { manager.updateAppWidget(id, rendered) }
    }

    /** The three sizes a responsive Widget is drawn for (Android 12 and later picks one by the room it has). */
    enum class Size { SMALL, MEDIUM, LARGE }

    /**
     * One picture per size on Android 12 (API 31) and later; on Android 11 there is no size map, so the plain MEDIUM
     * picture is the only one. [mediumAt] and [largeAt] are where those sizes start, in dp (the system picks the largest
     * entry that fits, so SMALL starts at zero); [draw] builds the picture for a size from the same layout.
     */
    fun responsive(mediumAt: SizeF, largeAt: SizeF, draw: (Size) -> RemoteViews): RemoteViews =
        if (Build.VERSION.SDK_INT >= 31) {
            RemoteViews(mapOf(SizeF(0f, 0f) to draw(Size.SMALL), mediumAt to draw(Size.MEDIUM), largeAt to draw(Size.LARGE)))
        } else {
            draw(Size.MEDIUM)
        }

    /** dp to pixels on this screen, at least 1. */
    fun px(context: Context, dp: Int): Int = (dp * context.resources.displayMetrics.density).roundToInt().coerceAtLeast(1)

    /** The card and its gradient for a tone: an orange border while something waits, else the plain border; the tone's tint over it. */
    fun paint(v: RemoteViews, root: Int, tint: Int, tone: WidgetTone) {
        v.setInt(root, "setBackgroundResource", if (tone == WidgetTone.ATTENTION) R.drawable.widget_card_attention else R.drawable.widget_card)
        v.setInt(tint, "setBackgroundResource", tintOf(tone))
    }

    private fun tintOf(tone: WidgetTone): Int = when (tone) {
        WidgetTone.MUTED -> R.drawable.widget_tint_muted
        WidgetTone.WORKING -> R.drawable.widget_tint_working
        WidgetTone.ATTENTION -> R.drawable.widget_tint_attention
        WidgetTone.DONE -> R.drawable.widget_tint_done
        WidgetTone.TROUBLE -> R.drawable.widget_tint_trouble
    }

    /** What the app says now. */
    private fun current(context: Context): WidgetContent = (context.applicationContext as CoucouApp).model.widgetContent()

    /** Draws every Widget again from what the app says now, even if nothing looks different (a new day, a new time zone). */
    @Synchronized
    fun refreshAll(context: Context) {
        last = null
        update(context, current(context))
    }

    /** Opens the app on Home. */
    fun openApp(context: Context, code: Int): PendingIntent {
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, code, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /**
     * Opens one session. It goes through LaunchActivity (our own, not exported) with an explicit component, never through
     * MainActivity's extras. Each call needs its own [code]: PendingIntents are told apart by code, not by extras.
     */
    fun openSession(context: Context, code: Int, pillId: String): PendingIntent {
        val open = Intent(context, LaunchActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(LaunchActivity.EXTRA_SESSION, pillId)
        return PendingIntent.getActivity(context, code, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Request codes: one range per widget, one code per row, so no two PendingIntents are the same. */
    const val CODE_SOLO = 0x5100
    const val CODE_LIST_HEADER = 0x5200
    const val CODE_LIST_ROW = 0x5300
    const val CODE_BIG = 0x5400
    const val CODE_PILL = 0x5500
    const val CODE_ALERT = 0x5600
    const val CODE_RING = 0x5700
    const val CODE_TODAY = 0x5800
    const val CODE_MOOD = 0x5900
}
