package com.coucou.android.core

import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiConst
import com.coucou.android.mochi.Rgb
import kotlin.math.roundToInt

/**
 * How loud a widget looks: the colour of its dot, badge, glow and gradient. Taken from the app's own state colours
 * ([MochiConst]), so a Widget and Mochi on Home always agree. Waiting is orange, working blue, done green.
 */
enum class WidgetTone(val rgb: Rgb) {
    MUTED(MochiConst.C_SLEEPING),
    WORKING(MochiConst.C_WORKING),
    ATTENTION(MochiConst.C_APPROVAL),
    DONE(MochiConst.C_FINISHED),
    TROUBLE(MochiConst.C_ERROR),
    ;

    /** Opaque ARGB. */
    val argb: Int get() = 0xFF000000.toInt() or (c(rgb.r) shl 16) or (c(rgb.g) shl 8) or c(rgb.b)

    companion object {
        private fun c(v: Double) = (v.coerceIn(0.0, 1.0) * 255).roundToInt()

        /** The tone of one agent's state; a computer that is not connected is always muted. */
        fun of(state: BotState, connected: Boolean = true): WidgetTone = if (!connected) MUTED else when (state) {
            BotState.APPROVAL, BotState.QUESTION -> ATTENTION
            BotState.WORKING, BotState.THINKING, BotState.SEARCHING -> WORKING
            BotState.FINISHED -> DONE
            BotState.ERROR, BotState.RATELIMIT, BotState.DIZZY -> TROUBLE
            BotState.IDLE, BotState.SLEEPING -> MUTED
        }
    }
}

/** One agent on a widget: who it is, a plain state word and its colour. Only names, state words and colours. */
data class WidgetTile(val pillId: String, val name: String, val state: BotState, val stateWord: String, val argb: Int)

/**
 * Everything the Solo and List widgets draw, as plain data so two pushes can be compared and the identical one skipped.
 * Built from the same sessions, order and wording as [GlanceBuilder], so the widgets never say anything the notification,
 * the tile and the first widget do not.
 */
data class WidgetContent(
    val headline: String,
    val tone: GlanceTone,
    val connected: Boolean,
    /** Requests and questions waiting for the user. */
    val waiting: Int,
    /** Most urgent first. Empty while the computer is not connected. */
    val tiles: List<WidgetTile>,
) {
    /** The agent Solo shows. */
    val top: WidgetTile? get() = tiles.firstOrNull()

    /** The look of the whole widget: orange while something waits for you, else the top agent's tone, muted when nothing runs. */
    val look: WidgetTone get() = when {
        !connected -> WidgetTone.MUTED
        waiting > 0 -> WidgetTone.ATTENTION
        else -> top?.let { WidgetTone.of(it.state) } ?: WidgetTone.MUTED
    }

    /** The state Mochi is drawn in: the top agent's, else calm when connected and asleep when not. */
    val mood: BotState get() = top?.state ?: if (connected) BotState.IDLE else BotState.SLEEPING
}

object WidgetData {
    /** Rows on the List widget. */
    const val MAX_ROWS = 5
    private val FALLBACK = GlanceTone.CALM.argb

    fun build(glance: Glance, sessions: List<SessionInfo>, nameOf: (String) -> String): WidgetContent {
        val tiles = if (!glance.connected) emptyList() else sessions
            .sortedBy { GlanceBuilder.rank(it.state) }
            .take(MAX_ROWS)
            .map { WidgetTile(it.pillId, nameOf(it.pillId), it.state, GlanceBuilder.lineOf(it), colourOf(it)) }
        return WidgetContent(glance.headline, glance.tone, glance.connected, glance.waiting, tiles)
    }

    /** The session's own colour, else its pill's, else grey. */
    private fun colourOf(s: SessionInfo): Int =
        parse(s.color) ?: parse(Pills.byId(s.pillId)?.colorHex) ?: FALLBACK

    /** "#RRGGBB" to opaque ARGB; null for anything else. */
    fun parse(hex: String?): Int? {
        val h = hex?.trim() ?: return null
        if (h.length != 7 || h[0] != '#') return null
        val digits = h.substring(1)
        // toIntOrNull accepts a sign, which is not a colour.
        if (!digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return 0xFF000000.toInt() or digits.toInt(16)
    }
}
