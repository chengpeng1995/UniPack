import Foundation
import Darwin

public struct CommandResult {public let status:Int32;public let output:String;public let stdout:String}
public final class ProcessRunner: @unchecked Sendable {
    private let lock=NSLock()
    private var groups:Set<pid_t>=[]
    private var cancelled=false
    private var descendants:[pid_t:[pid_t:UInt64]]=[:]
    public init() {}
    public func reset() { lock.lock(); cancelled=false; lock.unlock() }
    public func checkCancellation() throws {lock.lock();let c=cancelled;lock.unlock();if c || Task<Never,Never>.isCancelled {throw CancellationError()}}
    private static func birth(_ pid:pid_t)->UInt64? {
        var info=proc_bsdinfo()
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {return nil}
        return info.pbi_start_tvsec*1_000_000+info.pbi_start_tvusec
    }
    private func observeChildren(_ root:pid_t) {
        lock.lock();var known=descendants[root] ?? [:];lock.unlock()
        var queue=[root]+known.keys.filter{Self.birth($0)==known[$0]},visited=Set<pid_t>()
        while !queue.isEmpty,visited.count<2048 {
            let parent=queue.removeFirst();guard visited.insert(parent).inserted else {continue}
            var children=[pid_t](repeating:0,count:512)
            let count=proc_listchildpids(parent,&children,Int32(children.count*MemoryLayout<pid_t>.size))
            if count>0 {for child in children.prefix(min(Int(count),children.count)) where child>0 {if let stamp=Self.birth(child){known[child]=stamp;queue.append(child)}}}
        }
        lock.lock();if groups.contains(root){descendants[root]=known};lock.unlock()
    }
    private func stopGroup(_ pid:pid_t, signal:Int32) {
        // Gradle single-use daemons create a new process group. Track only descendants of this
        // command and verify process birth time before signalling, so unrelated jobs remain safe.
        observeChildren(pid)
        lock.lock();let children=descendants[pid] ?? [:];lock.unlock()
        for (child,stamp) in children where Self.birth(child)==stamp {Darwin.kill(child,signal)}
        Darwin.kill(-pid,signal)
        DispatchQueue.global().asyncAfter(deadline:.now()+2) {
            for (child,stamp) in children where Self.birth(child)==stamp {Darwin.kill(child,SIGKILL)}
            self.lock.lock();let owned=self.groups.contains(pid);self.lock.unlock()
            if owned {Darwin.kill(-pid,SIGKILL)}
        }
    }
    public func cancel() {lock.lock();cancelled=true;let active=groups;lock.unlock();active.forEach{stopGroup($0,signal:SIGTERM)}}
    public func run(_ executable:String,_ args:[String],cwd:URL?=nil,environment:[String:String]=[:],allowFailure:Bool=false,timeout:TimeInterval=1800,log:@escaping(String)->Void={_ in}) throws -> CommandResult {
        try checkCancellation()
        var env=ProcessInfo.processInfo.environment
        for key in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy"] {env.removeValue(forKey:key)}
        env["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"+(env["PATH"] ?? "")
        env["LANG"]="en_US.UTF-8";env["LC_ALL"]="en_US.UTF-8";environment.forEach{env[$0.key]=$0.value}
        let stdout=Pipe(),stderr=Pipe()
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attributes)
        defer{posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes)}
        posix_spawn_file_actions_adddup2(&actions,stdout.fileHandleForWriting.fileDescriptor,STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions,stderr.fileHandleForWriting.fileDescriptor,STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions,FileHandle.nullDevice.fileDescriptor,STDIN_FILENO)
        if let cwd {if #available(macOS 26.0,*) {posix_spawn_file_actions_addchdir(&actions,cwd.path)} else {posix_spawn_file_actions_addchdir_np(&actions,cwd.path)}}
        posix_spawnattr_setpgroup(&attributes,0)
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_CLOEXEC_DEFAULT))
        var argv=([executable]+args).map{strdup($0)}+[nil],envp=env.map{strdup("\($0.key)=\($0.value)")}+[nil]
        defer{argv.compactMap{$0}.forEach{free($0)};envp.compactMap{$0}.forEach{free($0)}}
        var pid:pid_t=0
        let error=posix_spawn(&pid,executable,&actions,&attributes,&argv,&envp)
        try stdout.fileHandleForWriting.close();try stderr.fileHandleForWriting.close()
        guard error == 0 else{throw PackError("无法启动 \(URL(fileURLWithPath:executable).lastPathComponent)：\(String(cString:strerror(error)))")}
        lock.lock();groups.insert(pid);let alreadyCancelled=cancelled;lock.unlock()
        defer{lock.lock();groups.remove(pid);descendants.removeValue(forKey:pid);lock.unlock()}
        if alreadyCancelled {stopGroup(pid,signal:SIGTERM)}
        let buffer=LockedOutput(),standard=LockedOutput(),readers=DispatchGroup()
        for pipe in [stdout,stderr] {
            readers.enter();DispatchQueue.global(qos:.utility).async {
                defer{readers.leave()}
                var incomplete=Data()
                while true {
                    let data=pipe.fileHandleForReading.availableData
                    if data.isEmpty {if !incomplete.isEmpty{log(String(decoding:incomplete,as:UTF8.self))};break}
                    buffer.append(data);if pipe === stdout {standard.append(data)};incomplete.append(data)
                    var decoded=false
                    for held in 0...min(3,incomplete.count) {
                        let length=incomplete.count-held
                        if let text=String(data:incomplete.prefix(length),encoding:.utf8) {incomplete=Data(incomplete.suffix(held));if !text.isEmpty{log(text)};decoded=true;break}
                    }
                    if !decoded {log(String(decoding:incomplete,as:UTF8.self));incomplete.removeAll(keepingCapacity:true)}
                }
            }
        }
        let started=Date();var status:Int32=0,timedOut=false
        while true {
            observeChildren(pid)
            let result=waitpid(pid,&status,WNOHANG)
            if result == pid {break}
            if result == -1 && errno != EINTR {throw PackError("等待子进程失败")}
            if !timedOut && Date().timeIntervalSince(started)>timeout {timedOut=true;stopGroup(pid,signal:SIGTERM)}
            Thread.sleep(forTimeInterval:0.05)
        }
        readers.wait();try checkCancellation()
        if timedOut {throw PackError("命令超时：\(URL(fileURLWithPath:executable).lastPathComponent)")}
        let signal=status&0x7f,code=signal == 0 ? (status>>8)&0xff : 128+signal
        let result=CommandResult(status:code,output:buffer.value,stdout:standard.value)
        if code != 0 && !allowFailure {
            if result.output.contains("errSecInternalComponent") || result.output.contains("User interaction is not allowed") {
                throw PackError("系统签名校验失败。请检查指定 P12 的完整证书链和描述文件；本次未生成成功 IPA。")
            }
            let errors=result.output.components(separatedBy:.newlines).filter{$0.contains(": error:") || $0.hasPrefix("error:") || $0.contains("fatal error:")}.suffix(10).joined(separator:"\n")
            throw PackError("\(URL(fileURLWithPath:executable).lastPathComponent) 执行失败（\(code)）\n\(errors)\n\(result.output.suffix(2500))")
        }
        return result
    }
}
private final class LockedOutput: @unchecked Sendable {
    private let lock=NSLock(); private var data=Data()
    func append(_ bytes:Data) {lock.lock();data.append(bytes);if data.count>8_000_000 {data=Data(data.suffix(4_000_000))};lock.unlock()}
    var value:String {lock.lock();defer{lock.unlock()};return String(decoding:data,as:UTF8.self)}
}
public enum RubyToolchain {
    public static func discover(pod:String) throws -> (ruby:String,environment:[String:String]) {
        guard FileManager.default.isExecutableFile(atPath:pod) else { throw PackError("未找到 CocoaPods，请安装后在环境页选择 pod 可执行文件。") }
        let wrapper=(try? String(contentsOfFile:pod,encoding:.utf8)) ?? ""
        var env:[String:String]=[:], ruby="/usr/bin/ruby"
        if let match=wrapper.range(of:"GEM_HOME=\"([^\"]+)\"",options:.regularExpression) {
            let home=String(wrapper[match]).replacingOccurrences(of:"GEM_HOME=\"",with:"").replacingOccurrences(of:"\"",with:"")
            env["GEM_HOME"]=home
            if let first=try? String(contentsOfFile:home+"/bin/pod",encoding:.utf8).components(separatedBy:.newlines).first, first.hasPrefix("#!/") { ruby=String(first.dropFirst(2)) }
        } else if wrapper.hasPrefix("#!/") { ruby=String(wrapper.components(separatedBy:.newlines)[0].dropFirst(2)) }
        if ruby.contains(" ") { ruby=FileManager.default.isExecutableFile(atPath:"/opt/homebrew/bin/ruby") ? "/opt/homebrew/bin/ruby" : "/usr/bin/ruby" }
        return (ruby,env)
    }
}
