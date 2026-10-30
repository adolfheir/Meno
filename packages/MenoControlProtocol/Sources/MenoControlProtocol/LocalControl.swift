import Darwin
import Foundation

private func socketFailure(_ context: String) -> ControlError {
    ControlError("ipc_error", "\(context)：\(String(cString: strerror(errno)))")
}
public enum PrivateDirectory {
    public static func prepare(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ControlError("unsafe_directory", "数据目录必须是当前用户拥有的真实目录。")
            }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
public final class InstanceLock {
    private var descriptor: Int32 = -1
    public init(directory: URL) throws {
        try PrivateDirectory.prepare(directory)
        descriptor = Darwin.open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw socketFailure("无法打开宿主锁") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw ControlError("host_running", "Meno 已在这个数据目录运行。")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor) } }
}
private enum LocalSocket {
    static let limit = 1_048_576
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlError("socket_path_too_long", "MENO_DATA_DIR 路径过长，Unix socket 路径需少于 104 字节。") }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    static func configure(_ fd: Int32) {
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketFailure("创建 socket 失败") }
        configure(fd)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { let e = socketFailure("连接宿主失败"); Darwin.close(fd); throw e }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); throw ControlError("unauthorized_peer", "宿主身份与当前用户不一致。") }
        return fd
    }
    static func read(_ fd: Int32) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= limit {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ControlError("connection_interrupted", "宿主连接中断或调用超时；写操作请使用相同 requestId 重试。") }
            if let end = buffer.prefix(count).firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<end])
                guard data.count <= limit else { throw ControlError("message_too_large", "单次本机请求不能超过 1 MiB。") }
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw ControlError("message_too_large", "单次本机请求不能超过 1 MiB。")
    }
    static func write(_ data: Data, to fd: Int32) throws {
        guard data.count <= limit else { throw ControlError("message_too_large", "响应超过 1 MiB，请减小查询分页。") }
        var data = data; data.append(10)
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw socketFailure("发送失败") }; sent += n
            }
        }
    }
}
public final class LocalControlServer: @unchecked Sendable {
    private let path: String
    private var listener: Int32 = -1
    private let handler: @Sendable (ControlRequest) async -> ControlResponse
    public init(path: String, handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) { self.path = path; self.handler = handler }
    /// Caller must hold InstanceLock before binding or removing a stale socket.
    public func start() throws {
        var address = try LocalSocket.address(path)
        if FileManager.default.fileExists(atPath: path) {
            let a = try FileManager.default.attributesOfItem(atPath: path)
            guard a[.type] as? FileAttributeType == .typeSocket,
                  (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ControlError("unsafe_socket", "socket 路径已被其他文件占用，原文件已保留。") }
            guard Darwin.unlink(path) == 0 else { throw socketFailure("清理过期 socket 失败") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketFailure("创建监听 socket 失败") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { let error = socketFailure("监听宿主失败"); Darwin.close(fd); throw error }
        listener = fd
        let handler = self.handler
        DispatchQueue(label: "com.meno.ipc.accept").async {
            let capacity = DispatchSemaphore(value: 16)
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), capacity.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
                LocalSocket.configure(client)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let request = try JSONDecoder.meno.decode(ControlRequest.self, from: LocalSocket.read(client))
                        Task {
                            let response: ControlResponse
                            if request.version != 1 { response = ControlResponse(id: request.id, error: ControlError("protocol_version", "不支持的控制协议版本。")) }
                            else if !["cli", "mcp", "ui"].contains(request.source) { response = ControlResponse(id: request.id, error: ControlError("invalid_source", "未知调用来源。")) }
                            else { response = await handler(request) }
                            do { try LocalSocket.write(JSONEncoder.meno.encode(response), to: client) }
                            catch let error as ControlError where error.code == "message_too_large" {
                                try? LocalSocket.write(JSONEncoder.meno.encode(ControlResponse(id: request.id, error: error)), to: client)
                            } catch { /* A disconnected caller can retry writes using requestId. */ }
                            Darwin.close(client); capacity.signal()
                        }
                    } catch {
                        let response = ControlResponse(id: "", error: ControlError("invalid_request", error.localizedDescription))
                        try? LocalSocket.write(JSONEncoder.meno.encode(response), to: client)
                        Darwin.close(client); capacity.signal()
                    }
                }
            }
        }
    }
    public func stop() {
        if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1; Darwin.unlink(path) }
    }
    deinit { stop() }
}
public struct LocalControlClient: Sendable {
    public init() {}
    public func call(_ request: ControlRequest, autoLaunch: Bool = true) throws -> JSONValue {
        let path = MenoIdentity.socketPath
        let fd: Int32
        do { fd = try LocalSocket.connect(path) }
        catch {
            guard autoLaunch else { throw ControlError("host_not_running", "Meno 宿主尚未运行。") }
            try launchHost()
            let deadline = Date().addingTimeInterval(12)
            var connection: Int32?
            while Date() < deadline {
                if let result = try? LocalSocket.connect(path) { connection = result; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let connection else { throw ControlError("host_start_timeout", "Meno 后台启动超时，请先打开 Meno.app，并检查数据目录及权限。") }
            fd = connection
        }
        defer { Darwin.close(fd) }
        try LocalSocket.write(JSONEncoder.meno.encode(request), to: fd)
        let response = try JSONDecoder.meno.decode(ControlResponse.self, from: LocalSocket.read(fd))
        guard response.version == 1, response.id == request.id else { throw ControlError("protocol_error", "宿主返回了不匹配的响应。") }
        if let error = response.error { throw error }
        return response.result ?? .null
    }
    private func launchHost() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app: URL
        if let override = ProcessInfo.processInfo.environment["MENO_APP_PATH"] { app = URL(fileURLWithPath: override) }
        else if bundled.pathExtension == "app" { app = bundled }
        else { app = URL(fileURLWithPath: "/Applications/Meno.app") }
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Meno").path) else { throw ControlError("host_not_installed", "找不到 Meno.app；请安装到 /Applications，或设置 MENO_APP_PATH。") }
        var arguments = ["-g"]
        if let directory = ProcessInfo.processInfo.environment["MENO_DATA_DIR"] { arguments += ["--env", "MENO_DATA_DIR=" + directory] }
        arguments += [app.path, "--args", "--background"]
        for attempt in 0..<4 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run()
            let diagnostic = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
            // LaunchServices can briefly retain the just-terminated process. Retry
            // procNotFound; other launch failures keep their original diagnostics.
            if attempt < 3, String(decoding: diagnostic, as: UTF8.self).contains("error -600") {
                Thread.sleep(forTimeInterval: 0.25 * Double(attempt + 1))
                continue
            }
            FileHandle.standardError.write(diagnostic)
            throw ControlError("host_start_failed", "无法后台启动 Meno.app。")
        }
    }
}
