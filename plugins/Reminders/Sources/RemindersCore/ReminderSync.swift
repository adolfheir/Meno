import Combine
import Foundation
import MenoControlProtocol
import Security

private struct SyncDeployment: Decodable {
    let endpoint: String
    let token: String?
    let rootCertificateDER: Data?
}

private struct SyncConnection {
    let endpoint: URL
    let host: String
    let token: String?
    let anchor: SecCertificate?

    init(deployment: SyncDeployment) throws {
        let address = deployment.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: address),
              let endpoint = components.url,
              let host = components.host?.lowercased(), !host.isEmpty,
              components.scheme?.lowercased() == "https" ||
                (components.scheme?.lowercased() == "http" && Self.isPrivateHost(host)),
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil else {
            throw ControlError("invalid_server", "请输入完整的服务地址。HTTP 仅支持本机、局域网或私有 VPN 地址。")
        }
        if let token = deployment.token {
            guard components.scheme?.lowercased() == "https", token.utf8.count >= 40,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
            else { throw ControlError("invalid_deployment", "安装包中的同步凭据无效。") }
        } else if components.scheme?.lowercased() == "https" {
            throw ControlError("invalid_deployment", "此安装包缺少部署凭据。")
        }
        if let data = deployment.rootCertificateDER {
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
                throw ControlError("invalid_deployment", "安装包中的服务证书无效。")
            }
            anchor = certificate
        } else { anchor = nil }
        self.endpoint = endpoint
        self.host = host
        token = deployment.token
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> UInt8? in
            guard let value = UInt8(part), String(value) == part else { return nil }
            return value
        }
        guard parts.count == 4, octets.count == 4 else { return false }
        let (a, b) = (octets[0], octets[1])
        return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) || (a == 100 && (64...127).contains(b))
    }
}

private struct SyncEnvelope: Decodable {
    let serverId: UUID
    let version: Int
    let state: SyncState
}

private struct SyncWrite: Encodable {
    let serverId: UUID
    let version: Int
    let state: SyncState
}

private final class SyncSessionDelegate: NSObject, URLSessionTaskDelegate {
    let host: String
    let anchor: SecCertificate?

    init(connection: SyncConnection) {
        host = connection.host
        anchor = connection.anchor
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let anchor else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.host.lowercased() == host, let trust = challenge.protectionSpace.serverTrust,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private final class SyncAPI {
    static let limit = 8 * 1024 * 1024
    let connection: SyncConnection
    private let session: URLSession

    init(connection: SyncConnection) {
        self.connection = connection
        session = URLSession(configuration: .ephemeral, delegate: SyncSessionDelegate(connection: connection), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func exchange(_ write: SyncWrite? = nil) async throws -> SyncEnvelope? {
        var request = URLRequest(url: connection.endpoint.appendingPathComponent("v1").appendingPathComponent("state"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        if let token = connection.token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let write {
            let body = try JSONEncoder.meno.encode(write)
            guard body.count <= Self.limit else { throw ControlError("sync_too_large", "同步服务的提醒数据已超过同步容量。") }
            request.httpMethod = "PUT"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ControlError("sync_response", "同步服务响应无效。") }
        if write != nil && response.statusCode == 409 { return nil }
        if response.statusCode == 401 { throw ControlError("sync_auth", "此安装包的同步凭据已失效。") }
        guard response.statusCode == 200, data.count <= Self.limit + 1024 else {
            throw ControlError("sync_response", "同步服务返回错误（HTTP \(response.statusCode)）。")
        }
        return try JSONDecoder.meno.decode(SyncEnvelope.self, from: data)
    }
}

@MainActor
public final class ReminderSync: ObservableObject {
    @Published public private(set) var configuredAddress: String?
    @Published public private(set) var isEnabled = false
    @Published public private(set) var busy = false
    @Published public private(set) var status = "同步未开启"
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var hasError = false
    public var onPull: (() async -> Void)?
    private let service: ReminderService
    private static let pauseKey = "sync_paused_v1"
    private let api: SyncAPI?
    private var periodic: Task<Void, Never>?
    private var needsSync = false

    public init(service: ReminderService, configuration: URL? = Bundle.main.url(forResource: "MenoSync", withExtension: "json")) {
        self.service = service
        var client: SyncAPI?
        do {
            guard let configuration else {
                throw ControlError("sync_configuration", "此安装包缺少同步部署配置。")
            }
            let deployment = try JSONDecoder().decode(SyncDeployment.self, from: Data(contentsOf: configuration))
            let connection = try SyncConnection(deployment: deployment)
            let enabled = try service.store.metadata(Self.pauseKey) != "true"
            client = SyncAPI(connection: connection)
            configuredAddress = connection.endpoint.absoluteString
            isEnabled = enabled
            status = enabled ? "等待连接同步服务" : "同步已暂停，本机提醒仍可使用"
        } catch {
            hasError = true
            status = error.localizedDescription
        }
        api = client
        service.onLocalMutation = { [weak self] in Task { await self?.syncNow() } }
    }

    public func start() {
        guard periodic == nil else { return }
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    public func stop() {
        periodic?.cancel()
        periodic = nil
    }

    public func setEnabled(_ enabled: Bool) {
        guard api != nil, !busy else { return }
        do {
            try service.store.setMetadata(Self.pauseKey, enabled ? "false" : "true")
            isEnabled = enabled
            hasError = false
            status = enabled ? "等待连接同步服务" : "同步已暂停，本机提醒仍可使用"
            if enabled { Task { await syncNow() } }
        } catch { show(error) }
    }

    public func syncNow() async {
        guard isEnabled, let api else { return }
        if busy { needsSync = true; return }
        busy = true
        defer { busy = false }
        do { try await synchronize(api) }
        catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { show(error) }
    }

    private func verifyServer(_ id: UUID) throws {
        if let previous = try service.store.metadata(ReminderService.syncServerKey), previous != id.uuidString {
            throw ControlError("different_sync_server", "本机已连接过另一份同步数据库。请使用原同步服务或恢复其数据库备份。")
        }
    }

    private func synchronize(_ api: SyncAPI) async throws {
        // Retry if another device writes between GET and PUT, or this device
        // edits while its previous snapshot is in flight.
        for _ in 0..<6 {
            needsSync = false
            guard let remote = try await api.exchange() else { continue }
            try verifyServer(remote.serverId)
            let remoteState = try remote.state.validated()
            try service.store.transaction {
                if try service.store.metadata(ReminderService.syncServerKey) == nil {
                    try service.store.setMetadata(ReminderService.syncServerKey, remote.serverId.uuidString)
                }
                try service.store.observeClock(remoteState.maxCounter)
            }
            let local = try service.store.syncState()
            let merged = try local.merging(remoteState)
            if merged != remoteState {
                guard let written = try await api.exchange(SyncWrite(serverId: remote.serverId, version: remote.version, state: merged)) else { continue }
                guard written.serverId == remote.serverId, written.version == remote.version + 1,
                      try written.state.validated() == merged else {
                    throw ControlError("sync_response", "同步服务返回了不一致的数据。")
                }
            }
            try Task.checkCancellation()
            if try service.applySyncedState(merged, serverID: remote.serverId) {
                await onPull?()
            }
            lastSyncedAt = .now
            hasError = false
            status = "提醒已同步"
            if !needsSync, try service.store.syncState() == merged { return }
        }
        throw ControlError("sync_busy", "两端正在同时修改，稍后将自动重试。")
    }

    private func show(_ error: Error) {
        hasError = true
        status = "同步失败，本机数据已保留。\(error.localizedDescription)"
    }
}
