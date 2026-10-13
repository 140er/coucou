package com.coucou.android.core

import java.time.LocalDate

/** Where the count of the day is kept: one day and one number. */
interface TodayStorage {
    fun load(): Pair<String, Int>?
    fun save(day: String, count: Int)
}

/**
 * How many agent tasks finished today, counted on this phone only. A new local day starts at zero without any timer: the
 * day is compared when the count is read or raised, so after midnight the first read says 0. [day] is injectable for tests.
 */
class TodayCounter(private val storage: TodayStorage, private val day: () -> String = { LocalDate.now().toString() }) {
    @Synchronized
    fun count(): Int {
        val (saved, n) = storage.load() ?: return 0
        return if (saved == day()) n else 0
    }

    /** One more task finished; returns the new count. */
    @Synchronized
    fun increment(): Int {
        val n = count() + 1
        storage.save(day(), n)
        return n
    }
}
