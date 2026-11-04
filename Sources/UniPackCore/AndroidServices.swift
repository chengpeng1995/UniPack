import Darwin
import Foundation

public struct AndroidServiceField: Identifiable {
  public let id: String, title: String, secret: Bool
  public init(_ id: String, _ title: String, secret: Bool = false) {
    self.id = id
    self.title = title
    self.secret = secret
  }
}
public struct AndroidServiceRequirements {
  public let push: Bool, verify: Bool, map: Bool
  public let vendors: [String]
  public static let vendorFields: [String: [AndroidServiceField]] = [
    "hms": [.init("HUAWEI_APP_ID", "华为 AppID")],
    "xiaomi": [
      .init("XIAOMI_APP_ID", "小米 AppID"), .init("XIAOMI_APP_KEY", "小米 AppKey", secret: true),
    ],
    "oppo": [
      .init("OPPO_APP_KEY", "OPPO AppKey", secret: true),
      .init("OPPO_APP_SECRET", "OPPO AppSecret", secret: true),
    ],
    "vivo": [
      .init("VIVO_APP_ID", "vivo AppID"), .init("VIVO_APP_KEY", "vivo AppKey", secret: true),
    ],
    "honor": [.init("HONOR_APP_ID", "荣耀 AppID")],
    "meizu": [
      .init("MEIZU_APP_ID", "魅族 AppID"), .init("MEIZU_APP_KEY", "魅族 AppKey", secret: true),
    ],
  ]
  public static let vendorOrder = ["hms", "xiaomi", "oppo", "vivo", "honor", "meizu"]
  public var fields: [AndroidServiceField] {
    [
      .init("PUSH_APPID", "推送 AppID"), .init("GY_APP_ID", "一键登录 AppID"),
      .init("TencentMapSDK", "腾讯地图 Key", secret: true),
    ] + Self.vendorOrder.filter(vendors.contains).flatMap { Self.vendorFields[$0] ?? [] }
  }
  public var requiredKeys: Set<String> {
    Set(
      (push ? ["PUSH_APPID"] : []) + (verify ? ["GY_APP_ID"] : []) + (map ? ["TencentMapSDK"] : [])
        + vendors.flatMap { Self.vendorFields[$0]?.map(\.id) ?? [] })
  }
  public init(manifest: [String: Any], exported: [String: Any] = [:]) {
    let selection = ModuleSelection(manifest: manifest, exported: exported, platform: .android)
    let modules = selection.modules
    push = modules["uni-push"] != nil
    verify = modules["uni-verify"] != nil
    map = selection.tencentMap || selection.tencentLocation
    vendors = Array(Set((modules["uni-push"] as? [String: Any] ?? [:]).keys.map {
      $0 == "huawei" ? "hms" : $0
    })).sorted()
  }

  public func problems(_ values: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    for field in fields {
      let v = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if v.isEmpty {
        if requiredKeys.contains(field.id) { result[field.id] = "请填写" + field.title }
        continue
      }
      if v.contains("$" + "{") || (v.hasPrefix("%") && v.hasSuffix("%"))
        || ["待填写", "请填写", "替换成", "你的", "一键登录AppID", "uni-push的AppID"].contains(where: v.contains)
      {
        result[field.id] = "请替换成真实值，不能填写模板占位文字"
      } else if v.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) != nil {
        result[field.id] = "参数中不能包含空格、换行或控制字符"
      } else if ["PUSH_APPID", "GY_APP_ID"].contains(field.id), v.hasPrefix("__UNI__") {
        result[field.id] = "这里需要服务 AppID，不是项目的 DCloud AppID"
      }
    }
    for vendor in vendors where Self.vendorFields[vendor] == nil {
      result["vendor." + vendor] = "当前离线引擎尚不支持推送通道：" + vendor
    }
    return result
  }
  public func validate(_ values: [String: String]) throws {
    let issues = problems(values).filter { requiredKeys.contains($0.key) || $0.key.hasPrefix("vendor.") }
    guard issues.isEmpty else {
      let titles = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.title) })
      throw PackError(issues.keys.sorted().compactMap { key in
        issues[key].map { (titles[key].map { $0 + "：" } ?? "") + $0 }
      }.joined(separator: "；"))
    }
  }
}

public enum AndroidServices {
  public static func readFile(_ url: URL) throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PackError("模块配置文件不存在，请重新选择文件或填写可视化参数")
    }
    let data: [String: Any]
    do { data = try JSONFile.read(url) } catch { throw PackError("模块配置文件不是有效 JSON 对象，请检查文件格式") }
    guard let values = data as? [String: String] else { throw PackError("模块配置的字段和值必须都是字符串") }
    return values
  }
  /// Keep legacy/plug-in keys, but present each business AppID exactly once.
  public static func editable(
    _ source: [String: String], requirements r: AndroidServiceRequirements
  ) -> [String: String] {
    var values = source
    if values["PUSH_APPID"] == nil {
      values["PUSH_APPID"] = values["GETUI_APP_ID"] ?? (r.verify ? nil : values["GETUI_APPID"])
    }
    if r.verify, values["GY_APP_ID"] == nil { values["GY_APP_ID"] = values["GETUI_APPID"] }
    values.removeValue(forKey: "GETUI_APP_ID")
    values.removeValue(forKey: "GETUI_APPID")
    return values
  }
  public static func sourceFile(_ p: ProjectConfig) -> URL? {
    if !p.android.manifestPlaceholdersPath.isEmpty {
      return URL(fileURLWithPath: p.android.manifestPlaceholdersPath)
    }
    return [
      "nativeResources/android/manifestPlaceholders.json",
      "build-config/android/manifest-placeholders.json",
    ]
    .map { URL(fileURLWithPath: p.path).appendingPathComponent($0) }.first {
      FileManager.default.fileExists(atPath: $0.path)
    }
  }
  public static func load(_ p: ProjectConfig, requirements: AndroidServiceRequirements) throws
    -> [String: String]
  {
    if p.android.servicesManaged {
      guard let encoded = try LocalCredentialStore.password(key: p.android.servicesKey),
        let data = encoded.data(using: .utf8),
        let values = try? JSONDecoder().decode([String: String].self, from: data)
      else {
        throw PackError("此项目的本地服务参数无法读取，请重新填写或导入；不会回退到旧配置")
      }
      return values
    }
    var values: [String: String] = [:]
    if let url = sourceFile(p) { values = editable(try readFile(url), requirements: requirements) }
    let manifest = try ProjectReader.inspect(p.path).manifest
    let modules = ModuleSelection(manifest: manifest, platform: .android).modules
    if values["TencentMapSDK"] == nil {
      for module in ["uni-map", "uni-location", "uni-getLocation"] {
        if let tencent = (modules[module] as? [String: Any])?["tencent"] as? [String: Any],
          let key = tencent["appkey"] as? String ?? tencent["key"] as? String {
          values["TencentMapSDK"] = key; break
        }
      }
    }
    return values
  }
  public static func placeholders(
    _ draft: [String: String], requirements r: AndroidServiceRequirements
  ) -> [String: String] {
    var values = draft.filter { !$0.key.hasPrefix("UI_") && !["WX_UNIVERSAL_LINK", "ALIPAY_UNIVERSAL_LINK", "GETUI_APP_KEY", "GETUI_APP_SECRET"].contains($0.key) }.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.value.isEmpty
    }
    values.removeValue(forKey: "GETUI_APPID")
    values.removeValue(forKey: "GETUI_APP_ID")
    if r.push, let push = values["PUSH_APPID"] {
      values["GETUI_APP_ID"] = push
      values["GETUI_APPID"] = push
    }
    if r.verify, let verify = values["GY_APP_ID"] { values["GETUI_APPID"] = verify }
    // 已缓存但未启用的官方服务参数不进入 Gradle；其它插件自定义字段原样保留。
    let known = Set(["PUSH_APPID", "GY_APP_ID", "TencentMapSDK"]
      + AndroidServiceRequirements.vendorFields.values.flatMap { $0.map(\.id) })
    for key in known where !r.requiredKeys.contains(key) { values.removeValue(forKey: key) }
    return values
  }
  public static func generatedFile(_ id: UUID) -> URL {
    Paths.data.appendingPathComponent(
      "GeneratedConfigs/" + id.uuidString + "/android/manifest-placeholders.json")
  }
  public static func write(_ values: [String: String], to file: URL) throws {
    let parent = file.deletingLastPathComponent()
    try Paths.ensure(parent)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    let temp = parent.appendingPathComponent("." + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: temp) }
    let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw PackError("无法生成模块配置文件") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try handle.write(
        contentsOf: JSONSerialization.data(
          withJSONObject: values, options: [.prettyPrinted, .sortedKeys]))
      try handle.close()
    } catch {
      try? handle.close()
      throw PackError("写入模块配置文件失败")
    }
    guard Darwin.rename(temp.path, file.path) == 0 else { throw PackError("保存模块配置文件失败") }
  }
  public static func save(
    _ values: [String: String], project: ProjectConfig, requirements r: AndroidServiceRequirements
  ) throws {
    let data = try JSONEncoder().encode(values)
    try LocalCredentialStore.savePassword(
      String(decoding: data, as: UTF8.self), key: project.android.servicesKey)
    try write(placeholders(values, requirements: r), to: generatedFile(project.id))
  }
}

extension BuildContext {
  public func serviceDraft(project: ProjectConfig, requirements: AndroidServiceRequirements) throws
    -> [String: String]
  {
    if let moduleParameterError { throw PackError(moduleParameterError) }
    if let moduleParameters { return moduleParameters }
    return try services(project:project,platform:.android)
  }
}
