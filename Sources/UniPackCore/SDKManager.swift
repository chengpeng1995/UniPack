import Foundation

public struct SDKRelease: Identifiable {
    public let version:String
    public let url:URL
    public var id:String { version }
    public init(version:String,url:URL) { self.version=version; self.url=url }
}
public struct SDKInfo {
    public let root:URL
    public let version:String
    public let fullVersion:String?
    public let libs:URL
    public let extSources:URL
    public static func inspect(_ root:URL) throws -> SDKInfo {
        let fm=FileManager.default
        var candidates=[root,root.appendingPathComponent("SDK")]
        for p in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:.skipsHiddenFiles)) ?? [] { candidates += [p,p.appendingPathComponent("SDK")] }
        guard let sdk=candidates.first(where:{fm.fileExists(atPath:$0.appendingPathComponent("libs/DCloudUniExtComponent.xcframework").path) && fm.fileExists(atPath:$0.appendingPathComponent("ExtApiSrc").path)}) else { throw PackError("不是有效的 Vapor iOS SDK：缺少 SDK/libs/DCloudUniExtComponent.xcframework 或 ExtApiSrc。") }
        let parent=sdk.lastPathComponent == "SDK" ? sdk.deletingLastPathComponent() : sdk
        var version="",full:String?
        for c in [parent.appendingPathComponent(".unipack-sdk.json"),root.appendingPathComponent(".unipack-sdk.json")] {
            if let d=try? JSONFile.read(c),let v=d["version"] as? String { version=v; full=d["hbuilderVersion"] as? String; break }
        }
        if version.isEmpty {
            let names=[parent.lastPathComponent,root.lastPathComponent]
            for name in names { if let r=name.range(of:"[0-9]+\\.[0-9]+(?:\\.[0-9]+)?",options:.regularExpression) { version=String(name[r]); break } }
        }
        guard !version.isEmpty else { throw PackError("SDK 版本无法确认，请保留官方解压目录的版本号。") }
        return SDKInfo(root:parent,version:version,fullVersion:full,libs:sdk.appendingPathComponent("libs"),extSources:sdk.appendingPathComponent("ExtApiSrc"))
    }
    public func validate(hbuilder:String) throws {
        let short=hbuilder.split(separator:".").prefix(2).joined(separator:".")
        guard version == short || version == hbuilder else { throw PackError("SDK \(version) 与 HBuilderX \(hbuilder) 不匹配") }
        if let fullVersion,fullVersion != hbuilder { throw PackError("SDK 发布版本 \(fullVersion) 与 HBuilderX \(hbuilder) 不匹配") }
        guard hbuilder == "5.34.2026102909" else { throw PackError("首版已适配 SDK 5.34，当前版本 \(short) 尚未适配模块清单。") }
    }
}
public final class SDKManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let page=URL(string:"https://doc.dcloud.net.cn/uni-app-x/native/download/ios.html")!
    private var session:URLSession?
    private var task:URLSessionDownloadTask?
    private var continuation:CheckedContinuation<URL,Error>?
    private var progress:((Double)->Void)?
    private var destination:URL?
    private let lock=NSLock()
    public override init() { super.init() }
    public static func releases() async throws -> [SDKRelease] {
        let (data,response)=try await URLSession.shared.data(from:page)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PackError("官方下载页不可用，请稍后重试或导入本地 SDK。") }
        let html=String(decoding:data,as:UTF8.self)
        let regex=try NSRegularExpression(pattern:"https://web-ext-storage\\.dcloud\\.net\\.cn/uni-app-x/sdk/iOS-Vapor/[^\\\"<>\\s]+\\.zip")
        let ns=html as NSString
        var seen=Set<String>(),result:[SDKRelease]=[]
        for m in regex.matches(in:html,range:NSRange(location:0,length:ns.length)) {
            let raw=ns.substring(with:m.range).replacingOccurrences(of:"&amp;",with:"&")
            guard let u=URL(string:raw),let r=u.lastPathComponent.removingPercentEncoding?.range(of:"[0-9]+\\.[0-9]+(?:\\.[0-9]+)?",options:.regularExpression) else { continue }
            let name=u.lastPathComponent.removingPercentEncoding!; let version=String(name[r]); if seen.insert(version).inserted { result.append(SDKRelease(version:version,url:u)) }
        }
        guard !result.isEmpty else { throw PackError("官方下载页格式已变化，无法识别 Vapor 下载链接；可导入本地 SDK。") }
        return result
    }
    public func cancel() { lock.lock(); let t=task; lock.unlock(); t?.cancel() }
    public func download(_ release:SDKRelease, to destination:URL, progress:@escaping (Double)->Void) async throws -> URL {
        try Task.checkCancellation()
        try Paths.ensure(destination.deletingLastPathComponent())
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { c in
                lock.lock(); self.continuation=c; self.progress=progress; self.destination=destination
                let config=URLSessionConfiguration.default; config.timeoutIntervalForRequest=60; config.timeoutIntervalForResource=3600
                let s=URLSession(configuration:config,delegate:self,delegateQueue:nil); session=s
                let t=s.downloadTask(with:release.url); task=t; lock.unlock(); t.resume(); if Task.isCancelled {t.cancel()}
            }
        },onCancel:{self.cancel()})
    }
    public func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesExpectedToWrite>0 { progress?(Double(totalBytesWritten)/Double(totalBytesExpectedToWrite)) }
    }
    public func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,let target=destination else { throw PackError("SDK 下载失败：服务器未返回完整 ZIP 文件") }
            // 先写唯一下载文件，旧 SDK 和上次成功结果不会被覆盖。
            try FileManager.default.moveItem(at:location,to:target)
            finish(.success(target))
        } catch { finish(.failure(error)) }
    }
    public func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) { if let error { finish(.failure(error)) } }
    private func finish(_ result:Result<URL,Error>) {
        lock.lock(); let c=continuation; continuation=nil; task=nil; let s=session; session=nil; lock.unlock()
        c?.resume(with:result); s?.finishTasksAndInvalidate()
    }
    public static func install(zip:URL, version:String, hbuilderVersion:String, runner:ProcessRunner, log:@escaping(String)->Void) throws -> URL {
        let root=Paths.data.appendingPathComponent("SDKs"), staging=root.appendingPathComponent(".install-"+UUID().uuidString)
        try Paths.ensure(staging)
        defer { try? FileManager.default.removeItem(at:staging) }
        let entries=try runner.run("/usr/bin/unzip",["-Z1",zip.path]).output.components(separatedBy:.newlines)
        guard !entries.contains(where:{$0.hasPrefix("/") || $0.split(separator:"/").contains("..")}) else { throw PackError("SDK ZIP 包含越界路径，已拒绝解压") }
        _=try runner.run("/usr/bin/ditto",["-x","-k",zip.path,staging.path],log:log)
        let sdk=try SDKInfo.inspect(staging)
        guard sdk.version == version else { throw PackError("下载文件中的 SDK 版本与所选版本不符") }
        let target=root.appendingPathComponent("iOS-Vapor-"+hbuilderVersion)
        guard !FileManager.default.fileExists(atPath:target.path) else { throw PackError("此版本已安装，请导入：\(target.path)") }
        try JSONFile.write(["version":version,"hbuilderVersion":hbuilderVersion],to:sdk.root.appendingPathComponent(".unipack-sdk.json"))
        try runner.checkCancellation()
        try FileManager.default.moveItem(at:sdk.root,to:target)
        return target
    }
}
