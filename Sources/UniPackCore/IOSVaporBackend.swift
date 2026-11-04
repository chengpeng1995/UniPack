import Foundation
import Darwin

public protocol PackagingBackend {
    func preflight(project:ProjectConfig,environment:EnvironmentConfig) -> [CheckItem]
    func build(project:ProjectConfig,environment:EnvironmentConfig,event:@escaping(BuildEvent)->Void) throws -> BuildRecord
    func cancel()
}
public final class IOSVaporBackend: PackagingBackend, @unchecked Sendable {
    public let runner:ProcessRunner
    public let context:BuildContext
    public init(runner:ProcessRunner=ProcessRunner()) {self.context=BuildContext();self.runner=runner}
    public init(context:BuildContext) {self.context=context;self.runner=context.runner}
    public func cancel() { context.cancel();runner.cancel() }
    public func preflight(project:ProjectConfig,environment:EnvironmentConfig) -> [CheckItem] {
        var checks:[CheckItem]=[]
        func check(_ name:String,_ body:() throws -> String) { do { checks.append(CheckItem(name,try body(),ok:true)) } catch { checks.append(CheckItem(name,error.localizedDescription,ok:false)) } }
        check("Vapor 项目") { let info=try ProjectReader.inspect(project.path); return "\(info.name) · \(info.appID) · \(info.version)" }
        check("iOS 服务配置") {
            let manifest=try ProjectReader.inspect(project.path).manifest
            let requirements=PlatformServiceRequirements(manifest:manifest,platform:.ios)
            try requirements.validate(context.services(project:project,platform:.ios))
            return "已按启用服务校验；打包时从本次参数快照生成原生配置"
        }
        check("隐私初始化") {
            let manifest=try ProjectReader.inspect(project.path).manifest
            let requirements=PlatformServiceRequirements(manifest:manifest,platform:.ios)
            let effective=PlatformServices.applied(try context.services(project:project,platform:.ios),manifest:manifest,requirements:requirements)
            return PrivacyConfiguration.description(try PrivacyConfiguration.read(manifest:effective))
        }
        check("应用版本") {let version=try context.version ?? BuildVersion.read(project:project.path);try version.validate();return version.title}
        check("HBuilderX") {
            guard FileManager.default.isExecutableFile(atPath:environment.cliPath),!environment.hbuilderVersion.isEmpty else { throw PackError("请在环境页选择 HBuilderX.app") }
            return environment.hbuilderVersion
        }
        check("Xcode") {
            let command=environment.xcodePath+"/usr/bin/xcodebuild"
            guard FileManager.default.isExecutableFile(atPath:command) else { throw PackError("请在环境页选择 Xcode 开发目录") }
            return try runner.run(command,["-version"],timeout:30).output.trimmingCharacters(in:.whitespacesAndNewlines)
        }
        check("Vapor iOS SDK") {
            guard !project.sdkPath.isEmpty else { throw PackError("请下载或导入与 HBuilderX 匹配的 Vapor iOS SDK") }
            let sdk=try SDKInfo.inspect(URL(fileURLWithPath:project.sdkPath)); try sdk.validate(hbuilder:environment.hbuilderVersion); return sdk.root.path
        }
        check("CocoaPods 与工程生成依赖") {
            let tool=try RubyToolchain.discover(pod:environment.podPath)
            _=try runner.run(tool.ruby,["-e","require 'xcodeproj'; puts Xcodeproj::VERSION"],environment:tool.environment,timeout:30)
            return "CocoaPods / xcodeproj 已就绪"
        }
        if !environment.dependencyProxy.isEmpty {
            check("依赖下载代理") {
                guard let url=URL(string:environment.dependencyProxy),["http","https"].contains(url.scheme ?? ""),let host=url.host,url.user == nil,url.password == nil else {throw PackError("代理需为不含账号密码的 HTTP(S) URL")}
                return host+(url.port.map{":\($0)"} ?? "")
            }
        }
        check("Bundle ID") {
            guard project.bundleID.range(of:"^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$",options:.regularExpression) != nil else { throw PackError("请填写合法的 Bundle ID，例如 com.example.app") }; return project.bundleID
        }
        check("指定 P12 文件与描述文件") {
            let signing=project.signing
            guard !signing.profilePath.isEmpty else {throw PackError("请选择当前包类型的描述文件")}
            guard FileManager.default.isExecutableFile(atPath:Paths.fileSigner.path) else {throw PackError("文件签名器缺失，请重新构建 UniPack 应用")}
            let identity=try FileSigningIdentity.inspect(path:signing.p12Path,password:context.password(key:signing.passwordKey) ?? "",runner:runner)
            let profile=try ProvisionProfile.read(signing.profilePath,runner:runner)
            try profile.validate(bundle:project.bundleID,kind:project.kind,identity:identity.sha1,requested:requestedEntitlements(project:project))
            return "\(identity.name) · \(profile.purpose) · 私钥来自指定文件"
        }
        if let info=try? ProjectReader.inspect(project.path) {
            let exported=URL(fileURLWithPath:project.path).appendingPathComponent("unpackage/resources/app-ios/\(info.appID)/www/manifest.json")
            let old=try? JSONFile.read(exported)
            if old != nil { checks.append(CheckItem("资源更新","每次打包都会重新导出资源，现有资源不会直接用于构建。",ok:true,required:false)) }
        }
        return checks
    }
    public func requestedEntitlements(project:ProjectConfig) throws -> [String:Any] {
        let info=try ProjectReader.inspect(project.path)
        let requirements=PlatformServiceRequirements(manifest:info.manifest,platform:.ios)
        let effective=PlatformServices.applied(try context.services(project:project,platform:.ios),manifest:info.manifest,requirements:requirements)
        let ios=effective["app-ios"] as? [String:Any] ?? [:],dist=ios["distribute"] as? [String:Any] ?? [:]
        var requested=(dist["capabilities"] as? [String:Any])?["entitlements"] as? [String:Any] ?? [:]
        let modules=ModuleSelection(manifest:info.manifest,platform:.ios).modules
        if modules["uni-push"] != nil { requested["aps-environment"]=project.kind == .debug ? "development" : "production" }
        if let oauth=modules["uni-oauth"] as? [String:Any],oauth["apple"] != nil { requested["com.apple.developer.applesignin"]=["Default"] }
        if !project.entitlementPath.isEmpty {
            let extra=try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:project.entitlementPath)),format:nil) as? [String:Any] ?? [:]
            for (k,v) in extra { if let old=requested[k], !(old as! NSObject).isEqual(v) { throw PackError("自定义 entitlements 与项目能力冲突：\(k)") }; requested[k]=v }
        }
        return requested
    }
    public func generate(project:ProjectConfig,environment:EnvironmentConfig,resources:URL,work:URL,log:@escaping(String)->Void) throws -> [String:Any] {
        let info=try ProjectReader.inspect(project.path),sdk=try SDKInfo.inspect(URL(fileURLWithPath:project.sdkPath))
        let version=try context.captureVersion(project:project)
        try version.verifyResource(JSONFile.read(resources.appendingPathComponent(info.appID+"/www/manifest.json")))
        let output=work.standardizedFileURL.resolvingSymlinksInPath().path
        for protected in [project.path,sdk.root.path,resources.path] {
            let input=URL(fileURLWithPath:protected).standardizedFileURL.resolvingSymlinksInPath().path
            if output == input || output.hasPrefix(input+"/") {throw PackError("原生工作目录必须独立于业务项目、SDK 和导出资源")}
        }
        try sdk.validate(hbuilder:environment.hbuilderVersion)
        try Paths.ensure(work)
        let exported=try JSONFile.read(resources.appendingPathComponent(info.appID+"/www/manifest.json"))
        let requirements=PlatformServiceRequirements(manifest:info.manifest,exported:exported,platform:.ios)
        let values=try context.services(project:project,platform:.ios);try requirements.validate(values)
        let effective=PlatformServices.applied(values,manifest:info.manifest,requirements:requirements)
        let services=try CredentialWorkspace();defer{services.close()}
        let document=PlatformServices.iosOverrides(values,requirements:requirements)
        let servicesFile=try services.write(JSONSerialization.data(withJSONObject:document),name:"ios-services.json")
        var spec:[String:Any]=["work":work.path,"sdk":sdk.root.path,"resources":resources.path,"project":project.path,"manifest":effective,"appid":info.appID,"name":info.name,"version":version.name,"versionCode":version.code,"bundle":project.bundleID,"kind":project.kind.rawValue,"hbuilderVersion":environment.hbuilderVersion,"entitlementPath":project.entitlementPath]
        spec["initialPrivacyAuthorization"]=try PrivacyConfiguration.read(manifest:effective)
        spec["serviceConfigurationPath"]=servicesFile.path
        spec["moduleSelection"]=ModuleSelection(manifest:effective,exported:exported,platform:.ios).specification
        spec["requiredEntitlements"]=try requestedEntitlements(project:project)
        let pagesFile=URL(fileURLWithPath:project.path).appendingPathComponent("pages.json")
        if FileManager.default.fileExists(atPath:pagesFile.path) {
            let pages=try JSONFile.read(pagesFile)
            if let orientation=(pages["globalStyle"] as? [String:Any])?["pageOrientation"] {spec["pageOrientation"]=orientation}
        }
        let file=work.appendingPathComponent("build-spec.json"); try JSONFile.write(spec,to:file)
        let tool=try RubyToolchain.discover(pod:environment.podPath)
        _=try runner.run(tool.ruby,[Paths.generator.path,file.path],cwd:work,environment:tool.environment,log:log)
        return try JSONFile.read(work.appendingPathComponent("integration.json"))
    }
    public func build(project inputProject:ProjectConfig,environment:EnvironmentConfig,event:@escaping(BuildEvent)->Void) throws -> BuildRecord {
        var project=inputProject
        guard project.kind != .adHoc else {throw PackError("Ad Hoc 历史记录仅供查看，当前只支持 App Store IPA 和自定义基座")}
        let lease=try BuildLease(project:project.path,platform:.ios);defer{lease.release()}
        let version=try context.captureVersion(project:project)
        if !context.credentialsCaptured {try context.captureServices(project:project,platform:.ios)}
        try context.checkCancellation()
        event(.stage("预检",0.02))
        let checks=preflight(project:project,environment:environment)
        let failures=checks.filter{!$0.ok && $0.required}
        guard failures.isEmpty else { throw PackError(failures.map{"\($0.title)：\($0.detail)"}.joined(separator:"\n")) }
        let password=try context.password(key:project.signing.passwordKey) ?? ""
        let sensitive=try CredentialWorkspace();defer{sensitive.close()}
        let p12=try sensitive.write(Data(contentsOf:URL(fileURLWithPath:project.signing.p12Path)),name:"specified.p12")
        let profileFile=try sensitive.write(Data(contentsOf:URL(fileURLWithPath:project.signing.profilePath)),name:"specified.mobileprovision")
        let identity=try FileSigningIdentity.inspect(path:p12.path,password:password,runner:runner)
        project.signing.p12Path=p12.path;project.signing.profilePath=profileFile.path
        let info=try ProjectReader.inspect(project.path),profile=try ProvisionProfile.read(profileFile.path,runner:runner)
        let work=context.work
        try Paths.ensure(work)
        let logFile=work.appendingPathComponent("build.log"); FileManager.default.createFile(atPath:logFile.path,contents:nil)
        let writer=try FileHandle(forWritingTo:logFile), logLock=NSLock()
        defer { try? writer.close() }
        let secretValues=[password]+PlatformServices.redactions(try context.services(project:project,platform:.ios))
        let redactor=SecretRedactor(secrets:secretValues) { safe in logLock.lock();try? writer.write(contentsOf:Data(safe.utf8));logLock.unlock();event(.log(safe)) }
        defer{redactor.finish()}
        let log:(String)->Void={redactor.accept($0)}
        do {
            event(.stage("导出最新 iOS 资源",0.1))
            let exported=try context.export(project:project,environment:environment,platform:.ios,log:log)
            try context.checkCancellation()
            event(.stage("集成官方模块和 UTS 插件",0.3))
            let integration=try generate(project:project,environment:environment,resources:exported,work:work,log:log)
            let requested=integration["entitlements"] as? [String:Any] ?? [:]
            try profile.validate(bundle:project.bundleID,kind:project.kind,identity:identity.sha1,requested:requested)
            var developerEnv=["DEVELOPER_DIR":environment.xcodePath,"COCOAPODS_DISABLE_STATS":"true"]
            if !environment.dependencyProxy.isEmpty {
                guard let proxy=URL(string:environment.dependencyProxy),["http","https"].contains(proxy.scheme ?? ""),proxy.host != nil,proxy.user == nil,proxy.password == nil else {throw PackError("构建代理需为不含账号密码的 HTTP(S) URL")}
                for k in ["HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy"] {developerEnv[k]=environment.dependencyProxy}
            }
            if integration["pods"] as? Bool == true {
                event(.stage("解析 CocoaPods 依赖",0.42))
                _=try runner.run(environment.podPath,["install","--verbose"],cwd:work,environment:developerEnv,timeout:1800,log:log)
            }
            // 静态 XCFramework 的内置隐私文件不会被 CocoaPods 自动嵌入，按实际链接目标合并。
            let ruby=try RubyToolchain.discover(pod:environment.podPath)
            _=try runner.run(ruby.ruby,[Paths.generator.deletingLastPathComponent().appendingPathComponent("ios-pod-privacy.rb").path,work.path],cwd:work,environment:ruby.environment,log:log)
            event(.stage("编译原生工程",0.55))
            let archive=work.appendingPathComponent("UniPackApp.xcarchive"),xcode=environment.xcodePath+"/usr/bin/xcodebuild"
            let archiveArguments=["-workspace",work.appendingPathComponent("UniPackBuild.xcworkspace").path,"-scheme","UniPackApp","-configuration",project.kind == .debug ? "Debug" : "Release","-destination","generic/platform=iOS","-archivePath",archive.path,"-derivedDataPath",work.appendingPathComponent("DerivedData").path,"-jobs","2","CODE_SIGNING_ALLOWED=NO","CODE_SIGNING_REQUIRED=NO","CODE_SIGN_IDENTITY=","archive"]
            _=try runner.run(xcode,archiveArguments,cwd:work,environment:developerEnv,timeout:3600,log:log)
            try context.checkCancellation()
            event(.stage("检查启动入口、原生依赖和资源",0.83))
            let apps=try FileManager.default.contentsOfDirectory(at:archive.appendingPathComponent("Products/Applications"),includingPropertiesForKeys:nil).filter{$0.pathExtension == "app"}
            guard apps.count == 1,let sourceApp=apps.first else {throw PackError("原生归档未包含唯一主应用")}
            let payload=work.appendingPathComponent("FileSign/Payload");try Paths.ensure(payload)
            let app=payload.appendingPathComponent(sourceApp.lastPathComponent)
            try FileManager.default.copyItem(at:sourceApp,to:app)
            try IOSBundleMetadata.validate(app:app,runner:runner)
            // Preserve all requested capabilities and add only the profile-required signing identifiers.
            var signedEntitlements=requested
            let prefix=profile.applicationIdentifier.components(separatedBy:".").first ?? profile.team
            signedEntitlements["application-identifier"]=prefix+"."+project.bundleID
            signedEntitlements["com.apple.developer.team-identifier"]=profile.team
            signedEntitlements["get-task-allow"]=profile.development
            if let beta=profile.entitlements["beta-reports-active"] {signedEntitlements["beta-reports-active"]=beta}
            if signedEntitlements["keychain-access-groups"] == nil {signedEntitlements["keychain-access-groups"]=[prefix+"."+project.bundleID]}
            try profile.validate(bundle:project.bundleID,kind:project.kind,identity:identity.sha1,requested:signedEntitlements)
            let entitlementFile=work.appendingPathComponent("Signing.entitlements")
            try PropertyListSerialization.data(fromPropertyList:signedEntitlements,format:.xml,options:0).write(to:entitlementFile)
            event(.stage("使用指定 P12 文件签名",0.85))
            try IOSFileSigner.sign(app:app,p12:p12,password:password,profile:profileFile,entitlements:entitlementFile,runner:runner)
            try context.checkCancellation()
            let export=work.appendingPathComponent("Export");try Paths.ensure(export)
            let ipa=export.appendingPathComponent("UniPackApp.ipa")
            _=try runner.run("/usr/bin/ditto",["-c","-k","--norsrc","--keepParent",payload.path,ipa.path],timeout:600,log:log)
            event(.stage("校验 IPA 和嵌入签名",0.95))
            try verifyIPA(ipa,bundle:project.bundleID,profile:profile,work:work,requested:requested,expectedIdentity:identity.sha1,version:version,appID:info.appID,log:log)
            try DependencyReport.finishIOS(work:work,app:app,runner:runner)
            try context.checkCancellation()
            let output=URL(fileURLWithPath:project.outputPath.isEmpty ? project.path+"/unpackage/release/ios" : project.outputPath)
            let destination=try ArtifactPublisher.publish(source:ipa,project:project,platform:.ios,mode:project.kind == .debug ? .debug : .release,version:version.name,output:output,context:context)
            event(.stage("打包完成",1))
            return BuildRecord(project:project.path,kind:project.kind,status:"成功",detail:"IPA 启动入口、原生依赖、资源、版本、签名与描述文件已检查",artifact:destination.path,logPath:logFile.path,version:version)
        } catch {
            log("\n构建终止：\(error.localizedDescription)\n日志：\(logFile.path)\n")
            var reason=error is CancellationError ? "已取消" : error.localizedDescription
            for value in secretValues.filter({!$0.isEmpty}).sorted(by:{$0.count>$1.count}) {reason=reason.replacingOccurrences(of:value,with:"[已隐藏]")}
            throw PackError("\(reason)\n日志：\(logFile.path)")
        }
    }
    public func verifyIPA(_ ipa:URL,bundle:String,profile:ProvisionProfile,work:URL,requested:[String:Any],expectedIdentity:String?=nil,version:BuildVersion?=nil,appID:String?=nil,log:@escaping(String)->Void) throws {
        let verify=work.appendingPathComponent("Verify-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:verify)}
        _=try runner.run("/usr/bin/ditto",["-x","-k",ipa.path,verify.path],log:log)
        let payload=verify.appendingPathComponent("Payload")
        let apps=try FileManager.default.contentsOfDirectory(at:payload,includingPropertiesForKeys:nil).filter{$0.pathExtension == "app"}
        guard apps.count == 1,let app=apps.first,let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:app.appendingPathComponent("Info.plist")),format:nil) as? [String:Any],info["CFBundleIdentifier"] as? String == bundle else { throw PackError("IPA 主应用结构或 Bundle ID 不正确") }
        try IOSBundleMetadata.validate(app:app,runner:runner)
        if let version {
            try version.verifyIOS(info)
            guard let appID else {throw PackError("IPA 版本核对缺少应用 AppID")}
            try version.verifyResource(JSONFile.read(app.appendingPathComponent("uni-app-x/apps/"+appID+"/www/manifest.json")))
        }
        _=try runner.run("/usr/bin/codesign",["--verify","--deep","--strict",app.path],log:log)
        if let identity=expectedIdentity {
            let prefix=verify.appendingPathComponent("signer-")
            // codesign accepts the optional filename prefix only when attached to the option.
            _=try runner.run("/usr/bin/codesign",["-d","--extract-certificates="+prefix.path,app.path])
            guard let leaf=try? Data(contentsOf:URL(fileURLWithPath:prefix.path+"0")),!leaf.isEmpty else {throw PackError("未能从 IPA 签名中提取证书，无法核对指定 P12")}
            guard fingerprint(leaf)==identity.uppercased() else {throw PackError("IPA 签名证书与指定 P12 文件不一致")}
        }
        let embedded=try ProvisionProfile.read(app.appendingPathComponent("embedded.mobileprovision").path,runner:runner)
        guard embedded.uuid == profile.uuid else { throw PackError("IPA 嵌入的描述文件与所选方案不符") }
        let signed=try runner.run("/usr/bin/codesign",["-d","--entitlements",":-",app.path]).output
        guard let start=signed.range(of:"<?xml"),let end=signed.range(of:"</plist>",range:start.lowerBound..<signed.endIndex),let actual=try PropertyListSerialization.propertyList(from:Data(signed[start.lowerBound..<end.upperBound].utf8),format:nil) as? [String:Any] else {throw PackError("无法读取 IPA 签名能力清单")}
        guard actual["application-identifier"] as? String == (profile.applicationIdentifier.components(separatedBy:".").first ?? profile.team)+"."+bundle else {throw PackError("IPA 签名缺少预期的应用标识")}
        try validateSignedEntitlements(actual,required:requested)
        guard (actual["get-task-allow"] as? Bool ?? false) == profile.development else {throw PackError("IPA 的调试签名标记与包类型不符")}
    }
}
