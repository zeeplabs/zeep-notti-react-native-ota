import Foundation
import XCTest

/// The CLI fixtures shared with the Android tests, read from `fixtures/ota` at the repo root.
enum Fixtures {
  static let root: URL = {
    var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("fixtures/ota", isDirectory: true)
  }()

  static func data(_ name: String) -> Data {
    let url = root.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url) else { fatalError("fixture \(url.path) not found") }
    return data
  }

  static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

  static func copy(_ name: String, to dir: URL) -> URL {
    let target = dir.appendingPathComponent((name as NSString).lastPathComponent)
    try! data(name).write(to: target)
    return target
  }

  static var keyId: String { text("key_id.txt").trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The 65-byte SEC1 point: the tail of the P-256 SPKI in public_key.pem.
  static var publicKeySec1: Data {
    let base64 = text("public_key.pem").split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    let der = Data(base64Encoded: base64)!
    return der.suffix(65)
  }

  static var publicKeyBase64: String { publicKeySec1.base64EncodedString() }
}

/// A fresh directory per test, removed afterwards.
class TempDirTestCase: XCTestCase {
  private(set) var tmp: URL!

  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notti-ota-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tmp)
  }

  func newFolder(_ name: String = UUID().uuidString) -> URL {
    let url = tmp.appendingPathComponent(name, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func write(_ text: String, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
  }
}
