package com.notti.ota

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

internal class FakeScheduler : OTAScheduler {
  var now = 0L
  private val tasks = mutableListOf<Triple<Long, () -> Unit, Int>>()
  private var nextId = 0

  override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
    val id = nextId++
    tasks += Triple(now + delayMs, task, id)
    return { tasks.removeAll { it.third == id } }
  }

  fun advance(ms: Long) {
    now += ms
    while (true) {
      val due = tasks.filter { it.first <= now }.minByOrNull { it.first } ?: return
      tasks.remove(due)
      due.second()
    }
  }
}

@RunWith(RobolectricTestRunner::class)
class OTALaunchMonitorTest {
  @get:Rule val tmp = TemporaryFolder()

  private val releaseA = "7d4f8a2e-1b3c-4e5f-9a6b-0c1d2e3f4a5b"
  private val releaseB = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
  private val bundle = "index.android.bundle"

  private lateinit var store: OTAStateStore
  private lateinit var events: OTAEventQueue
  private val scheduler = FakeScheduler()
  private var checks = 0

  private fun setUpStore(): OTAStateStore {
    store = OTAStateStore(tmp.newFolder())
    events = OTAEventQueue(File(store.root, "events.json"))
    return store
  }

  private fun installRelease(id: String) = File(store.releaseDir(id), bundle).apply { parentFile!!.mkdirs(); writeText("bundle $id") }

  private fun stateWith(stable: String? = null, pending: String? = null, change: (OTAState) -> OTAState = { it }): OTAState {
    val opened = store.open("id")
    stable?.let(::installRelease)
    pending?.let(::installRelease)
    val state = change(
      opened.copy(
        stable = stable?.let { ReleasePointer(it, bundle) },
        pending = pending?.let { ReleasePointer(it, bundle) }
      )
    )
    store.save(state)
    return state
  }

  private fun boot(exit: PreviousExit = PreviousExit.UNKNOWN): BootDecision {
    val decision = OTABoot.decide(store.load()!!, store, { exit }, 1_000)
    store.save(decision.state)
    decision.events.forEach(events::add)
    return decision
  }

  private fun monitor(
    decision: BootDecision,
    requested: Boolean = true,
    loaded: String? = null
  ) = OTALaunchMonitor(store, events, decision, scheduler, { scheduler.now }, { loaded }, { checks++ })
    .also { it.bundleRequested = requested }

  private fun eventTypes() = events.read().map { "${it.type}:${it.reason ?: ""}" }

  @Test
  fun aPendingReleaseIsSelectedAtBoot() {
    setUpStore()
    stateWith(stable = releaseA, pending = releaseB)
    val decision = boot()
    assertEquals(releaseB, decision.selected?.releaseId)
    assertTrue(decision.selectedIsPending)
  }

  @Test
  fun revertToEmbeddedDropsEveryReleaseAtTheNextBoot() {
    setUpStore()
    stateWith(stable = releaseA) { it.copy(revertToEmbedded = true) }

    val decision = boot()

    assertNull(decision.selected)
    assertFalse(decision.state.revertToEmbedded)
    assertFalse(store.releaseDir(releaseA).exists())
    assertEquals(listOf("reverted_to_embedded:server"), eventTypes())
  }

  @Test
  fun aLeftoverMarkerCountsOneFailedLaunch() {
    setUpStore()
    stateWith(pending = releaseB) { it.copy(attempt = LaunchAttempt(releaseB, 500)) }

    val decision = boot(PreviousExit.UNKNOWN)

    assertEquals(1, decision.state.failedCount)
    assertNull(decision.state.attempt)
    assertEquals(releaseB, decision.selected?.releaseId)
  }

  @Test
  fun aSecondFailureRollsBackToStableAndBlocklists() {
    setUpStore()
    stateWith(stable = releaseA, pending = releaseB) { it.copy(attempt = LaunchAttempt(releaseB, 500), failedCount = 1) }

    val decision = boot(PreviousExit.CRASH)

    assertEquals(releaseA, decision.selected?.releaseId)
    assertNull(decision.state.pending)
    assertEquals(listOf(releaseB), decision.state.blocklist)
    assertFalse(store.releaseDir(releaseB).exists())
    assertEquals(listOf("rolled_back:crash"), eventTypes())
  }

  @Test
  fun aRollbackWithoutStableBootsEmbedded() {
    setUpStore()
    stateWith(pending = releaseB) { it.copy(attempt = LaunchAttempt(releaseB, 500), failedCount = 1) }
    assertNull(boot().selected)
  }

  @Test
  fun threeInterruptedLaunchesCountAsOneFailure() {
    setUpStore()
    stateWith(pending = releaseB) { it.copy(attempt = LaunchAttempt(releaseB, 500)) }
    repeat(2) {
      val decision = boot(PreviousExit.INTERRUPTED)
      assertEquals(0, decision.state.failedCount)
      store.save(decision.state.copy(attempt = LaunchAttempt(releaseB, 500)))
    }
    val third = boot(PreviousExit.INTERRUPTED)
    assertEquals(1, third.state.failedCount)
    assertEquals(0, third.state.interruptedCount)
    assertEquals("interrupted", third.state.lastFailureReason)
  }

  @Test
  fun interruptionsAfterAFailureRollBackWithReasonInterrupted() {
    setUpStore()
    stateWith(pending = releaseB) { it.copy(attempt = LaunchAttempt(releaseB, 500), failedCount = 1, interruptedCount = 2) }
    boot(PreviousExit.INTERRUPTED)
    assertEquals(listOf("rolled_back:interrupted"), eventTypes())
  }

  @Test
  fun aMissingPendingBundleIsDropped() {
    setUpStore()
    stateWith(stable = releaseA, pending = releaseB)
    store.releaseDir(releaseB).deleteRecursively()
    assertEquals(releaseA, boot().selected?.releaseId)
  }

  @Test
  fun aForegroundLaunchThatShowsContentFor3SecondsIsApplied() {
    setUpStore()
    stateWith(stable = releaseA, pending = releaseB)
    val monitor = monitor(boot())

    monitor.onForeground()
    assertEquals(releaseB, store.load()!!.attempt?.releaseId)
    monitor.onContentAppeared()
    scheduler.advance(2_999)
    assertNotNull(store.load()!!.pending)
    scheduler.advance(1)

    val state = store.load()!!
    assertEquals(releaseB, state.stable?.releaseId)
    assertNull(state.pending)
    assertNull(state.attempt)
    assertFalse(store.releaseDir(releaseA).exists())
    assertEquals(listOf("applied:"), eventTypes())
    assertEquals(1, checks)
  }

  @Test
  fun noContentWithin10SecondsIsAWatchdogFailure() {
    setUpStore()
    stateWith(pending = releaseB)
    val first = monitor(boot())
    first.onForeground()
    scheduler.advance(10_000)
    assertEquals(1, store.load()!!.failedCount)
    assertEquals("watchdog", store.load()!!.lastFailureReason)
    assertNull(store.load()!!.attempt)

    first.onContentAppeared()
    scheduler.advance(5_000)
    assertNotNull(store.load()!!.pending)

    val second = monitor(boot())
    second.onForeground()
    scheduler.advance(10_000)
    assertNull(store.load()!!.pending)
    assertEquals(listOf("rolled_back:watchdog"), eventTypes())
  }

  @Test
  fun aCrashBeforeContentOrDuringTheGraceIsAFailure() {
    setUpStore()
    stateWith(pending = releaseB)
    val first = monitor(boot())
    first.onForeground()
    first.onFatal()
    assertEquals(1, store.load()!!.failedCount)

    val second = monitor(boot())
    second.onForeground()
    second.onContentAppeared()
    scheduler.advance(1_000)
    second.onFatal()
    assertNull(store.load()!!.pending)
    assertEquals(listOf("rolled_back:crash"), eventTypes())
  }

  @Test
  fun aCrashAfterSuccessDoesNotRevert() {
    setUpStore()
    stateWith(pending = releaseB)
    val monitor = monitor(boot())
    monitor.onForeground()
    monitor.onContentAppeared()
    scheduler.advance(3_000)
    monitor.onFatal()
    assertEquals(releaseB, store.load()!!.stable?.releaseId)
    assertEquals(0, store.load()!!.failedCount)
  }

  @Test
  fun aHeadlessStartNeverChangesTheState() {
    setUpStore()
    val before = stateWith(pending = releaseB)
    val decision = boot()
    val monitor = monitor(decision)
    OTAActivityCallbacks(monitor)
    monitor.onFatal()
    scheduler.advance(60_000)
    assertEquals(before, store.load())
    assertTrue(events.read().isEmpty())
    assertEquals(OTALaunchMonitor.Phase.STARTING, monitor.phase)
  }

  @Test
  fun leavingBeforeContentIsAnInterruptedLaunch() {
    setUpStore()
    stateWith(pending = releaseB)
    val monitor = monitor(boot())
    monitor.onForeground()
    monitor.onBackground()
    scheduler.advance(20_000)
    val state = store.load()!!
    assertEquals(1, state.interruptedCount)
    assertEquals(0, state.failedCount)
    assertNull(state.attempt)
  }

  @Test
  fun onlyTheFirstForegroundCountsAnAttempt() {
    setUpStore()
    stateWith(pending = releaseB)
    val monitor = monitor(boot())
    val callbacks = OTAActivityCallbacks(monitor)
    val activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java).get()
    callbacks.onActivityStarted(activity)
    callbacks.onActivityStarted(activity)
    callbacks.onActivityStopped(activity)
    assertEquals(OTALaunchMonitor.Phase.ATTEMPTING, monitor.phase)
    callbacks.onActivityStopped(activity)
    assertEquals(OTALaunchMonitor.Phase.DONE, monitor.phase)
  }

  @Test
  fun aStableLaunchChecksAfterFirstContent() {
    setUpStore()
    stateWith(stable = releaseA)
    val monitor = monitor(boot())
    monitor.onForeground()
    monitor.onContentAppeared()
    assertEquals(1, checks)
    assertNull(store.load()!!.attempt)
  }

  @Test
  fun aMissingBundleHookIsReportedOncePerBinary() {
    setUpStore()
    stateWith(pending = releaseB)
    repeat(2) {
      val monitor = monitor(boot(), requested = false)
      monitor.onForeground()
      monitor.onContentAppeared()
      scheduler.advance(10_000)
      assertTrue(monitor.disabled)
    }
    assertEquals(listOf("integration_missing:"), eventTypes())
    assertEquals(0, checks)
    assertEquals(0, store.load()!!.failedCount)
    assertNotNull(store.load()!!.pending)
  }

  @Test
  fun developerSupportNeverReportsAMissingHookOrAnOverride() {
    setUpStore()
    val before = stateWith(pending = releaseB)
    val monitor = monitor(boot(), requested = false, loaded = "/dev-server/index.bundle")
    monitor.onDeveloperSupport()
    monitor.onForeground()
    monitor.onContentAppeared()
    scheduler.advance(20_000)

    assertTrue(eventTypes().isEmpty())
    assertEquals(before, store.load()!!)
    assertEquals(0, checks)
  }

  @Test
  fun developerSupportLearnedDuringAnAttemptEndsItWithoutAVerdict() {
    setUpStore()
    stateWith(pending = releaseB)
    val monitor = monitor(boot())
    monitor.onForeground()
    assertNotNull(store.load()!!.attempt)

    monitor.onDeveloperSupport()
    scheduler.advance(20_000)
    monitor.onBackground()

    val state = store.load()!!
    assertNull(state.attempt)
    assertEquals(0, state.failedCount)
    assertEquals(0, state.interruptedCount)
    assertEquals(releaseB, state.pending?.releaseId)
    assertTrue(eventTypes().isEmpty())
  }

  @Test
  fun anOverriddenBundleTurnsLiveUpdatesOffForTheSession() {
    setUpStore()
    stateWith(pending = releaseB)
    val monitor = monitor(boot(), loaded = "assets://index.android.bundle")
    monitor.onForeground()
    monitor.onContentAppeared()
    scheduler.advance(10_000)

    assertTrue(monitor.disabled)
    assertEquals(listOf("bundle_overridden:"), eventTypes())
    assertNull(store.load()!!.attempt)
    assertEquals(0, store.load()!!.failedCount)
    assertEquals(0, checks)
  }

  @Test
  fun theCrashHandlerChainsThePreviousOne() {
    setUpStore()
    stateWith(pending = releaseB)
    val monitor = monitor(boot())
    monitor.onForeground()
    val original = Thread.getDefaultUncaughtExceptionHandler()
    var previousCalled: Throwable? = null
    try {
      Thread.setDefaultUncaughtExceptionHandler { _, e -> previousCalled = e }
      OTACrashHandler.install(monitor)
      val error = RuntimeException("boom")
      Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread.currentThread(), error)
      assertEquals(error, previousCalled)
      assertEquals(1, store.load()!!.failedCount)
    } finally {
      Thread.setDefaultUncaughtExceptionHandler(original)
    }
  }
}

@RunWith(RobolectricTestRunner::class)
class NottiOtaEntryTest {
  private val context = ApplicationProvider.getApplicationContext<Context>()

  @Before
  @After
  fun reset() = NottiOta.resetForTests()

  private fun configure(metaData: Bundle?) {
    shadowOf(context.packageManager).installPackage(
      PackageInfo().apply {
        packageName = context.packageName
        versionName = "1.0"
        lastUpdateTime = 1
        applicationInfo = ApplicationInfo().apply { packageName = context.packageName; this.metaData = metaData }
      }
    )
  }

  private fun validMetaData() = Bundle().apply {
    putString(OTAConfig.KEY_APP_ID, "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f")
    putString(OTAConfig.KEY_BASE_URL, "https://push.example.com")
    putString(OTAConfig.KEY_CLIENT_KEY, "ck")
    putString(OTAConfig.KEY_CHANNEL, "production")
    putString(OTAConfig.KEY_RUNTIME_VERSION, "1.4.0")
    putString(OTAConfig.KEY_PUBLIC_KEYS, "${Fixtures.keyId}:${Fixtures.publicKeyBase64}")
  }

  private fun configureDebuggable(metaData: Bundle?) {
    shadowOf(context.packageManager).installPackage(
      PackageInfo().apply {
        packageName = context.packageName
        versionName = "1.0"
        lastUpdateTime = 1
        applicationInfo = ApplicationInfo().apply {
          packageName = context.packageName
          this.metaData = metaData
          flags = ApplicationInfo.FLAG_DEBUGGABLE
        }
      }
    )
  }

  @Test
  fun aDebugBuildIsInertEvenWithAPendingRelease() {
    configureDebuggable(validMetaData())
    val root = File(context.filesDir, "notti-ota")

    assertTrue(NottiOta.isDebuggable(context))
    assertNull(NottiOta.getJSBundleFile(context))
    assertNull(NottiOta.session)
    assertNull(NottiOta.currentReleaseId())
    assertFalse(root.exists())
  }

  @Test
  fun aReleaseBuildIsNotDebuggable() {
    configure(validMetaData())
    assertFalse(NottiOta.isDebuggable(context))
    assertNotNull(NottiOta.prepare(context))
  }

  @Test
  fun developerSupportTurnsAReleaseSessionOffAndNeverThrowsWithoutOne() {
    NottiOta.onDeveloperSupport()
    configure(validMetaData())
    val session = NottiOta.prepare(context)!!
    NottiOta.onDeveloperSupport()
    assertTrue(session.monitor.disabled)
    assertNull(NottiOta.currentReleaseId())
  }

  @Test
  fun withoutConfigurationTheEmbeddedBundleIsUsedAndNothingIsWritten() {
    configure(null)
    assertNull(NottiOta.getJSBundleFile(context))
    assertFalse(File(context.filesDir, "notti-ota").exists())
  }

  @Test
  fun aPendingReleaseIsReturnedAsAnAbsolutePath() {
    configure(validMetaData())
    val store = OTAStateStore(File(context.filesDir, "notti-ota"))
    val releaseId = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
    val state = store.open(BinaryIdentity.of(context)).copy(pending = ReleasePointer(releaseId, "index.android.bundle"))
    File(store.releaseDir(releaseId), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    store.save(state)

    val path = NottiOta.getJSBundleFile(context)

    assertEquals(File(store.releaseDir(releaseId), "index.android.bundle").absolutePath, path)
    assertTrue(NottiOta.session!!.monitor.bundleRequested)
  }

  @Test
  fun theCurrentReleaseIsTheSelectedOneOnceTheHostAskedForIt() {
    configure(validMetaData())
    val store = OTAStateStore(File(context.filesDir, "notti-ota"))
    val releaseId = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
    val state = store.open(BinaryIdentity.of(context)).copy(stable = ReleasePointer(releaseId, "index.android.bundle"))
    File(store.releaseDir(releaseId), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    store.save(state)

    NottiOta.prepare(context)
    assertNull(NottiOta.currentReleaseId())
    NottiOta.getJSBundleFile(context)
    assertEquals(releaseId, NottiOta.currentReleaseId())
  }

  @Test
  fun aReadyReleaseReachesTheListenerAndAFailingListenerNeverThrows() {
    val received = mutableListOf<ReleasePointer>()
    val pointer = ReleasePointer("1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b", "index.android.bundle", mandatory = true)
    NottiOta.releaseReady(pointer)
    NottiOta.updateReadyListener = { received += it }
    NottiOta.releaseReady(pointer)
    assertEquals(listOf(pointer), received)
    NottiOta.updateReadyListener = { throw IllegalStateException("bridge gone") }
    NottiOta.releaseReady(pointer)
  }

  @Test
  fun aCorruptStateNeverThrowsAndBootsEmbedded() {
    configure(validMetaData())
    File(context.filesDir, "notti-ota").mkdirs()
    File(context.filesDir, "notti-ota/state.json").writeText("garbage")
    assertNull(NottiOta.getJSBundleFile(context))
  }

  @Test
  fun selectingTheBundleTakesUnder5Milliseconds() {
    configure(validMetaData())
    NottiOta.prepare(context)
    val samples = (1..50).map {
      val start = System.nanoTime()
      NottiOta.getJSBundleFile(context)
      System.nanoTime() - start
    }.sorted()
    val medianMs = samples[samples.size / 2] / 1_000_000.0
    assertTrue("median $medianMs ms", medianMs < 5.0)
  }

  @Test
  fun theColdBootDecisionTakesUnder5Milliseconds() {
    configure(validMetaData())
    val samples = (1..30).map {
      NottiOta.resetForTests()
      val start = System.nanoTime()
      NottiOta.getJSBundleFile(context)
      System.nanoTime() - start
    }.drop(10).sorted()
    val medianMs = samples[samples.size / 2] / 1_000_000.0
    assertTrue("median $medianMs ms", medianMs < 5.0)
  }
}
