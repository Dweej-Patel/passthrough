package dev.dpatel.passthrough.core

import java.security.KeyPair
import java.security.interfaces.ECPublicKey

/** Stands in for the app: a sealing key whose public half is published to this registry, so grants are stored. */
fun PairingRegistry.withSealing(): KeyPair =
    ShellKeySeal.newKeyPair().also { publishShellSealingKey(ShellKeySeal.x963(it.public as ECPublicKey)) }

/** What the app would open from [clientID]'s pending entry with [sealing]. */
fun PairingRegistry.openedPendingShellKey(clientID: String, sealing: KeyPair): ByteArray? =
    sealedPendingShellKey(clientID)?.let { ShellKeySeal.open(it, clientID, sealing.private, sealing.public as ECPublicKey) }
