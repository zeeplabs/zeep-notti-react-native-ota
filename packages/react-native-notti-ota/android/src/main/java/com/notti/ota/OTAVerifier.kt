package com.notti.ota

import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import java.util.zip.GZIPInputStream

/** A failed check, with the `verification_failed` reason code the server accepts. */
internal class OTAVerificationException(val reason: String, message: String) : Exception(message) {
  companion object {
    const val SIGNATURE = "signature"
    const val UNKNOWN_KEY = "unknown_key"
    const val HASH = "hash"
    const val INCOMPATIBLE = "incompatible"
    const val INVALID_PATH = "invalid_path"
    const val INVALID_ARCHIVE = "invalid_archive"
  }
}

internal data class ManifestFile(val path: String, val sha256: String, val size: Long)

/** Format v1 release manifest. [raw] is what the signature covers; it is never re-serialized. */
internal class OTAManifest(
  val raw: ByteArray,
  val releaseId: String,
  val appId: String,
  val platform: String,
  val channels: List<String>,
  val runtimeVersion: String,
  val hermesBytecodeVersion: Int,
  val bundle: String,
  val archiveSha256: String,
  val archiveSize: Long,
  val files: List<ManifestFile>
) {
  companion object {
    const val MAX_ARCHIVE_BYTES = 50L * 1024 * 1024
    private val SHA256 = Regex("^[0-9a-f]{64}$")

    fun parse(raw: ByteArray): OTAManifest {
      try {
        val json = JSONObject(String(raw, Charsets.UTF_8))
        require(json.getInt("format") == 1) { "unsupported format" }
        val releaseId = json.getString("release_id")
        require(UUID.fromString(releaseId).toString() == releaseId) { "release_id" }
        val channels = json.getJSONArray("channels").let { a -> (0 until a.length()).map { a.getString(it) } }
        val archive = json.getJSONObject("archive")
        val filesJson = json.getJSONArray("files")
        val files = (0 until filesJson.length()).map {
          val f = filesJson.getJSONObject(it)
          ManifestFile(f.getString("path"), f.getString("sha256"), f.getLong("size"))
        }
        val bundle = json.getString("bundle")
        require(files.all { OTAPaths.isSafeRelativePath(it.path) && SHA256.matches(it.sha256) && it.size > 0 }) { "files" }
        require(files.map { it.path }.toSet().size == files.size) { "duplicate file" }
        require(files.any { it.path == bundle }) { "bundle not listed" }
        val archiveSize = archive.getLong("size")
        require(archiveSize in 1..MAX_ARCHIVE_BYTES && SHA256.matches(archive.getString("sha256"))) { "archive" }
        return OTAManifest(
          raw, releaseId, json.getString("app_id"), json.getString("platform"), channels,
          json.getString("runtime_version"), json.getInt("hermes_bytecode_version"), bundle,
          archive.getString("sha256"), archiveSize, files
        )
      } catch (e: Exception) {
        throw OTAVerificationException(OTAVerificationException.INVALID_ARCHIVE, "manifest is not a valid format v1 manifest (${e.message})")
      }
    }
  }
}

internal object OTAVerifier {
  // DER prefix of an X.509 SubjectPublicKeyInfo for an uncompressed P-256 point.
  private val P256_SPKI_PREFIX = hexBytes("3059301306072a8648ce3d020106082a8648ce3d030107034200")

  /** Verifies the ECDSA P-256 / SHA-256 DER [signature] over the manifest bytes as received. */
  fun verifySignature(manifest: ByteArray, signature: ByteArray, keyId: String, keys: Map<String, ByteArray>) {
    val sec1 = keys[keyId]
      ?: throw OTAVerificationException(OTAVerificationException.UNKNOWN_KEY, "key_id $keyId is not embedded in this binary")
    val valid = try {
      val publicKey = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(P256_SPKI_PREFIX + sec1))
      Signature.getInstance("SHA256withECDSA").run {
        initVerify(publicKey)
        update(manifest)
        verify(signature)
      }
    } catch (e: Exception) {
      false
    }
    if (!valid) throw OTAVerificationException(OTAVerificationException.SIGNATURE, "manifest signature does not verify with key $keyId")
  }

  /**
   * The release must target this binary: app, platform, channel, runtime version and the Hermes
   * bytecode version of the embedded bundle ([embeddedHermesVersion], null when unreadable).
   */
  fun checkCompatible(manifest: OTAManifest, config: OTAConfig, embeddedHermesVersion: Int?) {
    val mismatch = when {
      manifest.appId != config.appId -> "app_id"
      manifest.platform != "android" -> "platform"
      config.channel !in manifest.channels -> "channel"
      manifest.runtimeVersion != config.runtimeVersion -> "runtime_version"
      embeddedHermesVersion == null -> "embedded bundle is not Hermes bytecode"
      manifest.hermesBytecodeVersion != embeddedHermesVersion -> "hermes_bytecode_version"
      else -> null
    }
    if (mismatch != null) throw OTAVerificationException(OTAVerificationException.INCOMPATIBLE, "release does not match this binary ($mismatch)")
  }

  fun checkArchive(archive: File, manifest: OTAManifest) {
    if (archive.length() != manifest.archiveSize || sha256(archive) != manifest.archiveSha256) {
      throw OTAVerificationException(OTAVerificationException.HASH, "archive does not match the manifest")
    }
  }

  /**
   * Checks the downloaded [archive] against [manifest] and extracts it into [dest]. On any failure
   * [dest] is deleted, so nothing is left behind.
   */
  fun verifyAndExtract(archive: File, manifest: OTAManifest, dest: File) {
    try {
      checkArchive(archive, manifest)
      OTAExtractor.extract(archive, dest, manifest)
      val bundleVersion = FileInputStream(File(dest, manifest.bundle)).use { HermesHeader.bytecodeVersion(it) }
      if (bundleVersion != manifest.hermesBytecodeVersion) {
        throw OTAVerificationException(OTAVerificationException.INCOMPATIBLE, "bundle is not Hermes bytecode version ${manifest.hermesBytecodeVersion}")
      }
    } catch (e: Throwable) {
      dest.deleteRecursively()
      throw e
    }
  }

  fun sha256(file: File): String = FileInputStream(file).use { sha256(it) }

  private fun sha256(input: InputStream): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(64 * 1024)
    while (true) {
      val n = input.read(buffer)
      if (n < 0) break
      digest.update(buffer, 0, n)
    }
    return digest.digest().toHex()
  }

  private fun hexBytes(hex: String) = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

/** Hermes bytecode header: 8-byte magic, then the bytecode version as a little-endian uint32. */
internal object HermesHeader {
  private val MAGIC = byteArrayOf(0xC6.toByte(), 0x1F, 0xBC.toByte(), 0x03, 0xC1.toByte(), 0x03, 0x19, 0x1F)

  fun bytecodeVersion(input: InputStream): Int? {
    val header = ByteArray(12)
    var read = 0
    while (read < header.size) {
      val n = input.read(header, read, header.size - read)
      if (n < 0) return null
      read += n
    }
    if (!header.copyOf(8).contentEquals(MAGIC)) return null
    val version = (header[8].toLong() and 0xFF) or
      ((header[9].toLong() and 0xFF) shl 8) or
      ((header[10].toLong() and 0xFF) shl 16) or
      ((header[11].toLong() and 0xFF) shl 24)
    return if (version in 1..Int.MAX_VALUE) version.toInt() else null
  }
}

/**
 * Minimal reader for the CLI's archives: gzip over POSIX ustar, regular files and directories only.
 * Every regular file must be listed in the manifest with the same size and SHA-256.
 */
internal object OTAExtractor {
  private const val BLOCK = 512
  private const val MAX_ENTRIES = 10_000

  fun extract(archive: File, dest: File, manifest: OTAManifest) {
    val listed = manifest.files.associateBy { it.path }
    val seen = HashSet<String>()
    if (!dest.mkdirs() && !dest.isDirectory) throw IOException("could not create ${dest.name}")
    val root = dest.canonicalFile

    try {
      GZIPInputStream(FileInputStream(archive), 64 * 1024).use { input ->
        val header = ByteArray(BLOCK)
        var entries = 0
        while (true) {
          if (!readFully(input, header)) throw invalidArchive("truncated archive")
          if (header.all { it == 0.toByte() }) break
          if (++entries > MAX_ENTRIES) throw invalidArchive("too many entries")
          val entry = parseHeader(header)
          when (entry.type) {
            '5' -> {
              val dir = resolve(root, entry.path.trimEnd('/'))
              if (!dir.mkdirs() && !dir.isDirectory) throw IOException("could not create a directory")
              skip(input, padded(entry.size))
            }
            '0', '\u0000' -> {
              val expected = listed[entry.path]
                ?: throw invalidArchive("entry ${entry.path} is not listed in the manifest")
              if (!seen.add(entry.path)) throw invalidArchive("entry ${entry.path} appears twice")
              if (entry.size != expected.size) throw hashMismatch(entry.path)
              val target = resolve(root, entry.path)
              target.parentFile?.mkdirs()
              val actual = copy(input, target, entry.size)
              if (actual != expected.sha256) throw hashMismatch(entry.path)
              skip(input, padded(entry.size) - entry.size)
            }
            '2' -> throw invalidArchive("entry ${entry.path} is a symbolic link")
            '1' -> throw invalidArchive("entry ${entry.path} is a hard link")
            else -> throw invalidArchive("entry ${entry.path} has unsupported type ${entry.type}")
          }
        }
      }
    } catch (e: OTAVerificationException) {
      throw e
    } catch (e: IOException) {
      if (isNoSpace(e)) throw e
      throw invalidArchive("archive is not a readable tar.gz (${e.message})")
    }

    val missing = listed.keys - seen
    if (missing.isNotEmpty()) throw OTAVerificationException(OTAVerificationException.HASH, "listed files missing from the archive: ${missing.size}")
  }

  private class Entry(val path: String, val size: Long, val type: Char)

  private fun parseHeader(h: ByteArray): Entry {
    if (!String(h, 257, 5, Charsets.US_ASCII).equals("ustar")) throw invalidArchive("not a ustar archive")
    val storedChecksum = octal(h, 148, 8)
    var sum = 0L
    for (i in h.indices) sum += if (i in 148 until 156) 32 else (h[i].toInt() and 0xFF)
    if (sum != storedChecksum) throw invalidArchive("tar header checksum mismatch")
    val name = text(h, 0, 100)
    val prefix = text(h, 345, 155)
    val path = if (prefix.isEmpty()) name else "$prefix/$name"
    val type = (h[156].toInt() and 0xFF).toChar()
    val size = octal(h, 124, 12)
    if (size < 0 || size > OTAManifest.MAX_ARCHIVE_BYTES * 4) throw invalidArchive("entry size out of range")
    checkPath(if (type == '5') path.trimEnd('/') else path)
    return Entry(path, size, type)
  }

  private fun checkPath(path: String) {
    if (path.startsWith("/")) throw invalidPath("entry $path is absolute")
    if (!OTAPaths.isSafeRelativePath(path)) throw invalidPath("entry $path leaves the extraction directory")
  }

  private fun resolve(root: File, path: String): File {
    val target = File(root, path).canonicalFile
    if (!target.path.startsWith(root.path + File.separator)) throw invalidPath("entry $path leaves the extraction directory")
    return target
  }

  private fun copy(input: InputStream, target: File, size: Long): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(64 * 1024)
    var remaining = size
    FileOutputStream(target).use { out ->
      while (remaining > 0) {
        val n = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
        if (n < 0) throw invalidArchive("truncated entry")
        digest.update(buffer, 0, n)
        out.write(buffer, 0, n)
        remaining -= n
      }
      out.fd.sync()
    }
    return digest.digest().toHex()
  }

  private fun text(h: ByteArray, offset: Int, length: Int): String {
    var end = offset
    while (end < offset + length && h[end] != 0.toByte()) end++
    return String(h, offset, end - offset, Charsets.UTF_8)
  }

  private fun octal(h: ByteArray, offset: Int, length: Int): Long {
    val s = text(h, offset, length).trim()
    if (s.isEmpty()) return 0
    return s.toLongOrNull(8) ?: throw invalidArchive("bad octal field in tar header")
  }

  private fun readFully(input: InputStream, buffer: ByteArray): Boolean {
    var read = 0
    while (read < buffer.size) {
      val n = input.read(buffer, read, buffer.size - read)
      if (n < 0) return false
      read += n
    }
    return true
  }

  private fun skip(input: InputStream, count: Long) {
    var remaining = count
    val buffer = ByteArray(BLOCK)
    while (remaining > 0) {
      val n = input.read(buffer, 0, minOf(remaining, BLOCK.toLong()).toInt())
      if (n < 0) throw invalidArchive("truncated archive")
      remaining -= n
    }
  }

  private fun padded(size: Long) = (size + BLOCK - 1) / BLOCK * BLOCK

  internal fun isNoSpace(e: IOException): Boolean = e.message?.contains("ENOSPC") == true || e.message?.contains("No space left") == true

  private fun invalidArchive(message: String) = OTAVerificationException(OTAVerificationException.INVALID_ARCHIVE, message)

  private fun invalidPath(message: String) = OTAVerificationException(OTAVerificationException.INVALID_PATH, message)

  private fun hashMismatch(path: String) = OTAVerificationException(OTAVerificationException.HASH, "$path does not match the manifest")
}
