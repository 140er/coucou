package com.coucou.android.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.coucou.android.R
import com.coucou.android.core.WidgetContent

/**
 * The Usage Ring widget: a ring drawn to a bitmap for the plan usage the computer sent (its switch is on), with the
 * percentage in the middle. If plan usage is off it says "Turn on plan usage in the app"; if the computer is not there, that
 * it is waiting for it. A tap opens the app. It only shows what the computer already sent to this phone.
 */
class UsageRingWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetHub.refresh(context, manager, ids) { c, w -> views(c, w) }

    companion object {
        fun views(context: Context, c: WidgetContent): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_ring)
            val ring = c.ring
            WidgetHub.paint(v, R.id.ring_root, R.id.ring_tint, ring?.tone ?: com.coucou.android.core.WidgetTone.MUTED)
            if (ring != null) {
                v.setViewVisibility(R.id.ring_area, View.VISIBLE)
                v.setViewVisibility(R.id.ring_label, View.VISIBLE)
                v.setViewVisibility(R.id.ring_off, View.GONE)
                v.setImageViewBitmap(R.id.ring_image, RingBitmap.of(ring, WidgetHub.px(context, 96)))
                v.setTextViewText(R.id.ring_pct, "${ring.pct}%")
                v.setTextViewText(R.id.ring_label, ring.label)
                v.setContentDescription(R.id.ring_root, context.getString(R.string.widget_ring_cd, ring.plan, ring.pct))
            } else {
                v.setViewVisibility(R.id.ring_area, View.GONE)
                v.setViewVisibility(R.id.ring_label, View.GONE)
                v.setViewVisibility(R.id.ring_off, View.VISIBLE)
                v.setTextViewText(R.id.ring_off_text, if (c.connected) context.getString(R.string.widget_usage_off) else c.emptyLine.orEmpty())
                v.setContentDescription(R.id.ring_root, context.getString(R.string.widget_ring_label))
            }
            v.setOnClickPendingIntent(R.id.ring_root, WidgetHub.openApp(context, WidgetHub.CODE_RING))
            return v
        }
    }
}
