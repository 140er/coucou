package com.coucou.android

import com.coucou.android.core.Glance
import com.coucou.android.core.GlanceBuilder
import com.coucou.android.core.GlanceTone
import com.coucou.android.core.WidgetData
import com.coucou.android.link.LinkState
import com.coucou.android.link.SessionInfo
import com.coucou.android.mochi.BotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetDataTest {
    private fun s(id: String, state: BotState, color: String? = null, status: String = "") =
        SessionInfo(id, "", state, status, 0, 0, 0L, project = "secret-folder", color = color)

    private val names = mapOf("agent_codex" to "Codex", "agent_gemini" to "Gemini CLI", "agent_amp" to "Amp")
    private fun glance(sessions: List<SessionInfo>, approvals: Int = 0, link: LinkState = LinkState.CONNECTED): Glance =
        GlanceBuilder.build(true, link, "PC", sessions, approvals) { names[it] ?: "An agent" }

    private fun build(sessions: List<SessionInfo>, approvals: Int = 0, link: LinkState = LinkState.CONNECTED) =
        WidgetData.build(glance(sessions, approvals, link), sessions) { names[it] ?: "An agent" }

    @Test fun theMostUrgentAgentComesFirstLikeOnTheOtherSurfaces() {
        val sessions = listOf(s("agent_amp", BotState.IDLE), s("agent_codex", BotState.WORKING), s("agent_gemini", BotState.APPROVAL))
        val c = build(sessions, approvals = 1)
        assertEquals(listOf("agent_gemini", "agent_codex", "agent_amp"), c.tiles.map { it.pillId })
        assertEquals("agent_gemini", c.top!!.pillId)
        // The same order as the notification and the first widget.
        assertEquals(c.tiles.map { it.name }, glance(sessions, 1).lines.map { it.agent })
    }

    @Test fun theStateWordIsTheOneOfTheGlance() {
        val sessions = listOf(s("agent_codex", BotState.QUESTION))
        assertEquals("Has a question", build(sessions).top!!.stateWord)
        assertEquals("Codex", build(sessions).top!!.name)
        assertEquals(glance(sessions).lines.single().text, build(sessions).top!!.stateWord)
    }

    @Test fun theListIsCapped() {
        val many = (1..9).map { s("p$it", BotState.WORKING) }
        assertEquals(WidgetData.MAX_ROWS, build(many).tiles.size)
    }

    @Test fun theColourIsTheSessionsOwnThenThePillsThenGrey() {
        assertEquals(0xFF112233.toInt(), build(listOf(s("agent_codex", BotState.IDLE, color = "#112233"))).top!!.argb)
        assertEquals(0xFF2DD4BF.toInt(), build(listOf(s("agent_codex", BotState.IDLE))).top!!.argb)
        assertEquals(0xFF2DD4BF.toInt(), build(listOf(s("agent_codex", BotState.IDLE, color = "teal"))).top!!.argb)
        assertEquals(GlanceTone.CALM.argb, build(listOf(s("nope", BotState.IDLE))).top!!.argb)
    }

    @Test fun parseOnlyTakesSixDigitHex() {
        assertEquals(0xFFFFFFFF.toInt(), WidgetData.parse("#FFFFFF"))
        for (bad in listOf(null, "", "FFFFFF", "#FFF", "#GGGGGG", "#FFFFFFFF", "#+12345")) assertNull(bad, WidgetData.parse(bad))
    }

    @Test fun nothingToShowWhileNotConnected() {
        val c = build(listOf(s("agent_codex", BotState.WORKING)), link = LinkState.DISCONNECTED)
        assertTrue(c.tiles.isEmpty())
        assertNull(c.top)
        assertFalse(c.connected)
        assertEquals(BotState.SLEEPING, c.mood)
        assertEquals("Not connected", c.headline)
    }

    @Test fun connectedWithNoAgentIsCalm() {
        val c = build(emptyList())
        assertEquals(BotState.IDLE, c.mood)
        assertEquals("Connected", c.headline)
    }

    @Test fun moodIsTheTopAgents() {
        assertEquals(BotState.ERROR, build(listOf(s("agent_codex", BotState.WORKING), s("agent_amp", BotState.ERROR))).mood)
    }

    @Test fun waitingCountsRequestsAndQuestions() {
        val c = build(listOf(s("agent_codex", BotState.QUESTION)), approvals = 2)
        assertEquals(3, c.waiting)
    }

    @Test fun sameContentIsEqualSoThePushCanBeSkipped() {
        val a = build(listOf(s("agent_codex", BotState.WORKING)))
        val b = build(listOf(s("agent_codex", BotState.WORKING)))
        assertEquals(a, b)
        // A change the widget does not show (step text, project) does not change the content.
        assertEquals(a, build(listOf(s("agent_codex", BotState.WORKING, status = "editing a.kt"))))
        assertFalse(a == build(listOf(s("agent_codex", BotState.THINKING))))
    }

    @Test fun nothingPrivateReachesTheTiles() {
        val c = build(listOf(s("agent_codex", BotState.WORKING, status = "rm -rf /home/me/secret.txt")), approvals = 1)
        val text = c.toString()
        assertFalse(text.contains("secret"))
        assertFalse(text.contains("rm -rf"))
    }

    @Test fun anEmptyCardSaysOneClearLine() {
        assertEquals("Waiting for your computer", build(emptyList(), link = LinkState.DISCONNECTED).emptyLine)
        assertEquals("Waiting for your computer", build(listOf(s("agent_codex", BotState.WORKING)), link = LinkState.CONNECTING).emptyLine)
        assertEquals("No agents running", build(emptyList()).emptyLine)
        assertNull(build(listOf(s("agent_codex", BotState.WORKING))).emptyLine)
    }

    @Test fun aTilesDotIsTheToneOfItsState() {
        val t = build(listOf(s("agent_codex", BotState.APPROVAL), s("agent_amp", BotState.FINISHED))).tiles
        assertEquals(com.coucou.android.core.WidgetTone.ATTENTION, t[0].tone)
        assertEquals(com.coucou.android.core.WidgetTone.DONE, t[1].tone)
    }
}
