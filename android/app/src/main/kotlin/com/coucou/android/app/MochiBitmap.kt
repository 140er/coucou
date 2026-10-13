package com.coucou.android.app

import android.graphics.Bitmap
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import com.coucou.android.mochi.BotState
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiPainter.drawMochi
import kotlin.random.Random

/**
 * One still picture of Mochi for a widget (a widget cannot animate): the engine is settled for a second of fake time
 * with a fixed seed, so the same state always gives the same picture, then drawn once with the app's own painter into an
 * [ImageBitmap]. No timer and no frame loop; a few pictures are kept so a push that changes only the text redraws nothing.
 */
object MochiBitmap {
    private const val SEED = 7
    private const val SETTLE_FRAMES = 60
    private const val FRAME_SEC = 1.0 / 60
    private const val KEEP = 6

    private data class Key(val state: BotState, val size: Int)

    private val cache = object : LinkedHashMap<Key, Bitmap>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Bitmap>) = size > KEEP
    }

    /** Mochi in [state], [sizePx] pixels square. The same instance comes back while it is kept. */
    @Synchronized
    fun of(state: BotState, sizePx: Int): Bitmap {
        val key = Key(state, sizePx)
        return cache.getOrPut(key) { draw(state, sizePx) }
    }

    private fun draw(state: BotState, sizePx: Int): Bitmap {
        var ms = 0.0
        val engine = MochiEngine({ ms }, Random(SEED)).apply { setState(state, force = true) }
        repeat(SETTLE_FRAMES) {
            ms += FRAME_SEC * 1000
            engine.update(FRAME_SEC)
        }
        val image = ImageBitmap(sizePx, sizePx)
        CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, Canvas(image), Size(sizePx.toFloat(), sizePx.toFloat())) {
            drawMochi(engine, ms / 1000)
        }
        return image.asAndroidBitmap()
    }
}
