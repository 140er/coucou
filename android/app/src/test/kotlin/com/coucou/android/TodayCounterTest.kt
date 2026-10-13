package com.coucou.android

import com.coucou.android.core.TodayCounter
import com.coucou.android.core.TodayStorage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TodayCounterTest {
    private class Memory : TodayStorage {
        var saved: Pair<String, Int>? = null
        override fun load() = saved
        override fun save(day: String, count: Int) { saved = day to count }
    }

    private var day = "2026-10-13"
    private val storage = Memory()
    private val counter = TodayCounter(storage) { day }

    @Test fun startsAtZero() = assertEquals(0, counter.count())

    @Test fun countsUpDuringTheDay() {
        assertEquals(1, counter.increment())
        assertEquals(2, counter.increment())
        assertEquals(2, counter.count())
        assertEquals("2026-10-13" to 2, storage.saved)
    }

    @Test fun readsZeroAfterMidnightWithoutAnythingRunning() {
        counter.increment(); counter.increment()
        day = "2026-10-14"
        assertEquals(0, counter.count())
    }

    @Test fun theFirstTaskOfTheNewDayStartsAtOne() {
        repeat(3) { counter.increment() }
        day = "2026-10-14"
        assertEquals(1, counter.increment())
        assertEquals("2026-10-14" to 1, storage.saved)
    }

    @Test fun anOldDayNeverComesBack() {
        counter.increment()
        day = "2026-10-12"
        assertEquals("a day that is not today is not today", 0, counter.count())
    }

    @Test fun itIsKeptOnThePhoneOnly() {
        val store = File("src/main/kotlin/com/coucou/android/app/TodayStore.kt")
        if (store.exists()) {
            val src = store.readText()
            assertTrue(src.contains("getSharedPreferences(\"widget_today\""))
            for (net in listOf("http", "Socket", "link.", "Protocol")) assertTrue(net, !src.contains(net))
        }
    }
}
