package com.coucou.android

import com.coucou.android.core.PendingLaunch
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingLaunchTest {
    private var now = 1_000L
    private val launch = PendingLaunch { now }

    @Test fun aRequestFromOurOwnTapIsTakenOnce() {
        launch.request("fp-1", allow = true)
        assertEquals(PendingLaunch.Request("fp-1", true), launch.take())
        assertNull("only once", launch.take())
    }

    @Test fun nothingAskedMeansNothingToTake() {
        // A foreign intent with the same extras never reaches here: MainActivity does not read them (see below),
        // so with no tap on our own notification there is simply no request.
        assertNull(launch.take())
    }

    @Test fun aStaleRequestIsDropped() {
        launch.request("fp-1", allow = true)
        now += PendingLaunch.TTL_MS + 1
        assertNull(launch.take())
        launch.request("fp-2", allow = true)
        now += PendingLaunch.TTL_MS
        assertEquals("fp-2", launch.take()!!.fingerprint)
    }

    @Test fun aBlankOrHugeFingerprintCanNeverAllow() {
        launch.request("", allow = true)
        assertNull(launch.take())
        launch.request(null, allow = true)
        assertNull(launch.take())
        launch.request("x".repeat(PendingLaunch.MAX_FP + 1), allow = true)
        assertNull(launch.take())
    }

    @Test fun aNewerRequestReplacesTheOlderOne() {
        launch.request("old", allow = true)
        launch.request("new", allow = false)
        assertEquals(PendingLaunch.Request("new", false), launch.take())
    }

    private val main = "src/main/kotlin/com/coucou/android/"
    private fun manifest() = File("src/main/AndroidManifest.xml").readText()

    @Test fun theExportedActivityNeverReadsTheRequestFromItsIntent() {
        val src = File(main + "MainActivity.kt").readText()
        for (bad in listOf("EXTRA_FP", "EXTRA_ALLOW", "getStringExtra", "getBooleanExtra", "\"fingerprint\"", "\"allow\"")) {
            assertFalse("MainActivity must not read $bad from an intent", src.contains(bad))
        }
        assertTrue(src.contains("model.launch.take()"))
    }

    @Test fun onlyTheNonExportedEntryActivityCanMakeARequest() {
        val callers = File(main).walkTopDown().filter { it.extension == "kt" }
            .filter { it.readText().contains("launch.request(") }.map { it.name }.toList()
        assertEquals(listOf("LaunchActivity.kt"), callers)
        val m = manifest()
        val entry = m.substringAfter("""android:name=".app.LaunchActivity"""").substringBefore("/>")
        assertTrue(entry.contains("""android:exported="false""""))
        assertTrue("it is the only way the request reaches the app", m.contains(".app.LaunchActivity"))
    }

    @Test fun ourNotificationsAndTheIslandGoThroughIt() {
        val n = File(main + "app/Notifications.kt").readText()
        assertTrue(n.contains("LaunchActivity::class.java"))
        // The only component that takes the fingerprint extra from the outside is the Deny receiver, which is not exported.
        assertTrue(manifest().substringAfter(""".app.ActionReceiver"""").substringBefore("/>").contains("""android:exported="false""""))
    }

    @Test fun everyOtherComponentWithAnIntentFilterIsTheLauncher() {
        val m = manifest()
        val exported = Regex("""android:name="([^"]+)"[^>]*android:exported="true"""").findAll(m).map { it.groupValues[1] }.toSet()
        assertEquals(setOf(".MainActivity", ".app.GlanceWidget", ".app.GlanceTile", ".app.SoloWidget", ".app.ListWidget"), exported)
    }

    @Test fun aWidgetRowAsksForASessionOnce() {
        launch.requestSession("agent_codex")
        assertEquals("agent_codex", launch.takeSession())
        assertNull("only once", launch.takeSession())
    }

    @Test fun aStaleOrBadSessionRequestIsDropped() {
        launch.requestSession("agent_codex")
        now += PendingLaunch.TTL_MS + 1
        assertNull(launch.takeSession())
        launch.requestSession("")
        assertNull(launch.takeSession())
        launch.requestSession(null)
        assertNull(launch.takeSession())
        launch.requestSession("x".repeat(PendingLaunch.MAX_PILL + 1))
        assertNull(launch.takeSession())
    }

    @Test fun theSessionSlotAndTheAllowSlotNeverMeet() {
        launch.request("fp-1", allow = true)
        launch.requestSession("agent_codex")
        assertEquals("agent_codex", launch.takeSession())
        assertEquals("the Allow is still there", PendingLaunch.Request("fp-1", true), launch.take())
        launch.requestSession("agent_codex")
        assertNull("a session request is never an Allow", launch.take())
        assertEquals("agent_codex", launch.takeSession())
    }

    @Test fun theExportedActivityOnlyAsksTheModelForTheSessionToOpen() {
        val src = File(main + "MainActivity.kt").readText()
        assertTrue(src.contains("model.launch.takeSession()"))
        assertFalse(src.contains("EXTRA_SESSION"))
        val callers = File(main).walkTopDown().filter { it.extension == "kt" }
            .filter { it.readText().contains("launch.requestSession(") }.map { it.name }.toList()
        assertEquals(listOf("LaunchActivity.kt"), callers)
    }
}
