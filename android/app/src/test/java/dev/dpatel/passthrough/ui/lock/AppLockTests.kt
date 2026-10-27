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

    @Test fun relockLocks() {
        val l = lock().also { it.onUnlocked() }
        l.relock()
        assertFalse(l.unlocked.value)
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

    @Test fun startsLockedForStartup() {
        assertEquals(LockReason.STARTUP, lock().reason.value)
    }

    @Test fun expiryLocksAsAway() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now += 61_000
        l.onForeground()
        assertFalse(l.unlocked.value)
        assertEquals(LockReason.AWAY, l.reason.value)
    }

    @Test fun relockSaysWhy() {
        val l = lock().also { it.onUnlocked() }
        l.relock()
        assertEquals(LockReason.SHELL_KEY, l.reason.value)
    }

    @Test fun relockWhileLockedKeepsTheFirstReason() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground()
        now += 61_000
        l.onForeground()
        l.relock()
        assertEquals(LockReason.AWAY, l.reason.value)
    }

    /** Locking itself never claims the prompt slot: the lock screen starts the prompt. */
    @Test fun lockingNeverStartsAPrompt() {
        val l = lock()
        assertFalse(l.promptInFlight)
        l.onUnlocked()
        l.onBackground()
        now += 61_000
        l.onForeground()
        assertFalse(l.unlocked.value)
        assertFalse(l.promptInFlight)
        l.onUnlocked()
        l.relock()
        assertFalse(l.promptInFlight)
    }

    @Test fun backgroundWhilePromptInFlightKeepsTheSlot() {
        val l = lock()
        assertTrue(l.beginPrompt())
        l.onBackground()   // credential screen stops the activity (API < 29)
        l.onForeground()
        assertFalse(l.beginPrompt())
        l.endPrompt()      // user cancelled
        assertTrue(l.beginPrompt())
    }

    @Test fun onlyOnePromptAtATime() {
        val l = lock()
        assertTrue(l.beginPrompt())
        assertFalse(l.beginPrompt())
        l.endPrompt()
        assertTrue(l.beginPrompt())
    }

    @Test fun configChangeDoesNotStartRelockClock() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground(changingConfigurations = true)
        now += 120_000
        l.onForeground()
        assertTrue(l.unlocked.value)
    }

    @Test fun realBackgroundStillRelocks() {
        val l = lock().also { it.onUnlocked() }
        l.onBackground(changingConfigurations = false)
        now += 61_000
        l.onForeground()
        assertFalse(l.unlocked.value)
    }

    @Test fun coldStartAsksOnce() {
        val l = lock()
        assertTrue(l.claimArrivalPrompt())
        assertFalse(l.claimArrivalPrompt())   // the prompt closing resumes the activity again
    }

    @Test fun eachTripAwayAsksOnceMore() {
        val l = lock()
        l.claimArrivalPrompt()   // cancelled
        l.onBackground()
        l.onForeground()
        assertTrue(l.claimArrivalPrompt())
        assertFalse(l.claimArrivalPrompt())
    }

    @Test fun rotationDoesNotAskAgain() {
        val l = lock()
        l.claimArrivalPrompt()
        l.onBackground(changingConfigurations = true)
        l.onForeground()
        assertFalse(l.claimArrivalPrompt())
    }

    @Test fun credentialScreenDoesNotAskAgain() {
        val l = lock()
        assertTrue(l.claimArrivalPrompt())
        l.beginPrompt()
        l.onBackground()   // credential screen stops the activity (API < 29)
        l.onForeground()
        l.endPrompt()      // user cancelled
        assertFalse(l.claimArrivalPrompt())
    }

    @Test fun relockAfterExpiryAsks() {
        val l = lock().also { it.claimArrivalPrompt(); it.onUnlocked() }
        l.onBackground()
        now += 61_000
        l.onForeground()
        assertTrue(l.claimArrivalPrompt())
    }

    @Test fun relockWhileInUseWaitsForATap() {
        val l = lock().also { it.claimArrivalPrompt(); it.onUnlocked() }
        l.onBackground()
        now += 5_000
        l.onForeground()   // back within the grace period, still unlocked
        l.relock()
        assertFalse(l.claimArrivalPrompt())
    }

    @Test fun unlockClearsPromptInFlight() {
        val l = lock()
        l.beginPrompt()
        l.onUnlocked()
        assertFalse(l.promptInFlight)
    }
}
