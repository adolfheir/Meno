import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(Self.self, from: JSONEncoder.meno.encode(value))
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder.meno.decode(type, from: JSONEncoder.meno.encode(self))
    }
    public func text(pretty: Bool = false) -> String {
        let encoder = JSONEncoder.meno
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        return String(data: (try? encoder.encode(self)) ?? Data("null".utf8), encoding: .utf8)!
    }
}
public extension JSONEncoder {
    static var meno: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer(); try c.encode(TimeText.format(date))
        }
        return encoder
    }
}
public extension JSONDecoder {
    static var meno: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = TimeText.parse(text) else { throw ControlError("invalid_date", "无效的 ISO 8601 时间：\(text)") }
            return date
        }
        return decoder
    }
}
public enum TimeText {
    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
    public static func parse(_ string: String) -> Date? {
        // Foundation's ISO formatter otherwise normalizes Feb 31 / 24:00 and
        // silently ignores trailing text. External parameters must be exact.
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#
        guard let match = string.range(of: pattern, options: .regularExpression), match == string.startIndex..<string.endIndex else { return nil }
        let parts = string.prefix(10).split(separator: "-")
        guard let year = Int(parts[0]), year > 0, let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]) else { return nil }
        let leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
public struct ControlError: Error, Codable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
public struct ControlRequest: Codable, Sendable {
    public var version: Int = 1
    public let id: String
    public let command: String
    public var arguments: [String: JSONValue]
    public let source: String
    public init(command: String, arguments: [String: JSONValue] = [:], source: String = "cli", id: String = UUID().uuidString) {
        self.id = id; self.command = command; self.arguments = arguments; self.source = source
    }
}
public struct ControlResponse: Codable, Sendable {
    public var version: Int = 1
    public let id: String
    public let result: JSONValue?
    public let error: ControlError?
    public init(id: String, result: JSONValue? = nil, error: ControlError? = nil) { self.id = id; self.result = result; self.error = error }
}
public enum MenoIdentity {
    public static let bundleID = "com.meno.app"
    public static let remindersID = "com.meno.reminders"
    public static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MENO_DATA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Meno", isDirectory: true)
    }
    public static var socketPath: String { dataDirectory.appendingPathComponent("control.sock").path }
    public static func pluginID(_ id: String) -> String { id == "reminders" ? remindersID : id }
}
