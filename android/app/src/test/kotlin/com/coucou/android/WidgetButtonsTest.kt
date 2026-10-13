package com.coucou.android

import com.coucou.android.core.LaunchScreen
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The buttons of the Status Pill and Mochi Big, and the room they take. A button only opens a screen of the app (or the top agent):
 * none approves, denies or sends anything, and each has its own request code, a name and a content description.
 */
class WidgetButtonsTest {
    private val main = "src/main/kotlin/com/coucou/android/"
    private val res = "src/main/res/"
    private fun read(path: String) = File(path).readText()
    private val strings: Map<String, String> =
        Regex("""<string name="(\w+)">(.*?)</string>""").findAll(read(res + "values/strings.xml")).associate { it.groupValues[1] to it.groupValues[2] }
    private val dimens: Map<String, Double> =
        Regex("""<dimen name="(\w+)">([\d.]+)(?:dp|sp)</dimen>""").findAll(read(res + "values/dimens.xml")).associate { it.groupValues[1] to it.groupValues[2].toDouble() }

    // A tiny reader for layout files: attributes keep their android: prefix (the parser is not namespace aware).
    private fun element(xml: String): org.w3c.dom.Element =
        javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xml.byteInputStream()).documentElement
    private fun org.w3c.dom.Element.children(): List<org.w3c.dom.Element> =
        (0 until childNodes.length).map { childNodes.item(it) }.filterIsInstance<org.w3c.dom.Element>()
    private fun org.w3c.dom.Element.descendants(): List<org.w3c.dom.Element> = children().flatMap { listOf(it) + it.descendants() }

    // ── The icons ────────────────────────────────────────────────────────────────────────────────────

    private val icons = listOf("home", "chat", "settings", "recent", "session", "pair")

    @Test fun sixOutlineIconsWithOneStrokeWeight() {
        for (i in icons) {
            val xml = read("${res}drawable/ic_widget_$i.xml")
            assertTrue(i, xml.contains("<vector") && xml.contains("""android:width="24dp"""") && xml.contains("""android:viewportWidth="24""""))
            val widths = Regex("""android:strokeWidth="([\d.]+)"""").findAll(xml).map { it.groupValues[1] }.toSet()
            assertEquals("$i: one stroke weight", setOf("2"), widths)
            assertTrue("$i: in the Widgets' text colour, so the light variant follows", xml.contains("""android:strokeColor="@color/widget_text""""))
            assertFalse("$i: an outline, not a fill", xml.contains("android:fillColor"))
            assertTrue(i, xml.contains("""android:strokeLineCap="round""""))
        }
    }

    @Test fun theButtonsAreLighterCirclesAndRoundedTilesInBothModes() {
        val dark = read(res + "values/colors.xml")
        val light = read(res + "values-notnight/colors.xml")
        assertTrue(dark.contains("""<color name="widget_button">#1FFFFFFF</color>"""))
        assertTrue(light.contains("""<color name="widget_button">#14000000</color>"""))
        assertTrue(read(res + "drawable/widget_button_bg.xml").contains("""android:shape="oval""""))
        assertEquals(16.0, dimens.getValue("widget_tile_radius"), 0.0)
        assertTrue(read(res + "drawable/widget_tile_bg.xml").contains("@dimen/widget_tile_radius"))
        // Tinted orange while something waits.
        val waiting = read(res + "drawable/widget_tile_bg_attention.xml")
        assertTrue(waiting.contains("@color/widget_tint_attention") && waiting.contains("@color/widget_tone_attention"))
        assertTrue("round buttons of 36 to 40dp", dimens.getValue("widget_button") in 36.0..40.0)
    }

    @Test fun everyButtonHasAShortLabelAndADescription() {
        for (k in listOf("home", "chat", "settings", "recent", "session", "pair")) {
            val label = strings.getValue("widget_btn_$k")
            val cd = strings.getValue("widget_btn_${k}_cd")
            assertTrue("$k label '$label'", label.isNotBlank() && label.length <= 12)
            assertTrue("$k description '$cd'", cd.isNotBlank() && cd.length <= 40)
        }
    }

    // ── The Status Pill ─────────────────────────────────────────────────────────────────────────────

    @Test fun theStatusPillHasFourRoundButtonsThatOpenTheFourScreens() {
        val layout = read(res + "layout/widget_pill.xml")
        val ids = Regex("""@\+id/(pill_btn_\w+)""").findAll(layout).map { it.groupValues[1] }.toList()
        assertEquals(listOf("pill_btn_home", "pill_btn_chat", "pill_btn_settings", "pill_btn_recent"), ids)
        for (b in Regex("""<ImageView[^>]*pill_btn_[^>]*>""").findAll(layout)) {
            val tag = b.value
            assertTrue(tag, tag.contains("""android:layout_width="@dimen/widget_button"""") && tag.contains("""android:layout_height="@dimen/widget_button""""))
            assertTrue(tag, tag.contains("@drawable/widget_button_bg") && tag.contains("android:contentDescription=\"@string/widget_btn_"))
        }
        val src = read(main + "app/StatusPillWidget.kt")
        val pairs = Regex("""Button\(R\.id\.(pill_btn_\w+), LaunchScreen\.(\w+)\)""").findAll(src).map { it.groupValues[1] to it.groupValues[2] }.toList()
        assertEquals(listOf("pill_btn_home" to "HOME", "pill_btn_chat" to "CHAT", "pill_btn_settings" to "SETTINGS", "pill_btn_recent" to "RECENT"), pairs)
        assertTrue(src.contains("WidgetHub.openScreen(context, WidgetHub.CODE_PILL_BUTTON + i, b.screen)"))
        assertFalse("the pill opens no session from a button", src.contains("openSession(context, WidgetHub.CODE_PILL_BUTTON"))
    }

    @Test fun theStatusPillKeepsTheTextOffTheButtons() {
        val layout = read(res + "layout/widget_pill.xml")
        // The text group is the one weighted child of the row, so the buttons (fixed size) are measured first and never move.
        val row = element(layout).descendants().first { it.tagName == "LinearLayout" && it.getAttribute("android:orientation") == "horizontal" && it.children().any { c -> c.getAttribute("android:layout_weight").isNotEmpty() } }
        val weighted = row.children().filter { it.getAttribute("android:layout_weight").isNotEmpty() }
        assertEquals("exactly one weighted child: the text group", 1, weighted.size)
        val group = weighted.single()
        assertEquals("0dp", group.getAttribute("android:layout_width"))
        assertEquals("1", group.getAttribute("android:layout_weight"))
        assertEquals(listOf("LinearLayout"), listOf(group.tagName))
        val inside = group.descendants().mapNotNull { it.getAttribute("android:id").takeIf { id -> id.isNotEmpty() } }
        assertEquals(listOf("@+id/pill_dot", "@+id/pill_name", "@+id/pill_state"), inside)
        val others = row.children().filter { it !== group }
        assertEquals("the four buttons are the other children", listOf("@+id/pill_btn_home", "@+id/pill_btn_chat", "@+id/pill_btn_settings", "@+id/pill_btn_recent"), others.map { it.getAttribute("android:id") })
        for (b in others) {
            assertEquals(b.getAttribute("android:id"), "ImageView", b.tagName)
            assertEquals("a button has a fixed width", "@dimen/widget_button", b.getAttribute("android:layout_width"))
            assertTrue("a button has no weight, so it is never squeezed", b.getAttribute("android:layout_weight").isEmpty())
        }
        // The text inside the group: the state word is the weighted one (it shrinks first), the name wraps its content.
        val name = group.descendants().first { it.getAttribute("android:id") == "@+id/pill_name" }
        val state = group.descendants().first { it.getAttribute("android:id") == "@+id/pill_state" }
        assertEquals("wrap_content", name.getAttribute("android:layout_width"))
        assertEquals("0dp", state.getAttribute("android:layout_width"))
        assertEquals("1", state.getAttribute("android:layout_weight"))
        assertEquals("every text on the pill is one line, ellipsized", 2, Regex("""android:maxLines="1"""").findAll(layout).count())
        // Width budget in dp: padding 16 + 8, four buttons of 36 with 6 between.
        val buttons = 4 * dimens.getValue("widget_button") + 4 * 6 + 16 + 8
        val src = read(main + "app/StatusPillWidget.kt")
        val medium = Regex("""MEDIUM_AT = SizeF\((\d+)f""").find(src)!!.groupValues[1].toInt()
        val large = Regex("""LARGE_AT = SizeF\((\d+)f""").find(src)!!.groupValues[1].toInt()
        val minResize = Regex("""android:minResizeWidth="(\d+)dp"""").find(read(res + "xml/coucou_pill_widget_info.xml"))!!.groupValues[1].toInt()
        assertTrue("the buttons alone fit the narrowest the Widget can be", buttons <= minResize)
        assertTrue("from $medium dp the name has room (dot + about 80dp)", medium - buttons >= 90)
        assertTrue("from $large dp the state word has room too", large - buttons >= 90 + 50)
        assertTrue("narrower the pill hides the state word first: $medium < $large", medium < large)
        // Under the medium width only the dot is left of the buttons; the state word goes first, then the name.
        assertTrue(src.contains("R.id.pill_name, if (size == WidgetHub.Size.SMALL) View.GONE"))
        assertTrue(src.contains("R.id.pill_state, if (size == WidgetHub.Size.LARGE) View.VISIBLE else View.GONE"))
    }

    // ── Mochi Big ───────────────────────────────────────────────────────────────────────────────────

    @Test fun mochiBigHasSixTilesAndEachOpensOneThing() {
        val layout = read(res + "layout/widget_big.xml")
        val ids = Regex("""@\+id/(big_tile_\w+)""").findAll(layout).map { it.groupValues[1] }.toList()
        assertEquals(listOf("big_tile_home", "big_tile_chat", "big_tile_settings", "big_tile_recent", "big_tile_session", "big_tile_pair"), ids)
        // Icon above a 12sp label, on a rounded tile.
        assertEquals(6, Regex("""@drawable/widget_tile_bg"""").findAll(layout).count())
        assertEquals(6, Regex("""android:textSize="@dimen/widget_text_secondary"[^>]*/>""").findAll(layout.substringAfter("big_buttons").substringBefore("big_badge")).count())
        assertEquals(12.0, dimens.getValue("widget_text_secondary"), 0.0)
        val src = read(main + "app/MochiBigWidget.kt")
        val tiles = Regex("""Tile\(R\.id\.(big_tile_\w+), (LaunchScreen\.\w+|null)\)""").findAll(src).map { it.groupValues[1] to it.groupValues[2] }.toList()
        assertEquals(
            listOf(
                "big_tile_home" to "LaunchScreen.HOME", "big_tile_chat" to "LaunchScreen.CHAT", "big_tile_settings" to "LaunchScreen.SETTINGS",
                "big_tile_recent" to "LaunchScreen.RECENT", "big_tile_session" to "null", "big_tile_pair" to "LaunchScreen.PAIR",
            ),
            tiles,
        )
        // The top agent goes through the session slot; everything else through the screen slot; each tile has its own code.
        assertTrue(src.contains("WidgetHub.openSession(context, WidgetHub.CODE_BIG_BUTTON + i, top.pillId)"))
        assertTrue(src.contains("WidgetHub.openScreen(context, WidgetHub.CODE_BIG_BUTTON + i, t.screen)"))
        assertTrue(src.contains("R.drawable.widget_tile_bg_attention"))
    }

    @Test fun theBigOnesButtonsGoFromTwoRowsToOneRowToNone() {
        val layout = read(res + "layout/widget_big.xml")
        assertEquals("a row of four then a row of two", 2, Regex("""@\+id/big_buttons_[ab]""").findAll(layout).count())
        assertEquals(4, Regex("""@\+id/big_tile_(home|chat|settings|recent)"""").findAll(layout).count())
        val src = read(main + "app/MochiBigWidget.kt")
        assertTrue(src.contains("R.id.big_buttons, if (small) View.GONE else View.VISIBLE"))
        assertTrue(src.contains("R.id.big_buttons_b, if (large) View.VISIBLE else View.GONE"))
    }

    @Test fun mochiKeepsAtLeastFortyPercentOfTheBigCardWheneverButtonsShow() {
        val src = read(main + "app/MochiBigWidget.kt")
        val medium = Regex("""MEDIUM_AT = SizeF\(0f, (\d+)f""").find(src)!!.groupValues[1].toDouble()
        val large = Regex("""LARGE_AT = SizeF\(0f, (\d+)f""").find(src)!!.groupValues[1].toDouble()
        val tile = dimens.getValue("widget_tile_height")
        // dp: padding 12 + 12, the bubble in two lines (8 + 2 x 20 + 8 = 56) and its tail 10, the status line 20, then the buttons.
        val fixed = 24 + 56 + 10 + 20
        val rowA = 8 + tile
        val rowB = 6 + tile
        assertTrue("one row from $medium dp: Mochi ${medium - fixed - rowA}", (medium - fixed - rowA) / medium >= 0.40)
        assertTrue("two rows from $large dp: Mochi ${large - fixed - rowA - rowB}", (large - fixed - rowA - rowB) / large >= 0.40)
        // And with no buttons there is more room still.
        val minHeight = Regex("""android:minHeight="(\d+)dp"""").find(read(res + "xml/coucou_big_widget_info.xml"))!!.groupValues[1].toDouble()
        assertTrue((minHeight - fixed) / minHeight >= 0.40)
        assertTrue("the steps are in order", medium < large && minHeight < medium)
    }

    // ── Nothing here can approve, deny or send ──────────────────────────────────────────────────────

    @Test fun everyButtonOpensAScreenOfTheClosedListAndNothingElse() {
        for (f in listOf("app/StatusPillWidget.kt", "app/MochiBigWidget.kt")) {
            val src = read(main + f)
            for (word in listOf("PendingLaunch", "launch.request", "ActionReceiver", "approve", "Allow", "Deny", "decide", "send", "BiometricGate", "putExtra")) {
                assertFalse("$f uses $word", src.contains(word, ignoreCase = word != "send" && word != "Allow" && word != "Deny"))
            }
        }
        // Every screen a button names is on the list.
        val named = (read(main + "app/StatusPillWidget.kt") + read(main + "app/MochiBigWidget.kt"))
        for (m in Regex("""LaunchScreen\.([A-Z]+)""").findAll(named)) assertTrue(m.groupValues[1], LaunchScreen.values().any { it.name == m.groupValues[1] })
    }
}
