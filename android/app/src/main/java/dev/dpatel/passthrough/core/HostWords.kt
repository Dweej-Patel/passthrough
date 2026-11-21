package dev.dpatel.passthrough.core

/**
 * The nouns for one computer, by its kind: most sentences differ between a Mac and a PC only
 * in these. [kind] null is the neutral "computer" (a kind this build doesn't know, or no
 * computer in particular). [name] is the computer's own name, when known. Mirrors HostWords in
 * PassthroughCore (Swift); "this phone" is Android's device noun.
 */
class HostWords(val kind: HostKind?, name: String?, val device: String = "phone") {
    /** "Mac", "PC" or "computer". */
    val noun: String = when (kind) {
        HostKind.MAC -> "Mac"
        HostKind.WINDOWS -> "PC"
        null -> "computer"
    }
    /** "Macs", "PCs" or "computers". */
    val plural: String = noun + "s"
    /** "the Mac". */
    val the: String = "the $noun"
    /** "The Mac" (named apart from [the] for the JVM). */
    @get:JvmName("getTheCapitalized")
    val The: String = "The $noun"
    /** "your Mac". */
    val your: String = "your $noun"
    /** "Your Mac". */
    @get:JvmName("getYourCapitalized")
    val Your: String = "Your $noun"
    /** "this Mac" (Swift's `this`). */
    val thisOne: String = "this $noun"
    /** "that Mac". */
    val that: String = "that $noun"
    /** The computer's name, else "Your Mac". */
    val name: String = name?.takeIf { it.isNotBlank() } ?: Your
    /** Where its per-device settings are. */
    val settingsPlace: String = if (kind == HostKind.WINDOWS) "Passthrough's settings on the PC" else "Passthrough's Remote Shell settings on the $noun"
    /** What the setting that lets phones in is called there. */
    val feature: String = if (kind == HostKind.WINDOWS) "Remote access" else "Remote shell"
    val isMac: Boolean get() = kind == HostKind.MAC
    val isPC: Boolean get() = kind == HostKind.WINDOWS

    override fun equals(other: Any?): Boolean = other is HostWords && kind == other.kind && name == other.name && device == other.device
    override fun hashCode(): Int = listOf(kind, name, device).hashCode()
    override fun toString(): String = "HostWords($noun, $name, $device)"

    companion object {
        /** No one computer in particular: lists, pairing, settings. */
        fun generic(device: String = "phone") = HostWords(null, null, device)
    }
}
