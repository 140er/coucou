package com.coucou.android.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.coucou.android.core.WidgetData
import com.coucou.android.core.WidgetSample

/**
 * DEBUG BUILDS ONLY (this file lives in src/debug): look at every Widget in every state without a computer.
 *
 * Put the Widgets on the home screen, then, from a computer with the phone connected:
 *
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state disconnected
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state empty
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state working
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state waiting
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state done
 *   adb shell am broadcast -n com.coucou.android/.app.WidgetPreviewReceiver -a com.coucou.android.debug.WIDGET_STATE --es state live
 *
 * `live` goes back to the real state. A chosen state stays on the Widgets (real changes wait) until `live` or until the app
 * process is killed. The states are made up by [WidgetSample]; nothing is read from, or sent to, a computer.
 */
class WidgetPreviewReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val key = intent.getStringExtra("state")?.trim()?.lowercase()
        if (key == "live") {
            WidgetHub.preview(context, null)
            return
        }
        val sample = WidgetSample.parse(key)
        if (sample == null) {
            Log.w("CoucouWidgets", "unknown state '$key': use disconnected, empty, working, waiting, done or live")
            return
        }
        WidgetHub.preview(context, WidgetData.sample(sample, System.currentTimeMillis()))
    }
}
