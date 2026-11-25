import Foundation
@testable import NottiOta
import XCTest

final class OTAStateTests: TempDirTestCase {
  private let appId = "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
  private let releaseA = "7d4f8a2e-1b3c-4e5f-9a6b-0c1d2e3f4a5b"
  private let releaseB = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
  private let bundle = "main.jsbundle"

  private func info(except: [String] = [], overrides: [String: Any] = [:]) -> [String: Any] {
    var values: [String: Any] = [
      OTAConfig.keyAppId: appId,
      OTAConfig.keyBaseUrl: "https://push.example.com/",
      OTAConfig.keyClientKey: "ck_test",
      OTAConfig.keyChannel: "production",
      OTAConfig.keyRuntimeVersion: "1.4.0",
      OTAConfig.keyPublicKeys: "\(Fixtures.keyId):\(Fixtures.publicKeyBase64)",
    ]
    values.merge(overrides) { _, new in new }
    except.forEach { values.removeValue(forKey: $0) }
    return values
  }

  func testConfigReadsEveryKey() throws {
    let config = try XCTUnwrap(OTAConfig.fromInfoDictionary(info()))
    XCTAssertEqual(config.appId, appId)
    XCTAssertEqual(config.baseUrl, "https://push.example.com")
    XCTAssertEqual(config.channel, "production")
    XCTAssertEqual(config.runtimeVersion, "1.4.0")
    XCTAssertEqual(config.publicKeys[Fixtures.keyId], Fixtures.publicKeySec1)
  }

  func testConfigIsOffWithoutAnyKey() {
    XCTAssertNil(OTAConfig.fromInfoDictionary(nil))
    XCTAssertNil(OTAConfig.fromInfoDictionary([:]))
    XCTAssertNil(OTAConfig.fromInfoDictionary(["CFBundleVersion": "1"]))
  }

  func testConfigIsOffWhenAnyKeyIsMissing() {
    for key in OTAConfig.allKeys {
      XCTAssertNil(OTAConfig.fromInfoDictionary(info(except: [key])), "missing \(key)")
    }
  }

  func testConfigIsOffWhenAValueIsInvalid() {
    let invalid: [String: Any] = [
      OTAConfig.keyAppId: "not-a-uuid",
      OTAConfig.keyBaseUrl: "push.example.com",
      OTAConfig.keyChannel: "Production",
      OTAConfig.keyRuntimeVersion: String(repeating: "x", count: 65),
      OTAConfig.keyPublicKeys: "0000000000000000:\(Fixtures.publicKeyBase64)",
    ]
    for (key, value) in invalid {
      XCTAssertNil(OTAConfig.fromInfoDictionary(info(overrides: [key: value])), "\(key)=\(value)")
    }
    let sixKeys = Array(repeating: "\(Fixtures.keyId):\(Fixtures.publicKeyBase64)", count: 6).joined(separator: ",")
    XCTAssertNil(OTAConfig.fromInfoDictionary(info(overrides: [OTAConfig.keyPublicKeys: sixKeys])))
    XCTAssertNil(OTAConfig.fromInfoDictionary(info(overrides: [OTAConfig.keyPublicKeys: "\(Fixtures.keyId):AAAA"])))
    XCTAssertNil(OTAConfig.fromInfoDictionary(info(overrides: [OTAConfig.keyBaseUrl: "https://push.example.com/?a=1"])))
  }

  func testConfigRejectsARealOrBooleanRuntimeVersionButAcceptsAnInteger() throws {
    XCTAssertNil(OTAConfig.fromInfoDictionary(info(overrides: [OTAConfig.keyRuntimeVersion: NSNumber(value: 1.10)])))
    XCTAssertNil(OTAConfig.fromInfoDictionary(info(overrides: [OTAConfig.keyRuntimeVersion: NSNumber(value: true)])))
    let config = try XCTUnwrap(OTAConfig.fromInfoDictionary(info(overrides: [OTAConfig.keyRuntimeVersion: NSNumber(value: 7)])))
    XCTAssertEqual(config.runtimeVersion, "7")
  }

  func testConfigIsReadFromTheInfoPlist() throws {
    let bundleDir = newFolder("Host.bundle")
    let plist = try PropertyListSerialization.data(fromPropertyList: info(), format: .xml, options: 0)
    try plist.write(to: bundleDir.appendingPathComponent("Info.plist"))
    let host = try XCTUnwrap(Bundle(url: bundleDir))
    XCTAssertNotNil(OTAConfig.read(bundle: host))
    XCTAssertNil(OTAConfig.read(bundle: Bundle(for: Self.self)))
  }

  func testStateRoundTrips() throws {
    let store = OTAStateStore(root: newFolder("ota"))
    var state = OTAState.fresh()
    state.binaryIdentity = "1|1.0|uuid"
    state.stable = ReleasePointer(releaseId: releaseA, bundle: bundle)
    state.pending = ReleasePointer(releaseId: releaseB, bundle: bundle, mandatory: true)
    state.attempt = LaunchAttempt(releaseId: releaseB, startedAt: 1234)
    state.failedCount = 1
    state.interruptedCount = 2
    state.lastFailureReason = "watchdog"
    state.blocklist = [releaseA]
    state.revertToEmbedded = true
    state.lastCheckAt = 99
    state.reported = ["integration_missing"]
    try store.save(state)
    XCTAssertEqual(try OTAStateStore(root: store.root).load(), state)
  }

  func testTheStateFileIsTheSameDocumentAsAndroid() throws {
    let android = """
      {"version":1,"installation_id":"0f8fad5b-d9cb-469f-a165-70867728950e","binary_identity":"42|1.4.0|1000",\
      "stable":{"release_id":"\(releaseA)","bundle":"index.android.bundle","mandatory":false},"pending":null,\
      "attempt":{"release_id":"\(releaseA)","started_at":1732536000000},"failed_count":1,"interrupted_count":0,\
      "last_failure_reason":"crash","blocklist":["\(releaseB)"],"revert_to_embedded":false,"last_check_at":5,\
      "reported":["bundle_overridden"]}
      """
    let state = try OTAState.from(jsonData: Data(android.utf8))
    XCTAssertEqual(state.installationId, "0f8fad5b-d9cb-469f-a165-70867728950e")
    XCTAssertEqual(state.stable, ReleasePointer(releaseId: releaseA, bundle: "index.android.bundle"))
    XCTAssertEqual(state.attempt, LaunchAttempt(releaseId: releaseA, startedAt: 1_732_536_000_000))
    XCTAssertEqual(state.lastFailureReason, "crash")
    XCTAssertEqual(state.blocklist, [releaseB])
    XCTAssertEqual(state.reported, ["bundle_overridden"])

    let written = try XCTUnwrap(JSONSerialization.jsonObject(with: state.jsonData()) as? [String: Any])
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(android.utf8)) as? [String: Any])
    XCTAssertEqual(Set(written.keys), Set(original.keys))
    XCTAssertTrue(written["pending"] is NSNull)
  }

  func testACorruptFileGivesAFreshStateAndWipesReleases() throws {
    let store = OTAStateStore(root: newFolder("ota"))
    write("x", to: store.releaseDir(releaseA).appendingPathComponent(bundle))
    write("{not json", to: store.stateFile)

    let state = try store.open(binaryIdentity: "1|1.0|uuid")

    XCTAssertNil(state.stable)
    XCTAssertEqual(state.binaryIdentity, "1|1.0|uuid")
    XCTAssertFalse(exists(store.releasesDir))
    XCTAssertEqual(try store.load(), state)
  }

  func testAStateWithAnUnsafeBundlePathIsCorrupt() throws {
    let store = OTAStateStore(root: newFolder("ota"))
    var state = OTAState.fresh()
    state.binaryIdentity = "id"
    state.stable = ReleasePointer(releaseId: releaseA, bundle: bundle)
    try store.save(state)
    let text = try String(contentsOf: store.stateFile, encoding: .utf8).replacingOccurrences(of: bundle, with: "../../evil")
    write(text, to: store.stateFile)
    XCTAssertNil(try store.load())
  }

  func testANonCanonicalReleaseIdIsCorrupt() throws {
    let store = OTAStateStore(root: newFolder("ota"))
    var state = OTAState.fresh()
    state.blocklist = [releaseA]
    try store.save(state)
    let text = try String(contentsOf: store.stateFile, encoding: .utf8).replacingOccurrences(of: releaseA, with: releaseA.uppercased())
    write(text, to: store.stateFile)
    XCTAssertNil(try store.load())
  }

  func testACrashBetweenWriteAndRenameKeepsThePreviousState() throws {
    let store = OTAStateStore(root: newFolder("ota"))
    var before = try store.open(binaryIdentity: "1|1.0|uuid")
    before.stable = ReleasePointer(releaseId: releaseA, bundle: bundle)
    try store.save(before)
    var torn = before
    torn.stable = nil
    torn.failedCount = 9
    try torn.jsonData().write(to: store.root.appendingPathComponent("state.json.tmp"))

    XCTAssertEqual(try OTAStateStore(root: store.root).open(binaryIdentity: "1|1.0|uuid"), before)
  }

  func testANewBinaryIdentityWipesReleasesAndKeepsTheInstallationId() throws {
    let store = OTAStateStore(root: newFolder("ota"))
    var first = try store.open(binaryIdentity: "1|1.0|uuid-a")
    first.stable = ReleasePointer(releaseId: releaseA, bundle: bundle)
    first.reported = ["bundle_overridden"]
    try store.save(first)
    write("x", to: store.releaseDir(releaseA).appendingPathComponent(bundle))
    write("x", to: store.tmpDir.appendingPathComponent("partial"))

    let after = try store.open(binaryIdentity: "2|1.1|uuid-b")

    XCTAssertEqual(after.installationId, first.installationId)
    XCTAssertNil(after.stable)
    XCTAssertTrue(after.reported.isEmpty)
    XCTAssertFalse(exists(store.releasesDir))
    XCTAssertFalse(exists(store.tmpDir))
  }

  func testTheSameBinaryIdentityKeepsTheState() throws {
    let store = OTAStateStore(root: newFolder("ota"))
    var state = try store.open(binaryIdentity: "1|1.0|uuid")
    state.stable = ReleasePointer(releaseId: releaseA, bundle: bundle)
    try store.save(state)
    XCTAssertEqual(try store.open(binaryIdentity: "1|1.0|uuid"), state)
  }

  func testTheInstallationIdIsALowercaseUUID() {
    let id = OTAState.fresh().installationId
    XCTAssertTrue(isCanonicalUUID(id), id)
  }

  func testTheStateDirectoryIsExcludedFromBackup() throws {
    let store = OTAStateStore(root: tmp.appendingPathComponent("NottiOTA", isDirectory: true))
    _ = try store.open(binaryIdentity: "id")
    let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testTheBlocklistKeepsTheNewestTwenty() {
    var state = OTAState.fresh()
    let ids = (0..<25).map { _ in UUID().uuidString.lowercased() }
    ids.forEach { state = state.blocking($0) }
    XCTAssertEqual(state.blocklist, Array(ids.suffix(20)))
  }

  func testBinaryIdentityChangesWithTheBuild() throws {
    func host(build: String) throws -> Bundle {
      let dir = newFolder("Host-\(build).bundle")
      let plist = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleVersion": build, "CFBundleShortVersionString": "1.4.0"], format: .xml, options: 0
      )
      try plist.write(to: dir.appendingPathComponent("Info.plist"))
      return try XCTUnwrap(Bundle(url: dir))
    }
    let uuid = try XCTUnwrap(BinaryIdentity.executableUUID())
    let first = BinaryIdentity.current(bundle: try host(build: "42"))
    XCTAssertEqual(first, "42|1.4.0|\(uuid)")
    XCTAssertEqual(first, BinaryIdentity.current(bundle: try host(build: "42")))
    XCTAssertNotEqual(first, BinaryIdentity.current(bundle: try host(build: "43")))
  }

  func testTheIdentityDigestHidesTheRawValues() {
    let digest = BinaryIdentity.digest("42|1.4.0|8C3E2D7A-0000-4000-8000-000000000000")
    XCTAssertEqual(digest.count, 32)
    XCTAssertTrue(isLowerHex(digest, count: 32))
    XCTAssertFalse(digest.contains("42|"))
  }
}
