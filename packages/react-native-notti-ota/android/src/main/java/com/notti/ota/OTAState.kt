package com.notti.ota

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

internal const val TAG = "NottiOta"

/**
 * The `NottiOTA*` meta-data of the host app. [read] returns null when Live updates are off:
 * any key missing or invalid (spec OTA-33).
 */
internal data class OTAConfig(
  val appId: String,
  val baseUrl: String,
  val clientKey: String,
  val channel: String,
  val runtimeVersion: String,
  /** key_id to the 65-byte uncompressed SEC1 public key. */
  val publicKeys: Map<String, ByteArray>
) {
  companion object {
    const val KEY_APP_ID = "NottiOTAAppId"
    const val KEY_BASE_URL = "NottiOTABaseUrl"
    const val KEY_CLIENT_KEY = "NottiOTAClientKey"
    const val KEY_CHANNEL = "NottiOTAChannel"
    const val KEY_RUNTIME_VERSION = "NottiOTARuntimeVersion"
    const val KEY_PUBLIC_KEYS = "NottiOTAPublicKeys"

    private val ALL_KEYS = listOf(KEY_APP_ID, KEY_BASE_URL, KEY_CLIENT_KEY, KEY_CHANNEL, KEY_RUNTIME_VERSION, KEY_PUBLIC_KEYS)
    private val CHANNEL = Regex("^[a-z0-9-]{1,32}$")
    private val KEY_ID = Regex("^[0-9a-f]{16}$")
    private const val MAX_PUBLIC_KEYS = 5

    fun read(context: Context): OTAConfig? {
      val metaData = try {
        context.packageManager
          .getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
          .metaData
      } catch (e: Exception) {
        null
      }
      return fromMetaData(metaData)
    }

    fun fromMetaData(metaData: Bundle?): OTAConfig? {
      if (metaData == null || ALL_KEYS.none { metaData.containsKey(it) }) return null
      return parse { key -> stringValue(metaData, key) }
    }

    // Android parses a numeric-looking meta-data value as a number, and a float loses digits
    // ("1.10" becomes 1.1), so only strings and integers are accepted.
    private fun stringValue(metaData: Bundle, key: String): String? =
      when (@Suppress("DEPRECATION") val value = metaData.get(key)) {
        is String -> value
        is Int, is Long -> value.toString()
        else -> null
      }

    fun parse(value: (String) -> String?): OTAConfig? {
      val missing = ALL_KEYS.filter { value(it).isNullOrBlank() }
      if (missing.isNotEmpty()) {
        return off("missing or not a string: ${missing.joinToString()}")
      }
      val appId = value(KEY_APP_ID)!!.trim()
      if (!isUuid(appId)) return off("$KEY_APP_ID is not a UUID")
      val baseUrl = normalizeBaseUrl(value(KEY_BASE_URL)!!) ?: return off("$KEY_BASE_URL is not an http(s) URL")
      val channel = value(KEY_CHANNEL)!!.trim()
      if (!CHANNEL.matches(channel)) return off("$KEY_CHANNEL must match ${CHANNEL.pattern}")
      val runtimeVersion = value(KEY_RUNTIME_VERSION)!!.trim()
      if (runtimeVersion.length > 64) return off("$KEY_RUNTIME_VERSION is longer than 64 characters")
      val publicKeys = parsePublicKeys(value(KEY_PUBLIC_KEYS)!!) ?: return null
      return OTAConfig(appId, baseUrl, value(KEY_CLIENT_KEY)!!.trim(), channel, runtimeVersion, publicKeys)
    }

    private fun parsePublicKeys(raw: String): Map<String, ByteArray>? {
      val entries = raw.split(',').map { it.trim() }.filter { it.isNotEmpty() }
      if (entries.isEmpty() || entries.size > MAX_PUBLIC_KEYS) {
        return off("$KEY_PUBLIC_KEYS must list 1 to $MAX_PUBLIC_KEYS keys")
      }
      val keys = LinkedHashMap<String, ByteArray>()
      for (entry in entries) {
        val keyId = entry.substringBefore(':', "")
        if (!KEY_ID.matches(keyId)) return off("$KEY_PUBLIC_KEYS entries must be key_id:base64")
        val key = try {
          Base64.decode(entry.substringAfter(':'), Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
          return off("$KEY_PUBLIC_KEYS key $keyId is not base64")
        }
        if (key.size != 65 || key[0] != 0x04.toByte()) {
          return off("$KEY_PUBLIC_KEYS key $keyId is not an uncompressed P-256 point")
        }
        if (OTAKeys.keyId(key) != keyId) return off("$KEY_PUBLIC_KEYS key_id $keyId does not match its key")
        keys[keyId] = key
      }
      return keys
    }

    internal fun normalizeBaseUrl(raw: String): String? {
      val trimmed = raw.trim().trimEnd('/')
      val uri = try {
        java.net.URI(trimmed)
      } catch (e: Exception) {
        return null
      }
      if (uri.scheme != "https" && uri.scheme != "http") return null
      if (uri.host.isNullOrEmpty() || uri.rawQuery != null || uri.rawFragment != null) return null
      return trimmed
    }

    private fun isUuid(s: String): Boolean =
      try {
        UUID.fromString(s).toString() == s.lowercase()
      } catch (e: IllegalArgumentException) {
        false
      }

    private fun <T> off(reason: String): T? {
      Log.e(TAG, "Live updates are off: invalid configuration ($reason)")
      return null
    }
  }
}

internal object OTAKeys {
  fun keyId(sec1PublicKey: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(sec1PublicKey).copyOf(8).toHex()
}

internal fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

/** Release on disk: `releases/<releaseId>/<bundle>`. */
internal data class ReleasePointer(val releaseId: String, val bundle: String, val mandatory: Boolean = false)

internal data class LaunchAttempt(val releaseId: String, val startedAt: Long)

internal data class OTAState(
  val installationId: String,
  val binaryIdentity: String? = null,
  val stable: ReleasePointer? = null,
  val pending: ReleasePointer? = null,
  val attempt: LaunchAttempt? = null,
  val failedCount: Int = 0,
  val interruptedCount: Int = 0,
  val lastFailureReason: String? = null,
  val blocklist: List<String> = emptyList(),
  val revertToEmbedded: Boolean = false,
  val lastCheckAt: Long = 0,
  /** Event types already reported for this binary identity. */
  val reported: Set<String> = emptySet()
) {
  fun blocking(releaseId: String): OTAState =
    copy(blocklist = (blocklist.filter { it != releaseId } + releaseId).takeLast(MAX_BLOCKLIST))

  fun toJson(): JSONObject = JSONObject()
    .put("version", FORMAT)
    .put("installation_id", installationId)
    .put("binary_identity", binaryIdentity ?: JSONObject.NULL)
    .put("stable", stable?.toJson() ?: JSONObject.NULL)
    .put("pending", pending?.toJson() ?: JSONObject.NULL)
    .put("attempt", attempt?.let { JSONObject().put("release_id", it.releaseId).put("started_at", it.startedAt) } ?: JSONObject.NULL)
    .put("failed_count", failedCount)
    .put("interrupted_count", interruptedCount)
    .put("last_failure_reason", lastFailureReason ?: JSONObject.NULL)
    .put("blocklist", JSONArray(blocklist))
    .put("revert_to_embedded", revertToEmbedded)
    .put("last_check_at", lastCheckAt)
    .put("reported", JSONArray(reported.sorted()))

  companion object {
    const val FORMAT = 1
    const val MAX_BLOCKLIST = 20

    fun fresh(installationId: String = UUID.randomUUID().toString()) = OTAState(installationId = installationId)

    fun fromJson(json: JSONObject): OTAState {
      require(json.getInt("version") == FORMAT) { "unknown state version" }
      val installationId = json.getString("installation_id")
      UUID.fromString(installationId)
      return OTAState(
        installationId = installationId,
        binaryIdentity = json.optStringOrNull("binary_identity"),
        stable = json.optJSONObject("stable")?.let(::pointer),
        pending = json.optJSONObject("pending")?.let(::pointer),
        attempt = json.optJSONObject("attempt")?.let { LaunchAttempt(releaseId(it.getString("release_id")), it.getLong("started_at")) },
        failedCount = json.getInt("failed_count"),
        interruptedCount = json.getInt("interrupted_count"),
        lastFailureReason = json.optStringOrNull("last_failure_reason"),
        blocklist = json.getJSONArray("blocklist").strings().map(::releaseId).takeLast(MAX_BLOCKLIST),
        revertToEmbedded = json.getBoolean("revert_to_embedded"),
        lastCheckAt = json.getLong("last_check_at"),
        reported = json.getJSONArray("reported").strings().toSet()
      )
    }

    private fun ReleasePointer.toJson() = JSONObject().put("release_id", releaseId).put("bundle", bundle).put("mandatory", mandatory)

    private fun pointer(json: JSONObject): ReleasePointer {
      val bundle = json.getString("bundle")
      require(OTAPaths.isSafeRelativePath(bundle)) { "unsafe bundle path" }
      return ReleasePointer(releaseId(json.getString("release_id")), bundle, json.optBoolean("mandatory", false))
    }

    // Release IDs become directory names, so anything but a canonical UUID is corruption.
    private fun releaseId(s: String): String {
      require(UUID.fromString(s).toString() == s) { "release id is not a canonical UUID" }
      return s
    }

    private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key)) null else getString(key)

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
  }
}

internal object OTAPaths {
  fun isSafeRelativePath(path: String): Boolean {
    if (path.isEmpty() || path.startsWith("/") || path.contains('\\') || path.contains('\u0000')) return false
    return path.split('/').none { it.isEmpty() || it == "." || it == ".." }
  }
}

/**
 * Owns `filesDir/notti-ota`: `state.json`, `releases/` and `tmp/`. The state file is replaced
 * atomically (tmp file, fsync, rename), so a crash mid-write keeps the previous state.
 */
internal class OTAStateStore(val root: File) {
  val stateFile = File(root, "state.json")
  val releasesDir = File(root, "releases")
  val tmpDir = File(root, "tmp")
  private val stateTmp = File(root, "state.json.tmp")

  /**
   * Loads the state for [binaryIdentity]. A missing or corrupt file, or a different binary
   * identity, gives a fresh state and wipes every downloaded release (spec OTA-30, OTA-31).
   */
  @Synchronized
  fun open(binaryIdentity: String): OTAState {
    val loaded = load()
    if (loaded != null && loaded.binaryIdentity == binaryIdentity) return loaded

    if (loaded == null && stateFile.exists()) {
      Log.w(TAG, "Live updates: state file unreadable, starting from the embedded bundle")
    }
    wipeReleases()
    val fresh = OTAState.fresh(loaded?.installationId ?: UUID.randomUUID().toString())
      .copy(binaryIdentity = binaryIdentity)
    save(fresh)
    return fresh
  }

  @Synchronized
  fun load(): OTAState? {
    if (!stateFile.exists()) return null
    return try {
      OTAState.fromJson(JSONObject(stateFile.readText()))
    } catch (e: Exception) {
      null
    }
  }

  @Synchronized
  fun save(state: OTAState) {
    root.mkdirs()
    FileOutputStream(stateTmp).use { out ->
      out.write(state.toJson().toString().toByteArray(Charsets.UTF_8))
      out.fd.sync()
    }
    if (!stateTmp.renameTo(stateFile)) {
      stateTmp.delete()
      throw java.io.IOException("could not replace ${stateFile.name}")
    }
  }

  /** Applies [change] to the stored state and saves it, under the store lock. */
  @Synchronized
  fun update(change: (OTAState) -> OTAState): OTAState {
    val current = load() ?: throw IllegalStateException("state not opened")
    val next = change(current)
    if (next != current) save(next)
    return next
  }

  fun releaseDir(releaseId: String) = File(releasesDir, releaseId)

  fun bundleFile(pointer: ReleasePointer) = File(releaseDir(pointer.releaseId), pointer.bundle)

  /** Deletes release directories other than [keep] (stable and pending). */
  fun pruneReleases(keep: Set<String>) {
    releasesDir.listFiles()?.filter { it.name !in keep }?.forEach { it.deleteRecursively() }
  }

  fun wipeReleases() {
    releasesDir.deleteRecursively()
    tmpDir.deleteRecursively()
  }
}

/**
 * Identity of the installed binary: `versionCode`, `versionName` and `lastUpdateTime`, which
 * changes on every store update or reinstall (spec OTA-30).
 */
internal object BinaryIdentity {
  fun of(context: Context): String {
    val info = context.packageManager.getPackageInfo(context.packageName, 0)
    val versionCode = if (Build.VERSION.SDK_INT >= 28) {
      info.longVersionCode
    } else {
      @Suppress("DEPRECATION") info.versionCode.toLong()
    }
    return "$versionCode|${info.versionName}|${info.lastUpdateTime}"
  }

  /**
   * What the check request sends: a digest, so the install time never leaves the device. The
   * server only validates the field (OTA-14 AC6).
   */
  fun digest(identity: String): String =
    MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8)).copyOf(16).toHex()
}
