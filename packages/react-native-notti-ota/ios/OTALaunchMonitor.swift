import Foundation
import React
import UIKit

/// The failure and rollback rules shared by the boot decision and the running session.
enum OTARollback {
  static let maxFailures = 2
  static let interruptedPerFailure = 3

  static let crash = "crash"
  static let watchdog = "watchdog"
  static let interrupted = "interrupted"

  /// One failed launch of the pending release; the second one rolls it back and blocklists it.
  static func failed(_ state: OTAState, reason: String, events: inout [OTAEvent], now: Int64) -> OTAState {
    var next = state
    next.attempt = nil
    guard let pending = state.pending else { return next }
    let failures = state.failedCount + 1
    if failures < maxFailures {
      next.failedCount = failures
      next.interruptedCount = 0
      next.lastFailureReason = reason
      return next
    }
    otaLog.warning("Live updates: release \(pending.releaseId, privacy: .public) failed \(failures) launches (\(reason, privacy: .public)), rolling back")
    events.append(.create(OTAEvent.rolledBack, releaseId: pending.releaseId, reason: reason, now: now))
    next = next.blocking(pending.releaseId)
    next.pending = nil
    next.failedCount = 0
    next.interruptedCount = 0
    next.lastFailureReason = nil
    return next
  }

  /// A launch the user or the OS ended before it could prove anything; 3 count as 1 failure.
  static func interrupted(_ state: OTAState, events: inout [OTAEvent], now: Int64) -> OTAState {
    var next = state
    let count = state.interruptedCount + 1
    if count < interruptedPerFailure {
      next.attempt = nil
      next.interruptedCount = count
      return next
    }
    next.interruptedCount = 0
    return failed(next, reason: interrupted, events: &events, now: now)
  }
}

struct BootDecision {
  let state: OTAState
  let selected: ReleasePointer?
  let events: [OTAEvent]

  var selectedIsPending: Bool { selected != nil && selected == state.pending }
}

/// The native boot decision, before any JS runs (spec OTA-24 to OTA-28).
enum OTABoot {
  /// iOS has no process exit reasons: a launch attempt left over at start is a failed launch only when
  /// a crash handler wrote the crash marker; otherwise the user or the OS ended it (interrupted).
  static func decide(_ initial: OTAState, store: OTAStateStore, now: Int64) -> BootDecision {
    var events: [OTAEvent] = []
    var state = initial
    let crashed = store.crashMarked()
    store.clearCrashMarker()

    if state.revertToEmbedded {
      events.append(.create(OTAEvent.revertedToEmbedded, releaseId: state.stable?.releaseId, reason: "server", now: now))
      state.stable = nil
      state.pending = nil
      state.attempt = nil
      state.failedCount = 0
      state.interruptedCount = 0
      state.lastFailureReason = nil
      state.revertToEmbedded = false
    }

    if let attempt = state.attempt {
      if attempt.releaseId != state.pending?.releaseId {
        state.attempt = nil
      } else if crashed {
        state = OTARollback.failed(state, reason: OTARollback.crash, events: &events, now: now)
      } else {
        state = OTARollback.interrupted(state, events: &events, now: now)
      }
    }

    if let pending = state.pending, !isFile(store.bundleFile(pending)) {
      state.pending = nil
      state.attempt = nil
    }
    if let stable = state.stable, !isFile(store.bundleFile(stable)) { state.stable = nil }

    store.pruneReleases(keep: Set([state.stable?.releaseId, state.pending?.releaseId].compactMap { $0 }))
    return BootDecision(state: state, selected: state.pending ?? state.stable, events: events)
  }

  private static func isFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }
}

/// Arms the process-wide crash handlers for one launch attempt: a crash while armed writes
/// `crash.marker` from the handler itself, so the next boot can tell a crash from a kill.
final class OTACrashMarker {
  private let store: OTAStateStore

  init(store: OTAStateStore) {
    self.store = store
  }

  func arm() {
    do {
      try store.ensureRoot()
    } catch {
      return
    }
    NottiOtaCrashMarkerInstall()
    if !NottiOtaCrashMarkerArm(store.crashMarkerFile.path) {
      otaLog.error("Live updates: could not arm the crash marker; a crash in this launch counts as interrupted")
    }
  }

  func disarm() {
    NottiOtaCrashMarkerDisarm()
    store.clearCrashMarker()
  }
}

protocol OTAScheduler {
  /// Runs `task` after `delayMs`; the returned closure cancels it.
  func schedule(_ delayMs: Int64, _ task: @escaping () -> Void) -> () -> Void
}

struct MainQueueScheduler: OTAScheduler {
  func schedule(_ delayMs: Int64, _ task: @escaping () -> Void) -> () -> Void {
    let item = DispatchWorkItem(block: task)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    return { item.cancel() }
  }
}

/// The running session's launch evaluation (design: device boot state machine). An attempt only
/// counts from a foreground activation; a process launched in the background never touches the state.
final class OTALaunchMonitor {
  enum Phase { case starting, attempting, grace, done }

  static let watchdogMs: Int64 = 10_000
  static let graceMs: Int64 = 3_000

  private let store: OTAStateStore
  private let events: OTAEventQueue
  private let decision: BootDecision
  private let scheduler: OTAScheduler
  private let crashMarker: OTACrashMarker?
  private let clock: () -> Int64
  private let readyToCheck: () -> Void
  private let lock = NSRecursiveLock()

  private var requested = false
  private(set) var disabled = false
  private(set) var phase = Phase.starting
  private var foregroundCount = 0
  private var contentAppeared = false
  private var loadedBundle: URL?
  private var cancelTimer: (() -> Void)?

  init(
    store: OTAStateStore, events: OTAEventQueue, decision: BootDecision, scheduler: OTAScheduler,
    crashMarker: OTACrashMarker? = nil, clock: @escaping () -> Int64 = currentMillis,
    readyToCheck: @escaping () -> Void = {}
  ) {
    self.store = store
    self.events = events
    self.decision = decision
    self.scheduler = scheduler
    self.crashMarker = crashMarker
    self.clock = clock
    self.readyToCheck = readyToCheck
  }

  var bundleRequested: Bool {
    get { locked { requested } }
    set { locked { requested = newValue } }
  }

  private var attemptingRelease: ReleasePointer? {
    requested && decision.selectedIsPending ? decision.selected : nil
  }

  func onForeground() {
    locked {
      foregroundCount += 1
      if foregroundCount > 1 || phase != .starting {
        if phase == .done && !disabled { readyToCheck() }
        return
      }
      guard let pending = attemptingRelease else {
        phase = contentAppeared ? .done : .starting
        return
      }
      let now = clock()
      crashMarker?.arm()
      persist { state in
        var next = state
        next.attempt = LaunchAttempt(releaseId: pending.releaseId, startedAt: now)
        return next
      }
      phase = .attempting
      cancelTimer = scheduler.schedule(Self.watchdogMs) { [weak self] in self?.onWatchdog() }
    }
  }

  func onBackground() {
    locked {
      guard phase == .attempting else { return }
      cancelTimer?()
      record { state, queued, now in OTARollback.interrupted(state, events: &queued, now: now) }
      crashMarker?.disarm()
      phase = .done
    }
  }

  func onContentAppeared() {
    locked {
      if contentAppeared { return }
      contentAppeared = true
      checkIntegration()
      switch phase {
      case .attempting:
        cancelTimer?()
        if disabled {
          endAttemptWithoutVerdict()
          return
        }
        phase = .grace
        cancelTimer = scheduler.schedule(Self.graceMs) { [weak self] in self?.onGraceElapsed() }
      case .starting:
        if foregroundCount > 0 {
          phase = .done
          if !disabled { readyToCheck() }
        }
      default:
        break
      }
    }
  }

  /// Called from the chained fatal handler: records only, the crash still happens.
  func onFatal() {
    locked {
      guard phase == .attempting || phase == .grace else { return }
      cancelTimer?()
      record { state, queued, now in OTARollback.failed(state, reason: OTARollback.crash, events: &queued, now: now) }
      crashMarker?.disarm()
      phase = .done
    }
  }

  /// The bundle URL the React Native host actually loaded, when the TurboModule learns it.
  func onHostLoadedBundle(_ url: URL) {
    locked {
      loadedBundle = url
      if contentAppeared && !disabled && checkOverridden() { endAttemptWithoutVerdict() }
    }
  }

  private func onWatchdog() {
    locked {
      guard phase == .attempting else { return }
      otaLog.warning("Live updates: no content \(Self.watchdogMs / 1000) s after the app became active, counting a failed launch")
      record { state, queued, now in OTARollback.failed(state, reason: OTARollback.watchdog, events: &queued, now: now) }
      crashMarker?.disarm()
      phase = .done
    }
  }

  private func onGraceElapsed() {
    locked {
      guard phase == .grace, !disabled, let pending = decision.selected else { return }
      let now = clock()
      let state = persist { state in
        var next = state
        next.attempt = nil
        guard state.pending?.releaseId == pending.releaseId else { return next }
        next.stable = state.pending
        next.pending = nil
        next.failedCount = 0
        next.interruptedCount = 0
        next.lastFailureReason = nil
        return next
      }
      if let state {
        store.pruneReleases(keep: Set([state.stable?.releaseId, state.pending?.releaseId].compactMap { $0 }))
      }
      crashMarker?.disarm()
      events.add(.create(OTAEvent.applied, releaseId: pending.releaseId, now: now))
      otaLog.info("Live updates: release \(pending.releaseId, privacy: .public) applied")
      phase = .done
      readyToCheck()
    }
  }

  private func endAttemptWithoutVerdict() {
    guard phase == .attempting || phase == .grace else { return }
    cancelTimer?()
    persist { state in
      var next = state
      next.attempt = nil
      return next
    }
    crashMarker?.disarm()
    phase = .done
  }

  private func checkIntegration() {
    guard requested else {
      otaLog.error("Live updates: the app never asked for its bundle. Return NottiOTA.bundleURL() from bundleURL() in Release, or install react-native-notti-ota-expo in an Expo app.")
      reportOnce(OTAEvent.integrationMissing)
      disabled = true
      return
    }
    _ = checkOverridden()
  }

  /// True when the host loaded another bundle than the selected release: Live updates turn off.
  private func checkOverridden() -> Bool {
    guard let selected = decision.selected, let loaded = loadedBundle else { return false }
    guard loaded.standardizedFileURL.path != store.bundleFile(selected).standardizedFileURL.path else { return false }
    otaLog.error("Live updates: another bundle was loaded instead of the selected one; Live updates are off for this session.")
    reportOnce(OTAEvent.bundleOverridden, releaseId: selected.releaseId)
    disabled = true
    return true
  }

  private func reportOnce(_ type: String, releaseId: String? = nil) {
    var first = false
    persist { state in
      first = !state.reported.contains(type)
      var next = state
      next.reported.insert(type)
      return next
    }
    if first { events.add(.create(type, releaseId: releaseId, now: clock())) }
  }

  private func record(_ change: (OTAState, inout [OTAEvent], Int64) -> OTAState) {
    var queued: [OTAEvent] = []
    let now = clock()
    persist { change($0, &queued, now) }
    queued.forEach(events.add)
  }

  @discardableResult
  private func persist(_ change: (OTAState) -> OTAState) -> OTAState? {
    do {
      return try store.update(change)
    } catch {
      otaLog.error("Live updates: could not save the launch state (\(String(describing: type(of: error)), privacy: .public))")
      return nil
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

/// Foreground and first-content signals. App-level and scene activation are both observed and
/// de-duplicated; a process launched in the background posts neither until the user opens it.
final class OTALifecycleObserver {
  static let contentDidAppear = Notification.Name("RCTContentDidAppearNotification")

  private let monitor: OTALaunchMonitor
  private var tokens: [NSObjectProtocol] = []
  private var active = false
  private let lock = NSLock()

  init(monitor: OTALaunchMonitor, center: NotificationCenter = .default) {
    self.monitor = monitor
    for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
      tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.becameActive() })
    }
    tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
      self?.enteredBackground()
    })
    tokens.append(center.addObserver(forName: Self.contentDidAppear, object: nil, queue: nil) { [weak monitor] _ in
      monitor?.onContentAppeared()
    })
  }

  private func becameActive() {
    lock.lock()
    let first = !active
    active = true
    lock.unlock()
    if first { monitor.onForeground() }
  }

  private func enteredBackground() {
    lock.lock()
    let wasActive = active
    active = false
    lock.unlock()
    if wasActive { monitor.onBackground() }
  }
}

/// Chains React Native's fatal handler: records the failed launch, then hands the error to the
/// previous handler, or to React Native's default when there was none, so the crash still happens.
enum OTAFatalHandler {
  static func install(_ monitor: OTALaunchMonitor) {
    let previous = RCTGetFatalHandler()
    var chained: RCTFatalHandler?
    chained = { error in
      monitor.onFatal()
      if let previous {
        previous(error)
      } else {
        RCTSetFatalHandler(nil)
        RCTFatal(error)
        RCTSetFatalHandler(chained)
      }
    }
    RCTSetFatalHandler(chained)
  }
}

/// Process-wide entry point. The host returns `NottiOTA.bundleURL()` from `bundleURL()` in Release;
/// the Expo adapter does it for you.
@objc(NottiOTA)
public final class NottiOTA: NSObject {
  final class Session {
    let config: OTAConfig
    let store: OTAStateStore
    let events: OTAEventQueue
    let decision: BootDecision
    let monitor: OTALaunchMonitor
    let selectedURL: URL?
    var hooks: OTALifecycleObserver?

    init(config: OTAConfig, store: OTAStateStore, events: OTAEventQueue, decision: BootDecision, monitor: OTALaunchMonitor) {
      self.config = config
      self.store = store
      self.events = events
      self.decision = decision
      self.monitor = monitor
      selectedURL = decision.selected.map(store.bundleFile)
    }
  }

  private static let lock = NSRecursiveLock()
  private static var prepared = false
  private static var current: Session?
  private static var updateReadyHandler: ((String, Bool) -> Void)?

  static var session: Session? {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  /// The bundle React Native should load: a downloaded Live update, or nil for the embedded bundle.
  /// Synchronous, no network, never throws. Always nil in Debug builds, which load from Metro.
  @objc public static func bundleURL() -> URL? {
#if DEBUG
    return nil
#else
    return selectBundle()
#endif
  }

  static func selectBundle() -> URL? {
    guard let session = prepare() else { return nil }
    session.monitor.bundleRequested = true
    return session.selectedURL
  }

  /// Installs the launch hooks at app launch, before any scene becomes active. Called from the
  /// TurboModule's `+load`; does nothing in Debug builds or without configuration.
  @objc public static func startAtLaunch() {
#if !DEBUG
    var token: NSObjectProtocol?
    token = NotificationCenter.default.addObserver(
      forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: nil
    ) { _ in
      if let token { NotificationCenter.default.removeObserver(token) }
      installHooks()
    }
#endif
  }

  static func installHooks(center: NotificationCenter = .default) {
    lock.lock()
    defer { lock.unlock() }
    guard let session = prepare(), session.hooks == nil else { return }
    OTAFatalHandler.install(session.monitor)
    session.hooks = OTALifecycleObserver(monitor: session.monitor, center: center)
  }

  /// Reported by the TurboModule from its bundle manager: what the host really loaded.
  @objc public static func hostLoadedBundle(_ url: URL?) {
    guard let url else { return }
    session?.monitor.onHostLoadedBundle(url)
  }

  /// The Live update this session runs: selected, asked for by the host and not overridden.
  @objc public static func currentReleaseId() -> String? {
    guard let session, session.monitor.bundleRequested, !session.monitor.disabled else { return nil }
    return session.decision.selected?.releaseId
  }

  /// Set by the TurboModule while JS can receive `otaUpdateReady`.
  @objc public static func setUpdateReadyHandler(_ handler: ((String, Bool) -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    updateReadyHandler = handler
  }

  static func releaseReady(_ pointer: ReleasePointer) {
    lock.lock()
    let handler = updateReadyHandler
    lock.unlock()
    handler?(pointer.releaseId, pointer.mandatory)
  }

  @discardableResult
  static func prepare(
    config readConfig: () -> OTAConfig? = { OTAConfig.read() },
    root: () throws -> URL = OTAStateStore.defaultRoot,
    identity: () -> String = { BinaryIdentity.current() },
    scheduler: OTAScheduler = MainQueueScheduler()
  ) -> Session? {
    lock.lock()
    defer { lock.unlock() }
    if prepared { return current }
    prepared = true
    guard let config = readConfig() else { return nil }
    do {
      let store = OTAStateStore(root: try root())
      let events = OTAEventQueue(file: store.root.appendingPathComponent("events.json"))
      let opened = try store.open(binaryIdentity: identity())
      let decision = OTABoot.decide(opened, store: store, now: currentMillis())
      if decision.state != opened { try store.save(decision.state) }
      decision.events.forEach(events.add)
      let updater = OTAUpdater(
        config: config, store: store, events: events, api: OTAApiClient(config: config),
        embeddedHermesVersion: OTAUpdater.embeddedHermesVersion(), onPending: releaseReady
      )
      let monitor = OTALaunchMonitor(
        store: store, events: events, decision: decision, scheduler: scheduler,
        crashMarker: OTACrashMarker(store: store), readyToCheck: updater.onReady
      )
      current = Session(config: config, store: store, events: events, decision: decision, monitor: monitor)
      return current
    } catch {
      otaLog.error("Live updates: could not select a bundle, using the embedded one (\(String(describing: type(of: error)), privacy: .public))")
      return nil
    }
  }

  static func resetForTests() {
    lock.lock()
    defer { lock.unlock() }
    prepared = false
    current = nil
    updateReadyHandler = nil
  }
}
