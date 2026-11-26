package com.notti.ota

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
class OTAUpdaterTest {
  @get:Rule val tmp = TemporaryFolder()

  private val server = MockWebServer()
  private val requests = CopyOnWriteArrayList<RecordedRequest>()
  private var checkResponse: () -> MockResponse = { MockResponse().setBody("""{"update":null,"revert_to_embedded":false}""") }
  private var archiveResponse: () -> MockResponse = { MockResponse().setBody(Buffer().write(Fixtures.bytes("archives/valid.tar.gz"))) }
  private var eventsResponse: () -> MockResponse = { MockResponse().setBody("""{"accepted":1,"duplicates":0}""") }

  private val manifestBytes = Fixtures.bytes("manifest.json")
  private val manifest = OTAManifest.parse(manifestBytes)
  private val releaseId = manifest.releaseId
  private val otherRelease = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"

  private lateinit var config: OTAConfig
  private lateinit var store: OTAStateStore
  private lateinit var events: OTAEventQueue
  private var now = 10_000_000L
  private var freeSpace = Long.MAX_VALUE
  private val pendingNotices = mutableListOf<ReleasePointer>()

  @Before
  fun setUp() {
    server.dispatcher = object : Dispatcher() {
      override fun dispatch(request: RecordedRequest): MockResponse {
        requests += request
        return when {
          request.path!!.endsWith("/ota/check") -> checkResponse()
          request.path!!.endsWith("/ota/events") -> eventsResponse()
          request.path!!.startsWith("/archive") -> archiveResponse()
          else -> MockResponse().setResponseCode(404)
        }
      }
    }
    server.start()
    config = OTAConfig(
      appId = manifest.appId,
      baseUrl = server.url("/").toString().trimEnd('/'),
      clientKey = "ck_live",
      channel = "production",
      runtimeVersion = "1.4.0",
      publicKeys = mapOf(Fixtures.keyId to Fixtures.publicKeySec1)
    )
    store = OTAStateStore(tmp.newFolder("ota"))
    events = OTAEventQueue(File(store.root, "events.json"))
    store.open("42|1.4.0|1000")
  }

  @After
  fun tearDown() = server.shutdown()

  private fun updater(readTimeoutMs: Int = 15_000) = OTAUpdater(
    config, store, events, OTAApiClient(config, readTimeoutMs = readTimeoutMs), { 96 },
    executor = { it.run() }, clock = { now }, freeSpace = { freeSpace }, onPending = { pendingNotices += it }
  )

  private fun offer(
    id: String = releaseId,
    mandatory: Boolean = false,
    manifest: ByteArray = manifestBytes,
    signature: ByteArray = Fixtures.bytes("manifest.sig"),
    keyId: String = Fixtures.keyId
  ) = {
    MockResponse().setBody(
      JSONObject()
        .put(
          "update",
          JSONObject()
            .put("release_id", id)
            .put("manifest", Base64.getEncoder().encodeToString(manifest))
            .put("signature", Base64.getEncoder().encodeToString(signature))
            .put("key_id", keyId)
            .put("download_url", server.url("/archive?X-Amz-Signature=abc").toString())
            .put("expires_at", "2026-11-25T12:15:00Z")
            .put("mandatory", mandatory)
        )
        .put("revert_to_embedded", false)
        .toString()
    )
  }

  private fun eventTypes() = events.read().map { "${it.type}:${it.reason ?: ""}@${it.releaseId ?: ""}" }

  private fun tmpIsEmpty() = store.tmpDir.listFiles().isNullOrEmpty()

  @Test
  fun anOfferedReleaseIsDownloadedVerifiedAndBecomesPending() {
    checkResponse = offer(mandatory = true)

    updater().check()

    val state = store.load()!!
    assertEquals(ReleasePointer(releaseId, "index.android.bundle", mandatory = true), state.pending)
    assertTrue(store.bundleFile(state.pending!!).isFile)
    assertEquals(now, state.lastCheckAt)
    assertEquals(listOf("downloaded:@$releaseId"), eventTypes())
    assertTrue(tmpIsEmpty())
    assertEquals(listOf(state.pending), pendingNotices)

    val check = requests.first { it.path!!.endsWith("/ota/check") }
    assertEquals("/v1/apps/${manifest.appId}/ota/check", check.path)
    assertEquals("Bearer ck_live", check.getHeader("Authorization"))
    val body = JSONObject(check.body.readUtf8())
    assertEquals("android", body.getString("platform"))
    assertEquals("production", body.getString("channel"))
    assertEquals("1.4.0", body.getString("runtime_version"))
    assertEquals(state.installationId, body.getString("installation_id"))
    assertEquals(BinaryIdentity.digest("42|1.4.0|1000"), body.getString("binary_identity"))
    assertEquals(96, body.getInt("hermes_bytecode_version"))
    assertFalse(body.has("current_release_id"))

    val download = requests.first { it.path!!.startsWith("/archive") }
    assertNull("a presigned URL must not carry the client key", download.getHeader("Authorization"))
  }

  @Test
  fun theRunningReleaseIsSentAsCurrent() {
    File(store.releaseDir(otherRelease), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    store.update { it.copy(stable = ReleasePointer(otherRelease, "index.android.bundle")) }
    updater().check()
    val body = JSONObject(requests.first().body.readUtf8())
    assertEquals(otherRelease, body.getString("current_release_id"))
  }

  @Test
  fun noUpdateChangesNothing() {
    val before = store.load()!!
    updater().check()
    assertEquals(before.copy(lastCheckAt = now), store.load())
    assertTrue(events.read().isEmpty())
  }

  @Test
  fun aFailedDownloadIsNotAnnounced() {
    checkResponse = offer()
    archiveResponse = { MockResponse().setResponseCode(403) }
    updater().check()
    assertTrue(pendingNotices.isEmpty())
  }

  @Test
  fun rateLimitedIsNoUpdate() {
    checkResponse = { MockResponse().setResponseCode(429).setHeader("Retry-After", "60") }
    updater().check()
    assertNull(store.load()!!.pending)
    assertTrue(events.read().isEmpty())
    assertEquals(0, requests.count { it.path!!.startsWith("/archive") })
  }

  @Test
  fun anInterruptedDownloadRemovesThePartialFile() {
    checkResponse = offer()
    archiveResponse = {
      MockResponse().setBody(Buffer().write(Fixtures.bytes("archives/valid.tar.gz"))).setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
    }
    updater().check()
    assertNull(store.load()!!.pending)
    assertEquals(listOf("download_failed:network@$releaseId"), eventTypes())
    assertTrue(tmpIsEmpty())
    assertFalse(store.releaseDir(releaseId).exists())
  }

  @Test
  fun anHttpErrorOnTheDownloadIsReported() {
    checkResponse = offer()
    archiveResponse = { MockResponse().setResponseCode(403) }
    updater().check()
    assertEquals(listOf("download_failed:http_status@$releaseId"), eventTypes())
  }

  @Test
  fun aSlowDownloadTimesOut() {
    checkResponse = offer()
    archiveResponse = { MockResponse().setBody(Buffer().write(Fixtures.bytes("archives/valid.tar.gz"))).setHeadersDelay(2, TimeUnit.SECONDS) }
    updater(readTimeoutMs = 300).check()
    assertEquals(listOf("download_failed:timeout@$releaseId"), eventTypes())
    assertTrue(tmpIsEmpty())
  }

  @Test
  fun withoutFreeSpaceNothingIsDownloaded() {
    checkResponse = offer()
    freeSpace = 100
    updater().check()
    assertEquals(listOf("download_failed:no_space@$releaseId"), eventTypes())
    assertEquals(0, requests.count { it.path!!.startsWith("/archive") })
  }

  @Test
  fun aTamperedArchiveIsRejectedAndRemoved() {
    checkResponse = offer()
    archiveResponse = { MockResponse().setBody(Buffer().write(Fixtures.bytes("archives/tampered.tar.gz"))) }
    updater().check()
    assertNull(store.load()!!.pending)
    assertEquals(listOf("verification_failed:hash@$releaseId"), eventTypes())
    assertTrue(tmpIsEmpty())
  }

  @Test
  fun anIncompatibleReleaseIsRejectedBeforeDownloading() {
    config = config.copy(runtimeVersion = "2.0.0")
    checkResponse = offer()
    updater().check()
    assertEquals(listOf("verification_failed:incompatible@$releaseId"), eventTypes())
    assertEquals(0, requests.count { it.path!!.startsWith("/archive") })
  }

  @Test
  fun aReleaseForAnotherPlatformIsRejectedBeforeDownloading() {
    val iosManifest = String(manifestBytes, Charsets.UTF_8)
      .replace("\"platform\":\"android\"", "\"platform\":\"ios\"").toByteArray(Charsets.UTF_8)
    assertFalse(iosManifest.contentEquals(manifestBytes))
    val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    val point = (pair.public as ECPublicKey).w
    fun fixed(n: BigInteger) = n.toByteArray().takeLast(32).toByteArray().let { ByteArray(32 - it.size) + it }
    val sec1 = byteArrayOf(0x04) + fixed(point.affineX) + fixed(point.affineY)
    val signature = Signature.getInstance("SHA256withECDSA").run { initSign(pair.private); update(iosManifest); sign() }
    val keyId = OTAKeys.keyId(sec1)
    config = config.copy(publicKeys = mapOf(keyId to sec1))
    checkResponse = offer(manifest = iosManifest, signature = signature, keyId = keyId)

    updater().check()

    assertEquals(listOf("verification_failed:incompatible@$releaseId"), eventTypes())
    assertNull(store.load()!!.pending)
    assertEquals(0, requests.count { it.path!!.startsWith("/archive") })
    assertTrue(pendingNotices.isEmpty())
  }

  @Test
  fun aBlocklistedReleaseIsSkipped() {
    store.update { it.blocking(releaseId) }
    checkResponse = offer()
    updater().check()
    assertNull(store.load()!!.pending)
    assertTrue(events.read().isEmpty())
    assertEquals(0, requests.count { it.path!!.startsWith("/archive") })
  }

  @Test
  fun revertToEmbeddedIsRecordedForTheNextColdStart() {
    File(store.releaseDir(otherRelease), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    store.update { it.copy(stable = ReleasePointer(otherRelease, "index.android.bundle")) }
    checkResponse = { MockResponse().setBody("""{"update":null,"revert_to_embedded":true}""") }
    updater().check()
    val state = store.load()!!
    assertTrue(state.revertToEmbedded)
    assertEquals(otherRelease, state.stable?.releaseId)
  }

  @Test
  fun theQueueKeepsTheNewest50() {
    val added = List(60) { OTAEvent.create(OTAEvent.APPLIED, null, now = it.toLong()) }
    added.forEach(events::add)
    assertEquals(added.takeLast(50).map { it.eventId }, events.read().map { it.eventId })
  }

  @Test
  fun eventsAreFlushedInBatchesWithoutPersonalData() {
    List(60) { OTAEvent.create(OTAEvent.DOWNLOAD_FAILED, releaseId, "network", now) }.forEach(events::add)
    updater().flushEvents()

    assertTrue(events.read().isEmpty())
    val batch = JSONObject(requests.first { it.path!!.endsWith("/ota/events") }.body.readUtf8())
    assertEquals(setOf("installation_id", "platform", "events"), batch.keys().asSequence().toSet())
    val event = batch.getJSONArray("events").getJSONObject(0)
    assertEquals(setOf("event_id", "type", "release_id", "reason", "occurred_at"), event.keys().asSequence().toSet())
    assertEquals(50, batch.getJSONArray("events").length())
  }

  @Test
  fun theFlushedBatchCarriesEachEventByValue() {
    val queued = listOf(
      OTAEvent.create(OTAEvent.DOWNLOADED, releaseId, now = now),
      OTAEvent.create(OTAEvent.VERIFICATION_FAILED, otherRelease, "signature", now + 1),
      OTAEvent.create(OTAEvent.INTEGRATION_MISSING, null, now = now + 2)
    )
    queued.forEach(events::add)
    updater().flushEvents()

    val request = requests.single { it.path!!.endsWith("/ota/events") }
    assertEquals("/v1/apps/${manifest.appId}/ota/events", request.path)
    assertEquals("Bearer ck_live", request.getHeader("Authorization"))
    val batch = JSONObject(request.body.readUtf8())
    assertEquals(store.load()!!.installationId, batch.getString("installation_id"))
    assertEquals("android", batch.getString("platform"))
    val sent = batch.getJSONArray("events")
    assertEquals(3, sent.length())

    val downloaded = sent.getJSONObject(0)
    assertEquals(queued[0].eventId, downloaded.getString("event_id"))
    assertEquals("downloaded", downloaded.getString("type"))
    assertEquals(releaseId, downloaded.getString("release_id"))
    assertFalse(downloaded.has("reason"))
    assertEquals("1970-01-01T02:46:40.000Z", downloaded.getString("occurred_at"))

    val rejected = sent.getJSONObject(1)
    assertEquals(queued[1].eventId, rejected.getString("event_id"))
    assertEquals("verification_failed", rejected.getString("type"))
    assertEquals(otherRelease, rejected.getString("release_id"))
    assertEquals("signature", rejected.getString("reason"))
    assertEquals("1970-01-01T02:46:40.001Z", rejected.getString("occurred_at"))

    val missing = sent.getJSONObject(2)
    assertEquals("integration_missing", missing.getString("type"))
    assertFalse(missing.has("release_id"))
    assertFalse(missing.has("reason"))
    assertTrue(events.read().isEmpty())
  }

  @Test
  fun aDownloadedReleaseIsFlushedWithItsReleaseId() {
    checkResponse = offer()
    val updater = updater()
    updater.check()
    updater.flushEvents()

    val batch = JSONObject(requests.single { it.path!!.endsWith("/ota/events") }.body.readUtf8())
    val event = batch.getJSONArray("events").getJSONObject(0)
    assertEquals("downloaded", event.getString("type"))
    assertEquals(releaseId, event.getString("release_id"))
    assertEquals(store.load()!!.installationId, batch.getString("installation_id"))
    assertEquals("android", batch.getString("platform"))
  }

  @Test
  fun eventsStayQueuedWhenTheServerFails() {
    events.add(OTAEvent.create(OTAEvent.APPLIED, releaseId, now = now))
    eventsResponse = { MockResponse().setResponseCode(503) }
    updater().flushEvents()
    assertEquals(1, events.read().size)
  }

  @Test
  fun foregroundChecksAreThrottledTo30Minutes() {
    val updater = updater()
    updater.onReady()
    updater.onReady()
    assertEquals(1, requests.count { it.path!!.endsWith("/ota/check") })
    now += OTAUpdater.CHECK_INTERVAL_MS
    updater.onReady()
    assertEquals(2, requests.count { it.path!!.endsWith("/ota/check") })
  }

  @Test
  fun aNewerReleaseReplacesThePendingOne() {
    File(store.releaseDir(otherRelease), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    store.update { it.copy(pending = ReleasePointer(otherRelease, "index.android.bundle"), failedCount = 1) }
    checkResponse = offer()
    updater().check()
    val state = store.load()!!
    assertEquals(releaseId, state.pending?.releaseId)
    assertEquals(0, state.failedCount)
    assertFalse(store.releaseDir(otherRelease).exists())
  }
}
