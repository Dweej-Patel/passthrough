package dev.dpatel.passthrough.ui.shell

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Phones know a PC: no new sentence in the app's UI or service names a Mac by accident. A
 * string literal that says "Mac", "Macs" or "macOS" must come from [HostCopy] (or
 * [dev.dpatel.passthrough.core.HostWords]), say "Mac or PC", or sit on a line that ends in
 * `// mac-only` (a row or feature only a Mac's page shows).
 */
class HostWordingTests {
    private val allowed = setOf("HostCopy.kt", "ShellDemo.kt")
    private val literal = Regex("\"(?:[^\"\\\\]|\\\\.)*\"")
    private val mac = Regex("\\b(Mac|Macs|macOS)\\b")

    private fun sources(): List<File> {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "android/app/src/main/java").exists() && !File(dir, "src/main/java").exists()) dir = dir.parentFile
        val base = requireNotNull(dir) { "app sources not found above ${File("").absolutePath}" }
        val main = File(base, "android/app/src/main/java").takeIf { it.exists() } ?: File(base, "src/main/java")
        val app = File(main, "dev/dpatel/passthrough")
        return listOf(File(app, "ui"), File(app, "service")).flatMap { root -> root.walkTopDown().filter { it.extension == "kt" }.toList() }
    }

    @Test fun noStrayMacLiterals() {
        val files = sources()
        assertTrue("found the sources", files.size > 10)
        val stray = mutableListOf<String>()
        for (file in files) {
            if (file.name in allowed) continue
            file.readLines().forEachIndexed { i, line ->
                val code = line.trim()
                if (code.startsWith("//") || code.startsWith("*") || code.startsWith("/*") || code.endsWith("// mac-only") || "// mac-only" in code) return@forEachIndexed
                val hits = literal.findAll(line).map { it.value.replace("Mac or PC", "") }.filter { mac.containsMatchIn(it) }.toList()
                if (hits.isNotEmpty()) stray += "${file.name}:${i + 1}: ${hits.joinToString()}"
            }
        }
        assertTrue("Mac named in UI copy (use HostWords / HostCopy, or mark the line // mac-only):\n" + stray.joinToString("\n"), stray.isEmpty())
    }
}
