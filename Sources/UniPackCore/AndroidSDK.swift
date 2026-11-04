import Foundation
public struct AndroidSDKInfo {
    public let root:URL,version:String
    public static func inspect(_ input:URL) throws -> Self {
        let fm=FileManager.default
        let candidates=[input]+((try? fm.contentsOfDirectory(at:input,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [])
        guard let root=candidates.first(where:{fm.fileExists(atPath:$0.appendingPathComponent("xvnativeproject/gradlew").path) && fm.fileExists(atPath:$0.appendingPathComponent("SDK/libs/ext-component-release.aar").path) && fm.fileExists(atPath:$0.appendingPathComponent("plugins/auto-register-gradle-plugin-1.0.0.jar").path)}) else {throw PackError("不是 Vapor Android SDK：缺少 xvnativeproject、SDK/libs 或蒸汽注册插件")}
        let metadata=try? JSONFile.read(root.appendingPathComponent(".unipack-sdk.json"))
        let name=root.lastPathComponent
        let version=(metadata?["version"] as? String) ?? name.range(of:"[0-9]+\\.[0-9]+",options:.regularExpression).map{String(name[$0])} ?? ""
        guard !version.isEmpty else {throw PackError("SDK 版本无法识别，请保留官方版本目录")}
        return Self(root:root,version:version)
    }
    public func validate(hbuilder:String) throws {
        guard hbuilder == "5.34.2026102909",version == "5.34" || version == hbuilder else {throw PackError("Android SDK \(version) 与已适配的 HBuilderX 5.34.2026102909 不匹配")}
        if let d=try? JSONFile.read(root.appendingPathComponent(".unipack-sdk.json")),let full=d["hbuilderVersion"] as? String,full != hbuilder {throw PackError("SDK 完整发布版本不匹配")}
    }
}
public extension SDKManager {
    static func releases(platform:BuildPlatform) async throws -> [SDKRelease] {
        if platform == .ios {return try await releases()}
        let page=URL(string:"https://doc.dcloud.net.cn/uni-app-x/native/download/android.html")!
        let (data,response)=try await URLSession.shared.data(from:page)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw PackError("官方下载页不可用，请导入本地 SDK")}
        let html=String(decoding:data,as:UTF8.self),ns=String(decoding:data,as:UTF8.self) as NSString
        let re=try NSRegularExpression(pattern:"https://web-ext-storage\\.dcloud\\.net\\.cn/uni-app-x/sdk/Android-Vapor/[^\\\"<>\\s]+\\.zip")
        var seen=Set<String>(),result:[SDKRelease]=[]
        for m in re.matches(in:html,range:NSRange(location:0,length:ns.length)) {
            guard let url=URL(string:ns.substring(with:m.range).replacingOccurrences(of:"&amp;",with:"&")) else {continue}
            let name=url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            guard let r=name.range(of:"[0-9]+\\.[0-9]+",options:.regularExpression) else {continue}
            let v=String(name[r]);if seen.insert(v).inserted {result.append(SDKRelease(version:v,url:url))}
        }
        guard !result.isEmpty else {throw PackError("官方页面未找到 Vapor Android SDK，支持导入本地目录")};return result
    }
    static func install(zip:URL,release:SDKRelease,platform:BuildPlatform,hbuilder:String,runner:ProcessRunner,log:@escaping(String)->Void) throws -> URL {
        if platform == .ios {return try install(zip:zip,version:release.version,hbuilderVersion:hbuilder,runner:runner,log:log)}
        let root=Paths.data.appendingPathComponent("SDKs"),stage=root.appendingPathComponent(".install-"+UUID().uuidString)
        try Paths.ensure(stage);defer{try? FileManager.default.removeItem(at:stage)}
        let names=try runner.run("/usr/bin/unzip",["-Z1",zip.path]).output.components(separatedBy:.newlines)
        guard !names.contains(where:{$0.hasPrefix("/") || $0.split(separator:"/").contains("..")}) else {throw PackError("SDK ZIP 包含越界路径")}
        _=try runner.run("/usr/bin/ditto",["-x","-k",zip.path,stage.path],log:log)
        let sdk=try AndroidSDKInfo.inspect(stage);try sdk.validate(hbuilder:hbuilder)
        guard sdk.version == release.version else {throw PackError("下载包版本不符")}
        let target=root.appendingPathComponent("Android-Vapor-"+hbuilder)
        guard !FileManager.default.fileExists(atPath:target.path) else {throw PackError("此版本已安装，请直接导入："+target.path)}
        try JSONFile.write(["version":sdk.version,"hbuilderVersion":hbuilder],to:sdk.root.appendingPathComponent(".unipack-sdk.json"))
        try runner.checkCancellation();try FileManager.default.moveItem(at:sdk.root,to:target);return target
    }
}
