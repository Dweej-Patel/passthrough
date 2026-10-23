package dev.dpatel.passthrough.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.io.File

/** protocol/fixtures.json, the file the Swift tests read too. */
object Fixtures {
    val root: JsonObject by lazy {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "protocol/fixtures.json").exists()) dir = dir.parentFile
        val file = File(requireNotNull(dir) { "protocol/fixtures.json not found above ${File("").absolutePath}" }, "protocol/fixtures.json")
        Json.parseToJsonElement(file.readText()).jsonObject
    }

    /** Numbers compare by value (1.0 == 1, 1.7580624E9 == 1758062400.0); strings and booleans by content. */
    fun normalize(e: JsonElement): Any? = when (e) {
        is JsonObject -> e.mapValues { normalize(it.value) }
        is JsonArray -> e.map { normalize(it) }
        is JsonPrimitive -> if (e.isString) e.content else e.content.toBooleanStrictOrNull() ?: e.content.toDoubleOrNull()
    }
}
