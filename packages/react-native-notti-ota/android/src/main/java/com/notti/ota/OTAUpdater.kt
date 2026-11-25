package com.notti.ota

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.Executor
import java.util.concurrent.Executors

internal class OTAUpdate(
  val releaseId: String,
  val manifest: ByteArray,
  val signature: ByteArray,
  val keyId: String,
  val downloadUrl: String,
  val mandatory: Boolean
)

internal sealed class OTACheckResult {
  class Update(val update: OTAUpdate) : OTACheckResult()
  object NoUpdate : OTACheckResult()
  object RevertToEmbedded : OTACheckResult()
}

/** A failed download, with the `download_failed` reason code the server accepts. */
internal class OTADownloadException(val reason: String, message: String) : Exception(message) {
  companion object {
    const val NETWORK = "network"
    const val HTTP_STATUS = "http_status"
    const val TIMEOUT = "timeout"
    const val NO_SPACE = "no_space"
  }
}

/** `POST /ota/check`, `POST /ota/events` and the archive download, over HttpURLConnection. */
internal class OTAApiClient(
  private val config: OTAConfig,
  private val connectTimeoutMs: Int = 10_000,
  private val readTimeoutMs: Int = 15_000
) {
  private val appBase = "${config.baseUrl}/v1/apps/${config.appId}/ota"

  /** Any failure, including 429, is "no update": the device keeps what it runs. */
  fun check(body: JSONObject): OTACheckResult {
    val response = try {
      post("$appBase/check", body)
    } catch (e: IOException) {
      Log.w(TAG, "Live updates: update check failed (${e.javaClass.simpleName})")
      return OTACheckResult.NoUpdate
    }
    if (response.first !in 200..299) {
      Log.w(TAG, "Live updates: update check answered HTTP ${response.first}")
      return OTACheckResult.NoUpdate
    }
    return try {
      val json = JSONObject(response.second)
      val update = json.optJSONObject("update")
      when {
        update != null -> OTACheckResult.Update(
          OTAUpdate(
            releaseId = update.getString("release_id"),
            manifest = Base64.decode(update.getString("manifest"), Base64.DEFAULT),
            signature = Base64.decode(update.getString("signature"), Base64.DEFAULT),
            keyId = update.getString("key_id"),
            downloadUrl = update.getString("download_url"),
            mandatory = update.optBoolean("mandatory", false)
          )
        )
        json.optBoolean("revert_to_embedded", false) -> OTACheckResult.RevertToEmbedded
        else -> OTACheckResult.NoUpdate
      }
    } catch (e: Exception) {
      Log.w(TAG, "Live updates: unreadable update check response")
      OTACheckResult.NoUpdate
    }
  }

  /**
   * True when the server took the batch, or rejected it as invalid (422): a batch it will never
   * accept must not block the queue. Network errors, 429 and 5xx keep the events for later.
   */
  fun postEvents(installationId: String, events: List<OTAEvent>): Boolean {
    val body = JSONObject()
      .put("installation_id", installationId)
      .put("platform", "android")
      .put("events", JSONArray().also { array -> events.forEach { array.put(it.toJson()) } })
    return try {
      val status = post("$appBase/events", body).first
      status in 200..299 || status == 422
    } catch (e: IOException) {
      false
    }
  }

  /** Streams [url] (a presigned GET, sent without credentials) into [dest], at most [maxBytes]. */
  fun download(url: String, dest: File, maxBytes: Long) {
    try {
      val connection = open(url)
      try {
        val status = connection.responseCode
        if (status != 200) throw OTADownloadException(OTADownloadException.HTTP_STATUS, "download answered HTTP $status")
        connection.inputStream.use { input ->
          FileOutputStream(dest).use { out ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
              val n = input.read(buffer)
              if (n < 0) break
              total += n
              if (total > maxBytes) {
                throw OTAVerificationException(OTAVerificationException.HASH, "archive is larger than the manifest says")
              }
              out.write(buffer, 0, n)
            }
            val expected = connection.contentLengthLong
            if (expected >= 0 && total != expected) throw IOException("connection closed after $total of $expected bytes")
            out.fd.sync()
          }
        }
      } finally {
        connection.disconnect()
      }
    } catch (e: SocketTimeoutException) {
      throw OTADownloadException(OTADownloadException.TIMEOUT, "download timed out")
    } catch (e: IOException) {
      val reason = if (OTAExtractor.isNoSpace(e)) OTADownloadException.NO_SPACE else OTADownloadException.NETWORK
      throw OTADownloadException(reason, "download failed (${e.javaClass.simpleName})")
    }
  }

  private fun post(url: String, body: JSONObject): Pair<Int, String> {
    val connection = open(url)
    try {
      connection.requestMethod = "POST"
      connection.doOutput = true
      connection.setRequestProperty("Authorization", "Bearer ${config.clientKey}")
      connection.setRequestProperty("Content-Type", "application/json")
      connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
      val status = connection.responseCode
      val stream = if (status in 200..299) connection.inputStream else connection.errorStream
      val text = stream?.use { String(it.readBytes(), Charsets.UTF_8) } ?: ""
      return status to text
    } finally {
      connection.disconnect()
    }
  }

  private fun open(url: String): HttpURLConnection =
    (URL(url).openConnection() as HttpURLConnection).apply {
      connectTimeout = connectTimeoutMs
      readTimeout = readTimeoutMs
      instanceFollowRedirects = true
      useCaches = false
    }
}

/**
 * Check, download, verify and promote a Live update in the background, then flush the event
 * queue. A new release only becomes `pending`: it is loaded on the next cold start (spec OTA-16).
 */
internal class OTAUpdater(
  private val config: OTAConfig,
  private val store: OTAStateStore,
  private val events: OTAEventQueue,
  private val api: OTAApiClient,
  private val embeddedHermesVersion: () -> Int?,
  private val executor: Executor = Executors.newSingleThreadExecutor(),
  private val clock: () -> Long = System::currentTimeMillis,
  private val freeSpace: (File) -> Long = { it.usableSpace }
) {
  private var checkedThisProcess = false

  /** First call per process checks; later foreground calls check only after [CHECK_INTERVAL_MS]. */
  fun onReady() {
    executor.execute {
      try {
        val state = store.load() ?: return@execute
        val due = !checkedThisProcess || clock() - state.lastCheckAt >= CHECK_INTERVAL_MS
        if (due) {
          checkedThisProcess = true
          check()
        }
        flushEvents()
      } catch (t: Throwable) {
        Log.e(TAG, "Live updates: update check stopped (${t.javaClass.simpleName})")
      }
    }
  }

  fun check() {
    val state = store.update { it.copy(lastCheckAt = clock()) }
    val body = JSONObject()
      .put("platform", "android")
      .put("channel", config.channel)
      .put("runtime_version", config.runtimeVersion)
      .put("binary_identity", BinaryIdentity.digest(state.binaryIdentity ?: ""))
      .put("installation_id", state.installationId)
      .put("sdk_version", SDK_VERSION)
      .put("hermes_bytecode_version", embeddedHermesVersion() ?: 0)
    state.stable?.let { body.put("current_release_id", it.releaseId) }

    when (val result = api.check(body)) {
      is OTACheckResult.NoUpdate -> Unit
      is OTACheckResult.RevertToEmbedded -> store.update {
        if (it.stable == null && it.pending == null) it else it.copy(revertToEmbedded = true)
      }
      is OTACheckResult.Update -> apply(result.update)
    }
  }

  private fun apply(update: OTAUpdate) {
    val state = store.load() ?: return
    val id = update.releaseId
    if (id in state.blocklist || id == state.pending?.releaseId || id == state.stable?.releaseId) return

    val archive = File(store.tmpDir, "$id.tar.gz")
    val extracted = File(store.tmpDir, id)
    try {
      val manifest = OTAManifest.parse(update.manifest)
      if (manifest.releaseId != id) {
        throw OTAVerificationException(OTAVerificationException.INVALID_ARCHIVE, "manifest is for another release")
      }
      OTAVerifier.verifySignature(update.manifest, update.signature, update.keyId, config.publicKeys)
      OTAVerifier.checkCompatible(manifest, config, embeddedHermesVersion())

      store.tmpDir.mkdirs()
      archive.delete()
      extracted.deleteRecursively()
      if (freeSpace(store.tmpDir) < manifest.archiveSize * SPACE_FACTOR) {
        throw OTADownloadException(OTADownloadException.NO_SPACE, "not enough free space")
      }
      api.download(update.downloadUrl, archive, manifest.archiveSize)
      OTAVerifier.verifyAndExtract(archive, manifest, extracted)
      archive.delete()

      val target = store.releaseDir(id)
      target.deleteRecursively()
      store.releasesDir.mkdirs()
      if (!extracted.renameTo(target)) throw IOException("could not promote the release")

      val next = store.update {
        it.copy(
          pending = ReleasePointer(id, manifest.bundle, update.mandatory),
          attempt = null, failedCount = 0, interruptedCount = 0, lastFailureReason = null, revertToEmbedded = false
        )
      }
      store.pruneReleases(setOfNotNull(next.stable?.releaseId, next.pending?.releaseId))
      events.add(OTAEvent.create(OTAEvent.DOWNLOADED, id, now = clock()))
      Log.i(TAG, "Live updates: release $id downloaded, it loads on the next cold start")
    } catch (e: OTADownloadException) {
      Log.w(TAG, "Live updates: download of $id failed (${e.reason})")
      events.add(OTAEvent.create(OTAEvent.DOWNLOAD_FAILED, id, e.reason, clock()))
    } catch (e: OTAVerificationException) {
      Log.w(TAG, "Live updates: release $id rejected (${e.reason}): ${e.message}")
      events.add(OTAEvent.create(OTAEvent.VERIFICATION_FAILED, id, e.reason, clock()))
    } catch (e: IOException) {
      val reason = if (OTAExtractor.isNoSpace(e)) OTADownloadException.NO_SPACE else OTADownloadException.NETWORK
      events.add(OTAEvent.create(OTAEvent.DOWNLOAD_FAILED, id, reason, clock()))
    } finally {
      archive.delete()
      extracted.deleteRecursively()
    }
  }

  fun flushEvents() {
    val installationId = store.load()?.installationId ?: return
    while (true) {
      val batch = events.peek(OTAEventQueue.MAX_EVENTS)
      if (batch.isEmpty()) return
      if (!api.postEvents(installationId, batch)) return
      events.remove(batch.map { it.eventId }.toSet())
    }
  }

  companion object {
    const val SDK_VERSION = "0.1.0"
    const val CHECK_INTERVAL_MS = 30 * 60 * 1000L
    private const val SPACE_FACTOR = 3

    fun embeddedHermesVersion(context: Context): () -> Int? {
      val cached by lazy {
        try {
          context.assets.open("index.android.bundle").use { HermesHeader.bytecodeVersion(it) }
        } catch (e: IOException) {
          null
        }
      }
      return { cached }
    }
  }
}
