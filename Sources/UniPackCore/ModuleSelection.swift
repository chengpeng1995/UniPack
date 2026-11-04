import Foundation

/// 预检、依赖预览和双端工程生成共用的模块选择规则。
public struct ModuleSelection {
  public let modules: [String: Any]
  public let origins: [String: String]
  public let ignored: [String: String]
  public init(manifest: [String: Any], exported: [String: Any] = [:], platform: BuildPlatform) {
    func nodes(_ value: [String: Any]) -> [[String: Any]] {
      let app = value["app"] as? [String: Any] ?? [:]
      let specific = value["app-" + platform.rawValue] as? [String: Any] ?? [:]
      return [app["modules"] as? [String: Any] ?? [:],
        (app["distribute"] as? [String: Any])?["modules"] as? [String: Any] ?? [:],
        (specific["distribute"] as? [String: Any])?["modules"] as? [String: Any] ?? [:]]
    }
    var result: [String: Any] = [:], sources: [String: String] = [:], excluded: [String: String] = [:]
    for (document, source) in [(exported, "HBuilderX 本次导出"), (manifest, "工程 manifest 显式声明")] {
      for node in nodes(document) {
        for (name, value) in node {
          result[name] = value
          sources[name] = sources[name].map { $0.contains(source) ? $0 : $0 + "；" + source } ?? source
        }
      }
    }
    // 空对象仍可显式启用普通模块，不能一概删除。仅 uni-map 是 provider 配置容器。
    for name in Array(result.keys) {
      if result[name] as? Bool == false {
        result.removeValue(forKey: name); excluded[name] = "配置明确关闭"
      } else if let providers = result[name] as? [String: Any],
        ["uni-map", "uni-location", "uni-getLocation", "uni-oauth", "uni-payment", "uni-share", "uni-push"].contains(name) {
        result[name] = providers.filter { $0.value as? Bool != false }
      }
    }
    if let map = result["uni-map"] as? [String: Any], map.isEmpty {
      result.removeValue(forKey: "uni-map")
      excluded["uni-map"] = "空的地图 provider 配置；未启用腾讯地图 SDK"
    }
    // 编译器识别到地图组件/API 时导出 uni-map-tencent；空 uni-map 不能覆盖它。
    if result["uni-map-tencent"] != nil {
      var providers = result["uni-map"] as? [String: Any] ?? [:]
      if providers["tencent"] == nil { providers["tencent"] = [String: Any]() }
      result["uni-map"] = providers
      sources["uni-map"] = "uni-map-tencent 需要腾讯地图 provider"
      excluded.removeValue(forKey: "uni-map")
    }
    modules = result; origins = sources.filter { result[$0.key] != nil }; ignored = excluded
  }
  public var tencentMap: Bool { (modules["uni-map"] as? [String: Any])?["tencent"] != nil }
  public var tencentLocation: Bool {
    modules["uni-location-tencent"] != nil || modules["uni-getLocation-tencent"] != nil
      || (modules["uni-location"] as? [String: Any])?["tencent"] != nil
      || (modules["uni-getLocation"] as? [String: Any])?["tencent"] != nil
  }
  public var specification: [String: Any] { ["modules": modules, "origins": origins, "ignored": ignored] }
}
