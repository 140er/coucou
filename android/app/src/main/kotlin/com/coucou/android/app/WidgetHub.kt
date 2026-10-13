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
import com.coucou.android.core.WidgetContent
import com.coucou.android.core.WidgetData

/**
 * The one place that pushes the Solo and List widgets. The app calls [update] on every change of sessions, requests and
 * link (from AppModel.pushGlance); a push whose content is the same as the last one is dropped, so a change that does not
 * show on a widget costs nothing. There is no timer: a widget is drawn when something changes or when it is added.
 */
object WidgetHub {
    private class Kind(val provider: Class<out AppWidgetProvider>, val views: (Context, WidgetContent) -> RemoteViews)

    private val widgets = listOf(
        Kind(SoloWidget::class.java) { c, w -> SoloWidget.views(c, w) },
        Kind(ListWidget::class.java) { c, w -> ListWidget.views(c, w) },
    )

    private var last: WidgetContent? = null

    /** Pushes [content] to every Solo and List widget on the home screen (none: nothing happens). */
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
        val model = (context.applicationContext as CoucouApp).model
        val content = WidgetData.build(model.glance(), model.sessions, model::agentName)
        val rendered = views(context, content)
        for (id in ids) runCatching { manager.updateAppWidget(id, rendered) }
    }

    /** The three sizes a responsive Widget is drawn for (Android 12 and later picks one by the room it has). */
    enum class Size { SMALL, MEDIUM, LARGE }

    // Where each size starts, in dp. The system picks the largest entry that fits, so SMALL starts at zero.
    private val SMALL_AT = SizeF(0f, 0f)
    private val MEDIUM_AT = SizeF(180f, 110f)
    private val LARGE_AT = SizeF(250f, 180f)

    /**
     * One picture per size on Android 12 and later; on Android 11 (API 30) there is no size map, so the plain MEDIUM
     * picture is the only one. [draw] builds the picture for a size from the same layout.
     */
    fun responsive(draw: (Size) -> RemoteViews): RemoteViews =
        if (Build.VERSION.SDK_INT >= 31) {
            RemoteViews(mapOf(SMALL_AT to draw(Size.SMALL), MEDIUM_AT to draw(Size.MEDIUM), LARGE_AT to draw(Size.LARGE)))
        } else {
            draw(Size.MEDIUM)
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
}
