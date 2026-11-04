import Foundation

/// Only allowlisted display values are exposed; credentials never enter the project summary.
public struct ManifestDisplayGroup: Identifiable, Sendable {
  public struct Item: Identifiable, Sendable {
    public let id: String, title: String, value: String
  }
  public let id: String, title: String, items: [Item]

  public static func read(_ manifest: [String: Any]) -> [Self] {
    func text(_ value: Any?) -> String {
      if let string = value as? String { return string }
      if let number = value as? NSNumber { return number.stringValue }
      if let strings = value as? [String] { return strings.joined(separator: "、") }
      return ""
    }
    func item(_ id: String, _ title: String, _ value: Any?) -> Item {
      Item(id: id, title: title, value: text(value))
    }
    let vapor = manifest["uni-app-x"] as? [String: Any] ?? [:]
    var groups = [
      Self(
        id: "app", title: "应用信息",
        items: [
          item("name", "应用名称", manifest["name"]),
          item("appid", "DCloud AppID", manifest["appid"]),
          item("versionName", "版本名称", manifest["versionName"]),
          item("versionCode", "版本号", manifest["versionCode"]),
          item("render", "渲染模式", vapor["vapor"] as? Bool == true ? "Vapor" : "未启用 Vapor"),
          item("target", "视图编译目标", vapor["vapor-render-target"] ?? "bytecode（默认）"),
          item("lang", "默认脚本语言", vapor["vapor-default-script-lang"] ?? "ts（默认）"),
          item("locale", "默认语言", manifest["locale"]),
          item("privacy", "隐私初始状态", (try? PrivacyConfiguration.read(manifest: manifest)).map { PrivacyConfiguration.description($0) } ?? "配置无效，请检查 initPrivacyAuthorization"),
        ])
    ]
    for platform in ["app-ios", "app-android"] {
      let dist = (manifest[platform] as? [String: Any])?["distribute"] as? [String: Any] ?? [:]
      let modules = dist["modules"] as? [String: Any] ?? [:]
      let ios = platform == "app-ios"
      var items =
        ios
        ? [
          item("schemes", "URL Scheme", dist["urltypes"]),
        ]
        : [
          item("minSDK", "最低 Android API", dist["minSdkVersion"]),
          item("targetSDK", "目标 Android API", dist["targetSdkVersion"]),
          item("abis", "CPU 架构", dist["abiFilters"]),
          item("schemes", "URL Scheme", dist["schemes"]),
        ]
      for module in ["uni-oauth", "uni-share", "uni-payment"] {
        let providers = modules[module] as? [String: Any] ?? [:]
        for provider in ["weixin", "wxpay"] {
          guard let config = providers[provider] as? [String: Any] else { continue }
          let title = module == "uni-oauth" ? "微信登录" : module == "uni-share" ? "微信分享" : "微信支付"
          if !text(config["appid"]).isEmpty {
            items.append(
              item(module + "." + provider + ".appid", title + " AppID", config["appid"]))
          }
          if ios, !text(config["universalLink"]).isEmpty {
            items.append(
              item(
                module + "." + provider + ".link", title + " Universal Link",
                config["universalLink"]))
          }
        }
      }
      items.append(item("modules", "已配置模块", modules.keys.sorted().joined(separator: "、")))
      groups.append(Self(id: platform, title: ios ? "iOS" : "Android", items: items))
    }
    return groups
  }
}

public struct ProjectGitInfo: Sendable {
  public let label: String
  public let trackedPaths: [String]

  /// Read HEAD directly, including worktree/submodule gitfiles. Never invoke Git or change a ref.
  public static func read(_ path: String) -> Self {
    var directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    var tracked: [String] = []
    let fm = FileManager.default
    while true {
      let marker = directory.appendingPathComponent(".git")
      tracked.append(marker.path)
      var isDirectory = ObjCBool(false)
      if fm.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
        let gitDirectory: URL
        if isDirectory.boolValue {
          gitDirectory = marker
        } else {
          guard let contents = smallText(marker), contents.hasPrefix("gitdir:") else {
            return Self(label: "Git 信息不可读", trackedPaths: tracked)
          }
          let target = String(contents.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
          guard !target.isEmpty else {
            return Self(label: "Git 信息不可读", trackedPaths: tracked)
          }
          gitDirectory = URL(fileURLWithPath: target, relativeTo: directory).standardizedFileURL
        }
        let head = gitDirectory.appendingPathComponent("HEAD")
        tracked.append(head.path)
        guard let contents = smallText(head) else {
          return Self(label: "Git 信息不可读", trackedPaths: tracked)
        }
        if contents.hasPrefix("ref: refs/heads/") {
          let branch = String(contents.dropFirst("ref: refs/heads/".count))
          return Self(label: branch.isEmpty ? "Git 信息不可读" : branch, trackedPaths: tracked)
        }
        if [40, 64].contains(contents.count),
          contents.allSatisfy({ $0.isASCII && $0.isHexDigit })
        {
          return Self(label: "游离 HEAD · " + contents.prefix(8), trackedPaths: tracked)
        }
        return Self(label: "Git 信息不可读", trackedPaths: tracked)
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return Self(label: "未使用 Git", trackedPaths: tracked)
  }

  private static func smallText(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let bytes = try? handle.read(upToCount: 4097), bytes.count <= 4096,
      let value = String(data: bytes, encoding: .utf8)
    else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
    return text
  }
}
