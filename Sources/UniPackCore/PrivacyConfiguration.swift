import Foundation

/// HBuilderX 5.34 的 iOS SDK 读取字符串策略；布尔 false 会被当作缺省值并默认同意。
/// 不重置已保存的授权，也不代替业务的同意按钮。
public enum PrivacyConfiguration {
  public static let policies: Set<String> = ["auto", "agree", "disagree"]
  public static func read(manifest: [String: Any]) throws -> String {
    if let raw = manifest["app"], !(raw is [String: Any]) {
      throw PackError("manifest.app 必须是对象，无法确定隐私初始状态")
    }
    let app = manifest["app"] as? [String: Any] ?? [:]
    guard let raw = app["initPrivacyAuthorization"] else { return "auto" }
    return try value(raw, label: "manifest.app.initPrivacyAuthorization")
  }
  public static func value(_ raw: Any?, label: String) throws -> String {
    guard let text = raw as? String, policies.contains(text) else {
      throw PackError("\(label) 必须是字符串 auto / agree / disagree，不能使用布尔值或其他类型")
    }
    return text
  }
  public static func description(_ policy: String) -> String {
    switch policy {
    case "disagree": return "disagree · 首次未同意，由业务弹窗取得授权后初始化"
    case "agree": return "agree · 首次默认同意，不会触发需要授权的分支"
    default: return "auto · iOS 首次默认同意；Android / 鸿蒙首次未同意"
    }
  }
  public static func verifyIOS(info: [String: Any], resource: [String: Any], expected: String?) throws {
    let native = try value((info["uniapp-x"] as? [String: Any])?["initPrivacyAuthorization"],
      label: "IPA Info.plist/uniapp-x/initPrivacyAuthorization")
    let embedded = try value((resource["app"] as? [String: Any])?["initPrivacyAuthorization"],
      label: "IPA 资源 manifest.app.initPrivacyAuthorization")
    let snapshot = try value(expected, label: "构建快照 initialPrivacyAuthorization")
    guard native == snapshot, embedded == snapshot else {
      throw PackError("iOS 隐私初始状态不一致：任务为 \(snapshot)，Info.plist 为 \(native)，包内资源为 \(embedded)；已拒绝发布")
    }
  }
}
