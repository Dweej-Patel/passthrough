package dev.dpatel.passthrough.core

import org.junit.Assert.assertEquals
import org.junit.Test

class ShellLostKeysTests {
    /** After a wipe, one Mac granting again must not hide that the others' keys are still lost. */
    @Test fun adoptingOneMacKeepsTheOthersLost() {
        var lost = ShellLostKeys.afterWipe(emptySet(), listOf("a", "b", "c"))
        assertEquals(setOf("a", "b", "c"), lost)
        lost = ShellLostKeys.afterAdopt(lost, "a")
        assertEquals(setOf("b", "c"), lost)
        assertEquals(ShellKeyStatus.READY, ShellLostKeys.status(ShellKeyStatus.READY, lost, "a"))
        assertEquals(ShellKeyStatus.KEY_UNAVAILABLE, ShellLostKeys.status(ShellKeyStatus.READY, lost, "b"))
        // A Mac that never had a key stored is not lost.
        assertEquals(ShellKeyStatus.READY, ShellLostKeys.status(ShellKeyStatus.READY, lost, "d"))
        // The vault's own state still wins.
        assertEquals(ShellKeyStatus.LOCKED, ShellLostKeys.status(ShellKeyStatus.LOCKED, lost, "b"))
    }

    @Test fun aSecondWipeAddsToTheLostAndPruneDropsUnpairedMacs() {
        var lost = ShellLostKeys.afterWipe(setOf("b"), listOf("a"))
        assertEquals(setOf("a", "b"), lost)
        lost = ShellLostKeys.afterPrune(lost, setOf("a", "z"))
        assertEquals(setOf("a"), lost)
        assertEquals(emptySet<String>(), ShellLostKeys.afterAdopt(lost, "a"))
    }

    @Test fun legacyFlagMarksGrantedMacsWithoutAKeyLost() {
        val lost = ShellLostKeys.afterLegacyMigration(setOf("x"), listOf("a", "b"))
        assertEquals(setOf("x", "a", "b"), lost)
        assertEquals(ShellKeyStatus.KEY_UNAVAILABLE, ShellLostKeys.status(ShellKeyStatus.READY, lost, "a"))
        assertEquals(ShellKeyStatus.READY, ShellLostKeys.status(ShellKeyStatus.READY, lost, "keyed"))
        assertEquals(emptySet<String>(), ShellLostKeys.afterLegacyMigration(emptySet(), emptyList()))
    }

    @Test fun deletingAMacKeepsALockedVaultLocked() {
        assertEquals(ShellKeyStatus.LOCKED, ShellLostKeys.afterDelete(ShellKeyStatus.LOCKED, ShellKeyStatus.READY))
        assertEquals(ShellKeyStatus.READY, ShellLostKeys.afterDelete(ShellKeyStatus.KEY_UNAVAILABLE, ShellKeyStatus.READY))
    }
}
