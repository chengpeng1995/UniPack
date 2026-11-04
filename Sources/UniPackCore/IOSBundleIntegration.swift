import Foundation
import CoreFoundation
import CryptoKit

/// 校验最终应用的启动入口和实际链接内容，不能以工程中存在引用代替产物检查。
enum IOSBundleIntegration {
  private struct Requirements: Decodable {
    let schemaVersion: Int
    let resources: [String]
    let frameworks: [String]
    let classes: [String: [String]]
    let canvas: Bool
    let highRefreshRate: Bool?
    let initialPrivacyAuthorization: String?
    let resourceHashes: [String: String]
    let serviceHashes: [String: String]?
    let deviceFamilies: [Int]
    let temporaryLocationPurpose: String?
  }

  static func validate(app: URL, info: [String: Any], runner: ProcessRunner) throws {
    let fm = FileManager.default
    func fail(_ message: String) -> PackError { PackError("iOS 启动与依赖检查失败：\(message)") }
    func child(_ path: String) throws -> URL {
      let file = app.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
      guard file.path.hasPrefix(app.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
        throw fail("集成清单路径越界：\(path)")
      }
      return file
    }
    func plist(_ file: URL) throws -> [String: Any] {
      guard let data = try? Data(contentsOf: file),
        let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
      else { throw fail("无法读取 \(file.lastPathComponent)") }
      return value
    }
    for (name, key) in [("Main", "UIMainStoryboardFile"), ("LaunchScreen", "UILaunchStoryboardName")] {
      guard info[key] as? String == name else { throw fail("Info.plist 的 \(key) 必须为 \(name)") }
      let candidates = ["Base.lproj/\(name).storyboardc", "\(name).storyboardc"]
      guard let path = candidates.first(where: { fm.fileExists(atPath: app.appendingPathComponent($0).path) }) else {
        throw fail("缺少已编译的 \(name).storyboardc；不能发布会在启动时退出的包")
      }
      let storyboard = try child(path)
      let metadata = try plist(storyboard.appendingPathComponent("Info.plist"))
      guard let entry = metadata["UIStoryboardDesignatedEntryPointIdentifier"] as? String,
        !entry.isEmpty, !entry.contains("/"), !entry.contains("..")
      else { throw fail("\(name).storyboardc 未设置初始控制器") }
      let nib = storyboard.appendingPathComponent(entry + ".nib")
      guard let data = try? Data(contentsOf: nib), !data.isEmpty else {
        throw fail("\(name).storyboardc 缺少初始控制器 \(entry).nib")
      }
      if name == "Main" {
        let rootClass = "_TtC19DCloudUniappRuntime24UniAppRootViewController"
        guard data.range(of: Data(rootClass.utf8)) != nil else {
          throw fail("Main.storyboardc 的初始控制器未连接 DCloudUniappRuntime.UniAppRootViewController")
        }
      }
    }
    let manifest = app.appendingPathComponent("UniPackIntegration.json")
    guard let data = try? Data(contentsOf: manifest),
      let required = try? JSONDecoder().decode(Requirements.self, from: data), required.schemaVersion == 1
    else { throw fail("缺少有效的原生集成清单 UniPackIntegration.json，请使用新版工具重新生成工程") }
    guard let families = info["UIDeviceFamily"] as? [Int],
      !required.deviceFamilies.isEmpty, Set(families) == Set(required.deviceFamilies) else {
      throw fail("最终设备范围与本次配置不一致")
    }
    if let purpose = required.temporaryLocationPurpose {
      let actual = (info["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: Any])?["PurposeKey"] as? String
      guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, actual == purpose else {
        throw fail("缺少或改变了系统定位的临时精确定位用途说明 PurposeKey")
      }
    }
    let raw = try JSONFile.read(manifest)
    guard let privacy = raw["privacyManifests"] as? [String: [String: Any]],
      privacy["Frameworks/DCloudUTSExtAPI.framework/PrivacyInfo.xcprivacy"] != nil else {
      throw fail("缺少官方模块隐私声明快照，请重新生成工程")
    }
    for (path, expected) in privacy {
      let actual = try plist(child(path))
      guard NSDictionary(dictionary: actual).isEqual(to: expected) else {
        throw fail("隐私清单与所属模块声明不一致：\(path)")
      }
    }
    for (path, expected) in required.serviceHashes ?? [:] {
      let keys = path.components(separatedBy: ".")
      var value: Any? = info
      for key in keys { value = (value as? [String: Any])?[key] }
      guard let text = value as? String,
        SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() == expected else {
        throw fail("服务参数未正确进入最终 Info.plist：\(path)")
      }
    }
    for (path, expected) in required.resourceHashes {
      let bytes = try Data(contentsOf: child(path))
      let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      guard actual == expected else { throw fail("资源内容校验失败：\(path)") }
    }
    let refreshKey = "CADisableMinimumFrameDurationOnPhone"
    guard let enabled = info[refreshKey] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() else {
      throw fail("Info.plist 缺少布尔型 \(refreshKey)，未能确认 ProMotion 支持配置")
    }
    guard let expected = required.highRefreshRate, enabled.boolValue == expected else {
      throw fail("Info.plist 的高刷新率配置与本次集成快照不一致，请重新生成工程")
    }
    guard let appID = (info["uniapp-x"] as? [String: Any])?["appid"] as? String,
      !appID.isEmpty, !appID.contains("/"), !appID.contains("..")
    else { throw fail("隐私检查缺少合法的应用 AppID") }
    let resourceFile = try child("uni-app-x/apps/" + appID + "/www/manifest.json")
    try PrivacyConfiguration.verifyIOS(info: info, resource: JSONFile.read(resourceFile), expected: required.initialPrivacyAuthorization)
    for path in required.resources {
      let file = try child(path)
      let attrs = try? fm.attributesOfItem(atPath: file.path)
      guard attrs?[.type] as? FileAttributeType == .typeRegular else {
        throw fail("缺少 SDK 资源 \(path)")
      }
    }
    for name in required.frameworks {
      guard name.hasSuffix(".framework"), !name.contains("/") else { throw fail("无效的 Framework 名称") }
      let bundle = try child("Frameworks/" + name)
      let metadata = try plist(bundle.appendingPathComponent("Info.plist"))
      guard let executable = metadata["CFBundleExecutable"] as? String, !executable.contains("/"),
        fm.fileExists(atPath: bundle.appendingPathComponent(executable).path)
      else { throw fail("内嵌 Framework 不完整：\(name)") }
    }
    // 敏感系统库也可能被第三方预编译 Framework 引入，实际包中再次核查。
    let executable = info["CFBundleExecutable"] as? String ?? "UniPackApp"
    let embedded = try fm.contentsOfDirectory(at: app.appendingPathComponent("Frameworks"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "framework" }.map(\.lastPathComponent)
    let binaries = [executable] + embedded.map {
      "Frameworks/" + $0 + "/" + String($0.dropLast(".framework".count))
    }
    for path in binaries {
      let binary = try child(path)
      let linked = try runner.run("/usr/bin/otool", ["-L", binary.path], timeout: 30).stdout
      for (framework, key) in [("CoreBluetooth", "NSBluetoothAlwaysUsageDescription"),
        ("AppTrackingTransparency", "NSUserTrackingUsageDescription")] {
        if linked.contains("/" + framework + ".framework/"),
          (info[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          if framework == "AppTrackingTransparency", try isWeakTrackingStatusQuery(binary: binary, runner: runner) {
            continue
          }
          throw fail("\(path) 引用了 \(framework)，但主应用缺少 \(key)；请检查依赖来源或填写真实用途说明")
        }
      }
    }
    for (path, names) in required.classes where !names.isEmpty {
      let binary = try child(path)
      // 读取 Mach-O 的 ObjC 类定义；字符串出现或头文件存在不能证明静态库已链接。
      let result = try runner.run("/usr/bin/xcrun", ["dyld_info", "-objc", binary.path], timeout: 90)
      let definitions = Set(result.stdout.components(separatedBy: .newlines).compactMap { line -> String? in
        let words = line.split(whereSeparator: { $0.isWhitespace })
        guard words.count > 2, words[0] == "@interface", words[2] == ":" else { return nil }
        return String(words[1])
      })
      for name in names where !definitions.contains(name) {
        throw fail("\(path) 未链接原生实现 \(name)")
      }
    }
    if required.canvas {
      let path = try child("Frameworks/DCloudUTSExtCanvas.framework/uts-config.json")
      guard let data = try? Data(contentsOf: path),
        let registration = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let components = registration["components"] as? [[String: String]],
        components.contains(where: { $0["delegateClass"] == "UniCanvasElementRegister" })
      else { throw fail("Canvas 实现未注册 UniCanvasElementRegister") }
    }
  }
  /// 部分厂商 SDK 可选读取 ATT 状态；弱链接和授权请求不是同一件事。
  /// 授权请求入口、强链接或未知形态仍要求显式用途说明，不生成占位文案。
  static func isWeakTrackingStatusQuery(binary: URL, runner: ProcessRunner) throws -> Bool {
    let output = try runner.run("/usr/bin/otool", ["-l", binary.path], timeout: 30).stdout
    let commands = output.components(separatedBy: "Load command").filter {
      $0.contains("/AppTrackingTransparency.framework/")
    }
    guard !commands.isEmpty, commands.allSatisfy({ $0.contains("cmd LC_LOAD_WEAK_DYLIB") }) else { return false }
    let data = try Data(contentsOf: binary)
    return data.range(of: Data("trackingAuthorizationStatus".utf8)) != nil
      && data.range(of: Data("requestTrackingAuthorization".utf8)) == nil
  }

}
