import Compression
import CryptoKit
import Foundation
@testable import NottiOta
import XCTest

final class OTAVerifierTests: TempDirTestCase {
  private let manifestBytes = Fixtures.data("manifest.json")
  private let signature = Fixtures.data("manifest.sig")
  private var keys: [String: Data] { [Fixtures.keyId: Fixtures.publicKeySec1] }
  private lazy var manifest = try! OTAManifest.parse(manifestBytes)

  private lazy var config = OTAConfig(
    appId: manifest.appId, baseUrl: "https://push.example.com", clientKey: "ck", channel: "production",
    runtimeVersion: "1.4.0", publicKeys: keys
  )

  /// The CLI fixtures are an Android release; the compatibility checks need the iOS twin.
  private func iosManifest(files: [ManifestFile]? = nil) -> OTAManifest {
    OTAManifest(
      raw: manifest.raw, releaseId: manifest.releaseId, appId: manifest.appId, platform: "ios",
      channels: manifest.channels, runtimeVersion: manifest.runtimeVersion,
      hermesBytecodeVersion: manifest.hermesBytecodeVersion, bundle: manifest.bundle,
      archiveSha256: manifest.archiveSha256, archiveSize: manifest.archiveSize, files: files ?? manifest.files
    )
  }

  private func expectReason(_ reason: String, file: StaticString = #filePath, line: UInt = #line, _ block: () throws -> Void) {
    do {
      try block()
      XCTFail("expected verification_failed/\(reason)", file: file, line: line)
    } catch let error as OTAVerificationError {
      XCTAssertEqual(error.reason, reason, error.message, file: file, line: line)
    } catch {
      XCTFail("unexpected \(error)", file: file, line: line)
    }
  }

  private func archive(_ name: String) -> URL { Fixtures.copy("archives/\(name)", to: newFolder()) }

  private func configWith(_ change: (inout (appId: String, channel: String, runtime: String)) -> Void) -> OTAConfig {
    var values = (appId: config.appId, channel: config.channel, runtime: config.runtimeVersion)
    change(&values)
    return OTAConfig(
      appId: values.appId, baseUrl: config.baseUrl, clientKey: config.clientKey, channel: values.channel,
      runtimeVersion: values.runtime, publicKeys: keys
    )
  }

  func testTheFixtureKeyIdMatchesTheCli() {
    XCTAssertEqual(OTAKeys.keyId(Fixtures.publicKeySec1), Fixtures.keyId)
  }

  func testAValidReleaseVerifiesAndExtracts() throws {
    try OTAVerifier.verifySignature(manifest: manifestBytes, signature: signature, keyId: Fixtures.keyId, keys: keys)
    try OTAVerifier.checkCompatible(iosManifest(), config: config, embeddedHermesVersion: 96)
    let dest = tmp.appendingPathComponent("tmp/\(manifest.releaseId)")

    try OTAVerifier.verifyAndExtract(archive("valid.tar.gz"), manifest: manifest, into: dest)

    for file in manifest.files {
      let extracted = dest.appendingPathComponent(file.path)
      let size = try FileManager.default.attributesOfItem(atPath: extracted.path)[.size] as? NSNumber
      XCTAssertEqual(size?.int64Value, file.size)
      XCTAssertEqual(try OTAVerifier.sha256(extracted), file.sha256)
    }
  }

  func testAChangedManifestByteFailsTheSignature() {
    var tampered = manifestBytes
    tampered[tampered.count / 2] ^= 1
    expectReason(OTAVerificationError.signature) {
      try OTAVerifier.verifySignature(manifest: tampered, signature: signature, keyId: Fixtures.keyId, keys: keys)
    }
  }

  func testADifferentKeyFailsTheSignature() {
    let other = P256.Signing.PrivateKey().publicKey.x963Representation
    expectReason(OTAVerificationError.signature) {
      try OTAVerifier.verifySignature(manifest: manifestBytes, signature: signature, keyId: Fixtures.keyId, keys: [Fixtures.keyId: other])
    }
  }

  func testAMalformedSignatureFailsTheSignature() {
    expectReason(OTAVerificationError.signature) {
      try OTAVerifier.verifySignature(manifest: manifestBytes, signature: Data([0x30, 0x01]), keyId: Fixtures.keyId, keys: keys)
    }
  }

  func testAnUnknownKeyIdIsRejected() {
    expectReason(OTAVerificationError.unknownKey) {
      try OTAVerifier.verifySignature(manifest: manifestBytes, signature: signature, keyId: "0123456789abcdef", keys: keys)
    }
  }

  func testATamperedArchiveFailsTheArchiveHash() {
    expectReason(OTAVerificationError.hash) { try OTAVerifier.checkArchive(archive("tampered.tar.gz"), manifest: manifest) }
  }

  func testATamperedFileFailsItsHashEvenWhenTheArchiveHashIsSkipped() {
    expectReason(OTAVerificationError.hash) {
      try OTAExtractor.extract(archive("tampered.tar.gz"), into: newFolder("out"), manifest: manifest)
    }
  }

  func testPathTraversalIsRejected() {
    expectReason(OTAVerificationError.invalidPath) {
      try OTAExtractor.extract(archive("path-traversal.tar.gz"), into: newFolder("out"), manifest: manifest)
    }
    XCTAssertFalse(exists(tmp.appendingPathComponent("escape.js")))
  }

  func testAnAbsolutePathIsRejected() {
    expectReason(OTAVerificationError.invalidPath) {
      try OTAExtractor.extract(archive("absolute-path.tar.gz"), into: newFolder("out"), manifest: manifest)
    }
  }

  func testASymlinkEntryIsRejected() {
    expectReason(OTAVerificationError.invalidArchive) {
      try OTAExtractor.extract(archive("symlink.tar.gz"), into: newFolder("out"), manifest: manifest)
    }
  }

  func testAnUnlistedFileIsRejected() {
    expectReason(OTAVerificationError.invalidArchive) {
      try OTAExtractor.extract(archive("unlisted-file.tar.gz"), into: newFolder("out"), manifest: manifest)
    }
  }

  func testAListedFileMissingFromTheArchiveIsRejected() {
    let withExtra = iosManifest(files: manifest.files + [ManifestFile(path: "assets/missing.png", sha256: String(repeating: "0", count: 64), size: 10)])
    expectReason(OTAVerificationError.hash) {
      try OTAExtractor.extract(archive("valid.tar.gz"), into: newFolder("out"), manifest: withExtra)
    }
  }

  func testEveryFailureLeavesNothingBehind() {
    let store = OTAStateStore(root: newFolder("ota"))
    for name in ["tampered.tar.gz", "path-traversal.tar.gz", "absolute-path.tar.gz", "symlink.tar.gz", "unlisted-file.tar.gz"] {
      let dest = store.tmpDir.appendingPathComponent(manifest.releaseId)
      let source = archive(name)
      do {
        try OTAVerifier.verifyAndExtract(source, manifest: manifest, into: dest)
        XCTFail("\(name) was accepted")
      } catch {
        XCTAssertFalse(exists(dest), "\(name) left \(dest.path)")
      }
      XCTAssertFalse(exists(store.releasesDir))
    }
    XCTAssertFalse(exists(tmp.appendingPathComponent("escape.js")))
  }

  func testAReleaseForAnotherPlatformRuntimeChannelAppOrHermesVersionIsIncompatible() throws {
    let ios = iosManifest()
    expectReason(OTAVerificationError.incompatible) { try OTAVerifier.checkCompatible(manifest, config: config, embeddedHermesVersion: 96) }
    expectReason(OTAVerificationError.incompatible) {
      try OTAVerifier.checkCompatible(ios, config: configWith { $0.runtime = "1.5.0" }, embeddedHermesVersion: 96)
    }
    expectReason(OTAVerificationError.incompatible) { try OTAVerifier.checkCompatible(ios, config: config, embeddedHermesVersion: 98) }
    expectReason(OTAVerificationError.incompatible) { try OTAVerifier.checkCompatible(ios, config: config, embeddedHermesVersion: nil) }
    expectReason(OTAVerificationError.incompatible) {
      try OTAVerifier.checkCompatible(ios, config: configWith { $0.channel = "beta" }, embeddedHermesVersion: 96)
    }
    expectReason(OTAVerificationError.incompatible) {
      try OTAVerifier.checkCompatible(ios, config: configWith { $0.appId = "00000000-0000-4000-8000-000000000000" }, embeddedHermesVersion: 96)
    }
    try OTAVerifier.checkCompatible(ios, config: configWith { $0.channel = "staging" }, embeddedHermesVersion: 96)
  }

  func testAMalformedManifestIsAnInvalidArchive() {
    expectReason(OTAVerificationError.invalidArchive) { _ = try OTAManifest.parse(Data("{}".utf8)) }
    expectReason(OTAVerificationError.invalidArchive) { _ = try OTAManifest.parse(Data("not json".utf8)) }
    let text = String(decoding: manifestBytes, as: UTF8.self)
    let unsafe = text.replacingOccurrences(of: "\"path\":\"assets/fonts/inter.ttf\"", with: "\"path\":\"../inter.ttf\"")
    expectReason(OTAVerificationError.invalidArchive) { _ = try OTAManifest.parse(Data(unsafe.utf8)) }
    let fractional = text.replacingOccurrences(of: "\"hermes_bytecode_version\":96", with: "\"hermes_bytecode_version\":96.5")
    expectReason(OTAVerificationError.invalidArchive) { _ = try OTAManifest.parse(Data(fractional.utf8)) }
  }

  func testTheHermesHeaderIsReadForVersions96To99() {
    for version: UInt8 in [96, 98, 99] {
      let header: [UInt8] = [0xC6, 0x1F, 0xBC, 0x03, 0xC1, 0x03, 0x19, 0x1F, version, 0, 0, 0]
      XCTAssertEqual(HermesHeader.bytecodeVersion(Data(header + [UInt8](repeating: 0, count: 20))), Int(version))
    }
    XCTAssertNil(HermesHeader.bytecodeVersion(Data("var a = 1;".utf8)))
    XCTAssertNil(HermesHeader.bytecodeVersion(Data(count: 4)))
  }

  func testTheFixtureBundleIsHermes96() throws {
    let dest = newFolder("out")
    try OTAExtractor.extract(archive("valid.tar.gz"), into: dest, manifest: manifest)
    XCTAssertEqual(HermesHeader.bytecodeVersion(fileAt: dest.appendingPathComponent(manifest.bundle)), 96)
  }

  func testEveryOptionalGzipHeaderFieldIsSkipped() throws {
    let original = Fixtures.data("archives/valid.tar.gz")
    let body = try original.withUnsafeBytes { Data(try OTAExtractor.gzipBody($0)) }
    var rewrapped = Data([0x1F, 0x8B, 0x08, 0x1E, 0, 0, 0, 0, 0, 0x03])
    rewrapped += Data([4, 0, 0x41, 0x42, 2, 0])
    rewrapped += Data("valid.tar\0".utf8) + Data("a comment\0".utf8) + Data([0xAB, 0xCD])
    rewrapped += body + original.suffix(8)
    let url = tmp.appendingPathComponent("flags.tar.gz")
    try rewrapped.write(to: url)

    try OTAExtractor.extract(url, into: newFolder("out"), manifest: manifest)
  }

  func testATruncatedOrNonGzipArchiveIsInvalid() throws {
    let original = Fixtures.data("archives/valid.tar.gz")
    let truncated = tmp.appendingPathComponent("truncated.tar.gz")
    try original.prefix(original.count / 2).write(to: truncated)
    expectReason(OTAVerificationError.invalidArchive) { try OTAExtractor.extract(truncated, into: newFolder("a"), manifest: manifest) }

    let plain = tmp.appendingPathComponent("plain.tar.gz")
    try Data(repeating: 0x61, count: 2048).write(to: plain)
    expectReason(OTAVerificationError.invalidArchive) { try OTAExtractor.extract(plain, into: newFolder("b"), manifest: manifest) }
  }

  func testAnArchiveThatInflatesPastTheListedSizeIsRejected() throws {
    let entrySize = 20 * 1024 * 1024
    let tar = tarHeader(name: "d/", size: entrySize, type: UInt8(ascii: "5")) + [UInt8](repeating: 0, count: entrySize)
    let url = tmp.appendingPathComponent("bomb.tar.gz")
    try gzip(tar).write(to: url)

    XCTAssertThrowsError(try OTAExtractor.extract(url, into: newFolder("out"), manifest: manifest)) { error in
      let failure = error as? OTAVerificationError
      XCTAssertEqual(failure?.reason, OTAVerificationError.invalidArchive)
      XCTAssertTrue(failure?.message.contains("inflates past") == true, "\(error)")
    }
  }

  private func tarHeader(name: String, size: Int, type: UInt8) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 512)
    func put(_ text: String, at offset: Int) {
      for (i, byte) in text.utf8.enumerated() { h[offset + i] = byte }
    }
    put(name, at: 0)
    put("0000755", at: 100)
    put(String(format: "%011o", size), at: 124)
    h[156] = type
    put("ustar", at: 257)
    put("00", at: 263)
    for i in 148..<156 { h[i] = 32 }
    put(String(format: "%06o", h.reduce(0) { $0 + Int($1) }), at: 148)
    h[154] = 0
    return h
  }

  private func gzip(_ bytes: [UInt8]) -> Data {
    var deflated = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
    let n = compression_encode_buffer(&deflated, deflated.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
    precondition(n > 0)
    return Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0x03]) + Data(deflated.prefix(n)) + Data(count: 8)
  }
}
