import CryptoKit
import Foundation
@testable import NottiOta
import XCTest

/// Answers every request of a stubbed URLSession from `handler`, and records it with its body.
final class StubURLProtocol: URLProtocol {
  enum Reply {
    case response(status: Int, body: Data, headers: [String: String] = [:])
    case partial(Data, total: Int)
    case failure(URLError.Code)
  }

  static var handler: (URLRequest) -> Reply = { _ in .response(status: 404, body: Data()) }
  static var requests: [(request: URLRequest, body: Data)] = []
  private static let lock = NSLock()

  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    requests = []
  }

  static func count(_ suffix: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.filter { $0.request.url!.path.hasSuffix(suffix) }.count
  }

  static func first(_ suffix: String) -> (request: URLRequest, body: Data)? {
    lock.lock()
    defer { lock.unlock() }
    return requests.first { $0.request.url!.path.hasSuffix(suffix) }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        body.append(buffer, count: n)
      }
      stream.close()
    }
    Self.lock.lock()
    Self.requests.append((request, body))
    Self.lock.unlock()

    switch Self.handler(request) {
    case let .response(status, data, headers):
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case let .partial(data, total):
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(total)"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    case let .failure(code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    }
  }

  override func stopLoading() {}
}

final class OTAUpdaterTests: TempDirTestCase {
  private let otherRelease = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"
  private let signingKey = P256.Signing.PrivateKey()
  private var keyId: String { OTAKeys.keyId(signingKey.publicKey.x963Representation) }

  /// The CLI fixture manifest re-targeted at iOS and signed with a test key: same archive and files.
  private lazy var manifestBytes: Data = {
    let text = String(decoding: Fixtures.data("manifest.json"), as: UTF8.self)
    return Data(text.replacingOccurrences(of: "\"platform\":\"android\"", with: "\"platform\":\"ios\"").utf8)
  }()
  private lazy var manifest = try! OTAManifest.parse(manifestBytes)
  private var releaseId: String { manifest.releaseId }

  private var config: OTAConfig!
  private var store: OTAStateStore!
  private var events: OTAEventQueue!
  private var now: Int64 = 10_000_000
  private var freeSpace: Int64 = .max
  private var pendingNotices: [ReleasePointer] = []

  private var checkReply: () -> StubURLProtocol.Reply = { .response(status: 200, body: Data(#"{"update":null,"revert_to_embedded":false}"#.utf8)) }
  private var archiveReply: () -> StubURLProtocol.Reply = { .response(status: 200, body: Fixtures.data("archives/valid.tar.gz")) }
  private var eventsReply: () -> StubURLProtocol.Reply = { .response(status: 200, body: Data(#"{"accepted":1,"duplicates":0}"#.utf8)) }

  override func setUpWithError() throws {
    try super.setUpWithError()
    StubURLProtocol.reset()
    StubURLProtocol.handler = { [unowned self] request in
      let path = request.url!.path
      if path.hasSuffix("/ota/check") { return checkReply() }
      if path.hasSuffix("/ota/events") { return eventsReply() }
      if path.hasPrefix("/archive") { return archiveReply() }
      return .response(status: 404, body: Data())
    }
    config = makeConfig(runtimeVersion: "1.4.0")
    store = OTAStateStore(root: newFolder("ota"))
    events = OTAEventQueue(file: store.root.appendingPathComponent("events.json"))
    _ = try store.open(binaryIdentity: "42|1.4.0|uuid")
  }

  private func makeConfig(runtimeVersion: String) -> OTAConfig {
    OTAConfig(
      appId: manifest.appId, baseUrl: "https://notti.test", clientKey: "ck_live", channel: "production",
      runtimeVersion: runtimeVersion, publicKeys: [keyId: signingKey.publicKey.x963Representation]
    )
  }

  private func updater(timeout: TimeInterval = 15) -> OTAUpdater {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return OTAUpdater(
      config: config, store: store, events: events, api: OTAApiClient(config: config, configuration: configuration, timeout: timeout),
      embeddedHermesVersion: { 96 }, run: { $0() }, clock: { [unowned self] in now }, freeSpace: { [unowned self] _ in freeSpace },
      onPending: { [unowned self] in pendingNotices.append($0) }
    )
  }

  private func offer(_ id: String? = nil, mandatory: Bool = false) -> () -> StubURLProtocol.Reply {
    let signature = try! signingKey.signature(for: manifestBytes).derRepresentation
    let body: [String: Any] = [
      "update": [
        "release_id": id ?? releaseId,
        "manifest": manifestBytes.base64EncodedString(),
        "signature": signature.base64EncodedString(),
        "key_id": keyId,
        "download_url": "https://bucket.test/archive?X-Amz-Signature=abc",
        "expires_at": "2026-11-25T12:15:00Z",
        "mandatory": mandatory,
      ] as [String: Any],
      "revert_to_embedded": false,
    ]
    let data = try! JSONSerialization.data(withJSONObject: body)
    return { .response(status: 200, body: data) }
  }

  private func load() -> OTAState { try! store.load()! }

  private func eventTypes() -> [String] { events.read().map { "\($0.type):\($0.reason ?? "")" } }

  private func tmpIsEmpty() -> Bool { ((try? FileManager.default.contentsOfDirectory(atPath: store.tmpDir.path)) ?? []).isEmpty }

  private func installRelease(_ id: String) {
    write("x", to: store.bundleFile(ReleasePointer(releaseId: id, bundle: "main.jsbundle")))
  }

  func testAnOfferedReleaseIsDownloadedVerifiedAndBecomesPending() throws {
    checkReply = offer(mandatory: true)

    updater().check()

    let state = load()
    XCTAssertEqual(state.pending, ReleasePointer(releaseId: releaseId, bundle: "index.android.bundle", mandatory: true))
    XCTAssertTrue(exists(store.bundleFile(state.pending!)))
    XCTAssertEqual(state.lastCheckAt, now)
    XCTAssertEqual(eventTypes(), ["downloaded:"])
    XCTAssertTrue(tmpIsEmpty())
    XCTAssertEqual(pendingNotices, [state.pending!])

    let check = try XCTUnwrap(StubURLProtocol.first("/ota/check"))
    XCTAssertEqual(check.request.url?.absoluteString, "https://notti.test/v1/apps/\(manifest.appId)/ota/check")
    XCTAssertEqual(check.request.value(forHTTPHeaderField: "Authorization"), "Bearer ck_live")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: check.body) as? [String: Any])
    XCTAssertEqual(body["platform"] as? String, "ios")
    XCTAssertEqual(body["channel"] as? String, "production")
    XCTAssertEqual(body["runtime_version"] as? String, "1.4.0")
    XCTAssertEqual(body["installation_id"] as? String, state.installationId)
    XCTAssertEqual(body["binary_identity"] as? String, BinaryIdentity.digest("42|1.4.0|uuid"))
    XCTAssertEqual(body["hermes_bytecode_version"] as? Int, 96)
    XCTAssertEqual(body["sdk_version"] as? String, OTAUpdater.sdkVersion)
    XCTAssertNil(body["current_release_id"])

    let download = try XCTUnwrap(StubURLProtocol.first("/archive"))
    XCTAssertNil(download.request.value(forHTTPHeaderField: "Authorization"), "a presigned URL must not carry the client key")
  }

  func testTheRunningReleaseIsSentAsCurrent() throws {
    installRelease(otherRelease)
    try store.update { var s = $0; s.stable = ReleasePointer(releaseId: otherRelease, bundle: "main.jsbundle"); return s }
    updater().check()
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.first("/ota/check")!.body) as? [String: Any])
    XCTAssertEqual(body["current_release_id"] as? String, otherRelease)
  }

  func testNoUpdateChangesNothing() {
    var before = load()
    updater().check()
    before.lastCheckAt = now
    XCTAssertEqual(load(), before)
    XCTAssertTrue(events.read().isEmpty)
  }

  func testRateLimitedIsNoUpdate() {
    checkReply = { .response(status: 429, body: Data(), headers: ["Retry-After": "60"]) }
    updater().check()
    XCTAssertNil(load().pending)
    XCTAssertTrue(events.read().isEmpty)
    XCTAssertEqual(StubURLProtocol.count("/archive"), 0)
  }

  func testAnUnreachableServerIsNoUpdate() {
    checkReply = { .failure(.notConnectedToInternet) }
    updater().check()
    XCTAssertNil(load().pending)
    XCTAssertTrue(events.read().isEmpty)
  }

  func testAnInterruptedDownloadRemovesThePartialFile() {
    checkReply = offer()
    archiveReply = { .partial(Fixtures.data("archives/valid.tar.gz").prefix(100), total: 241) }
    updater().check()
    XCTAssertNil(load().pending)
    XCTAssertEqual(eventTypes(), ["download_failed:network"])
    XCTAssertTrue(tmpIsEmpty())
    XCTAssertFalse(exists(store.releaseDir(releaseId)))
  }

  func testAnHttpErrorOnTheDownloadIsReported() {
    checkReply = offer()
    archiveReply = { .response(status: 403, body: Data()) }
    updater().check()
    XCTAssertEqual(eventTypes(), ["download_failed:http_status"])
    XCTAssertTrue(tmpIsEmpty())
  }

  func testASlowDownloadTimesOut() {
    checkReply = offer()
    archiveReply = { .failure(.timedOut) }
    updater().check()
    XCTAssertEqual(eventTypes(), ["download_failed:timeout"])
    XCTAssertTrue(tmpIsEmpty())
  }

  func testWithoutFreeSpaceNothingIsDownloaded() {
    checkReply = offer()
    freeSpace = 100
    updater().check()
    XCTAssertEqual(eventTypes(), ["download_failed:no_space"])
    XCTAssertEqual(StubURLProtocol.count("/archive"), 0)
  }

  func testATamperedArchiveIsRejectedAndRemoved() {
    checkReply = offer()
    archiveReply = { .response(status: 200, body: Fixtures.data("archives/tampered.tar.gz")) }
    updater().check()
    XCTAssertNil(load().pending)
    XCTAssertEqual(eventTypes(), ["verification_failed:hash"])
    XCTAssertTrue(tmpIsEmpty())
  }

  func testAnArchiveLargerThanTheManifestIsRejected() {
    checkReply = offer()
    archiveReply = { .response(status: 200, body: Fixtures.data("archives/valid.tar.gz") + Data(count: 4096)) }
    updater().check()
    XCTAssertEqual(eventTypes(), ["verification_failed:hash"])
    XCTAssertTrue(tmpIsEmpty())
  }

  func testABadSignatureIsRejectedBeforeDownloading() {
    let other = P256.Signing.PrivateKey()
    config = OTAConfig(
      appId: manifest.appId, baseUrl: "https://notti.test", clientKey: "ck_live", channel: "production",
      runtimeVersion: "1.4.0", publicKeys: [keyId: other.publicKey.x963Representation]
    )
    checkReply = offer()
    updater().check()
    XCTAssertEqual(eventTypes(), ["verification_failed:signature"])
    XCTAssertEqual(StubURLProtocol.count("/archive"), 0)
  }

  func testAnIncompatibleReleaseIsRejectedBeforeDownloading() {
    config = makeConfig(runtimeVersion: "2.0.0")
    checkReply = offer()
    updater().check()
    XCTAssertEqual(eventTypes(), ["verification_failed:incompatible"])
    XCTAssertEqual(StubURLProtocol.count("/archive"), 0)
  }

  func testABlocklistedReleaseIsSkipped() throws {
    try store.update { $0.blocking(releaseId) }
    checkReply = offer()
    updater().check()
    XCTAssertNil(load().pending)
    XCTAssertTrue(events.read().isEmpty)
    XCTAssertEqual(StubURLProtocol.count("/archive"), 0)
  }

  func testAnOfferOfTheAlreadyPendingReleaseIsIgnored() throws {
    installRelease(releaseId)
    try store.update { var s = $0; s.pending = ReleasePointer(releaseId: releaseId, bundle: "main.jsbundle"); return s }
    checkReply = offer()
    updater().check()
    XCTAssertEqual(StubURLProtocol.count("/archive"), 0)
    XCTAssertTrue(events.read().isEmpty)
  }

  func testRevertToEmbeddedIsRecordedForTheNextColdStart() throws {
    installRelease(otherRelease)
    try store.update { var s = $0; s.stable = ReleasePointer(releaseId: otherRelease, bundle: "main.jsbundle"); return s }
    checkReply = { .response(status: 200, body: Data(#"{"update":null,"revert_to_embedded":true}"#.utf8)) }
    updater().check()
    XCTAssertTrue(load().revertToEmbedded)
    XCTAssertEqual(load().stable?.releaseId, otherRelease)
  }

  func testRevertToEmbeddedOnTheEmbeddedBundleChangesNothing() {
    checkReply = { .response(status: 200, body: Data(#"{"update":null,"revert_to_embedded":true}"#.utf8)) }
    updater().check()
    XCTAssertFalse(load().revertToEmbedded)
  }

  func testTheQueueKeepsTheNewest50() {
    let added = (0..<60).map { OTAEvent.create(OTAEvent.applied, releaseId: nil, now: Int64($0)) }
    added.forEach(events.add)
    XCTAssertEqual(events.read().map(\.eventId), added.suffix(50).map(\.eventId))
  }

  func testEventsAreFlushedInBatchesWithoutPersonalData() throws {
    (0..<60).forEach { _ in events.add(.create(OTAEvent.downloadFailed, releaseId: releaseId, reason: "network", now: now)) }
    updater().flushEvents()

    XCTAssertTrue(events.read().isEmpty)
    let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.first("/ota/events")!.body) as? [String: Any])
    XCTAssertEqual(Set(batch.keys), ["installation_id", "platform", "events"])
    XCTAssertEqual(batch["platform"] as? String, "ios")
    let sent = try XCTUnwrap(batch["events"] as? [[String: Any]])
    XCTAssertEqual(sent.count, 50)
    XCTAssertEqual(Set(sent[0].keys), ["event_id", "type", "release_id", "reason", "occurred_at"])
    XCTAssertEqual(sent[0]["occurred_at"] as? String, "1970-01-01T02:46:40.000Z")
  }

  func testEventsStayQueuedWhenTheServerFails() {
    events.add(.create(OTAEvent.applied, releaseId: releaseId, now: now))
    eventsReply = { .response(status: 503, body: Data()) }
    updater().flushEvents()
    XCTAssertEqual(events.read().count, 1)
  }

  func testABatchTheServerRejectsAsInvalidIsDropped() {
    events.add(.create(OTAEvent.applied, releaseId: releaseId, now: now))
    eventsReply = { .response(status: 422, body: Data()) }
    updater().flushEvents()
    XCTAssertTrue(events.read().isEmpty)
  }

  func testForegroundChecksAreThrottledTo30Minutes() {
    let updater = updater()
    updater.onReady()
    updater.onReady()
    XCTAssertEqual(StubURLProtocol.count("/ota/check"), 1)
    now += OTAUpdater.checkIntervalMs
    updater.onReady()
    XCTAssertEqual(StubURLProtocol.count("/ota/check"), 2)
  }

  func testANewerReleaseReplacesThePendingOne() throws {
    installRelease(otherRelease)
    try store.update { var s = $0; s.pending = ReleasePointer(releaseId: otherRelease, bundle: "main.jsbundle"); s.failedCount = 1; return s }
    checkReply = offer()
    updater().check()
    XCTAssertEqual(load().pending?.releaseId, releaseId)
    XCTAssertEqual(load().failedCount, 0)
    XCTAssertFalse(exists(store.releaseDir(otherRelease)))
  }
}
