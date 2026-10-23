package dev.dpatel.passthrough.core

import java.io.ByteArrayOutputStream

/**
 * What the phone needs to reach one Mac's shell: the grant it got over the
 * cable plus the key from the vault. Mirrors ShellCredential in
 * PassthroughCore/ShellClient.swift. Never printed with its key.
 */
data class ShellCredential(
    val macID: String,
    val macName: String,
    /** SHA-256 of the Mac's certificate: the only one this phone accepts. */
    val certSHA256: String,
    val shellKey: ByteArray,
    val phoneID: String,
    val port: Int,
    /** Where to dial the Mac, in order. */
    val addresses: List<String>,
    /** The Mac's iroh endpoint id and home relay, for dialing it from anywhere. */
    val irohID: String? = null,
    val irohRelay: String? = null,
    /** The relay's token, when the Mac's relay needs one. Never printed. */
    val relayToken: String? = null,
) {
    override fun equals(other: Any?): Boolean = other is ShellCredential && macID == other.macID && macName == other.macName &&
        certSHA256 == other.certSHA256 && shellKey.contentEquals(other.shellKey) && phoneID == other.phoneID &&
        port == other.port && addresses == other.addresses &&
        irohID == other.irohID && irohRelay == other.irohRelay && relayToken == other.relayToken

    override fun hashCode(): Int = listOf(macID, macName, certSHA256, shellKey.contentHashCode(), phoneID, port, addresses, irohID, irohRelay, relayToken).hashCode()

    override fun toString(): String = "ShellCredential(macID=$macID, macName=$macName, port=$port, addresses=$addresses, irohID=$irohID, irohRelay=$irohRelay, relayToken=${if (relayToken == null) "none" else "<redacted>"})"
}

/** A `_passthrough-sh._tcp` service seen on the local network; [host] is null until resolved. */
data class ShellService(val name: String, val host: String?, val port: Int) {
    val endpoint: Pair<String, Int>? get() = host?.let { it to port }
}

/** Why Remote shell can't use its keys right now, with the copy to show. */
enum class ShellKeyStatus(val message: String?) {
    READY(null),
    /** No secure lock screen: the vault can't hold keys; pending ones wait. */
    NEEDS_PASSCODE("Set a device passcode to use Remote shell."),
    /** The vault needs a recent unlock; the app relocks so the user can unlock again. */
    LOCKED("Unlock Passthrough to use Remote shell."),
    /** The vault's key was invalidated (new biometrics, lock screen removed); its entries are gone. */
    KEY_UNAVAILABLE("Couldn't read the Remote shell key. Plug into the Mac again to renew access."),
    /** Remote shell needs Android 10 (TLS 1.3); the UI says so. */
    UNSUPPORTED(null),
}

/**
 * How the phone turns its paired Macs into [ShellCredential]s and picks a
 * discovered service for one of them. Mirrors PassthroughCore/ShellCredentials.swift.
 */
object ShellCredentials {
    /**
     * One credential for every client that granted the shell and whose key
     * [key] returns. [manualAddress] is a per-Mac address the user typed; it is
     * dialed before the addresses the Mac sent.
     */
    fun build(
        clients: List<PairedClient>,
        phoneID: String,
        key: (String) -> ByteArray?,
        manualAddress: (String) -> String?,
        relayToken: (String) -> String? = { null },
    ): List<ShellCredential> = clients.mapNotNull { client ->
        val grant = client.shell ?: return@mapNotNull null
        val shellKey = key(client.id) ?: return@mapNotNull null
        ShellCredential(client.id, grant.macName, grant.certSHA256, shellKey, phoneID, grant.port,
            addresses(grant.addresses, manualAddress(client.id)),
            grant.irohID, grant.irohRelay, if (grant.irohID == null) null else relayToken(client.id))
    }

    /**
     * Keeps what the connected Mac says about reaching it ([ShellEvent.MacInfo]:
     * iroh details, addresses) with its grant in [registry], never touching the
     * shell key, and returns [credential] as the next connect will build it
     * (with [manualAddress] first). Null when the Mac has no grant here.
     * Blocking (storage): call off the main thread.
     */
    fun applyMacInfo(registry: PairingRegistry, credential: ShellCredential, info: ShellEvent.MacInfo, manualAddress: String?): ShellCredential? {
        if (!registry.updateShellInfo(credential.macID, info.irohID, info.irohRelay, info.relayToken, info.addresses)) return null
        val grant = registry.clients.firstOrNull { it.id == credential.macID }?.shell ?: return null
        return credential.copy(
            addresses = addresses(grant.addresses, manualAddress),
            irohID = grant.irohID,
            irohRelay = grant.irohRelay,
            relayToken = if (grant.irohID == null) null else registry.relayToken(credential.macID),
        )
    }

    /**
     * Whether two credentials authorize the same way (key, pin, phone, port),
     * so a live connection made with [a] can stay when only how to dial the Mac
     * next time changed.
     */
    fun sameKey(a: ShellCredential, b: ShellCredential): Boolean =
        a.shellKey.contentEquals(b.shellKey) && a.certSHA256 == b.certSHA256 && a.phoneID == b.phoneID && a.port == b.port

    /** The manual address (trimmed; ignored when blank) first, then the granted ones, without repeats. */
    fun addresses(granted: List<String>, manual: String?): List<String> {
        val typed = manual?.trim().orEmpty()
        return ((if (typed.isEmpty()) emptyList() else listOf(typed)) + granted).distinct()
    }

    /**
     * The service to dial for [macName]: the one named after the Mac (the
     * listener advertises under the computer name), else the only result when
     * this phone has shell access to exactly one Mac and exactly one is
     * advertising. Null when it can't be tied to this Mac.
     */
    fun discovered(among: List<ShellService>, macName: String, shellMacCount: Int): ShellService? =
        among.firstOrNull { it.name == macName } ?: among.singleOrNull()?.takeIf { shellMacCount == 1 }

    /**
     * Undoes DNS-SD presentation escapes (`\032` for a space, `\.`) that some
     * Android versions leave in NSD service names; `\DDD` are UTF-8 bytes.
     */
    fun unescapeServiceName(name: String): String {
        if ('\\' !in name) return name
        val out = ByteArrayOutputStream()
        val plain = StringBuilder()
        fun flush() { out.write(plain.toString().toByteArray(Charsets.UTF_8)); plain.clear() }
        var i = 0
        while (i < name.length) {
            val c = name[i]
            if (c == '\\' && i + 3 < name.length && name.substring(i + 1, i + 4).all { it in '0'..'9' }) {
                val v = name.substring(i + 1, i + 4).toInt()
                if (v <= 255) { flush(); out.write(v); i += 4; continue }
            }
            if (c == '\\' && i + 1 < name.length) { plain.append(name[i + 1]); i += 2; continue }
            plain.append(c)
            i++
        }
        flush()
        return out.toString(Charsets.UTF_8.name())
    }
}
