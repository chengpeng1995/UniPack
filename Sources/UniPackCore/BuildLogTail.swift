import Foundation

/// A display-only excerpt. The on-disk log stays intact regardless of file/line size.
public struct BuildLogTail: Equatable, Sendable {
  public let text: String
  public let clipped: Bool
  public static let byteLimit = 64 * 1024, lineLimit = 240, columnLimit = 800

  public static func read(_ url: URL) throws -> Self {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let end = try file.seekToEnd()
    guard end > 0 else { return Self(text: "", clipped: false) }
    let length = min(end, UInt64(byteLimit))
    try file.seek(toOffset: end - length)
    let bytes = try file.read(upToCount: Int(length)) ?? Data()
    // The beginning can split a UTF-8 code point; only discard leading continuation bytes.
    let input = end > length ? bytes.drop(while: { $0 & 0xC0 == 0x80 }) : bytes[...]
    let decoded = String(decoding: input, as: UTF8.self)
      .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var lines = decoded.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    var clipped = end > length || lines.count > lineLimit
    let visible = lines.suffix(lineLimit).map { line -> String in
      guard line.utf8.count > columnLimit, line.count > columnLimit else { return String(line) }
      clipped = true
      return String(line.prefix(columnLimit / 2)) + " … " + String(line.suffix(columnLimit / 2))
    }
    return Self(text: visible.joined(separator: "\n"), clipped: clipped)
  }
}
