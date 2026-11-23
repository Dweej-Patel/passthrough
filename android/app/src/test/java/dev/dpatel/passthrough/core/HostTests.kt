package dev.dpatel.passthrough.core

import kotlinx.serialization.builtins.ListSerializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Phones know a PC: what kind a computer is, and which of its shells New shell opens. */
class HostTests {
    private val shells = listOf(
        HostShell("pwsh", "PowerShell", default = true),
        HostShell("cmd", "Command Prompt"),
        HostShell("wsl:Ubuntu", "Ubuntu"),
    )

    @Test fun kindPrecedence() {
        assertEquals("never said: a Mac", HostKind.MAC, Hosts.kind(null, null))
        assertEquals(HostKind.WINDOWS, Hosts.kind(null, "windows"))
        assertEquals(HostKind.MAC, Hosts.kind(null, "mac"))
        assertEquals("an unknown stored kind is ignored", HostKind.MAC, Hosts.kind(null, "toaster"))
        assertEquals("the live host wins", HostKind.WINDOWS, Hosts.kind(HostInfo(kind = "windows"), "mac"))
        assertEquals(HostKind.MAC, Hosts.kind(HostInfo(kind = "mac"), "windows"))
        assertNull("a live kind this build doesn't know: neutral, never a Mac", Hosts.kind(HostInfo(kind = "toaster"), "mac"))
    }

    @Test fun wireNames() {
        assertEquals(HostKind.WINDOWS, HostKind.fromWire("windows"))
        assertEquals(HostKind.MAC, HostKind.fromWire("mac"))
        assertNull(HostKind.fromWire("Windows"))
        assertNull(HostKind.fromWire(null))
    }

    @Test fun preferredShell() {
        val host = HostInfo(kind = "windows", shells = shells)
        assertEquals("the host's default", "pwsh", Hosts.preferredShell(host, null)?.id)
        assertEquals("the last chosen", "wsl:Ubuntu", Hosts.preferredShell(host, "wsl:Ubuntu")?.id)
        assertEquals("a remembered shell the host no longer lists is not used", "pwsh", Hosts.preferredShell(host, "gitbash")?.id)
        assertEquals("no default: the first", "cmd", Hosts.preferredShell(HostInfo(kind = "windows", shells = shells.drop(1)), null)?.id)
        assertNull(Hosts.preferredShell(HostInfo(kind = "windows"), "pwsh"))
        assertNull(Hosts.preferredShell(null, "pwsh"))
    }

    @Test fun choiceOnlyWithMoreThanOneShell() {
        assertTrue(Hosts.offersChoice(HostInfo(kind = "windows", shells = shells)))
        assertFalse("a Mac's one login shell", Hosts.offersChoice(HostInfo(kind = "mac", shells = listOf(HostShell(HostShell.LOGIN_ID, "zsh", default = true)))))
        assertFalse(Hosts.offersChoice(HostInfo(kind = "windows")))
        assertFalse(Hosts.offersChoice(null))
    }

    @Test fun cleaningKeepsLimits() {
        val many = (1..100).map { HostShell("s$it", "Shell $it") }
        val host = HostInfo(
            kind = "windows", user = "me\nyou", os = "W".repeat(10_000),
            shells = many + HostShell("has space", "Bad") + HostShell("s1", "Duplicate"),
        ).cleaned()!!
        assertEquals(HostInfo.MAX_SHELLS, host.shells?.size)
        assertTrue(host.shells!!.none { it.id == "has space" })
        assertNull("a newline: dropped", host.user)
        assertNull("too long: dropped", host.os)
        assertNull("no kind: not a host", HostInfo(os = "Windows 11").cleaned())
    }

    @Test fun pairedClientsWithAndWithoutAKindRoundTrip() {
        val list = listOf(PairedClient("mac1", "MacBook", "h", 0), PairedClient("pc1", "Office-PC", "h", 0, hostKind = "windows"))
        val json = ControlEnvelope.json.encodeToString(ListSerializer(PairedClient.serializer()), list)
        assertFalse("absent, not null, for a Mac that never said", json.contains("\"hostKind\":null"))
        assertEquals(list, ControlEnvelope.json.decodeFromString(ListSerializer(PairedClient.serializer()), json))
    }

    @Test fun farewellRoundTrips() {
        val f = HostFarewell(HostFarewell.SLEEPING, 1_700_000_000_000)
        assertEquals(f, ControlEnvelope.json.decodeFromString(HostFarewell.serializer(), ControlEnvelope.json.encodeToString(HostFarewell.serializer(), f)))
        assertEquals(HostInfo.GOING_AWAY_REASONS, listOf(HostFarewell.SLEEPING, HostFarewell.TURNED_OFF, HostFarewell.SHUTTING_DOWN))
    }

    @Test fun onlyMacsAreOnlineThroughThisPhone() {
        val stats = ProviderStats(macs = listOf(ConnectedMac("m", "MacBook", 0), ConnectedMac("p", "Office-PC", 0, kind = "windows"),
            ConnectedMac("m2", "iMac", 0, kind = "mac")))
        assertEquals(listOf("m", "m2"), stats.onlineMacs.map { it.id })
    }
}
