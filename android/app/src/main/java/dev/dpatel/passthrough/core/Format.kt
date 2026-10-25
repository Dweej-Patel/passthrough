package dev.dpatel.passthrough.core

/** The Mac's numbers as the apps show them. Mirrors MacFormat in PassthroughCore. */
object MacFormat {
    /** "3 h 10 m", "45 m". */
    fun duration(minutes: Int): String = if (minutes >= 60) "${minutes / 60} h ${minutes % 60} m" else "$minutes m"

    /** A 0-to-1 level as a rounded percent: "82%". */
    fun percent(fraction: Double): String = "${Math.round(fraction * 100)}%"
}
