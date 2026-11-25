import CryptoKit
import Foundation
import MachO
import os

let otaLog = Logger(subsystem: "com.notti.ota", category: "NottiOta")

/// The `NottiOTA*` keys of the host app's Info.plist. `read` returns nil when Live updates are off:
/// any key missing or invalid (spec OTA-33).
struct OTAConfig: Equatable {
  let appId: String
  let baseUrl: String
  let clientKey: String
  let channel: String
  let runtimeVersion: String
  /// key_id to the 65-byte uncompressed SEC1 public key.
  let publicKeys: [String: Data]

  static let keyAppId = "NottiOTAAppId"
  static let keyBaseUrl = "NottiOTABaseUrl"
  static let keyClientKey = "NottiOTAClientKey"
  static let keyChannel = "NottiOTAChannel"
  static let keyRuntimeVersion = "NottiOTARuntimeVersion"
  static let keyPublicKeys = "NottiOTAPublicKeys"

  static let allKeys = [keyAppId, keyBaseUrl, keyClientKey, keyChannel, keyRuntimeVersion, keyPublicKeys]
  static let maxPublicKeys = 5

  static func read(bundle: Bundle = .main) -> OTAConfig? {
    fromInfoDictionary(bundle.infoDictionary)
  }

  static func fromInfoDictionary(_ info: [String: Any]?) -> OTAConfig? {
    guard let info, allKeys.contains(where: { info[$0] != nil }) else { return nil }
    return parse { stringValue(info[$0]) }
  }

  // A plist <real> loses digits ("1.10" becomes 1.1) and a boolean is not a value, so only strings
  // and integers are accepted, like the Android meta-data.
  private static func stringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    guard let number = value as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() || CFNumberIsFloatType(number) { return nil }
    return number.stringValue
  }

  static func parse(_ value: (String) -> String?) -> OTAConfig? {
    let missing = allKeys.filter { value($0)?.trimmed.isEmpty ?? true }
    if !missing.isEmpty {
      return off("missing or not a string: \(missing.joined(separator: ", "))")
    }
    let appId = value(keyAppId)!.trimmed
    guard UUID(uuidString: appId) != nil else { return off("\(keyAppId) is not a UUID") }
    guard let baseUrl = normalizeBaseUrl(value(keyBaseUrl)!) else {
      return off("\(keyBaseUrl) is not an http(s) URL")
    }
    let channel = value(keyChannel)!.trimmed
    guard isChannel(channel) else { return off("\(keyChannel) must match ^[a-z0-9-]{1,32}$") }
    let runtimeVersion = value(keyRuntimeVersion)!.trimmed
    guard runtimeVersion.utf8.count <= 64 else { return off("\(keyRuntimeVersion) is longer than 64 characters") }
    guard let publicKeys = parsePublicKeys(value(keyPublicKeys)!) else { return nil }
    return OTAConfig(
      appId: appId, baseUrl: baseUrl, clientKey: value(keyClientKey)!.trimmed, channel: channel,
      runtimeVersion: runtimeVersion, publicKeys: publicKeys
    )
  }

  private static func parsePublicKeys(_ raw: String) -> [String: Data]? {
    let entries = raw.split(separator: ",", omittingEmptySubsequences: false)
      .map { String($0).trimmed }
      .filter { !$0.isEmpty }
    guard (1...maxPublicKeys).contains(entries.count) else {
      return off("\(keyPublicKeys) must list 1 to \(maxPublicKeys) keys")
    }
    var keys: [String: Data] = [:]
    for entry in entries {
      guard let colon = entry.firstIndex(of: ":") else { return off("\(keyPublicKeys) entries must be key_id:base64") }
      let keyId = String(entry[..<colon])
      guard isLowerHex(keyId, count: 16) else { return off("\(keyPublicKeys) entries must be key_id:base64") }
      guard let key = Data(base64Encoded: String(entry[entry.index(after: colon)...]), options: .ignoreUnknownCharacters) else {
        return off("\(keyPublicKeys) key \(keyId) is not base64")
      }
      guard key.count == 65, key.first == 0x04 else {
        return off("\(keyPublicKeys) key \(keyId) is not an uncompressed P-256 point")
      }
      guard OTAKeys.keyId(key) == keyId else { return off("\(keyPublicKeys) key_id \(keyId) does not match its key") }
      keys[keyId] = key
    }
    return keys
  }

  static func normalizeBaseUrl(_ raw: String) -> String? {
    var trimmed = raw.trimmed
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let components = URLComponents(string: trimmed),
          components.scheme == "https" || components.scheme == "http",
          let host = components.host, !host.isEmpty,
          components.query == nil, components.fragment == nil
    else { return nil }
    return trimmed
  }

  private static func isChannel(_ s: String) -> Bool {
    (1...32).contains(s.count) && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
  }

  private static func off<T>(_ reason: String) -> T? {
    otaLog.error("Live updates are off: invalid configuration (\(reason, privacy: .public))")
    return nil
  }
}

func isLowerHex(_ s: String, count: Int) -> Bool {
  s.utf8.count == count && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}

enum OTAKeys {
  static func keyId(_ sec1PublicKey: Data) -> String {
    Data(SHA256.hash(data: sec1PublicKey)).prefix(8).hex
  }
}

/// Release on disk: `releases/<releaseId>/<bundle>`.
struct ReleasePointer: Equatable {
  let releaseId: String
  let bundle: String
  var mandatory = false
}

struct LaunchAttempt: Equatable {
  let releaseId: String
  /// Epoch milliseconds.
  let startedAt: Int64
}

struct OTAStateError: Error {
  let message: String
}

/// The device state, stored as the same JSON document as the Android SDK writes.
struct OTAState: Equatable {
  var installationId: String
  var binaryIdentity: String?
  var stable: ReleasePointer?
  var pending: ReleasePointer?
  var attempt: LaunchAttempt?
  var failedCount = 0
  var interruptedCount = 0
  var lastFailureReason: String?
  var blocklist: [String] = []
  var revertToEmbedded = false
  /// Epoch milliseconds.
  var lastCheckAt: Int64 = 0
  /// Event types already reported for this binary identity.
  var reported: Set<String> = []

  static let format = 1
  static let maxBlocklist = 20

  static func fresh(installationId: String = UUID().uuidString.lowercased()) -> OTAState {
    OTAState(installationId: installationId)
  }

  func blocking(_ releaseId: String) -> OTAState {
    var next = self
    next.blocklist = Array((blocklist.filter { $0 != releaseId } + [releaseId]).suffix(Self.maxBlocklist))
    return next
  }

  func jsonData() throws -> Data {
    let object: [String: Any] = [
      "version": Self.format,
      "installation_id": installationId,
      "binary_identity": binaryIdentity ?? NSNull(),
      "stable": stable.map(Self.pointerJSON) ?? NSNull(),
      "pending": pending.map(Self.pointerJSON) ?? NSNull(),
      "attempt": attempt.map { ["release_id": $0.releaseId, "started_at": $0.startedAt] as [String: Any] } ?? NSNull(),
      "failed_count": failedCount,
      "interrupted_count": interruptedCount,
      "last_failure_reason": lastFailureReason ?? NSNull(),
      "blocklist": blocklist,
      "revert_to_embedded": revertToEmbedded,
      "last_check_at": lastCheckAt,
      "reported": reported.sorted(),
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func from(jsonData data: Data) throws -> OTAState {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OTAStateError(message: "state is not an object")
    }
    guard int(json["version"]) == format else { throw OTAStateError(message: "unknown state version") }
    guard let installationId = json["installation_id"] as? String, UUID(uuidString: installationId) != nil else {
      throw OTAStateError(message: "installation_id")
    }
    var state = OTAState(installationId: installationId)
    state.binaryIdentity = try optionalString(json["binary_identity"])
    state.stable = try optionalObject(json["stable"]).map(pointer)
    state.pending = try optionalObject(json["pending"]).map(pointer)
    state.attempt = try optionalObject(json["attempt"]).map { attempt in
      guard let startedAt = int64(attempt["started_at"]) else { throw OTAStateError(message: "attempt") }
      return LaunchAttempt(releaseId: try releaseId(attempt["release_id"]), startedAt: startedAt)
    }
    guard let failed = int(json["failed_count"]), let interrupted = int(json["interrupted_count"]),
          let blocklist = json["blocklist"] as? [Any], let revert = json["revert_to_embedded"] as? Bool,
          let lastCheckAt = int64(json["last_check_at"]), let reported = json["reported"] as? [String]
    else { throw OTAStateError(message: "missing fields") }
    state.failedCount = failed
    state.interruptedCount = interrupted
    state.lastFailureReason = try optionalString(json["last_failure_reason"])
    state.blocklist = Array(try blocklist.map(releaseId).suffix(maxBlocklist))
    state.revertToEmbedded = revert
    state.lastCheckAt = lastCheckAt
    state.reported = Set(reported)
    return state
  }

  private static func pointerJSON(_ pointer: ReleasePointer) -> [String: Any] {
    ["release_id": pointer.releaseId, "bundle": pointer.bundle, "mandatory": pointer.mandatory]
  }

  private static func pointer(_ json: [String: Any]) throws -> ReleasePointer {
    guard let bundle = json["bundle"] as? String, OTAPaths.isSafeRelativePath(bundle) else {
      throw OTAStateError(message: "unsafe bundle path")
    }
    return ReleasePointer(releaseId: try releaseId(json["release_id"]), bundle: bundle, mandatory: json["mandatory"] as? Bool ?? false)
  }

  // Release IDs become directory names, so anything but a canonical UUID is corruption.
  private static func releaseId(_ value: Any?) throws -> String {
    guard let s = value as? String, isCanonicalUUID(s) else {
      throw OTAStateError(message: "release id is not a canonical UUID")
    }
    return s
  }

  private static func optionalString(_ value: Any?) throws -> String? {
    if value == nil || value is NSNull { return nil }
    guard let s = value as? String else { throw OTAStateError(message: "expected a string") }
    return s
  }

  private static func optionalObject(_ value: Any?) throws -> [String: Any]? {
    if value == nil || value is NSNull { return nil }
    guard let object = value as? [String: Any] else { throw OTAStateError(message: "expected an object") }
    return object
  }

  private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

  private static func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
}

func isCanonicalUUID(_ s: String) -> Bool {
  UUID(uuidString: s)?.uuidString.lowercased() == s
}

enum OTAPaths {
  static func isSafeRelativePath(_ path: String) -> Bool {
    if path.isEmpty || path.hasPrefix("/") || path.contains("\\") || path.contains("\u{0}") { return false }
    return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }
}

/// Owns `Application Support/NottiOTA`: `state.json`, `releases/` and `tmp/`. The state file is
/// replaced atomically (tmp file, fsync, rename), so a crash mid-write keeps the previous state.
final class OTAStateStore {
  let root: URL
  let stateFile: URL
  let releasesDir: URL
  let tmpDir: URL
  private let stateTmp: URL
  private let lock = NSRecursiveLock()

  init(root: URL) {
    self.root = root
    stateFile = root.appendingPathComponent("state.json")
    releasesDir = root.appendingPathComponent("releases", isDirectory: true)
    tmpDir = root.appendingPathComponent("tmp", isDirectory: true)
    stateTmp = root.appendingPathComponent("state.json.tmp")
  }

  static func defaultRoot() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("NottiOTA", isDirectory: true)
  }

  /// Loads the state for `binaryIdentity`. A missing or corrupt file, or a different binary identity,
  /// gives a fresh state and wipes every downloaded release (spec OTA-30, OTA-31). A file that exists
  /// but cannot be read (data protection before the first unlock) throws, and nothing is touched.
  func open(binaryIdentity: String) throws -> OTAState {
    lock.lock()
    defer { lock.unlock() }
    let loaded = try load()
    if let loaded, loaded.binaryIdentity == binaryIdentity { return loaded }

    if loaded == nil, FileManager.default.fileExists(atPath: stateFile.path) {
      otaLog.warning("Live updates: state file unreadable, starting from the embedded bundle")
    }
    wipeReleases()
    var fresh = OTAState.fresh(installationId: loaded?.installationId ?? UUID().uuidString.lowercased())
    fresh.binaryIdentity = binaryIdentity
    try save(fresh)
    return fresh
  }

  /// nil when the file is missing or corrupt.
  func load() throws -> OTAState? {
    lock.lock()
    defer { lock.unlock() }
    guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
    let data = try Data(contentsOf: stateFile)
    return try? OTAState.from(jsonData: data)
  }

  func save(_ state: OTAState) throws {
    lock.lock()
    defer { lock.unlock() }
    try ensureRoot()
    try writeDurably(try state.jsonData(), to: stateTmp)
    guard rename(stateTmp.path, stateFile.path) == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      unlink(stateTmp.path)
      throw error
    }
  }

  /// Applies `change` to the stored state and saves it, under the store lock.
  @discardableResult
  func update(_ change: (OTAState) throws -> OTAState) throws -> OTAState {
    lock.lock()
    defer { lock.unlock() }
    guard let current = try load() else { throw OTAStateError(message: "state not opened") }
    let next = try change(current)
    if next != current { try save(next) }
    return next
  }

  func releaseDir(_ releaseId: String) -> URL {
    releasesDir.appendingPathComponent(releaseId, isDirectory: true)
  }

  func bundleFile(_ pointer: ReleasePointer) -> URL {
    releaseDir(pointer.releaseId).appendingPathComponent(pointer.bundle)
  }

  /// Deletes release directories other than `keep` (stable and pending).
  func pruneReleases(keep: Set<String>) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: releasesDir.path)) ?? []
    for name in names where !keep.contains(name) {
      try? FileManager.default.removeItem(at: releasesDir.appendingPathComponent(name))
    }
  }

  func wipeReleases() {
    try? FileManager.default.removeItem(at: releasesDir)
    try? FileManager.default.removeItem(at: tmpDir)
  }

  /// Creates the root once, excluded from iCloud backup. Files created inside inherit its
  /// protection class, readable after the first unlock so headless launches can boot.
  func ensureRoot() throws {
    guard !FileManager.default.fileExists(atPath: root.path) else { return }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = root
    try url.setResourceValues(values)
  }
}

/// Writes `data` to `url` and fsyncs it before returning.
func writeDurably(_ data: Data, to url: URL) throws {
  let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
  guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  defer { close(fd) }
  try data.withUnsafeBytes { raw in
    var offset = 0
    while offset < raw.count {
      let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
  }
  guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Identity of the installed binary: `CFBundleVersion`, `CFBundleShortVersionString` and the
/// LC_UUID of the main executable, which changes with every build (spec OTA-30).
enum BinaryIdentity {
  static func current(bundle: Bundle = .main) -> String {
    let info = bundle.infoDictionary ?? [:]
    let build = info["CFBundleVersion"] as? String ?? ""
    let version = info["CFBundleShortVersionString"] as? String ?? ""
    return "\(build)|\(version)|\(executableUUID() ?? "")"
  }

  static func executableUUID() -> String? {
    for index in 0..<_dyld_image_count() {
      guard let header = _dyld_get_image_header(index), header.pointee.filetype == MH_EXECUTE else { continue }
      return uuid(of: header)
    }
    return nil
  }

  static func uuid(of header: UnsafePointer<mach_header>) -> String? {
    let raw = UnsafeRawPointer(header)
    var offset: Int
    switch header.pointee.magic {
    case MH_MAGIC_64: offset = MemoryLayout<mach_header_64>.size
    case MH_MAGIC: offset = MemoryLayout<mach_header>.size
    default: return nil
    }
    for _ in 0..<header.pointee.ncmds {
      let command = raw.load(fromByteOffset: offset, as: load_command.self)
      if command.cmd == UInt32(LC_UUID) {
        return UUID(uuid: raw.load(fromByteOffset: offset, as: uuid_command.self).uuid).uuidString
      }
      offset += Int(command.cmdsize)
    }
    return nil
  }

  /// What the check request sends: a digest, so the raw values never leave the device. The server
  /// only validates the field (OTA-14 AC6).
  static func digest(_ identity: String) -> String {
    Data(SHA256.hash(data: Data(identity.utf8))).prefix(16).hex
  }
}
