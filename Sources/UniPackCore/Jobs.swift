import Foundation
import Darwin

public enum BuildPlatform:String,Codable,CaseIterable,Identifiable,Sendable {
    case ios,android
    public var id:String {rawValue}
    public var title:String {self == .ios ? "iOS" : "Android"}
    public var symbol:String {self == .ios ? "apple.logo" : "apps.iphone"}
}
public enum PackageMode:String,Codable,CaseIterable,Identifiable,Sendable {
    case debug,release
    public var id:String {rawValue}
    public var title:String {self == .debug ? "自定义基座" : "正式包"}
}
public struct AndroidSigning:Codable,Equatable {
    public var keystorePath="",alias=""
    public var storePasswordKey=UUID().uuidString,keyPasswordKey=UUID().uuidString
    public var managed=false
    public init() {}
}
public struct AndroidConfig:Codable,Equatable {
    public var applicationID="",sdkPath="",outputPath=""
    public var mode=PackageMode.debug
    public var debugSigning=AndroidSigning(),releaseSigning=AndroidSigning()
    public var ndkVersion="28.2.13676358",cmakeVersion="3.22.1"
    public var manifestPlaceholdersPath=""
    public var servicesRevision=0
    public var servicesManaged=false
    public var servicesKey=UUID().uuidString
    public init() {}
    enum CodingKeys:String,CodingKey {case applicationID,sdkPath,outputPath,mode,debugSigning,releaseSigning,ndkVersion,cmakeVersion,manifestPlaceholdersPath,servicesManaged,servicesKey,servicesRevision}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        applicationID=try c.decodeIfPresent(String.self,forKey:.applicationID) ?? "";sdkPath=try c.decodeIfPresent(String.self,forKey:.sdkPath) ?? "";outputPath=try c.decodeIfPresent(String.self,forKey:.outputPath) ?? ""
        mode=try c.decodeIfPresent(PackageMode.self,forKey:.mode) ?? .debug
        debugSigning=try c.decodeIfPresent(AndroidSigning.self,forKey:.debugSigning) ?? AndroidSigning();releaseSigning=try c.decodeIfPresent(AndroidSigning.self,forKey:.releaseSigning) ?? AndroidSigning()
        ndkVersion=try c.decodeIfPresent(String.self,forKey:.ndkVersion) ?? "28.2.13676358";cmakeVersion=try c.decodeIfPresent(String.self,forKey:.cmakeVersion) ?? "3.22.1"
        manifestPlaceholdersPath=try c.decodeIfPresent(String.self,forKey:.manifestPlaceholdersPath) ?? ""
        servicesRevision=try c.decodeIfPresent(Int.self,forKey:.servicesRevision) ?? 0
        servicesManaged=try c.decodeIfPresent(Bool.self,forKey:.servicesManaged) ?? false
        servicesKey=try c.decodeIfPresent(String.self,forKey:.servicesKey) ?? UUID().uuidString
    }
    public var signing:AndroidSigning {
        get {mode == .debug ? debugSigning : releaseSigning}
        set {if mode == .debug {debugSigning=newValue} else {releaseSigning=newValue}}
    }
}
public enum JobStatus:String,Codable,Sendable {
    case queued,running,cancelling,succeeded,failed,cancelled,interrupted
    public var isActive:Bool {self == .queued || self == .running || self == .cancelling}
    public var title:String {switch self {case .queued:"等待中";case .running:"构建中";case .cancelling:"取消中";case .succeeded:"成功";case .failed:"失败";case .cancelled:"已取消";case .interrupted:"已中断"}}
}
public struct BuildArtifact:Codable,Identifiable {
    public var id=UUID(),platform:BuildPlatform,mode:PackageMode
    public var path:String,version:String,created=Date(),size:Int64
    public var versionCode:String?
    public init(platform:BuildPlatform,mode:PackageMode,path:String,version:String,versionCode:String?=nil) {
        self.platform=platform;self.mode=mode;self.path=path;self.version=version;self.versionCode=versionCode
        size=(try? FileManager.default.attributesOfItem(atPath:path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
public struct BuildJob:Codable,Identifiable {
    public var id=UUID(),projectID:UUID,platform:BuildPlatform,mode:PackageMode
    public var project:ProjectConfig,environment:EnvironmentConfig
    public var version:BuildVersion?
    public var status=JobStatus.queued,stage="等待构建",progress=0.0,detail=""
    public var created=Date(),finished:Date?,artifacts:[BuildArtifact]=[],logPath=""
    public init(project:ProjectConfig,environment:EnvironmentConfig,platform:BuildPlatform,mode:PackageMode,version:BuildVersion?=nil) {
        self.projectID=project.id;self.project=project;self.environment=environment;self.platform=platform;self.mode=mode;self.version=version
    }
    public var duplicateKey:String {URL(fileURLWithPath:project.path).standardizedFileURL.resolvingSymlinksInPath().path+"|"+platform.rawValue}
}
/// Each task owns its processes. HBuilderX export intentionally uses another runner, so cancelling
/// a native process group can never terminate the shared editor or release the export lock early.
public final class BuildContext:@unchecked Sendable {
    public let id:UUID,work:URL,runner=ProcessRunner()
    public var credentials:[String:String]=[:]
    public var credentialsCaptured=false
    public var platformServiceValues:[BuildPlatform:[String:String]]=[:]
    public var platformServiceErrors:[BuildPlatform:String]=[:]
    public var huaweiConfiguration:Data?
    public var moduleParameters:[String:String]?
    public var moduleParameterError:String?
    public var version:BuildVersion?
    public func captureVersion(project:ProjectConfig) throws -> BuildVersion {
        let resolved=try version ?? BuildVersion.read(project:project.path)
        try resolved.validate();version=resolved;return resolved
    }
    public func password(key:String) throws -> String? {if let value=credentials[key]{return value};return credentialsCaptured ? nil : try LocalCredentialStore.password(key:key)}
    private let state=NSLock();private var cancelled=false
    public init(id:UUID=UUID()) {self.id=id;work=Paths.data.appendingPathComponent("Builds/"+id.uuidString)}
    public func cancel() {state.lock();cancelled=true;state.unlock();runner.cancel()}
    public func checkCancellation() throws {state.lock();let c=cancelled;state.unlock();if c {throw CancellationError()}}
    public func export(project:ProjectConfig,environment:EnvironmentConfig,platform:BuildPlatform,log:@escaping(String)->Void) throws -> URL {
        try Paths.ensure(Paths.data)
        let fd=Darwin.open(Paths.data.appendingPathComponent("export.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else {throw PackError("无法创建 HBuilderX 导出锁")}
        defer {flock(fd,LOCK_UN);Darwin.close(fd)}
        while flock(fd,LOCK_EX|LOCK_NB) != 0 {try checkCancellation();Thread.sleep(forTimeInterval:0.15)}
        try checkCancellation()
        let exportRunner=ProcessRunner(),info=try ProjectReader.inspect(project.path)
        let expected=try captureVersion(project:project)
        guard try BuildVersion.read(project:project.path)==expected else {throw PackError("工程版本在任务等待期间发生变化，请使用新版本重新构建")}
        let name=URL(fileURLWithPath:environment.hbuilderPath).deletingPathExtension().lastPathComponent
        if try exportRunner.run("/usr/bin/pgrep",["-x",name],allowFailure:true,timeout:10).status != 0 {_=try exportRunner.run("/usr/bin/open",[environment.hbuilderPath],timeout:30)}
        var ready=false
        for _ in 0..<30 {
            try checkCancellation()
            if try exportRunner.run(environment.cliPath,["project","list"],allowFailure:true,timeout:5).status == 0 {ready=true;break}
            Thread.sleep(forTimeInterval:1)
        }
        guard ready else {throw PackError("HBuilderX CLI 未就绪")}
        _=try exportRunner.run(environment.cliPath,["project","open","--path",project.path],timeout:30,log:log)
        try checkCancellation()
        let folder="app-"+platform.rawValue,started=Date()
        log("HBuilderX 导出已取得全局锁；取消会等待此导出结束，其他任务不受影响。\n")
        _=try exportRunner.run(environment.cliPath,["publish",folder,"--type","appResource","--project",project.path],timeout:1800,log:log)
        try checkCancellation()
        guard try BuildVersion.read(project:project.path)==expected else {throw PackError("资源导出期间工程版本发生变化，本次构建已停止，请重新构建")}
        let source=URL(fileURLWithPath:project.path).appendingPathComponent("unpackage/resources/"+folder)
        let manifest=source.appendingPathComponent(info.appID+"/www/manifest.json")
        let modified=try FileManager.default.attributesOfItem(atPath:manifest.path)[.modificationDate] as? Date
        guard let modified,modified>=started.addingTimeInterval(-2) else {throw PackError("未生成新资源，已拒绝沿用旧产物")}
        let m=try JSONFile.read(manifest),x=m["uni-app-x"] as? [String:Any] ?? [:]
        guard x["vapor"] as? Bool == true,x["compilerVersion"] as? String == environment.hbuilderVersion.split(separator:".").prefix(2).joined(separator:".") else {throw PackError("导出资源模式或编译器版本不匹配")}
        try Paths.ensure(work)
        let snapshot=work.appendingPathComponent("Resources")
        try FileManager.default.copyItem(at:source,to:snapshot)
        try expected.verifyResource(JSONFile.read(snapshot.appendingPathComponent(info.appID+"/www/manifest.json")))
        try checkCancellation()
        log("新资源已复制到任务独立目录，释放 HBuilderX 导出锁。\n")
        return snapshot
    }
}
/// Main-thread scheduler keeps presentation and persistence ordered; native work never runs on it.
public typealias JobOperation = (BuildJob,BuildContext,@escaping(BuildEvent)->Void) throws -> BuildRecord
@MainActor public final class BuildScheduler {
    public private(set) var jobs:[BuildJob]
    public var onChange:(([BuildJob])->Void)?
    public var onLog:((UUID,String)->Void)?
    private var contexts:[UUID:BuildContext]=[:]
    private var pending:[UUID]=[]
    private var prepared:[UUID:BuildContext]=[:]
    private let operation:JobOperation?
    public var limit:Int=2 {didSet {limit=min(4,max(1,limit));pump()}}
    public init(jobs:[BuildJob]=[],operation:JobOperation?=nil) {self.jobs=jobs;self.operation=operation}
    @discardableResult public func submit(project:ProjectConfig,environment:EnvironmentConfig,platform:BuildPlatform,mode:PackageMode) throws -> UUID {
        let ids = try submit(project: project, environment: environment, platforms: [platform], mode: mode)
        return ids[0] // The single-platform overload always prepares exactly one job.
    }

    /// Prepare every credential snapshot before enqueuing anything; a rejected batch starts no jobs.
    @discardableResult public func submit(project: ProjectConfig, environment: EnvironmentConfig,
        platforms: Set<BuildPlatform>, mode: PackageMode) throws -> [UUID] {
        guard !platforms.isEmpty else { throw PackError("请先选择打包平台") }
        let version = try BuildVersion.read(project: project.path)
        try version.validate()
        var snapshot = project
        snapshot.kind = mode == .debug ? .debug : .appStore
        snapshot.android.mode = mode
        let batch = BuildPlatform.allCases.filter(platforms.contains).map {
            BuildJob(project: snapshot, environment: environment, platform: $0, mode: mode, version: version)
        }
        for job in batch where jobs.contains(where: { $0.status.isActive && $0.duplicateKey == job.duplicateKey }) {
            throw PackError("该项目的 \(job.platform.title) 任务已在等待或构建中")
        }
        let contexts = try batch.map { job in
            let context = BuildContext(id: job.id)
            context.version = version
            let android = snapshot.android.signing
            let keys = job.platform == .ios ? [snapshot.signing.passwordKey] : [android.storePasswordKey, android.keyPasswordKey]
            for key in keys { if let value = try LocalCredentialStore.password(key: key) { context.credentials[key] = value } }
            do { try context.captureServices(project:snapshot,platform:job.platform) }
            catch { context.platformServiceErrors[job.platform]=error.localizedDescription }
            context.credentialsCaptured = true
            return context
        }
        for context in contexts { prepared[context.id] = context }
        let ids = batch.map(\.id)
        jobs.insert(contentsOf: batch, at: 0)
        pending.append(contentsOf: ids)
        changed(); pump()
        return ids
    }
    public func cancel(_ id:UUID) {
        guard let i=jobs.firstIndex(where:{$0.id == id}),jobs[i].status.isActive else {return}
        if jobs[i].status == .queued {pending.removeAll{$0 == id};prepared.removeValue(forKey:id);jobs[i].status = .cancelled;jobs[i].stage="已取消";jobs[i].finished=Date()}
        else {jobs[i].status = .cancelling;jobs[i].stage="正在取消（导出中需等待导出完成）";contexts[id]?.cancel()}
        changed()
    }
    private func changed() {onChange?(jobs)}
    private func pump() {
        while contexts.count<limit,!pending.isEmpty {
            let id=pending.removeFirst();guard let i=jobs.firstIndex(where:{$0.id == id}),jobs[i].status == .queued else {continue}
            let context=prepared.removeValue(forKey:id) ?? BuildContext(id:id),job=jobs[i],operation=self.operation, forwardsLogs=onLog != nil;contexts[id]=context
            jobs[i].status = .running;jobs[i].stage="预检";jobs[i].logPath=context.work.appendingPathComponent("build.log").path;changed()
            Task.detached { [weak self] in
                let result:Result<BuildRecord,Error>
                do {
                    try Paths.ensure(context.work)
                    let backend:any PackagingBackend=job.platform == .ios ? IOSVaporBackend(context:context) : AndroidVaporBackend(context:context)
                    let events:(BuildEvent)->Void={event in
                        if case .log = event, !forwardsLogs { return }
                        Task { @MainActor [weak self] in self?.event(id,event) }
                    }
                    let record:BuildRecord
                    if let operation {record=try operation(job,context,events)} else {record=try backend.build(project:job.project,environment:job.environment,event:events)}
                    result = .success(record)
                } catch {result = .failure(error)}
                await self?.finish(id,result)
            }
        }
    }
    private func event(_ id:UUID,_ event:BuildEvent) {
        guard let i=jobs.firstIndex(where:{$0.id == id}),jobs[i].status.isActive else {return}
        switch event {case .stage(let name,let progress):if jobs[i].status != .cancelling {jobs[i].stage=name};jobs[i].progress=progress;changed()
        case .log(let s):onLog?(id,s)}
    }
    private func finish(_ id:UUID,_ result:Result<BuildRecord,Error>) {
        guard let i=jobs.firstIndex(where:{$0.id == id}) else {return}
        switch result {
        case .success(let record):
            jobs[i].status = .succeeded;jobs[i].progress=1;jobs[i].stage="打包完成";jobs[i].detail=record.detail
            let version=record.version ?? jobs[i].version
            jobs[i].artifacts=[BuildArtifact(platform:jobs[i].platform,mode:jobs[i].mode,path:record.artifact,version:version?.name ?? "",versionCode:version?.code)]
        case .failure(let error):
            jobs[i].status = jobs[i].status == .cancelling || error is CancellationError ? .cancelled : .failed
            jobs[i].stage=jobs[i].status.title;jobs[i].detail=jobs[i].status == .cancelled ? "已取消本次构建，保留上一次成功产物。" : error.localizedDescription
            try? ("\n"+error.localizedDescription+"\n").data(using:.utf8)?.appendFile(to:URL(fileURLWithPath:jobs[i].logPath))
        }
        jobs[i].finished=Date();contexts.removeValue(forKey:id);changed();pump()
    }
}
private extension Data {
    func appendFile(to url:URL) throws {
        if !FileManager.default.fileExists(atPath:url.path) {try write(to:url)}
        else {let h=try FileHandle(forWritingTo:url);defer{try? h.close()};try h.seekToEnd();try h.write(contentsOf:self)}
    }
}

public final class BuildLease {
    private var fd:Int32 = -1
    public init(project:String,platform:BuildPlatform) throws {
        try Paths.ensure(Paths.data.appendingPathComponent("Locks"))
        let canonical=URL(fileURLWithPath:project).standardizedFileURL.resolvingSymlinksInPath().path
        let key=fingerprint(Data((canonical+"|"+platform.rawValue).utf8))
        fd=Darwin.open(Paths.data.appendingPathComponent("Locks/"+key).path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else {throw PackError("无法创建项目任务锁")}
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else {Darwin.close(fd);fd = -1;throw PackError("此项目的同平台任务已在其他进程构建")}
    }
    public func release() {if fd>=0 {flock(fd,LOCK_UN);Darwin.close(fd);fd = -1}}
    deinit {release()}
}
public enum ArtifactPublisher {
    public static func publish(source:URL,project:ProjectConfig,platform:BuildPlatform,mode:PackageMode,version:String,output:URL,context:BuildContext) throws -> URL {
        let fm=FileManager.default,ext=platform == .ios ? "ipa" : "apk"
        // Every history entry points to an immutable task-specific artifact; the debug alias is only a convenience copy.
        let folder=mode == .debug ? URL(fileURLWithPath:project.path).appendingPathComponent("unpackage/debug/builds") : output
        try Paths.ensure(folder)
        let safeVersion=version.replacingOccurrences(of:"[^A-Za-z0-9_.-]",with:"_",options:.regularExpression)
        let name="UniPack-\(platform.rawValue)-\(safeVersion)-\(mode.rawValue)-\(Int(Date().timeIntervalSince1970))-\(context.id.uuidString.prefix(8)).\(ext)"
        let target=folder.appendingPathComponent(name),staged=folder.appendingPathComponent("."+UUID().uuidString+"."+ext)
        defer {try? fm.removeItem(at:staged)}
        try fm.copyItem(at:source,to:staged);try context.checkCancellation()
        guard Darwin.rename(staged.path,target.path) == 0 else {throw PackError("无法原子保存产物")}
        if mode == .debug {
            let alias=URL(fileURLWithPath:project.path).appendingPathComponent("unpackage/debug/"+(platform == .ios ? "iOS_debug_vapor.ipa" : "android_debug_vapor.apk"))
            let temp=alias.deletingLastPathComponent().appendingPathComponent("."+context.id.uuidString+"."+ext)
            defer {try? fm.removeItem(at:temp)}
            do {try fm.copyItem(at:target,to:temp);try context.checkCancellation();guard Darwin.rename(temp.path,alias.path) == 0 else {throw PackError("无法更新成功基座路径")}}
            catch {try? fm.removeItem(at:target);throw error}
        }
        return target
    }
}
