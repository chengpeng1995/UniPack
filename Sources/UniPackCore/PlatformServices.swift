import Foundation

public struct ServiceField: Identifiable {
  public enum Kind { case text, secret, url, file, prose, choice([(String, String)]) }
  public let id: String, title: String, hint: String, kind: Kind, required: Bool
  public init(_ id: String, _ title: String, _ hint: String = "", kind: Kind = .text, required: Bool = false) {
    self.id = id; self.title = title; self.hint = hint; self.kind = kind; self.required = required
  }
}
public struct ServiceGroup: Identifiable {
  public let id: String, title: String, note: String, fields: [ServiceField], advanced: Bool
  public init(_ id: String, _ title: String, _ note: String = "", _ fields: [ServiceField], advanced: Bool = false) {
    self.id = id; self.title = title; self.note = note; self.fields = fields; self.advanced = advanced
  }
}
public struct PlatformServiceRequirements {
  public let platform: BuildPlatform, selection: ModuleSelection, groups: [ServiceGroup]
  public var fields: [ServiceField] { groups.flatMap(\.fields) }
  public var requiredKeys: Set<String> { Set(fields.filter(\.required).map(\.id)) }
  public var push: Bool { selection.modules["uni-push"] != nil }
  public var verify: Bool { selection.modules["uni-verify"] != nil }
  public var wechat: Bool { Self.hasWechat(selection) }
  public var alipay: Bool { (selection.modules["uni-payment"] as? [String: Any])?["alipay"] != nil }
  public var huawei: Bool { platform == .android && AndroidServiceRequirements(manifest: ["app-android": ["distribute": ["modules": selection.modules]]]).vendors.contains("hms") }
  static func hasWechat(_ s: ModuleSelection) -> Bool {
    [("uni-oauth", "weixin"), ("uni-share", "weixin"), ("uni-payment", "wxpay")].contains {
      (s.modules[$0.0] as? [String: Any])?[$0.1] != nil
    }
  }
  public init(manifest: [String: Any], exported: [String: Any] = [:], platform: BuildPlatform) {
    self.platform = platform
    let s = ModuleSelection(manifest: manifest, exported: exported, platform: platform); selection = s
    let ios = platform == .ios
    var result: [ServiceGroup] = []
    if s.modules["uni-push"] != nil {
      var fields = [ServiceField("PUSH_APPID", "推送 AppID", "DCloud / 个推应用配置中的 AppID", required: true)]
      if ios {
        fields += [.init("GETUI_APP_KEY", "个推 AppKey", "客户端 AppKey", kind: .secret, required: true),
          .init("GETUI_APP_SECRET", "个推 AppSecret", "客户端 AppSecret，不是 MasterSecret", kind: .secret, required: true)]
      } else {
        fields += [.init("UI_AUTO_NOTIFICATION", "透传消息通知", kind: .choice([("true", "自动创建通知"), ("false", "交由应用处理")]))]
      }
      result.append(.init("push", "推送通知", "DCloud / 个推应用配置", fields))
    }
    if s.modules["uni-verify"] != nil {
      result.append(.init("verify", "一键登录", "DCloud 一键登录基础配置", [.init("GY_APP_ID", "一键登录 AppID", "DCloud 一键登录基础配置中的应用 ID", required: true)]))
    }
    if Self.hasWechat(s) {
      var fields = [ServiceField("WX_APPID", "微信 AppID", "微信开放平台移动应用 AppID", required: true)]
      if ios { fields.append(.init("WX_UNIVERSAL_LINK", "Universal Link", "https://…/", kind: .url, required: true)) }
      result.append(.init("wechat", "微信", "登录、分享和支付共用同一应用身份", fields))
    }
    if ios, (s.modules["uni-payment"] as? [String: Any])?["alipay"] != nil {
      result.append(.init("alipay", "支付宝回调", "Scheme 自动生成，可按业务需要调整", [
        .init("UI_ALIPAY_SCHEME", "回调 Scheme", "留空使用自动生成值"),
        .init("ALIPAY_UNIVERSAL_LINK", "Universal Link", "可选 · https://…/", kind: .url)]))
    }
    if s.tencentMap || s.tencentLocation {
      result.append(.init("tencent", "腾讯位置服务", "仅已启用的腾讯地图 / 定位使用此 Key", [
        .init("TencentMapSDK", "腾讯位置服务 Key", "与当前平台包名绑定的 Key", kind: .secret, required: true)]))
    }
    if !ios {
      let r = AndroidServiceRequirements(manifest: manifest, exported: exported)
      let names = ["hms": "华为", "xiaomi": "小米", "oppo": "OPPO", "vivo": "vivo", "honor": "荣耀", "meizu": "魅族"]
      for vendor in AndroidServiceRequirements.vendorOrder where r.vendors.contains(vendor) {
        var fields = (AndroidServiceRequirements.vendorFields[vendor] ?? []).map { ServiceField($0.id, $0.title, "来自厂商应用配置", kind: $0.secret ? .secret : .text, required: true) }
        if vendor == "hms" { fields.append(.init("UI_AGCONNECT_FILE", "华为配置文件", "选择 agconnect-services.json", kind: .file, required: true)) }
        result.append(.init("vendor." + vendor, (names[vendor] ?? vendor) + "推送", "已在 manifest 启用", fields))
      }
    }
    var callbacks = [ServiceField("UI_SCHEMES", "应用 URL Scheme", "多个值使用逗号或换行分隔", kind: .prose)]
    if ios { callbacks.append(.init("UI_DOMAINS", "额外关联域名", "applinks:example.com；微信和支付宝域名自动补齐", kind: .prose)) }
    result.append(.init("callbacks", "回调与关联", "自动读取工程，填写后在本次打包中生效", callbacks, advanced: true))
    if ios {
      result.append(.init("display", "隐私与设备", "按当前项目保存", [
        .init("UI_DEVICES", "支持设备", kind: .choice([("iphone", "iPhone"), ("ipad", "iPad"), ("universal", "iPhone + iPad")])),
        .init("UI_HIGH_REFRESH", "高刷新率", kind: .choice([("true", "开启"), ("false", "关闭")])),
        .init("UI_PRIVACY", "首次隐私状态", kind: .choice([("disagree", "未同意"), ("agree", "已同意"), ("auto", "跟随平台")]))
      ], advanced: true))
      let dist = (manifest["app-ios"] as? [String: Any])?["distribute"] as? [String: Any] ?? [:]
      let original = dist["privacyDescription"] as? [String: Any] ?? [:]
      let titles = ["NSCameraUsageDescription": "相机用途", "NSMicrophoneUsageDescription": "麦克风用途", "NSPhotoLibraryUsageDescription": "相册读取用途", "NSPhotoLibraryAddUsageDescription": "相册保存用途", "NSLocationWhenInUseUsageDescription": "前台定位用途", "NSLocationAlwaysUsageDescription": "始终定位用途", "NSLocationAlwaysAndWhenInUseUsageDescription": "后台定位用途", "NSUserNotificationsUsageDescription": "通知用途"]
      var keys = Set(original.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") })
      if s.modules["uni-push"] != nil { keys.insert("NSUserNotificationsUsageDescription") }
      if s.modules["uni-location"] != nil || s.modules["uni-getLocation"] != nil || s.tencentMap { keys.insert("NSLocationWhenInUseUsageDescription") }
      var fields = keys.sorted().map { ServiceField("UI_USAGE_" + $0, titles[$0] ?? $0, "说明此应用使用该权限的实际场景", kind: .prose) }
      if keys.contains("NSLocationWhenInUseUsageDescription") { fields.append(.init("UI_LOCATION_PURPOSE", "临时精确定位用途", "留空沿用前台定位用途", kind: .prose)) }
      if !fields.isEmpty { result.append(.init("purposes", "权限用途说明", "仅配置项目使用的权限；文案不会开启相应模块", fields, advanced: true)) }
    }
    groups = result
  }
  public func problems(_ values: [String: String], required: Bool = true) -> [String: String] {
    var issues: [String: String] = [:]
    for field in fields {
      let v = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if v.isEmpty { if required && field.required { issues[field.id] = "请填写" + field.title }; continue }
      switch field.kind {
      case .url:
        if let u = URL(string: v), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil {} else { issues[field.id] = "请填写完整的 HTTPS 链接" }
      case .prose, .file: break
      case .choice(let choices): if !choices.contains(where: { $0.0 == v }) { issues[field.id] = "请选择有效选项" }
      default:
        if v.contains("${") || v.contains("%") || v.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) != nil { issues[field.id] = "不能包含占位符、空格或换行" }
      }
      if ["PUSH_APPID", "GY_APP_ID"].contains(field.id), v.hasPrefix("__UNI__") { issues[field.id] = "这里填写服务 AppID，不是 DCloud 项目 AppID" }
      if field.id == "WX_APPID", v.range(of: "^wx[A-Za-z0-9]+$", options: .regularExpression) == nil { issues[field.id] = "微信移动应用 AppID 应以 wx 开头" }
    }
    for key in ["UI_SCHEMES", "UI_ALIPAY_SCHEME"] where fields.contains(where: { $0.id == key }) {
      if PlatformServices.list(values[key]).contains(where: { $0.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) == nil }) { issues[key] = "Scheme 仅填写名称，不包含 :// 或路径" }
    }
    if PlatformServices.list(values["UI_ALIPAY_SCHEME"]).count > 1 { issues["UI_ALIPAY_SCHEME"] = "支付宝回调只填写一个 Scheme" }
    if platform == .ios, PlatformServices.list(values["UI_DOMAINS"]).contains(where: { value in
      let parts = value.split(separator: ":", maxSplits: 1)
      return parts.count != 2 || !["applinks", "webcredentials", "activitycontinuation"].contains(String(parts[0])) || parts[1].contains("/") || parts[1].contains(" ")
    }) { issues["UI_DOMAINS"] = "请按 applinks:example.com 格式填写，每行一项" }
    if wechat, values["UI_SOURCE_WECHAT_CONFLICT"] == "true" { issues["WX_APPID"] = "工程中微信参数存在冲突，请在界面确认要使用的配置" }
    return issues
  }
  public func validate(_ values: [String: String]) throws {
    var issues = problems(values)
    if platform == .android {
      let r = AndroidServiceRequirements(manifest: ["app-android": ["distribute": ["modules": selection.modules]]])
      for (key, value) in r.problems(values) where key.hasPrefix("vendor.") { issues[key] = value }
    }
    guard issues.isEmpty else {
      let names = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.title) })
      throw PackError(platform.title + " 服务配置：" + issues.keys.sorted().map { (names[$0] ?? $0) + "：" + issues[$0]! }.joined(separator: "；"))
    }
  }
}

public enum PlatformServices {
  public static func list(_ value: String?) -> [String] {
    (value ?? "").components(separatedBy: CharacterSet(charactersIn: ",，\n\r")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }
  static func string(_ value: Any?) -> String { if let v = value as? String { return v }; if let v = value as? NSNumber { return v.stringValue }; return "" }
  public static func managed(_ project: ProjectConfig, _ platform: BuildPlatform) -> Bool { platform == .ios ? project.iosServicesManaged : project.android.servicesManaged }
  static func key(_ project: ProjectConfig, _ platform: BuildPlatform) -> String { platform == .ios ? project.iosServicesKey : project.android.servicesKey }
  public static func sourceValues(project: ProjectConfig, platform: BuildPlatform) throws -> [String: String] {
    let manifest = try ProjectReader.inspect(project.path).manifest
    let s = ModuleSelection(manifest: manifest, platform: platform)
    let dist = (manifest["app-" + platform.rawValue] as? [String: Any])?["distribute"] as? [String: Any] ?? [:]
    var v: [String: String] = [:]
    var info: [String: Any] = [:]
    if platform == .ios {
      let file = URL(fileURLWithPath: project.path).appendingPathComponent("Info.plist")
      if FileManager.default.fileExists(atPath: file.path) { info = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] ?? [:] }
      let push = info["getui"] as? [String: Any] ?? [:]
      v["PUSH_APPID"] = string(push["appid"]); v["GETUI_APP_KEY"] = string(push["appKey"]); v["GETUI_APP_SECRET"] = string(push["appSecret"])
      v["GY_APP_ID"] = string((info["geyan"] as? [String: Any])?["appid"])
      v["TencentMapSDK"] = string(info["TencentLBSAPIKey"])
      v["UI_DEVICES"] = string(dist["devices"]); if v["UI_DEVICES"]?.isEmpty != false || v["UI_DEVICES"] == "auto" { v["UI_DEVICES"] = "iphone" }
      if dist["devices"] == nil, let family = info["UIDeviceFamily"] as? [Int] { v["UI_DEVICES"] = family.contains(1) && family.contains(2) ? "universal" : family.contains(2) ? "ipad" : "iphone" }
      v["UI_HIGH_REFRESH"] = (info["CADisableMinimumFrameDurationOnPhone"] as? Bool ?? true) ? "true" : "false"
      v["UI_PRIVACY"] = try PrivacyConfiguration.read(manifest: manifest)
      let entitlements = (dist["capabilities"] as? [String: Any])?["entitlements"] as? [String: Any] ?? [:]
      v["UI_DOMAINS"] = (entitlements["com.apple.developer.associated-domains"] as? [String] ?? []).joined(separator: "\n")
      let descriptions = dist["privacyDescription"] as? [String: Any] ?? [:]
      for (k, value) in info.merging(descriptions, uniquingKeysWith: { _, newer in newer }) where k.hasPrefix("NS") && k.hasSuffix("UsageDescription") { v["UI_USAGE_" + k] = string(value) }
      v["UI_LOCATION_PURPOSE"] = string((descriptions["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: Any])?["PurposeKey"] ?? (info["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: Any])?["PurposeKey"])
      if let alipay = info["Alipay"] as? [String: Any] { v["ALIPAY_UNIVERSAL_LINK"] = string(alipay["universalLink"]) }
      if let wechat = info["WeChat"] as? [String: Any] { v["WX_APPID"] = string(wechat["appid"]); v["WX_UNIVERSAL_LINK"] = string(wechat["universalLink"]) }
      for t in info["CFBundleURLTypes"] as? [[String: Any]] ?? [] where (t["CFBundleURLName"] as? String)?.lowercased() == "alipay" { v["UI_ALIPAY_SCHEME"] = (t["CFBundleURLSchemes"] as? [String])?.first }
    } else {
      if let file = AndroidServices.sourceFile(project) { v = AndroidServices.editable(try AndroidServices.readFile(file), requirements: AndroidServiceRequirements(manifest: manifest)) }
      v["UI_AUTO_NOTIFICATION"] = v["dcloud_unipush_auto_notification"] ?? "true"
      let resource = URL(fileURLWithPath: project.path).appendingPathComponent("nativeResources/android/res/values/motor_push.xml")
      if let text = try? String(contentsOf: resource, encoding: .utf8), let range = text.range(of: #"(?<=name="motor_push_auto_notification">)\s*(true|false)\s*(?=</bool>)"#, options: .regularExpression) { v["UI_AUTO_NOTIFICATION"] = text[range].trimmingCharacters(in: .whitespacesAndNewlines) }
      for name in ["nativeResources/android/agconnect-services.json", "agconnect-services.json", "build-config/android/agconnect-services.json"] {
        let file = URL(fileURLWithPath: project.path).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { v["UI_AGCONNECT_FILE"] = file.path; break }
      }
    }
    v["UI_SCHEMES"] = (dist[platform == .ios ? "urltypes" : "schemes"] as? [String])?.joined(separator: "\n") ?? string(dist[platform == .ios ? "urltypes" : "schemes"])
    for (module, provider) in [("uni-oauth", "weixin"), ("uni-share", "weixin"), ("uni-payment", "wxpay")] {
      if let config = (s.modules[module] as? [String: Any])?[provider] as? [String: Any] {
        for (field, key) in [("WX_APPID", "appid"), ("WX_UNIVERSAL_LINK", "universalLink")] where !string(config[key]).isEmpty {
          let next = string(config[key]); if let previous = v[field], !previous.isEmpty, previous != next { v["UI_SOURCE_WECHAT_CONFLICT"] = "true" }; v[field] = next
        }
      }
    }
    if let config = (s.modules["uni-payment"] as? [String: Any])?["alipay"] as? [String: Any], let value = config["universalLink"] as? String { v["ALIPAY_UNIVERSAL_LINK"] = value }
    for name in ["uni-map", "uni-location", "uni-getLocation"] {
      if let config = (s.modules[name] as? [String: Any])?["tencent"] as? [String: Any] { v["TencentMapSDK"] = string(config["key"] ?? config["appkey"]) }
    }
    if platform == .ios {
      let wx = v["WX_APPID"] ?? ""
      let originalSchemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).filter { ($0["CFBundleURLName"] as? String)?.lowercased() != "alipay" }.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
      v["UI_SCHEMES"] = Array(Set(list(v["UI_SCHEMES"]) + originalSchemes)).filter { $0 != wx }.sorted().joined(separator: "\n")
      let automaticDomains = Set(["WX_UNIVERSAL_LINK", "ALIPAY_UNIVERSAL_LINK"].compactMap { key -> String? in guard let value = v[key], let host = URL(string: value)?.host else { return nil }; return "applinks:" + host })
      v["UI_DOMAINS"] = list(v["UI_DOMAINS"]).filter { !automaticDomains.contains($0) }.joined(separator: "\n")
    }
    return v
  }
  public static func load(project: ProjectConfig, platform: BuildPlatform) throws -> [String: String] {
    if managed(project, platform) {
      guard let text = try LocalCredentialStore.password(key: key(project, platform)), let data = text.data(using: .utf8), let values = try? JSONDecoder().decode([String: String].self, from: data) else { throw PackError("本机服务配置无法读取，请重新导入；不会回退到旧参数") }
      // 旧 Android 草稿没有新增字段；升级时仅补充缺少的键，显式空值仍表示用户清空。
      if platform == .android, values["UI_SCHEMES"] == nil { return try sourceValues(project: project, platform: platform).merging(values, uniquingKeysWith: { _, saved in saved }) }
      return values
    }
    return try sourceValues(project: project, platform: platform)
  }
  public static func save(_ values: [String: String], project: ProjectConfig, platform: BuildPlatform) throws {
    let data = try JSONEncoder().encode(values)
    try LocalCredentialStore.savePassword(String(decoding: data, as: UTF8.self), key: key(project, platform))
  }
  public static func applied(_ values: [String: String], manifest: [String: Any], requirements r: PlatformServiceRequirements) -> [String: Any] {
    var result = manifest, node = manifest["app-" + r.platform.rawValue] as? [String: Any] ?? [:]
    var dist = node["distribute"] as? [String: Any] ?? [:], modules = r.selection.modules
    if r.wechat {
      for (module, provider) in [("uni-oauth", "weixin"), ("uni-share", "weixin"), ("uni-payment", "wxpay")] {
        guard var providers = modules[module] as? [String: Any], var config = providers[provider] as? [String: Any] else { continue }
        config["appid"] = values["WX_APPID"] ?? ""
        if r.platform == .ios { config["universalLink"] = values["WX_UNIVERSAL_LINK"] ?? "" }
        providers[provider] = config; modules[module] = providers
      }
    }
    dist["modules"] = modules
    dist[r.platform == .ios ? "urltypes" : "schemes"] = list(values["UI_SCHEMES"])
    if r.platform == .ios {
      dist["devices"] = values["UI_DEVICES"] ?? "iphone"
      var cap = dist["capabilities"] as? [String: Any] ?? [:], ent = cap["entitlements"] as? [String: Any] ?? [:]
      var domains = list(values["UI_DOMAINS"])
      for key in [r.wechat ? "WX_UNIVERSAL_LINK" : "", r.alipay ? "ALIPAY_UNIVERSAL_LINK" : ""] {
        if let value = values[key], let host = URL(string: value)?.host { let entry = "applinks:" + host; if !domains.contains(entry) { domains.append(entry) } }
      }
      if domains.isEmpty { ent.removeValue(forKey: "com.apple.developer.associated-domains") } else { ent["com.apple.developer.associated-domains"] = domains }; cap["entitlements"] = ent; dist["capabilities"] = cap
      var descriptions = dist["privacyDescription"] as? [String: Any] ?? [:]
      for field in r.fields where field.id.hasPrefix("UI_USAGE_") { descriptions[String(field.id.dropFirst(9))] = values[field.id] ?? "" }
      if r.fields.contains(where: { $0.id == "UI_LOCATION_PURPOSE" }) {
        var purposes = descriptions["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: Any] ?? [:]
        let explicit = values["UI_LOCATION_PURPOSE"] ?? ""
        purposes["PurposeKey"] = explicit.isEmpty ? values["UI_USAGE_NSLocationWhenInUseUsageDescription"] ?? "" : explicit
        descriptions["NSLocationTemporaryUsageDescriptionDictionary"] = purposes
      }
      dist["privacyDescription"] = descriptions
      var app = result["app"] as? [String: Any] ?? [:]; app["initPrivacyAuthorization"] = values["UI_PRIVACY"] ?? "auto"; result["app"] = app
    }
    node["distribute"] = dist; result["app-" + r.platform.rawValue] = node
    return result
  }
  public static func iosOverrides(_ values: [String: String], requirements r: PlatformServiceRequirements) -> [String: Any] {
    var plist: [String: Any] = ["CADisableMinimumFrameDurationOnPhone": values["UI_HIGH_REFRESH"] != "false"]
    if r.push { plist["getui"] = ["appid": values["PUSH_APPID"] ?? "", "appKey": values["GETUI_APP_KEY"] ?? "", "appSecret": values["GETUI_APP_SECRET"] ?? ""] }
    if r.verify { plist["geyan"] = ["appid": values["GY_APP_ID"] ?? ""] }
    if r.wechat { plist["WeChat"] = ["appid": values["WX_APPID"] ?? "", "universalLink": values["WX_UNIVERSAL_LINK"] ?? ""] }
    if r.alipay, let link = values["ALIPAY_UNIVERSAL_LINK"], !link.isEmpty { plist["Alipay"] = ["universalLink": link] }
    if r.selection.tencentMap || r.selection.tencentLocation { plist["TencentLBSAPIKey"] = values["TencentMapSDK"] ?? "" }
    var document: [String: Any] = ["plist": plist, "alipayScheme": r.alipay ? values["UI_ALIPAY_SCHEME"] ?? "" : ""]
    if r.fields.contains(where: { $0.id == "UI_LOCATION_PURPOSE" }) { document["locationPurpose"] = values["UI_LOCATION_PURPOSE"] ?? "" }
    return document
  }
  public static func importValues(from file: URL, project: ProjectConfig, platform: BuildPlatform) throws -> [String: String] {
    guard let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, count <= 2_000_000 else { throw PackError("配置文件过大或无法读取") }
    let data = try Data(contentsOf: file)
    let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
      ?? (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    guard let root = raw else { throw PackError("请选择有效的 Info.plist 或服务参数 JSON") }
    let r = PlatformServiceRequirements(manifest: try ProjectReader.inspect(project.path).manifest, platform: platform)
    let allowed = Set(r.fields.map(\.id))
    var values: [String: String] = [:]
    if platform == .ios {
      if let bundle = root["CFBundleIdentifier"] as? String, !bundle.contains("$("), !project.bundleID.isEmpty, bundle != project.bundleID { throw PackError("导入配置的 Bundle ID 与当前项目不一致") }
      let mappings = [("getui", "appid", "PUSH_APPID"), ("getui", "appKey", "GETUI_APP_KEY"), ("getui", "appSecret", "GETUI_APP_SECRET"), ("geyan", "appid", "GY_APP_ID"), ("WeChat", "appid", "WX_APPID"), ("WeChat", "universalLink", "WX_UNIVERSAL_LINK"), ("Alipay", "universalLink", "ALIPAY_UNIVERSAL_LINK")]
      for (node, key, field) in mappings { if let value = (root[node] as? [String: Any])?[key] { values[field] = string(value) } }
      if let value = root["TencentLBSAPIKey"] { values["TencentMapSDK"] = string(value) }
    } else if let client = root["client"] as? [String: Any], r.huawei {
      values["HUAWEI_APP_ID"] = string(client["app_id"]); values["UI_AGCONNECT_FILE"] = file.path
      if !project.android.applicationID.isEmpty { _ = try huaweiDocument(values, bundle: project.android.applicationID) }
    } else if let flat = root as? [String: String] {
      values = AndroidServices.editable(flat, requirements: AndroidServiceRequirements(manifest: try ProjectReader.inspect(project.path).manifest))
    }
    for (key, value) in root where allowed.contains(key) { values[key] = string(value) }
    if let flag = values["dcloud_unipush_auto_notification"], r.push { values["UI_AUTO_NOTIFICATION"] = flag }
    if platform == .ios { values = values.filter { allowed.contains($0.key) } }
    guard !values.isEmpty else { throw PackError("文件没有当前平台已启用服务的参数") }
    return values
  }
  static func redactions(_ values: [String: String], document: Data? = nil) -> [String] {
    var result = values.filter { !$0.key.hasPrefix("UI_") }.map(\.value)
    func scan(_ node: Any) {
      if let d = node as? [String: Any] {
        for (k, v) in d {
          if ["secret", "token", "key"].contains(where: k.lowercased().contains), let text = v as? String { result.append(text) }
          else { scan(v) }
        }
      } else if let a = node as? [Any] { a.forEach(scan) }
    }
    if let document, let json = try? JSONSerialization.jsonObject(with: document) { scan(json) }
    return result.filter { !$0.isEmpty }
  }
  public static func huaweiDocument(_ values: [String: String], bundle: String) throws -> Data {
    let path = values["UI_AGCONNECT_FILE"] ?? ""
    guard !path.isEmpty else { throw PackError("请在 Android → 华为推送中选择 agconnect-services.json") }
    let file = URL(fileURLWithPath: path)
    guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else { throw PackError("华为配置文件过大或无法读取") }
    let bytes = try Data(contentsOf: file)
    let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
    let client = json["client"] as? [String: Any] ?? [:]
    guard string(client["package_name"]) == bundle else { throw PackError("华为配置文件的包名与当前 Android 应用包名不一致") }
    guard !string(client["app_id"]).isEmpty, string(client["app_id"]) == values["HUAWEI_APP_ID"] else { throw PackError("华为配置文件的 AppID 与填写的华为 AppID 不一致") }
    return bytes
  }
}

extension BuildContext {
  public func services(project: ProjectConfig, platform: BuildPlatform) throws -> [String: String] {
    if let error = platformServiceErrors[platform] { throw PackError(error) }
    if let values = platformServiceValues[platform] { return values }
    if credentialsCaptured { throw PackError("任务缺少平台服务参数快照，请重新提交") }
    return try PlatformServices.load(project: project, platform: platform).mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }
  public func captureServices(project: ProjectConfig, platform: BuildPlatform) throws {
    let values = try PlatformServices.load(project: project, platform: platform).mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    platformServiceValues[platform] = values
    let r = PlatformServiceRequirements(manifest: try ProjectReader.inspect(project.path).manifest, platform: platform)
    if r.huawei { huaweiConfiguration = try PlatformServices.huaweiDocument(values, bundle: project.android.applicationID) }
  }
}
