import Foundation

public struct FileSigningIdentity {
    public let sha1:String,name:String
    public static func inspect(path:String,password:String,runner:ProcessRunner=ProcessRunner()) throws -> Self {
        guard !path.isEmpty,FileManager.default.fileExists(atPath:path) else {throw PackError("请选择当前包类型的 P12 / PFX 文件；不再使用旧签名身份")}
        let workspace=try CredentialWorkspace();defer{workspace.close()}
        let key=try workspace.write(Data(contentsOf:URL(fileURLWithPath:path)),name:"specified.p12")
        let pass=try workspace.write(Data(password.utf8),name:"password")
        let request=workspace.root.appendingPathComponent("inspect.json")
        try JSONFile.write(["p12":key.path,"passwordFile":pass.path],to:request)
        let result=try runner.run(Paths.fileSigner.path,["inspect",request.path],environment:Paths.fileSignerEnvironment,timeout:30)
        guard let value=try JSONSerialization.jsonObject(with:Data(result.stdout.utf8)) as? [String:Any],let sha=value["identity"] as? String,value["privateKeyVerified"] as? Bool == true else {throw PackError("无法验证指定 P12 的证书与私钥")}
        return Self(sha1:sha,name:value["name"] as? String ?? "")
    }
}
public extension Paths {
    static var fileSigner:URL {
        if let path=ProcessInfo.processInfo.environment["UNIPACK_FILE_SIGNER"] {return URL(fileURLWithPath:path)}
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("unipack-file-signer")
    }
    static var fileSignerEnvironment:[String:String] {
        let frameworks=fileSigner.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks")
        return ["OPENSSL_MODULES":frameworks.appendingPathComponent("ossl-modules").path,"OPENSSL_CONF":"/dev/null"]
    }
}
public enum IOSFileSigner {
    public static func sign(app:URL,p12:URL,password:String,profile:URL,entitlements:URL,runner:ProcessRunner) throws {
        let workspace=try CredentialWorkspace();defer{workspace.close()}
        let pass=try workspace.write(Data(password.utf8),name:"password")
        let request=workspace.root.appendingPathComponent("sign.json")
        try JSONFile.write(["p12":p12.path,"passwordFile":pass.path,"profile":profile.path,"entitlements":entitlements.path,"app":app.path],to:request)
        // The restricted helper has no password argument, keychain API, install or capability-removal path.
        _=try runner.run(Paths.fileSigner.path,["sign",request.path],environment:Paths.fileSignerEnvironment,timeout:600)
    }
}
