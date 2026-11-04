import Foundation
import CryptoKit
import Darwin

/// Passwords are remembered in UniPack's own files. This type never uses Security.framework.
/// The local wrapping key and encrypted values are owner-only; no secret is encoded in settings/jobs.
public enum LocalCredentialStore {
    private static let lock=NSLock()
    public static var directory:URL {Paths.data.appendingPathComponent("LocalCredentials")}
    public static func savePassword(_ value:String,key:String) throws {
        guard !value.contains("\0") else {throw PackError("密码不能包含 NUL 字符")}
        try access(create:true) {values in values[key]=value}
    }
    public static func password(key:String) throws -> String? {
        var result:String?;try access(create:false){result=$0[key]};return result
    }
    public static func contains(key:String)->Bool {(try? password(key:key)) != nil}
    public static func clear(key:String) throws {try access(create:false){$0.removeValue(forKey:key)}}
    public static func clear(keys:Set<String>) throws {
        try access(create:false){values in for key in keys {values.removeValue(forKey:key)}}
    }
    private static func access(create:Bool,_ body:(inout [String:String])->Void) throws {
        lock.lock();defer{lock.unlock()}
        let root=directory,fm=FileManager.default
        guard create || fm.fileExists(atPath:root.path) else {var empty:[String:String]=[:];body(&empty);return}
        try Paths.ensure(root);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        let fd=Darwin.open(root.appendingPathComponent(".lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0,flock(fd,LOCK_EX)==0 else {if fd>=0{Darwin.close(fd)};throw PackError("无法访问本地密码缓存")}
        defer{flock(fd,LOCK_UN);Darwin.close(fd)}
        let keyFile=root.appendingPathComponent("wrapping.key"),store=root.appendingPathComponent("passwords.sealed")
        let keyData:Data
        if fm.fileExists(atPath:keyFile.path) {keyData=try ownerRead(keyFile)}
        else {
            guard !fm.fileExists(atPath:store.path) else {throw PackError("本地密码缓存密钥丢失，请恢复 LocalCredentials 目录或清空该目录后重新填写密码")}
            guard create else {var empty:[String:String]=[:];body(&empty);return}
            keyData=SymmetricKey(size:.bits256).withUnsafeBytes{Data($0)}
            try ownerWrite(keyData,to:keyFile,exclusive:true)
        }
        guard keyData.count==32 else {throw PackError("本地密码缓存密钥损坏，请恢复 LocalCredentials 目录")}
        let key=SymmetricKey(data:keyData)
        var values:[String:String]=[:]
        if fm.fileExists(atPath:store.path) {
            do {let box=try AES.GCM.SealedBox(combined:ownerRead(store));let clear=try AES.GCM.open(box,using:key);values=try JSONDecoder().decode([String:String].self,from:clear)}
            catch {throw PackError("本地密码缓存无法解密，请恢复 LocalCredentials 目录或清空该目录后重新填写密码")}
        }
        let old=values;body(&values)
        if values != old {
            let encrypted=try AES.GCM.seal(JSONEncoder().encode(values),using:key)
            guard let data=encrypted.combined else {throw PackError("本地密码缓存加密失败")}
            let temp=root.appendingPathComponent("."+UUID().uuidString)
            defer{try? fm.removeItem(at:temp)}
            try ownerWrite(data,to:temp,exclusive:true)
            guard Darwin.rename(temp.path,store.path)==0 else {throw PackError("保存本地密码缓存失败")}
        }
    }
    private static func ownerRead(_ url:URL) throws -> Data {
        let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else {throw PackError("本地密码缓存文件无法读取")}
        var st=stat()
        guard fstat(fd,&st)==0,st.st_uid==getuid(),st.st_mode&S_IFMT==S_IFREG,st.st_mode&0o077==0 else {Darwin.close(fd);throw PackError("本地密码缓存的属主、类型或权限不正确")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? handle.close()};return try handle.readToEnd() ?? Data()
    }
    private static func ownerWrite(_ data:Data,to url:URL,exclusive:Bool) throws {
        let fd=Darwin.open(url.path,O_CREAT|O_WRONLY|O_NOFOLLOW|O_CLOEXEC|(exclusive ? O_EXCL : O_TRUNC),0o600)
        guard fd>=0 else {throw PackError("无法写入本地密码缓存文件")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? handle.close()};try handle.write(contentsOf:data)
    }
}

/// Credential snapshots and password hand-off files live only for one operation.
/// A process lock allows the next launch to remove crash leftovers without touching live tasks.
public final class CredentialWorkspace {
    public let root:URL
    private var fd:Int32 = -1
    public init() throws {
        let parent=Paths.data.appendingPathComponent("TemporaryCredentials");try Paths.ensure(parent)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:parent.path)
        root=parent.appendingPathComponent(UUID().uuidString);try Paths.ensure(root)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        fd=Darwin.open(root.appendingPathComponent(".active").path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else {throw PackError("无法创建临时凭证目录")}
    }
    public func write(_ data:Data,name:String) throws -> URL {
        guard !name.contains("/"),name != ".",name != ".." else {throw PackError("临时凭证文件名不正确")}
        let url=root.appendingPathComponent(name),file=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard file>=0 else {throw PackError("无法创建临时凭证文件")}
        let h=FileHandle(fileDescriptor:file,closeOnDealloc:true);defer{try? h.close()};try h.write(contentsOf:data);return url
    }
    public func close() {if fd>=0 {try? FileManager.default.removeItem(at:root);flock(fd,LOCK_UN);Darwin.close(fd);fd = -1}}
    deinit {close()}
    public static func cleanInterrupted() {
        let fm=FileManager.default,parent=Paths.data.appendingPathComponent("TemporaryCredentials")
        for root in (try? fm.contentsOfDirectory(at:parent,includingPropertiesForKeys:[.isSymbolicLinkKey,.isDirectoryKey])) ?? [] {
            guard UUID(uuidString:root.lastPathComponent) != nil,let v=try? root.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]),v.isSymbolicLink != true,v.isDirectory == true else {continue}
            let fd=Darwin.open(root.appendingPathComponent(".active").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
            if fd>=0 {if flock(fd,LOCK_EX|LOCK_NB)==0 {try? fm.removeItem(at:root);flock(fd,LOCK_UN)};Darwin.close(fd)}
        }
    }
}
