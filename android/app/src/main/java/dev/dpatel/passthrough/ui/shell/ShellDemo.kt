package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.BatterySample
import dev.dpatel.passthrough.core.MacEvent
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.MacStates
import dev.dpatel.passthrough.core.MacTimeline
import dev.dpatel.passthrough.core.ShellCredential
import dev.dpatel.passthrough.core.ShellEvent
import dev.dpatel.passthrough.core.ShellHistoryEntry
import dev.dpatel.passthrough.core.ShellPath
import dev.dpatel.passthrough.core.ShellReplayChunk
import dev.dpatel.passthrough.core.ShellSessionInfo

/**
 * Debug builds only: sample Remote shell state for working on the UI without a
 * Mac. Reached solely through MainActivity's [EXTRA] intent extra when
 * BuildConfig.DEBUG; never dials anything and holds no real key.
 *
 *     adb shell am start -n dev.dpatel.passthrough.android/dev.dpatel.passthrough.MainActivity --es pt.demo.shell ready
 *
 * Values: ready, connecting, unreachable, no_access, needs_passcode, key_unavailable.
 */
internal object ShellDemo {
    const val EXTRA = "pt.demo.shell"

    fun reach(value: String): ShellReach = when (value) {
        "connecting" -> ShellReach.CONNECTING
        "unreachable" -> ShellReach.UNREACHABLE
        "no_access" -> ShellReach.NO_ACCESS
        "needs_passcode" -> ShellReach.NEEDS_PASSCODE
        "key_unavailable" -> ShellReach.KEY_UNAVAILABLE
        else -> ShellReach.READY
    }

    val macs = listOf(
        ShellCredential("demo-mac-1", "My MacBook Pro", "", ByteArray(0), "demo-phone", 0, emptyList()),
        ShellCredential("demo-mac-2", "Studio", "", ByteArray(0), "demo-phone", 0, emptyList()),
    )

    private fun now() = System.currentTimeMillis() / 1000.0

    fun sessions(extra: List<String> = emptyList()): List<ShellSessionInfo> {
        val t = now()
        return listOf(
            ShellSessionInfo("8F3A1C2E-5B7D-4E60-8F21-3C4D5E6F7A8B", "claude", startedAt = t - 1900, lastOutputAt = t - 40, running = true,
                waiting = "Do you want to make this edit to HomeView.swift?"),
            ShellSessionInfo("demo-1", "zsh — ~/dev/passthrough", startedAt = t - 4 * 60, lastOutputAt = t - 5, running = true),
            ShellSessionInfo("demo-2", "htop", startedAt = t - 3 * 3600, lastOutputAt = t - 60, running = true),
            ShellSessionInfo("demo-3", "npm run build", startedAt = t - 2 * 3600, lastOutputAt = t - 3600, running = false, exitStatus = 0),
        ) + extra.map { ShellSessionInfo(it, "zsh", startedAt = t, lastOutputAt = t, running = true) }
    }

    val macState = MacState(awake = true, battery = 0.64, charging = false, minutesLeft = 190, batteryFloor = 0.2, hot = false,
        vpn = MacStates.VPN_ON, vpnName = "NordVPN Germany", killSwitch = true, control = true)

    fun timeline(since: Double): MacTimeline {
        val start = now() - (2 * 3600 + 14 * 60)
        fun at(minutes: Double) = start + minutes * 60
        val events = listOf(
            MacEvent(at(0.0), "awake", "Pixel 9 turned Keep awake on"),
            MacEvent(at(0.2), "link", "Off Pixel 9's connection"),
            MacEvent(at(18.0), "vpn", "VPN dropped", "Reconnecting", warning = true),
            MacEvent(at(18.05), "vpn", "VPN reconnected after 2 s", "Kill switch held: nothing left without it"),
            MacEvent(at(38.0), "shell", "npm run build finished", "exit 0 · 34 min", session = "demo-3"),
            MacEvent(at(66.0), "asked", "claude asked", "Do you want to make this edit to HomeView.swift?", session = "demo-1"),
            MacEvent(at(67.0), "answered", "claude got an answer", session = "demo-1"),
            MacEvent(at(131.0), "power", "Plugged in at 41%"),
        )
        val battery = (0..26).map { i ->
            val m = i * 5.0
            BatterySample(at(m), if (m < 131) 0.64 - 0.23 * m / 131 else 0.41 + 0.004 * (m - 131), if (m >= 131) true else null)
        }
        return MacTimeline(since, events.filter { it.t >= since }, battery, now())
    }

    fun history(): List<ShellHistoryEntry> {
        val t = now()
        return listOf(
            ShellHistoryEntry("demo-1", "zsh — ~/dev/passthrough", "Pixel 9", startedAt = t - 4 * 60, bytes = 18_000, cols = 48, rows = 30),
            ShellHistoryEntry("demo-3", "npm run build", "Pixel 9", startedAt = t - 2 * 3600, endedAt = t - 3600, exitStatus = 0, bytes = 92_000),
            ShellHistoryEntry("demo-4", "ssh build-box", "iPhone", startedAt = t - 26 * 3600, endedAt = t - 25 * 3600, exitStatus = 255, bytes = 4_000),
            ShellHistoryEntry("demo-5", "zsh", "Pixel 9", startedAt = t - 3 * 86_400, bytes = 1_200),
        )
    }

    fun output(session: String): ByteArray {
        val esc = "\u001b"
        val prompt = "$esc[1;36mme$esc[0m@$esc[1;35mmacbook$esc[0m ~/dev/passthrough % "
        val text = when (session) {
            "demo-3" -> "${prompt}npm run build\r\n\r\n> passthrough@1.0.0 build\r\n> tsc && vite build\r\n\r\n$esc[32m✓$esc[0m 142 modules transformed.\r\n$esc[32m✓$esc[0m built in 2.31s\r\n"
            else -> buildString {
                append(prompt).append("git status\r\n")
                append("On branch remote-shell\r\nYour branch is up to date with 'origin/remote-shell'.\r\n\r\n")
                append("Changes not staged for commit:\r\n")
                append("  $esc[31mmodified:   android/app/src/main/java/.../LockGate.kt$esc[0m\r\n")
                append("  $esc[31mmodified:   android/app/src/main/java/.../RemoteShellCard.kt$esc[0m\r\n\r\n")
                append(prompt).append("ls\r\n")
                append("$esc[1;34mandroid$esc[0m  $esc[1;34miOS$esc[0m  $esc[1;34mmacOS$esc[0m  $esc[1;34mPackages$esc[0m  README.md\r\n")
                append(prompt)
            }
        }
        return text.toByteArray()
    }

    fun ended(session: String): ShellEvent? = if (session == "demo-3") ShellEvent.Ended(session, 0) else null

    fun transcript(id: String): List<ShellReplayChunk> = listOf(ShellReplayChunk.Output(output(id)))

    val path = ShellPath.DIRECT
}
