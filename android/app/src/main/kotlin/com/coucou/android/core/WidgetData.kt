package com.coucou.android.core

import com.coucou.android.link.SessionInfo
import com.coucou.android.link.UsageSnapshot
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
data class WidgetTile(val pillId: String, val name: String, val state: BotState, val stateWord: String, val argb: Int) {
    /** The colour of its dot: the state's tone (the agent's own colour is [argb]). */
    val tone: WidgetTone get() = WidgetTone.of(state)
}

/** The plan usage a ring shows: which plan and window, and how much of it is used. */
data class UsageRing(val plan: String, val window: String, val pct: Int) {
    /** 0 to 1, for the arc. */
    val fraction: Float get() = pct.coerceIn(0, 100) / 100f

    /** "Claude · 5 h". */
    val label: String get() = "$plan · $window"

    /** Green while there is room, orange from half, red from four fifths: the same rule as Home ([PlanText]). */
    val tone: WidgetTone get() = when (PlanText.level(pct)) {
        PlanText.Level.LOW -> WidgetTone.DONE
        PlanText.Level.MEDIUM -> WidgetTone.ATTENTION
        PlanText.Level.HIGH -> WidgetTone.TROUBLE
    }
}

/**
 * Everything the Widgets draw, as plain data so two pushes can be compared and the identical one skipped.
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
    /** The plan usage for the ring; null when the computer does not send it (its switch is off) or is not connected. */
    val ring: UsageRing? = null,
    /** Agent tasks finished today, counted on this phone only. */
    val today: Int = 0,
) {
    /** The agent Solo shows. */
    val top: WidgetTile? get() = tiles.firstOrNull()

    /** The one clear line when there is no agent to list: the computer is not there, or nothing runs. Null when there are agents. */
    val emptyLine: String? get() = when {
        tiles.isNotEmpty() -> null
        !connected -> "Waiting for your computer"
        else -> "No agents running"
    }

    /** What Mochi says in his speech bubble: the agent's name and its state, nothing about what it is doing. */
    val bubble: String get() {
        val t = top ?: return emptyLine.orEmpty()
        if (waiting > 1) return "$waiting things are waiting for you"
        return when (t.state) {
            BotState.APPROVAL -> "${t.name} is waiting for you"
            BotState.QUESTION -> "${t.name} has a question"
            BotState.WORKING -> "${t.name} is working"
            BotState.THINKING -> "${t.name} is thinking"
            BotState.SEARCHING -> "${t.name} is searching"
            BotState.FINISHED -> "${t.name} is done"
            BotState.ERROR -> "${t.name} stopped on an error"
            BotState.RATELIMIT -> "${t.name} hit a limit"
            BotState.DIZZY -> "${t.name} needs a look"
            BotState.IDLE, BotState.SLEEPING -> "${t.name} is idle"
        }
    }

    /** The Waiting Alert's line: "2 waiting" in orange, or a calm word. */
    val alertLine: String get() = when {
        !connected -> "Not connected"
        waiting > 0 -> "$waiting waiting"
        else -> "All calm"
    }

    /** The line under the alert: who is waiting, or why there is nothing to say. */
    val alertSub: String get() = when {
        !connected -> "Waiting for your computer"
        waiting > 0 -> top?.name.orEmpty()
        else -> "Nothing needs you"
    }

    /** Mochi's face on the Today widget: pleased once something finished today, calm before. */
    val todayMood: BotState get() = if (today > 0) BotState.FINISHED else BotState.IDLE

    /** The Today widget glows green once something finished today. */
    val todayLook: WidgetTone get() = if (today > 0) WidgetTone.DONE else WidgetTone.MUTED

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

    fun build(
        glance: Glance,
        sessions: List<SessionInfo>,
        nameOf: (String) -> String,
        usage: UsageSnapshot? = null,
        today: Int = 0,
        nowMs: Long = 0L,
    ): WidgetContent {
        val tiles = if (!glance.connected) emptyList() else sessions
            .sortedBy { GlanceBuilder.rank(it.state) }
            .take(MAX_ROWS)
            .map { WidgetTile(it.pillId, nameOf(it.pillId), it.state, GlanceBuilder.lineOf(it), colourOf(it)) }
        val ring = if (glance.connected) ring(usage, nowMs) else null
        return WidgetContent(glance.headline, glance.tone, glance.connected, glance.waiting, tiles, ring, today.coerceAtLeast(0))
    }

    /** Claude's five-hour window first, then its week, then Codex; null when the computer sent none of them. */
    fun ring(usage: UsageSnapshot?, nowMs: Long): UsageRing? {
        usage ?: return null
        for ((name, plan) in listOf("Claude" to usage.claude, "Codex" to usage.codex)) {
            plan ?: continue
            plan.fiveHour?.let { return UsageRing(name, "5 h", PlanText.effectivePct(it, nowMs)) }
            plan.sevenDay?.let { return UsageRing(name, "week", PlanText.effectivePct(it, nowMs)) }
        }
        return null
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
