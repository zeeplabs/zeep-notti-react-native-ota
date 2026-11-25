import Foundation

struct OTAUpdate {
  let releaseId: String
  let manifest: Data
  let signature: Data
  let keyId: String
  let downloadURL: URL
  let mandatory: Bool
}

enum OTACheckResult {
  case update(OTAUpdate)
  case noUpdate
  case revertToEmbedded
}

/// A failed download, with the `download_failed` reason code the server accepts.
struct OTADownloadError: Error {
  let reason: String
  let message: String

  static let network = "network"
  static let httpStatus = "http_status"
  static let timeout = "timeout"
  static let noSpace = "no_space"
}

/// `POST /ota/check`, `POST /ota/events` and the archive download, over URLSession. Calls block the
/// updater's own queue, never the main thread.
final class OTAApiClient {
  private let config: OTAConfig
  private let configuration: URLSessionConfiguration
  private let session: URLSession
  private var appBase: String { "\(config.baseUrl)/v1/apps/\(config.appId)/ota" }

  init(config: OTAConfig, configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 15) {
    self.config = config
    configuration.timeoutIntervalForRequest = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    self.configuration = configuration
    session = URLSession(configuration: configuration)
  }

  /// Any failure, including 429, is "no update": the device keeps what it runs.
  func check(_ body: [String: Any]) -> OTACheckResult {
    guard let (status, data) = post("\(appBase)/check", body) else {
      otaLog.warning("Live updates: update check failed")
      return .noUpdate
    }
    guard (200..<300).contains(status) else {
      otaLog.warning("Live updates: update check answered HTTP \(status)")
      return .noUpdate
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      otaLog.warning("Live updates: unreadable update check response")
      return .noUpdate
    }
    if let update = json["update"] as? [String: Any] {
      guard let releaseId = update["release_id"] as? String,
            let manifest = (update["manifest"] as? String).flatMap({ Data(base64Encoded: $0) }),
            let signature = (update["signature"] as? String).flatMap({ Data(base64Encoded: $0) }),
            let keyId = update["key_id"] as? String,
            let downloadURL = (update["download_url"] as? String).flatMap(URL.init(string:))
      else {
        otaLog.warning("Live updates: unreadable update check response")
        return .noUpdate
      }
      return .update(OTAUpdate(
        releaseId: releaseId, manifest: manifest, signature: signature, keyId: keyId, downloadURL: downloadURL,
        mandatory: update["mandatory"] as? Bool ?? false
      ))
    }
    return json["revert_to_embedded"] as? Bool == true ? .revertToEmbedded : .noUpdate
  }

  /// True when the server took the batch, or rejected it as invalid (422): a batch it will never
  /// accept must not block the queue. Network errors, 429 and 5xx keep the events for later.
  func postEvents(installationId: String, events: [OTAEvent]) -> Bool {
    let body: [String: Any] = ["installation_id": installationId, "platform": "ios", "events": events.map { $0.json() }]
    guard let (status, _) = post("\(appBase)/events", body) else { return false }
    return (200..<300).contains(status) || status == 422
  }

  /// Streams `url` (a presigned GET, sent without credentials) into `dest`, at most `maxBytes`.
  func download(_ url: URL, to dest: URL, maxBytes: Int64) throws {
    let receiver = DownloadReceiver(dest: dest, maxBytes: maxBytes)
    let downloads = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
    defer { downloads.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    downloads.dataTask(with: request).resume()
    try receiver.wait()
  }

  private func post(_ url: String, _ body: [String: Any]) -> (Int, Data)? {
    guard let target = URL(string: url), let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.clientKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload
    let done = DispatchSemaphore(value: 0)
    var result: (Int, Data)?
    session.dataTask(with: request) { data, response, error in
      if error == nil, let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
      done.signal()
    }.resume()
    done.wait()
    return result
  }
}

/// Writes a download to disk as it arrives and stops it past the size the manifest declares.
private final class DownloadReceiver: NSObject, URLSessionDataDelegate {
  private let dest: URL
  private let maxBytes: Int64
  private let done = DispatchSemaphore(value: 0)
  private var fd: Int32 = -1
  private var total: Int64 = 0
  private var expected: Int64 = -1
  private var failure: Error?

  init(dest: URL, maxBytes: Int64) {
    self.dest = dest
    self.maxBytes = maxBytes
  }

  func wait() throws {
    done.wait()
    if let failure { throw failure }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      failure = OTADownloadError(reason: OTADownloadError.httpStatus, message: "download answered HTTP \(status)")
      return completionHandler(.cancel)
    }
    expected = response.expectedContentLength
    fd = Darwin.open(dest.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    if fd < 0 {
      failure = writeError(errno)
      return completionHandler(.cancel)
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    total += Int64(data.count)
    if total > maxBytes {
      failure = OTAVerificationError(reason: OTAVerificationError.hash, message: "archive is larger than the manifest says")
      return dataTask.cancel()
    }
    let written = data.withUnsafeBytes { raw -> Bool in
      var offset = 0
      while offset < raw.count {
        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 {
          if errno == EINTR { continue }
          failure = writeError(errno)
          return false
        }
        offset += n
      }
      return true
    }
    if !written { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if fd >= 0 {
      if failure == nil, error == nil, fsync(fd) != 0 { failure = writeError(errno) }
      close(fd)
    }
    if failure == nil, let error = error as? URLError {
      failure = error.code == .timedOut
        ? OTADownloadError(reason: OTADownloadError.timeout, message: "download timed out")
        : OTADownloadError(reason: OTADownloadError.network, message: "download failed (\(error.code.rawValue))")
    } else if failure == nil, error != nil {
      failure = OTADownloadError(reason: OTADownloadError.network, message: "download failed")
    } else if failure == nil, expected >= 0, total != expected {
      failure = OTADownloadError(reason: OTADownloadError.network, message: "connection closed after \(total) of \(expected) bytes")
    }
    done.signal()
  }

  private func writeError(_ code: Int32) -> Error {
    code == ENOSPC
      ? OTADownloadError(reason: OTADownloadError.noSpace, message: "no space left")
      : OTADownloadError(reason: OTADownloadError.network, message: "could not write the download (\(code))")
  }
}

/// Check, download, verify and promote a Live update in the background, then flush the event queue.
/// A new release only becomes `pending`: it is loaded on the next cold start (spec OTA-16).
final class OTAUpdater {
  static let sdkVersion = "0.1.0"
  static let checkIntervalMs: Int64 = 30 * 60 * 1000
  private static let spaceFactor: Int64 = 3
  private static let queue = DispatchQueue(label: "com.notti.ota.updater", qos: .utility)

  private let config: OTAConfig
  private let store: OTAStateStore
  private let events: OTAEventQueue
  private let api: OTAApiClient
  private let embeddedHermesVersion: () -> Int?
  private let run: (@escaping () -> Void) -> Void
  private let clock: () -> Int64
  private let freeSpace: (URL) -> Int64
  private let onPending: (ReleasePointer) -> Void
  private var checkedThisProcess = false

  init(
    config: OTAConfig, store: OTAStateStore, events: OTAEventQueue, api: OTAApiClient,
    embeddedHermesVersion: @escaping () -> Int?,
    run: @escaping (@escaping () -> Void) -> Void = { OTAUpdater.queue.async(execute: $0) },
    clock: @escaping () -> Int64 = currentMillis,
    freeSpace: @escaping (URL) -> Int64 = OTAUpdater.availableCapacity,
    onPending: @escaping (ReleasePointer) -> Void = { _ in }
  ) {
    self.config = config
    self.store = store
    self.events = events
    self.api = api
    self.embeddedHermesVersion = embeddedHermesVersion
    self.clock = clock
    self.freeSpace = freeSpace
    self.onPending = onPending
    self.run = run
  }

  /// First call per process checks; later foreground calls check only after `checkIntervalMs`.
  func onReady() {
    run { [self] in
      guard let state = try? store.load() else { return }
      if !checkedThisProcess || clock() - state.lastCheckAt >= Self.checkIntervalMs {
        checkedThisProcess = true
        check()
      }
      flushEvents()
    }
  }

  func check() {
    let now = clock()
    guard let state = try? store.update({ state in
      var next = state
      next.lastCheckAt = now
      return next
    }) else { return }
    var body: [String: Any] = [
      "platform": "ios",
      "channel": config.channel,
      "runtime_version": config.runtimeVersion,
      "binary_identity": BinaryIdentity.digest(state.binaryIdentity ?? ""),
      "installation_id": state.installationId,
      "sdk_version": Self.sdkVersion,
      "hermes_bytecode_version": embeddedHermesVersion() ?? 0,
    ]
    if let stable = state.stable { body["current_release_id"] = stable.releaseId }

    switch api.check(body) {
    case .noUpdate:
      break
    case .revertToEmbedded:
      _ = try? store.update { state in
        guard state.stable != nil || state.pending != nil else { return state }
        var next = state
        next.revertToEmbedded = true
        return next
      }
    case .update(let update):
      apply(update)
    }
  }

  private func apply(_ update: OTAUpdate) {
    guard let state = try? store.load() else { return }
    let id = update.releaseId
    guard isCanonicalUUID(id), !state.blocklist.contains(id), id != state.pending?.releaseId, id != state.stable?.releaseId else { return }

    let archive = store.tmpDir.appendingPathComponent("\(id).tar.gz")
    let extracted = store.tmpDir.appendingPathComponent(id, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: archive)
      try? FileManager.default.removeItem(at: extracted)
    }
    do {
      let manifest = try OTAManifest.parse(update.manifest)
      guard manifest.releaseId == id else {
        throw OTAVerificationError(reason: OTAVerificationError.invalidArchive, message: "manifest is for another release")
      }
      try OTAVerifier.verifySignature(manifest: update.manifest, signature: update.signature, keyId: update.keyId, keys: config.publicKeys)
      try OTAVerifier.checkCompatible(manifest, config: config, embeddedHermesVersion: embeddedHermesVersion())

      try FileManager.default.createDirectory(at: store.tmpDir, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: archive)
      try? FileManager.default.removeItem(at: extracted)
      if freeSpace(store.tmpDir) < manifest.archiveSize * Self.spaceFactor {
        throw OTADownloadError(reason: OTADownloadError.noSpace, message: "not enough free space")
      }
      try api.download(update.downloadURL, to: archive, maxBytes: manifest.archiveSize)
      try OTAVerifier.verifyAndExtract(archive, manifest: manifest, into: extracted)
      try? FileManager.default.removeItem(at: archive)

      let target = store.releaseDir(id)
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.createDirectory(at: store.releasesDir, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: extracted, to: target)

      let pointer = ReleasePointer(releaseId: id, bundle: manifest.bundle, mandatory: update.mandatory)
      let next = try store.update { state in
        var next = state
        next.pending = pointer
        next.attempt = nil
        next.failedCount = 0
        next.interruptedCount = 0
        next.lastFailureReason = nil
        next.revertToEmbedded = false
        return next
      }
      store.pruneReleases(keep: Set([next.stable?.releaseId, next.pending?.releaseId].compactMap { $0 }))
      events.add(.create(OTAEvent.downloaded, releaseId: id, now: clock()))
      otaLog.info("Live updates: release \(id, privacy: .public) downloaded, it loads on the next cold start")
      onPending(pointer)
    } catch let error as OTADownloadError {
      otaLog.warning("Live updates: download of \(id, privacy: .public) failed (\(error.reason, privacy: .public))")
      events.add(.create(OTAEvent.downloadFailed, releaseId: id, reason: error.reason, now: clock()))
    } catch let error as OTAVerificationError {
      otaLog.warning("Live updates: release \(id, privacy: .public) rejected (\(error.reason, privacy: .public)): \(error.message, privacy: .public)")
      events.add(.create(OTAEvent.verificationFailed, releaseId: id, reason: error.reason, now: clock()))
    } catch {
      let reason = OTAExtractor.isNoSpace(error) ? OTADownloadError.noSpace : OTADownloadError.network
      events.add(.create(OTAEvent.downloadFailed, releaseId: id, reason: reason, now: clock()))
    }
  }

  func flushEvents() {
    guard let installationId = (try? store.load())??.installationId else { return }
    while true {
      let batch = events.peek(limit: OTAEventQueue.maxEvents)
      if batch.isEmpty || !api.postEvents(installationId: installationId, events: batch) { return }
      events.remove(Set(batch.map(\.eventId)))
    }
  }

  static func availableCapacity(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  /// The Hermes bytecode version of the embedded `main.jsbundle`, read once.
  static func embeddedHermesVersion(bundle: Bundle = .main) -> () -> Int? {
    var cached: Int??
    let lock = NSLock()
    return {
      lock.lock()
      defer { lock.unlock() }
      if let cached { return cached }
      let version = bundle.url(forResource: "main", withExtension: "jsbundle").flatMap(HermesHeader.bytecodeVersion(fileAt:))
      cached = .some(version)
      return version
    }
  }
}
