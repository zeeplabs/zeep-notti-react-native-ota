import Darwin
import Foundation
@testable import NottiOta
import XCTest

private var previousSignal: Int32 = 0
private var previousSignalCalls = 0
private var previousException: String?

private func previousSignalAction(_ signo: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
  previousSignal = signo
  previousSignalCalls += 1
}

private func previousExceptionHandler(_ exception: NSException) {
  previousException = exception.name.rawValue
}

final class OTACrashMarkerTests: TempDirTestCase {
  private var store: OTAStateStore!
  private var savedAction = sigaction()
  private var savedExceptionHandler: (@convention(c) (NSException) -> Void)?

  override func setUpWithError() throws {
    try super.setUpWithError()
    store = OTAStateStore(root: newFolder("ota"))
    previousSignal = 0
    previousSignalCalls = 0
    previousException = nil
    sigaction(SIGFPE, nil, &savedAction)
    savedExceptionHandler = NSGetUncaughtExceptionHandler()
  }

  override func tearDown() {
    NottiOtaCrashMarkerUninstallForTests()
    sigaction(SIGFPE, &savedAction, nil)
    NSSetUncaughtExceptionHandler(savedExceptionHandler)
    super.tearDown()
  }

  private func installPreviousSignalAction() {
    var action = sigaction()
    action.__sigaction_u.__sa_sigaction = previousSignalAction
    action.sa_flags = SA_SIGINFO
    sigemptyset(&action.sa_mask)
    sigaction(SIGFPE, &action, nil)
  }

  func testASignalWhileArmedWritesTheMarkerAndChainsThePreviousHandler() {
    installPreviousSignalAction()
    let marker = OTACrashMarker(store: store)
    marker.arm()

    raise(SIGFPE)

    XCTAssertEqual(previousSignal, SIGFPE, "the previous handler still runs")
    XCTAssertTrue(store.crashMarked())
  }

  func testASignalWhileDisarmedWritesNothingAndStillChains() {
    installPreviousSignalAction()
    let marker = OTACrashMarker(store: store)
    marker.arm()
    marker.disarm()

    raise(SIGFPE)

    XCTAssertEqual(previousSignal, SIGFPE)
    XCTAssertFalse(store.crashMarked())
  }

  func testAnUncaughtExceptionWhileArmedWritesTheMarkerAndChainsThePreviousHandler() {
    NSSetUncaughtExceptionHandler(previousExceptionHandler)
    let marker = OTACrashMarker(store: store)
    marker.arm()

    NSGetUncaughtExceptionHandler()?(NSException(name: .internalInconsistencyException, reason: "test"))

    XCTAssertEqual(previousException, NSExceptionName.internalInconsistencyException.rawValue)
    XCTAssertTrue(store.crashMarked())
  }

  func testArmingTwiceKeepsOneHandlerInTheChain() {
    installPreviousSignalAction()
    let marker = OTACrashMarker(store: store)
    marker.arm()
    marker.arm()

    raise(SIGFPE)

    XCTAssertEqual(previousSignalCalls, 1)
    var current = sigaction()
    sigaction(SIGFPE, nil, &current)
    XCTAssertEqual(
      unsafeBitCast(current.__sigaction_u.__sa_sigaction, to: UnsafeRawPointer?.self),
      unsafeBitCast(previousSignalAction as @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void, to: UnsafeRawPointer?.self),
      "after a crash signal the SDK steps out of the chain"
    )
  }

  func testAnArmedAttemptThatEndsWithoutACrashIsNotMarked() {
    let marker = OTACrashMarker(store: store)
    marker.arm()
    XCTAssertFalse(store.crashMarked())
    marker.disarm()
    XCTAssertFalse(exists(store.crashMarkerFile))
  }
}
