import CoreFoundation
import Foundation

public struct BuildVersion: Codable, Equatable, Sendable {
  public let name: String
  public let code: String
  public init(name: String, code: String) {
    self.name = name
    self.code = code
  }
  public var title: String { "v\(name) · 构建号 \(code)" }

  public func validate() throws {
    guard
      name.range(
        of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
        options: .regularExpression) != nil
    else { throw PackError("版本名称请使用三段数字，例如 4.0.1") }
    guard code.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil,
      let number = Int64(code), number <= Int64(Int32.max)
    else { throw PackError("版本号需为 1–2147483647 的整数，例如 2026110412") }
  }

  public static func read(project: String) throws -> Self {
    try fromManifest(
      JSONFile.read(URL(fileURLWithPath: project).appendingPathComponent("manifest.json")))
  }
  static func fromManifest(_ document: [String: Any]) throws -> Self {
    guard document["versionName"] == nil || document["versionName"] is String else {
      throw PackError("manifest.json 的 versionName 必须是文本")
    }
    return Self(
      name: document["versionName"] as? String ?? "1.0.0",
      code: try scalarCode(document["versionCode"]) ?? "1")
  }
  private static func scalarCode(_ value: Any?) throws -> String? {
    guard let value else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      return number.stringValue
    }
    throw PackError("版本号必须是整数或整数字符串")
  }
  public func verifyResource(_ document: [String: Any]) throws {
    guard let version = document["version"] as? [String: Any],
      version["name"] as? String == name, try Self.scalarCode(version["code"]) == code
    else { throw PackError("包内资源版本与本次构建不一致，预期 \(title)；请重新导出资源") }
  }
  public func verifyIOS(_ info: [String: Any]) throws {
    guard info["CFBundleShortVersionString"] as? String == name,
      info["CFBundleVersion"] as? String == code
    else { throw PackError("IPA 的版本信息与本次构建不一致，预期 \(title)") }
  }
  public func verifyAndroid(_ badging: String) throws {
    let package =
      badging.components(separatedBy: .newlines).first { $0.hasPrefix("package:") } ?? ""
    guard package.contains("versionName='\(name)'"), package.contains("versionCode='\(code)'")
    else {
      throw PackError("APK 的版本信息与本次构建不一致，预期 \(title)")
    }
  }
}

public enum ManifestVersionStore {
  public static func save(_ version: BuildVersion, project: String, expected: BuildVersion) throws {
    try version.validate()
    // 与两个平台的原生构建互斥，其他项目不受影响。
    let ios = try BuildLease(project: project, platform: .ios)
    defer { ios.release() }
    let android = try BuildLease(project: project, platform: .android)
    defer { android.release() }
    let file = URL(fileURLWithPath: project).appendingPathComponent("manifest.json")
      .resolvingSymlinksInPath()
    var coordinationError: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) {
      url in
      do {
        let original = try Data(contentsOf: url)
        guard let text = String(data: original, encoding: .utf8) else {
          throw PackError("manifest.json 不是 UTF-8 文本")
        }
        let document = try JSONFile.parse(text, label: "manifest.json")
        guard try BuildVersion.fromManifest(document) == expected else {
          throw PackError("工程版本已被其他编辑器修改，请重新读取后再保存，避免覆盖外部改动")
        }
        if version == expected { return }
        let updated = try ManifestVersionEditor.replacing(
          text, version: version, document: document)
        guard
          try BuildVersion.fromManifest(JSONFile.parse(updated, label: "manifest.json")) == version
        else {
          throw PackError("版本写入校验失败，原文件未修改")
        }
        guard try Data(contentsOf: url) == original else {
          throw PackError("manifest.json 在保存期间发生变化，请重试")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try Data(updated.utf8).write(to: url, options: .atomic)
        if let mode = attributes[.posixPermissions] {
          try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
      } catch { failure = error }
    }
    if let failure { throw failure }
    if let coordinationError { throw coordinationError }
  }
}

/// 只替换根节点的两个标量值；不重新序列化整个 JSONC，不丢弃注释、缩进或其他配置。
private struct ManifestVersionEditor {
  struct Property { let key: String, keyStart: Int, value: Range<Int> }
  var bytes: [UInt8]
  var index = 0

  static func replacing(_ text: String, version: BuildVersion, document: [String: Any]) throws
    -> String
  {
    var parser = Self(bytes: Array(text.utf8))
    let result = try parser.properties()
    let quotedName = Array(try JSONEncoder().encode(version.name))
    let code =
      document["versionCode"] is String
      ? Array(try JSONEncoder().encode(version.code)) : Array(version.code.utf8)
    let values = [("versionName", quotedName), ("versionCode", code)]
    var edits: [(Range<Int>, [UInt8])] = []
    var additions: [String] = []
    for (key, value) in values {
      let matches = result.items.filter { $0.key == key }
      guard matches.count <= 1 else { throw PackError("manifest.json 存在重复的 \(key)，请先整理该字段") }
      if let match = matches.first {
        edits.append((match.value, value))
      } else {
        additions.append("\"\(key)\": " + String(decoding: value, as: UTF8.self))
      }
    }
    if !additions.isEmpty {
      let newline = text.contains("\r\n") ? "\r\n" : "\n"
      var indent = "  "
      if let first = result.items.first {
        let prefix =
          String(decoding: parser.bytes[..<first.keyStart], as: UTF8.self)
          .components(separatedBy: "\n").last ?? ""
        if !prefix.isEmpty, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) { indent = prefix }
      }
      if let last = result.items.last, !result.trailingComma {
        edits.append((last.value.upperBound..<last.value.upperBound, Array(",".utf8)))
      }
      let addition =
        newline + indent + additions.joined(separator: "," + newline + indent) + newline
      edits.append((result.close..<result.close, Array(addition.utf8)))
    }
    let ordered = edits.enumerated().sorted {
      if $0.element.0.lowerBound == $1.element.0.lowerBound { return $0.offset > $1.offset }
      return $0.element.0.lowerBound > $1.element.0.lowerBound
    }
    for edit in ordered { parser.bytes.replaceSubrange(edit.element.0, with: edit.element.1) }
    return String(decoding: parser.bytes, as: UTF8.self)
  }

  mutating func properties() throws -> (items: [Property], close: Int, trailingComma: Bool) {
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    try trivia()
    guard index < bytes.count, bytes[index] == 123 else {
      throw PackError("manifest.json 根节点必须为对象")
    }
    index += 1
    var items: [Property] = []
    var trailing = false
    while true {
      try trivia()
      guard index < bytes.count else { throw PackError("manifest.json 对象未结束") }
      if bytes[index] == 125 { return (items, index, trailing) }
      let keyStart = index
      try string()
      let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<index]))
      try trivia()
      guard index < bytes.count, bytes[index] == 58 else { throw PackError("manifest.json 字段缺少冒号") }
      index += 1
      try trivia()
      let start = index
      try value()
      items.append(Property(key: key, keyStart: keyStart, value: start..<index))
      try trivia()
      guard index < bytes.count else { throw PackError("manifest.json 对象未结束") }
      if bytes[index] == 44 {
        trailing = true
        index += 1
      } else if bytes[index] == 125 {
        return (items, index, false)
      } else {
        throw PackError("manifest.json 字段分隔符无效")
      }
    }
  }
  mutating func trivia() throws {
    while index < bytes.count {
      if [9, 10, 13, 32].contains(bytes[index]) {
        index += 1
        continue
      }
      if index + 1 < bytes.count, bytes[index] == 47 {
        if bytes[index + 1] == 47 {
          index += 2
          while index < bytes.count && ![10, 13].contains(bytes[index]) { index += 1 }
          continue
        }
        if bytes[index + 1] == 42 {
          index += 2
          while index + 1 < bytes.count && !(bytes[index] == 42 && bytes[index + 1] == 47) {
            index += 1
          }
          guard index + 1 < bytes.count else { throw PackError("manifest.json 注释未结束") }
          index += 2
          continue
        }
      }
      break
    }
  }
  mutating func string() throws {
    guard index < bytes.count, bytes[index] == 34 else { throw PackError("manifest.json 字段名无效") }
    index += 1
    while index < bytes.count {
      if bytes[index] == 92 {
        index += 2
      } else if bytes[index] == 34 {
        index += 1
        return
      } else {
        index += 1
      }
    }
    throw PackError("manifest.json 字符串未结束")
  }
  mutating func value() throws {
    guard index < bytes.count else { throw PackError("manifest.json 字段值缺失") }
    if bytes[index] == 34 {
      try string()
      return
    }
    if [91, 123].contains(bytes[index]) {
      var depth = 0
      repeat {
        try trivia()
        guard index < bytes.count else { throw PackError("manifest.json 字段值未结束") }
        if bytes[index] == 34 {
          try string()
          continue
        }
        if [91, 123].contains(bytes[index]) { depth += 1 }
        if [93, 125].contains(bytes[index]) { depth -= 1 }
        index += 1
      } while depth > 0
      return
    }
    let start = index
    while index < bytes.count && ![9, 10, 13, 32, 44, 47, 93, 125].contains(bytes[index]) {
      index += 1
    }
    guard index > start else { throw PackError("manifest.json 字段值无效") }
  }
}
