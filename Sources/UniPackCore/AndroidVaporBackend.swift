import Foundation
import Darwin

public final class SecretFile {
    public let url:URL
    public init(at url:URL,values:[String:String]) throws {
        self.url=url
        func escape(_ s:String)->String {s.unicodeScalars.map {c in
            switch c.value {case 92:return "\\\\";case 10:return "\\n";case 13:return "\\r";case 9:return "\\t";case 32,58,61,35,33:return "\\"+String(c)
            case 0x21...0x7e:return String(c)
            default:return String(c).utf16.map{String(format:"\\u%04x",$0)}.joined()}
        }.joined()}
        let text=values.sorted{$0.key<$1.key}.map{escape($0.key)+"="+escape($0.value)}.joined(separator:"\n")+"\n"
        let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
        guard fd>=0 else {throw PackError("无法创建权限 0600 的临时签名文件")}
        Darwin.close(fd)
        do {try Data(text.utf8).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)} catch {try? FileManager.default.removeItem(at:url);throw error}
    }
    public func remove(){try? FileManager.default.removeItem(at:url)}
    deinit {remove()}
}
public final class AndroidVaporBackend:PackagingBackend,@unchecked Sendable {
    public let context:BuildContext
    public var runner:ProcessRunner {context.runner}
    public init(context:BuildContext=BuildContext()) {self.context=context}
    public func cancel(){context.cancel()}
    public func preflight(project:ProjectConfig,environment:EnvironmentConfig)->[CheckItem] {
        var items:[CheckItem]=[]
        func check(_ title:String,_ body:() throws -> String){do{items.append(CheckItem(title,try body(),ok:true))}catch{items.append(CheckItem(title,error.localizedDescription,ok:false))}}
        check("Vapor 项目"){let i=try ProjectReader.inspect(project.path);return i.name+" · "+i.version}
        check("应用版本"){let version=try context.version ?? BuildVersion.read(project:project.path);try version.validate();return version.title}
        check("HBuilderX"){guard environment.hbuilderVersion == "5.34.2026102909",FileManager.default.isExecutableFile(atPath:environment.cliPath) else {throw PackError("需要 HBuilderX 5.34.2026102909")};return environment.hbuilderVersion}
        check("Android Vapor SDK"){let sdk=try AndroidSDKInfo.inspect(URL(fileURLWithPath:project.android.sdkPath));try sdk.validate(hbuilder:environment.hbuilderVersion);return sdk.root.path}
        check("JDK"){guard FileManager.default.isExecutableFile(atPath:environment.javaHome+"/bin/java") else {throw PackError("请配置兼容 Gradle 9.2 的 JDK（21 或以上）")};return try runner.run(environment.javaHome+"/bin/java",["-version"],timeout:15).output}
        check("Android SDK / Build Tools"){let root=URL(fileURLWithPath:environment.androidSDKPath);guard FileManager.default.fileExists(atPath:root.appendingPathComponent("platforms/android-36/android.jar").path),let tools=Self.buildTools(environment),FileManager.default.isExecutableFile(atPath:tools+"/apksigner") else {throw PackError("需要 Android platform 36 与带 apksigner 的 Build Tools")};return root.path}
        check("Application ID"){guard project.android.applicationID.range(of:"^[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+$",options:.regularExpression) != nil else {throw PackError("请填写合法的 Android Application ID")};return project.android.applicationID}
        check("Keystore 与私钥"){
            let s=project.android.signing
            guard !s.managed else {throw PackError("请重新选择你指定的 Keystore 文件；不再自动使用旧版生成的证书")}
            guard !s.keystorePath.isEmpty,FileManager.default.fileExists(atPath:s.keystorePath),!s.alias.isEmpty else {throw PackError("请配置当前包类型的 Keystore 和 Alias")}
            for reference in [s.storePasswordKey,s.keyPasswordKey] {
                if let password=try context.password(key:reference),password.contains("\n") || password.contains("\r") {throw PackError("Keystore 密码不能包含换行符")}
            }
            guard try context.password(key:s.storePasswordKey) != nil,try context.password(key:s.keyPasswordKey) != nil else {throw PackError("本地未保存当前文件的签名密码，请在详情中输入两个密码（旧密码不从钥匙串迁移）")}
            return "\(s.alias) · 密码已记住，构建时校验私钥和 APK 签名"
        }
        // 服务参数按启用模块预检；插件以新导出结果为准，不能因已下载但未引用的插件阻止构建。
        check("模块配置与原生插件源码") {
            let info=try ProjectReader.inspect(project.path)
            let requirements=PlatformServiceRequirements(manifest:info.manifest,platform:.android)
            let draft=try context.services(project:project,platform:.android)
            try requirements.validate(draft)
            if requirements.huawei, context.huaweiConfiguration == nil {
                if context.credentialsCaptured {throw PackError("任务缺少华为配置文件快照，请重新提交")}
                _=try PlatformServices.huaweiDocument(draft,bundle:project.android.applicationID)
            }

            return "仅集成本次导出的插件；缺少原生源码或不支持的配置会在原生编译前明确报错"
        }
        return items
    }
    public static func buildTools(_ env:EnvironmentConfig)->String? {
        let root=URL(fileURLWithPath:env.androidSDKPath).appendingPathComponent("build-tools")
        return ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []).sorted{$0.lastPathComponent.compare($1.lastPathComponent,options:.numeric) == .orderedDescending}.first(where:{FileManager.default.isExecutableFile(atPath:$0.appendingPathComponent("apksigner").path)})?.path
    }
    public func build(project:ProjectConfig,environment:EnvironmentConfig,event:@escaping(BuildEvent)->Void) throws -> BuildRecord {
        let lease=try BuildLease(project:project.path,platform:.android);defer{lease.release()}
        let version=try context.captureVersion(project:project)
        if !context.credentialsCaptured {try context.captureServices(project:project,platform:.android)}
        try Paths.ensure(context.work)
        let logFile=context.work.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath:logFile.path,contents:nil)
        let writer=try FileHandle(forWritingTo:logFile);let lock=NSLock();defer{try? writer.close()}
        let signing=project.android.signing
        let store=try context.password(key:signing.storePasswordKey) ?? "",key=try context.password(key:signing.keyPasswordKey) ?? ""
        let inputManifest=try ProjectReader.inspect(project.path).manifest
        let initialRequirements=AndroidServiceRequirements(manifest:inputManifest)
        let serviceDraft=try context.serviceDraft(project:project,requirements:initialRequirements)
        let sensitiveValues=[store,key]+PlatformServices.redactions(serviceDraft,document:context.huaweiConfiguration)
        let redactor=SecretRedactor(secrets:sensitiveValues) {safe in
            lock.lock();try? writer.write(contentsOf:Data(safe.utf8));lock.unlock();event(.log(safe))
        }
        defer{redactor.finish()}
        let log:(String)->Void={redactor.accept($0)}
        do {
        event(.stage("预检",0.02));let failures=preflight(project:project,environment:environment).filter{!$0.ok && $0.required}
        guard failures.isEmpty else {throw PackError(failures.map{$0.title+"："+$0.detail}.joined(separator:"\n"))}
        try context.checkCancellation()
        // Probe key password and validity by signing a disposable JAR with the actual private key before export.
        let passStore=context.work.appendingPathComponent(".store-password"),passKey=context.work.appendingPathComponent(".key-password")
        let tempA=try SecretFile(at:passStore,values:[:]),tempB=try SecretFile(at:passKey,values:[:]);defer{tempA.remove();tempB.remove()}
        try Data((store+"\n").utf8).write(to:passStore);try Data((key+"\n").utf8).write(to:passKey)
        _=try runner.run(environment.javaHome+"/bin/keytool",["-list","-v","-keystore",signing.keystorePath,"-alias",signing.alias,"-storepass:file",passStore.path],timeout:30,log:log)
        let certFile=context.work.appendingPathComponent("signer.der")
        _=try runner.run(environment.javaHome+"/bin/keytool",["-exportcert","-keystore",signing.keystorePath,"-alias",signing.alias,"-storepass:file",passStore.path,"-file",certFile.path],timeout:30)
        _=try runner.run("/usr/bin/openssl",["x509","-inform","der","-in",certFile.path,"-checkend","0","-noout"],timeout:15)
        let marker=context.work.appendingPathComponent("probe.txt");try Data("UniPack signing probe".utf8).write(to:marker)
        let jar=context.work.appendingPathComponent("probe.jar")
        _=try runner.run(environment.javaHome+"/bin/jar",["cf",jar.path,"-C",context.work.path,"probe.txt"],timeout:30)
        _=try runner.run(environment.javaHome+"/bin/jarsigner",["-keystore",signing.keystorePath,"-storepass:file",passStore.path,"-keypass:file",passKey.path,jar.path,signing.alias],timeout:30,log:log)
        event(.stage("等待并导出最新 Android 资源",0.1))
        let resources=try context.export(project:project,environment:environment,platform:.android,log:log)
        try context.checkCancellation()
        event(.stage("集成模块与 UTS / Kotlin 插件",0.3))
        let sdk=try AndroidSDKInfo.inspect(URL(fileURLWithPath:project.android.sdkPath)),info=try ProjectReader.inspect(project.path)
        let native=context.work.appendingPathComponent("Native");try Paths.ensure(native)
        let exported=try JSONFile.read(resources.appendingPathComponent(info.appID+"/www/manifest.json"))
        let serviceRequirements=PlatformServiceRequirements(manifest:info.manifest,exported:exported,platform:.android)
        try serviceRequirements.validate(serviceDraft)
        let effective=PlatformServices.applied(serviceDraft,manifest:info.manifest,requirements:serviceRequirements)
        let finalRequirements=AndroidServiceRequirements(manifest:effective,exported:exported)
        let parameters=try CredentialWorkspace();defer{parameters.close()}
        let parameterFile=parameters.root.appendingPathComponent("manifest-placeholders.json")
        var placeholderValues=serviceDraft
        if !serviceRequirements.wechat {placeholderValues.removeValue(forKey:"WX_APPID")}
        try AndroidServices.write(AndroidServices.placeholders(placeholderValues,requirements:finalRequirements),to:parameterFile)
        var spec:[String:Any]=["work":native.path,"sdk":sdk.root.path,"resources":resources.path,"project":project.path,"manifest":effective,"appid":info.appID,"name":info.name,"version":version.name,"versionCode":version.code,"bundle":project.android.applicationID,"debug":project.android.mode == .debug,"androidSDK":environment.androidSDKPath,"ndkVersion":project.android.ndkVersion,"cmakeVersion":project.android.cmakeVersion,"manifestPlaceholdersPath":parameterFile.path]
        spec["moduleSelection"]=ModuleSelection(manifest:effective,exported:exported,platform:.android).specification
        if serviceRequirements.push {spec["autoNotification"]=serviceDraft["UI_AUTO_NOTIFICATION"] != "false"}
        if serviceRequirements.huawei {
            guard let data=context.huaweiConfiguration else {throw PackError("缺少华为配置快照，请选择配置文件后重新打包")}
            spec["huaweiConfigPath"]=try parameters.write(data,name:"agconnect-services.json").path
        }
        defer{try? FileManager.default.removeItem(at:native.appendingPathComponent("app/agconnect-services.json"))}
        let specFile=context.work.appendingPathComponent("android-spec.json");try JSONFile.write(spec,to:specFile)
        let script=Paths.generator.deletingLastPathComponent().appendingPathComponent("android.rb")
        _=try runner.run("/usr/bin/ruby",[script.path,specFile.path],timeout:120,log:log)
        try FileManager.default.copyItem(at:native.appendingPathComponent(DependencyReport.filename),to:context.work.appendingPathComponent(DependencyReport.filename))
        let secrets=try SecretFile(at:native.appendingPathComponent("signing.properties"),values:["storeFile":signing.keystorePath,"keyAlias":signing.alias,"storePassword":store,"keyPassword":key]);defer{secrets.remove()}
        var env=["JAVA_HOME":environment.javaHome,"ANDROID_HOME":environment.androidSDKPath,"ANDROID_SDK_ROOT":environment.androidSDKPath]
        if !environment.dependencyProxy.isEmpty {
            guard let u=URL(string:environment.dependencyProxy),let host=u.host,u.user == nil,u.password == nil,["http","https"].contains(u.scheme ?? "") else {throw PackError("依赖代理 URL 无效")}
            let proxy="\nsystemProp.http.proxyHost=\(host)\nsystemProp.http.proxyPort=\(u.port ?? 80)\nsystemProp.https.proxyHost=\(host)\nsystemProp.https.proxyPort=\(u.port ?? 80)\n"
            let file=native.appendingPathComponent("gradle.properties"),h=try FileHandle(forWritingTo:file);try h.seekToEnd();try h.write(contentsOf:Data(proxy.utf8));try h.close()
            env["HTTPS_PROXY"]=environment.dependencyProxy
        }
        event(.stage("Gradle 编译与签名 APK",0.5))
        let variant=project.android.mode == .debug ? "debug" : "release"
        do {_=try runner.run("/bin/sh",[native.appendingPathComponent("gradlew").path,":app:assemble"+variant.capitalized,":app:unipackDependencyReport","--no-daemon","--console=plain","--max-workers=2","--no-configuration-cache"],cwd:native,environment:env,timeout:3600,log:log)}
        catch {throw PackError(error.localizedDescription.replacingOccurrences(of:store,with:store.isEmpty ? "" : "[已隐藏]").replacingOccurrences(of:key,with:key.isEmpty ? "" : "[已隐藏]"))}
        try context.checkCancellation();event(.stage("校验 APK 结构、应用标识与签名",0.94))
        let apk=native.appendingPathComponent("app/build/outputs/apk/\(variant)/app-\(variant).apk")
        guard FileManager.default.fileExists(atPath:apk.path),let tools=Self.buildTools(environment) else {throw PackError("Gradle 未生成 APK")}
        let signer=try runner.run(tools+"/apksigner",["verify","--verbose","--print-certs",apk.path],environment:["JAVA_HOME":environment.javaHome],log:log)
        let expected=fingerprint(try Data(contentsOf:certFile)).lowercased()
        guard signer.output.lowercased().replacingOccurrences(of:":",with:"").contains(expected) else {throw PackError("APK 签名证书与所选 Keystore 不匹配")}
        let badging=try runner.run(tools+"/aapt",["dump","badging",apk.path],timeout:30).output
        try version.verifyAndroid(badging)
        guard badging.contains("name='\(project.android.applicationID)'"),badging.contains("application-debuggable") == (project.android.mode == .debug) else {throw PackError("APK 的 Application ID 或调试标记不符合当前配置")}
        let entries=try runner.run("/usr/bin/unzip",["-Z1",apk.path]).output
        guard entries.contains("assets/apps/\(info.appID)/www/manifest.json"),entries.contains("lib/arm64-v8a/") else {throw PackError("APK 缺少应用资源或原生动态库")}
        let embedded=try runner.run("/usr/bin/unzip",["-p",apk.path,"assets/apps/"+info.appID+"/www/manifest.json"],timeout:30).stdout
        try version.verifyResource(JSONFile.parse(embedded,label:"APK 内嵌 manifest.json"))
        let permissions=try runner.run(tools+"/aapt",["dump","permissions",apk.path],timeout:30).stdout
        try DependencyReport.finishAndroid(work:context.work,native:native,permissions:permissions,entries:entries)
        let dest=try ArtifactPublisher.publish(source:apk,project:project,platform:.android,mode:project.android.mode,version:version.name,output:URL(fileURLWithPath:project.android.outputPath.isEmpty ? project.path+"/unpackage/release/android" : project.android.outputPath),context:context)
        event(.stage("打包完成",1));return BuildRecord(project:project.path,kind:project.android.mode == .debug ? .debug : .appStore,status:"成功",detail:"APK 结构、应用标识、版本、调试标记及 Keystore 签名已校验",artifact:dest.path,logPath:logFile.path,version:version)
        } catch {
            if error is CancellationError {throw error}
            let safe=sensitiveValues.filter{!$0.isEmpty}.sorted{$0.count>$1.count}.reduce(error.localizedDescription){$0.replacingOccurrences(of:$1,with:"[已隐藏]")}
            throw PackError(safe)
        }
    }
}
