import Foundation
@testable import NottiOta
import React
import UIKit
import XCTest

final class FakeScheduler: OTAScheduler {
  var now: Int64 = 0
  private var tasks: [(due: Int64, id: Int, task: () -> Void)] = []
  private var nextId = 0

  func schedule(_ delayMs: Int64, _ task: @escaping () -> Void) -> () -> Void {
    let id = nextId
    nextId += 1
    tasks.append((now + delayMs, id, task))
    return { [weak self] in self?.tasks.removeAll { $0.id == id } }
  }

  func advance(_ ms: Int64) {
    now += ms
    while let due = tasks.filter({ $0.due <= now }).min(by: { $0.due < $1.due }) {
      tasks.removeAll { $0.id == due.id }
      due.task()
    }
  }
}

final class OTALaunchMonitorTests: TempDirTestCase {
  private let releaseA = "7d4f8a2e-1b3c-4e5f-9a6b-0c1d2e3f4a5b"
  private let releaseB = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
  private let bundle = "main.jsbundle"

  private var store: OTAStateStore!
  private var events: OTAEventQueue!
  private let scheduler = FakeScheduler()
  private var checks = 0

  override func setUpWithError() throws {
    try super.setUpWithError()
    store = OTAStateStore(root: newFolder("ota"))
    events = OTAEventQueue(file: store.root.appendingPathComponent("events.json"))
  }

  override func tearDown() {
    RCTSetFatalHandler(nil)
    super.tearDown()
  }

  private func installRelease(_ id: String) {
    write("bundle \(id)", to: store.bundleFile(ReleasePointer(releaseId: id, bundle: bundle)))
  }

  @discardableResult
  private func stateWith(stable: String? = nil, pending: String? = nil, _ change: (inout OTAState) -> Void = { _ in }) throws -> OTAState {
    var state = try store.open(binaryIdentity: "id")
    stable.map(installRelease)
    pending.map(installRelease)
    state.stable = stable.map { ReleasePointer(releaseId: $0, bundle: bundle) }
    state.pending = pending.map { ReleasePointer(releaseId: $0, bundle: bundle) }
    change(&state)
    try store.save(state)
    return state
  }

  private func load() -> OTAState { try! store.load()! }

  private func boot() -> BootDecision {
    let decision = OTABoot.decide(load(), store: store, now: 1_000)
    try! store.save(decision.state)
    decision.events.forEach(events.add)
    return decision
  }

  private func monitor(_ decision: BootDecision, requested: Bool = true) -> OTALaunchMonitor {
    let monitor = OTALaunchMonitor(
      store: store, events: events, decision: decision, scheduler: scheduler,
      clock: { [scheduler] in scheduler.now }, readyToCheck: { [weak self] in self?.checks += 1 }
    )
    monitor.bundleRequested = requested
    return monitor
  }

  private func eventTypes() -> [String] { events.read().map { "\($0.type):\($0.reason ?? "")" } }

  func testAPendingReleaseIsSelectedAtBoot() throws {
    try stateWith(stable: releaseA, pending: releaseB)
    let decision = boot()
    XCTAssertEqual(decision.selected?.releaseId, releaseB)
    XCTAssertTrue(decision.selectedIsPending)
  }

  func testRevertToEmbeddedDropsEveryReleaseAtTheNextBoot() throws {
    try stateWith(stable: releaseA) { $0.revertToEmbedded = true }

    let decision = boot()

    XCTAssertNil(decision.selected)
    XCTAssertFalse(decision.state.revertToEmbedded)
    XCTAssertFalse(exists(store.releaseDir(releaseA)))
    XCTAssertEqual(eventTypes(), ["reverted_to_embedded:server"])
  }

  func testALeftoverMarkerCountsOneFailedLaunch() throws {
    try stateWith(pending: releaseB) { $0.attempt = LaunchAttempt(releaseId: self.releaseB, startedAt: 500) }

    let decision = boot()

    XCTAssertEqual(decision.state.failedCount, 1)
    XCTAssertEqual(decision.state.lastFailureReason, "crash")
    XCTAssertNil(decision.state.attempt)
    XCTAssertEqual(decision.selected?.releaseId, releaseB)
  }

  func testASecondFailureRollsBackToStableAndBlocklists() throws {
    try stateWith(stable: releaseA, pending: releaseB) {
      $0.attempt = LaunchAttempt(releaseId: self.releaseB, startedAt: 500)
      $0.failedCount = 1
    }

    let decision = boot()

    XCTAssertEqual(decision.selected?.releaseId, releaseA)
    XCTAssertNil(decision.state.pending)
    XCTAssertEqual(decision.state.blocklist, [releaseB])
    XCTAssertFalse(exists(store.releaseDir(releaseB)))
    XCTAssertEqual(eventTypes(), ["rolled_back:crash"])
  }

  func testARollbackWithoutStableBootsEmbedded() throws {
    try stateWith(pending: releaseB) {
      $0.attempt = LaunchAttempt(releaseId: self.releaseB, startedAt: 500)
      $0.failedCount = 1
    }
    XCTAssertNil(boot().selected)
  }

  func testAMarkerForAnotherReleaseIsDropped() throws {
    try stateWith(pending: releaseB) { $0.attempt = LaunchAttempt(releaseId: self.releaseA, startedAt: 500) }
    let decision = boot()
    XCTAssertNil(decision.state.attempt)
    XCTAssertEqual(decision.state.failedCount, 0)
  }

  func testThreeInterruptedLaunchesCountAsOneFailure() throws {
    try stateWith(pending: releaseB)
    for _ in 0..<2 {
      let session = monitor(boot())
      session.onForeground()
      session.onBackground()
      XCTAssertEqual(load().failedCount, 0)
    }
    let third = monitor(boot())
    third.onForeground()
    third.onBackground()
    XCTAssertEqual(load().failedCount, 1)
    XCTAssertEqual(load().interruptedCount, 0)
    XCTAssertEqual(load().lastFailureReason, "interrupted")
  }

  func testInterruptionsAfterAFailureRollBackWithReasonInterrupted() throws {
    try stateWith(pending: releaseB) {
      $0.failedCount = 1
      $0.interruptedCount = 2
    }
    let session = monitor(boot())
    session.onForeground()
    session.onBackground()
    XCTAssertEqual(eventTypes(), ["rolled_back:interrupted"])
    XCTAssertEqual(load().blocklist, [releaseB])
  }

  func testAMissingPendingBundleIsDropped() throws {
    try stateWith(stable: releaseA, pending: releaseB)
    try FileManager.default.removeItem(at: store.releaseDir(releaseB))
    XCTAssertEqual(boot().selected?.releaseId, releaseA)
  }

  func testAForegroundLaunchThatShowsContentFor3SecondsIsApplied() throws {
    try stateWith(stable: releaseA, pending: releaseB)
    let session = monitor(boot())

    session.onForeground()
    XCTAssertEqual(load().attempt?.releaseId, releaseB)
    session.onContentAppeared()
    scheduler.advance(2_999)
    XCTAssertNotNil(load().pending)
    scheduler.advance(1)

    let state = load()
    XCTAssertEqual(state.stable?.releaseId, releaseB)
    XCTAssertNil(state.pending)
    XCTAssertNil(state.attempt)
    XCTAssertFalse(exists(store.releaseDir(releaseA)))
    XCTAssertEqual(eventTypes(), ["applied:"])
    XCTAssertEqual(checks, 1)
  }

  func testNoContentWithin10SecondsIsAWatchdogFailure() throws {
    try stateWith(pending: releaseB)
    let first = monitor(boot())
    first.onForeground()
    scheduler.advance(10_000)
    XCTAssertEqual(load().failedCount, 1)
    XCTAssertEqual(load().lastFailureReason, "watchdog")
    XCTAssertNil(load().attempt)

    first.onContentAppeared()
    scheduler.advance(5_000)
    XCTAssertNotNil(load().pending)

    let second = monitor(boot())
    second.onForeground()
    scheduler.advance(10_000)
    XCTAssertNil(load().pending)
    XCTAssertEqual(eventTypes(), ["rolled_back:watchdog"])
  }

  func testACrashBeforeContentOrDuringTheGraceIsAFailure() throws {
    try stateWith(pending: releaseB)
    let first = monitor(boot())
    first.onForeground()
    first.onFatal()
    XCTAssertEqual(load().failedCount, 1)

    let second = monitor(boot())
    second.onForeground()
    second.onContentAppeared()
    scheduler.advance(1_000)
    second.onFatal()
    XCTAssertNil(load().pending)
    XCTAssertEqual(eventTypes(), ["rolled_back:crash"])
  }

  func testACrashAfterSuccessDoesNotRevert() throws {
    try stateWith(pending: releaseB)
    let session = monitor(boot())
    session.onForeground()
    session.onContentAppeared()
    scheduler.advance(3_000)
    session.onFatal()
    XCTAssertEqual(load().stable?.releaseId, releaseB)
    XCTAssertEqual(load().failedCount, 0)
  }

  func testABackgroundLaunchNeverChangesTheState() throws {
    let before = try stateWith(pending: releaseB)
    let center = NotificationCenter()
    let session = monitor(boot())
    let observer = OTALifecycleObserver(monitor: session, center: center)
    center.post(name: OTALifecycleObserver.contentDidAppear, object: nil)
    session.onFatal()
    scheduler.advance(60_000)
    XCTAssertEqual(load(), before)
    XCTAssertTrue(events.read().isEmpty)
    XCTAssertEqual(session.phase, .starting)
    withExtendedLifetime(observer) {}
  }

  func testLeavingBeforeContentIsAnInterruptedLaunch() throws {
    try stateWith(pending: releaseB)
    let session = monitor(boot())
    session.onForeground()
    session.onBackground()
    scheduler.advance(20_000)
    let state = load()
    XCTAssertEqual(state.interruptedCount, 1)
    XCTAssertEqual(state.failedCount, 0)
    XCTAssertNil(state.attempt)
  }

  func testAppAndSceneActivationCountOneAttempt() throws {
    try stateWith(pending: releaseB)
    let center = NotificationCenter()
    let session = monitor(boot())
    let observer = OTALifecycleObserver(monitor: session, center: center)

    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    center.post(name: UIScene.didActivateNotification, object: nil)
    XCTAssertEqual(session.phase, .attempting)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertEqual(session.phase, .done)
    XCTAssertEqual(load().interruptedCount, 1)

    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(load().interruptedCount, 1)
    withExtendedLifetime(observer) {}
  }

  func testTheContentNotificationIsReactNativesOwn() {
    XCTAssertEqual(OTALifecycleObserver.contentDidAppear, NSNotification.Name.RCTContentDidAppear)
  }

  func testAStableLaunchChecksAfterFirstContent() throws {
    try stateWith(stable: releaseA)
    let session = monitor(boot())
    session.onForeground()
    session.onContentAppeared()
    XCTAssertEqual(checks, 1)
    XCTAssertNil(load().attempt)
    session.onBackground()
    session.onForeground()
    XCTAssertEqual(checks, 2)
  }

  func testAMissingBundleHookIsReportedOncePerBinary() throws {
    try stateWith(pending: releaseB)
    for _ in 0..<2 {
      let session = monitor(boot(), requested: false)
      session.onForeground()
      session.onContentAppeared()
      scheduler.advance(10_000)
      XCTAssertTrue(session.disabled)
    }
    XCTAssertEqual(eventTypes(), ["integration_missing:"])
    XCTAssertEqual(checks, 0)
    XCTAssertEqual(load().failedCount, 0)
    XCTAssertNotNil(load().pending)
  }

  func testAnOverriddenBundleTurnsLiveUpdatesOffForTheSession() throws {
    try stateWith(pending: releaseB)
    let session = monitor(boot())
    session.onHostLoadedBundle(Bundle.main.bundleURL.appendingPathComponent("main.jsbundle"))
    session.onForeground()
    session.onContentAppeared()
    scheduler.advance(10_000)

    XCTAssertTrue(session.disabled)
    XCTAssertEqual(eventTypes(), ["bundle_overridden:"])
    XCTAssertNil(load().attempt)
    XCTAssertEqual(load().failedCount, 0)
    XCTAssertNotNil(load().pending)
    XCTAssertEqual(checks, 0)
  }

  func testAnOverrideLearnedDuringTheGraceStopsThePromotion() throws {
    try stateWith(pending: releaseB)
    let session = monitor(boot())
    session.onForeground()
    session.onContentAppeared()
    session.onHostLoadedBundle(URL(fileURLWithPath: "/elsewhere/main.jsbundle"))
    scheduler.advance(10_000)

    XCTAssertEqual(load().pending?.releaseId, releaseB)
    XCTAssertNil(load().stable)
    XCTAssertNil(load().attempt)
    XCTAssertEqual(eventTypes(), ["bundle_overridden:"])
  }

  func testTheSelectedBundleLoadedIsNotAnOverride() throws {
    try stateWith(pending: releaseB)
    let session = monitor(boot())
    session.onHostLoadedBundle(store.bundleFile(ReleasePointer(releaseId: releaseB, bundle: bundle)))
    session.onForeground()
    session.onContentAppeared()
    scheduler.advance(3_000)
    XCTAssertFalse(session.disabled)
    XCTAssertEqual(load().stable?.releaseId, releaseB)
  }

  func testTheFatalHandlerChainsThePreviousOne() throws {
    try stateWith(pending: releaseB)
    let session = monitor(boot())
    session.onForeground()
    var previousError: Error?
    RCTSetFatalHandler { previousError = $0 }

    OTAFatalHandler.install(session)
    RCTFatal(NSError(domain: "test", code: 7))

    XCTAssertEqual((previousError as NSError?)?.code, 7)
    XCTAssertEqual(load().failedCount, 1)
  }

  func testWithoutAPreviousHandlerReactNativesDefaultStillRuns() throws {
    try stateWith(pending: releaseB)
    let session = monitor(boot())
    session.onForeground()
    RCTSetFatalHandler(nil)

    OTAFatalHandler.install(session)
    RCTFatal(NSError(domain: "test", code: 8))

    XCTAssertEqual(load().failedCount, 1)
    XCTAssertNotNil(RCTGetFatalHandler(), "the chained handler stays installed")
  }
}

final class NottiOTAEntryTests: TempDirTestCase {
  private let releaseId = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
  private var root: URL { tmp.appendingPathComponent("NottiOTA", isDirectory: true) }

  private let config = OTAConfig(
    appId: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", baseUrl: "https://push.example.com", clientKey: "ck",
    channel: "production", runtimeVersion: "1.4.0", publicKeys: [Fixtures.keyId: Fixtures.publicKeySec1]
  )

  override func setUp() {
    super.setUp()
    NottiOTA.resetForTests()
  }

  override func tearDown() {
    NottiOTA.resetForTests()
    RCTSetFatalHandler(nil)
    super.tearDown()
  }

  @discardableResult
  private func prepare(config: OTAConfig? = nil, scheduler: OTAScheduler = FakeScheduler()) -> NottiOTA.Session? {
    let config = config ?? self.config
    return NottiOTA.prepare(config: { config }, root: { self.root }, identity: { "1|1.0|uuid" }, scheduler: scheduler)
  }

  func testWithoutConfigurationTheEmbeddedBundleIsUsedAndNothingIsWritten() {
    XCTAssertNil(NottiOTA.prepare(config: { nil }, root: { self.root }, identity: { "id" }))
    XCTAssertNil(NottiOTA.selectBundle())
    XCTAssertFalse(exists(root))
  }

  func testAPendingReleaseIsReturnedAsAFileURL() throws {
    let store = OTAStateStore(root: root)
    var state = try store.open(binaryIdentity: "1|1.0|uuid")
    state.pending = ReleasePointer(releaseId: releaseId, bundle: "main.jsbundle")
    try store.save(state)
    write("x", to: store.bundleFile(state.pending!))

    prepare()
    let url = NottiOTA.selectBundle()

    XCTAssertEqual(url, store.bundleFile(state.pending!))
    XCTAssertTrue(NottiOTA.session!.monitor.bundleRequested)
  }

  func testACorruptStateNeverThrowsAndBootsEmbedded() throws {
    write("garbage", to: root.appendingPathComponent("state.json"))
    prepare()
    XCTAssertNil(NottiOTA.selectBundle())
  }

  func testAnUnreadableStateBootsEmbeddedAndKeepsTheReleases() throws {
    let kept = root.appendingPathComponent("releases/\(releaseId)/main.jsbundle")
    write("x", to: kept)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("state.json"), withIntermediateDirectories: true)

    XCTAssertNil(prepare())
    XCTAssertNil(NottiOTA.selectBundle())
    XCTAssertTrue(exists(kept))
  }

  func testTheCurrentReleaseIsTheSelectedOneOnceTheHostAskedForIt() throws {
    let store = OTAStateStore(root: root)
    var state = try store.open(binaryIdentity: "1|1.0|uuid")
    state.stable = ReleasePointer(releaseId: releaseId, bundle: "main.jsbundle")
    try store.save(state)
    write("x", to: store.bundleFile(state.stable!))

    prepare()
    XCTAssertNil(NottiOTA.currentReleaseId())
    _ = NottiOTA.selectBundle()
    XCTAssertEqual(NottiOTA.currentReleaseId(), releaseId)
    NottiOTA.session!.monitor.onHostLoadedBundle(URL(fileURLWithPath: "/elsewhere/main.jsbundle"))
    NottiOTA.session!.monitor.onContentAppeared()
    XCTAssertNil(NottiOTA.currentReleaseId(), "an overridden session does not run the release")
  }

  func testAReadyReleaseReachesTheHandler() {
    var received: [(String, Bool)] = []
    let pointer = ReleasePointer(releaseId: releaseId, bundle: "main.jsbundle", mandatory: true)
    NottiOTA.releaseReady(pointer)
    NottiOTA.setUpdateReadyHandler { received.append(($0, $1)) }
    NottiOTA.releaseReady(pointer)
    XCTAssertEqual(received.map(\.0), [releaseId])
    XCTAssertEqual(received.map(\.1), [true])
  }

  func testTheBundleURLIsNilInDebugBuilds() {
    prepare()
    XCTAssertNil(NottiOTA.bundleURL())
  }

  func testTheHooksCountAnAttemptOnActivation() throws {
    let store = OTAStateStore(root: root)
    var state = try store.open(binaryIdentity: "1|1.0|uuid")
    state.pending = ReleasePointer(releaseId: releaseId, bundle: "main.jsbundle")
    try store.save(state)
    write("x", to: store.bundleFile(state.pending!))
    let center = NotificationCenter()

    prepare()
    _ = NottiOTA.selectBundle()
    NottiOTA.installHooks(center: center)
    NottiOTA.installHooks(center: center)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

    XCTAssertEqual(try store.load()?.attempt?.releaseId, releaseId)
    XCTAssertNotNil(RCTGetFatalHandler())
  }

  func testSelectingTheBundleTakesUnder5Milliseconds() {
    prepare()
    let samples = (0..<50).map { _ -> Double in
      let start = DispatchTime.now().uptimeNanoseconds
      _ = NottiOTA.selectBundle()
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }.sorted()
    XCTAssertLessThan(samples[samples.count / 2], 5, "median \(samples[samples.count / 2]) ms")
  }

  func testTheColdBootDecisionTakesUnder5Milliseconds() {
    let samples = (0..<30).map { _ -> Double in
      NottiOTA.resetForTests()
      let start = DispatchTime.now().uptimeNanoseconds
      prepare()
      _ = NottiOTA.selectBundle()
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }.dropFirst(10).sorted()
    XCTAssertLessThan(samples[samples.count / 2], 5, "median \(samples[samples.count / 2]) ms")
  }
}
