package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source guards for the Solo and List widgets (Compose and Android classes only compile in CI), in the style of [GlanceSurfacesTest]. */
class WidgetSurfacesTest {
    private val main = "src/main/kotlin/com/coucou/android/"
    private fun read(path: String) = File(path).readText()
    private val manifest get() = read("src/main/AndroidManifest.xml")

    /** Every widget source: the providers, the hub, the pictures, the pure logic and the day's count. */
    private val widgets = listOf(
        "SoloWidget" to "coucou_solo_widget_info", "ListWidget" to "coucou_list_widget_info", "MochiBigWidget" to "coucou_big_widget_info",
        "StatusPillWidget" to "coucou_pill_widget_info", "WaitingAlertWidget" to "coucou_alert_widget_info",
        "UsageRingWidget" to "coucou_ring_widget_info", "TodayWidget" to "coucou_today_widget_info", "MoodWidget" to "coucou_mood_widget_info",
    )
    private val sources = (
        widgets.map { "app/${it.first}.kt" } +
            listOf("app/WidgetHub.kt", "app/MochiBitmap.kt", "app/RingBitmap.kt", "app/TodayStore.kt", "core/WidgetData.kt", "core/TodayCounter.kt")
        ).associateWith { read(main + it) }

    @Test fun theWidgetsAreRegisteredAndNeverWakeOnATimer() {
        for ((cls, info) in widgets) {
            assertTrue(manifest.contains("""android:name=".app.$cls""""))
            assertTrue(manifest.contains("@xml/$info"))
            val xml = read("src/main/res/xml/$info.xml")
            assertTrue(xml.contains("""android:updatePeriodMillis="0""""))
            assertTrue(xml.contains("""android:widgetCategory="home_screen""""))
        }
    }

    @Test fun noWidgetSourceTouchesAnythingBeyondTheGlance() {
        // Agent names, state words and colours only: no step text, no command, no file, no answer.
        for ((name, src) in sources) {
            for (word in listOf("statusText", "finalLine", "steps", ".command", "files", "project")) assertFalse("$name uses $word", src.contains(word))
        }
    }

    @Test fun noWidgetCanDecideAnything() {
        for ((name, src) in sources) {
            for (word in listOf("decide", "allow", "deny", "approve", "answer", "unpair")) assertFalse("$name uses $word", src.contains(word, ignoreCase = true))
        }
        for (layout in listOf("widget_solo", "widget_list")) assertFalse(read("src/main/res/layout/$layout.xml").contains("Button"))
    }

    @Test fun noTimerAndNoLibrary() {
        for ((name, src) in sources) {
            for (word in listOf("AlarmManager", "WorkManager", "postDelayed", "Handler(", "Timer", "androidx.glance")) assertFalse("$name uses $word", src.contains(word))
        }
        assertFalse(read("build.gradle.kts").contains("androidx.glance"))
    }

    @Test fun everyPendingIntentIsImmutableAndExplicit() {
        val hub = sources.getValue("app/WidgetHub.kt")
        assertEquals(2, Regex("PendingIntent.getActivity").findAll(hub).count())
        assertEquals(2, Regex("FLAG_IMMUTABLE").findAll(hub).count())
        assertTrue(hub.contains("Intent(context, LaunchActivity::class.java)"))
        assertTrue(hub.contains("Intent(context, MainActivity::class.java)"))
        for ((name, src) in sources) {
            if (name == "app/WidgetHub.kt") continue
            assertFalse("$name builds its own PendingIntent", src.contains("PendingIntent.get"))
            assertFalse("$name builds its own Intent", src.contains("Intent(\""))
        }
    }

    @Test fun everyRowAndEveryWidgetHasItsOwnRequestCode() {
        val hub = sources.getValue("app/WidgetHub.kt")
        val codes = Regex("""const val CODE_\w+ = (0x[0-9A-Fa-f]+)""").findAll(hub).map { it.groupValues[1] }.toList()
        assertEquals(9, codes.size)
        assertEquals(codes.size, codes.toSet().size)
        // The rows use CODE_LIST_ROW + index: the ranges must not run into the next code.
        val values = codes.map { it.removePrefix("0x").toInt(16) }.sorted()
        assertTrue(values.zipWithNext().all { (a, b) -> b - a >= 16 })
        assertTrue(sources.getValue("app/ListWidget.kt").contains("WidgetHub.CODE_LIST_ROW + i"))
        // Every provider uses its own code, and the family uses each code once.
        val used = widgets.map { (cls, _) -> Regex("""WidgetHub\.(CODE_\w+)""").findAll(sources.getValue("app/$cls.kt")).map { it.groupValues[1] }.toSet() }
        for (u in used) assertTrue(u.isNotEmpty())
        val flat = used.flatten()
        assertEquals("a code is shared by two Widgets: $flat", flat.size, flat.toSet().size)
    }

    @Test fun theImageAndTheBadgeAreDescribed() {
        assertTrue(sources.getValue("app/SoloWidget.kt").contains("setContentDescription(R.id.solo_mochi"))
        assertTrue(sources.getValue("app/SoloWidget.kt").contains("setContentDescription(R.id.solo_badge"))
        assertTrue(sources.getValue("app/ListWidget.kt").contains("setContentDescription(R.id.list_badge"))
        // Every Widget with a picture describes it; every layout image that is not decoration has a description or is hidden from it.
        for ((cls, _) in widgets) assertTrue("$cls has no content description", sources.getValue("app/$cls.kt").contains("setContentDescription("))
        for (layout in File("src/main/res/layout").listFiles()!!.filter { it.name.startsWith("widget_") && it.name != "widget_glance.xml" }) {
            for (img in Regex("""<ImageView[^>]*>""").findAll(layout.readText())) {
                val tag = img.value
                assertTrue("${layout.name}: an image with neither a description nor importantForAccessibility=no: $tag",
                    tag.contains("android:contentDescription") || tag.contains("""android:importantForAccessibility="no""""))
            }
        }
    }

    @Test fun everyChangeOfThePictureReachesTheHub() {
        val model = read(main + "app/AppModel.kt")
        val push = model.substringAfter("private fun pushGlance()").substringBefore("private fun refreshIsland()")
        assertTrue(push.contains("WidgetHub.update"))
        assertTrue("the first widget stays", push.contains("GlanceWidget.update"))
        assertTrue(sources.getValue("app/WidgetHub.kt").contains("if (content == last) return"))
    }

    @Test fun theFirstWidgetIsUntouched() {
        // GlanceSurfacesTest guards its registration; this guards that the new widgets did not take its names.
        assertTrue(manifest.contains("@xml/coucou_widget_info"))
        assertTrue(File("src/main/res/layout/widget_glance.xml").exists())
        assertTrue(read("src/main/res/xml/coucou_widget_info.xml").contains("""android:targetCellWidth="3""""))
    }

    @Test fun theListRowsAreAtLeastFortyEightDpAndTheEmptyStateFillsTheCard() {
        val list = read("src/main/res/layout/widget_list.xml")
        assertEquals(5, Regex("""android:layout_height="@dimen/widget_row_min"""").findAll(list).count())
        for (id in listOf("list_empty", "list_empty_face", "list_empty_title", "list_empty_line", "list_tint", "list_root")) assertTrue(id, list.contains("@+id/$id"))
        val code = read(main + "app/ListWidget.kt")
        assertTrue(code.contains("c.tiles.isEmpty()"))
        assertTrue(code.contains("R.id.list_empty"))
    }

    @Test fun theCardsUseTheSharedLook() {
        for (layout in listOf("widget_solo", "widget_list")) {
            val xml = read("src/main/res/layout/$layout.xml")
            assertTrue(layout, xml.contains("@drawable/widget_card"))
            assertTrue(layout, xml.contains("@drawable/widget_tint_muted"))
            // Colours and sizes come from the shared resources, never from a literal grey at 12sp.
            assertFalse(layout, xml.contains("#FFAEAEB2"))
        }
        val solo = read(main + "app/SoloWidget.kt")
        assertTrue(solo.contains("WidgetHub.paint("))
        assertTrue(read(main + "app/ListWidget.kt").contains("WidgetHub.paint("))
    }

    @Test fun mochiHasAtLeastHalfOfTheSoloCard() {
        val solo = read("src/main/res/layout/widget_solo.xml")
        // Mochi takes the leftover height (weight 1) while the text rows wrap their content.
        assertTrue(solo.contains("""android:layout_weight="1""""))
        assertTrue(read(main + "app/SoloWidget.kt").contains("glow = true"))
    }
}
