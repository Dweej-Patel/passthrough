package dev.dpatel.passthrough.ui.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLockTests {
    private var now = 1_000L
    private fun lock() = AppLock { now }

    @Test fun startsLocked() {
        assertFalse(lock().unlocked.value)
    }

    @Test fun relockLocksAndArmsThePrompt() {
        val l = lock().also { it.onUnlocked(); it.takeAutoPrompt() }
        l.relock()
        assertFalse(l.unlocked.value)
        assertTrue(l.takeAutoPrompt())
    }

    @Test fun staysUnlockedWithinGrace() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now += 59_000
        l.onForeground()
        assertTrue(l.unlocked.value)
    }

    @Test fun relocksAfterGrace() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now += 61_000
        l.onForeground()
        assertFalse(l.unlocked.value)
    }

    @Test fun relocksExactlyAtGrace() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now += AppLock.RELOCK_AFTER_MS
        l.onForeground()
        assertFalse(l.unlocked.value)
    }

    @Test fun clockGoingBackwardsRelocks() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now -= 5_000
        l.onForeground()
        assertFalse(l.unlocked.value)
    }

    @Test fun foregroundWithoutBackgroundKeepsUnlocked() {
        val l = lock().also { it.onUnlocked() }
        now += 600_000
        l.onForeground()
        assertTrue(l.unlocked.value)
    }

    @Test fun secondBackgroundDoesNotRestartTheClock() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now += 40_000
        l.onBackground()
        now += 40_000
        l.onForeground()
        assertFalse(l.unlocked.value)
    }

    @Test fun unlockClearsPendingBackground() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now += 90_000
        l.onForeground()
        l.onUnlocked()
        l.onForeground()
        assertTrue(l.unlocked.value)
    }

    @Test fun autoPromptOncePerForegrounding() {
        val l = lock()
        assertTrue(l.takeAutoPrompt())
        assertFalse(l.takeAutoPrompt())
        l.onBackground()
        assertTrue(l.takeAutoPrompt())
        assertFalse(l.takeAutoPrompt())
    }

    @Test fun relockRearmsAutoPrompt() {
        val l = lock().also { it.onUnlocked(); it.takeAutoPrompt() }
        l.onBackground()
        l.takeAutoPrompt()
        now += 61_000
        l.onForeground()
        assertEquals(false, l.unlocked.value)
        assertTrue(l.takeAutoPrompt())
    }

    @Test fun stopStartWhilePromptInFlightDoesNotRearm() {
        val l = lock()
        assertTrue(l.takeAutoPrompt())
        assertTrue(l.beginPrompt())
        l.onBackground()   // credential screen stops the activity
        l.onForeground()
        l.endPrompt()      // user cancelled
        assertFalse(l.takeAutoPrompt())
    }

    @Test fun onlyOnePromptAtATime() {
        val l = lock()
        assertTrue(l.beginPrompt())
        assertFalse(l.beginPrompt())
        l.endPrompt()
        assertTrue(l.beginPrompt())
    }

    @Test fun configChangeAfterCancelDoesNotRearm() {
        val l = lock()
        l.takeAutoPrompt()
        l.onBackground(changingConfigurations = true)
        l.onForeground()
        assertFalse(l.takeAutoPrompt())
    }

    @Test fun configChangeDoesNotStartRelockClock() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground(changingConfigurations = true)
        now += 120_000
        l.onForeground()
        assertTrue(l.unlocked.value)
    }

    @Test fun realBackgroundStillRelocksAndRearms() {
        val l = lock().also { it.onUnlocked(); it.takeAutoPrompt() }
        l.onBackground(changingConfigurations = false)
        now += 61_000
        l.onForeground()
        assertFalse(l.unlocked.value)
        assertTrue(l.takeAutoPrompt())
    }

    @Test fun unlockClearsPromptInFlight() {
        val l = lock()
        l.beginPrompt()
        l.onUnlocked()
        assertFalse(l.promptInFlight)
    }
}
