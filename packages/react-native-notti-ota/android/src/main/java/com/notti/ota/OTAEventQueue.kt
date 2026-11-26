package com.notti.ota

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * Device event in the shape `POST /ota/events` accepts. Reason codes are the server's fixed list
 * (`internal/ota/events.go`). No personal data: the installation ID travels once per batch.
 */
internal data class OTAEvent(
  val eventId: String,
  val type: String,
  val releaseId: String?,
  val reason: String?,
  val occurredAt: Long
) {
  fun toJson(): JSONObject = JSONObject()
    .put("event_id", eventId)
    .put("type", type)
    .also { json -> releaseId?.let { json.put("release_id", it) } }
    .also { json -> reason?.let { json.put("reason", it) } }
    .put("occurred_at", rfc3339(occurredAt))

  companion object {
    const val DOWNLOADED = "downloaded"
    const val DOWNLOAD_FAILED = "download_failed"
    const val VERIFICATION_FAILED = "verification_failed"
    const val APPLIED = "applied"
    const val ROLLED_BACK = "rolled_back"
    const val REVERTED_TO_EMBEDDED = "reverted_to_embedded"
    const val INTEGRATION_MISSING = "integration_missing"
    const val BUNDLE_OVERRIDDEN = "bundle_overridden"

    fun create(type: String, releaseId: String?, reason: String? = null, now: Long = System.currentTimeMillis()) =
      OTAEvent(UUID.randomUUID().toString(), type, releaseId, reason, now)

    fun fromJson(json: JSONObject) = OTAEvent(
      json.getString("event_id"),
      json.getString("type"),
      json.optString("release_id").ifEmpty { null },
      json.optString("reason").ifEmpty { null },
      json.getLong("occurred_at_ms")
    )

    private fun rfc3339(millis: Long): String =
      SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        .apply { timeZone = TimeZone.getTimeZone("UTC") }
        .format(Date(millis))
  }
}

/** `events.json`: at most [MAX_EVENTS] events, the oldest dropped first (spec OTA-49). */
internal class OTAEventQueue(private val file: File) {
  private val tmp = File(file.parentFile, file.name + ".tmp")

  @Synchronized
  fun add(event: OTAEvent) = write((read() + event).takeLast(MAX_EVENTS))

  @Synchronized
  fun peek(limit: Int = MAX_EVENTS): List<OTAEvent> = read().take(limit)

  @Synchronized
  fun remove(eventIds: Set<String>) = write(read().filter { it.eventId !in eventIds })

  @Synchronized
  fun read(): List<OTAEvent> {
    if (!file.exists()) return emptyList()
    return try {
      val array = JSONArray(file.readText())
      (0 until array.length()).map { OTAEvent.fromJson(array.getJSONObject(it)) }
    } catch (e: Exception) {
      emptyList()
    }
  }

  private fun write(events: List<OTAEvent>) {
    file.parentFile?.mkdirs()
    val array = JSONArray()
    events.forEach { array.put(it.toJson().put("occurred_at_ms", it.occurredAt)) }
    FileOutputStream(tmp).use { out ->
      out.write(array.toString().toByteArray(Charsets.UTF_8))
      out.fd.sync()
    }
    if (!tmp.renameTo(file)) tmp.delete()
  }

  companion object {
    const val MAX_EVENTS = 50
  }
}
