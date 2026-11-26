import Compression
import CryptoKit
import Foundation

/// A failed check, with the `verification_failed` reason code the server accepts.
struct OTAVerificationError: Error, CustomStringConvertible {
  let reason: String
  let message: String

  static let signature = "signature"
  static let unknownKey = "unknown_key"
  static let hash = "hash"
  static let incompatible = "incompatible"
  static let invalidPath = "invalid_path"
  static let invalidArchive = "invalid_archive"

  var description: String { "\(reason): \(message)" }
}

struct ManifestFile: Equatable {
  let path: String
  let sha256: String
  let size: Int64
}

/// Format v1 release manifest. `raw` is what the signature covers; it is never re-serialized.
struct OTAManifest {
  let raw: Data
  let releaseId: String
  let appId: String
  let platform: String
  let channels: [String]
  let runtimeVersion: String
  let hermesBytecodeVersion: Int
  let bundle: String
  let archiveSha256: String
  let archiveSize: Int64
  let files: [ManifestFile]

  static let maxArchiveBytes: Int64 = 50 * 1024 * 1024

  static func parse(_ raw: Data) throws -> OTAManifest {
    do {
      return try strictParse(raw)
    } catch {
      throw OTAVerificationError(reason: OTAVerificationError.invalidArchive, message: "manifest is not a valid format v1 manifest (\(error))")
    }
  }

  private struct Invalid: Error, CustomStringConvertible {
    let description: String
  }

  private static func strictParse(_ raw: Data) throws -> OTAManifest {
    guard let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw Invalid(description: "not an object") }
    guard integer(json["format"]) == 1 else { throw Invalid(description: "unsupported format") }
    guard let releaseId = json["release_id"] as? String, isCanonicalUUID(releaseId) else { throw Invalid(description: "release_id") }
    guard let channels = json["channels"] as? [String] else { throw Invalid(description: "channels") }
    guard let archive = json["archive"] as? [String: Any], let archiveSha = archive["sha256"] as? String,
          let archiveSize = integer(archive["size"]), (1...maxArchiveBytes).contains(archiveSize), isLowerHex(archiveSha, count: 64)
    else { throw Invalid(description: "archive") }
    guard let filesJson = json["files"] as? [[String: Any]] else { throw Invalid(description: "files") }
    let files = try filesJson.map { f -> ManifestFile in
      guard let path = f["path"] as? String, let sha = f["sha256"] as? String, let size = integer(f["size"]),
            OTAPaths.isSafeRelativePath(path), isLowerHex(sha, count: 64), size > 0
      else { throw Invalid(description: "files") }
      return ManifestFile(path: path, sha256: sha, size: size)
    }
    guard Set(files.map(\.path)).count == files.count else { throw Invalid(description: "duplicate file") }
    guard let bundle = json["bundle"] as? String, files.contains(where: { $0.path == bundle }) else {
      throw Invalid(description: "bundle not listed")
    }
    guard let appId = json["app_id"] as? String, let platform = json["platform"] as? String,
          let runtimeVersion = json["runtime_version"] as? String,
          let hermes = integer(json["hermes_bytecode_version"]), let hermesVersion = Int(exactly: hermes)
    else { throw Invalid(description: "fields") }
    return OTAManifest(
      raw: raw, releaseId: releaseId, appId: appId, platform: platform, channels: channels,
      runtimeVersion: runtimeVersion, hermesBytecodeVersion: hermesVersion, bundle: bundle,
      archiveSha256: archiveSha, archiveSize: archiveSize, files: files
    )
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number) else { return nil }
    return number.int64Value
  }
}

enum OTAVerifier {
  /// Verifies the ECDSA P-256 / SHA-256 DER `signature` over the manifest bytes as received.
  static func verifySignature(manifest: Data, signature: Data, keyId: String, keys: [String: Data]) throws {
    guard let sec1 = keys[keyId] else {
      throw OTAVerificationError(reason: OTAVerificationError.unknownKey, message: "key_id \(keyId) is not embedded in this binary")
    }
    let valid: Bool
    do {
      let publicKey = try P256.Signing.PublicKey(x963Representation: sec1)
      let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: signature)
      valid = publicKey.isValidSignature(ecdsa, for: manifest)
    } catch {
      valid = false
    }
    if !valid {
      throw OTAVerificationError(reason: OTAVerificationError.signature, message: "manifest signature does not verify with key \(keyId)")
    }
  }

  /// The release must target this binary: app, platform, channel, runtime version and the Hermes
  /// bytecode version of the embedded bundle (`embeddedHermesVersion`, nil when unreadable).
  static func checkCompatible(_ manifest: OTAManifest, config: OTAConfig, embeddedHermesVersion: Int?) throws {
    let mismatch: String?
    if manifest.appId != config.appId {
      mismatch = "app_id"
    } else if manifest.platform != "ios" {
      mismatch = "platform"
    } else if !manifest.channels.contains(config.channel) {
      mismatch = "channel"
    } else if manifest.runtimeVersion != config.runtimeVersion {
      mismatch = "runtime_version"
    } else if embeddedHermesVersion == nil {
      mismatch = "embedded bundle is not Hermes bytecode"
    } else if manifest.hermesBytecodeVersion != embeddedHermesVersion {
      mismatch = "hermes_bytecode_version"
    } else {
      mismatch = nil
    }
    if let mismatch {
      throw OTAVerificationError(reason: OTAVerificationError.incompatible, message: "release does not match this binary (\(mismatch))")
    }
  }

  static func checkArchive(_ archive: URL, manifest: OTAManifest) throws {
    let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value
    guard size == manifest.archiveSize, try sha256(archive) == manifest.archiveSha256 else {
      throw OTAVerificationError(reason: OTAVerificationError.hash, message: "archive does not match the manifest")
    }
  }

  /// Checks the downloaded `archive` against `manifest` and extracts it into `dest`. On any failure
  /// `dest` is deleted, so nothing is left behind.
  static func verifyAndExtract(_ archive: URL, manifest: OTAManifest, into dest: URL) throws {
    do {
      try checkArchive(archive, manifest: manifest)
      try OTAExtractor.extract(archive, into: dest, manifest: manifest)
      let bundleVersion = HermesHeader.bytecodeVersion(fileAt: dest.appendingPathComponent(manifest.bundle))
      if bundleVersion != manifest.hermesBytecodeVersion {
        throw OTAVerificationError(
          reason: OTAVerificationError.incompatible,
          message: "bundle is not Hermes bytecode version \(manifest.hermesBytecodeVersion)"
        )
      }
    } catch {
      try? FileManager.default.removeItem(at: dest)
      throw error
    }
  }

  static func sha256(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize()).hex
  }
}

/// Hermes bytecode header: 8-byte magic, then the bytecode version as a little-endian uint32.
enum HermesHeader {
  private static let magic: [UInt8] = [0xC6, 0x1F, 0xBC, 0x03, 0xC1, 0x03, 0x19, 0x1F]

  static func bytecodeVersion(_ header: Data) -> Int? {
    let bytes = [UInt8](header.prefix(12))
    guard bytes.count == 12, Array(bytes[0..<8]) == magic else { return nil }
    let version = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
    return (1...UInt32(Int32.max)).contains(version) ? Int(version) : nil
  }

  static func bytecodeVersion(fileAt url: URL) -> Int? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 12)).flatMap(bytecodeVersion)
  }
}

/// Minimal reader for the CLI's archives: gzip (RFC 1952) over POSIX ustar, regular files and
/// directories only. Every regular file must be listed in the manifest with the same size and SHA-256.
enum OTAExtractor {
  static let block = 512
  static let maxEntries = 10_000

  static func extract(_ archive: URL, into dest: URL, manifest: OTAManifest) throws {
    let listed = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
    var seen = Set<String>()
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let root = dest.standardizedFileURL

    do {
      let data = try Data(contentsOf: archive, options: .alwaysMapped)
      try data.withUnsafeBytes { raw in
        // The inflated size is capped by what the manifest lists, never by the attacker-controlled ISIZE.
        let limit = manifest.files.reduce(0) { $0 + padded(Int($1.size)) } + block * (maxEntries + 2) + 20 * block
        let input = try Inflater(body: try gzipBody(raw), limit: limit)
        var header = [UInt8](repeating: 0, count: block)
        var entries = 0
        while true {
          guard try input.readFully(&header) else { throw invalidArchive("truncated archive") }
          if header.allSatisfy({ $0 == 0 }) { break }
          entries += 1
          if entries > maxEntries { throw invalidArchive("too many entries") }
          let entry = try parseHeader(header)
          switch entry.type {
          case UInt8(ascii: "5"):
            let dir = try resolve(root, path: String(entry.path.trimmingTrailingSlashes))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try input.skip(padded(entry.size))
          case UInt8(ascii: "0"), 0:
            guard let expected = listed[entry.path] else {
              throw invalidArchive("entry \(entry.path) is not listed in the manifest")
            }
            guard seen.insert(entry.path).inserted else { throw invalidArchive("entry \(entry.path) appears twice") }
            guard Int64(entry.size) == expected.size else { throw hashMismatch(entry.path) }
            let target = try resolve(root, path: entry.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try copy(input, to: target, size: entry.size) == expected.sha256 else { throw hashMismatch(entry.path) }
            try input.skip(padded(entry.size) - entry.size)
          case UInt8(ascii: "2"):
            throw invalidArchive("entry \(entry.path) is a symbolic link")
          case UInt8(ascii: "1"):
            throw invalidArchive("entry \(entry.path) is a hard link")
          default:
            throw invalidArchive("entry \(entry.path) has unsupported type \(entry.type)")
          }
        }
      }
    } catch let error as OTAVerificationError {
      throw error
    } catch {
      if isNoSpace(error) { throw error }
      throw invalidArchive("archive is not a readable tar.gz (\(error))")
    }

    let missing = Set(listed.keys).subtracting(seen)
    if !missing.isEmpty {
      throw OTAVerificationError(reason: OTAVerificationError.hash, message: "listed files missing from the archive: \(missing.count)")
    }
  }

  /// The raw deflate body of a single-member gzip file: the header (with its optional FEXTRA, FNAME,
  /// FCOMMENT and FHCRC fields) and the 8-byte CRC32/ISIZE trailer are stripped.
  static func gzipBody(_ bytes: UnsafeRawBufferPointer) throws -> UnsafeRawBufferPointer {
    let count = bytes.count
    guard count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw invalidArchive("not a gzip file") }
    let flags = bytes[3]
    guard flags & 0xE0 == 0 else { throw invalidArchive("reserved gzip flags set") }
    var position = 10
    if flags & 0x04 != 0 {
      guard position + 2 <= count else { throw invalidArchive("truncated gzip header") }
      position += 2 + (Int(bytes[position]) | Int(bytes[position + 1]) << 8)
    }
    for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
      while position < count, bytes[position] != 0 { position += 1 }
      position += 1
    }
    if flags & 0x02 != 0 { position += 2 }
    guard position < count - 8 else { throw invalidArchive("truncated gzip header") }
    return UnsafeRawBufferPointer(rebasing: bytes[position..<(count - 8)])
  }

  private struct Entry {
    let path: String
    let size: Int
    let type: UInt8
  }

  private static func parseHeader(_ h: [UInt8]) throws -> Entry {
    guard Array(h[257..<262]) == Array("ustar".utf8) else { throw invalidArchive("not a ustar archive") }
    let storedChecksum = try octal(h, 148, 8)
    var sum: Int64 = 0
    for (i, byte) in h.enumerated() { sum += (148..<156).contains(i) ? 32 : Int64(byte) }
    guard sum == storedChecksum else { throw invalidArchive("tar header checksum mismatch") }
    let name = text(h, 0, 100)
    let prefix = text(h, 345, 155)
    let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
    let type = h[156]
    let size = try octal(h, 124, 12)
    guard size >= 0, size <= OTAManifest.maxArchiveBytes * 4 else { throw invalidArchive("entry size out of range") }
    try checkPath(type == UInt8(ascii: "5") ? String(path.trimmingTrailingSlashes) : path)
    return Entry(path: path, size: Int(size), type: type)
  }

  private static func checkPath(_ path: String) throws {
    if path.hasPrefix("/") { throw invalidPath("entry \(path) is absolute") }
    if !OTAPaths.isSafeRelativePath(path) { throw invalidPath("entry \(path) leaves the extraction directory") }
  }

  private static func resolve(_ root: URL, path: String) throws -> URL {
    let target = root.appendingPathComponent(path).standardizedFileURL
    guard target.path.hasPrefix(root.path + "/") else { throw invalidPath("entry \(path) leaves the extraction directory") }
    return target
  }

  private static func copy(_ input: Inflater, to target: URL, size: Int) throws -> String {
    let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var remaining = size
    while remaining > 0 {
      let n = try buffer.withUnsafeMutableBufferPointer { try input.read(into: $0.baseAddress!, count: min($0.count, remaining)) }
      if n == 0 { throw invalidArchive("truncated entry") }
      try buffer.withUnsafeBufferPointer { chunk in
        hasher.update(bufferPointer: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: chunk[0..<n])))
        var offset = 0
        while offset < n {
          let written = write(fd, chunk.baseAddress! + offset, n - offset)
          if written < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
          offset += written
        }
      }
      remaining -= n
    }
    guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return Data(hasher.finalize()).hex
  }

  private static func text(_ h: [UInt8], _ offset: Int, _ length: Int) -> String {
    var end = offset
    while end < offset + length, h[end] != 0 { end += 1 }
    return String(decoding: h[offset..<end], as: UTF8.self)
  }

  private static func octal(_ h: [UInt8], _ offset: Int, _ length: Int) throws -> Int64 {
    let s = text(h, offset, length).trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return 0 }
    guard let value = Int64(s, radix: 8) else { throw invalidArchive("bad octal field in tar header") }
    return value
  }

  static func padded(_ size: Int) -> Int { (size + block - 1) / block * block }

  static func isNoSpace(_ error: Error) -> Bool {
    let ns = error as NSError
    return (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
      || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
  }

  private static func invalidArchive(_ message: String) -> OTAVerificationError {
    OTAVerificationError(reason: OTAVerificationError.invalidArchive, message: message)
  }

  private static func invalidPath(_ message: String) -> OTAVerificationError {
    OTAVerificationError(reason: OTAVerificationError.invalidPath, message: message)
  }

  private static func hashMismatch(_ path: String) -> OTAVerificationError {
    OTAVerificationError(reason: OTAVerificationError.hash, message: "\(path) does not match the manifest")
  }
}

/// Streaming raw-deflate decoder over `compression_stream`, refusing to produce more than `limit` bytes.
final class Inflater {
  private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
  private let limit: Int
  private var produced = 0
  private var finished = false

  init(body: UnsafeRawBufferPointer, limit: Int) throws {
    guard let base = body.baseAddress, body.count > 0 else {
      stream.deallocate()
      throw OTAVerificationError(reason: OTAVerificationError.invalidArchive, message: "empty deflate stream")
    }
    guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
      stream.deallocate()
      throw OTAVerificationError(reason: OTAVerificationError.invalidArchive, message: "could not start the decoder")
    }
    stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
    stream.pointee.src_size = body.count
    self.limit = limit
  }

  deinit {
    compression_stream_destroy(stream)
    stream.deallocate()
  }

  /// Up to `count` inflated bytes; 0 only at the end of the stream.
  func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int {
    if finished || count == 0 { return 0 }
    stream.pointee.dst_ptr = buffer
    stream.pointee.dst_size = count
    while true {
      let sourceBefore = stream.pointee.src_size
      let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
      let n = count - stream.pointee.dst_size
      if status == COMPRESSION_STATUS_ERROR { throw invalid("not a valid deflate stream") }
      if status == COMPRESSION_STATUS_END { finished = true }
      if n > 0 || finished {
        produced += n
        if produced > limit { throw invalid("archive inflates past the size its manifest lists") }
        return n
      }
      if stream.pointee.src_size == sourceBefore { throw invalid("truncated deflate stream") }
    }
  }

  func readFully(_ buffer: inout [UInt8]) throws -> Bool {
    var filled = 0
    while filled < buffer.count {
      let n = try buffer.withUnsafeMutableBufferPointer { try read(into: $0.baseAddress! + filled, count: $0.count - filled) }
      if n == 0 { return false }
      filled += n
    }
    return true
  }

  func skip(_ count: Int) throws {
    var remaining = count
    var scratch = [UInt8](repeating: 0, count: min(max(count, 1), 64 * 1024))
    while remaining > 0 {
      let n = try scratch.withUnsafeMutableBufferPointer { try read(into: $0.baseAddress!, count: min($0.count, remaining)) }
      if n == 0 { throw invalid("truncated archive") }
      remaining -= n
    }
  }

  private func invalid(_ message: String) -> OTAVerificationError {
    OTAVerificationError(reason: OTAVerificationError.invalidArchive, message: message)
  }
}

private extension String {
  var trimmingTrailingSlashes: Substring {
    var s = Substring(self)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }
}
