package com.notti.ota

import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File

@RunWith(RobolectricTestRunner::class)
class OTAStateTest {
  @get:Rule val tmp = TemporaryFolder()

  private val appId = "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
  private val releaseA = "7d4f8a2e-1b3c-4e5f-9a6b-0c1d2e3f4a5b"
  private val releaseB = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"

  private fun metaData(vararg except: String, overrides: Map<String, Any> = emptyMap()): Bundle {
    val values = mapOf<String, Any>(
      OTAConfig.KEY_APP_ID to appId,
      OTAConfig.KEY_BASE_URL to "https://push.example.com/",
      OTAConfig.KEY_CLIENT_KEY to "ck_test",
      OTAConfig.KEY_CHANNEL to "production",
      OTAConfig.KEY_RUNTIME_VERSION to "1.4.0",
      OTAConfig.KEY_PUBLIC_KEYS to "${Fixtures.keyId}:${Fixtures.publicKeyBase64}"
    ) + overrides
    return Bundle().apply {
      values.filterKeys { it !in except }.forEach { (k, v) ->
        when (v) {
          is String -> putString(k, v)
          is Int -> putInt(k, v)
          is Float -> putFloat(k, v)
        }
      }
    }
  }

  @Test
  fun configReadsEveryKey() {
    val config = OTAConfig.fromMetaData(metaData())!!
    assertEquals(appId, config.appId)
    assertEquals("https://push.example.com", config.baseUrl)
    assertEquals("production", config.channel)
    assertEquals("1.4.0", config.runtimeVersion)
    assertTrue(config.publicKeys[Fixtures.keyId]!!.contentEquals(Fixtures.publicKeySec1))
  }

  @Test
  fun configIsOffWithoutAnyKey() {
    assertNull(OTAConfig.fromMetaData(null))
    assertNull(OTAConfig.fromMetaData(Bundle()))
  }

  @Test
  fun configIsOffWhenAnyKeyIsMissing() {
    for (key in listOf(OTAConfig.KEY_APP_ID, OTAConfig.KEY_BASE_URL, OTAConfig.KEY_CLIENT_KEY, OTAConfig.KEY_CHANNEL, OTAConfig.KEY_RUNTIME_VERSION, OTAConfig.KEY_PUBLIC_KEYS)) {
      assertNull("missing $key", OTAConfig.fromMetaData(metaData(key)))
    }
  }

  @Test
  fun configIsOffWhenAValueIsInvalid() {
    val invalid = mapOf<String, Any>(
      OTAConfig.KEY_APP_ID to "not-a-uuid",
      OTAConfig.KEY_BASE_URL to "push.example.com",
      OTAConfig.KEY_CHANNEL to "Production",
      OTAConfig.KEY_RUNTIME_VERSION to "x".repeat(65),
      OTAConfig.KEY_PUBLIC_KEYS to "0000000000000000:${Fixtures.publicKeyBase64}"
    )
    for ((key, value) in invalid) {
      assertNull("$key=$value", OTAConfig.fromMetaData(metaData(overrides = mapOf(key to value))))
    }
    val sixKeys = List(6) { "${Fixtures.keyId}:${Fixtures.publicKeyBase64}" }.joinToString(",")
    assertNull(OTAConfig.fromMetaData(metaData(overrides = mapOf(OTAConfig.KEY_PUBLIC_KEYS to sixKeys))))
  }

  @Test
  fun configRejectsAFloatRuntimeVersionButAcceptsAnInteger() {
    assertNull(OTAConfig.fromMetaData(metaData(overrides = mapOf(OTAConfig.KEY_RUNTIME_VERSION to 1.10f))))
    assertEquals("7", OTAConfig.fromMetaData(metaData(overrides = mapOf(OTAConfig.KEY_RUNTIME_VERSION to 7)))!!.runtimeVersion)
  }

  @Test
  fun configIsReadFromTheManifestMetaData() {
    val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    val info = ApplicationInfo().apply { packageName = context.packageName; metaData = metaData() }
    shadowOf(context.packageManager).installPackage(PackageInfo().apply { packageName = context.packageName; applicationInfo = info })
    assertNotNull(OTAConfig.read(context))
  }

  @Test
  fun stateRoundTrips() {
    val store = OTAStateStore(tmp.newFolder("ota"))
    val state = OTAState.fresh().copy(
      binaryIdentity = "1|1.0|10",
      stable = ReleasePointer(releaseA, "index.android.bundle"),
      pending = ReleasePointer(releaseB, "index.android.bundle", mandatory = true),
      attempt = LaunchAttempt(releaseB, 1234),
      failedCount = 1,
      interruptedCount = 2,
      lastFailureReason = "watchdog",
      blocklist = listOf(releaseA),
      revertToEmbedded = true,
      lastCheckAt = 99,
      reported = setOf("integration_missing")
    )
    store.save(state)
    assertEquals(state, OTAStateStore(store.root).load())
  }

  @Test
  fun aCorruptFileGivesAFreshStateAndWipesReleases() {
    val store = OTAStateStore(tmp.newFolder("ota"))
    File(store.releaseDir(releaseA), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    store.stateFile.writeText("{not json")

    val state = store.open("1|1.0|10")

    assertNull(state.stable)
    assertEquals("1|1.0|10", state.binaryIdentity)
    assertFalse(store.releasesDir.exists())
    assertEquals(state, store.load())
  }

  @Test
  fun aStateWithAnUnsafeBundlePathIsCorrupt() {
    val store = OTAStateStore(tmp.newFolder("ota"))
    store.save(OTAState.fresh().copy(binaryIdentity = "id", stable = ReleasePointer(releaseA, "index.android.bundle")))
    store.stateFile.writeText(store.stateFile.readText().replace("index.android.bundle", "../../evil"))
    assertNull(store.load())
  }

  @Test
  fun aCrashBetweenWriteAndRenameKeepsThePreviousState() {
    val store = OTAStateStore(tmp.newFolder("ota"))
    val before = store.open("1|1.0|10").copy(stable = ReleasePointer(releaseA, "index.android.bundle"))
    store.save(before)
    File(store.root, "state.json.tmp").writeText(before.copy(stable = null, failedCount = 9).toJson().toString())

    assertEquals(before, OTAStateStore(store.root).open("1|1.0|10"))
  }

  @Test
  fun aNewBinaryIdentityWipesReleasesAndKeepsTheInstallationId() {
    val store = OTAStateStore(tmp.newFolder("ota"))
    val first = store.open("1|1.0|10")
    store.save(first.copy(stable = ReleasePointer(releaseA, "index.android.bundle"), reported = setOf("bundle_overridden")))
    File(store.releaseDir(releaseA), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    File(store.tmpDir, "partial").apply { parentFile!!.mkdirs(); writeText("x") }

    val after = store.open("2|1.1|20")

    assertEquals(first.installationId, after.installationId)
    assertNull(after.stable)
    assertTrue(after.reported.isEmpty())
    assertFalse(store.releasesDir.exists())
    assertFalse(store.tmpDir.exists())
  }

  @Test
  fun theSameBinaryIdentityKeepsTheState() {
    val store = OTAStateStore(tmp.newFolder("ota"))
    val state = store.open("1|1.0|10").copy(stable = ReleasePointer(releaseA, "index.android.bundle"))
    store.save(state)
    assertEquals(state, store.open("1|1.0|10"))
  }

  @Test
  fun theBlocklistKeepsTheNewestTwenty() {
    var state = OTAState.fresh()
    val ids = List(25) { java.util.UUID.randomUUID().toString() }
    ids.forEach { state = state.blocking(it) }
    assertEquals(ids.takeLast(20), state.blocklist)
  }

  @Test
  fun binaryIdentityChangesWithTheInstall() {
    val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    val pm = shadowOf(context.packageManager)
    fun install(lastUpdateTime: Long) = pm.installPackage(
      PackageInfo().apply {
        packageName = context.packageName
        versionName = "1.4.0"
        @Suppress("DEPRECATION")
        versionCode = 42
        longVersionCode = 42
        this.lastUpdateTime = lastUpdateTime
        applicationInfo = ApplicationInfo().apply { packageName = context.packageName }
      }
    )
    install(1000)
    val first = BinaryIdentity.of(context)
    assertEquals("42|1.4.0|1000", first)
    install(2000)
    assertNotEquals(first, BinaryIdentity.of(context))
  }

  @Test
  fun theIdentityDigestHidesTheInstallTime() {
    val digest = BinaryIdentity.digest("42|1.4.0|1000")
    assertEquals(32, digest.length)
    assertFalse(digest.contains("1000"))
  }
}
