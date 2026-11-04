import Foundation

public struct DependencyReport: Codable, Sendable {
  public struct Entry: Codable, Identifiable, Sendable {
    public let category: String, name: String, reason: String
    public var id: String { category + "|" + name + "|" + reason }
    public init(_ category: String, _ name: String, _ reason: String) {
      self.category = category; self.name = name; self.reason = reason
    }
  }
  public var schemaVersion = 1
  public var platform: String, phase: String, generatedAt: String
  public var notes: [String], entries: [Entry]
  public static let filename = "dependency-report.json"
  public static func read(_ file: URL) throws -> Self {
    let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    guard result.schemaVersion == 1 else { throw PackError("依赖清单版本不受支持") }
    return result
  }
  public func save(_ file: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: file, options: .atomic)
  }
  public static func file(job: BuildJob) -> URL? {
    guard !job.logPath.isEmpty else { return nil }
    return URL(fileURLWithPath: job.logPath).deletingLastPathComponent().appendingPathComponent(filename)
  }
  public static func declarations(project: ProjectConfig, platform: BuildPlatform) throws -> Self {
    let info = try ProjectReader.inspect(project.path)
    let selection = ModuleSelection(manifest: info.manifest, platform: platform)
    var entries = selection.modules.keys.sorted().map {
      Entry("模块声明", $0, selection.origins[$0] ?? "manifest")
    }
    for (name, value) in selection.modules {
      if ["uni-map", "uni-location", "uni-getLocation", "uni-oauth", "uni-payment", "uni-share", "uni-push"].contains(name),
        let providers = value as? [String: Any] {
        entries += providers.keys.sorted().map { Entry("Provider 声明", name + " / " + $0, "manifest 显式配置") }
      }
    }
    entries += selection.ignored.keys.sorted().map { Entry("未启用", $0, selection.ignored[$0]!) }
    let sdk = platform == .ios ? project.sdkPath : project.android.sdkPath
    if !sdk.isEmpty { entries.append(Entry("SDK", URL(fileURLWithPath: sdk).lastPathComponent, "当前平台的 SDK 配置")) }
    return Self(platform: platform.rawValue, phase: "declarations", generatedAt: ISO8601DateFormatter().string(from: Date()),
      notes: ["这里只展示当前 manifest 声明，不把旧导出资源当成本次结果。", "代码自动引用的模块、实际使用的插件和传递依赖会在新资源导出后，记录到对应构建的实际清单。"], entries: entries)
  }
  public mutating func append(_ additions: [Entry], phase: String) {
    let seen = Set(entries.map(\.id)); entries += additions.filter { !seen.contains($0.id) }
    self.phase = phase
  }
  /// 读取实际归档内容及解析锁文件，不展示账号、服务参数或仓库认证 URL。
  public static func finishIOS(work: URL, app: URL, runner: ProcessRunner) throws {
    let file = work.appendingPathComponent(filename)
    var report = try read(file), additions: [Entry] = []
    let fm = FileManager.default
    let frameworks = try fm.contentsOfDirectory(at: app.appendingPathComponent("Frameworks"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "framework" }
    for bundle in frameworks {
      let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] ?? [:]
      additions.append(Entry("IPA 内嵌 Framework", bundle.lastPathComponent,
        "归档实际文件；版本 " + (info["CFBundleShortVersionString"] as? String ?? "未知")))
    }
    if let text = try? String(contentsOf: work.appendingPathComponent("Podfile.lock"), encoding: .utf8),
      let section = text.components(separatedBy: "PODS:\n").last?.components(separatedBy: "\n\n").first {
      for line in section.components(separatedBy: .newlines) where line.hasPrefix("  - ") {
        let value = String(line.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if value.range(of: #"^[A-Za-z0-9_+./-]+ \([A-Za-z0-9_.+\-]+\)$"#, options: .regularExpression) != nil {
          additions.append(Entry("CocoaPods 已解析", value, "本次 Podfile.lock，含传递依赖"))
        }
      }
    }
    let packageLocks = ["UniPackBuild.xcworkspace/xcshareddata/swiftpm/Package.resolved",
      "UniPackBuild.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
    let resolved = packageLocks.map { work.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
    if let resolved {
      let json = try JSONFile.read(resolved)
      for pin in json["pins"] as? [[String: Any]] ?? [] {
        let state = pin["state"] as? [String: Any] ?? [:]
        if let name = pin["identity"] as? String {
          additions.append(Entry("SPM 已解析", name, (state["version"] as? String ?? state["revision"] as? String ?? "已锁定")))
        }
      }
    }
    if resolved == nil && report.entries.contains(where: { $0.category == "SPM 声明" }) {
      report.notes.append("未发现 Package.resolved，SPM 仅显示声明；该部分实际版本尚未核对。")
    }
    // 包含预编译 SDK 的系统库依赖，不能仅依赖我们生成的链接参数。
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] ?? [:]
    let binaries = [app.appendingPathComponent(info["CFBundleExecutable"] as? String ?? "UniPackApp")]
      + frameworks.map { $0.appendingPathComponent($0.deletingPathExtension().lastPathComponent) }
    for binary in binaries {
      let output = try runner.run("/usr/bin/otool", ["-L", binary.path], timeout: 30).stdout
      for line in output.components(separatedBy: .newlines) {
        let path = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " (compatibility").first ?? ""
        if path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/lib/") {
          let statusQuery = path.contains("/AppTrackingTransparency.framework/")
            ? try IOSBundleIntegration.isWeakTrackingStatusQuery(binary: binary, runner: runner) : false
          additions.append(Entry("产物系统依赖", URL(fileURLWithPath: path).lastPathComponent,
            binary.lastPathComponent + (statusQuery ? " 的可选弱链接；检测到授权状态查询，未发现授权请求入口" : " 的 Mach-O 链接")))
        }
      }
    }
    report.append(additions, phase: "verified"); try report.save(file)
  }
  public static func finishAndroid(work: URL, native: URL, permissions: String, entries: String) throws {
    let file = work.appendingPathComponent(filename)
    var report = try read(file)
    let resolved = native.appendingPathComponent("resolved-dependencies.json")
    let dependencies = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: resolved))
    var additions = dependencies
    for line in permissions.components(separatedBy: .newlines) where line.hasPrefix("uses-permission") {
      if let range = line.range(of: #"name='[^']+'"#, options: .regularExpression) {
        additions.append(Entry("APK 实际权限", String(line[range].dropFirst(6).dropLast()), "aapt 读取最终 APK，包含 AAR / 插件合并结果"))
      }
    }
    for path in entries.components(separatedBy: .newlines) where path.hasPrefix("lib/") && path.hasSuffix(".so") {
      additions.append(Entry("APK 原生库", path, "最终 APK 实际文件"))
    }
    report.append(additions, phase: "verified"); try report.save(file)
  }
}
