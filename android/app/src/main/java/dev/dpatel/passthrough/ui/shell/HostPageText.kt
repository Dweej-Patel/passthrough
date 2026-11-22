package dev.dpatel.passthrough.ui.shell

import android.text.format.DateFormat
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import dev.dpatel.passthrough.core.HostWords
import dev.dpatel.passthrough.service.Runtime
import java.util.Date
import kotlinx.coroutines.delay

/** A time of day as this phone shows one ("14:02" or "2:02 PM"). */
@Composable
fun rememberClock(): (Long) -> String {
    val context = LocalContext.current
    return remember(context) {
        val format = DateFormat.getTimeFormat(context)
        val clock: (Long) -> String = { millis -> format.format(Date(millis)) }
        clock
    }
}

/**
 * The selected computer's page as of now, re-made every few seconds so Try again appears once
 * a connect has run long enough.
 */
@Composable
fun rememberHostPage(input: HostPageInput): HostPage {
    val now by produceState(System.currentTimeMillis()) {
        while (true) {
            delay(5_000)
            value = System.currentTimeMillis()
        }
    }
    return remember(input, now) { HostPage.make(input.copy(nowMillis = now)) }
}

/** The sentence under a PC's title while it can't be reached, with its times filled in. */
fun hostDetail(page: HostPage, w: HostWords, input: HostPageInput, macID: String?, clock: (Long) -> String): String? =
    HostCopy.detail(
        page.state, w, input.triedFromAnywhere,
        lastHeard = macID?.let { Runtime.settings.shellLastHeard()[it] }?.let(clock),
        at = input.farewell?.atMillis?.let(clock),
        sleepsAfter = HostCopy.sleepTimer(input.host?.sleepAfter),
    )
