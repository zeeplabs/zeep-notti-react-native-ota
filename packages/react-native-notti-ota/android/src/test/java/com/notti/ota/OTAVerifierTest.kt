package com.notti.ota

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.ByteArrayInputStream
import java.io.File
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

@RunWith(RobolectricTestRunner::class)
class OTAVerifierTest {
  @get:Rule val tmp = TemporaryFolder()

  private val manifestBytes = Fixtures.bytes("manifest.json")
  private val signature = Fixtures.bytes("manifest.sig")
  private val keys = mapOf(Fixtures.keyId to Fixtures.publicKeySec1)
  private val manifest = OTAManifest.parse(manifestBytes)

  private val config = OTAConfig(
    appId = manifest.appId,
    baseUrl = "https://push.example.com",
    clientKey = "ck",
    channel = "production",
    runtimeVersion = "1.4.0",
    publicKeys = keys
  )

  private fun expectReason(reason: String, block: () -> Unit) {
    try {
      block()
      fail("expected verification_failed/$reason")
    } catch (e: OTAVerificationException) {
      assertEquals(e.message, reason, e.reason)
    }
  }

  private fun archive(name: String): File = Fixtures.copyTo("archives/$name", tmp.newFolder())

  private fun otherP256Key(): ByteArray {
    val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    val point = (pair.public as ECPublicKey).w
    fun fixed(n: java.math.BigInteger) = n.toByteArray().takeLast(32).toByteArray().let { ByteArray(32 - it.size) + it }
    return byteArrayOf(0x04) + fixed(point.affineX) + fixed(point.affineY)
  }

  @Test
  fun theFixtureKeyIdMatchesTheCli() {
    assertEquals(Fixtures.keyId, OTAKeys.keyId(Fixtures.publicKeySec1))
  }

  @Test
  fun aValidReleaseVerifiesAndExtracts() {
    OTAVerifier.verifySignature(manifestBytes, signature, Fixtures.keyId, keys)
    OTAVerifier.checkCompatible(manifest, config, embeddedHermesVersion = 96)
    val dest = File(tmp.root, "tmp/${manifest.releaseId}")

    OTAVerifier.verifyAndExtract(archive("valid.tar.gz"), manifest, dest)

    for (file in manifest.files) {
      val extracted = File(dest, file.path)
      assertEquals(file.size, extracted.length())
      assertEquals(file.sha256, OTAVerifier.sha256(extracted))
    }
  }

  @Test
  fun aChangedManifestByteFailsTheSignature() {
    val tampered = manifestBytes.copyOf().also { it[it.size / 2] = (it[it.size / 2].toInt() xor 1).toByte() }
    expectReason(OTAVerificationException.SIGNATURE) { OTAVerifier.verifySignature(tampered, signature, Fixtures.keyId, keys) }
  }

  @Test
  fun aDifferentKeyFailsTheSignature() {
    expectReason(OTAVerificationException.SIGNATURE) {
      OTAVerifier.verifySignature(manifestBytes, signature, Fixtures.keyId, mapOf(Fixtures.keyId to otherP256Key()))
    }
  }

  @Test
  fun anUnknownKeyIdIsRejected() {
    expectReason(OTAVerificationException.UNKNOWN_KEY) { OTAVerifier.verifySignature(manifestBytes, signature, "0123456789abcdef", keys) }
  }

  @Test
  fun aTamperedArchiveFailsTheArchiveHash() {
    expectReason(OTAVerificationException.HASH) { OTAVerifier.checkArchive(archive("tampered.tar.gz"), manifest) }
  }

  @Test
  fun aTamperedFileFailsItsHashEvenWhenTheArchiveHashIsSkipped() {
    expectReason(OTAVerificationException.HASH) { OTAExtractor.extract(archive("tampered.tar.gz"), tmp.newFolder("out"), manifest) }
  }

  @Test
  fun pathTraversalIsRejected() {
    expectReason(OTAVerificationException.INVALID_PATH) { OTAExtractor.extract(archive("path-traversal.tar.gz"), tmp.newFolder("out"), manifest) }
    assertFalse(File(tmp.root, "escape.js").exists())
  }

  @Test
  fun anAbsolutePathIsRejected() {
    expectReason(OTAVerificationException.INVALID_PATH) { OTAExtractor.extract(archive("absolute-path.tar.gz"), tmp.newFolder("out"), manifest) }
  }

  @Test
  fun aSymlinkEntryIsRejected() {
    expectReason(OTAVerificationException.INVALID_ARCHIVE) { OTAExtractor.extract(archive("symlink.tar.gz"), tmp.newFolder("out"), manifest) }
  }

  @Test
  fun anUnlistedFileIsRejected() {
    expectReason(OTAVerificationException.INVALID_ARCHIVE) { OTAExtractor.extract(archive("unlisted-file.tar.gz"), tmp.newFolder("out"), manifest) }
  }

  @Test
  fun aListedFileMissingFromTheArchiveIsRejected() {
    val withExtra = OTAManifest(
      manifest.raw, manifest.releaseId, manifest.appId, manifest.platform, manifest.channels, manifest.runtimeVersion,
      manifest.hermesBytecodeVersion, manifest.bundle, manifest.archiveSha256, manifest.archiveSize,
      manifest.files + ManifestFile("assets/missing.png", "0".repeat(64), 10)
    )
    expectReason(OTAVerificationException.HASH) { OTAExtractor.extract(archive("valid.tar.gz"), tmp.newFolder("out"), withExtra) }
  }

  @Test
  fun everyFailureLeavesNothingBehind() {
    val store = OTAStateStore(tmp.newFolder("ota"))
    for (name in listOf("tampered.tar.gz", "path-traversal.tar.gz", "absolute-path.tar.gz", "symlink.tar.gz", "unlisted-file.tar.gz")) {
      val dest = File(store.tmpDir, manifest.releaseId)
      val source = archive(name)
      try {
        OTAVerifier.verifyAndExtract(source, manifest, dest)
        fail("$name was accepted")
      } catch (e: OTAVerificationException) {
        assertFalse("$name left ${dest.path}", dest.exists())
      }
      assertFalse(store.releasesDir.exists())
    }
    assertFalse(File(tmp.root, "escape.js").exists())
  }

  @Test
  fun aReleaseForAnotherRuntimeOrHermesVersionIsIncompatible() {
    expectReason(OTAVerificationException.INCOMPATIBLE) { OTAVerifier.checkCompatible(manifest, config.copy(runtimeVersion = "1.5.0"), 96) }
    expectReason(OTAVerificationException.INCOMPATIBLE) { OTAVerifier.checkCompatible(manifest, config, 98) }
    expectReason(OTAVerificationException.INCOMPATIBLE) { OTAVerifier.checkCompatible(manifest, config, null) }
    expectReason(OTAVerificationException.INCOMPATIBLE) { OTAVerifier.checkCompatible(manifest, config.copy(channel = "beta"), 96) }
    expectReason(OTAVerificationException.INCOMPATIBLE) {
      OTAVerifier.checkCompatible(manifest, config.copy(appId = "00000000-0000-4000-8000-000000000000"), 96)
    }
    OTAVerifier.checkCompatible(manifest, config.copy(channel = "staging"), 96)
  }

  @Test
  fun aReleaseForAnotherPlatformIsIncompatible() {
    for (platform in listOf("ios", "web", "")) {
      val other = OTAManifest(
        manifest.raw, manifest.releaseId, manifest.appId, platform, manifest.channels, manifest.runtimeVersion,
        manifest.hermesBytecodeVersion, manifest.bundle, manifest.archiveSha256, manifest.archiveSize, manifest.files
      )
      expectReason(OTAVerificationException.INCOMPATIBLE) { OTAVerifier.checkCompatible(other, config, 96) }
    }
  }

  @Test
  fun aMalformedManifestIsAnInvalidArchive() {
    expectReason(OTAVerificationException.INVALID_ARCHIVE) { OTAManifest.parse("{}".toByteArray()) }
    val unsafe = String(manifestBytes).replace("\"path\":\"assets/fonts/inter.ttf\"", "\"path\":\"../inter.ttf\"")
    expectReason(OTAVerificationException.INVALID_ARCHIVE) { OTAManifest.parse(unsafe.toByteArray()) }
  }

  @Test
  fun theHermesHeaderIsReadForVersions96To99() {
    for (version in listOf(96, 98, 99)) {
      val header = byteArrayOf(0xC6.toByte(), 0x1F, 0xBC.toByte(), 0x03, 0xC1.toByte(), 0x03, 0x19, 0x1F, version.toByte(), 0, 0, 0)
      assertEquals(version, HermesHeader.bytecodeVersion(ByteArrayInputStream(header + ByteArray(20))))
    }
    assertEquals(null, HermesHeader.bytecodeVersion(ByteArrayInputStream("var a = 1;".toByteArray())))
    assertEquals(null, HermesHeader.bytecodeVersion(ByteArrayInputStream(ByteArray(4))))
  }

  @Test
  fun theFixtureBundleIsHermes96() {
    val dest = tmp.newFolder("out")
    OTAExtractor.extract(archive("valid.tar.gz"), dest, manifest)
    assertTrue(File(dest, manifest.bundle).inputStream().use { HermesHeader.bytecodeVersion(it) } == 96)
  }
}
