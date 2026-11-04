import Foundation
import UniPackCore

func option(_ name:String)->String? {let a=CommandLine.arguments;if let i=a.firstIndex(of:name),i+1<a.count{return a[i+1]};return nil}
func emit(_ object:Any) throws {let d=try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:d,as:UTF8.self))}
do {
    let args=CommandLine.arguments
    guard args.count>1 else {print("unipack inspect <项目> | check <项目> [--sdk 路径 --bundle ID --profile 路径 --p12 文件] | profile <文件> | generate <项目> --sdk 路径 --work 目录（诊断工程，不生成 IPA）");exit(0)}
    let command=args[1]
    guard args.count>2 else{throw PackError("缺少项目目录或文件路径")}
    if command == "profile" {
        let p=try ProvisionProfile.read(args[2]);try emit(["name":p.name,"bundle":p.bundleID,"purpose":p.purpose,"expired":p.expiration<Date(),"deviceCount":p.devices.count]);exit(0)
    }
    guard args.count>2 else{throw PackError("缺少项目目录")}
    var p=ProjectConfig(path:args[2]);p.sdkPath=option("--sdk") ?? "";p.bundleID=option("--bundle") ?? "";p.kind=BuildKind(rawValue:option("--kind") ?? "debug") ?? .debug; var signing=p.signing; signing.profilePath=option("--profile") ?? ""; signing.p12Path=option("--p12") ?? ""; signing.passwordKey=option("--p12-password-key") ?? signing.passwordKey;p.signing=signing
    var env=EnvironmentConfig();env.javaHome=option("--java-home") ?? env.javaHome;env.androidSDKPath=option("--android-sdk") ?? env.androidSDKPath
    let platform=BuildPlatform(rawValue:option("--platform") ?? "ios") ?? .ios
    p.android.sdkPath=option("--sdk") ?? "";p.android.applicationID=option("--bundle") ?? "";p.android.mode=p.kind == .debug ? .debug : .release
    p.outputPath=option("--output") ?? "";p.android.outputPath=p.outputPath
    p.android.signing.keystorePath=option("--keystore") ?? "";p.android.signing.alias=option("--alias") ?? ""
    p.android.signing.storePasswordKey=option("--store-key") ?? p.android.signing.storePasswordKey;p.android.signing.keyPasswordKey=option("--key-key") ?? p.android.signing.keyPasswordKey
    p.android.manifestPlaceholdersPath=option("--module-config") ?? ""
    let context=BuildContext()
    for (optionName,key) in [("--p12-password-file",p.signing.passwordKey),("--store-password-file",p.android.signing.storePasswordKey),("--key-password-file",p.android.signing.keyPasswordKey)] {
        if let file=option(optionName) {
            let password=try String(contentsOfFile:file,encoding:.utf8)
            context.credentials[key]=password.hasSuffix("\n") ? String(password.dropLast()) : password
        }
    }
    let backend:any PackagingBackend=platform == .ios ? IOSVaporBackend(context:context) : AndroidVaporBackend(context:context)
    switch command {
    case "inspect":let i=try ProjectReader.inspect(p.path);try emit(["name":i.name,"appid":i.appID,"version":i.version,"modules":i.modules])
    case "check":let checks=backend.preflight(project:p,environment:env);try emit(checks.map{["title":$0.title,"detail":$0.detail,"ok":$0.ok,"required":$0.required] as [String:Any]});exit(checks.contains{!$0.ok && $0.required} ? 1 : 0)
    case "build":
        let r=try backend.build(project:p,environment:env) { event in switch event {case .stage(let name,_):fputs("\n["+name+"]\n",stderr);case .log(let text):fputs(text,stderr)} }
        try emit(["status":r.status,"artifact":r.artifact,"log":r.logPath])
    case "add-project":
        _=try ProjectReader.inspect(p.path)
        let store=ConfigStore();var saved=try store.load()
        if let i=saved.projects.firstIndex(where:{$0.path == p.path}) {p=saved.projects[i]} else {saved.projects.append(p)}
        try store.save(projects:saved.projects,environment:saved.environment,records:saved.records);try emit(["saved":p.path])
    case "verify-ipa":
        guard let path=option("--ipa"),let work=option("--work") else {throw PackError("缺少 --ipa 或 --work")}
        let profile=try ProvisionProfile.read(p.signing.profilePath)
        let integration=try JSONFile.read(URL(fileURLWithPath:work).appendingPathComponent("integration.json"))
        let buildSpec=try JSONFile.read(URL(fileURLWithPath:work).appendingPathComponent("build-spec.json"))
        guard let versionName=buildSpec["version"] as? String,let versionCode=buildSpec["versionCode"] as? String,let appID=buildSpec["appid"] as? String else {throw PackError("构建记录缺少版本快照")}
        try IOSVaporBackend().verifyIPA(URL(fileURLWithPath:path),bundle:p.bundleID,profile:profile,work:URL(fileURLWithPath:work),requested:integration["entitlements"] as? [String:Any] ?? [:],version:BuildVersion(name:versionName,code:versionCode),appID:appID,log:{fputs($0,stderr)})
        try emit(["verified":path])
    case "generate-android":
        guard let work=option("--work") else {throw PackError("缺少 --work")}
        let i=try ProjectReader.inspect(p.path),sdk=try AndroidSDKInfo.inspect(URL(fileURLWithPath:p.android.sdkPath));try sdk.validate(hbuilder:env.hbuilderVersion)
        let version=try context.captureVersion(project:p)
        try version.verifyResource(JSONFile.read(URL(fileURLWithPath:p.path+"/unpackage/resources/app-android/"+i.appID+"/www/manifest.json")))
        let w=URL(fileURLWithPath:work);try Paths.ensure(w)
        var spec:[String:Any]=["work":w.path,"sdk":sdk.root.path,"resources":p.path+"/unpackage/resources/app-android","project":p.path,"manifest":i.manifest,"appid":i.appID,"name":i.name,"version":version.name,"versionCode":version.code,"bundle":p.android.applicationID,"debug":p.android.mode == .debug,"androidSDK":env.androidSDKPath,"ndkVersion":p.android.ndkVersion,"cmakeVersion":p.android.cmakeVersion,"manifestPlaceholdersPath":p.android.manifestPlaceholdersPath]
        spec["moduleSelection"]=ModuleSelection(manifest:i.manifest,exported:try JSONFile.read(URL(fileURLWithPath:p.path+"/unpackage/resources/app-android/"+i.appID+"/www/manifest.json")),platform:.android).specification
        let file=w.deletingLastPathComponent().appendingPathComponent("android-spec-"+UUID().uuidString+".json");defer{try? FileManager.default.removeItem(at:file)};try JSONFile.write(spec,to:file)
        _=try ProcessRunner().run("/usr/bin/ruby",[Paths.generator.deletingLastPathComponent().appendingPathComponent("android.rb").path,file.path],log:{fputs($0,stderr)})
        try emit(["workspace":w.path])
    case "generate":
        guard let work=option("--work") else {throw PackError("缺少 --work")}
        let data=try IOSVaporBackend().generate(project:p,environment:env,resources:URL(fileURLWithPath:p.path+"/unpackage/resources/app-ios"),work:URL(fileURLWithPath:work),log:{fputs($0,stderr)})
        try emit(data)
    default:throw PackError("未知命令")
    }
} catch {fputs(error.localizedDescription+"\n",stderr);exit(1)}
