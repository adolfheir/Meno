import Foundation

/// Atomic persistence. Decode errors are propagated so callers never silently
/// replace an unreadable file with an empty state.
public struct JSONStore<Value: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load(default defaultValue: @autoclosure () -> Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
