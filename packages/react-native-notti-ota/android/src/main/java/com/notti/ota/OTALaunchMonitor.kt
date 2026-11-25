package com.notti.ota

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.facebook.react.ReactApplication
import com.facebook.react.bridge.ReactMarker
import com.facebook.react.bridge.ReactMarkerConstants
import java.io.File

/** How the previous process ended, for a launch attempt left over at start. */
internal enum class PreviousExit { CRASH, INTERRUPTED, UNKNOWN }

internal fun interface ExitReasonSource {
  /** The most recent exit of this app's process at or after [since] (epoch ms). */
  fun lastExit(since: Long): PreviousExit
}

internal class AndroidExitReasons(private val context: Context) : ExitReasonSource {
  override fun lastExit(since: Long): PreviousExit {
    if (Build.VERSION.SDK_INT < 30) return PreviousExit.UNKNOWN
    val manager = context.getSystemService(ActivityManager::class.java) ?: return PreviousExit.UNKNOWN
    val exit = manager.getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull() ?: return PreviousExit.UNKNOWN
    if (exit.timestamp < since) return PreviousExit.UNKNOWN
    return when (exit.reason) {
      ApplicationExitInfo.REASON_CRASH,
      ApplicationExitInfo.REASON_CRASH_NATIVE,
      ApplicationExitInfo.REASON_ANR,
      ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> PreviousExit.CRASH
      ApplicationExitInfo.REASON_USER_REQUESTED,
      ApplicationExitInfo.REASON_USER_STOPPED,
      ApplicationExitInfo.REASON_LOW_MEMORY,
      ApplicationExitInfo.REASON_SIGNALED,
      ApplicationExitInfo.REASON_EXIT_SELF,
      ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
      ApplicationExitInfo.REASON_PERMISSION_CHANGE,
      ApplicationExitInfo.REASON_DEPENDENCY_DIED,
      ApplicationExitInfo.REASON_OTHER -> PreviousExit.INTERRUPTED
      else -> PreviousExit.UNKNOWN
    }
  }
}

/** The failure and rollback rules shared by the boot decision and the running session. */
internal object OTARollback {
  const val MAX_FAILURES = 2
  const val INTERRUPTED_PER_FAILURE = 3

  const val CRASH = "crash"
  const val WATCHDOG = "watchdog"
  const val INTERRUPTED = "interrupted"

  /** One failed launch of the pending release; the second one rolls it back and blocklists it. */
  fun failed(state: OTAState, reason: String, events: MutableList<OTAEvent>, now: Long): OTAState {
    val pending = state.pending ?: return state.copy(attempt = null)
    val failures = state.failedCount + 1
    if (failures < MAX_FAILURES) {
      return state.copy(attempt = null, failedCount = failures, interruptedCount = 0, lastFailureReason = reason)
    }
    Log.w(TAG, "Live updates: release ${pending.releaseId} failed $failures launches ($reason), rolling back")
    events += OTAEvent.create(OTAEvent.ROLLED_BACK, pending.releaseId, reason, now)
    return state.blocking(pending.releaseId).copy(
      pending = null, attempt = null, failedCount = 0, interruptedCount = 0, lastFailureReason = null
    )
  }

  /** A launch the user or the OS ended before it could prove anything; 3 count as 1 failure. */
  fun interrupted(state: OTAState, events: MutableList<OTAEvent>, now: Long): OTAState {
    val interrupted = state.interruptedCount + 1
    if (interrupted < INTERRUPTED_PER_FAILURE) return state.copy(attempt = null, interruptedCount = interrupted)
    return failed(state.copy(interruptedCount = 0), INTERRUPTED, events, now)
  }
}

internal class BootDecision(val state: OTAState, val selected: ReleasePointer?, val events: List<OTAEvent>) {
  val selectedIsPending: Boolean get() = selected != null && selected == state.pending
}

/** The native boot decision, before any JS runs (spec OTA-24 to OTA-28). */
internal object OTABoot {
  fun decide(initial: OTAState, store: OTAStateStore, exits: ExitReasonSource, now: Long): BootDecision {
    val events = mutableListOf<OTAEvent>()
    var state = initial

    if (state.revertToEmbedded) {
      events += OTAEvent.create(OTAEvent.REVERTED_TO_EMBEDDED, state.stable?.releaseId, "server", now)
      state = state.copy(stable = null, pending = null, attempt = null, failedCount = 0, interruptedCount = 0, lastFailureReason = null, revertToEmbedded = false)
    }

    val attempt = state.attempt
    if (attempt != null) {
      state = if (attempt.releaseId != state.pending?.releaseId) {
        state.copy(attempt = null)
      } else {
        when (exits.lastExit(attempt.startedAt)) {
          PreviousExit.INTERRUPTED -> OTARollback.interrupted(state, events, now)
          PreviousExit.CRASH, PreviousExit.UNKNOWN -> OTARollback.failed(state, OTARollback.CRASH, events, now)
        }
      }
    }

    if (state.pending != null && !store.bundleFile(state.pending!!).isFile) state = state.copy(pending = null, attempt = null)
    if (state.stable != null && !store.bundleFile(state.stable!!).isFile) state = state.copy(stable = null)

    store.pruneReleases(setOfNotNull(state.stable?.releaseId, state.pending?.releaseId))
    return BootDecision(state, state.pending ?: state.stable, events)
  }
}

internal fun interface OTAScheduler {
  fun schedule(delayMs: Long, task: () -> Unit): () -> Unit
}

/**
 * The running session's launch evaluation (design: device boot state machine). An attempt only
 * counts from a foreground start; a process started headless never touches the state.
 */
internal class OTALaunchMonitor(
  private val store: OTAStateStore,
  private val events: OTAEventQueue,
  private val decision: BootDecision,
  private val scheduler: OTAScheduler,
  private val clock: () -> Long = System::currentTimeMillis,
  private val loadedSource: () -> String? = { null },
  private val readyToCheck: () -> Unit = {}
) {
  enum class Phase { STARTING, ATTEMPTING, GRACE, DONE }

  @Volatile var bundleRequested = false
  @Volatile var disabled = false
    private set
  var phase = Phase.STARTING
    private set

  private var foregroundCount = 0
  private var contentAppeared = false
  private var cancelTimer: (() -> Unit)? = null

  private val attemptingRelease: ReleasePointer?
    get() = if (bundleRequested && decision.selectedIsPending) decision.selected else null

  @Synchronized
  fun onForeground() {
    foregroundCount++
    if (foregroundCount > 1 || phase != Phase.STARTING) {
      if (phase == Phase.DONE && !disabled) readyToCheck()
      return
    }
    val pending = attemptingRelease
    if (pending == null) {
      phase = if (contentAppeared) Phase.DONE else Phase.STARTING
      return
    }
    store.update { it.copy(attempt = LaunchAttempt(pending.releaseId, clock())) }
    phase = Phase.ATTEMPTING
    cancelTimer = scheduler.schedule(WATCHDOG_MS) { onWatchdog() }
  }

  @Synchronized
  fun onBackground() {
    if (phase != Phase.ATTEMPTING) return
    cancelTimer?.invoke()
    record { state, queued, now -> OTARollback.interrupted(state, queued, now) }
    phase = Phase.DONE
  }

  @Synchronized
  fun onContentAppeared() {
    if (contentAppeared) return
    contentAppeared = true
    checkIntegration()
    when (phase) {
      Phase.ATTEMPTING -> {
        cancelTimer?.invoke()
        if (disabled) {
          store.update { it.copy(attempt = null) }
          phase = Phase.DONE
          return
        }
        phase = Phase.GRACE
        cancelTimer = scheduler.schedule(GRACE_MS) { onGraceElapsed() }
      }
      Phase.STARTING -> {
        if (foregroundCount > 0) {
          phase = Phase.DONE
          if (!disabled) readyToCheck()
        }
      }
      else -> Unit
    }
  }

  /** Called from the uncaught-exception handler: records only, never swallows the crash. */
  @Synchronized
  fun onFatal() {
    if (phase != Phase.ATTEMPTING && phase != Phase.GRACE) return
    cancelTimer?.invoke()
    record { state, queued, now -> OTARollback.failed(state, OTARollback.CRASH, queued, now) }
    phase = Phase.DONE
  }

  @Synchronized
  private fun onWatchdog() {
    if (phase != Phase.ATTEMPTING) return
    Log.w(TAG, "Live updates: no content ${WATCHDOG_MS / 1000} s after the app started, counting a failed launch")
    record { state, queued, now -> OTARollback.failed(state, OTARollback.WATCHDOG, queued, now) }
    phase = Phase.DONE
  }

  @Synchronized
  private fun onGraceElapsed() {
    if (phase != Phase.GRACE) return
    val pending = decision.selected ?: return
    val now = clock()
    val state = store.update { state ->
      if (state.pending?.releaseId != pending.releaseId) return@update state.copy(attempt = null)
      state.copy(stable = state.pending, pending = null, attempt = null, failedCount = 0, interruptedCount = 0, lastFailureReason = null)
    }
    store.pruneReleases(setOfNotNull(state.stable?.releaseId, state.pending?.releaseId))
    events.add(OTAEvent.create(OTAEvent.APPLIED, pending.releaseId, now = now))
    Log.i(TAG, "Live updates: release ${pending.releaseId} applied")
    phase = Phase.DONE
    readyToCheck()
  }

  private fun record(change: (OTAState, MutableList<OTAEvent>, Long) -> OTAState) {
    val queued = mutableListOf<OTAEvent>()
    val now = clock()
    store.update { change(it, queued, now) }
    queued.forEach(events::add)
  }

  private fun checkIntegration() {
    if (!bundleRequested) {
      Log.e(TAG, "Live updates: the app never asked for its bundle. Pass NottiOta.getJSBundleFile(context) as jsBundleFilePath to getDefaultReactHost, or install react-native-notti-ota-expo in an Expo app.")
      reportOnce(OTAEvent.INTEGRATION_MISSING)
      disabled = true
      return
    }
    val selected = decision.selected ?: return
    val loaded = try {
      loadedSource()
    } catch (e: Exception) {
      null
    } ?: return
    if (loaded != store.bundleFile(selected).absolutePath) {
      Log.e(TAG, "Live updates: another bundle was loaded instead of the selected one; Live updates are off for this session.")
      reportOnce(OTAEvent.BUNDLE_OVERRIDDEN, selected.releaseId)
      disabled = true
    }
  }

  private fun reportOnce(type: String, releaseId: String? = null) {
    var first = false
    store.update { state ->
      first = type !in state.reported
      if (first) state.copy(reported = state.reported + type) else state
    }
    if (first) events.add(OTAEvent.create(type, releaseId, now = clock()))
  }

  companion object {
    const val WATCHDOG_MS = 10_000L
    const val GRACE_MS = 3_000L
  }
}

/** Process-wide entry point the host app calls before React Native loads its bundle. */
object NottiOta {
  private var prepared = false
  @Volatile internal var session: Session? = null
    private set

  /** Set by the TurboModule while JS can receive `otaUpdateReady`. */
  @Volatile internal var updateReadyListener: ((ReleasePointer) -> Unit)? = null

  internal class Session(
    val config: OTAConfig,
    val store: OTAStateStore,
    val events: OTAEventQueue,
    val decision: BootDecision,
    val monitor: OTALaunchMonitor
  ) {
    val selectedPath: String? = decision.selected?.let { store.bundleFile(it).absolutePath }
  }

  /**
   * The bundle React Native should load: a downloaded Live update, or null for the embedded
   * bundle. Synchronous, no network, never throws. Bare apps pass it as `jsBundleFilePath` to
   * `getDefaultReactHost`; the Expo adapter calls it for you.
   */
  @JvmStatic
  fun getJSBundleFile(context: Context): String? =
    try {
      val current = prepare(context.applicationContext ?: context)
      current?.monitor?.bundleRequested = true
      current?.selectedPath
    } catch (t: Throwable) {
      Log.e(TAG, "Live updates: could not select a bundle, using the embedded one (${t.javaClass.simpleName})")
      null
    }

  /** The Live update this session runs: selected, asked for by the host and not overridden. */
  internal fun currentReleaseId(): String? {
    val current = session ?: return null
    if (!current.monitor.bundleRequested || current.monitor.disabled) return null
    return current.decision.selected?.releaseId
  }

  internal fun releaseReady(pointer: ReleasePointer) {
    try {
      updateReadyListener?.invoke(pointer)
    } catch (t: Throwable) {
      Log.e(TAG, "Live updates: could not notify JS of a ready release (${t.javaClass.simpleName})")
    }
  }

  @Synchronized
  internal fun prepare(
    context: Context,
    exits: ExitReasonSource = AndroidExitReasons(context),
    scheduler: OTAScheduler = MainThreadScheduler
  ): Session? {
    if (prepared) return session
    prepared = true
    val config = OTAConfig.read(context) ?: return null
    val store = OTAStateStore(File(context.filesDir, "notti-ota"))
    val events = OTAEventQueue(File(store.root, "events.json"))
    val now = System.currentTimeMillis()
    val opened = store.open(BinaryIdentity.of(context))
    val decision = OTABoot.decide(opened, store, exits, now)
    if (decision.state != opened) store.save(decision.state)
    decision.events.forEach(events::add)
    val updater = OTAUpdater(
      config, store, events, OTAApiClient(config), OTAUpdater.embeddedHermesVersion(context),
      onPending = ::releaseReady
    )
    val monitor = OTALaunchMonitor(
      store, events, decision, scheduler,
      loadedSource = { (context as? ReactApplication)?.reactHost?.currentReactContext?.sourceURL },
      readyToCheck = updater::onReady
    )
    return Session(config, store, events, decision, monitor).also { session = it }
  }

  internal fun resetForTests() {
    synchronized(this) {
      prepared = false
      session = null
      updateReadyListener = null
    }
  }
}

internal object MainThreadScheduler : OTAScheduler {
  private val handler by lazy { Handler(Looper.getMainLooper()) }

  override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
    val runnable = Runnable { task() }
    handler.postAtTime(runnable, SystemClock.uptimeMillis() + delayMs)
    return { handler.removeCallbacks(runnable) }
  }
}

/** Chains the existing default handler: records the failure, then lets the crash happen. */
internal object OTACrashHandler {
  fun install(monitor: OTALaunchMonitor) {
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, error ->
      try {
        monitor.onFatal()
      } catch (t: Throwable) {
        Log.e(TAG, "Live updates: could not record the crash (${t.javaClass.simpleName})")
      }
      if (previous != null) {
        previous.uncaughtException(thread, error)
      } else {
        android.os.Process.killProcess(android.os.Process.myPid())
        kotlin.system.exitProcess(10)
      }
    }
  }
}

/** Foreground signal: the first started Activity, never a headless start. */
internal class OTAActivityCallbacks(private val monitor: OTALaunchMonitor) : Application.ActivityLifecycleCallbacks {
  private var started = 0

  override fun onActivityStarted(activity: Activity) {
    if (started++ == 0) monitor.onForeground()
  }

  override fun onActivityStopped(activity: Activity) {
    if (started > 0 && --started == 0) monitor.onBackground()
  }

  override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
  override fun onActivityResumed(activity: Activity) = Unit
  override fun onActivityPaused(activity: Activity) = Unit
  override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
  override fun onActivityDestroyed(activity: Activity) = Unit
}

/**
 * Runs at process start, before `Application.onCreate`: makes the boot decision and installs the
 * launch hooks. Does nothing when Live updates are not configured.
 */
class NottiOtaInitProvider : ContentProvider() {
  override fun onCreate(): Boolean {
    val application = context?.applicationContext as? Application ?: return false
    try {
      val session = NottiOta.prepare(application) ?: return true
      install(application, session.monitor)
    } catch (t: Throwable) {
      Log.e(TAG, "Live updates: could not start (${t.javaClass.simpleName}); the embedded bundle is used")
    }
    return true
  }

  override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
  override fun getType(uri: Uri): String? = null
  override fun insert(uri: Uri, values: ContentValues?): Uri? = null
  override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
  override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

  internal companion object {
    fun install(application: Application, monitor: OTALaunchMonitor) {
      OTACrashHandler.install(monitor)
      application.registerActivityLifecycleCallbacks(OTAActivityCallbacks(monitor))
      ReactMarker.addListener { name, _, _ ->
        if (name == ReactMarkerConstants.CONTENT_APPEARED) monitor.onContentAppeared()
      }
    }
  }
}
