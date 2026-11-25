// T31 spike (throwaway): gzip header parsing + raw deflate with Apple's Compression
// framework + a ustar reader, run against the CLI fixture archives.
// Usage: swift spikes/ios-extractor/main.swift fixtures/ota
import Compression
import CryptoKit
import Foundation

enum SpikeError: Error, CustomStringConvertible {
  case reject(String)
  var description: String {
    switch self {
    case .reject(let m): return m
    }
  }
}

let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
  var c = UInt32(n)
  for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
  return c
}

func crc32(_ data: Data) -> UInt32 {
  var c: UInt32 = 0xFFFF_FFFF
  for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
  return c ^ 0xFFFF_FFFF
}

func le32(_ d: Data, _ at: Int) -> UInt32 {
  d[d.startIndex + at..<d.startIndex + at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
}

func gunzip(_ gz: Data, maxSize: Int) throws -> Data {
  let d = Data(gz)
  guard d.count >= 18, d[0] == 0x1F, d[1] == 0x8B, d[2] == 8 else { throw SpikeError.reject("not gzip/deflate") }
  let flags = d[3]
  guard flags & 0xE0 == 0 else { throw SpikeError.reject("reserved gzip flags set") }
  var pos = 10
  if flags & 0x04 != 0 { pos += 2 + Int(d[pos]) | Int(d[pos + 1]) << 8 }
  if flags & 0x08 != 0 { while pos < d.count, d[pos] != 0 { pos += 1 }; pos += 1 }
  if flags & 0x10 != 0 { while pos < d.count, d[pos] != 0 { pos += 1 }; pos += 1 }
  if flags & 0x02 != 0 { pos += 2 }
  guard pos <= d.count - 8 else { throw SpikeError.reject("truncated gzip header") }
  let expectedCRC = le32(d, d.count - 8)
  let expectedSize = Int(le32(d, d.count - 4))
  guard expectedSize <= maxSize else { throw SpikeError.reject("uncompressed size over limit") }
  let deflate = d[pos..<(d.count - 8)]
  var out = Data(count: expectedSize + 1)
  let written = out.withUnsafeMutableBytes { dst in
    deflate.withUnsafeBytes { src in
      compression_decode_buffer(
        dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize + 1,
        src.bindMemory(to: UInt8.self).baseAddress!, deflate.count,
        nil, COMPRESSION_ZLIB)
    }
  }
  guard written == expectedSize else { throw SpikeError.reject("inflated \(written) bytes, gzip trailer says \(expectedSize)") }
  out.count = written
  guard crc32(out) == expectedCRC else { throw SpikeError.reject("gzip CRC32 mismatch") }
  return out
}

struct Entry { let path: String; let type: UInt8; let data: Data }

func field(_ b: Data, _ off: Int, _ len: Int) -> String {
  let slice = b[b.startIndex + off..<b.startIndex + off + len]
  let end = slice.firstIndex(of: 0) ?? slice.endIndex
  return String(decoding: slice[slice.startIndex..<end], as: UTF8.self)
}

func octal(_ b: Data, _ off: Int, _ len: Int) throws -> Int {
  let s = field(b, off, len).trimmingCharacters(in: .whitespaces)
  guard let v = Int(s.isEmpty ? "0" : s, radix: 8) else { throw SpikeError.reject("bad octal field") }
  return v
}

func untar(_ tar: Data) throws -> [Entry] {
  var entries: [Entry] = []
  var pos = 0
  while pos + 512 <= tar.count {
    let h = tar.subdata(in: pos..<pos + 512)
    if h.allSatisfy({ $0 == 0 }) { break }
    guard field(h, 257, 6) == "ustar" else { throw SpikeError.reject("not a ustar header") }
    var sum = 0
    for (i, byte) in h.enumerated() { sum += (148..<156).contains(i) ? 32 : Int(byte) }
    guard try octal(h, 148, 8) == sum else { throw SpikeError.reject("tar header checksum mismatch") }
    let name = field(h, 0, 100), prefix = field(h, 345, 155)
    let path = prefix.isEmpty ? name : prefix + "/" + name
    let size = try octal(h, 124, 12)
    let type = h[156]
    guard pos + 512 + size <= tar.count else { throw SpikeError.reject("truncated entry \(path)") }
    entries.append(Entry(path: path, type: type, data: tar.subdata(in: pos + 512..<pos + 512 + size)))
    pos += 512 + (size + 511) / 512 * 512
  }
  return entries
}

func check(_ entries: [Entry], listed: [String: String]) throws -> Int {
  var seen = Set<String>()
  for e in entries {
    if e.path.hasPrefix("/") { throw SpikeError.reject("entry \(e.path) is absolute") }
    let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
    if parts.contains("..") { throw SpikeError.reject("entry \(e.path) leaves the extraction directory") }
    switch e.type {
    case UInt8(ascii: "5"): continue
    case UInt8(ascii: "0"), 0: break
    case UInt8(ascii: "2"): throw SpikeError.reject("entry \(e.path) is a symbolic link")
    default: throw SpikeError.reject("entry \(e.path) has unsupported type \(e.type)")
    }
    guard let want = listed[e.path] else { throw SpikeError.reject("entry \(e.path) is not listed in files.json") }
    let got = SHA256.hash(data: e.data).map { String(format: "%02x", $0) }.joined()
    guard got == want else { throw SpikeError.reject("\(e.path) does not match the sha256 in files.json") }
    seen.insert(e.path)
  }
  guard seen.count == listed.count else { throw SpikeError.reject("listed files missing from the archive") }
  return seen.count
}

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "fixtures/ota")
let filesJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("files.json"))) as! [String: Any]
var listed: [String: String] = [:]
for f in filesJSON["files"] as! [[String: Any]] { listed[f["path"] as! String] = (f["sha256"] as! String) }
let index = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("index.json"))) as! [String: [String: Any]]

var failures = 0
for name in index.keys.sorted() {
  let expect = index[name]!["expect"] as! String
  let gz = try Data(contentsOf: dir.appendingPathComponent("archives").appendingPathComponent(name))
  var outcome: String
  do {
    let tar = try gunzip(gz, maxSize: 200 << 20)
    let n = try check(try untar(tar), listed: listed)
    outcome = "accept (\(n) files, \(tar.count) tar bytes)"
  } catch {
    outcome = "reject: \(error)"
  }
  let ok = expect == "accept" ? outcome.hasPrefix("accept") : outcome == expect
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name): \(outcome)")
}
exit(failures == 0 ? 0 : 1)
