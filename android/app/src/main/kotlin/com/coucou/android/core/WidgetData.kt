package com.coucou.android.core

import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState

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
