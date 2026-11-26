import Foundation

/// Device event in the shape `POST /ota/events` accepts. Reason codes are the server's fixed list
/// (`internal/ota/events.go`). No personal data: the installation ID travels once per batch.
struct OTAEvent: Equatable {
  let eventId: String
  let type: String
  let releaseId: String?
  let reason: String?
  /// Epoch milliseconds.
  let occurredAt: Int64

  static let downloaded = "downloaded"
  static let downloadFailed = "download_failed"
  static let verificationFailed = "verification_failed"
  static let applied = "applied"
  static let rolledBack = "rolled_back"
  static let revertedToEmbedded = "reverted_to_embedded"
  static let integrationMissing = "integration_missing"
  static let bundleOverridden = "bundle_overridden"

  static func create(_ type: String, releaseId: String?, reason: String? = nil, now: Int64 = currentMillis()) -> OTAEvent {
    OTAEvent(eventId: UUID().uuidString.lowercased(), type: type, releaseId: releaseId, reason: reason, occurredAt: now)
  }

  func json() -> [String: Any] {
    var json: [String: Any] = ["event_id": eventId, "type": type, "occurred_at": Self.rfc3339(occurredAt)]
    if let releaseId { json["release_id"] = releaseId }
    if let reason { json["reason"] = reason }
    return json
  }

  static func from(json: [String: Any]) -> OTAEvent? {
    guard let eventId = json["event_id"] as? String, let type = json["type"] as? String,
          let occurredAt = (json["occurred_at_ms"] as? NSNumber)?.int64Value
    else { return nil }
    return OTAEvent(
      eventId: eventId, type: type, releaseId: json["release_id"] as? String, reason: json["reason"] as? String, occurredAt: occurredAt
    )
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
  }()

  static func rfc3339(_ millis: Int64) -> String {
    formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
  }
}

func currentMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

/// `events.json`: at most `maxEvents` events, the oldest dropped first (spec OTA-49). Same file
/// format as the Android SDK.
final class OTAEventQueue {
  static let maxEvents = 50

  private let file: URL
  private let tmp: URL
  private let lock = NSLock()

  init(file: URL) {
    self.file = file
    tmp = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".tmp")
  }

  func add(_ event: OTAEvent) {
    lock.lock()
    defer { lock.unlock() }
    write(Array((readUnlocked() + [event]).suffix(Self.maxEvents)))
  }

  func peek(limit: Int = maxEvents) -> [OTAEvent] {
    Array(read().prefix(limit))
  }

  func remove(_ eventIds: Set<String>) {
    lock.lock()
    defer { lock.unlock() }
    write(readUnlocked().filter { !eventIds.contains($0.eventId) })
  }

  func read() -> [OTAEvent] {
    lock.lock()
    defer { lock.unlock() }
    return readUnlocked()
  }

  private func readUnlocked() -> [OTAEvent] {
    guard let data = try? Data(contentsOf: file),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return array.compactMap(OTAEvent.from(json:))
  }

  private func write(_ events: [OTAEvent]) {
    let array = events.map { event -> [String: Any] in
      var json = event.json()
      json["occurred_at_ms"] = event.occurredAt
      return json
    }
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try writeDurably(try JSONSerialization.data(withJSONObject: array), to: tmp)
      if rename(tmp.path, file.path) != 0 { unlink(tmp.path) }
    } catch {
      otaLog.error("Live updates: could not write the event queue (\(String(describing: type(of: error)), privacy: .public))")
    }
  }
}
