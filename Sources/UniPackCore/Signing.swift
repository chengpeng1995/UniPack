import Foundation
import CryptoKit

public struct ProvisionProfile {
    public let name:String, uuid:String, team:String, applicationIdentifier:String
    public let expiration:Date
    public let development:Bool
    public let devices:[String]
    public let allDevices:Bool
    public let entitlements:[String:Any]
    public let certificateHashes:[String]
    public var bundleID:String { applicationIdentifier.components(separatedBy:".").dropFirst().joined(separator:".") }
    public var purpose:String { development ? "开发调试" : (allDevices ? "企业分发（首版不支持）" : devices.isEmpty ? "App Store" : "Ad Hoc") }
    public static func read(_ path:String, runner:ProcessRunner=ProcessRunner()) throws -> ProvisionProfile {
        let result=try runner.run("/usr/bin/openssl",["smime","-inform","der","-verify","-noverify","-in",path])
        // OpenSSL 的成功提示在 stderr；从输出中单独取 plist，避免拼接的诊断破坏解析。
        guard let start=result.stdout.range(of:"<?xml"), let end=result.stdout.range(of:"</plist>",range:start.lowerBound..<result.stdout.endIndex) else { throw PackError("无法解析描述文件，请选择有效的 .mobileprovision。") }
        let data=Data(result.stdout[start.lowerBound..<end.upperBound].utf8)
        guard let d=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any], let e=d["Entitlements"] as? [String:Any], let expiry=d["ExpirationDate"] as? Date else { throw PackError("描述文件缺少必要字段") }
        return ProvisionProfile(name:d["Name"] as? String ?? "",uuid:d["UUID"] as? String ?? "",team:(d["TeamIdentifier"] as? [String])?.first ?? "",applicationIdentifier:e["application-identifier"] as? String ?? "",expiration:expiry,development:e["get-task-allow"] as? Bool ?? false,devices:d["ProvisionedDevices"] as? [String] ?? [],allDevices:d["ProvisionsAllDevices"] as? Bool ?? false,entitlements:e,certificateHashes:(d["DeveloperCertificates"] as? [Data] ?? []).map { fingerprint($0) })
    }
    public func validate(bundle:String,kind:BuildKind,identity:String,requested:[String:Any]=[:],now:Date=Date()) throws {
        guard expiration>now else { throw PackError("描述文件已过期：\(name)（\(expiration.formatted(date:.numeric,time:.omitted))）") }
        guard matches(bundleID,bundle) else { throw PackError("Bundle ID 不匹配：描述文件 \(bundleID)，项目 \(bundle)") }
        guard !allDevices else { throw PackError("首版不支持企业分发描述文件") }
        switch kind {
        case .debug: guard development && !devices.isEmpty else { throw PackError("调试基座需要包含测试设备的开发描述文件") }
        case .appStore: guard !development && devices.isEmpty else { throw PackError("App Store 包需要 App Store 发布描述文件") }
        case .adHoc: guard !development && !devices.isEmpty else { throw PackError("Ad Hoc 包需要包含设备的 Ad Hoc 发布描述文件") }
        }
        guard !identity.isEmpty,certificateHashes.contains(identity.uppercased()) else { throw PackError("签名证书不在描述文件允许的证书列表内，请选择匹配的 P12 文件。") }
        for (key,value) in requested {
            guard let allowed=entitlements[key], supports(allowed,value) else { throw PackError("描述文件不支持能力 \(key)，请更新描述文件或修正项目配置。") }
        }
    }
}
public func fingerprint(_ data:Data) -> String { Insecure.SHA1.hash(data:data).map{String(format:"%02X",$0)}.joined() }
private func matches(_ pattern:String,_ value:String) -> Bool { pattern == value || (pattern.hasSuffix("*") && value.hasPrefix(String(pattern.dropLast()))) }
private func supports(_ allowed:Any,_ requested:Any) -> Bool {
    if let a=allowed as? String,a == "*",requested is String || requested is [String] { return true }
    if let a=allowed as? String, let b=requested as? String { return matches(a,b) }
    if let a=allowed as? [Any],let b=requested as? [Any] { return b.allSatisfy { request in a.contains { supports($0,request) } } }
    if let a=allowed as? [String:Any],let b=requested as? [String:Any] { return b.allSatisfy { key,value in a[key].map { supports($0,value) } ?? false } }
    return (allowed as? NSObject)?.isEqual(requested) ?? false
}
public func validateSignedEntitlements(_ actual:[String:Any],required:[String:Any]) throws {
    for (key,value) in required {guard let included=actual[key],supports(included,value) else {throw PackError("IPA 签名遗漏或更改了请求的能力：\(key)")}}
}
