import Foundation

public struct PackError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum BuildKind: String, Codable, CaseIterable, Identifiable {
    case debug, appStore, adHoc
    public var id: String { rawValue }
    public var title: String { switch self { case .debug: "自定义调试基座"; case .appStore: "App Store 正式 IPA"; case .adHoc: "Ad Hoc 测试 IPA" } }
}
public struct SigningConfig: Codable, Equatable {
    public var p12Path = ""
    public var profilePath = ""
    public var passwordKey = UUID().uuidString
    public init() {}
}
public struct ProjectConfig: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var path: String
    public var bundleID = ""
    public var sdkPath = ""
    public var outputPath = ""
    public var kind = BuildKind.debug
    public var debugSigning = SigningConfig()
    public var releaseSigning = SigningConfig()
    public var entitlementPath = ""
    public var android = AndroidConfig()
    public var iosServicesManaged = false
    public var iosServicesKey = UUID().uuidString
    public var iosServicesRevision = 0
    public var selectedPlatforms: Set<BuildPlatform> = [.ios]
    private enum LegacyKeys: String, CodingKey { case selectedPlatform }
    // Source compatibility for callers which still explicitly choose one platform.
    public var selectedPlatform: BuildPlatform {
        get { selectedPlatforms == [.android] ? .android : .ios }
        set { selectedPlatforms = [newValue] }
    }
    public init(path: String) { self.path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    enum CodingKeys:String,CodingKey { case id,path,bundleID,sdkPath,outputPath,kind,debugSigning,releaseSigning,entitlementPath,android,selectedPlatforms,iosServicesManaged,iosServicesKey,iosServicesRevision }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id); path=try c.decode(String.self,forKey:.path)
        bundleID=try c.decodeIfPresent(String.self,forKey:.bundleID) ?? ""
        sdkPath=try c.decodeIfPresent(String.self,forKey:.sdkPath) ?? ""
        outputPath=try c.decodeIfPresent(String.self,forKey:.outputPath) ?? ""
        kind=try c.decodeIfPresent(BuildKind.self,forKey:.kind) ?? .debug
        debugSigning=try c.decodeIfPresent(SigningConfig.self,forKey:.debugSigning) ?? SigningConfig()
        releaseSigning=try c.decodeIfPresent(SigningConfig.self,forKey:.releaseSigning) ?? SigningConfig()
        entitlementPath=try c.decodeIfPresent(String.self,forKey:.entitlementPath) ?? ""
        android=try c.decodeIfPresent(AndroidConfig.self,forKey:.android) ?? AndroidConfig()
        iosServicesManaged=try c.decodeIfPresent(Bool.self,forKey:.iosServicesManaged) ?? false
        iosServicesKey=try c.decodeIfPresent(String.self,forKey:.iosServicesKey) ?? UUID().uuidString
        iosServicesRevision=try c.decodeIfPresent(Int.self,forKey:.iosServicesRevision) ?? 0
        if let saved = try c.decodeIfPresent(Set<BuildPlatform>.self, forKey: .selectedPlatforms) {
            selectedPlatforms = saved
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            selectedPlatforms = [try legacy.decodeIfPresent(BuildPlatform.self, forKey: .selectedPlatform) ?? .ios]
        }
    }
    public var signing: SigningConfig {
        get { kind == .debug ? debugSigning : releaseSigning }
        set { if kind == .debug { debugSigning = newValue } else { releaseSigning = newValue } }
    }
    public var label: String { URL(fileURLWithPath: path).lastPathComponent }
}
public struct EnvironmentConfig: Codable {
    public var hbuilderPath = "/Applications/HBuilderX.app"
    public var xcodePath = "/Applications/Xcode.app/Contents/Developer"
    public var dependencyProxy = ""
    public var androidSDKPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path
    public var javaHome = EnvironmentConfig.detectJava()
    public var concurrency = 2
    public static func detectJava()->String {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Java/JavaVirtualMachines")
        return ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []).sorted{$0.lastPathComponent>$1.lastPathComponent}.first(where:{FileManager.default.isExecutableFile(atPath:$0.appendingPathComponent("Contents/Home/bin/java").path)})?.appendingPathComponent("Contents/Home").path ?? "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home"
    }
    public var podPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pod") ? "/opt/homebrew/bin/pod" : "/usr/local/bin/pod"
    public init() {}
    enum CodingKeys:String,CodingKey {case hbuilderPath,xcodePath,podPath,dependencyProxy,androidSDKPath,javaHome,concurrency}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        hbuilderPath=try c.decodeIfPresent(String.self,forKey:.hbuilderPath) ?? "/Applications/HBuilderX.app"
        xcodePath=try c.decodeIfPresent(String.self,forKey:.xcodePath) ?? "/Applications/Xcode.app/Contents/Developer"
        podPath=try c.decodeIfPresent(String.self,forKey:.podPath) ?? "/opt/homebrew/bin/pod"
        dependencyProxy=try c.decodeIfPresent(String.self,forKey:.dependencyProxy) ?? ""
        androidSDKPath=try c.decodeIfPresent(String.self,forKey:.androidSDKPath) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path
        javaHome=try c.decodeIfPresent(String.self,forKey:.javaHome) ?? Self.detectJava()
        concurrency=min(4,max(1,try c.decodeIfPresent(Int.self,forKey:.concurrency) ?? 2))
    }
    public var cliPath: String { hbuilderPath + "/Contents/MacOS/cli" }
    public var hbuilderVersion: String {
        guard let d = NSDictionary(contentsOfFile: hbuilderPath + "/Contents/Info.plist") else { return "" }
        return d["CFBundleShortVersionString"] as? String ?? ""
    }
}
public struct CheckItem: Identifiable, Codable {
    public var id = UUID()
    public let title: String
    public let detail: String
    public let ok: Bool
    public let required: Bool
    public init(_ title: String, _ detail: String, ok: Bool, required: Bool = true) { self.title=title; self.detail=detail; self.ok=ok; self.required=required }
}
public struct ProjectInfo {
    public let name: String
    public let appID: String
    public let version: String
    public let versionCode: String
    public let modules: [String]
    public let manifest: [String: Any]
}
public struct BuildRecord: Codable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var project: String
    public var kind: BuildKind
    public var status: String
    public var detail: String
    public var artifact: String
    public var logPath: String
    public var version: BuildVersion?
    public init(project: String, kind: BuildKind, status: String, detail: String = "", artifact: String = "", logPath: String = "", version: BuildVersion? = nil) {
        self.project=project; self.kind=kind; self.status=status; self.detail=detail; self.artifact=artifact; self.logPath=logPath; self.version=version
    }
}
public enum BuildEvent {
    case stage(String, Double), log(String)
}
public enum Paths {
    public static var data: URL {
        if let p = ProcessInfo.processInfo.environment["UNIPACK_DATA_DIR"] { return URL(fileURLWithPath:p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UniPack", isDirectory:true)
    }
    public static func ensure(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories:true) }
    public static var generator: URL {
        if let resources=Bundle.main.resourceURL {
            let embedded=resources.appendingPathComponent("UniPack_UniPackCore.bundle/Resources/generate.rb")
            if FileManager.default.fileExists(atPath:embedded.path) { return embedded }
        }
        return Bundle.module.url(forResource:"generate", withExtension:"rb", subdirectory:"Resources")!
    }
}
public final class ConfigStore {
    public init() {}
    public struct Saved:Codable {
        public static let currentSchema = 7
        public var schemaVersion = Self.currentSchema
        public var projects:[ProjectConfig]
        public var environment:EnvironmentConfig
        public var records:[BuildRecord]
        public var jobs:[BuildJob]
        public init(projects:[ProjectConfig]=[],environment:EnvironmentConfig=EnvironmentConfig(),records:[BuildRecord]=[],jobs:[BuildJob]=[]) {self.projects=projects;self.environment=environment;self.records=records;self.jobs=jobs}
        enum CodingKeys:String,CodingKey {case schemaVersion,projects,environment,records,jobs}
        public init(from decoder:Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            schemaVersion=try c.decodeIfPresent(Int.self,forKey:.schemaVersion) ?? 1
            guard schemaVersion<=Self.currentSchema else {throw PackError("配置版本高于当前工具版本，请更新 UniPack")}
            projects=try c.decode([ProjectConfig].self,forKey:.projects)
            environment=try c.decode(EnvironmentConfig.self,forKey:.environment)
            records=try c.decodeIfPresent([BuildRecord].self,forKey:.records) ?? []
            jobs=try c.decodeIfPresent([BuildJob].self,forKey:.jobs) ?? []
        }
    }
    public func load() throws -> Saved {
        let file=Paths.data.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath:file.path) else {return Saved()}
        let bytes=try Data(contentsOf:file)
        var saved=try JSONDecoder().decode(Saved.self,from:bytes)
        if saved.schemaVersion<Saved.currentSchema {
            let backup=Paths.data.appendingPathComponent("settings-v\(saved.schemaVersion)-"+UUID().uuidString+".backup.json")
            try bytes.write(to:backup,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
            saved.schemaVersion=Saved.currentSchema
            for i in saved.projects.indices {if saved.projects[i].kind == .adHoc {saved.projects[i].kind = .appStore}}
            // Preserve only path/identifier metadata. Passwords are never read from the old credential store.
            try save(saved)
        }
        CredentialWorkspace.cleanInterrupted()
        for i in saved.jobs.indices where saved.jobs[i].status.isActive {
            saved.jobs[i].status = .interrupted; saved.jobs[i].stage="已中断";saved.jobs[i].detail="上次应用退出时任务未完成，请手动重试。";saved.jobs[i].finished=Date()
            let root=Paths.data.appendingPathComponent("Builds/"+saved.jobs[i].id.uuidString)
            for name in [".store-password",".key-password","Native/signing.properties"] {try? FileManager.default.removeItem(at:root.appendingPathComponent(name))}
        }
        return saved
    }
    public func save(_ saved:Saved) throws {
        try Paths.ensure(Paths.data)
        let data=try JSONEncoder().encode(saved),file=Paths.data.appendingPathComponent("settings.json")
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    public func save(projects:[ProjectConfig],environment:EnvironmentConfig,records:[BuildRecord]) throws {
        var saved=try load();saved.projects=projects;saved.environment=environment;saved.records=records;try save(saved)
    }
}
public enum JSONFile {
    public static func read(_ url:URL) throws -> [String:Any] {
        // HBuilderX manifest 支持注释和末尾逗号；保留字符串中的 URL、转义和注释符号。
        let text=try String(contentsOf:url,encoding:.utf8)
        return try parse(text,label:url.lastPathComponent)
    }
    public static func parse(_ text:String,label:String="JSON") throws -> [String:Any] {
        var out="", i=text.startIndex, quote=false, escaped=false
        while i < text.endIndex {
            let c=text[i], next=text.index(after:i)
            if quote { out.append(c); if escaped { escaped=false } else if c == "\\" { escaped=true } else if c == "\"" { quote=false }; i=next; continue }
            if c == "\"" { quote=true; out.append(c); i=next; continue }
            if c == "/", next < text.endIndex, text[next] == "/" {
                i=text.index(after:next); while i < text.endIndex && text[i] != "\n" { i=text.index(after:i) }; continue
            }
            if c == "/", next < text.endIndex, text[next] == "*" {
                i=text.index(after:next)
                while i < text.endIndex { let n=text.index(after:i); if text[i] == "*", n < text.endIndex, text[n] == "/" { i=text.index(after:n); break }; if text[i] == "\n" { out.append("\n") }; i=n }; continue
            }
            out.append(c); i=next
        }
        var clean=""; quote=false; escaped=false
        let a=Array(out); var k=0
        while k<a.count {
            let c=a[k]
            if quote { clean.append(c); if escaped { escaped=false } else if c == "\\" { escaped=true } else if c == "\"" { quote=false } }
            else if c == "\"" { quote=true; clean.append(c) }
            else if c == "," { var n=k+1; while n<a.count && a[n].isWhitespace { n+=1 }; if n==a.count || (a[n] != "}" && a[n] != "]") { clean.append(c) } }
            else { clean.append(c) }; k+=1
        }
        guard let d=try JSONSerialization.jsonObject(with:Data(clean.utf8)) as? [String:Any] else { throw PackError("JSON 根节点必须为对象：\(label)") }; return d
    }
    public static func write(_ value:Any, to:URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:to,options:.atomic) }
}
public enum ProjectReader {
    public static func inspect(_ path:String) throws -> ProjectInfo {
        let d=try JSONFile.read(URL(fileURLWithPath:path).appendingPathComponent("manifest.json"))
        guard let x=d["uni-app-x"] as? [String:Any], x["vapor"] as? Bool == true else { throw PackError("首版仅支持 uni-app X Vapor，请检查 manifest.json 的 uni-app-x.vapor。") }
        guard let appID=d["appid"] as? String, appID.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else { throw PackError("manifest.json 缺少 AppID") }
        let ios=d["app-ios"] as? [String:Any] ?? [:], dist=ios["distribute"] as? [String:Any] ?? [:]
        return ProjectInfo(name:d["name"] as? String ?? "未命名",appID:appID,version:d["versionName"] as? String ?? "1.0.0",versionCode:String(describing:d["versionCode"] ?? "1"),modules:Array((dist["modules"] as? [String:Any] ?? [:]).keys).sorted(),manifest:d)
    }
}

/// Retains enough trailing text to redact passwords split across process output chunks.
public final class SecretRedactor:@unchecked Sendable {
    private let lock=NSLock(),secrets:[String],sink:(String)->Void
    private var pending=""
    public init(secrets:[String],sink:@escaping(String)->Void) {self.secrets=Array(Set(secrets.filter{!$0.isEmpty})).sorted{$0.count>$1.count};self.sink=sink}
    public func accept(_ text:String) {
        lock.lock();pending+=text
        for secret in secrets {pending=pending.replacingOccurrences(of:secret,with:"[已隐藏]")}
        let keep=max(0,(secrets.map(\.count).max() ?? 1)-1)
        let count=max(0,pending.count-keep),cut=pending.index(pending.startIndex,offsetBy:count)
        let safe=String(pending[..<cut]);pending=String(pending[cut...]);if !safe.isEmpty{sink(safe)};lock.unlock()
    }
    public func finish(){lock.lock();let safe=pending;pending="";if !safe.isEmpty{sink(safe)};lock.unlock()}
}
