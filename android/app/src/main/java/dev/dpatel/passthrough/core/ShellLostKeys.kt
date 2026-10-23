package dev.dpatel.passthrough.core

/**
 * Which Macs' shell keys the vault lost when its Keystore key was
 * invalidated, tracked per Mac: a Mac granting a key again clears only its
 * own loss. Pure, so the vault's bookkeeping is testable without a Keystore.
 */
object ShellLostKeys {
    /** The vault was wiped while it held keys for [stored]: those are lost too. */
    fun afterWipe(lost: Set<String>, stored: Collection<String>): Set<String> = lost + stored

    /** [macID]'s new key is in the vault: it is no longer lost. Others stay lost. */
    fun afterAdopt(lost: Set<String>, macID: String): Set<String> = lost - macID

    /** Only Macs still paired can be lost. */
    fun afterPrune(lost: Set<String>, paired: Set<String>): Set<String> = lost.filterTo(HashSet()) { it in paired }

    /** The old single "lost" flag is dropped: each granted Mac in [unkeyed] (no stored key) is lost. */
    fun afterLegacyMigration(lost: Set<String>, unkeyed: Collection<String>): Set<String> = lost + unkeyed

    /** A Mac was forgotten: the vault's [current] status stays LOCKED if it was, else it is [fresh]. */
    fun afterDelete(current: ShellKeyStatus, fresh: ShellKeyStatus): ShellKeyStatus =
        if (current == ShellKeyStatus.LOCKED) current else fresh

    /** [base] (the vault's status), or [ShellKeyStatus.KEY_UNAVAILABLE] when it is ready but [macID]'s key was lost. */
    fun status(base: ShellKeyStatus, lost: Set<String>, macID: String): ShellKeyStatus =
        if (base == ShellKeyStatus.READY && macID in lost) ShellKeyStatus.KEY_UNAVAILABLE else base
}
