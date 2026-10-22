package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.ShellError
import dev.dpatel.passthrough.core.ShellHistoryEntry
import dev.dpatel.passthrough.core.ShellPath
import dev.dpatel.passthrough.core.ShellSessionInfo
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShellLogicTests {
    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)

    // Reach and copy

    @Test fun copyMatchesTheOtherApps() {
        assertEquals("Remote shell needs Android 10 or later.", ShellReach.UNSUPPORTED.message)
        assertEquals("Turn on Remote shell in Passthrough on your Mac, then connect this phone with the cable once.", ShellReach.NO_ACCESS.message)
        assertEquals("Can't reach your Mac. Use the same Wi-Fi, or turn on Tailscale on both devices.", ShellReach.UNREACHABLE.message)
        assertEquals("Unlock Passthrough to use Remote shell.", ShellReach.LOCKED.message)
        assertEquals("Set a device passcode to use Remote shell.", ShellReach.NEEDS_PASSCODE.message)
        assertEquals("Couldn't read the Remote shell key. Plug into the Mac again to renew access.", ShellReach.KEY_UNAVAILABLE.message)
        assertNull(ShellReach.CONNECTING.message)
        assertNull(ShellReach.READY.message)
    }

    @Test fun unreachableCopyWhenTriedFromAnywhere() {
        assertEquals("Can't reach your Mac. Check that Remote shell is on and the Mac is awake.", ShellReach.UNREACHABLE.message(fromAnywhere = true))
        assertEquals(ShellReach.UNREACHABLE.message, ShellReach.UNREACHABLE.message(fromAnywhere = false))
        assertEquals(ShellReach.LOCKED.message, ShellReach.LOCKED.message(fromAnywhere = true))
    }

    @Test fun pathLabels() {
        assertEquals("direct", ShellPath.DIRECT.label)
        assertEquals("via relay", ShellPath.RELAY.label)
        assertNull(ShellPath.LOCAL.label)
        assertNull(ShellPath.UNKNOWN.label)
    }

    @Test fun reachBeforeKeys() {
        assertEquals(ShellReach.UNSUPPORTED, ShellReach.beforeKeys(supported = false, unlocked = true, deviceSecure = true, granting = true))
        assertEquals(ShellReach.LOCKED, ShellReach.beforeKeys(supported = true, unlocked = false, deviceSecure = true, granting = true))
        assertEquals(ShellReach.NO_ACCESS, ShellReach.beforeKeys(supported = true, unlocked = false, deviceSecure = true, granting = false))
        assertEquals(ShellReach.NEEDS_PASSCODE, ShellReach.beforeKeys(supported = true, unlocked = true, deviceSecure = false, granting = true))
        assertEquals(ShellReach.NO_ACCESS, ShellReach.beforeKeys(supported = true, unlocked = true, deviceSecure = false, granting = false))
        assertNull(ShellReach.beforeKeys(supported = true, unlocked = true, deviceSecure = true, granting = true))
    }

    @Test fun reachWithoutCredential() {
        assertEquals(ShellReach.NO_ACCESS, ShellReach.withoutCredential(granting = false, anyLocked = true, keyLost = true))
        assertEquals(ShellReach.KEY_UNAVAILABLE, ShellReach.withoutCredential(granting = true, anyLocked = true, keyLost = false))
        assertEquals(ShellReach.KEY_UNAVAILABLE, ShellReach.withoutCredential(granting = true, anyLocked = false, keyLost = true))
        assertEquals(ShellReach.NO_ACCESS, ShellReach.withoutCredential(granting = true, anyLocked = false, keyLost = false))
    }

    @Test fun sessionLimitIsExplained() {
        assertEquals("Your Mac already has 8 sessions open. End one to start another.", ShellError.TOO_MANY_SESSIONS.message())
        assertNull(ShellError.NO_SUCH_SESSION.message())
    }

    // Formatting

    @Test fun sessionStatus() {
        val running = ShellSessionInfo("a", "zsh", startedAt = 1000.0, lastOutputAt = 1100.0, running = true)
        assertEquals("running · 4m", ShellFormat.status(running, 1000.0 + 4 * 60 + 30))
        val exited = running.copy(running = false, exitStatus = 2)
        assertEquals("exited 2 · 1h", ShellFormat.status(exited, 1100.0 + 3600))
        assertEquals("exited · <1m", ShellFormat.status(exited.copy(exitStatus = null), 1100.0))
    }

    @Test fun ages() {
        assertEquals("<1m", ShellFormat.age(-5.0))
        assertEquals("<1m", ShellFormat.age(59.0))
        assertEquals("1m", ShellFormat.age(60.0))
        assertEquals("23h", ShellFormat.age(86_399.0))
        assertEquals("2d", ShellFormat.age(2 * 86_400.0))
    }

    @Test fun historyStatus() {
        val e = ShellHistoryEntry("a", "zsh", "Pixel", startedAt = 0.0, bytes = 1)
        assertEquals("running", ShellFormat.historyStatus(e, running = true))
        assertEquals("interrupted", ShellFormat.historyStatus(e, running = false))
        assertEquals("exited 0", ShellFormat.historyStatus(e.copy(endedAt = 5.0, exitStatus = 0), running = false))
        assertEquals("ended", ShellFormat.historyStatus(e.copy(endedAt = 5.0), running = false))
    }

    // Keys

    @Test fun ctrlMapping() {
        assertEquals(3, TerminalKeys.ctrl('c'.code))
        assertEquals(3, TerminalKeys.ctrl('C'.code))
        assertEquals(0, TerminalKeys.ctrl(' '.code))
        assertEquals(27, TerminalKeys.ctrl('['.code))
        assertEquals(28, TerminalKeys.ctrl('\\'.code))
        assertEquals(31, TerminalKeys.ctrl('/'.code))
        assertEquals(127, TerminalKeys.ctrl('8'.code))
        assertEquals('|'.code, TerminalKeys.ctrl('|'.code))
    }

    @Test fun typedEncodesUtf8WithModifiers() {
        assertArrayEquals(bytes("é"), TerminalKeys.typed('é'.code, ctrl = false))
        assertArrayEquals(byteArrayOf(3), TerminalKeys.typed('c'.code, ctrl = true))
        assertArrayEquals(byteArrayOf(0x1b, 'b'.code.toByte()), TerminalKeys.typed('b'.code, ctrl = false, alt = true))
        assertArrayEquals(bytes("😀"), TerminalKeys.typed(0x1F600, ctrl = false))
        assertArrayEquals(bytes("�"), TerminalKeys.encode(0xD800))
    }

    @Test fun arrowsFollowCursorMode() {
        assertArrayEquals(bytes("\u001b[A"), TerminalKeys.arrow(ExtraKey.UP, applicationCursor = false, ctrl = false))
        assertArrayEquals(bytes("\u001bOD"), TerminalKeys.arrow(ExtraKey.LEFT, applicationCursor = true, ctrl = false))
        assertArrayEquals(bytes("\u001b[1;5C"), TerminalKeys.arrow(ExtraKey.RIGHT, applicationCursor = true, ctrl = true))
        assertArrayEquals(bytes("\u001b[B"), TerminalKeys.arrow(ExtraKey.DOWN, applicationCursor = false, ctrl = false))
    }

    @Test fun keyRowBytes() {
        assertNull(TerminalKeys.extraKey(ExtraKey.CTRL, false, false))
        assertNull(TerminalKeys.extraKey(ExtraKey.PASTE, false, ctrl = true))   // the screen pastes the clipboard
        assertArrayEquals(byteArrayOf(0x1b), TerminalKeys.extraKey(ExtraKey.ESC, false, ctrl = true))
        assertArrayEquals(byteArrayOf(0x09), TerminalKeys.extraKey(ExtraKey.TAB, false, false))
        assertArrayEquals(bytes("|"), TerminalKeys.extraKey(ExtraKey.PIPE, false, ctrl = true))
        assertArrayEquals(bytes("~"), TerminalKeys.extraKey(ExtraKey.TILDE, false, false))
    }

    // Search

    @Test fun findsForwardAndBackwardWithWrap() {
        val lines = listOf("alpha", "beta Alpha", "gamma")
        assertEquals(0 to 0, findInLines(lines, "alpha", null, forward = true))
        assertEquals(1 to 5, findInLines(lines, "alpha", 0 to 0, forward = true))
        assertEquals(0 to 0, findInLines(lines, "alpha", 1 to 5, forward = true))
        assertEquals(1 to 5, findInLines(lines, "alpha", null, forward = false))
        assertEquals(0 to 0, findInLines(lines, "alpha", 1 to 5, forward = false))
        assertEquals(1 to 5, findInLines(lines, "alpha", 0 to 0, forward = false))
        assertNull(findInLines(lines, "delta", null, forward = true))
        assertNull(findInLines(lines, "", null, forward = true))
    }

    @Test fun findsTheOnlyMatchAgain() {
        val lines = listOf("one", "two")
        assertEquals(1 to 0, findInLines(lines, "two", 1 to 0, forward = true))
        assertEquals(1 to 0, findInLines(lines, "two", 1 to 0, forward = false))
    }

    // Ended sessions

    private fun info(id: String, running: Boolean, exit: Int? = null) = ShellSessionInfo(id, id, 0.0, 0.0, running, exit)

    @Test fun endedMessageMakesSessionReadOnly() {
        val ended = ShellEndedSessions().ended("a", 0)
        assertTrue(ended.isEnded("a"))
        assertFalse(ended.isWritable("a", listOf("a")))
        assertTrue(ended.isWritable("b", listOf("b")))
        assertEquals(0, ended.exitStatus("a"))
    }

    @Test fun closedTabOrNothingShown() {
        val ended = ShellEndedSessions()
        assertFalse(ended.isWritable("a", emptyList()))
        assertTrue(ended.isWritable(null, emptyList()))
    }

    @Test fun negativeStatusMeansNone() {
        val ended = ShellEndedSessions().ended("a", -1)
        assertTrue(ended.isEnded("a"))
        assertNull(ended.exitStatus("a"))
        assertEquals("Session closed — read-only", ended.banner("a"))
    }

    @Test fun messageWithoutStatusKeepsKnownStatus() {
        val ended = ShellEndedSessions().apply(listOf(info("a", running = false, exit = 3))).ended("a", -1)
        assertEquals(3, ended.exitStatus("a"))
    }

    @Test fun listMarksStoppedSessionsEnded() {
        val ended = ShellEndedSessions().apply(listOf(info("a", true), info("b", false, 130), info("c", false)))
        assertFalse(ended.isEnded("a"))
        assertEquals(130, ended.exitStatus("b"))
        assertTrue(ended.isEnded("c"))
        assertNull(ended.exitStatus("c"))
    }

    @Test fun unlistedEndedSessionsAreForgottenUnlessKept() {
        val ended = ShellEndedSessions().ended("a", 0).ended("b", 1).apply(emptyList(), keeping = setOf("b"))
        assertFalse(ended.isEnded("a"))
        assertTrue(ended.isEnded("b"))
        assertFalse(ended.forget("b").isEnded("b"))
    }

    @Test fun endedBannerCopy() {
        assertEquals("Session ended (exit 0) — read-only", ShellEndedSessions.banner(0))
        assertEquals("Session ended (exit 127) — read-only", ShellEndedSessions.banner(127))
        assertEquals("Session closed — read-only", ShellEndedSessions.banner(null))
        assertNull(ShellEndedSessions().banner("a"))
        assertEquals("Session ended (exit 2) — read-only", ShellEndedSessions().ended("a", 2).banner("a"))
    }
}
