import Foundation

/// 在签名前及最终 IPA 校验中检查实际包内容，不改写任何已签名文件。
public enum IOSBundleMetadata {
  public static let ipadOrientations: Set<String> = [
    "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
  ]

  public static func validate(app: URL, runner: ProcessRunner = ProcessRunner()) throws {
    var failures: [String] = []
    func inspect(_ bundle: URL) throws -> [String: Any] {
      let path = bundle == app ? bundle.lastPathComponent
        : String(bundle.path.dropFirst(app.path.count + 1))
      let plist = bundle.appendingPathComponent("Info.plist")
      guard let data = try? Data(contentsOf: plist),
        let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
      else { throw PackError("无法读取 \(path)/Info.plist") }
      for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
        guard let value = info[key] as? String, !value.isEmpty else {
          failures.append("\(path)/Info.plist 缺少 \(key)")
          continue
        }
        // 兼容官方预编译 SDK 的 1.0 等版本写法；拒绝未展开变量和非数字版本。
        if value.range(of: #"^[0-9]+(?:\.[0-9]+){0,2}$"#, options: .regularExpression) == nil {
          failures.append("\(path)/Info.plist 的 \(key) 格式无效")
        }
      }
      return info
    }
    let main = try inspect(app)
    try IOSBundleIntegration.validate(app: app, info: main, runner: runner)
    let fm = FileManager.default
    var scanError: Error?
    guard let files = fm.enumerator(
      at: app, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
      errorHandler: { _, error in scanError = error; return false })
    else { throw PackError("无法检查应用内嵌 Framework") }
    for case let file as URL in files where file.pathExtension == "framework" {
      if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        _ = try inspect(file)
      }
    }
    if scanError != nil { throw PackError("无法完整读取应用内嵌 Framework，元数据检查未完成") }
    if (main["UIDeviceFamily"] as? [Int] ?? []).contains(2) {
      let fullScreen = main["UIRequiresFullScreen"] as? Bool == true
        && main["UIRequiresFullScreenIgnoredStartingWithVersion"] == nil
      let orientations = main["UISupportedInterfaceOrientations~ipad"]
        ?? main["UISupportedInterfaceOrientations"]
      let supported = Set(orientations as? [String] ?? [])
      if !fullScreen && !ipadOrientations.isSubset(of: supported) {
        failures.append(
          "\(app.lastPathComponent)/Info.plist 支持 iPad 多任务，但 UISupportedInterfaceOrientations~ipad 未包含全部四个方向")
      }
    }
    guard failures.isEmpty else {
      throw PackError("iOS 包元数据检查失败：\n" + failures.joined(separator: "\n"))
    }
  }
}
