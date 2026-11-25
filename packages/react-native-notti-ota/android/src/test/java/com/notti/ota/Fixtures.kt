package com.notti.ota

import java.io.File
import java.util.Base64

internal object Fixtures {
  fun bytes(name: String): ByteArray =
    requireNotNull(Fixtures::class.java.classLoader?.getResourceAsStream("ota/$name")) { "fixture ota/$name not found" }
      .use { it.readBytes() }

  fun text(name: String): String = String(bytes(name), Charsets.UTF_8)

  fun copyTo(name: String, dir: File): File = File(dir, name.substringAfterLast('/')).also { it.writeBytes(bytes(name)) }

  val keyId: String get() = text("key_id.txt").trim()

  /** The 65-byte SEC1 point: the tail of the P-256 SPKI in public_key.pem. */
  val publicKeySec1: ByteArray
    get() {
      val der = Base64.getMimeDecoder().decode(
        text("public_key.pem").lines().filter { !it.startsWith("-----") }.joinToString("")
      )
      return der.copyOfRange(der.size - 65, der.size)
    }

  val publicKeyBase64: String get() = Base64.getEncoder().encodeToString(publicKeySec1)
}
