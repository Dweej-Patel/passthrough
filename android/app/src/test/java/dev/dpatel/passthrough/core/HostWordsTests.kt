package dev.dpatel.passthrough.core

import org.junit.Assert.assertEquals
import org.junit.Test

class HostWordsTests {
    @Test fun mac() {
        val w = HostWords(HostKind.MAC, "MacBook Pro")
        assertEquals("Mac", w.noun)
        assertEquals("Macs", w.plural)
        assertEquals("the Mac", w.the)
        assertEquals("The Mac", w.The)
        assertEquals("your Mac", w.your)
        assertEquals("Your Mac", w.Your)
        assertEquals("this Mac", w.thisOne)
        assertEquals("that Mac", w.that)
        assertEquals("MacBook Pro", w.name)
        assertEquals("Remote shell", w.feature)
        assertEquals("Passthrough's Remote Shell settings on the Mac", w.settingsPlace)
        assertEquals("phone", w.device)
    }

    @Test fun pc() {
        val w = HostWords(HostKind.WINDOWS, "Office-PC")
        assertEquals("PC", w.noun)
        assertEquals("PCs", w.plural)
        assertEquals("your PC", w.your)
        assertEquals("this PC", w.thisOne)
        assertEquals("Office-PC", w.name)
        assertEquals("Remote access", w.feature)
        assertEquals("Passthrough's settings on the PC", w.settingsPlace)
    }

    @Test fun neutralAndNameFallback() {
        val w = HostWords.generic()
        assertEquals("computer", w.noun)
        assertEquals("computers", w.plural)
        assertEquals("Your computer", w.name)
        assertEquals("Your PC", HostWords(HostKind.WINDOWS, null).name)
        assertEquals("Your Mac", HostWords(HostKind.MAC, "  ").name)
    }
}
